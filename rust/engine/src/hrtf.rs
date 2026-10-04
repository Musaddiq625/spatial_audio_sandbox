//! Synthetic HRTF set: spherical-head model + pinna comb cues.
//!
//! Model (Woodworth–Schlosberg ITD, first-order head shadow, sparse pinna
//! echoes, rear dullness) is cheap to synthesize, so we precompute a
//! quantized az/el grid at startup and hand out references — wait-free on
//! the audio path. Not a substitute for a measured SOFA set, but enough to
//! prove externalization in spike S2.

use std::f32::consts::PI;

pub const HRIR_LEN: usize = 128;

/// One binaural impulse-response pair.
#[derive(Clone)]
pub struct Hrir {
    pub left: [f32; HRIR_LEN],
    pub right: [f32; HRIR_LEN],
}

/// Direction quantization. Fine enough that the convolver's crossfade hides
/// the steps; coarse enough that the whole grid fits in ~1 MB.
const AZ_STEP: f32 = 5.0; // deg, covers [-180, 180]
const EL_STEP: f32 = 15.0; // deg, covers [-90, 90]
const AZ_BINS: usize = (360.0 / AZ_STEP) as usize + 1; // 73
const EL_BINS: usize = (180.0 / EL_STEP) as usize + 1; // 13

const HEAD_RADIUS_M: f32 = 0.0875;
const SPEED_OF_SOUND: f32 = 343.0;
/// Constant tap offset so fractional delays never write negative indices.
const BASE_TAP: usize = 8;

pub struct SyntheticHrirSet {
    grid: Vec<Hrir>, // az_bin * EL_BINS + el_bin
    sr: f32,
}

impl SyntheticHrirSet {
    pub fn new(sr: f32) -> Self {
        let mut grid = Vec::with_capacity(AZ_BINS * EL_BINS);
        for az_i in 0..AZ_BINS {
            let az_deg = -180.0 + az_i as f32 * AZ_STEP;
            for el_i in 0..EL_BINS {
                let el_deg = -90.0 + el_i as f32 * EL_STEP;
                grid.push(Self::synthesize(sr, az_deg, el_deg));
            }
        }
        SyntheticHrirSet { grid, sr }
    }

    /// Lookup. az in [-PI, PI] (+ = left), el in [-PI/2, PI/2] (+ = up).
    #[inline]
    pub fn hrir(&self, az: f32, el: f32) -> &Hrir {
        let az_deg = (az.to_degrees() + 180.0).rem_euclid(360.0) - 180.0;
        let az_i = ((az_deg + 180.0) / AZ_STEP).round() as usize;
        let el_i = ((el.to_degrees() + 90.0) / EL_STEP)
            .round()
            .clamp(0.0, (EL_BINS - 1) as f32) as usize;
        &self.grid[az_i.min(AZ_BINS - 1) * EL_BINS + el_i]
    }

    pub fn sample_rate(&self) -> f32 {
        self.sr
    }

    /// Woodworth ITD in seconds for |az_deg| measured from the front.
    fn itd_secs(abs_az_deg: f32) -> f32 {
        let th = abs_az_deg.min(180.0).to_radians();
        let a = HEAD_RADIUS_M / SPEED_OF_SOUND;
        if th <= PI / 2.0 {
            a * (th.sin() + th)
        } else {
            a * (PI - th + th.sin())
        }
    }

    /// One-pole lowpass `a` coefficient for cutoff fc at sample rate sr.
    fn lp_a(fc: f32, sr: f32) -> f32 {
        (-2.0 * PI * fc / sr).exp()
    }

    /// Two-band head-shadow shelf: frequencies below `fc` pass at ~0 dB
    /// (sound diffracts around the head), above `fc` attenuated to
    /// `hf_gain`. A one-pole split keeps the transition gentle.
    fn shelf_filter(ir: &mut [f32], fc: f32, hf_gain: f32, sr: f32) {
        let a = Self::lp_a(fc, sr);
        let mut y1 = 0.0f32;
        for x in ir.iter_mut() {
            let lo = (1.0 - a) * *x + a * y1;
            y1 = lo;
            *x = lo + (*x - lo) * hf_gain;
        }
    }

    /// Apply one-pole LP in place: y[n] = (1-a)x[n] + a*y[n-1].
    fn lp_filter(ir: &mut [f32], fc: f32, sr: f32) {
        let a = Self::lp_a(fc, sr);
        let mut y1 = 0.0f32;
        for x in ir.iter_mut() {
            y1 = (1.0 - a) * *x + a * y1;
            *x = y1;
        }
    }

    /// Pinna-style sparse echo taps, shifted by elevation (crude height cue).
    /// Returns (delay_in_samples, coeff) pairs.
    fn pinna_taps(el_deg: f32) -> [(f32, f32); 3] {
        let e = (el_deg / 90.0).clamp(-1.0, 1.0);
        [
            (0.0, 1.0),
            (4.0 + 3.0 * e, 0.13),
            (9.0 + 5.0 * e, -0.10),
        ]
    }

    /// Accumulate `src` taps into `ir` through a windowed-sinc fractional
    /// delay of `delay` samples, scaled by `gain`.
    fn place_delayed(ir: &mut [f32], src: &[(f32, f32); 3], delay: f32, gain: f32) {
        const K: i32 = 4; // sinc half-width
        let d_int = delay.floor() as i32;
        let d_frac = delay - d_int as f32;
        for &(t, c) in src.iter() {
            let center = BASE_TAP as f32 + t;
            for k in -K..=K {
                let idx = center as i32 + d_int + k;
                if idx < 0 || idx >= ir.len() as i32 {
                    continue;
                }
                let tt = k as f32 - d_frac;
                let w = {
                    let x = tt / K as f32;
                    if x.abs() >= 1.0 { 0.0 } else { 0.5 + 0.5 * (PI * x).cos() }
                };
                let sinc = if tt.abs() < 1e-6 { 1.0 } else { (PI * tt).sin() / (PI * tt) };
                ir[idx as usize] += c * gain * sinc * w;
            }
        }
    }

    fn synthesize(sr: f32, az_deg: f32, el_deg: f32) -> Hrir {
        let abs_az = az_deg.abs();
        // Lateral factor on a sin curve — the old linear |az|/90 ramp
        // gave only ~2.5 dB at 45 deg; a real head is ~7-8 dB there.
        // sin grows faster at mid angles: ~3.5 dB@20, ~8 dB@45, ~12 dB@90.
        let s = (abs_az.min(90.0).to_radians()).sin();
        // Rear factor: 0 in front hemisphere, 1 directly behind.
        let rear = ((abs_az - 90.0) / 90.0).clamp(0.0, 1.0);

        let itd_samp = Self::itd_secs(abs_az) * sr;
        // Broadband level difference: ~12 dB max, weighted by the sin
        // curve, plus a small rear penalty. Near ear gets a hair of
        // lift — physical heads gain ~1 dB ipsilaterally at lateral.
        let g_far = 10f32.powf(-(11.0 * s + 1.5 * rear) / 20.0);
        let g_near = 10f32.powf((1.2 * s) / 20.0);
        // Frequency-dependent shadow (Brown-Duda style): LF diffracts
        // around the head nearly unimpeded; HF is shelved off. The
        // shelf deepens with angle — at az=0 it must be transparent or
        // front symmetry breaks.
        let fc_sh = 1_600.0 + 2_400.0 * (1.0 - s); // 1.6kHz lateral .. 4kHz frontal
        let hf_g = 10f32.powf(-14.0 * s / 20.0); // 0 dB front .. -14 dB lateral
        // Rear sources sound duller on BOTH ears (pinna front/back cue).
        let fc_dull = 20_000.0 - 13_000.0 * rear;

        let taps = Self::pinna_taps(el_deg);

        let mut near = [0f32; HRIR_LEN];
        Self::place_delayed(&mut near, &taps, 0.0, g_near);
        Self::lp_filter(&mut near, fc_dull, sr);

        let mut far = [0f32; HRIR_LEN];
        Self::place_delayed(&mut far, &taps, itd_samp, g_far);
        Self::shelf_filter(&mut far, fc_sh.min(fc_dull), hf_g, sr);
        Self::lp_filter(&mut far, fc_dull, sr);

        // az > 0 => source on the left => left ear is near.
        let (left, right) = if az_deg >= 0.0 { (near, far) } else { (far, near) };
        Hrir { left, right }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peak_index(ir: &[f32; HRIR_LEN]) -> usize {
        ir.iter()
            .enumerate()
            .max_by(|a, b| a.1.abs().partial_cmp(&b.1.abs()).unwrap())
            .map(|(i, _)| i)
            .unwrap()
    }

    fn energy(ir: &[f32; HRIR_LEN]) -> f32 {
        ir.iter().map(|x| x * x).sum()
    }

    /// Crude HF measure: energy of the sample-to-sample difference.
    fn hf_energy(ir: &[f32; HRIR_LEN]) -> f32 {
        ir.windows(2).map(|w| (w[1] - w[0]).powi(2)).sum()
    }

    #[test]
    fn left_source_leads_and_outlevels_left_ear() {
        let set = SyntheticHrirSet::new(48_000.0);
        let h = set.hrir((90f32).to_radians(), 0.0);
        let lp = peak_index(&h.left);
        let rp = peak_index(&h.right);
        assert!(lp < rp, "left peak {lp} should precede right peak {rp}");
        // ~0.65 ms at 48 kHz.
        assert!((rp - lp) > 20, "ITD too small: {} samples", rp - lp);
        assert!(energy(&h.left) > 1.3 * energy(&h.right), "ILD missing");
        assert!(hf_energy(&h.left) > 2.0 * hf_energy(&h.right), "head shadow LP missing");
    }

    #[test]
    fn right_source_mirrors() {
        let set = SyntheticHrirSet::new(48_000.0);
        let h = set.hrir((-90f32).to_radians(), 0.0);
        assert!(peak_index(&h.right) < peak_index(&h.left));
        assert!(energy(&h.right) > energy(&h.left));
    }

    #[test]
    fn front_is_symmetric() {
        let set = SyntheticHrirSet::new(48_000.0);
        let h = set.hrir(0.0, 0.0);
        for i in 0..HRIR_LEN {
            assert!((h.left[i] - h.right[i]).abs() < 1e-6, "front HRIR not symmetric at {i}");
        }
    }

    /// Broadband level difference between ears in dB for a given az.
    fn ild_db(set: &SyntheticHrirSet, az_deg: f32) -> f32 {
        let h = set.hrir(az_deg.to_radians(), 0.0);
        let near = energy(&h.left).max(energy(&h.right));
        let far = energy(&h.left).min(energy(&h.right));
        10.0 * (near / far).log10()
    }

    /// The fix for "can't tell left from right until it's lateral":
    /// ILD must grow steeply through the 20-60 deg band, not only
    /// near 90 deg. Targets approximate a real head above ~2 kHz.
    #[test]
    fn ild_grows_fast_enough_at_mid_angles() {
        let set = SyntheticHrirSet::new(48_000.0);
        let i20 = ild_db(&set, 20.0);
        let i30 = ild_db(&set, 30.0);
        let i45 = ild_db(&set, 45.0);
        let i90 = ild_db(&set, 90.0);
        // Monotonic growth.
        assert!(i20 < i30 && i30 < i45 && i45 < i90,
            "ILD not monotonic: {i20} {i30} {i45} {i90}");
        // The old linear model gave ~2.5 dB at 45 deg — demand clearly
        // more through the band where users were guessing.
        assert!(i30 > 4.0, "30 deg ILD too weak: {i30} dB");
        assert!(i45 > 6.5, "45 deg ILD too weak: {i45} dB");
        assert!(i90 > 10.0, "90 deg ILD too weak: {i90} dB");
    }

    #[test]
    fn rear_is_duller_than_front() {
        let set = SyntheticHrirSet::new(48_000.0);
        let front = set.hrir(0.0, 0.0);
        let rear = set.hrir(PI, 0.0);
        assert!(hf_energy(&rear.left) < 0.7 * hf_energy(&front.left));
    }
}
