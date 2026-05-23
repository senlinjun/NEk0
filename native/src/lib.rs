mod api;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64};
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

/// Per-speaker audio buffer with adaptive jitter tracking.
/// Each active speaker gets their own buffer — no mixing.
pub struct ClientAudioBuffer {
    /// Ring buffer of decoded frames (each 960 × i16)
    pub frames: VecDeque<Vec<i16>>,
    /// Adaptive target depth (frames), clamped to [MIN, MAX]
    pub target_depth: usize,
    /// Sequence number of the last decoded frame (for gap detection)
    pub last_seq: u16,
    /// When the last packet was received (for jitter calculation)
    pub last_packet: Instant,
    /// Smoothed inter-packet jitter (ms), EMA-filtered
    pub jitter_ms: f32,
}

impl ClientAudioBuffer {
    const MIN_DEPTH: usize = 2;    // 40ms
    const MAX_DEPTH: usize = 10;   // 200ms
    const NOMINAL_DEPTH: usize = 4; // 80ms
    const JITTER_ALPHA: f32 = 0.1;

    fn new() -> Self {
        Self {
            frames: VecDeque::new(),
            target_depth: Self::NOMINAL_DEPTH,
            last_seq: 0,
            last_packet: Instant::now(),
            jitter_ms: 0.0,
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
    pub audio_out: VecDeque<i16>,         // output track consumed by Dart
    pub mix_track: VecDeque<i16>,         // independent mix output (fake-mixed single speaker)
    pub client_volumes: HashMap<u16, f32>, // per-client linear gain (from dB)
    pub talking_clients: HashMap<u16, Instant>, // last audio timestamp per client
    pub client_buffers: HashMap<u16, ClientAudioBuffer>, // per-speaker jitter buffers
    pub active_speaker: Option<u16>, // currently selected speaker ID
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
            audio_out: VecDeque::new(),
            mix_track: VecDeque::new(),
            client_volumes: HashMap::new(),
            talking_clients: HashMap::new(),
            client_buffers: HashMap::new(),
            active_speaker: None,
        }
    }
}

pub static STATE: Lazy<Mutex<TsConnection>> = Lazy::new(|| Mutex::new(TsConnection::new()));
pub static PANIC_LOG: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

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
