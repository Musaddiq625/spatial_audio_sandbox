//! Realtime engine handle: owns the stream, the command producer, and the
//! shared pose slot. Platform IO lives in cpal_io / oboe_io.

use crate::math::Vec3;
use crate::mix::{Cmd, SourceState};
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
    /// Retired sources land here — dropping them (decoded PCM, convolver
    /// state) happens on the control thread, never in the callback.
    trash_rx: rtrb::Consumer<SourceState>,
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
        trash_rx: rtrb::Consumer<SourceState>,
        pose: Arc<PoseSlot>,
        stream: Box<dyn StreamGuard>,
    ) -> Engine {
        Engine { info, cmd_tx, trash_rx, pose, _stream: stream }
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
}
