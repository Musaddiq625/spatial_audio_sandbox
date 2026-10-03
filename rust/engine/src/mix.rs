//! The mixer: pull commands, render each source mono, spatialize through the
//! HRIR set using the current head pose, sum to stereo, add a light room
//! tail (helps externalization), soft-clip.
//!
//! Hot-path rules: no allocation, no locks (seqlock pose + rtrb commands only).

use crate::convolve::{Fir, XFadeConvolver};
use crate::hrtf::SyntheticHrirSet;
use crate::math::{Spherical, Vec3};
use crate::pose::PoseSlot;
use crate::source::{OnePole, Source, XorShift};
use std::sync::Arc;

/// Commands into the audio thread. Carrying `Box<dyn Source>` is fine: the
/// allocation happens on the caller's thread, not the callback's.
pub enum Cmd {
    Add { id: u32, gen: Box<dyn Source>, pos: Vec3, gain: f32 },
    Remove { id: u32 },
    SetPos { id: u32, pos: Vec3 },
    SetGain { id: u32, gain: f32 },
    Seek { id: u32, pos_s: f32 },
    SetMaster { gain: f32 },
    SetWet { wet: f32 },
}

const MAX_SOURCES: usize = 16;
const MAX_BLOCK: usize = 4096;
/// Distance (m) at which gain stops falling off as 1/d (prevents blowup at
/// the listener's head) — sources closer than this use full near gain.
const REF_DIST: f32 = 1.0;
/// Beyond this distance sources are silent.
const MAX_DIST: f32 = 60.0;

struct SourceState {
    id: u32,
    gen: Box<dyn Source>,
    pos: Vec3,
    gain: f32,
    conv: XFadeConvolver,
    az_q: i32,
    el_q: i32,
    dist_lp: OnePole,
    last_fc: f32,
}

impl SourceState {
    fn new(id: u32, gen: Box<dyn Source>, pos: Vec3, gain: f32, sr: f32) -> Self {
        SourceState {
            id,
            gen,
            pos,
            gain,
            conv: XFadeConvolver::new(),
            az_q: i32::MIN,
            el_q: i32::MIN,
            dist_lp: OnePole::new(20_000.0, sr),
            last_fc: 20_000.0,
        }
    }
}

/// Sparse velvet-noise room tail + asymmetric early reflections. Deliberately
/// subtle — just enough room impression to pull images out of the head.
fn build_room_irs(sr: f32) -> ([f32; 128], [f32; 128]) {
    let _ = sr;
    let mut l = [0f32; 128];
    let mut r = [0f32; 128];
    let mut rng = XorShift::new(0x2007);
    // ~120 ms tail: a tap every other sample, exponentially decaying.
    for i in (4..128).step_by(2) {
        let t = i as f32 / 128.0;
        let env = (-t * 5.0).exp();
        l[i] = rng.next_f() * env * 0.5;
        r[i] = rng.next_f() * env * 0.5;
    }
    // Early reflections (fractional positions smoothed across 2 taps).
    let er_l = [(11, 0.55), (23, 0.35), (41, 0.25)];
    let er_r = [(13, 0.5), (29, 0.32), (47, 0.22)];
    for (i, g) in er_l {
        l[i] += g;
    }
    for (i, g) in er_r {
        r[i] += g;
    }
    (l, r)
}

pub struct Mixer {
    sr: f32,
    pose: Arc<PoseSlot>,
    hrir: SyntheticHrirSet,
    sources: Vec<SourceState>,
    cmd_rx: rtrb::Consumer<Cmd>,
    scratch: Vec<f32>,
    verb_l: Fir,
    verb_r: Fir,
    wet: f32,
    master: f32,
    pub frames_rendered: u64,
}

impl Mixer {
    /// Returns the mixer and the command producer the engine handle keeps.
    pub fn new(sr: f32, pose: Arc<PoseSlot>) -> (Self, rtrb::Producer<Cmd>) {
        let (tx, rx) = rtrb::RingBuffer::<Cmd>::new(64);
        let (il, ir) = build_room_irs(sr);
        let mut verb_l = Fir::new(128);
        verb_l.set_coeffs(&il);
        let mut verb_r = Fir::new(128);
        verb_r.set_coeffs(&ir);
        (
            Mixer {
                sr,
                pose,
                hrir: SyntheticHrirSet::new(sr),
                sources: Vec::with_capacity(MAX_SOURCES),
                cmd_rx: rx,
                scratch: vec![0.0; MAX_BLOCK],
                verb_l,
                verb_r,
                wet: 0.12,
                master: 0.9,
                frames_rendered: 0,
            },
            tx,
        )
    }

    pub fn sample_rate(&self) -> f32 {
        self.sr
    }

    /// Test/offline helper: push a command without a producer handle.
    #[cfg(test)]
    pub fn push_cmd(&mut self, c: Cmd) {
        self.apply(c);
    }

    fn apply(&mut self, c: Cmd) {
        match c {
            Cmd::Add { id, gen, pos, gain } => {
                if self.sources.len() < MAX_SOURCES {
                    self.sources.push(SourceState::new(id, gen, pos, gain, self.sr));
                }
            }
            Cmd::Remove { id } => {
                self.sources.retain(|s| s.id != id);
            }
            Cmd::SetPos { id, pos } => {
                if let Some(s) = self.sources.iter_mut().find(|s| s.id == id) {
                    s.pos = pos;
                }
            }
            Cmd::SetGain { id, gain } => {
                if let Some(s) = self.sources.iter_mut().find(|s| s.id == id) {
                    s.gain = gain;
                }
            }
            Cmd::Seek { id, pos_s } => {
                if let Some(s) = self.sources.iter_mut().find(|s| s.id == id) {
                    s.gen.seek(pos_s, self.sr);
                }
            }
            Cmd::SetMaster { gain } => self.master = gain,
            Cmd::SetWet { wet } => self.wet = wet.clamp(0.0, 1.0),
        }
    }

    #[inline]
    fn dist_gain(d: f32) -> f32 {
        if d >= MAX_DIST {
            0.0
        } else {
            REF_DIST / d.max(REF_DIST)
        }
    }

    /// Air absorption: gentle LP that closes in with distance.
    #[inline]
    fn dist_fc(d: f32) -> f32 {
        (20_000.0 * (-(d - REF_DIST).max(0.0) / 18.0).exp()).max(3_000.0)
    }

    /// Render `n` frames of interleaved stereo into `out` (len = 2n).
    /// Chunks internally so arbitrarily large callbacks stay correct.
    pub fn process(&mut self, out: &mut [f32]) {
        while let Ok(c) = self.cmd_rx.pop() {
            self.apply(c);
        }
        for chunk in out.chunks_mut(self.scratch.len() * 2) {
            self.process_chunk(chunk);
        }
    }

    fn process_chunk(&mut self, out: &mut [f32]) {
        let n = out.len() / 2;
        out.fill(0.0);
        let head = self.pose.read().head;

        // Snapshot so we can retain() finished sources after the loop.
        let mut finished = false;

        for s in self.sources.iter_mut() {
            if s.gen.is_finished() {
                finished = true;
                continue;
            }
            let dir = head.rotate(s.pos);
            let sph = Spherical::from_vec3(dir);

            // Retarget the convolver when the quantized direction moved.
            let az_q = (sph.az.to_degrees() / 5.0).round() as i32;
            let el_q = (sph.el.to_degrees() / 15.0).round() as i32;
            if az_q != s.az_q || el_q != s.el_q {
                let h = self.hrir.hrir(sph.az, sph.el);
                // First assignment: no fade — there is no old tail to
                // preserve, and fading from silence would mis-weight early
                // vs late taps of the first block.
                if s.az_q == i32::MIN {
                    s.conv.init_hrir(h);
                } else {
                    s.conv.set_hrir(h);
                }
                s.az_q = az_q;
                s.el_q = el_q;
            }

            // Distance: gain + air LP (update only when it drifts).
            let fc = Self::dist_fc(sph.dist);
            if (fc - s.last_fc).abs() > 50.0 {
                s.dist_lp = OnePole::new(fc, self.sr);
                s.last_fc = fc;
            }
            let g = s.gain * Self::dist_gain(sph.dist);
            if g <= 1e-5 {
                // Still run the generator so loops keep phase, but skip conv.
                for i in 0..n {
                    s.gen.tick(self.sr);
                    let _ = i;
                }
                continue;
            }

            // n <= scratch.len() is guaranteed by the chunking in process().
            for i in 0..n {
                self.scratch[i] = s.dist_lp.tick(s.gen.tick(self.sr)) * g;
            }
            for i in 0..n {
                let (l, r) = s.conv.tick(self.scratch[i]);
                out[2 * i] += l;
                out[2 * i + 1] += r;
            }
        }

        if finished {
            self.sources.retain(|s| !s.gen.is_finished());
        }

        // Room tail on the mid signal.
        let wet = self.wet;
        if wet > 0.0 {
            for i in 0..n {
                let mid = 0.5 * (out[2 * i] + out[2 * i + 1]);
                out[2 * i] += self.verb_l.tick(mid) * wet;
                out[2 * i + 1] += self.verb_r.tick(mid) * wet;
            }
        }

        // Master gain + soft clip.
        let m = self.master;
        for x in out.iter_mut() {
            *x = (*x * m).tanh();
        }
        self.frames_rendered += n as u64;
    }
}

/// Convenience: a mixer + pose slot + producer for tests and offline renders.
pub fn standalone(sr: f32) -> (Mixer, Arc<PoseSlot>, rtrb::Producer<Cmd>) {
    let slot = Arc::new(PoseSlot::new());
    let (mix, tx) = Mixer::new(sr, slot.clone());
    (mix, slot, tx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::Vec3;
    use crate::source::{self, SourceKind};
    use crate::SAMPLE_RATE;

    /// Click at hard left must reach the left ear before the right ear.
    #[test]
    fn click_left_shows_itd_and_ild() {
        let (mut mix, _slot, mut tx) = standalone(SAMPLE_RATE);
        // Measure the direct path only — the decorrelated room tail would
        // swamp a single click's ILD.
        tx.push(Cmd::SetWet { wet: 0.0 }).unwrap();
        tx.push(Cmd::Add {
            id: 1,
            gen: source::make(SourceKind::Click),
            pos: Vec3::new(0.0, 1.0, 0.0), // hard left
            gain: 1.0,
        })
        .unwrap();
        let mut buf = [0f32; 256];
        mix.process(&mut buf);
        let (l_peak, r_peak) = peak_positions(&buf);
        assert!(l_peak < r_peak, "left ear should fire first: l={l_peak} r={r_peak}");
        let l_e: f32 = buf.iter().step_by(2).map(|x| x * x).sum();
        let r_e: f32 = buf.iter().skip(1).step_by(2).map(|x| x * x).sum();
        assert!(l_e > r_e * 1.2, "ILD: left energy {l_e} should exceed right {r_e}");
    }

    #[test]
    fn head_turn_moves_image() {
        use crate::pose::Pose;
        use std::f32::consts::FRAC_PI_2;
        let (mut mix, slot, mut tx) = standalone(SAMPLE_RATE);
        tx.push(Cmd::Add {
            id: 1,
            gen: source::make(SourceKind::Click),
            pos: Vec3::new(1.0, 0.0, 0.0), // scene front
            gain: 1.0,
        })
        .unwrap();
        // Head turned 90 deg right => front source sits at hard left in
        // head coords => left ear fires first.
        slot.write(Pose {
            head: crate::math::Quat::yaw(FRAC_PI_2),
            raw: crate::math::Quat::IDENTITY,
        });
        let mut buf = [0f32; 256];
        mix.process(&mut buf);
        let (l_peak, r_peak) = peak_positions(&buf);
        assert!(l_peak < r_peak);
    }

    fn peak_positions(buf: &[f32]) -> (usize, usize) {
        let mut lp = 0;
        let mut rp = 0;
        let mut lv = 0f32;
        let mut rv = 0f32;
        for i in 0..buf.len() / 2 {
            if buf[2 * i].abs() > lv {
                lv = buf[2 * i].abs();
                lp = i;
            }
            if buf[2 * i + 1].abs() > rv {
                rv = buf[2 * i + 1].abs();
                rp = i;
            }
        }
        (lp, rp)
    }
}
