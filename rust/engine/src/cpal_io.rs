//! Desktop realtime IO via cpal — dev backend for the DSP engine
//! (same callback code path as the Android Oboe backend).

#![cfg(not(target_os = "android"))]

use crate::mix::Mixer;
use crate::pose::PoseSlot;
use crate::rt::{Engine, EngineInfo, StreamGuard};
use crate::SAMPLE_RATE;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::Arc;

struct Guard(#[allow(dead_code)] cpal::Stream);
impl StreamGuard for Guard {}
// cpal marks Stream !Send conservatively for backends where it isn't
// (some ALSA/Emscripten paths). On CoreAudio/AAudio/WASAPI owning and
// dropping a stream from another thread is fine — rodio does the same.
unsafe impl Send for Guard {}

pub fn start(pose: Arc<PoseSlot>) -> Result<Engine, String> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or_else(|| "no default output device".to_string())?;
    let supported = device
        .default_output_config()
        .map_err(|e| format!("no default output config: {e}"))?;

    let mut cfg: cpal::StreamConfig = supported.config();
    cfg.sample_rate = cpal::SampleRate(SAMPLE_RATE as u32);
    cfg.channels = 2;
    // Ask for the smallest stable buffer: fixed small buffer size.
    cfg.buffer_size = cpal::BufferSize::Fixed(256);

    let (mut mixer, cmd_tx, trash_rx) = Mixer::new(SAMPLE_RATE, pose.clone());

    let err_fn = |e| eprintln!("[sas_engine] cpal stream error: {e}");
    let stream = device
        .build_output_stream(
            &cfg,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                mixer.process(data);
            },
            err_fn,
            None,
        )
        .map_err(|e| format!("build_output_stream failed: {e}"))?;
    stream.play().map_err(|e| format!("stream play failed: {e}"))?;

    let info = EngineInfo {
        backend: "cpal".to_string(),
        api: format!("{:?}", host.id()),
        sample_rate: cfg.sample_rate.0,
        channels: cfg.channels as u32,
        frames_per_burst: match cfg.buffer_size {
            cpal::BufferSize::Fixed(n) => n as i32,
            cpal::BufferSize::Default => -1,
        },
        buffer_size_frames: match cfg.buffer_size {
            cpal::BufferSize::Fixed(n) => n as i32,
            cpal::BufferSize::Default => -1,
        },
        buffer_capacity_frames: -1,
        performance_mode: "n/a (desktop)".to_string(),
        sharing_mode: "n/a (desktop)".to_string(),
        latency_ms: None,
    };
    Ok(Engine::assemble(info, cmd_tx, trash_rx, pose, Box::new(Guard(stream))))
}
