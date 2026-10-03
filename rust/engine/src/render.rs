//! Offline renders to WAV — the S2 ear-test deliverable. Runs the exact same
//! Mixer as the realtime path, just driven by a loop instead of a callback.

use crate::math::Vec3;
use crate::mix::{standalone, Cmd, Mixer};
use crate::source::{self, SourceKind};
use crate::SAMPLE_RATE;
use std::f32::consts::PI;

fn write_wav(path: &str, sr: f32, samples: &[f32]) -> Result<(), hound::Error> {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: sr as u32,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut w = hound::WavWriter::create(path, spec)?;
    for &s in samples {
        w.write_sample(s)?;
    }
    w.finalize()
}

/// A source orbiting the listener once per `period_s` at `radius_m`,
/// `elev_deg` above the horizon. The classic externalization test.
pub fn render_orbit(
    path: &str,
    kind: SourceKind,
    seconds: f32,
    radius_m: f32,
    elev_deg: f32,
    period_s: f32,
) -> Result<(), String> {
    let (mut mix, _slot, mut tx) = standalone(SAMPLE_RATE);
    tx.push(Cmd::Add {
        id: 1,
        gen: source::make(kind),
        pos: Vec3::new(radius_m, 0.0, 0.0),
        gain: 1.0,
    })
    .map_err(|_| "cmd queue full")?;

    let total = (seconds * SAMPLE_RATE) as usize;
    let mut pcm = vec![0f32; total * 2];
    let block = 128;
    for start in (0..total).step_by(block) {
        let t = start as f32 / SAMPLE_RATE;
        let az = 2.0 * PI * t / period_s;
        let el = elev_deg.to_radians();
        let pos = Vec3::new(
            radius_m * el.cos() * az.cos(),
            radius_m * el.cos() * az.sin(),
            radius_m * el.sin(),
        );
        tx.push(Cmd::SetPos { id: 1, pos }).map_err(|_| "cmd queue full")?;
        let n = block.min(total - start);
        mix.process(&mut pcm[start * 2..(start + n) * 2]);
    }
    write_wav(path, SAMPLE_RATE, &pcm).map_err(|e| e.to_string())
}

/// Static binaural render: `seconds` of `kind` at fixed az/el/dist.
pub fn render_static(
    path: &str,
    kind: SourceKind,
    seconds: f32,
    az_deg: f32,
    elev_deg: f32,
    dist_m: f32,
) -> Result<(), String> {
    let (mut mix, _slot, mut tx) = standalone(SAMPLE_RATE);
    let az = az_deg.to_radians();
    let el = elev_deg.to_radians();
    tx.push(Cmd::Add {
        id: 1,
        gen: source::make(kind),
        pos: Vec3::new(
            dist_m * el.cos() * az.cos(),
            dist_m * el.cos() * az.sin(),
            dist_m * el.sin(),
        ),
        gain: 1.0,
    })
    .map_err(|_| "cmd queue full")?;

    let total = (seconds * SAMPLE_RATE) as usize;
    let mut pcm = vec![0f32; total * 2];
    for chunk in pcm.chunks_mut(256) {
        mix.process(chunk);
    }
    write_wav(path, SAMPLE_RATE, &pcm).map_err(|e| e.to_string())
}

#[allow(dead_code)]
fn _assert_mixer_send(_: Mixer) {}
