//! Procedural demo sources — no audio assets needed for the spikes.
//! All generators are allocation-free and `Send`.

use std::f32::consts::PI;

/// Mono generator. `tick` returns one sample at sample rate `sr`.
pub trait Source: Send {
    fn tick(&mut self, sr: f32) -> f32;
    fn is_finished(&self) -> bool {
        false
    }
}

/// What the UI can ask for. Kept FRB-friendly (plain enum).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    Bee,
    Rain,
    Pad,
    Tone,
    Noise,
    Click,
}

pub fn make(kind: SourceKind) -> Box<dyn Source> {
    match kind {
        SourceKind::Bee => Box::new(Bee::new()),
        SourceKind::Rain => Box::new(Rain::new()),
        SourceKind::Pad => Box::new(Pad::new()),
        SourceKind::Tone => Box::new(Tone::new(440.0)),
        SourceKind::Noise => Box::new(Noise::new(0.3)),
        SourceKind::Click => Box::new(Click::new()),
    }
}

/// Tiny deterministic PRNG — no rand dep, no alloc.
pub struct XorShift(u32);

impl XorShift {
    pub fn new(seed: u32) -> Self {
        XorShift(seed | 1)
    }
    /// Uniform in [-1, 1).
    pub fn next_f(&mut self) -> f32 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.0 = x;
        (x as f32 / u32::MAX as f32) * 2.0 - 1.0
    }
}

/// One-pole lowpass helper.
#[derive(Clone, Copy)]
pub struct OnePole {
    a: f32,
    y: f32,
}

impl OnePole {
    pub fn new(fc: f32, sr: f32) -> Self {
        OnePole { a: (-2.0 * PI * fc / sr).exp(), y: 0.0 }
    }
    #[inline]
    pub fn tick(&mut self, x: f32) -> f32 {
        self.y = (1.0 - self.a) * x + self.a * self.y;
        self.y
    }
}

/// Sine tone — used by the S1 latency spike and tests.
pub struct Tone {
    freq: f32,
    phase: f32,
}

impl Tone {
    pub fn new(freq: f32) -> Self {
        Tone { freq, phase: 0.0 }
    }
}

impl Source for Tone {
    fn tick(&mut self, sr: f32) -> f32 {
        let out = (2.0 * PI * self.phase).sin() * 0.5;
        self.phase = (self.phase + self.freq / sr) % 1.0;
        out
    }
}

pub struct Noise {
    rng: XorShift,
    gain: f32,
}

impl Noise {
    pub fn new(gain: f32) -> Self {
        Noise { rng: XorShift::new(0x9E3779B9), gain }
    }
}

impl Source for Noise {
    fn tick(&mut self, _sr: f32) -> f32 {
        self.rng.next_f() * self.gain
    }
}

/// Single impulse then silence — impulse-response probe for tests.
pub struct Click {
    fired: bool,
}

impl Click {
    pub fn new() -> Self {
        Click { fired: false }
    }
}

impl Source for Click {
    fn tick(&mut self, _sr: f32) -> f32 {
        if self.fired {
            0.0
        } else {
            self.fired = true;
            1.0
        }
    }
    fn is_finished(&self) -> bool {
        self.fired
    }
}

/// Buzzing insect: detuned harmonic stack + wing flutter + slow wander.
pub struct Bee {
    rng: XorShift,
    base: f32,
    phase: [f32; 6],
    t: f32,
    wander: f32,
    lp: OnePole,
}

impl Bee {
    pub fn new() -> Self {
        Bee {
            rng: XorShift::new(0xBEE),
            base: 165.0,
            phase: [0.0; 6],
            t: 0.0,
            wander: 0.0,
            lp: OnePole::new(3_000.0, 48_000.0),
        }
    }
}

impl Source for Bee {
    fn tick(&mut self, sr: f32) -> f32 {
        self.t += 1.0 / sr;
        // Slow pitch wander (~0.5 Hz lowpassed noise).
        self.wander += (self.rng.next_f() * 0.02 - self.wander * 0.002).clamp(-0.05, 0.05);
        let vib = 1.0 + 0.05 * (2.0 * PI * 9.0 * self.t).sin() + self.wander;
        let f = self.base * vib;
        let mut x = 0.0;
        for h in 0..6 {
            let hf = f * (h + 1) as f32;
            self.phase[h] = (self.phase[h] + hf / sr) % 1.0;
            x += (2.0 * PI * self.phase[h]).sin() / (h + 1) as f32;
        }
        // Wing flutter ~24 Hz AM.
        let amp = 0.55 + 0.35 * (2.0 * PI * 24.0 * self.t).sin().abs();
        // A pinch of breath noise.
        x = x * 0.45 + self.rng.next_f() * 0.04;
        self.lp.tick(x) * amp * 0.5
    }
}

/// Rain: lowpassed noise bed + sparse droplet "plinks".
pub struct Rain {
    rng: XorShift,
    bed_lp: OnePole,
    bed_lp2: OnePole,
    drops: [Drop; 8],
    next_drop_in: u32,
}

#[derive(Clone, Copy, Default)]
struct Drop {
    age: u32, // u32::MAX = inactive
    freq: f32,
    amp: f32,
    phase: f32,
}

impl Rain {
    pub fn new() -> Self {
        Rain {
            rng: XorShift::new(0x2A11),
            bed_lp: OnePole::new(1_100.0, 48_000.0),
            bed_lp2: OnePole::new(4_000.0, 48_000.0),
            drops: [Drop::default(); 8],
            next_drop_in: 0,
        }
    }
}

impl Source for Rain {
    fn tick(&mut self, sr: f32) -> f32 {
        // Noise bed, double-LP'd for a soft hiss.
        let n = self.rng.next_f();
        let bed = self.bed_lp.tick(n) * 0.9 + self.bed_lp2.tick(n) * 0.15;

        if self.next_drop_in == 0 {
            // Spawn a droplet if a slot is free (~10/sec Poisson-ish).
            for d in self.drops.iter_mut() {
                if d.age == u32::MAX {
                    d.age = 0;
                    d.freq = 1_400.0 + (self.rng.next_f() * 0.5 + 0.5) * 3_200.0;
                    d.amp = 0.03 + (self.rng.next_f() * 0.5 + 0.5) * 0.10;
                    d.phase = 0.0;
                    break;
                }
            }
            self.next_drop_in = (sr * 0.1) as u32 + (self.rng.next_f().abs() * sr * 0.1) as u32;
        } else {
            self.next_drop_in -= 1;
        }

        let mut x = bed;
        for d in self.drops.iter_mut() {
            if d.age == u32::MAX {
                continue;
            }
            let t = d.age as f32 / sr;
            let env = (-t / 0.015).exp();
            x += (2.0 * PI * (d.phase)).sin() * d.amp * env;
            d.phase = (d.phase + d.freq / sr) % 1.0;
            d.age += 1;
            if env < 0.001 {
                d.age = u32::MAX;
            }
        }
        x * 0.4
    }
}

/// Buffered playback source — decoded PCM from a file/API response.
/// `looping` wraps at the end (use with seamless-loop content, e.g.
/// ElevenLabs `loop:true` output); one-shots report `is_finished` and the
/// mixer drops them on its own.
pub struct FileSource {
    buf: Vec<f32>,
    idx: usize,
    looping: bool,
    done: bool,
}

impl FileSource {
    pub fn new(buf: Vec<f32>, looping: bool) -> Self {
        let done = buf.is_empty();
        FileSource { buf, idx: 0, looping, done }
    }
}

impl Source for FileSource {
    fn tick(&mut self, _sr: f32) -> f32 {
        if self.done {
            return 0.0;
        }
        let x = self.buf[self.idx];
        self.idx += 1;
        if self.idx >= self.buf.len() {
            if self.looping {
                self.idx = 0;
            } else {
                self.done = true;
            }
        }
        x
    }
    fn is_finished(&self) -> bool {
        self.done
    }
}

/// Pad: slow chord (A3 + C4 + E4) with staggered tremolo.
pub struct Pad {
    phase: [f32; 3],
    t: f32,
}

impl Pad {
    pub fn new() -> Self {
        Pad { phase: [0.0; 3], t: 0.0 }
    }
}

const PAD_FREQS: [f32; 3] = [220.0, 261.63, 329.63];

impl Source for Pad {
    fn tick(&mut self, sr: f32) -> f32 {
        self.t += 1.0 / sr;
        let mut x = 0.0;
        for (i, &f) in PAD_FREQS.iter().enumerate() {
            self.phase[i] = (self.phase[i] + f / sr) % 1.0;
            let trem = 0.7 + 0.3 * (2.0 * PI * (0.13 + i as f32 * 0.05) * self.t).sin();
            x += (2.0 * PI * self.phase[i]).sin() * trem;
        }
        // Soft 2 s attack, then sustain.
        let env = (self.t / 2.0).min(1.0);
        x * env * 0.22
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_sources_produce_finite_bounded_output() {
        for kind in [SourceKind::Bee, SourceKind::Rain, SourceKind::Pad, SourceKind::Tone, SourceKind::Noise] {
            let mut s = make(kind);
            for _ in 0..4096 {
                let x = s.tick(48_000.0);
                assert!(x.is_finite(), "{kind:?} produced non-finite sample");
                assert!(x.abs() < 4.0, "{kind:?} sample out of range: {x}");
            }
        }
    }

    #[test]
    fn click_fires_once() {
        let mut c = Click::new();
        assert_eq!(c.tick(48_000.0), 1.0);
        assert_eq!(c.tick(48_000.0), 0.0);
        assert!(c.is_finished());
    }

    #[test]
    fn file_source_loops_and_finishes() {
        let mut one = FileSource::new(vec![0.5; 4], false);
        for _ in 0..4 {
            assert_eq!(one.tick(48_000.0), 0.5);
        }
        assert!(one.is_finished());
        assert_eq!(one.tick(48_000.0), 0.0);

        let mut l = FileSource::new(vec![1.0, -1.0], true);
        let got: Vec<f32> = (0..5).map(|_| l.tick(48_000.0)).collect();
        assert_eq!(got, [1.0, -1.0, 1.0, -1.0, 1.0]);
        assert!(!l.is_finished());
    }
}
