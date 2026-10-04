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

/// Control→audio commands. `Add` carries the fully-built SourceState
/// — convolver buffers are allocated on the control thread, so the
/// audio callback only moves a struct into place.
pub enum Cmd {
    Add(SourceState),
    Remove { id: u32 },
    SetPos { id: u32, pos: Vec3 },
    SetGain { id: u32, gain: f32 },
    /// L/R exaggeration: scales the azimuth used for HRIR lookup and
    /// adds a contralateral-ear level cut. 1.0 = natural.
    SetWidth { w: f32 },
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

/// A live source in the mixer. Built on the control thread and moved
/// through `Cmd::Add` so the audio callback never allocates.
pub struct SourceState {
    id: u32,
    gen: Box<dyn Source>,
    pos: Vec3,
    gain: f32,
    /// SetGain target — `gain` slews toward it per-sample (~20 ms ramp)
    /// so fades and mutes don't click.
    gain_target: f32,
    /// Remove requested — fade out, then move to the trash ring so the
    /// buffer is dropped on the control thread, not in the callback.
    removing: bool,
    conv: XFadeConvolver,
    az_q: i32,
    el_q: i32,
    dist_lp: OnePole,
    last_fc: f32,
}

impl SourceState {
    /// Construct off the audio thread — allocates convolver state.
    /// Sources fade in: gain starts at 0 and slews toward `gain`.
    pub fn new(id: u32, gen: Box<dyn Source>, pos: Vec3, gain: f32, sr: f32) -> Self {
        SourceState {
            id,
            gen,
            pos,
            gain: 0.0,
            gain_target: gain,
            removing: false,
            conv: XFadeConvolver::new(),
            az_q: i32::MIN,
            el_q: i32::MIN,
            dist_lp: OnePole::new(20_000.0, sr),
            last_fc: 20_000.0,
        }
    }
}

impl Cmd {
    /// Build an Add command — allocates the source's convolver state on
    /// the caller's (control) thread so `process` stays alloc-free.
    pub fn add(id: u32, gen: Box<dyn Source>, pos: Vec3, gain: f32, sr: f32) -> Cmd {
        Cmd::Add(SourceState::new(id, gen, pos, gain, sr))
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
    /// Audio→control ring: removed/finished sources go here to be
    /// dropped on the control thread. Never blocks — overflow parks in
    /// `pending_trash` and retries next block.
    trash_tx: rtrb::Producer<SourceState>,
    /// Retired sources waiting for trash ring space. Preallocated so
    /// pushing is alloc-free on the callback.
    pending_trash: Vec<SourceState>,
    scratch: Vec<f32>,
    verb_l: Fir,
    verb_r: Fir,
    wet: f32,
    master: f32,
    /// Lateral exaggeration (>1 widens the stereo image's L/R cue).
    width: f32,
    pub frames_rendered: u64,
}

impl Mixer {
    /// Returns the mixer, the command producer the engine handle keeps,
    /// and the trash consumer the engine drains on control calls.
    pub fn new(
        sr: f32,
        pose: Arc<PoseSlot>,
    ) -> (Self, rtrb::Producer<Cmd>, rtrb::Consumer<SourceState>) {
        let (tx, rx) = rtrb::RingBuffer::<Cmd>::new(256);
        let (ttx, trx) = rtrb::RingBuffer::<SourceState>::new(MAX_SOURCES);
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
                trash_tx: ttx,
                pending_trash: Vec::with_capacity(MAX_SOURCES),
                scratch: vec![0.0; MAX_BLOCK],
                verb_l,
                verb_r,
                wet: 0.12,
                master: 0.9,
                width: 1.3,
                frames_rendered: 0,
            },
            tx,
            trx,
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

    /// Retire a source: push it to the trash ring for the control
    /// thread to drop. Ring full → park in `pending_trash` (never freed
    /// on the callback either way).
    fn retire(&mut self, i: usize) {
        let ss = self.sources.swap_remove(i);
        if let Err(rtrb::PushError::Full(back)) = self.trash_tx.push(ss) {
            self.pending_trash.push(back);
        }
    }

    /// Flush parked trash — alloc-free within `pending_trash` capacity.
    fn drain_trash(&mut self) {
        while let Some(ss) = self.pending_trash.pop() {
            match self.trash_tx.push(ss) {
                Ok(()) => {}
                Err(rtrb::PushError::Full(back)) => {
                    self.pending_trash.push(back);
                    break;
                }
            }
        }
    }

    fn apply(&mut self, c: Cmd) {
        match c {
            Cmd::Add(ss) => {
                if self.sources.len() < MAX_SOURCES {
                    self.sources.push(ss);
                }
            }
            Cmd::Remove { id } => {
                // Fade out first — an instant removal clicks and frees
                // the buffer on the audio thread.
                if let Some(s) = self.sources.iter_mut().find(|s| s.id == id) {
                    s.removing = true;
                    s.gain_target = 0.0;
                }
            }
            Cmd::SetPos { id, pos } => {
                if let Some(s) = self.sources.iter_mut().find(|s| s.id == id) {
                    s.pos = pos;
                }
            }
            Cmd::SetGain { id, gain } => {
                if let Some(s) = self.sources.iter_mut().find(|s| s.id == id) {
                    s.gain_target = gain;
                }
            }
            Cmd::SetWidth { w } => {
                self.width = w.clamp(0.4, 2.0);
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
        self.drain_trash();
        for chunk in out.chunks_mut(self.scratch.len() * 2) {
            self.process_chunk(chunk);
        }
    }

    fn process_chunk(&mut self, out: &mut [f32]) {
        let n = out.len() / 2;
        out.fill(0.0);
        let head = self.pose.read().head;

        for s in self.sources.iter_mut() {
            // Finished one-shots and Remove'd sources fade through the
            // convolver tail instead of hard-cutting — then retire.
            if s.gen.is_finished() || s.removing {
                s.removing = true;
                s.gain_target = 0.0;
            }
            let dir = head.rotate(s.pos);
            let sph = Spherical::from_vec3(dir);

            // Width: exaggerate the rendered azimuth (super-stereo
            // trick — a 30 deg source spatializes like ~40 deg at 1.3)
            // plus an extra contralateral cut below. Soft-clamped so a
            // lateral source never wraps to the rear.
            let az_e = (sph.az * self.width).clamp(-2.1, 2.1);
            // Retarget the convolver when the quantized direction moved.
            let az_q = (az_e.to_degrees() / 5.0).round() as i32;
            let el_q = (sph.el.to_degrees() / 15.0).round() as i32;
            if az_q != s.az_q || el_q != s.el_q {
                let h = self.hrir.hrir(az_e, sph.el);
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
            let dg = Self::dist_gain(sph.dist);
            if s.gain.max(s.gain_target) * dg <= 1e-5 {
                // Fully faded (target and current both ~0): still run
                // the generator so loops keep phase, but skip conv.
                // A ramping-up gain fails this check and ticks below.
                for _ in 0..n {
                    s.gen.tick(self.sr);
                }
                continue;
            }

            // Per-sample gain slew toward the target — ~20 ms ramp,
            // click-free fades/mutes.
            let slew = 1.0 - (-1.0f32 / (self.sr * 0.02)).exp();
            // n <= scratch.len() is guaranteed by the chunking in process().
            for i in 0..n {
                s.gain += (s.gain_target - s.gain) * slew;
                self.scratch[i] = s.dist_lp.tick(s.gen.tick(self.sr)) * s.gain * dg;
            }
            // Extra interaural level difference on top of the baked-in
            // head shadow — this is the cue the ear uses most for L vs
            // R. Never boosts the far ear (width < 1 still narrows via
            // the azimuth scale above).
            let ild_db = ((self.width - 1.0) * 10.0 * sph.az.abs().sin()).max(0.0);
            let far_cut = 10f32.powf(-ild_db / 20.0);
            let (gl, gr) = if az_e >= 0.0 { (1.0, far_cut) } else { (far_cut, 1.0) };
            for i in 0..n {
                let (l, r) = s.conv.tick(self.scratch[i]);
                out[2 * i] += l * gl;
                out[2 * i + 1] += r * gr;
            }
        }

        // Retire sources whose fade-out converged — off the RT thread
        // via the trash ring, so no big frees in the callback.
        let mut i = 0;
        while i < self.sources.len() {
            let s = &self.sources[i];
            if s.removing && s.gain <= 1e-4 {
                self.retire(i);
            } else {
                i += 1;
            }
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

/// Convenience: a mixer + pose slot + producers for tests and offline
/// renders. The trash consumer is returned too — drain it to inspect
/// retired sources.
pub fn standalone(
    sr: f32,
) -> (Mixer, Arc<PoseSlot>, rtrb::Producer<Cmd>, rtrb::Consumer<SourceState>) {
    let slot = Arc::new(PoseSlot::new());
    let (mix, tx, trash) = Mixer::new(sr, slot.clone());
    (mix, slot, tx, trash)
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
        let (mut mix, _slot, mut tx, _trash) = standalone(SAMPLE_RATE);
        // Measure the direct path only — the decorrelated room tail would
        // swamp a single click's ILD.
        tx.push(Cmd::SetWet { wet: 0.0 }).unwrap();
        tx.push(Cmd::add(
            1,
            source::make(SourceKind::Click),
            Vec3::new(0.0, 1.0, 0.0), // hard left
            1.0,
            SAMPLE_RATE,
        ))
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
        let (mut mix, slot, mut tx, _trash) = standalone(SAMPLE_RATE);
        tx.push(Cmd::add(
            1,
            source::make(SourceKind::Click),
            Vec3::new(1.0, 0.0, 0.0), // scene front
            1.0,
            SAMPLE_RATE,
        ))
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

    /// SetGain must slew (~20 ms), never jump — fades and the scrub
    /// mute would click otherwise.
    #[test]
    fn gain_ramps_toward_target() {
        let (mut mix, _slot, _tx, _trash) = standalone(SAMPLE_RATE);
        mix.push_cmd(Cmd::add(
            1,
            source::make(SourceKind::Tone),
            Vec3::new(1.0, 0.0, 0.0),
            1.0,
            SAMPLE_RATE,
        ));
        // Adds fade in from 0 — render ~200 ms so the fade-in converges
        // before measuring the SetGain slew.
        let mut buf = [0f32; 19200];
        mix.process(&mut buf);
        mix.push_cmd(Cmd::SetGain { id: 1, gain: 0.5 });
        let mut buf = [0f32; 480]; // 240 frames ≈ 5 ms — still mid-ramp
        mix.process(&mut buf);
        let g = mix.sources[0].gain;
        assert!(g > 0.55 && g < 1.0, "5 ms in, gain should be mid-ramp: {g}");
        let mut buf = [0f32; 19200]; // 9600 frames ≈ 200 ms — converged
        mix.process(&mut buf);
        assert!(
            (mix.sources[0].gain - 0.5).abs() < 0.01,
            "gain should reach target: {}",
            mix.sources[0].gain
        );
    }

    /// Newly added sources fade in from silence — a hard gain jump on
    /// add clicks at the convolution edge.
    #[test]
    fn add_fades_in() {
        let (mut mix, _slot, _tx, _trash) = standalone(SAMPLE_RATE);
        mix.push_cmd(Cmd::add(
            1,
            source::make(SourceKind::Tone),
            Vec3::new(1.0, 0.0, 0.0),
            1.0,
            SAMPLE_RATE,
        ));
        let mut buf = [0f32; 256];
        mix.process(&mut buf);
        assert!(
            mix.sources[0].gain > 0.0 && mix.sources[0].gain < 0.9,
            "gain should still be ramping up: {}",
            mix.sources[0].gain
        );
    }

    /// Remove fades out, then retires the source to the trash ring —
    /// the buffer is dropped by the consumer (control thread), never
    /// freed inside process().
    #[test]
    fn remove_fades_then_retires() {
        let (mut mix, _slot, _tx, mut trash) = standalone(SAMPLE_RATE);
        mix.push_cmd(Cmd::add(
            1,
            source::make(SourceKind::Tone),
            Vec3::new(1.0, 0.0, 0.0),
            1.0,
            SAMPLE_RATE,
        ));
        let mut buf = [0f32; 19200]; // ~200 ms — fade-in converges
        mix.process(&mut buf);
        mix.push_cmd(Cmd::Remove { id: 1 });
        let mut buf = [0f32; 128]; // one small block — still fading
        mix.process(&mut buf);
        assert_eq!(mix.sources.len(), 1, "fading source still in the mix");
        assert!(mix.sources[0].removing);
        let mut buf = [0f32; 19200]; // ~200 ms — fade-out converges
        mix.process(&mut buf);
        assert_eq!(mix.sources.len(), 0, "retired out of the source list");
        assert!(trash.pop().is_ok(), "retired source lands on trash ring");
    }

    /// A finished one-shot is retired the same way — no abrupt free or
    /// silent source leaking forever.
    #[test]
    fn finished_source_retires() {
        let (mut mix, _slot, _tx, mut trash) = standalone(SAMPLE_RATE);
        mix.push_cmd(Cmd::add(
            1,
            Box::new(crate::source::FileSource::new(
                std::sync::Arc::new(vec![0.1f32; 32]),
                false,
            )),
            Vec3::new(1.0, 0.0, 0.0),
            1.0,
            SAMPLE_RATE,
        ));
        let mut buf = [0f32; 38400]; // ~400 ms — plays out + fades + retires
        mix.process(&mut buf);
        assert_eq!(mix.sources.len(), 0);
        assert!(trash.pop().is_ok());
    }

    // ── RT-safety guard ─────────────────────────────────────────────
    // Counting allocator: only active while ENABLED — proves process()
    // performs no heap allocation with a burst of add/remove commands.
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Thread-local gate — cargo runs tests in parallel, so a plain
    /// atomic would count sibling tests' allocations too.
    thread_local! {
        static ENABLED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    static ALLOCS: AtomicUsize = AtomicUsize::new(0);

    struct Counting;
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            if ENABLED.with(|e| e.get()) {
                ALLOCS.fetch_add(1, Ordering::Relaxed);
            }
            System.alloc(l)
        }
        unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
            System.dealloc(p, l)
        }
    }

    #[global_allocator]
    static A: Counting = Counting;

    /// Fill the mixer with a burst of adds/removes, then run process()
    /// under the counting allocator — zero allocations allowed.
    #[test]
    fn process_is_alloc_free() {
        let (mut mix, _slot, mut tx, _trash) = standalone(SAMPLE_RATE);
        // Park a full trash ring + pending queue so retirement paths run.
        for i in 0..MAX_SOURCES as u32 {
            tx.push(Cmd::add(
                i,
                Box::new(crate::source::FileSource::new(
                    std::sync::Arc::new(vec![0.1f32; 32]),
                    false,
                )),
                Vec3::new(1.0, 0.0, 0.0),
                1.0,
                SAMPLE_RATE,
            ))
            .unwrap();
            tx.push(Cmd::Remove { id: i }).unwrap();
            tx.push(Cmd::SetPos { id: i, pos: Vec3::new(0.0, 1.0, 0.0) })
                .unwrap();
        }
        // Warm up outside the counted region — HRIR lookup etc.
        let mut buf = [0f32; 256];
        mix.process(&mut buf);

        ALLOCS.store(0, Ordering::Relaxed);
        ENABLED.with(|e| e.set(true));
        let mut buf = [0f32; 512];
        mix.process(&mut buf);
        ENABLED.with(|e| e.set(false));
        assert_eq!(
            ALLOCS.load(Ordering::Relaxed),
            0,
            "process() allocated on the audio path"
        );
    }

    /// Width > 1 deepens the L/R level split; width < 1 narrows it.
    /// This is the cue the ear uses most for left vs right.
    #[test]
    fn width_controls_lr_separation() {
        fn lr_ratio(width: f32) -> f32 {
            let (mut mix, _slot, mut tx, _trash) = standalone(SAMPLE_RATE);
            tx.push(Cmd::SetWet { wet: 0.0 }).unwrap();
            tx.push(Cmd::SetWidth { w: width }).unwrap();
            tx.push(Cmd::add(
                1,
                source::make(SourceKind::Noise),
                Vec3::new(1.0, 0.5, 0.0), // ~27 deg left
                1.0,
                SAMPLE_RATE,
            ))
            .unwrap();
            let mut buf = [0f32; 19200];
            mix.process(&mut buf);
            let l: f32 = buf.iter().step_by(2).map(|x| x * x).sum();
            let r: f32 = buf.iter().skip(1).step_by(2).map(|x| x * x).sum();
            l / r
        }
        let narrow = lr_ratio(0.6);
        let wide = lr_ratio(2.0);
        assert!(narrow > 1.0, "left source should favor left ear: {narrow}");
        assert!(
            wide > narrow * 1.5,
            "width 2.0 should deepen separation vs 0.6: {narrow} -> {wide}"
        );
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
