//! Realtime engine handle: owns the stream, the command producer, and the
//! shared pose slot. Platform IO lives in cpal_io / oboe_io.

use crate::math::Vec3;
use crate::mix::{Cmd, DiagStatus, Trash};
use crate::pose::PoseSlot;
use crate::source::{self, Source, SourceKind};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct EngineInfo {
    pub backend: String,
    pub api: String,
    pub sample_rate: u32,
    pub channels: u32,
    pub frames_per_burst: i32,
    pub buffer_size_frames: i32,
    pub buffer_capacity_frames: i32,
    pub performance_mode: String,
    pub sharing_mode: String,
    /// Estimated output latency in ms, when the backend can report it.
    pub latency_ms: Option<f64>,
}

/// Keeps the platform stream alive; dropping it stops audio.
pub struct Engine {
    pub info: EngineInfo,
    cmd_tx: rtrb::Producer<Cmd>,
    /// Retired state lands here — dropping it (decoded PCM, convolver
    /// buffers) happens on the control thread, never in the callback.
    trash_rx: rtrb::Consumer<Trash>,
    /// Diagnostic-session status snapshot written by the mixer.
    diag_status: Arc<DiagStatus>,
    pub pose: Arc<PoseSlot>,
    _stream: Box<dyn StreamGuard>,
}

/// Object-safe "keep-alive" token for the platform stream.
pub trait StreamGuard: Send {
    /// Live output-latency estimate (AAudio timestamp path on Android).
    fn latency_ms(&mut self) -> Option<f64> {
        None
    }
}

impl Engine {
    /// `pose` is shared with the caller's PoseTracker so head tracking keeps
    /// working across engine restarts.
    pub fn start(pose: Arc<PoseSlot>) -> Result<Engine, String> {
        #[cfg(target_os = "android")]
        {
            crate::oboe_io::start(pose)
        }
        #[cfg(not(target_os = "android"))]
        {
            crate::cpal_io::start(pose)
        }
    }

    pub(crate) fn assemble(
        info: EngineInfo,
        cmd_tx: rtrb::Producer<Cmd>,
        trash_rx: rtrb::Consumer<Trash>,
        diag_status: Arc<DiagStatus>,
        pose: Arc<PoseSlot>,
        stream: Box<dyn StreamGuard>,
    ) -> Engine {
        Engine { info, cmd_tx, trash_rx, diag_status, pose, _stream: stream }
    }

    /// Drop retired sources on this (control) thread. Called at the top
    /// of every engine op — each call costs one queue check.
    fn drain_trash(&mut self) {
        while self.trash_rx.pop().is_ok() {
            // popped value drops here
        }
    }

    /// Live latency re-query (AAudio timestamp path on Android).
    pub fn output_latency_ms(&mut self) -> Option<f64> {
        self._stream.latency_ms().or(self.info.latency_ms)
    }

    fn push(&mut self, c: Cmd) -> Result<(), String> {
        self.drain_trash();
        self.cmd_tx.push(c).map_err(|_| {
            // Logged because a dropped command is silent desync — this
            // is what made scrub seeks lose sources.
            eprintln!("[engine] cmd queue full — command dropped");
            "command queue full".to_string()
        })
    }

    pub fn add_source(&mut self, kind: SourceKind, pos: Vec3, gain: f32, id: u32) -> Result<(), String> {
        // SourceState allocates its convolver buffers here, on the
        // control thread — the callback just moves it into place.
        self.push(Cmd::add(id, source::make(kind), pos, gain, self.info.sample_rate as f32))
    }

    /// Any `Source` impl (e.g. decoded file playback) — same command path
    /// as the procedural kinds.
    pub fn add_custom(&mut self, gen: Box<dyn Source>, pos: Vec3, gain: f32, id: u32) -> Result<(), String> {
        self.push(Cmd::add(id, gen, pos, gain, self.info.sample_rate as f32))
    }

    /// Request removal — the mixer fades the source out, then retires it
    /// to the trash ring (drop happens here, on the control thread).
    pub fn remove_source(&mut self, id: u32) {
        let _ = self.push(Cmd::Remove { id });
    }

    pub fn set_source_pos(&mut self, id: u32, pos: Vec3) {
        let _ = self.push(Cmd::SetPos { id, pos });
    }

    pub fn set_source_gain(&mut self, id: u32, gain: f32) {
        let _ = self.push(Cmd::SetGain { id, gain });
    }

    /// Move a file source's playhead; no-op for procedural sources.
    pub fn seek_source(&mut self, id: u32, pos_s: f32) {
        let _ = self.push(Cmd::Seek { id, pos_s });
    }

    pub fn set_master(&mut self, gain: f32) {
        let _ = self.push(Cmd::SetMaster { gain });
    }

    /// L/R exaggeration: 1.0 natural, up to 2.0. Scales rendered
    /// azimuth and adds a contralateral-ear cut.
    pub fn set_spatial_width(&mut self, w: f32) {
        let _ = self.push(Cmd::SetWidth { w });
    }

    /// Live spatial tuning for the calibration panel: azimuth
    /// exaggeration, reverb wet send, extra far-ear cut span (dB).
    pub fn set_spatial_params(&mut self, width: f32, wet: f32, ild_db: f32) {
        let _ = self.push(Cmd::SetSpatial { width, wet, ild_db });
    }

    // ── Diagnostic session (ear calibration / sound check) ─────────

    /// Enter a diagnostic session — suspends normal rendering.
    pub fn diag_enter(&mut self, token: u32) -> Result<(), String> {
        self.push(Cmd::diag_enter(token, self.info.sample_rate as f32))
    }

    /// End the session — normal sources fade back in.
    pub fn diag_exit(&mut self, token: u32) {
        let _ = self.push(Cmd::DiagExit { token });
    }

    /// Start/replace a bounded trial. `az` in radians (+ = left);
    /// `level` 0..1.5; `balance` -1 left .. +1 right (direct mode).
    pub fn diag_play(
        &mut self,
        token: u32,
        trial: u32,
        direct: bool,
        az: f32,
        level: f32,
        balance: f32,
    ) -> Result<(), String> {
        self.push(Cmd::DiagPlay { token, trial, direct, az, level, balance })
    }

    /// Stop the current trial; the session stays open.
    pub fn diag_stop(&mut self, token: u32) {
        let _ = self.push(Cmd::DiagStop { token });
    }

    /// Live-tune volume/balance/position mid-trial.
    pub fn diag_params(&mut self, token: u32, az: f32, level: f32, balance: f32) {
        let _ = self.push(Cmd::DiagParams { token, az, level, balance });
    }

    /// (session token, playing trial, remaining ms) — UI polls this.
    pub fn diag_status(&self) -> (u32, u32, u32) {
        self.diag_status.read()
    }
}
