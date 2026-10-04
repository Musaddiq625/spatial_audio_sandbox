//! Android realtime IO via the `oboe` crate (safe bindings to Google's Oboe
//! → AAudio low-latency path). This is the S1 spike target.

#![cfg(target_os = "android")]

use crate::mix::Mixer;
use crate::pose::PoseSlot;
use crate::rt::{Engine, EngineInfo, StreamGuard};
use crate::SAMPLE_RATE;
use oboe::{
    AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioStreamAsync,
    AudioStreamBase, AudioStreamBuilder, AudioStreamSafe, DataCallbackResult,
    Output, PerformanceMode, SharingMode, Stereo,
};
use std::sync::Arc;

struct Guard {
    stream: AudioStreamAsync<Output, Cb>,
}
// Stream is stopped/closed on drop.
impl StreamGuard for Guard {
    fn latency_ms(&mut self) -> Option<f64> {
        self.stream.calculate_latency_millis().ok()
    }
}
unsafe impl Send for Guard {}

struct Cb {
    mixer: Mixer,
}

impl AudioOutputCallback for Cb {
    type FrameType = (f32, Stereo);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        // (f32, f32) frames are contiguous — reinterpret as interleaved stereo.
        let out: &mut [f32] = unsafe {
            std::slice::from_raw_parts_mut(audio_data.as_mut_ptr() as *mut f32, audio_data.len() * 2)
        };
        self.mixer.process(out);
        DataCallbackResult::Continue
    }
}

pub fn start(pose: Arc<PoseSlot>) -> Result<Engine, String> {
    let (mixer, cmd_tx, trash_rx, diag_status) = Mixer::new(SAMPLE_RATE, pose.clone());

    let mut stream = AudioStreamBuilder::default()
        .set_output()
        .set_stereo()
        .set_f32()
        .set_sample_rate(SAMPLE_RATE as i32)
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_sharing_mode(SharingMode::Exclusive)
        .set_callback(Cb { mixer })
        .open_stream()
        .map_err(|e| format!("oboe open_stream failed: {e:?}"))?;

    // Shrink the buffer toward the hardware burst size — the lowest stable
    // latency this stream can offer.
    let burst = stream.get_frames_per_burst();
    if burst > 0 {
        let _ = stream.set_buffer_size_in_frames(burst * 2);
    }

    let info = EngineInfo {
        backend: "oboe".to_string(),
        api: format!("{:?}", stream.get_audio_api()),
        sample_rate: stream.get_sample_rate() as u32,
        channels: stream.get_channel_count() as u32,
        frames_per_burst: stream.get_frames_per_burst(),
        buffer_size_frames: stream.get_buffer_size_in_frames(),
        buffer_capacity_frames: stream.get_buffer_capacity_in_frames(),
        performance_mode: format!("{:?}", stream.get_performance_mode()),
        sharing_mode: format!("{:?}", stream.get_sharing_mode()),
        latency_ms: stream.calculate_latency_millis().ok(),
    };

    stream.request_start().map_err(|e| format!("oboe start failed: {e:?}"))?;
    Ok(Engine::assemble(info, cmd_tx, trash_rx, diag_status, pose, Box::new(Guard { stream })))
}
