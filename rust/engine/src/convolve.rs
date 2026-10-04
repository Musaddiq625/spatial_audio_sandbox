//! Direct time-domain FIR convolution (short HRIRs, few sources) with
//! equal-gain crossfade on coefficient swaps so head/source motion doesn't
//! zipper-click.

use crate::hrtf::{Hrir, HRIR_LEN};

/// Single-channel FIR, direct form, ring-buffer state.
pub struct Fir {
    coeffs: Vec<f32>,
    state: Vec<f32>,
    pos: usize,
}

impl Fir {
    pub fn new(len: usize) -> Self {
        Fir { coeffs: vec![0.0; len], state: vec![0.0; len], pos: 0 }
    }

    pub fn set_coeffs(&mut self, c: &[f32]) {
        for (d, s) in self.coeffs.iter_mut().zip(c.iter()) {
            *d = *s;
        }
    }

    /// Zero the delay line — clears the ringing tail without freeing
    /// or reallocating. Allocation-free; safe on the audio thread.
    pub fn reset(&mut self) {
        self.state.fill(0.0);
        self.pos = 0;
    }

    #[inline]
    pub fn tick(&mut self, x: f32) -> f32 {
        self.state[self.pos] = x;
        let mut acc = 0.0f32;
        let n = self.coeffs.len();
        let mut idx = self.pos;
        // Walk state backwards through coeffs.
        for (i, c) in self.coeffs.iter().enumerate() {
            let _ = i;
            acc += c * self.state[idx];
            idx = if idx == 0 { n - 1 } else { idx - 1 };
        }
        self.pos = (self.pos + 1) % n;
        acc
    }
}

/// Mono-in, stereo-out convolver around an HRIR pair with crossfade:
/// when a new HRIR is set, the old pair keeps rendering on `b` while `a`
/// fades in over `FADE` samples.
pub struct XFadeConvolver {
    a_l: Fir,
    a_r: Fir,
    b_l: Fir,
    b_r: Fir,
    fade: usize, // samples remaining on the b->a fade
}

const FADE: usize = 128;

impl XFadeConvolver {
    pub fn new() -> Self {
        XFadeConvolver {
            a_l: Fir::new(HRIR_LEN),
            a_r: Fir::new(HRIR_LEN),
            b_l: Fir::new(HRIR_LEN),
            b_r: Fir::new(HRIR_LEN),
            fade: 0,
        }
    }

    /// Point this convolver at a new HRIR pair (starts a crossfade).
    pub fn set_hrir(&mut self, h: &Hrir) {
        // Current a-state becomes b so its tail is preserved.
        std::mem::swap(&mut self.a_l, &mut self.b_l);
        std::mem::swap(&mut self.a_r, &mut self.b_r);
        self.a_l.set_coeffs(&h.left);
        self.a_r.set_coeffs(&h.right);
        self.fade = FADE;
    }

    /// First assignment without a fade (no audible tail to preserve).
    pub fn init_hrir(&mut self, h: &Hrir) {
        self.a_l.set_coeffs(&h.left);
        self.a_r.set_coeffs(&h.right);
        self.fade = 0;
    }

    /// Fresh start on an existing convolver: clear all filter history
    /// AND install `h`. `init_hrir` alone changes coefficients but
    /// keeps the old sample history — a new diagnostic trial would
    /// emit the previous trial's tail.
    pub fn reset_to(&mut self, h: &Hrir) {
        self.a_l.reset();
        self.a_r.reset();
        self.b_l.reset();
        self.b_r.reset();
        self.a_l.set_coeffs(&h.left);
        self.a_r.set_coeffs(&h.right);
        self.fade = 0;
    }

    /// Process one mono sample -> (left, right).
    #[inline]
    pub fn tick(&mut self, x: f32) -> (f32, f32) {
        let (mut l, mut r) = (self.a_l.tick(x), self.a_r.tick(x));
        if self.fade > 0 {
            let t = self.fade as f32 / FADE as f32; // 1 -> 0
            let (bl, br) = (self.b_l.tick(x), self.b_r.tick(x));
            l = l * (1.0 - t) + bl * t;
            r = r * (1.0 - t) + br * t;
            self.fade -= 1;
        }
        (l, r)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fir_convolves_impulse_into_coeffs() {
        let mut f = Fir::new(4);
        f.set_coeffs(&[0.5, -0.25, 0.125, 0.0625]);
        let mut got = [0.0f32; 4];
        got[0] = f.tick(1.0);
        for i in 1..4 {
            got[i] = f.tick(0.0);
        }
        assert!((got[0] - 0.5).abs() < 1e-6);
        assert!((got[1] + 0.25).abs() < 1e-6);
        assert!((got[2] - 0.125).abs() < 1e-6);
        assert!((got[3] - 0.0625).abs() < 1e-6);
    }

    #[test]
    fn xfade_renders_new_hrir_without_nans() {
        let mut c = XFadeConvolver::new();
        let mut h = Hrir { left: [0.0; HRIR_LEN], right: [0.0; HRIR_LEN] };
        h.left[0] = 1.0;
        h.right[0] = 0.5;
        c.init_hrir(&h);
        let (l, r) = c.tick(1.0);
        assert!((l - 1.0).abs() < 1e-6 && (r - 0.5).abs() < 1e-6);
        // Swap HRIR mid-stream: should crossfade, not click or NaN.
        h.left[0] = 0.25;
        h.right[0] = 1.0;
        c.set_hrir(&h);
        for _ in 0..FADE + 8 {
            let (l, r) = c.tick(0.0);
            assert!(l.is_finite() && r.is_finite());
        }
    }
}
