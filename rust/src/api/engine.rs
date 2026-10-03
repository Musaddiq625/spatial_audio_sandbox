//! FRB surface for the engine. Thin wrappers over `sas_engine` — all DSP
//! lives in the pure-Rust crate.

use anyhow::{anyhow, Result};
use sas_engine::math::Vec3;
use sas_engine::pose::{PoseSlot, PoseTracker};
use sas_engine::rt::{Engine, EngineInfo};
use sas_engine::source::SourceKind;
use sas_engine::render;
use std::sync::{Arc, Mutex, OnceLock};

/// Mirror of `sas_engine::rt::EngineInfo` for codegen (all-owned types).
pub struct EngineInfoWire {
    pub backend: String,
    pub api: String,
    pub sample_rate: u32,
    pub channels: u32,
    pub frames_per_burst: i32,
    pub buffer_size_frames: i32,
    pub buffer_capacity_frames: i32,
    pub performance_mode: String,
    pub sharing_mode: String,
    pub latency_ms: Option<f64>,
}

impl From<EngineInfo> for EngineInfoWire {
    fn from(i: EngineInfo) -> Self {
        EngineInfoWire {
            backend: i.backend,
            api: i.api,
            sample_rate: i.sample_rate,
            channels: i.channels,
            frames_per_burst: i.frames_per_burst,
            buffer_size_frames: i.buffer_size_frames,
            buffer_capacity_frames: i.buffer_capacity_frames,
            performance_mode: i.performance_mode,
            sharing_mode: i.sharing_mode,
            latency_ms: i.latency_ms,
        }
    }
}

/// FRB-friendly mirror of SourceKind.
#[derive(Clone, Copy, Debug)]
pub enum SourceKindWire {
    Bee,
    Rain,
    Pad,
    Tone,
    Noise,
    Click,
}

impl From<SourceKindWire> for SourceKind {
    fn from(k: SourceKindWire) -> Self {
        match k {
            SourceKindWire::Bee => SourceKind::Bee,
            SourceKindWire::Rain => SourceKind::Rain,
            SourceKindWire::Pad => SourceKind::Pad,
            SourceKindWire::Tone => SourceKind::Tone,
            SourceKindWire::Noise => SourceKind::Noise,
            SourceKindWire::Click => SourceKind::Click,
        }
    }
}

struct State {
    engine: Option<Engine>,
    tracker: PoseTracker,
    next_id: u32,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| {
        let slot = Arc::new(PoseSlot::new());
        Mutex::new(State {
            engine: None,
            tracker: PoseTracker::new(slot),
            next_id: 1,
        })
    })
}

/// Start the realtime engine (cpal on desktop, oboe on Android).
/// Returns the negotiated stream parameters — the S1 latency data.
pub fn engine_start() -> Result<EngineInfoWire> {
    let mut st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
    if st.engine.is_some() {
        let info: EngineInfoWire = st.engine.as_ref().unwrap().info.clone().into();
        return Ok(info);
    }
    let engine = Engine::start(st.tracker.slot()).map_err(|e| anyhow!(e))?;
    let info = engine.info.clone().into();
    st.engine = Some(engine);
    Ok(info)
}

pub fn engine_stop() {
    if let Ok(mut st) = state().lock() {
        st.engine = None; // drop stops the stream
    }
}

/// Live engine stats (latency may update on Android via timestamps).
#[flutter_rust_bridge::frb(sync)]
pub fn engine_info() -> Option<EngineInfoWire> {
    state().lock().ok().and_then(|mut st| {
        st.engine.as_mut().map(|e| {
            let mut w: EngineInfoWire = e.info.clone().into();
            w.latency_ms = e.output_latency_ms();
            w
        })
    })
}

/// Push the fused-IMU quaternion (+ gyro rate in rad/s) into the engine.
/// Called at ~60 Hz from the sensor stream — keep it cheap and sync.
#[flutter_rust_bridge::frb(sync)]
pub fn set_head_pose(w: f32, x: f32, y: f32, z: f32, gx: f32, gy: f32, gz: f32) {
    if let Ok(mut st) = state().lock() {
        st.tracker.update(w, x, y, z, gx, gy, gz);
    }
}

/// Latch the current orientation as "forward".
#[flutter_rust_bridge::frb(sync)]
pub fn recenter() {
    if let Ok(mut st) = state().lock() {
        st.tracker.recenter();
    }
}

/// Prediction horizon in milliseconds (e.g. measured BT output latency).
#[flutter_rust_bridge::frb(sync)]
pub fn set_predict_ms(ms: f32) {
    if let Ok(mut st) = state().lock() {
        st.tracker.predict_secs = ms / 1000.0;
        st.tracker.refresh();
    }
}

pub fn add_source(kind: SourceKindWire, x: f32, y: f32, z: f32, gain: f32) -> Result<u32> {
    let mut st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
    let id = st.next_id;
    st.next_id += 1;
    st.engine
        .as_mut()
        .ok_or_else(|| anyhow!("engine not running"))?
        .add_source(kind.into(), Vec3::new(x, y, z), gain, id)
        .map_err(|e| anyhow!(e))?;
    Ok(id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_source_position(id: u32, x: f32, y: f32, z: f32) {
    if let Ok(mut st) = state().lock() {
        if let Some(e) = st.engine.as_mut() {
            e.set_source_pos(id, Vec3::new(x, y, z));
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_source_gain(id: u32, gain: f32) {
    if let Ok(mut st) = state().lock() {
        if let Some(e) = st.engine.as_mut() {
            e.set_source_gain(id, gain);
        }
    }
}

pub fn remove_source(id: u32) {
    if let Ok(mut st) = state().lock() {
        if let Some(e) = st.engine.as_mut() {
            e.remove_source(id);
        }
    }
}

/// S2 ear-test render: a source orbiting the head, written to a WAV file.
pub fn render_orbit_wav(
    path: String,
    kind: SourceKindWire,
    seconds: f32,
    radius_m: f32,
    elev_deg: f32,
    period_s: f32,
) -> Result<()> {
    render::render_orbit(&path, kind.into(), seconds, radius_m, elev_deg, period_s)
        .map_err(|e| anyhow!(e))
}

/// Static binaural render at a fixed direction.
pub fn render_static_wav(
    path: String,
    kind: SourceKindWire,
    seconds: f32,
    az_deg: f32,
    elev_deg: f32,
    dist_m: f32,
) -> Result<()> {
    render::render_static(&path, kind.into(), seconds, az_deg, elev_deg, dist_m)
        .map_err(|e| anyhow!(e))
}
