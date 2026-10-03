//! FRB surface for the engine. Thin wrappers over `sas_engine` — all DSP
//! lives in the pure-Rust crate.

use anyhow::{anyhow, Result};
use sas_engine::math::Vec3;
use sas_engine::pose::{PoseSlot, PoseTracker};
use sas_engine::rt::{Engine, EngineInfo};
use sas_engine::source::{FileSource, SourceKind};
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

/// What a file source resolved to — the engine id plus the real decoded
/// length (a generator may return shorter audio than requested).
pub struct FileSourceInfo {
    pub id: u32,
    pub duration_s: f32,
}

/// Play an audio file through the spatial pipeline. `bytes` is any
/// container symphonia probes (mp3/wav); decoding happens here on the
/// caller's thread — the audio callback only reads a mono buffer.
pub fn add_file_source(
    bytes: Vec<u8>,
    looping: bool,
    x: f32,
    y: f32,
    z: f32,
    gain: f32,
) -> Result<FileSourceInfo> {
    let mut st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
    let sr = st
        .engine
        .as_ref()
        .ok_or_else(|| anyhow!("engine not running"))?
        .info
        .sample_rate as f32;
    let id = st.next_id;
    st.next_id += 1;
    let pcm = decode_to_mono(&bytes, sr)?;
    let duration_s = pcm.len() as f32 / sr;
    st.engine
        .as_mut()
        .unwrap()
        .add_custom(
            Box::new(FileSource::new(pcm, looping)),
            Vec3::new(x, y, z),
            gain,
            id,
        )
        .map_err(|e| anyhow!(e))?;
    Ok(FileSourceInfo { id, duration_s })
}

/// Move a file source's playhead to `pos_s` seconds (clamped inside the
/// clip; seeking back into a finished one-shot replays it).
#[flutter_rust_bridge::frb(sync)]
pub fn seek_source(id: u32, pos_s: f32) {
    if let Ok(mut st) = state().lock() {
        if let Some(e) = st.engine.as_mut() {
            e.seek_source(id, pos_s);
        }
    }
}

/// Bytes (mp3/wav/…) → mono f32 at `dst_sr`, peak-normalized. Stereo is
/// downmixed — direction comes from the engine, not the file.
fn decode_to_mono(bytes: &[u8], dst_sr: f32) -> Result<Vec<f32>> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::DecoderOptions;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let mss = MediaSourceStream::new(
        Box::new(std::io::Cursor::new(bytes.to_vec())),
        Default::default(),
    );
    let probed = symphonia::default::get_probe()
        .format(&Hint::new(), mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| anyhow!("unrecognized audio: {e}"))?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| anyhow!("no audio track"))?;
    let src_sr = track
        .codec_params
        .sample_rate
        .ok_or_else(|| anyhow!("unknown sample rate"))? as f32;
    let track_id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| anyhow!("decoder init: {e}"))?;

    let mut mono = Vec::new();
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != track_id {
            continue;
        }
        if let Ok(decoded) = decoder.decode(&packet) {
            let spec = *decoded.spec();
            let ch = spec.channels.count().max(1);
            let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
            buf.copy_interleaved_ref(decoded);
            for frame in buf.samples().chunks(ch) {
                let sum: f32 = frame.iter().sum();
                mono.push(sum / ch as f32);
            }
        }
    }
    if mono.is_empty() {
        return Err(anyhow!("decoded zero samples"));
    }
    let out = if (src_sr - dst_sr).abs() < 1.0 {
        mono
    } else {
        resample_linear(&mono, src_sr, dst_sr)
    };
    Ok(normalize_peak(out, 0.8))
}

/// Linear interpolation — plenty for SFX/ambience; the spatial cues come
/// from the HRTF stage, not source fidelity.
fn resample_linear(src: &[f32], src_sr: f32, dst_sr: f32) -> Vec<f32> {
    let step = src_sr / dst_sr;
    let n = ((src.len() - 1) as f32 / step) as usize;
    let mut out = Vec::with_capacity(n + 1);
    for i in 0..=n {
        let pos = i as f32 * step;
        let i0 = pos.floor() as usize;
        let frac = pos - i0 as f32;
        let a = src[i0.min(src.len() - 1)];
        let b = src[(i0 + 1).min(src.len() - 1)];
        out.push(a + (b - a) * frac);
    }
    out
}

fn normalize_peak(mut buf: Vec<f32>, target: f32) -> Vec<f32> {
    let peak = buf.iter().fold(0.0f32, |m, &x| m.max(x.abs()));
    if peak > 1e-6 {
        let g = target / peak;
        for x in buf.iter_mut() {
            *x *= g;
        }
    }
    buf
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
