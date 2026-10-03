//! Realtime engine handle: owns the stream, the command producer, and the
//! shared pose slot. Platform IO lives in cpal_io / oboe_io.

use crate::math::Vec3;
use crate::mix::Cmd;
use crate::pose::PoseSlot;
use crate::source::{self, SourceKind};
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
        pose: Arc<PoseSlot>,
        stream: Box<dyn StreamGuard>,
    ) -> Engine {
        Engine { info, cmd_tx, pose, _stream: stream }
    }

    /// Live latency re-query (AAudio timestamp path on Android).
    pub fn output_latency_ms(&mut self) -> Option<f64> {
        self._stream.latency_ms().or(self.info.latency_ms)
    }

    pub fn add_source(&mut self, kind: SourceKind, pos: Vec3, gain: f32, id: u32) -> Result<(), String> {
        self.cmd_tx
            .push(Cmd::Add { id, gen: source::make(kind), pos, gain })
            .map_err(|_| "command queue full".to_string())
    }

    pub fn remove_source(&mut self, id: u32) {
        let _ = self.cmd_tx.push(Cmd::Remove { id });
    }

    pub fn set_source_pos(&mut self, id: u32, pos: Vec3) {
        let _ = self.cmd_tx.push(Cmd::SetPos { id, pos });
    }

    pub fn set_source_gain(&mut self, id: u32, gain: f32) {
        let _ = self.cmd_tx.push(Cmd::SetGain { id, gain });
    }

    pub fn set_master(&mut self, gain: f32) {
        let _ = self.cmd_tx.push(Cmd::SetMaster { gain });
    }
}
