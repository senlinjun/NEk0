//! Multi-track session recorder with a rolling backtrack buffer.
//!
//! Design: while a connection is up, every audio path taps into this module
//! and hands over work through a lock-free queue; a single recorder thread
//! owns all state, so hot paths never block:
//!
//! - remote clients: `decode_to_client_buffer` (api.rs) pushes the RAW Opus
//!   packet tagged with the playback slot the jitter buffer assigned it —
//!   no decode/re-encode cost, tracks align with the mix clock by
//!   construction (a packet scheduled for slot S is summed into the mix
//!   frame generated at slot S);
//! - own microphone: the `Command::SendAudio` encode loop pushes the already
//!   encoded uplink packet at the current mix slot;
//! - the playback mix: `gen_output_mix_frame` pushes each stereo frame; the
//!   recorder thread Opus-encodes it (what-you-hear mix: positional gains,
//!   per-client volumes, SFX).
//!
//! Frames are stored as `(key, packet)` with `key = (epoch << 32) | slot`.
//! The epoch absorbs mixing-clock resets (PLAYED_SAMPLES is zeroed on stream
//! rebuild/teardown), keeping keys monotonic. Pruning keeps the last
//! `backtrack_secs` (the backtrack window); a continuous recording pins
//! everything since its start until it is saved or discarded.
//!
//! Saving decodes the selected window slot-by-slot (silence for gaps, so
//! tracks stay cuttable/alignable) and streams WAV files to a Dart-supplied
//! directory; Dart then moves them into Downloads. All buffers are Opus, so
//! an hour of a chatty user costs roughly 15–25 MB of RAM, silence nothing.

use crossbeam::queue::SegQueue;
use once_cell::sync::Lazy;
use opus_rs::{Application, OpusDecoder, OpusEncoder};
use parking_lot::Mutex;
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::io::{Seek, SeekFrom, Write as _};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::{FRAME_SIZE, PLAYED_SAMPLES, STATE, TsEvent, TsRecordingFile};

/// Sentinel track id for our own microphone (real client ids never reach this).
pub const OWN_TRACK_ID: u16 = u16::MAX;
/// Save mode for `ts_save_recording`: one mixed file (the live playback mix
/// plus our own mic summed in).
pub const SAVE_MODE_MIX: u8 = 0;
/// Save mode for `ts_save_recording`: one mono file per user.
pub const SAVE_MODE_SEPARATE: u8 = 1;

/// Slots per second: 20 ms frames at 48 kHz.
const SLOTS_PER_SEC: u64 = 50;
/// Samples per slot per channel.
const SAMPLES_PER_SLOT: usize = 960;
/// Output buffer for one Opus frame (libopus caps packets at ~1275 bytes).
const OPUS_BUF: usize = 4000;
/// Stereo mix bitrate. Voice tracks use the encoder default.
const MIX_BITRATE_BPS: i32 = 96_000;
/// Safety valve for a forgotten continuous recording: auto-stop after 4 h
/// (the buffered data stays savable until disconnect).
const MAX_RECORDING_SLOTS: u64 = 4 * 3600 * SLOTS_PER_SEC;
/// A slot jump backward by more than this means the mixing clock was reset
/// (device switch / teardown), not a late packet — bump the virtual base.
const CLOCK_RESET_SLACK: u64 = 1024;
/// Keys further than this ahead of the newest buffered frame are stragglers
/// carrying pre-reset slots (a packet decoded just before a clock reset but
/// processed after it) — dropped instead of punching a hole in the timeline.
const KEY_HORIZON: u64 = 1024;
const DEFAULT_BACKTRACK_SECS: u32 = 300;

// ─── Producer side (hot paths — never locks) ─────────────────────────

enum RecItem {
    /// Raw Opus packet from a remote client, tagged with its playback slot.
    Remote { client_id: u16, slot: u64, packet: Vec<u8> },
    /// Own uplink Opus packet, tagged with the current mix slot.
    Mic { slot: u64, packet: Vec<u8> },
    /// One stereo mix frame (960 L/R pairs), Opus-encoded by the thread.
    Mix { slot: u64, interleaved: Vec<f32> },
}

static REC_QUEUE: Lazy<SegQueue<RecItem>> = Lazy::new(SegQueue::new);
/// Cheap gate so unused builds (feature never configured / disconnected)
/// skip the queue pushes entirely.
static REC_ON: AtomicBool = AtomicBool::new(false);
static THREAD_STARTED: AtomicBool = AtomicBool::new(false);
static SAVING: AtomicBool = AtomicBool::new(false);

pub fn push_remote(client_id: u16, slot: u64, packet: &[u8]) {
    if !REC_ON.load(Ordering::Relaxed) || packet.is_empty() {
        return;
    }
    ensure_thread();
    REC_QUEUE.push(RecItem::Remote { client_id, slot, packet: packet.to_vec() });
}

pub fn push_mic(slot: u64, packet: &[u8]) {
    if !REC_ON.load(Ordering::Relaxed) || packet.is_empty() {
        return;
    }
    ensure_thread();
    REC_QUEUE.push(RecItem::Mic { slot, packet: packet.to_vec() });
}

/// Called from the cpal output callback: interleaves one mix frame and
/// queues it (the encode happens on the recorder thread).
pub fn push_mix(slot: u64, l: &[f32], r: &[f32]) {
    if !REC_ON.load(Ordering::Relaxed) {
        return;
    }
    ensure_thread();
    let mut interleaved = Vec::with_capacity(l.len() * 2);
    for i in 0..l.len() {
        interleaved.push(l[i]);
        interleaved.push(r.get(i).copied().unwrap_or(0.0));
    }
    REC_QUEUE.push(RecItem::Mix { slot, interleaved });
}

fn ensure_thread() {
    if THREAD_STARTED.swap(true, Ordering::AcqRel) {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("recorder".into())
        .spawn(recorder_loop);
}

// ─── Recorder state ──────────────────────────────────────────────────

pub struct Track {
    client_id: u16,
    /// Snapshot from the roster when the track was created; re-resolved at
    /// save/status time when empty (roster may have lagged).
    nickname: String,
    uid: Option<String>,
    /// (key, raw Opus packet), strictly ascending keys.
    frames: VecDeque<(u64, Vec<u8>)>,
}

impl Clone for Track {
    fn clone(&self) -> Self {
        Track {
            client_id: self.client_id,
            nickname: self.nickname.clone(),
            uid: self.uid.clone(),
            frames: self.frames.clone(),
        }
    }
}

pub struct RecorderState {
    backtrack_secs: u32,
    /// Dart-provided directory used ONLY for the auto-save on disconnect.
    work_dir: String,
    /// Continuous recording active (no pruning before rec_start_key).
    recording: bool,
    /// Recording stopped, buffer pinned until saved/discarded.
    hold: bool,
    rec_start_key: u64,
    /// Added to raw mixing-clock slots. Bumped when the clock resets (see
    /// pack_key) so keys stay monotonic AND contiguous — a save window may
    /// span a reset without inflating the timeline.
    virtual_base: u64,
    last_raw_slot: u64,
    tracks: HashMap<u16, Track>,
    /// Stereo Opus packets of the live playback mix.
    mix: VecDeque<(u64, Vec<u8>)>,
    last_mix_key: u64,
    mix_encoder: Option<OpusEncoder>,
}

impl Default for RecorderState {
    fn default() -> Self {
        RecorderState {
            backtrack_secs: DEFAULT_BACKTRACK_SECS,
            work_dir: String::new(),
            recording: false,
            hold: false,
            rec_start_key: 0,
            virtual_base: 0,
            last_raw_slot: 0,
            tracks: HashMap::new(),
            mix: VecDeque::new(),
            last_mix_key: 0,
            mix_encoder: None,
        }
    }
}

static RECORDER: Lazy<Mutex<RecorderState>> = Lazy::new(|| Mutex::new(RecorderState::default()));

impl RecorderState {
    /// Maps a raw mixing-clock slot to a monotonic virtual-timeline key.
    /// When the clock jumps backward by more than CLOCK_RESET_SLACK it was
    /// reset (PLAYED_SAMPLES is zeroed on output-stream rebuild/teardown —
    /// see api.rs): fold the new epoch into the virtual timeline right after
    /// the newest buffered frame, keeping keys contiguous so a save window
    /// spanning a reset cannot inflate the output with silence.
    fn pack_key(&mut self, slot: u64) -> u64 {
        if slot < self.last_raw_slot.saturating_sub(CLOCK_RESET_SLACK) {
            let resume = self.data_end_key();
            eprintln!("[recording] clock reset detected, timeline resumes at key {}", resume);
            self.virtual_base = resume;
        }
        self.last_raw_slot = slot;
        self.virtual_base + slot
    }

    fn now_key(&mut self) -> u64 {
        self.pack_key(PLAYED_SAMPLES.load(Ordering::Relaxed) / FRAME_SIZE)
    }

    fn apply(&mut self, item: RecItem) {
        // Straggler guard, shared by all item kinds: a key far beyond the
        // newest buffered frame carries a pre-clock-reset slot.
        let horizon = self.data_end_key() + KEY_HORIZON;
        match item {
            RecItem::Remote { client_id, slot, packet } => {
                if packet.is_empty() {
                    return;
                }
                let key = self.pack_key(slot);
                if key > horizon {
                    return;
                }
                let track = self.tracks.entry(client_id).or_insert_with(|| {
                    // Snapshot name/uid while the track is fresh — the client
                    // may leave before the user ever saves.
                    let (nickname, uid) = {
                        let state = STATE.lock();
                        match state.clients.iter().find(|c| c.id as u16 == client_id) {
                            Some(c) => (c.nickname.clone(), c.uid.clone()),
                            None => (String::new(), None),
                        }
                    };
                    Track { client_id, nickname, uid, frames: VecDeque::new() }
                });
                if track.frames.back().map_or(true, |(k, _)| *k < key) {
                    track.frames.push_back((key, packet));
                }
            }
            RecItem::Mic { slot, packet } => {
                if packet.is_empty() {
                    return;
                }
                let key = self.pack_key(slot);
                if key > horizon {
                    return;
                }
                let track = self.tracks.entry(OWN_TRACK_ID).or_insert_with(|| Track {
                    client_id: 0,
                    nickname: String::new(),
                    uid: None,
                    frames: VecDeque::new(),
                });
                if track.frames.back().map_or(true, |(k, _)| *k < key) {
                    track.frames.push_back((key, packet));
                }
            }
            RecItem::Mix { slot, interleaved } => {
                let key = self.pack_key(slot);
                if !self.mix.is_empty() && (key <= self.last_mix_key || key > horizon) {
                    return; // device-switch straggler — drop instead of unsorting
                }
                self.last_mix_key = key;
                if self.mix_encoder.is_none() {
                    match OpusEncoder::new(48_000, 2, Application::Audio) {
                        Ok(mut enc) => {
                            enc.bitrate_bps = MIX_BITRATE_BPS;
                            self.mix_encoder = Some(enc);
                        }
                        Err(e) => {
                            eprintln!("[recording] mix encoder init failed: {}", e);
                            return;
                        }
                    }
                }
                let mut out = vec![0u8; OPUS_BUF];
                match self
                    .mix_encoder
                    .as_mut()
                    .unwrap()
                    .encode(&interleaved, SAMPLES_PER_SLOT, &mut out)
                {
                    Ok(len) => {
                        out.truncate(len);
                        self.mix.push_back((key, out));
                    }
                    Err(e) => eprintln!("[recording] mix encode error: {}", e),
                }
            }
        }
    }

    fn prune(&mut self) {
        let threshold = if self.recording || self.hold {
            self.rec_start_key
        } else {
            self.now_key().saturating_sub(self.backtrack_secs as u64 * SLOTS_PER_SEC)
        };
        for track in self.tracks.values_mut() {
            while track.frames.front().map_or(false, |(k, _)| *k < threshold) {
                track.frames.pop_front();
            }
        }
        self.tracks.retain(|_, t| !t.frames.is_empty());
        while self.mix.front().map_or(false, |(k, _)| *k < threshold) {
            self.mix.pop_front();
        }
    }

    fn check_max_duration(&mut self) {
        if self.recording
            && self.now_key().saturating_sub(self.rec_start_key) > MAX_RECORDING_SLOTS
        {
            self.recording = false;
            self.hold = true;
            eprintln!("[recording] auto-stopped at max duration");
            push_event(TsEvent::RecordingState { recording: false });
        }
    }

    fn has_data(&self) -> bool {
        !self.mix.is_empty() || self.tracks.values().any(|t| !t.frames.is_empty())
    }

    /// Exclusive end key: one past the newest buffered frame.
    fn data_end_key(&self) -> u64 {
        let mut end = self.mix.back().map_or(0, |(k, _)| k + 1);
        for t in self.tracks.values() {
            if let Some((k, _)) = t.frames.back() {
                end = end.max(k + 1);
            }
        }
        end
    }

    fn data_start_key(&self) -> u64 {
        let mut start = self.mix.front().map_or(u64::MAX, |(k, _)| *k);
        for t in self.tracks.values() {
            if let Some((k, _)) = t.frames.front() {
                start = start.min(*k);
            }
        }
        start
    }
}

fn push_event(ev: TsEvent) {
    STATE.lock().pending_events.push_back(ev);
}

// ─── Recorder thread ─────────────────────────────────────────────────

fn recorder_loop() {
    let mut last_maintenance = Instant::now();
    loop {
        let mut did_work = false;
        if REC_ON.load(Ordering::Acquire) {
            let mut batch = 0usize;
            {
                let mut st = RECORDER.lock();
                while batch < 256 {
                    match REC_QUEUE.pop() {
                        Some(item) => {
                            st.apply(item);
                            batch += 1;
                        }
                        None => break,
                    }
                }
                if batch > 0 || last_maintenance.elapsed() >= Duration::from_millis(500) {
                    st.prune();
                    st.check_max_duration();
                    last_maintenance = Instant::now();
                }
            }
            did_work = batch > 0;
        } else {
            // Feature not configured / disconnected: drop stale items.
            while REC_QUEUE.pop().is_some() {}
            last_maintenance = Instant::now();
        }
        if !did_work {
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

// ─── FFI-facing controls ─────────────────────────────────────────────

/// Arms the recorder for a new connection (resets leftover state) or, when
/// already armed, just updates the configuration so a live session keeps its
/// buffered audio when the user tweaks the settings.
pub fn set_config(backtrack_secs: u32, work_dir: String) {
    ensure_thread();
    let backtrack = backtrack_secs.clamp(10, 3600);
    let mut st = RECORDER.lock();
    if REC_ON.load(Ordering::Acquire) {
        st.backtrack_secs = backtrack;
        if !work_dir.is_empty() {
            st.work_dir = work_dir;
        }
    } else {
        *st = RecorderState {
            backtrack_secs: backtrack,
            work_dir,
            ..RecorderState::default()
        };
        REC_ON.store(true, Ordering::Release);
    }
}

/// Starts a continuous recording. With `include_backtrack` the recording
/// opens with the buffered backtrack window (clamped to what is actually
/// buffered), so the saved file(s) begin with the pre-recorded audio.
pub fn start_recording(include_backtrack: bool) -> bool {
    let mut st = RECORDER.lock();
    if st.recording {
        return false;
    }
    let mut start = st.now_key();
    if include_backtrack {
        start = start.saturating_sub(st.backtrack_secs as u64 * SLOTS_PER_SEC);
        let data_start = st.data_start_key();
        if data_start != u64::MAX && data_start > start {
            start = data_start;
        }
    }
    st.recording = true;
    st.hold = false;
    st.rec_start_key = start;
    eprintln!("[recording] started at key {}", st.rec_start_key);
    push_event(TsEvent::RecordingState { recording: true });
    true
}

pub fn stop_recording() -> bool {
    let mut st = RECORDER.lock();
    if !st.recording {
        return false;
    }
    st.recording = false;
    st.hold = true;
    eprintln!("[recording] stopped, buffer held for save/discard");
    push_event(TsEvent::RecordingState { recording: false });
    true
}

pub fn discard() {
    let mut st = RECORDER.lock();
    st.recording = false;
    st.hold = false;
    st.rec_start_key = 0;
    st.tracks.clear();
    st.mix.clear();
    eprintln!("[recording] buffer discarded");
}

/// JSON status for the save dialog (track list, durations).
pub fn status_json() -> String {
    let st = RECORDER.lock();
    let end = st.data_end_key();
    let start = st.data_start_key();
    let available_secs = if end > start { (end - start) / SLOTS_PER_SEC } else { 0 };
    let recording_secs = if st.recording || st.hold {
        end.saturating_sub(st.rec_start_key) / SLOTS_PER_SEC
    } else {
        0
    };
    let mut tracks: Vec<serde_json::Value> = st
        .tracks
        .values()
        .filter(|t| !t.frames.is_empty())
        .map(|t| {
            let (name, uid) = resolve_track_name(t);
            json!({
                "client_id": if t.client_id == OWN_TRACK_ID { 0 } else { t.client_id as u32 },
                "uid": uid,
                "name": name,
            })
        })
        .collect();
    tracks
        .sort_by(|a, b| a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or("")));
    json!({
        "recording": st.recording,
        "hold": st.hold,
        "backtrack_secs": st.backtrack_secs,
        "available_secs": available_secs,
        "recording_secs": recording_secs,
        "tracks": tracks,
    })
    .to_string()
}

/// Display name/uid for a track, filling roster gaps left at creation time.
fn resolve_track_name(t: &Track) -> (String, Option<String>) {
    if t.client_id == OWN_TRACK_ID {
        let own = STATE.lock().nickname.clone();
        return (if own.is_empty() { "me".to_string() } else { own }, None);
    }
    let mut nickname = t.nickname.clone();
    let mut uid = t.uid.clone();
    if nickname.is_empty() || uid.is_none() {
        let state = STATE.lock();
        if let Some(c) = state.clients.iter().find(|c| c.id as u16 == t.client_id) {
            if nickname.is_empty() {
                nickname = c.nickname.clone();
            }
            if uid.is_none() {
                uid = c.uid.clone();
            }
        }
    }
    if nickname.is_empty() {
        nickname = format!("user_{}", t.client_id);
    }
    (nickname, uid)
}

/// Kick off an async save. `window_ms == 0` saves the whole (stopped)
/// recording, otherwise the trailing window. Returns false (nothing started)
/// when a save is already running or there is no data.
pub fn request_save(window_ms: u32, mode: u8, dir: String) -> bool {
    if dir.is_empty() || SAVING.swap(true, Ordering::AcqRel) {
        return false;
    }
    if !RECORDER.lock().has_data() {
        SAVING.store(false, Ordering::Release);
        return false;
    }
    let spawn_res = std::thread::Builder::new()
        .name("recording-save".into())
        .spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                save_live(window_ms, mode, &dir, "manual")
            }));
            if let Err(p) = result {
                eprintln!("[recording] save panicked: {}", panic_msg(&p));
                push_event(TsEvent::RecordingSaveFailed {
                    reason: "manual".into(),
                    error: format!("save failed: {}", panic_msg(&p)),
                });
            }
            SAVING.store(false, Ordering::Release);
        });
    if spawn_res.is_err() {
        SAVING.store(false, Ordering::Release);
        return false;
    }
    true
}

/// Called from the output-stream teardown paths. A real disconnect
/// (STATE.connected already false) auto-saves an active recording as
/// separate files into `work_dir`; a mere playback stop keeps the buffer.
pub fn on_disconnect() {
    REC_ON.store(false, Ordering::Release);
    if STATE.lock().connected {
        return; // ts_stop_audio mid-session — keep recording alive
    }
    let st = std::mem::take(&mut *RECORDER.lock());
    if !(st.recording || st.hold) || !st.has_data() || st.work_dir.is_empty() {
        return;
    }
    let dir = st.work_dir.clone();
    eprintln!("[recording] disconnect during recording, auto-saving to {}", dir);
    let _ = std::thread::Builder::new().name("recording-save".into()).spawn(move || {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            save_detached(st, SAVE_MODE_SEPARATE, &dir, "disconnected");
        }));
    });
}

// ─── Saving ──────────────────────────────────────────────────────────

/// One track's frames cloned out of the live state for a save.
struct TrackWindow {
    client_id: u16,
    nickname: String,
    uid: Option<String>,
    frames: Vec<(u64, Vec<u8>)>,
}

/// Saves from the live state (manual request).
fn save_live(window_ms: u32, mode: u8, dir: &str, reason: &'static str) {
    let (tracks, mix, win_start, win_end) = {
        let st = RECORDER.lock();
        snapshot_window(&st, window_ms)
    };
    let ok = write_save(tracks, mix, win_start, win_end, mode, dir, reason);
    if ok && window_ms == 0 {
        // Whole recording saved: release the pinned buffer (unless the user
        // already started a new recording while the save was running).
        let mut st = RECORDER.lock();
        if !st.recording {
            st.hold = false;
            st.rec_start_key = 0;
            st.tracks.clear();
            st.mix.clear();
        }
    }
}

/// Saves from a detached state (auto-save on disconnect).
fn save_detached(mut st: RecorderState, mode: u8, dir: &str, reason: &'static str) {
    let (tracks, mix, win_start, win_end) = snapshot_window(&st, 0);
    st.tracks.clear(); // free the source buffers before the long write
    st.mix.clear();
    let _ = write_save(tracks, mix, win_start, win_end, mode, dir, reason);
}

/// Computes the save window and clones the matching frames out of `st`.
/// `window_ms == 0` = [rec_start_key, end] (whole recording), otherwise the
/// trailing window clamped to the earliest available data.
fn snapshot_window(
    st: &RecorderState,
    window_ms: u32,
) -> (Vec<TrackWindow>, Vec<(u64, Vec<u8>)>, u64, u64) {
    let end = st.data_end_key();
    if end == 0 {
        return (Vec::new(), Vec::new(), 0, 0);
    }
    let mut win_start = if window_ms == 0 {
        if !(st.recording || st.hold) {
            eprintln!("[recording] save(whole) requested but nothing pinned");
            return (Vec::new(), Vec::new(), 0, 0);
        }
        st.rec_start_key
    } else {
        let requested = end.saturating_sub((window_ms as u64 * SLOTS_PER_SEC).div_ceil(1000));
        requested.max(st.data_start_key())
    };
    if win_start >= end {
        win_start = end - 1;
    }

    let mut tracks = Vec::new();
    for t in st.tracks.values() {
        let frames: Vec<(u64, Vec<u8>)> =
            t.frames.iter().filter(|(k, _)| *k >= win_start).cloned().collect();
        if frames.is_empty() {
            continue;
        }
        let (nickname, uid) = resolve_track_name(t);
        tracks.push(TrackWindow { client_id: t.client_id, nickname, uid, frames });
    }
    tracks.sort_by(|a, b| a.nickname.cmp(&b.nickname));
    let mix: Vec<(u64, Vec<u8>)> =
        st.mix.iter().filter(|(k, _)| *k >= win_start).cloned().collect();
    (tracks, mix, win_start, end)
}

/// Decodes the window and writes the WAV file(s). Returns true on success.
fn write_save(
    tracks: Vec<TrackWindow>,
    mix: Vec<(u64, Vec<u8>)>,
    win_start: u64,
    win_end: u64,
    mode: u8,
    dir: &str,
    reason: &'static str,
) -> bool {
    let fail = |error: String| -> bool {
        eprintln!("[recording] save failed: {}", error);
        push_event(TsEvent::RecordingSaveFailed { reason: reason.into(), error });
        false
    };
    if win_end == 0 || win_start >= win_end {
        return fail("no audio data".into());
    }
    if std::fs::create_dir_all(dir).is_err() {
        return fail(format!("cannot create directory {}", dir));
    }

    let mut files: Vec<TsRecordingFile> = Vec::new();
    if mode == SAVE_MODE_MIX {
        // The live mix (stereo) with our own mic summed in. If no mix was
        // captured (output stream never ran), fall back to summing the
        // per-user tracks into a mono file.
        let path = Path::new(dir).join("mixed.wav");
        let mut tracks = tracks;
        let own = tracks
            .iter()
            .position(|t| t.client_id == OWN_TRACK_ID)
            .map(|i| tracks.remove(i).frames);
        let res = if !mix.is_empty() {
            write_mixed_wav(&path, &mix, own, win_start, win_end)
        } else if !tracks.is_empty() {
            write_summed_mono_wav(&path, &tracks, win_start, win_end)
        } else {
            Err("no audio data in window".into())
        };
        match res {
            Ok(()) => files.push(TsRecordingFile {
                path: path.to_string_lossy().into_owned(),
                client_id: 0,
                uid: None,
                name: String::new(),
                mixed: true,
            }),
            Err(e) => return fail(e),
        }
    } else {
        // One mono file per user, silence-padded from the window start so
        // tracks stay time-aligned for editing.
        let mut used: Vec<String> = Vec::new();
        for t in tracks {
            let base = sanitize_filename(&t.nickname, t.client_id);
            let name = unique_name(&base, &mut used);
            let path = Path::new(dir).join(format!("{}.wav", name));
            let mut dec = TrackDecoder::new(t.frames);
            let res =
                write_wav_streaming(&path, win_start, win_end, |key, out| dec.decode_into(key, out));
            match res {
                Ok(()) => files.push(TsRecordingFile {
                    path: path.to_string_lossy().into_owned(),
                    client_id: if t.client_id == OWN_TRACK_ID { 0 } else { t.client_id as u32 },
                    uid: t.uid,
                    name: t.nickname,
                    mixed: false,
                }),
                Err(e) => return fail(e),
            }
        }
    }

    eprintln!("[recording] saved {} file(s) to {}", files.len(), dir);
    push_event(TsEvent::RecordingSaved { reason: reason.into(), files });
    true
}

/// Mix file: decodes the stereo mix stream, sums our own mic track in and
/// clamps — the same staging the live mixer applies.
fn write_mixed_wav(
    path: &Path,
    mix: &[(u64, Vec<u8>)],
    own_frames: Option<Vec<(u64, Vec<u8>)>>,
    win_start: u64,
    win_end: u64,
) -> Result<(), String> {
    let mut mix_dec = MixDecoder::new(mix.to_vec());
    let mut mic_dec = own_frames.map(TrackDecoder::new);
    let mut mic_buf = vec![0f32; SAMPLES_PER_SLOT];
    let mut file = WavWriter::create(path, 2)?;
    let mut l = vec![0f32; SAMPLES_PER_SLOT];
    let mut r = vec![0f32; SAMPLES_PER_SLOT];
    let mut pcm = vec![0i16; SAMPLES_PER_SLOT * 2];
    for key in win_start..win_end {
        let has_mix = mix_dec.decode_into(key, &mut l, &mut r);
        let has_mic = mic_dec
            .as_mut()
            .map_or(false, |d| d.decode_into(key, &mut mic_buf));
        if has_mix || has_mic {
            for i in 0..SAMPLES_PER_SLOT {
                pcm[2 * i] = f32_to_i16(l[i] + mic_buf[i]);
                pcm[2 * i + 1] = f32_to_i16(r[i] + mic_buf[i]);
            }
        } else {
            pcm.fill(0);
        }
        file.write_frame(&pcm)?;
    }
    file.finish()
}

/// Fallback mix when no live mix was captured: plain sum of all tracks.
fn write_summed_mono_wav(
    path: &Path,
    tracks: &[TrackWindow],
    win_start: u64,
    win_end: u64,
) -> Result<(), String> {
    let mut decs: Vec<TrackDecoder> =
        tracks.iter().map(|t| TrackDecoder::new(t.frames.clone())).collect();
    let mut file = WavWriter::create(path, 1)?;
    let mut acc = vec![0f32; SAMPLES_PER_SLOT];
    let mut tmp = vec![0f32; SAMPLES_PER_SLOT];
    let mut pcm = vec![0i16; SAMPLES_PER_SLOT];
    for key in win_start..win_end {
        acc.fill(0.0);
        let mut any = false;
        for d in decs.iter_mut() {
            if d.decode_into(key, &mut tmp) {
                any = true;
                for i in 0..SAMPLES_PER_SLOT {
                    acc[i] += tmp[i];
                }
            }
        }
        if any {
            for (i, s) in acc.iter().enumerate() {
                pcm[i] = f32_to_i16(*s);
            }
        } else {
            pcm.fill(0);
        }
        file.write_frame(&pcm)?;
    }
    file.finish()
}

/// Per-track streaming writer: decodes slot-by-slot into silence-padded mono
/// PCM and appends to the file.
fn write_wav_streaming(
    path: &Path,
    win_start: u64,
    win_end: u64,
    mut decode_at: impl FnMut(u64, &mut [f32]) -> bool,
) -> Result<(), String> {
    let mut file = WavWriter::create(path, 1)?;
    let mut out = vec![0f32; SAMPLES_PER_SLOT];
    let mut pcm = vec![0i16; SAMPLES_PER_SLOT];
    for key in win_start..win_end {
        decode_at(key, &mut out);
        for (j, s) in out.iter().enumerate() {
            pcm[j] = f32_to_i16(*s);
        }
        file.write_frame(&pcm)?;
    }
    file.finish()
}

fn f32_to_i16(s: f32) -> i16 {
    (s.clamp(-1.0, 1.0) * 32767.0).clamp(-32768.0, 32767.0) as i16
}

// ─── Decoding helpers ────────────────────────────────────────────────

/// Streams one user track slot-by-slot. Gaps (slots without a packet) decode
/// as silence so the output stays aligned with the other tracks.
struct TrackDecoder {
    frames: Vec<(u64, Vec<u8>)>,
    pos: usize,
    mono: Option<OpusDecoder>,
    stereo: Option<OpusDecoder>,
    buf_mono: Vec<f32>,
    buf_stereo: Vec<f32>,
}

impl TrackDecoder {
    fn new(frames: Vec<(u64, Vec<u8>)>) -> Self {
        TrackDecoder {
            frames,
            pos: 0,
            mono: None,
            stereo: None,
            buf_mono: vec![0.0; SAMPLES_PER_SLOT],
            buf_stereo: vec![0.0; SAMPLES_PER_SLOT * 2],
        }
    }

    /// Decodes the frame at `key` into `out` (mono). Returns false for gaps.
    /// Stereo packets (music bots) are decoded stereo and downmixed.
    fn decode_into(&mut self, key: u64, out: &mut [f32]) -> bool {
        // Defensive: skip stale frames (should not happen — keys ascend).
        while self.pos < self.frames.len() && self.frames[self.pos].0 < key {
            self.pos += 1;
        }
        if self.pos >= self.frames.len() || self.frames[self.pos].0 != key {
            out.fill(0.0);
            return false;
        }
        let packet = &self.frames[self.pos].1;
        self.pos += 1;
        let stereo = !packet.is_empty() && (packet[0] >> 2) & 1 == 1;
        let res = if stereo {
            let dec = self
                .stereo
                .get_or_insert_with(|| OpusDecoder::new(48_000, 2).expect("stereo decoder"));
            self.buf_stereo.fill(0.0);
            dec.decode(packet, SAMPLES_PER_SLOT, &mut self.buf_stereo)
        } else {
            let dec = self
                .mono
                .get_or_insert_with(|| OpusDecoder::new(48_000, 1).expect("mono decoder"));
            self.buf_mono.fill(0.0);
            dec.decode(packet, SAMPLES_PER_SLOT, &mut self.buf_mono)
        };
        match res {
            Ok(_) => {
                if stereo {
                    for i in 0..SAMPLES_PER_SLOT {
                        out[i] = (self.buf_stereo[2 * i] + self.buf_stereo[2 * i + 1]) * 0.5;
                    }
                } else {
                    out.copy_from_slice(&self.buf_mono);
                }
                true
            }
            Err(e) => {
                eprintln!("[recording] track decode error at key {}: {}", key, e);
                out.fill(0.0);
                false
            }
        }
    }
}

/// Streams the stereo mix track slot-by-slot into L/R halves.
struct MixDecoder {
    frames: Vec<(u64, Vec<u8>)>,
    pos: usize,
    dec: Option<OpusDecoder>,
    buf: Vec<f32>,
}

impl MixDecoder {
    fn new(frames: Vec<(u64, Vec<u8>)>) -> Self {
        MixDecoder {
            frames,
            pos: 0,
            dec: None,
            buf: vec![0.0; SAMPLES_PER_SLOT * 2],
        }
    }

    fn decode_into(&mut self, key: u64, l: &mut [f32], r: &mut [f32]) -> bool {
        while self.pos < self.frames.len() && self.frames[self.pos].0 < key {
            self.pos += 1;
        }
        l.fill(0.0);
        r.fill(0.0);
        if self.pos >= self.frames.len() || self.frames[self.pos].0 != key {
            return false;
        }
        let packet = &self.frames[self.pos].1;
        self.pos += 1;
        let dec = self
            .dec
            .get_or_insert_with(|| OpusDecoder::new(48_000, 2).expect("stereo decoder"));
        self.buf.fill(0.0);
        match dec.decode(packet, SAMPLES_PER_SLOT, &mut self.buf) {
            Ok(_) => {
                for i in 0..SAMPLES_PER_SLOT {
                    l[i] = self.buf[2 * i];
                    r[i] = self.buf[2 * i + 1];
                }
                true
            }
            Err(e) => {
                eprintln!("[recording] mix decode error at key {}: {}", key, e);
                false
            }
        }
    }
}

// ─── WAV output ──────────────────────────────────────────────────────

/// Streaming 48 kHz PCM16 WAV writer — never materializes the whole file in
/// memory (a 4 h stereo mix is >1 GB). The size fields are patched in
/// `finish()` by seeking back.
struct WavWriter {
    file: std::io::BufWriter<std::fs::File>,
    pcm: Vec<u8>,
    channels: u16,
    data_len: u64,
}

impl WavWriter {
    fn create(path: &Path, channels: u16) -> Result<Self, String> {
        let file = std::fs::File::create(path)
            .map_err(|e| format!("create {}: {}", path.display(), e))?;
        let mut w = WavWriter {
            file: std::io::BufWriter::new(file),
            pcm: Vec::with_capacity(SAMPLES_PER_SLOT * channels as usize * 2),
            channels,
            data_len: 0,
        };
        // Placeholder header; finish() rewrites it with the real sizes.
        w.write_raw(&[0u8; 44])?;
        Ok(w)
    }

    fn write_raw(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.file
            .write_all(bytes)
            .map_err(|e| format!("write wav: {}", e))
    }

    fn write_frame(&mut self, samples: &[i16]) -> Result<(), String> {
        self.pcm.clear();
        for s in samples {
            self.pcm.extend_from_slice(&s.to_le_bytes());
        }
        self.data_len += self.pcm.len() as u64;
        self.file
            .write_all(&self.pcm)
            .map_err(|e| format!("write wav: {}", e))
    }

    fn finish(mut self) -> Result<(), String> {
        self.file.flush().map_err(|e| format!("write wav: {}", e))?;
        let byte_rate: u32 = 48_000 * self.channels as u32 * 2;
        let mut header: Vec<u8> = Vec::with_capacity(44);
        header.extend_from_slice(b"RIFF");
        header.extend_from_slice(&(36u32.wrapping_add(self.data_len as u32)).to_le_bytes());
        header.extend_from_slice(b"WAVE");
        header.extend_from_slice(b"fmt ");
        header.extend_from_slice(&16u32.to_le_bytes());
        header.extend_from_slice(&1u16.to_le_bytes()); // PCM
        header.extend_from_slice(&self.channels.to_le_bytes());
        header.extend_from_slice(&48_000u32.to_le_bytes());
        header.extend_from_slice(&byte_rate.to_le_bytes());
        header.extend_from_slice(&(self.channels * 2).to_le_bytes());
        header.extend_from_slice(&16u16.to_le_bytes());
        header.extend_from_slice(b"data");
        header.extend_from_slice(&(self.data_len as u32).to_le_bytes());
        let file = self.file.get_mut();
        file.seek(SeekFrom::Start(0))
            .and_then(|_| file.write_all(&header))
            .map_err(|e| format!("patch wav header: {}", e))?;
        Ok(())
    }
}

// ─── Names ───────────────────────────────────────────────────────────

fn sanitize_filename(name: &str, client_id: u16) -> String {
    let mut s: String = name
        .chars()
        .map(|c| {
            if matches!(
                c,
                '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0'..='\u{1f}'
            ) {
                '_'
            } else {
                c
            }
        })
        .collect();
    s = s.trim().trim_matches('.').to_string();
    if s.chars().count() > 60 {
        s = s.chars().take(60).collect();
    }
    if s.is_empty() {
        s = format!("user_{}", client_id);
    }
    s
}

fn unique_name(base: &str, used: &mut Vec<String>) -> String {
    if !used.iter().any(|u| u == base) {
        used.push(base.to_string());
        return base.to_string();
    }
    let mut n = 2;
    loop {
        let candidate = format!("{} ({})", base, n);
        if !used.iter().any(|u| *u == candidate) {
            used.push(candidate.clone());
            return candidate;
        }
        n += 1;
    }
}

fn panic_msg(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".into()
    }
}
