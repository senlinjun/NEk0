//! Automatic gain control for the mic uplink.
//!
//! A slow, speech-gated controller: while the RNNoise probability says
//! "voice" (plus a 200 ms tail so trailing syllables still count), the gain
//! walks toward `[target] − input_level` at an asymmetric rate limit
//! (rising slowly to avoid pumping, falling fast to avoid clipping).
//! During silence the gain is frozen — the one thing an AGC must never do
//! is amplify the noise floor up to the speech target.

/// Gain bounds and behavior, mirroring the TS client's `agc` /
/// `agc_level` / `agc_max_gain` knobs. The default target (−18 dBFS) is
/// deliberately more conservative than the TS client's 16000/32768 ≈
/// −6 dBFS, which was tuned for its int16 chain.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct AgcConfig {
    pub enabled: bool,
    /// Where a normal voice should sit after gain, in dBFS.
    pub target_db: f32,
    /// Upper gain bound (TS `agc_max_gain` semantics).
    pub max_gain_db: f32,
    /// Lower gain bound; also where the controller starts.
    pub min_gain_db: f32,
    /// Speech probability above which a frame counts as voice for the
    /// controller (the RNNoise paper's suggested secondary use of the VAD
    /// output).
    pub gate_prob: f32,
}

impl Default for AgcConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            target_db: -18.0,
            max_gain_db: 30.0,
            min_gain_db: -12.0,
            gate_prob: 0.3,
        }
    }
}

impl AgcConfig {
    pub fn clamped(mut self) -> Self {
        self.target_db = self.target_db.clamp(-30.0, -6.0);
        self.max_gain_db = self.max_gain_db.clamp(0.0, 40.0);
        self.min_gain_db = self.min_gain_db.clamp(-24.0, 0.0);
        self.gate_prob = self.gate_prob.clamp(0.05, 0.95);
        self
    }
}

/// Frames of non-voice after the last voiced frame that still count as
/// speech for the controller (200 ms — trailing syllables are usually
/// quieter and would otherwise be ignored).
const TAIL_FRAMES: u32 = 10;
/// Rise limit: 0.25 dB per 20 ms frame = 12.5 dB/s (no audible pumping).
const MAX_UP_DB_PER_FRAME: f32 = 0.25;
/// Fall limit: 1 dB per frame = 50 dB/s (fast enough to prevent clipping
/// when the speaker gets close to the mic).
const MAX_DOWN_DB_PER_FRAME: f32 = 1.0;

pub struct Agc {
    pub cfg: AgcConfig,
    /// Current gain. NOT reset on capture restart: the pipeline keeps it
    /// per input device so the first sentence of a session is not quiet.
    pub gain_db: f32,
    tail_left: u32,
}

impl Agc {
    pub fn new(cfg: AgcConfig) -> Self {
        Self {
            cfg: cfg.clamped(),
            gain_db: 0.0,
            tail_left: 0,
        }
    }

    /// Applies this frame's gain (returned BEFORE the update, so a frame is
    /// never amplified by a gain computed from itself), then feeds the
    /// measurement into the controller. `in_db` is the RAW input level; the
    /// controller closes the loop itself by adding the gain it just applied
    /// (the pipeline never feeds the AGC its own output).
    pub fn process(&mut self, in_db: f32, prob: f32) -> f32 {
        let gain_for_frame = self.gain_db;
        if !self.cfg.enabled {
            return gain_for_frame;
        }
        let voiced = prob > self.cfg.gate_prob;
        if voiced {
            self.tail_left = TAIL_FRAMES;
        } else {
            self.tail_left = self.tail_left.saturating_sub(1);
        }
        if self.tail_left > 0 {
            // Closed loop: the level the frame will actually have.
            let achieved_db = in_db + gain_for_frame;
            let error = self.cfg.target_db - achieved_db;
            // Within the tail (voice has dropped out but we may be mid
            // utterance) the gain may still fall fast but must never rise —
            // otherwise word gaps would pull the noise floor up to the
            // speech target.
            let step = if voiced {
                error.clamp(-MAX_DOWN_DB_PER_FRAME, MAX_UP_DB_PER_FRAME)
            } else {
                error.clamp(-MAX_DOWN_DB_PER_FRAME, 0.0)
            };
            self.gain_db = (self.gain_db + step).clamp(self.cfg.min_gain_db, self.cfg.max_gain_db);
        }
        gain_for_frame
    }

    /// Drops the speech-tail latch. The gain itself is deliberately kept
    /// (device memory) — only calibration and explicit resets overwrite it.
    pub fn reset(&mut self) {
        self.tail_left = 0;
    }

    /// Calibration / device-memory seeding.
    pub fn set_gain_db(&mut self, db: f32) {
        let c = self.cfg.clone().clamped();
        self.gain_db = db.clamp(c.min_gain_db, c.max_gain_db);
    }
}

/// Applies `gain_db` to a 20 ms frame with whole-frame peak limiting: if the
/// peak would exceed 0.99, the entire frame is scaled down to peak at 0.99
/// (a constant factor, so the waveform shape — and thus the sound — is
/// untouched, unlike per-sample hard clipping). Returns the frame and
/// whether the limiter engaged.
pub fn apply_gain_limit(frame: &[f32], gain_db: f32) -> ([f32; 960], bool) {
    let mut out = [0.0_f32; 960];
    if !gain_db.is_finite() || gain_db < -60.0 {
        return (out, false); // muted / −inf
    }
    let g = 10.0_f32.powf(gain_db / 20.0);
    let peak = frame.iter().fold(0.0_f32, |m, s| m.max(s.abs()));
    let limiter_scale = if peak > 0.0 && peak * g > 0.99 {
        0.99 / (peak * g)
    } else {
        1.0
    };
    if limiter_scale < 1.0 || g != 1.0 {
        for (o, s) in out.iter_mut().zip(frame.iter()) {
            *o = s * g * limiter_scale;
        }
    } else {
        out.copy_from_slice(frame);
    }
    (out, limiter_scale < 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(n: usize, in_db: f32, prob: f32) -> (Agc, Vec<f32>) {
        let mut agc = Agc::new(AgcConfig::default());
        let mut gains = Vec::with_capacity(n);
        for _ in 0..n {
            gains.push(agc.process(in_db, prob));
        }
        (agc, gains)
    }

    #[test]
    fn quiet_voice_rises_at_rate_limit_and_converges() {
        let (agc, gains) = frames(120, -40.0, 0.9); // needs +22 dB
        // First frame still at bootstrap gain 0, then +0.25 per frame.
        assert_eq!(gains[0], 0.0);
        assert!((gains[1] - 0.25).abs() < 1e-5);
        assert!((gains[2] - 0.5).abs() < 1e-5);
        // Converges near the required gain and never past it.
        assert!((agc.gain_db - 22.0).abs() < 0.3, "gain {}", agc.gain_db);
        assert!(agc.gain_db <= 22.0 + 1e-4);
    }

    #[test]
    fn loud_voice_falls_fast_toward_the_bound() {
        let (agc, gains) = frames(30, -5.0, 0.9); // needs −13 dB, bound −12
        // Falls 1 dB per frame, clamped at min_gain_db.
        assert!((gains[1] - (-1.0)).abs() < 1e-5);
        assert!((agc.gain_db - (-12.0)).abs() < 1e-5);
    }

    #[test]
    fn silence_freezes_the_gain() {
        let (mut agc, _) = frames(20, -40.0, 0.9);
        let g = agc.gain_db;
        // Voice stops: the 200 ms tail keeps updating, then it must freeze.
        for _ in 0..25 {
            agc.process(-60.0, 0.0);
        }
        let frozen = agc.gain_db;
        for _ in 0..50 {
            agc.process(-60.0, 0.0);
        }
        assert_eq!(agc.gain_db, frozen, "gain must not chase the noise floor");
        assert!(frozen >= g, "tail updates must not lower an earned gain");
    }

    #[test]
    fn disabled_returns_stored_gain_and_never_updates() {
        let mut agc = Agc::new(AgcConfig::default());
        agc.set_gain_db(6.0);
        agc.cfg.enabled = false;
        for _ in 0..20 {
            assert_eq!(agc.process(-50.0, 0.9), 6.0);
        }
        assert_eq!(agc.gain_db, 6.0);
    }

    #[test]
    fn bootstrap_and_seed() {
        let mut agc = Agc::new(AgcConfig::default());
        assert_eq!(agc.gain_db, 0.0, "bootstrap at unity");
        agc.set_gain_db(50.0); // calibration seed is clamped
        assert_eq!(agc.gain_db, 30.0);
        agc.set_gain_db(-99.0);
        assert_eq!(agc.gain_db, -12.0);
    }

    #[test]
    fn gain_limits_are_enforced() {
        let (agc, _) = frames(400, -70.0, 0.9); // wants +52 dB
        assert_eq!(agc.gain_db, 30.0, "must clamp at max_gain_db");
        let (agc, _) = frames(400, 0.0, 0.9); // wants −18 dB
        assert_eq!(agc.gain_db, -12.0, "must clamp at min_gain_db");
    }

    #[test]
    fn apply_gain_limit_shapes_and_flags() {
        // Unity gain passes the frame through untouched.
        let f = [0.5_f32; 960];
        let (out, clipped) = apply_gain_limit(&f, 0.0);
        assert!(!clipped);
        assert_eq!(out[123], 0.5);

        // +6 dB on a quiet frame (0.4 → 0.8 peak): no limiter.
        let quiet = [0.4_f32; 960];
        let (out, clipped) = apply_gain_limit(&quiet, 6.0);
        assert!(!clipped);
        assert!((out[0] - 0.4 * 10.0_f32.powf(0.3)).abs() < 1e-6);

        // Overload: whole frame scaled so the peak lands at 0.99, shape kept.
        let hot = [0.9_f32; 960];
        let (out, clipped) = apply_gain_limit(&hot, 6.0); // would peak at 1.8
        assert!(clipped);
        assert!((out[0] - 0.99).abs() < 1e-5);
        assert!((out[700] - 0.99).abs() < 1e-5); // constant factor, not clip

        // Mute (−inf) produces digital silence.
        let (out, clipped) = apply_gain_limit(&f, f32::NEG_INFINITY);
        assert!(!clipped);
        assert!(out.iter().all(|s| *s == 0.0));
    }

    #[test]
    fn config_clamps() {
        let c = AgcConfig {
            target_db: 0.0,
            max_gain_db: 99.0,
            min_gain_db: -99.0,
            gate_prob: 5.0,
            ..AgcConfig::default()
        }
        .clamped();
        assert_eq!(c.target_db, -6.0);
        assert_eq!(c.max_gain_db, 40.0);
        assert_eq!(c.min_gain_db, -24.0);
        assert_eq!(c.gate_prob, 0.95);
    }
}
