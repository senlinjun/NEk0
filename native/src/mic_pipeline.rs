//! The mic uplink pipeline: everything that happens to a captured frame
//! between the capture path (Android AudioRecord via Dart, or the desktop
//! cpal stream) and the network send.
//!
//! Per 20 ms frame: RNNoise speech probability (+ optional denoise) → AGC
//! → mic gain + peak limiter → VAD gate → Opus encode. The pipeline owns
//! its own mutex ([MIC_PIPELINE]) instead of living in `STATE`: the frame
//! rate is ~50× the Dart poll rate, and the poll loop holds `STATE` while
//! serializing the roster — the send path must not queue behind it.
//!
//! The pipeline also runs when NOT connected (analysis only, no encode):
//! the settings mic test and the calibration flow read [MicPipeline::status]
//! through `ts_get_vad_status`, on every platform.

use crate::agc::{apply_gain_limit, Agc, AgcConfig};
use crate::vad::{rms_to_db, Decision, NoiseFloor, RnnVad, Vad, VadConfig, VadMode, VadStatus, DB_FLOOR, FRAME};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use serde::Deserialize;
use std::collections::{HashMap, VecDeque};

/// The uplink pipeline singleton.
pub static MIC_PIPELINE: Lazy<Mutex<MicPipeline>> = Lazy::new(|| Mutex::new(MicPipeline::new()));

/// Last AGC gain per input device (empty key = system default / Android).
/// Lets the first sentence of a session start at the learned gain instead
/// of bootstrap unity; the calibration flow seeds it too.
pub static AGC_MEMORY: Lazy<Mutex<HashMap<String, f32>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// Name of the current input device (set by the desktop capture start;
/// empty on Android where the OS routes automatically).
pub static MIC_DEVICE_KEY: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

fn device_key() -> String {
    MIC_DEVICE_KEY.lock().clone()
}

/// Partial configuration update (all fields optional; absent fields keep
/// their current value). This is the JSON contract behind
/// `ts_set_vad_config` — Dart pushes this on every settings change.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PipelineConfigPatch {
    pub enabled: Option<bool>,
    pub mode: Option<VadMode>,
    pub activation_db: Option<f32>,
    pub open_prob: Option<f32>,
    pub hold_prob: Option<f32>,
    pub hysteresis_db: Option<f32>,
    pub hold_ms: Option<u32>,
    pub preroll_frames: Option<u32>,
    pub onset_frames: Option<u32>,
    pub agc_enabled: Option<bool>,
    pub agc_target_db: Option<f32>,
    pub agc_max_gain_db: Option<f32>,
    pub agc_min_gain_db: Option<f32>,
    pub agc_gate_prob: Option<f32>,
    pub denoise_enabled: Option<bool>,
    pub mic_gain: Option<f32>,
}

/// Everything needed to encode + transmit one decided frame batch.
pub struct EncodedBurst {
    /// `(sequence, opus payload)`, oldest frame first.
    pub packets: Vec<(u16, Vec<u8>)>,
}

pub struct MicPipeline {
    pub vad: Vad,
    pub agc: Agc,
    pub rnn: RnnVad,
    pub noise: NoiseFloor,
    pub denoise_enabled: bool,
    /// Linear mic gain slider (0..3), applied AFTER the AGC stage — the AGC
    /// measures the raw input, the VAD level is post-gain (TS semantics:
    /// moving the gain slider must move the level meter and the gate).
    pub mic_gain: f32,
    /// Unbounded accumulator drained in FRAME-sized chunks (fed by both the
    /// Android Dart push and the desktop cpal callback).
    pub pcm_in: Vec<f32>,
    pub encoder: Option<opus_rs::OpusEncoder>,
    pub seq: u16,
    /// Snapshot of the last processed frame, served by `ts_get_vad_status`.
    pub status: VadStatus,
}

impl Default for MicPipeline {
    fn default() -> Self {
        Self::new()
    }
}

impl MicPipeline {
    pub fn new() -> Self {
        let vad_cfg = VadConfig::default();
        let agc_cfg = AgcConfig::default();
        let status = VadStatus {
            enabled: vad_cfg.enabled,
            speaking: false,
            mode: vad_cfg.mode,
            level_db: DB_FLOOR,
            noise_db: DB_FLOOR,
            open_db: vad_cfg.activation_db,
            prob: 0.0,
            agc_gain_db: 0.0,
            clipped: false,
        };
        Self {
            vad: Vad::new(vad_cfg),
            agc: Agc::new(agc_cfg),
            rnn: RnnVad::new(),
            noise: NoiseFloor::default(),
            denoise_enabled: false,
            mic_gain: 1.0,
            pcm_in: Vec::new(),
            encoder: None,
            seq: 0,
            status,
        }
    }

    /// Applies a partial config update; every new value is clamped on the
    /// Rust side. Config changes do not touch learned state (noise floor,
    /// AGC gain) so live tuning doesn't wipe calibration.
    pub fn apply_patch(&mut self, patch: &str) -> Result<(), String> {
        let p: PipelineConfigPatch =
            serde_json::from_str(patch).map_err(|e| format!("invalid vad config: {e}"))?;
        if let Some(enabled) = p.enabled {
            self.vad.cfg.enabled = enabled;
        }
        if let Some(mode) = p.mode {
            self.vad.cfg.mode = mode;
        }
        if let Some(db) = p.activation_db {
            self.vad.cfg.activation_db = db.clamp(-60.0, -20.0);
        }
        if let Some(v) = p.open_prob {
            self.vad.cfg.open_prob = v.clamp(0.05, 0.95);
        }
        if let Some(v) = p.hold_prob {
            self.vad.cfg.hold_prob = v.clamp(0.02, 0.9);
        }
        if let Some(v) = p.hysteresis_db {
            self.vad.cfg.hysteresis_db = v.clamp(0.0, 12.0);
        }
        if let Some(v) = p.hold_ms {
            self.vad.cfg.hold_ms = v.clamp(0, 1000);
        }
        if let Some(v) = p.preroll_frames {
            self.vad.cfg.preroll_frames = v.clamp(0, 8);
        }
        if let Some(v) = p.onset_frames {
            self.vad.cfg.onset_frames = v.clamp(1, 5);
        }
        if let Some(v) = p.agc_enabled {
            self.agc.cfg.enabled = v;
        }
        if let Some(v) = p.agc_target_db {
            self.agc.cfg.target_db = v.clamp(-30.0, -6.0);
        }
        if let Some(v) = p.agc_max_gain_db {
            self.agc.cfg.max_gain_db = v.clamp(0.0, 40.0);
        }
        if let Some(v) = p.agc_min_gain_db {
            self.agc.cfg.min_gain_db = v.clamp(-24.0, 0.0);
        }
        if let Some(v) = p.agc_gate_prob {
            self.agc.cfg.gate_prob = v.clamp(0.05, 0.95);
        }
        if let Some(v) = p.denoise_enabled {
            self.denoise_enabled = v;
        }
        if let Some(v) = p.mic_gain {
            self.mic_gain = v.clamp(0.0, 3.0);
        }
        self.save_agc();
        Ok(())
    }

    /// Called when a new audio session starts (encoder created / capture
    /// restarted): DSP state is rebuilt, the AGC gain is re-seeded from the
    /// per-device memory.
    pub fn session_start(&mut self) {
        self.pcm_in.clear();
        self.vad.reset();
        self.noise = NoiseFloor::default();
        self.rnn = RnnVad::new();
        self.agc.reset();
        if let Some(db) = AGC_MEMORY.lock().get(&device_key()) {
            self.agc.set_gain_db(*db);
        }
    }

    /// Called when the session ends (encoder dropped): persist the learned
    /// AGC gain, drop buffered audio.
    pub fn session_stop(&mut self) {
        self.save_agc();
        self.pcm_in.clear();
        self.vad.reset();
    }

    pub fn save_agc(&self) {
        AGC_MEMORY
            .lock()
            .insert(device_key(), self.agc.gain_db.clamp(-24.0, 40.0));
    }

    /// Full analysis reset (calibration entry): everything learned about
    /// the current environment is dropped, including the AGC seed.
    pub fn reset_analysis(&mut self) {
        self.vad.reset();
        self.noise = NoiseFloor::default();
        self.rnn = RnnVad::new();
        self.agc = Agc::new(self.agc.cfg.clone());
    }

    pub fn push_samples(&mut self, data: &[f32]) {
        self.pcm_in.extend_from_slice(data);
        // Bound the buffer if the consumer stalls (e.g. connected but the
        // event loop died): keep at most ~400 ms.
        const MAX_QUEUED: usize = FRAME * 20;
        if self.pcm_in.len() > MAX_QUEUED {
            let excess = self.pcm_in.len() - MAX_QUEUED;
            self.pcm_in.drain(..excess);
        }
    }

    /// Internal per-frame DSP: returns the frames to transmit (empty = gate
    /// closed) and refreshes [MicPipeline::status].
    fn step(&mut self) -> VecDeque<[f32; FRAME]> {
        let frame: [f32; FRAME] = self
            .pcm_in
            .drain(..FRAME)
            .collect::<Vec<f32>>()
            .try_into()
            .expect("drained exactly FRAME samples");

        // 1. RNNoise: speech probability (+ optional denoised audio).
        let prob = self.rnn.process(&frame);
        let base = if self.denoise_enabled {
            // During warm-up rnn.out is the untouched input (documented
            // first-frame fade-in avoided).
            self.rnn.out
        } else {
            frame
        };

        // 2. AGC on the RAW input level, gated by the speech probability.
        let in_db = rms_to_db(rms_of(&frame));
        let agc_db = self.agc.process(in_db, prob.unwrap_or(0.0));

        // 3. Total send gain = AGC + slider, then whole-frame peak limiting.
        let mic_gain_db = if self.mic_gain > 0.0005 {
            rms_to_db_raw(self.mic_gain)
        } else {
            f32::NEG_INFINITY
        };
        let (gained, clipped) = apply_gain_limit(&base, agc_db + mic_gain_db);

        // 4. Gate level: post-gain RMS — same quantity the UI meter shows.
        let level_db = rms_to_db(rms_of(&gained));

        // 5. Noise floor (informational; frozen while the gate is open).
        self.noise.observe(level_db, self.vad.speaking(), 0.02);

        // 6. The decision.
        let decision = self.vad.decide(level_db, prob, &gained);

        self.status = VadStatus {
            enabled: self.vad.cfg.enabled,
            speaking: self.vad.speaking(),
            mode: self.vad.cfg.mode,
            level_db,
            noise_db: self.noise.db(),
            open_db: self.vad.cfg.activation_db,
            prob: prob.unwrap_or(0.0),
            agc_gain_db: self.agc.gain_db,
            clipped,
        };

        match decision {
            Decision::Send(frames) => frames,
            Decision::Silence => VecDeque::new(),
        }
    }

    /// Connected path: processes one frame and encodes it. `None` when no
    /// full frame is buffered, or when there is no encoder (audio session
    /// stopped) — in that case buffered PCM is dropped, as before.
    pub fn next_burst(&mut self) -> Option<EncodedBurst> {
        if self.pcm_in.len() < FRAME {
            return None;
        }
        if self.encoder.is_none() {
            self.pcm_in.clear();
            return None;
        }
        let frames = self.step();
        if frames.is_empty() {
            return Some(EncodedBurst { packets: Vec::new() });
        }
        let mut packets = Vec::with_capacity(frames.len());
        let mut enc_buf = [0u8; 4000];
        let encoder = self.encoder.as_mut().expect("checked above");
        for audio in &frames {
            match encoder.encode(audio, FRAME, &mut enc_buf) {
                Ok(len) => {
                    packets.push((self.seq, enc_buf[..len].to_vec()));
                    self.seq = self.seq.wrapping_add(1);
                }
                Err(e) => eprintln!("opus encode ERROR: {} (frame_len={})", e, audio.len()),
            }
        }
        Some(EncodedBurst { packets })
    }

    /// Not-connected path (mic test / calibration): run the DSP for the
    /// level meter, noise floor and probability, but never encode or send.
    pub fn analyze_only(&mut self, data: &[f32]) {
        self.push_samples(data);
        while self.pcm_in.len() >= FRAME {
            self.step();
        }
    }
}

fn rms_of(frame: &[f32]) -> f32 {
    (frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32).sqrt()
}

/// dB of a linear amplitude that is never zero (gain factor, not a level —
/// no floor clamping wanted here; callers pass NEG_INFINITY for mute).
fn rms_to_db_raw(v: f32) -> f32 {
    20.0 * v.max(1e-9).log10()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vad::VadConfig;

    /// Serializes tests that touch the process-global AGC memory /
    /// device-key state: apply_patch persists the current gain under the
    /// current device key, so the patch test and the roundtrip test race
    /// under cargo's default parallel execution unless serialized.
    static TEST_STATE: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn pipeline_with(cfg: VadConfig) -> MicPipeline {
        let mut p = MicPipeline::new();
        p.vad = Vad::new(cfg);
        p.encoder = Some(opus_rs::OpusEncoder::new(48000, 1, opus_rs::Application::Voip).unwrap());
        p
    }

    fn sine_frame(freq: f32, t: usize, amp: f32) -> [f32; FRAME] {
        let mut f = [0.0_f32; FRAME];
        for i in 0..FRAME {
            f[i] = amp * (2.0 * std::f32::consts::PI * freq * (t * FRAME + i) as f32 / 48_000.0)
                .sin();
        }
        f
    }

    #[test]
    fn patch_is_partial_and_clamped() {
        let _state = TEST_STATE.lock().unwrap_or_else(|e| e.into_inner());
        let mut p = MicPipeline::new();
        let before = p.vad.cfg.clone();
        p.apply_patch(r#"{"activation_db": -50.0, "preroll_frames": 99, "mode": "auto"}"#)
            .unwrap();
        assert_eq!(p.vad.cfg.activation_db, -50.0);
        assert_eq!(p.vad.cfg.preroll_frames, 8, "clamped to the documented max");
        assert_eq!(p.vad.cfg.mode, VadMode::Auto);
        // Untouched fields keep their values.
        assert_eq!(p.vad.cfg.hold_ms, before.hold_ms);
        assert_eq!(p.vad.cfg.open_prob, before.open_prob);
        assert!(p.apply_patch("not json").is_err());
        assert!(p
            .apply_patch(r#"{"no_such_field": 1}"#)
            .is_err(), "unknown fields are rejected (contract guard)");
    }

    #[test]
    fn gate_mode_gates_sine_bursts_end_to_end() {
        let mut p = pipeline_with(VadConfig {
            mode: VadMode::Gate,
            activation_db: -20.0,
            ..VadConfig::default()
        });
        // AGC off: a 0.5 sine sits at ≈ −9 dBFS, well above the −20 gate —
        // this test isolates the VAD, the AGC has its own suite.
        p.apply_patch(r#"{"agc_enabled":false}"#).unwrap();
        // Warm-up frame + 10 frames below the gate: nothing sent.
        for t in 0..12 {
            let f = sine_frame(440.0, t, 0.05); // ≈ −33 dBFS, gated
            p.push_samples(&f);
            let burst = p.next_burst().unwrap();
            assert!(burst.packets.is_empty(), "frame {t} must be gated");
        }
        // Hot frames open the gate (2-frame onset confirmation).
        for t in 12..14 {
            let f = sine_frame(440.0, t, 0.5); // ≈ −9 dBFS
            p.push_samples(&f);
            p.next_burst().unwrap();
        }
        assert!(p.status.speaking, "gate must be open after confirmation");
        let t = 14;
        p.push_samples(&sine_frame(440.0, t, 0.5));
        let burst = p.next_burst().unwrap();
        assert_eq!(burst.packets.len(), 1, "steady talking sends one frame");
        // Sequences are consecutive and never consumed while gated.
        for w in burst.packets.windows(2) {
            assert_eq!(w[1].0, w[0].0.wrapping_add(1));
        }
    }

    #[test]
    fn disabled_vad_sends_every_frame() {
        let mut p = pipeline_with(VadConfig {
            enabled: false,
            ..VadConfig::default()
        });
        for t in 0..5 {
            p.push_samples(&sine_frame(300.0, t, 0.05));
            let burst = p.next_burst().unwrap();
            assert_eq!(burst.packets.len(), 1, "frame {t} passes when disabled");
        }
        assert!(!p.status.speaking);
    }

    #[test]
    fn analyze_only_updates_status_without_encoder() {
        let mut p = MicPipeline::new(); // no encoder at all
        assert!(p.status.level_db <= DB_FLOOR);
        for t in 0..10 {
            p.analyze_only(&sine_frame(440.0, t, 0.2));
        }
        assert!(p.status.level_db > DB_FLOOR, "level meter is alive");
        assert_eq!(p.pcm_in.len(), 0, "buffer drained in full frames");
    }

    /// Regression guard for the denoise output scale: nnnoiseless writes
    /// the 16-bit-PCM domain; if the pipeline consumed it unscaled, the
    /// whole-frame limiter would engage on every frame (full-scale buzz)
    /// and the level meter would peg near 0 dBFS with the gate wide open.
    #[test]
    fn denoise_end_to_end_stays_unclipped() {
        let _state = TEST_STATE.lock().unwrap_or_else(|e| e.into_inner());
        let mut p = pipeline_with(VadConfig {
            enabled: false, // every frame is sent — the audio path is the point
            ..VadConfig::default()
        });
        p.apply_patch(r#"{"agc_enabled":false,"denoise_enabled":true}"#).unwrap();
        for t in 0..30 {
            p.push_samples(&sine_frame(440.0, t, 0.2));
            let burst = p.next_burst().unwrap();
            assert_eq!(burst.packets.len(), 1, "frame {t} must be sent");
            assert!(
                !p.status.clipped,
                "frame {t}: limiter engaged — denoise output is over-scaled"
            );
            assert!(
                p.status.level_db < -6.0,
                "frame {t}: level pegged at {} dBFS — denoise output is over-scaled",
                p.status.level_db
            );
        }
    }

    #[test]
    fn agc_memory_roundtrip() {
        let _state = TEST_STATE.lock().unwrap_or_else(|e| e.into_inner());
        *MIC_DEVICE_KEY.lock() = "test-device".into();
        let mut p = MicPipeline::new();
        p.agc.set_gain_db(9.5);
        p.save_agc();
        let mut p2 = MicPipeline::new();
        p2.session_start();
        assert!((p2.agc.gain_db - 9.5).abs() < 1e-5, "seed restored");
        p2.session_stop();
        *MIC_DEVICE_KEY.lock() = String::new();
        AGC_MEMORY.lock().clear();
    }
}
