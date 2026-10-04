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
    next_id: u32,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

/// The pose path gets its own locks: `set_head_pose` fires ~60 Hz from
/// the sensor bridge and must never queue behind an engine op or a
/// clip decode on the state mutex.
static POSE_SLOT: OnceLock<Arc<PoseSlot>> = OnceLock::new();
static TRACKER: OnceLock<Mutex<PoseTracker>> = OnceLock::new();

fn pose_slot() -> Arc<PoseSlot> {
    POSE_SLOT.get_or_init(|| Arc::new(PoseSlot::new())).clone()
}

fn tracker() -> &'static Mutex<PoseTracker> {
    TRACKER.get_or_init(|| Mutex::new(PoseTracker::new(pose_slot())))
}

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| Mutex::new(State { engine: None, next_id: 1 }))
}

// ── Clip cache ─────────────────────────────────────────────────────
// Decoded mono PCM at the engine sample rate, keyed by content hash.
// FileSource holds an Arc into this, so scrub-back, scene wraps, and
// engine restarts re-add clips without re-decoding — and a source drop
// never frees megabytes on the audio thread.

struct ClipCache {
    map: std::collections::HashMap<u64, std::sync::Arc<Vec<f32>>>,
    order: std::collections::VecDeque<u64>,
    bytes: usize,
}

static CLIP_CACHE: OnceLock<Mutex<ClipCache>> = OnceLock::new();
const CLIP_CACHE_MAX: usize = 64 << 20; // 64 MB of decoded PCM

fn clip_cache() -> &'static Mutex<ClipCache> {
    CLIP_CACHE.get_or_init(|| {
        Mutex::new(ClipCache {
            map: std::collections::HashMap::new(),
            order: std::collections::VecDeque::new(),
            bytes: 0,
        })
    })
}

fn clip_key(bytes: &[u8], sr: f32) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut h);
    sr.to_bits().hash(&mut h);
    h.finish()
}

/// Decode-or-fetch. The decode runs unlocked — only the map touch and
/// the insert take the cache mutex, for microseconds.
fn get_or_decode(bytes: &[u8], sr: f32) -> Result<std::sync::Arc<Vec<f32>>> {
    let key = clip_key(bytes, sr);
    {
        let c = clip_cache().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(hit) = c.map.get(&key) {
            return Ok(hit.clone());
        }
    }
    let t0 = std::time::Instant::now();
    let pcm = std::sync::Arc::new(decode_to_mono(bytes, sr)?);
    eprintln!(
        "[engine] decoded {}B -> {} samples in {:.1}ms",
        bytes.len(),
        pcm.len(),
        t0.elapsed().as_secs_f64() * 1000.0
    );
    let mut c = clip_cache().lock().unwrap_or_else(|e| e.into_inner());
    c.bytes += pcm.len() * 4;
    c.order.push_back(key);
    c.map.insert(key, pcm.clone());
    while c.bytes > CLIP_CACHE_MAX {
        match c.order.pop_front() {
            Some(k) => {
                if let Some(old) = c.map.remove(&k) {
                    c.bytes -= old.len() * 4;
                }
            }
            None => break,
        }
    }
    Ok(pcm)
}

/// Start the realtime engine (cpal on desktop, oboe on Android).
/// Returns the negotiated stream parameters — the S1 latency data.
pub fn engine_start() -> Result<EngineInfoWire> {
    let mut st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
    if st.engine.is_some() {
        let info: EngineInfoWire = st.engine.as_ref().unwrap().info.clone().into();
        return Ok(info);
    }
    let engine = Engine::start(pose_slot()).map_err(|e| anyhow!(e))?;
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
    if let Ok(mut t) = tracker().lock() {
        t.update(w, x, y, z, gx, gy, gz);
    }
}

/// Latch the current orientation as "forward".
#[flutter_rust_bridge::frb(sync)]
pub fn recenter() {
    if let Ok(mut t) = tracker().lock() {
        t.recenter();
    }
}

/// Prediction horizon in milliseconds (e.g. measured BT output latency).
#[flutter_rust_bridge::frb(sync)]
pub fn set_predict_ms(ms: f32) {
    if let Ok(mut t) = tracker().lock() {
        t.predict_secs = ms / 1000.0;
        t.refresh();
    }
}

/// L/R separation exaggeration: 1.0 = natural HRTF, up to 2.0.
/// Widens the rendered azimuth and deepens the far-ear shadow.
#[flutter_rust_bridge::frb(sync)]
pub fn set_spatial_width(w: f32) {
    if let Ok(mut st) = state().lock() {
        if let Some(e) = st.engine.as_mut() {
            e.set_spatial_width(w);
        }
    }
}

/// Live spatial tuning for the calibration panel: azimuth exaggeration
/// (0.4-2.0), reverb wet send (0-0.6), extra far-ear cut span (dB).
#[flutter_rust_bridge::frb(sync)]
pub fn set_spatial_params(width: f32, wet: f32, ild_db: f32) {
    if let Ok(mut st) = state().lock() {
        if let Some(e) = st.engine.as_mut() {
            e.set_spatial_params(width, wet, ild_db);
        }
    }
}

/// Restrict head tracking to yaw (heading about gravity): tilts and
/// in-hand rolls stop swinging the scene's azimuth. Toggleable live.
#[flutter_rust_bridge::frb(sync)]
pub fn set_yaw_only(yaw_only: bool) {
    if let Ok(mut t) = tracker().lock() {
        t.yaw_only = yaw_only;
        t.refresh();
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

/// Warm the decode cache for a generated clip so the later
/// `add_file_source` is a cache hit — call as soon as the clip bytes
/// land, before the source's cue arrives. Async (worker pool); no-op
/// while the engine is off.
pub fn prepare_file_source(bytes: Vec<u8>) -> Result<()> {
    let sr = {
        let st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
        st.engine.as_ref().map(|e| e.info.sample_rate as f32)
    };
    if let Some(sr) = sr {
        get_or_decode(&bytes, sr)?;
    }
    Ok(())
}

/// Play an audio file through the spatial pipeline. `bytes` is any
/// container symphonia probes (mp3/wav). Decode/resample runs OUTSIDE
/// the state lock and is cached — the lock is held only for id
/// allocation and the command push, so the 60 Hz pose and 30 Hz
/// position paths never stall behind an mp3 decode.
pub fn add_file_source(
    bytes: Vec<u8>,
    looping: bool,
    x: f32,
    y: f32,
    z: f32,
    gain: f32,
) -> Result<FileSourceInfo> {
    let (sr, id) = {
        let mut st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
        let sr = st
            .engine
            .as_ref()
            .ok_or_else(|| anyhow!("engine not running"))?
            .info
            .sample_rate as f32;
        let id = st.next_id;
        st.next_id += 1;
        (sr, id)
    };
    let pcm = get_or_decode(&bytes, sr)?;
    let duration_s = pcm.len() as f32 / sr;
    let mut st = state().lock().map_err(|_| anyhow!("state poisoned"))?;
    st.engine
        .as_mut()
        .ok_or_else(|| anyhow!("engine not running"))?
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
