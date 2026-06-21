mod api;

use crossbeam::queue::SegQueue;
use crossbeam::atomic::AtomicCell;
use dashmap::DashMap;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
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

// ─── Per-client lock-free jitter buffer ──────────────────────────────

/// Lock-free per-client jitter buffer with 32 slots (640ms window at 20ms/frame).
/// Writer: decoding thread (one per client). Reader: cpal audio callback.
pub struct ClientJitterBuffer {
    /// Circular array of frame slots. AtomicCell swap provides lock-free read/write.
    pub slots: [AtomicCell<Option<Vec<i16>>>; 32],
    /// Sequence number of the most recently written frame (unwrapped to u32 space).
    pub write_seq: AtomicU32,
    /// First sequence number seen, unwrapped to u32 space. Set once with compare_exchange.
    pub base_seq: AtomicU32,
    /// Global play_slot at which base_seq should be played (base_seq → base_slot mapping).
    pub base_slot: AtomicU64,
    /// Monotonic timestamp of last received packet. None = never received. Used for cleanup.
    pub last_packet: AtomicCell<Option<Instant>>,
    /// Lock-free frame pool — callback pushes used frames, decoder pops them. No contention.
    pub frame_pool: SegQueue<Vec<i16>>,
    /// Linear gain as f32::to_bits, applied as mixing weight in the audio callback.
    pub volume: AtomicU32,
}

impl ClientJitterBuffer {
    pub fn new() -> Self {
        const NONE: AtomicCell<Option<Vec<i16>>> =
            AtomicCell::new(None);
        Self {
            slots: [NONE; 32],
            write_seq: AtomicU32::new(0),
            base_seq: AtomicU32::new(0),
            base_slot: AtomicU64::new(0),
            last_packet: AtomicCell::new(None),
            frame_pool: SegQueue::new(),
            volume: AtomicU32::new(f32::to_bits(1.0)),
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
    pub talking_clients: HashMap<u16, Instant>, // last audio timestamp per client (monotonic Instant)
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
            talking_clients: HashMap::new(),
        }
    }
}

pub static STATE: Lazy<Mutex<TsConnection>> = Lazy::new(|| Mutex::new(TsConnection::new()));
pub static PANIC_LOG: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

/// cpal output stream (Send-safe wrapper). Drop to stop audio playback.
pub struct SendStream(pub Option<cpal::Stream>);
unsafe impl Send for SendStream {}
pub static AUDIO_STREAM: std::sync::Mutex<SendStream> = std::sync::Mutex::new(SendStream(None));

// ─── Lock-free audio globals ─────────────────────────────────────────

pub static CLIENT_BUFFERS: Lazy<DashMap<u16, ClientJitterBuffer>> = Lazy::new(DashMap::new);
pub static AUDIO_DECODERS: Lazy<DashMap<u16, opus_rs::OpusDecoder>> = Lazy::new(DashMap::new);
pub static AUDIO_DECODERS_STEREO: Lazy<DashMap<u16, opus_rs::OpusDecoder>> = Lazy::new(DashMap::new);
pub const FRAME_SIZE: u64 = 960;
/// Total samples written to the hardware output buffer since stream start.
/// Logical frame number = PLAYED_SAMPLES / FRAME_SIZE.
pub static PLAYED_SAMPLES: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));
/// Client ID snapshot for the audio callback — avoids iterating DashMap in the callback.
/// Refreshed by the maintenance task every 500ms. Lock-free via ArcSwap.
pub static ACTIVE_CLIENT_IDS: Lazy<arc_swap::ArcSwap<Vec<u16>>> =
    Lazy::new(|| arc_swap::ArcSwap::from(std::sync::Arc::new(Vec::new())));

// ─── Diagnostic callback stats (all atomics, safe to write from audio thread) ──

pub struct CallbackStats {
    /// Total callback invocations since last stats print.
    pub callbacks: AtomicU64,
    /// Sum of data.len() across all callbacks since last print.
    pub samples_total: AtomicU64,
    /// Total mix frames generated (slot changes) since last print.
    pub mix_frames: AtomicU64,
    /// DRIFT CHECK: expected played value at next callback entry. Set at end of
    /// each callback to (PLAYED_SAMPLES after fetch_add). The next callback compares
    /// its played_before against this value; mismatch = audio clock drift.
    pub expected_next_played: AtomicU64,
    /// Total PLAYED_SAMPLES consistency violations.
    pub played_mismatches: AtomicU64,
    /// Microseconds since the previous callback entry (0 if this is first).
    pub last_interval_us: AtomicU64,
    /// Instant::now() at the start of the last callback, in nanoseconds from boot.
    /// Used to compute the interval to the next callback.
    pub last_cb_entry_ns: AtomicU64,
}

pub static CB_STATS: Lazy<CallbackStats> = Lazy::new(|| CallbackStats {
    callbacks: AtomicU64::new(0),
    samples_total: AtomicU64::new(0),
    mix_frames: AtomicU64::new(0),
    expected_next_played: AtomicU64::new(0),
    played_mismatches: AtomicU64::new(0),
    last_interval_us: AtomicU64::new(0),
    last_cb_entry_ns: AtomicU64::new(0),
});

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
