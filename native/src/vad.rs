//! Voice activity detection for the mic uplink.
//!
//! TeamSpeak-style client semantics on a modern (Xiph-current) engine: the
//! frame speech probability comes from RNNoise (via the pure-Rust
//! `nnnoiseless` port), the volume gate is a dBFS activation level, and the
//! two combine into the three well-known modes — `auto` (ML only), `gate`
//! (volume only) and `hybrid` (both). The decision state machine adds the
//! pieces the old inline RMS gate lacked: two-threshold hysteresis, an onset
//! confirmation run, a configurable tail, and a preroll ring so the first
//! syllable survives the detector's reaction time.

use nnnoiseless::DenoiseState;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

/// 20 ms @ 48 kHz mono — the uplink frame the whole send pipeline works in.
pub const FRAME: usize = 960;
/// RNNoise operates on 10 ms frames (nnnoiseless `DenoiseState::FRAME_SIZE`).
const HALF: usize = DenoiseState::FRAME_SIZE;

/// dBFS reported when no measurement exists yet (digital silence is -inf, so
/// a finite floor keeps the UI and the JSON contract simple).
pub const DB_FLOOR: f32 = -90.0;

/// Linear RMS → dBFS. Digital silence maps to [DB_FLOOR], not -inf.
pub fn rms_to_db(rms: f32) -> f32 {
    if rms <= 1e-9 {
        return DB_FLOOR;
    }
    (20.0 * rms.log10()).max(DB_FLOOR)
}

/// dBFS → linear amplitude (test helper for the migration equivalence).
#[cfg_attr(not(test), allow(dead_code))]
pub fn db_to_rms(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VadMode {
    /// RNNoise speech probability only (TS "Automatic").
    Auto,
    /// dB volume gate only (TS "Volume gate").
    Gate,
    /// Probability AND volume must both hold (TS "Hybrid").
    Hybrid,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct VadConfig {
    pub enabled: bool,
    pub mode: VadMode,
    /// Activation level in dBFS (TS `voiceactivation_level` semantics:
    /// higher = less sensitive). The default is exactly the old linear
    /// default 0.005 RMS expressed in dB (20·log10 0.005 ≈ −46.02).
    pub activation_db: f32,
    /// Speech probability that opens the gate.
    pub open_prob: f32,
    /// Speech probability that keeps the gate open (lower → stickier).
    pub hold_prob: f32,
    /// Volume hysteresis: the gate stays open down to
    /// `activation_db - hysteresis_db`.
    pub hysteresis_db: f32,
    /// Tail: how long the gate stays open after the conditions drop.
    pub hold_ms: u32,
    /// Frames of pre-speech audio flushed when the gate opens
    /// (TS `vad_extrabuffersize` semantics, 0..8).
    pub preroll_frames: u32,
    /// Consecutive open-condition frames required before opening
    /// (single-frame click rejection). Costs decision latency only — the
    /// confirmed frames stay in the preroll ring, see [Vad::decide].
    pub onset_frames: u32,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: VadMode::Hybrid,
            activation_db: -46.0,
            open_prob: 0.5,
            hold_prob: 0.3,
            hysteresis_db: 3.0,
            hold_ms: 200,
            preroll_frames: 3,
            onset_frames: 2,
        }
    }
}

impl VadConfig {
    pub fn clamped(mut self) -> Self {
        self.activation_db = self.activation_db.clamp(-60.0, -20.0);
        self.open_prob = self.open_prob.clamp(0.05, 0.95);
        self.hold_prob = self.hold_prob.clamp(0.02, 0.9);
        self.hysteresis_db = self.hysteresis_db.clamp(0.0, 12.0);
        self.hold_ms = self.hold_ms.clamp(0, 1000);
        self.preroll_frames = self.preroll_frames.clamp(0, 8);
        self.onset_frames = self.onset_frames.clamp(1, 5);
        self
    }
}

/// One decision of the gate for the current frame.
pub enum Decision {
    /// Transmit these frames oldest-first; the LAST element is the current
    /// frame, anything before it is preroll. A single-element deque is the
    /// steady talking case; VAD-disabled also lands here (frame passes).
    Send(VecDeque<[f32; FRAME]>),
    /// Gate closed — drop the frame (no packet, no sequence number).
    Silence,
}

/// The gate state machine. Pure logic — the caller feeds per-frame
/// `(level_db, prob)` plus the already-gained audio frame and gets back what
/// to transmit.
///
/// Onset latency (the frames between speech starting and the gate opening)
/// is covered by the preroll ring, so no speech is lost as long as
/// `reaction_frames <= preroll_frames`. The ring freezes while the onset run
/// is being confirmed: confirmation frames are never evicted, they only cost
/// decision latency, and a failed confirmation trims the ring back to
/// `preroll_frames` newest frames.
pub struct Vad {
    pub cfg: VadConfig,
    speaking: bool,
    /// Consecutive open-condition frames seen while closed.
    onset_run: u32,
    /// Remaining tail frames while open.
    hold_left: u32,
    /// Recent processed frames, oldest first. While closed this holds at
    /// most `preroll_frames` (+ the frames of an unconfirmed onset run).
    ring: VecDeque<[f32; FRAME]>,
}

impl Vad {
    pub fn new(cfg: VadConfig) -> Self {
        Self {
            cfg: cfg.clamped(),
            speaking: false,
            onset_run: 0,
            hold_left: 0,
            ring: VecDeque::new(),
        }
    }

    /// Tail length in frames (ceil so 1 ms still means "at least 1 frame").
    fn hold_frames(&self) -> u32 {
        self.cfg.hold_ms.div_ceil(20)
    }

    /// `(open_condition, hold_condition)` for the current frame.
    fn conditions(&self, level_db: f32, prob: Option<f32>) -> (bool, bool) {
        let p = prob.unwrap_or(0.0);
        let vol_open = level_db >= self.cfg.activation_db;
        let vol_hold = level_db >= self.cfg.activation_db - self.cfg.hysteresis_db;
        let ml_open = p > self.cfg.open_prob;
        let ml_hold = p > self.cfg.hold_prob;
        match self.cfg.mode {
            VadMode::Auto => (ml_open, ml_hold),
            VadMode::Gate => (vol_open, vol_hold),
            VadMode::Hybrid => (ml_open && vol_open, ml_hold && vol_hold),
        }
    }

    pub fn speaking(&self) -> bool {
        self.speaking
    }

    pub fn decide(&mut self, level_db: f32, prob: Option<f32>, frame: &[f32; FRAME]) -> Decision {
        if !self.cfg.enabled {
            self.speaking = false;
            self.onset_run = 0;
            self.hold_left = 0;
            self.ring.clear();
            let mut send = VecDeque::with_capacity(1);
            send.push_back(*frame);
            return Decision::Send(send);
        }

        let (open_cond, hold_cond) = self.conditions(level_db, prob);

        if self.speaking {
            if hold_cond {
                self.hold_left = self.hold_frames();
            } else if self.hold_left > 0 {
                self.hold_left -= 1;
            } else {
                // Gate closed. Seed the preroll ring with this first quiet
                // frame so a quick re-open has context to flush.
                self.speaking = false;
                self.onset_run = 0;
                self.ring.clear();
                self.ring.push_back(*frame);
                return Decision::Silence;
            }
            let mut send = VecDeque::with_capacity(1);
            send.push_back(*frame);
            return Decision::Send(send);
        }

        if open_cond {
            self.onset_run += 1;
            // Freeze: nothing is evicted while the onset run confirms.
            self.ring.push_back(*frame);
            if self.onset_run >= self.cfg.onset_frames {
                self.speaking = true;
                self.onset_run = 0;
                self.hold_left = self.hold_frames();
                return Decision::Send(std::mem::take(&mut self.ring));
            }
            return Decision::Silence;
        }

        // Open condition failed: discard the confirmation frames beyond the
        // preroll depth and keep the newest `preroll_frames` + this one.
        self.onset_run = 0;
        let depth = self.cfg.preroll_frames as usize;
        if depth == 0 {
            self.ring.clear();
        } else {
            while self.ring.len() >= depth {
                self.ring.pop_front();
            }
            self.ring.push_back(*frame);
        }
        Decision::Silence
    }

    /// Drops all dynamic state (gate, counters, preroll). Used when capture
    /// restarts — the old inline gate leaked `vad_hold` across sessions.
    pub fn reset(&mut self) {
        self.speaking = false;
        self.onset_run = 0;
        self.hold_left = 0;
        self.ring.clear();
    }
}

/// Slowly-tracked background level for the UI meter and the calibration
/// flow. Purely informational in the ML modes — the RNNoise probability, not
/// this estimate, drives the decision.
pub struct NoiseFloor {
    db: Option<f32>,
}

impl Default for NoiseFloor {
    fn default() -> Self {
        Self { db: None }
    }
}

impl NoiseFloor {
    /// `dt_s` is the time since the previous observation (one 20 ms frame).
    pub fn observe(&mut self, level_db: f32, speech: bool, dt_s: f32) {
        if speech {
            return; // frozen during speech — must not chase the voice level
        }
        let next = match self.db {
            None => level_db,
            // Down instantly (noise got quieter), up at most 1 dB/s.
            Some(cur) if level_db < cur => level_db,
            Some(cur) => (cur + dt_s).min(level_db),
        };
        self.db = Some(next.clamp(DB_FLOOR, -20.0));
    }

    pub fn db(&self) -> f32 {
        self.db.unwrap_or(DB_FLOOR)
    }
}

/// RNNoise wrapper: one 20 ms uplink frame in (f32 −1..1), speech
/// probability out. The frame is processed as two 10 ms sub-frames in i16
/// range as nnnoiseless requires; the max of the two probabilities is
/// reported so a detection in either half counts (no extra half-frame
/// latency). The first frame after construction is passed through untouched
/// and reports `None` — nnnoiseless documents fade-in artifacts on the very
/// first output.
pub struct RnnVad {
    state: Box<DenoiseState<'static>>,
    warmed_up: bool,
    /// Denoised output of the last [RnnVad::process] call, −1..1. Only
    /// meaningful when the call returned `Some`; when denoising is not
    /// wanted the caller keeps its original frame.
    pub out: [f32; FRAME],
    buf: [f32; HALF],
}

impl Default for RnnVad {
    fn default() -> Self {
        Self::new()
    }
}

impl RnnVad {
    pub fn new() -> Self {
        Self {
            state: DenoiseState::new(),
            warmed_up: false,
            out: [0.0; FRAME],
            buf: [0.0; HALF],
        }
    }

    /// Processes one 20 ms frame. Returns the frame speech probability, or
    /// `None` for the warm-up frame after construction/reset. The denoised
    /// audio is always written to [RnnVad::out] (equal to the input during
    /// warm-up).
    pub fn process(&mut self, frame: &[f32; FRAME]) -> Option<f32> {
        if !self.warmed_up {
            self.warmed_up = true;
            self.out = *frame;
            return None;
        }
        let mut prob = 0.0_f32;
        for h in 0..2 {
            for i in 0..HALF {
                self.buf[i] = frame[h * HALF + i] * 32768.0;
            }
            let out_half = &mut self.out[h * HALF..(h + 1) * HALF];
            let p = self.state.process_frame(out_half, &self.buf);
            prob = prob.max(p);
        }
        Some(prob.clamp(0.0, 1.0))
    }
}

/// Everything the Dart side reads back about the last processed frame.
#[derive(Clone, Debug, Serialize)]
pub struct VadStatus {
    pub enabled: bool,
    pub speaking: bool,
    pub mode: VadMode,
    /// Post-gain RMS level of the latest frame in dBFS — the same quantity
    /// the gate compares against (TS `decibel_last_period` semantics).
    pub level_db: f32,
    /// Tracked background level in dBFS (informational / calibration).
    pub noise_db: f32,
    /// The activation threshold, echoed for the UI's gate marker.
    pub open_db: f32,
    /// Latest RNNoise speech probability (0 during warm-up / disabled).
    pub prob: f32,
    /// Current AGC gain in dB (0 when AGC is off).
    pub agc_gain_db: f32,
    /// The peak limiter engaged on the latest frame.
    pub clipped: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate_cfg(mode: VadMode) -> VadConfig {
        VadConfig {
            mode,
            activation_db: -40.0,
            hysteresis_db: 3.0,
            open_prob: 0.5,
            hold_prob: 0.3,
            hold_ms: 200,
            preroll_frames: 3,
            onset_frames: 2,
            ..VadConfig::default()
        }
    }

    fn frame_at(t: usize) -> [f32; FRAME] {
        let mut f = [0.0_f32; FRAME];
        f[0] = t as f32; // embed the frame index so tests can trace bursts
        f
    }

    /// Drives one frame and flattens `Decision::Send` into sent indices.
    fn step(v: &mut Vad, t: usize, level_db: f32, prob: Option<f32>) -> Vec<usize> {
        match v.decide(level_db, prob, &frame_at(t)) {
            Decision::Send(frames) => frames
                .into_iter()
                .map(|f| f[0] as usize)
                .collect::<Vec<usize>>(),
            Decision::Silence => Vec::new(),
        }
    }

    #[test]
    fn mode_semantics() {
        // auto ignores level, gate ignores prob, hybrid needs both. Two
        // identical frames: the first confirms, the second opens and
        // flushes — so "opens" means something was sent overall.
        for (mode, level, prob, expect_send) in [
            (VadMode::Auto, -70.0, Some(0.9), true),
            (VadMode::Auto, -30.0, Some(0.1), false),
            (VadMode::Gate, -30.0, Some(0.1), true),
            (VadMode::Gate, -70.0, Some(0.9), false),
            (VadMode::Hybrid, -70.0, Some(0.9), false),
            (VadMode::Hybrid, -30.0, Some(0.1), false),
            (VadMode::Hybrid, -30.0, Some(0.9), true),
        ] {
            let mut v = Vad::new(gate_cfg(mode));
            let mut sent = step(&mut v, 0, level, prob);
            sent.extend(step(&mut v, 1, level, prob));
            assert_eq!(
                !sent.is_empty(),
                expect_send,
                "mode {mode:?} level {level} prob {prob:?}"
            );
        }
    }

    #[test]
    fn hysteresis_and_tail() {
        let mut v = Vad::new(gate_cfg(VadMode::Gate));
        // Confirmation needs 2 open frames.
        assert!(step(&mut v, 0, -35.0, None).is_empty());
        let opened = step(&mut v, 1, -35.0, None);
        assert_eq!(opened, vec![0, 1]); // preroll flush includes both
        // Between activation (-40) and activation-hysteresis (-43): stays open.
        assert_eq!(step(&mut v, 2, -42.0, None), vec![2]);
        // Below hold threshold: tail counts down (200 ms = 10 frames).
        for t in 3..13 {
            assert_eq!(step(&mut v, t, -44.0, None), vec![t], "tail frame {t}");
        }
        // Exactly after the tail the gate closes; the closing frame seeds
        // the fresh preroll ring.
        assert!(step(&mut v, 13, -44.0, None).is_empty());
        // And recovery re-opens with confirmation; the flush carries the
        // ring (t=13) plus both confirmation frames.
        assert!(step(&mut v, 14, -35.0, None).is_empty());
        let reopened = step(&mut v, 15, -35.0, None);
        assert_eq!(reopened, vec![13, 14, 15]);
    }

    #[test]
    fn single_frame_pulse_does_not_open() {
        let mut v = Vad::new(gate_cfg(VadMode::Gate));
        assert!(step(&mut v, 0, -30.0, None).is_empty()); // 1 of 2 onset frames
        assert!(step(&mut v, 1, -70.0, None).is_empty()); // confirmation broken
        // The pulse frame ages out of the preroll ring as quiet frames pass.
        assert!(step(&mut v, 2, -70.0, None).is_empty());
        assert!(step(&mut v, 3, -70.0, None).is_empty());
        assert!(step(&mut v, 4, -70.0, None).is_empty()); // ring = [2,3,4]
        // A real onset opens; the flushed preroll must not contain the click.
        assert!(step(&mut v, 5, -30.0, None).is_empty());
        let opened = step(&mut v, 6, -30.0, None);
        // depth 3 ([2,3,4]) + 2 confirmation frames (5,6), contiguous.
        assert_eq!(opened, vec![2, 3, 4, 5, 6], "click frame 0 must be evicted");
    }

    #[test]
    fn preroll_flush_is_contiguous_and_bounded() {
        let mut v = Vad::new(gate_cfg(VadMode::Gate));
        let mut sent: Vec<usize> = Vec::new();
        for t in 0..10 {
            sent.extend(step(&mut v, t, -70.0, None)); // quiet: nothing opens
        }
        assert!(sent.is_empty());
        sent.extend(step(&mut v, 10, -30.0, None));
        sent.extend(step(&mut v, 11, -30.0, None)); // opens here
        // Burst = preroll depth (8,9,10... newest 3 = 7,8,9) + confirmation
        // frames (10,11), contiguous, never deeper than depth + onset.
        assert_eq!(sent, vec![7, 8, 9, 10, 11]);
    }

    /// The core zero-loss invariant: an onset whose RNNoise probability
    /// reaches the threshold within K frames loses no speech frame as long
    /// as K ≤ preroll (the ring freezes during confirmation).
    #[test]
    fn zero_loss_onset_invariant() {
        for preroll in [0u32, 2, 3, 5] {
            for k in 1..=5usize {
                let mut v = Vad::new(VadConfig {
                    mode: VadMode::Auto,
                    preroll_frames: preroll,
                    ..gate_cfg(VadMode::Auto)
                });
                let mut all_sent: Vec<usize> = Vec::new();
                let mut t = 0usize;
                let quiet = |t: usize| -> (f32, Option<f32>) { (-70.0, Some(0.05)) };
                let _ = quiet;
                // 6 quiet frames
                for _ in 0..6 {
                    all_sent.extend(step(&mut v, t, -70.0, Some(0.05)));
                    t += 1;
                }
                // K ramp frames: probability crosses 0.5 by the last one
                for i in 1..=k {
                    let p = 0.1 + 0.8 * i as f32 / k as f32;
                    all_sent.extend(step(&mut v, t, -30.0, Some(p)));
                    t += 1;
                }
                let speech_start = t; // prob 0.9 from here on
                for _ in 0..10 {
                    all_sent.extend(step(&mut v, t, -30.0, Some(0.9)));
                    t += 1;
                }
                // Every clearly-speech frame must have been transmitted…
                let lost: Vec<usize> = (speech_start..t)
                    .filter(|f| !all_sent.contains(f))
                    .collect();
                if k <= preroll as usize {
                    assert!(lost.is_empty(), "preroll {preroll} k {k}: lost {lost:?}");
                }
                // …and whatever was sent must be contiguous (no splices).
                for w in all_sent.windows(2) {
                    assert_eq!(w[1], w[0] + 1, "gap in sent stream: {:?}", all_sent);
                }
            }
        }
    }

    #[test]
    fn disabled_passes_everything_through() {
        let mut v = Vad::new(VadConfig {
            enabled: false,
            ..gate_cfg(VadMode::Hybrid)
        });
        for t in 0..5 {
            assert_eq!(step(&mut v, t, -90.0, None), vec![t]);
        }
        assert!(!v.speaking());
    }

    #[test]
    fn reset_clears_ring_and_gate() {
        let mut v = Vad::new(gate_cfg(VadMode::Gate));
        assert!(step(&mut v, 0, -30.0, None).is_empty()); // ring = [0]
        v.reset();
        // After a reset the stale ring frame (t=0) must not resurface.
        assert!(step(&mut v, 7, -30.0, None).is_empty()); // confirm 1, ring=[7]
        let opened = step(&mut v, 8, -30.0, None);
        assert_eq!(opened, vec![7, 8], "no stale preroll after reset");
    }

    #[test]
    fn noise_floor_tracks_and_freezes() {
        let mut nf = NoiseFloor::default();
        nf.observe(-50.0, false, 0.02);
        assert_eq!(nf.db(), -50.0);
        // Down is instant.
        nf.observe(-60.0, false, 0.02);
        assert_eq!(nf.db(), -60.0);
        // Up is limited to 1 dB/s; speech freezes it entirely.
        nf.observe(-40.0, true, 10.0);
        assert_eq!(nf.db(), -60.0);
        nf.observe(-40.0, false, 0.5);
        assert!((nf.db() - (-59.5)).abs() < 1e-4);
        // Clamped to the report floor.
        nf.observe(-120.0, false, 0.02);
        assert_eq!(nf.db(), DB_FLOOR);
    }

    #[test]
    fn db_conversion_matches_legacy_default() {
        assert!((rms_to_db(0.005) - (-46.02)).abs() < 0.02);
        assert_eq!(rms_to_db(0.0), DB_FLOOR);
        assert!((db_to_rms(-46.0) - 0.005).abs() < 1e-4);
        assert!((db_to_rms(0.0) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn config_clamps() {
        let c = VadConfig {
            activation_db: 10.0,
            open_prob: 5.0,
            hold_prob: 0.0,
            hysteresis_db: 99.0,
            hold_ms: 100_000,
            preroll_frames: 99,
            onset_frames: 0,
            ..VadConfig::default()
        }
        .clamped();
        assert_eq!(c.activation_db, -20.0);
        assert_eq!(c.open_prob, 0.95);
        assert_eq!(c.hold_prob, 0.02);
        assert_eq!(c.hysteresis_db, 12.0);
        assert_eq!(c.hold_ms, 1000);
        assert_eq!(c.preroll_frames, 8);
        assert_eq!(c.onset_frames, 1);
    }

    /// Measures the actual RNNoise onset latency L (frames from speech
    /// starting until prob > 0.5) on a synthetic speech-like burst in
    /// noise. Calibrates the preroll default (3) instead of guessing it.
    #[test]
    fn rnnoise_onset_latency_is_covered_by_default_preroll() {
        // Deterministic LCG so the measurement is reproducible.
        let mut seed: u32 = 0x1234_5678;
        let mut noise = move || {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 8) as f32 / 8_388_608.0 - 1.0
        };
        let latencies: Vec<usize> = (0..5)
            .map(|run| {
                let mut rnn = RnnVad::new();
                rnn.process(&[0.0; FRAME]); // warm-up
                let mut l = 0;
                let mut crossed = false;
                for t in 0..100usize {
                    let mut f = [0.0_f32; FRAME];
                    for i in 0..FRAME {
                        // Speech: 220 Hz + harmonics, amplitude 0.3, on from
                        // t=20; background noise throughout.
                        let speech = if t >= 20 {
                            0.3 * (2.0 * std::f32::consts::PI * 220.0 * (t * FRAME + i) as f32
                                / 48_000.0)
                                .sin()
                        } else {
                            0.0
                        };
                        f[i] = (speech + 0.02 * noise()).clamp(-1.0, 1.0);
                    }
                    let p = rnn.process(&f).unwrap_or(0.0);
                    if !crossed && t >= 20 && p > 0.5 {
                        l = t - 20;
                        crossed = true;
                    }
                }
                assert!(crossed, "run {run}: probability never crossed 0.5");
                l
            })
            .collect();
        let worst = *latencies.iter().max().unwrap();
        eprintln!("[vad-test] rnnoise onset latency frames: {latencies:?}");
        assert!(
            worst <= VadConfig::default().preroll_frames as usize,
            "measured onset latency {latencies:?} exceeds the default preroll"
        );
    }

    #[test]
    fn rnnoise_model_basics() {
        // Digital silence → low probability.
        let mut rnn = RnnVad::new();
        assert_eq!(rnn.process(&[0.0; FRAME]), None, "first frame is warm-up");
        assert_eq!(rnn.out, [0.0; FRAME], "warm-up audio bypasses the model");
        let p = rnn.process(&[0.0; FRAME]).unwrap();
        assert!(p <= 0.2, "silence prob {p} too high");
        // Probabilities stay in range and the model is deterministic.
        let mut f = [0.1_f32; FRAME];
        for i in 0..FRAME {
            f[i] *= (i as f32 * 0.01).sin();
        }
        let mut a = RnnVad::new();
        let mut b = RnnVad::new();
        a.process(&f);
        let pa = a.process(&f).unwrap();
        b.process(&f);
        let pb = b.process(&f).unwrap();
        assert!((0.0..=1.0).contains(&pa));
        assert_eq!(pa, pb, "same input must give the same probability");
    }
}
