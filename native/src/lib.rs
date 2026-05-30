mod api;

use arrayvec::ArrayVec;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Instant;
use tokio::runtime::Runtime;

pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    Runtime::new().expect("Failed to create tokio runtime")
});

// ─── Command queue ───────────────────────────────────────────────────

#[derive(Debug)]
pub enum Command {
    SendMessage { target_mode: u8, target_cid: u64, message: String },
    MoveChannel { client_id: u16, channel_id: u64 },
    SetMuted { input: bool, output: bool },
    Disconnect,
    SendAudio { data: Vec<f32> },
}

pub static COMMAND_TX: Lazy<Mutex<Option<tokio::sync::mpsc::UnboundedSender<Command>>>> =
    Lazy::new(|| Mutex::new(None));

pub static CONNECTION_GENERATION: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));
pub static EVENT_LOOP_ALIVE: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
pub static SWIPE_DISCONNECT: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
pub static CONNECTION_STASH: Lazy<Mutex<Option<tsclientlib::Connection>>> = Lazy::new(|| Mutex::new(None));
pub static IDENTITY_STASH: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// ─── Types for Dart ─────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type")]
pub enum TsEvent {
    #[serde(rename = "connected")]
    Connected { server_name: String, client_id: u32 },
    #[serde(rename = "disconnected")]
    Disconnected { reason: String },
    #[serde(rename = "text_message")]
    TextMessage { from_client: String, from_client_id: u32, target_mode: u8, message: String },
    #[serde(rename = "client_joined")]
    ClientJoined { client_id: u32, nickname: String, channel_id: u32 },
    #[serde(rename = "client_left")]
    ClientLeft { client_id: u32, nickname: String },
    #[serde(rename = "channels_updated")]
    ChannelsUpdated {},
    #[serde(rename = "diag")]
    Diag { msg: String },
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsChannel {
    pub id: u32,
    pub name: String,
    pub parent_id: u32,
    pub topic: String,
    pub has_password: bool,
    pub client_count: u32,
    pub order: u32,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsClient {
    pub id: u32,
    pub nickname: String,
    pub channel_id: u32,
    pub away: bool,
    pub input_muted: bool,
    pub output_muted: bool,
    pub is_talking: bool,
    pub volume: f32,
    pub uid: Option<String>,
}

// ─── Per-client jitter buffer ────────────────────────────────────────

pub const SLOTS: usize = 16;
pub const FRAMES_PER_SLOT: usize = 4;

/// Per-speaker audio buffer with adaptive jitter tracking.
/// Uses fixed-size ring array (no dynamic allocation during runtime).
pub struct ClientAudioBuffer {
    /// Fixed ring slots: ArrayVec of Vec<i16> per slot (max 4 frames/slot)
    pub slots: [ArrayVec<Vec<i16>, FRAMES_PER_SLOT>; SLOTS],
    /// Slot number tag for each position (0 = empty)
    pub slot_tags: [u64; SLOTS],
    /// Adaptive target depth (slots), clamped to [MIN, MAX]
    pub target_depth: usize,
    /// Number of populated slots
    pub slot_count: usize,
    /// Sequence number of the last decoded frame
    pub last_seq: u16,
    /// When the last packet was received (for jitter calculation)
    pub last_packet: Instant,
    /// Smoothed inter-packet jitter (ms), EMA-filtered
    pub jitter_ms: f32,
    /// Baseline: maps first received seq to a global wall-clock slot
    pub base_seq: u16,
    pub base_slot: u64,
}

/// Frame object pool — reuses Vec<i16> buffers to avoid allocation.
pub static FRAME_POOL: Lazy<Mutex<Vec<Vec<i16>>>> = Lazy::new(|| Mutex::new(Vec::new()));

pub fn alloc_frame() -> Vec<i16> {
    FRAME_POOL.lock().pop().unwrap_or_else(|| vec![0i16; 960])
}

pub fn free_frame(mut f: Vec<i16>) {
    f.clear();
    f.resize(960, 0);
    FRAME_POOL.lock().push(f);
}

impl ClientAudioBuffer {
    pub const MIN_DEPTH: usize = 2;
    pub const MAX_DEPTH: usize = 10;
    pub const NOMINAL_DEPTH: usize = 4;
    pub const JITTER_ALPHA: f32 = 0.1;

    pub fn new() -> Self {
        const EMPTY_SLOT: ArrayVec<Vec<i16>, FRAMES_PER_SLOT> = ArrayVec::new_const();
        Self {
            slots: [EMPTY_SLOT; SLOTS],
            slot_tags: [0u64; SLOTS],
            target_depth: Self::NOMINAL_DEPTH,
            slot_count: 0,
            last_seq: 0,
            last_packet: Instant::now(),
            jitter_ms: 0.0,
            base_seq: 0,
            base_slot: 0,
        }
    }

    /// Map per-speaker u16 sequence to global u64 slot, handling wrap.
    pub fn slot_for_seq(&self, seq: u16) -> u64 {
        if seq < self.base_seq && self.base_seq.wrapping_sub(seq) > 32768 {
            self.base_slot.wrapping_add(
                (seq as u64).wrapping_add(65536).wrapping_sub(self.base_seq as u64)
            )
        } else {
            self.base_slot.wrapping_add(seq.wrapping_sub(self.base_seq) as u64)
        }
    }

    /// Push a frame into the slot ring buffer. Returns old frames if slot was evicted.
    pub fn push_frame(&mut self, slot: u64, frame: Vec<i16>) {
        let pos = (slot as usize) % SLOTS;
        if self.slot_tags[pos] != slot {
            // Evict old slot — return frames to pool
            while let Some(old) = self.slots[pos].pop() {
                free_frame(old);
            }
            self.slot_tags[pos] = slot;
        } else {
            self.slot_count -= 1; // will re-add below
        }
        self.slots[pos].try_push(frame).ok();
        self.slot_count += 1;
    }

    /// Find the oldest (minimum) non-zero slot tag.
    pub fn min_slot(&self) -> Option<u64> {
        self.slot_tags.iter().filter(|&&t| t != 0).min().copied()
    }

    /// Pop one frame from a specific slot. Returns None if slot empty.
    pub fn pop_from(&mut self, slot: u64) -> Option<Vec<i16>> {
        let pos = (slot as usize) % SLOTS;
        if self.slot_tags[pos] == slot {
            let frame = self.slots[pos].pop();
            if self.slots[pos].is_empty() {
                self.slot_tags[pos] = 0;
            }
            if frame.is_some() {
                self.slot_count -= 1;
            }
            frame
        } else {
            None
        }
    }

    /// Trim to target_depth — evict oldest slots.
    pub fn trim(&mut self) {
        while self.slot_count > self.target_depth {
            let min = self.min_slot();
            if let Some(slot) = min {
                while let Some(f) = self.pop_from(slot) {
                    free_frame(f);
                }
            } else {
                break;
            }
        }
    }
}

// ─── Global State ───────────────────────────────────────────────────

pub struct TsConnection {
    pub connected: bool,
    pub connecting: bool,
    pub server_name: String,
    pub nickname: String,
    pub own_client_id: u32,
    pub channels: Vec<TsChannel>,
    pub clients: Vec<TsClient>,
    pub pending_events: VecDeque<TsEvent>,
    // Audio send state
    pub pcm_in: Vec<f32>,
    pub audio_encoder: Option<opus_rs::OpusEncoder>,
    pub audio_seq: u16,
    pub vad_threshold: f32,
    pub vad_enabled: bool,
    pub vad_hold: u32,
    pub voice_active: bool,
    pub disconnect_requested: bool,
    pub mic_gain: f32,
    // Audio receive state
    pub audio_decoders: HashMap<u16, opus_rs::OpusDecoder>,
    pub audio_decoders_stereo: HashMap<u16, opus_rs::OpusDecoder>,
    pub client_volumes: HashMap<u16, f32>, // per-client linear gain (from dB)
    pub talking_clients: HashMap<u16, Instant>, // last audio timestamp per client
    pub client_buffers: HashMap<u16, ClientAudioBuffer>, // per-speaker jitter buffers
}

impl TsConnection {
    fn new() -> Self {
        Self {
            connected: false,
            connecting: false,
            server_name: String::new(),
            nickname: String::new(),
            own_client_id: 0,
            channels: Vec::new(),
            clients: Vec::new(),
            pending_events: VecDeque::new(),
            pcm_in: Vec::new(),
            audio_encoder: None,
            audio_seq: 0,
            vad_threshold: 0.0,
            vad_enabled: false,
            vad_hold: 0,
            voice_active: false,
            disconnect_requested: false,
            mic_gain: 1.0,
            audio_decoders: HashMap::new(),
            audio_decoders_stereo: HashMap::new(),
            client_volumes: HashMap::new(),
            talking_clients: HashMap::new(),
            client_buffers: HashMap::new(),
        }
    }
}

pub static STATE: Lazy<Mutex<TsConnection>> = Lazy::new(|| Mutex::new(TsConnection::new()));
pub static PANIC_LOG: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

/// Lock-free SPSC ring buffer for audio output (Fix 1).
/// Producer: event loop mixing step. Consumer: Dart FFI ts_get_audio.
/// Separate mutex for audio output — avoids contention with STATE lock (Fix 1).
/// Mixing step pushes, Dart FFI ts_get_audio pops. Lock held microseconds only.
pub static AUDIO_OUT: Lazy<Mutex<VecDeque<i16>>> = Lazy::new(|| Mutex::new(VecDeque::new()));

/// Atomic flag: Dart side requests immediate mixing (Fix 2).
pub static MIX_REQUESTED: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let location = info.location()
            .map(|l| {
                let file = l.file();
                let short = file.rsplit(&['/', '\\']).next().unwrap_or(file);
                format!("{}:{}:{}", short, l.line(), l.column())
            })
            .unwrap_or_else(|| "unknown location".into());
        let payload = if let Some(s) = info.payload().downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".into()
        };
        let msg = format!("PANIC {}: {}", location, payload);
        eprintln!("{}", msg);
        *PANIC_LOG.lock() = msg;
    }));
}

pub fn flush_panic_log() {
    let mut log = PANIC_LOG.lock();
    if !log.is_empty() {
        STATE.lock().pending_events.push_back(TsEvent::Diag {
            msg: log.clone(),
        });
        log.clear();
    }
}
