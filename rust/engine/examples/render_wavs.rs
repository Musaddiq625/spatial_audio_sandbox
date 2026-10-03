//! Render the S2 ear-test WAVs. Usage:
//!   cargo run -p sas_engine --example render_wavs -- <out_dir>
//! Listen on headphones — check for externalization + orbit direction.

use sas_engine::render::{render_orbit, render_static};
use sas_engine::source::SourceKind;

fn main() {
    let out = std::env::args().nth(1).unwrap_or_else(|| ".".to_string());
    std::fs::create_dir_all(&out).expect("create out dir");

    let jobs: Vec<(&str, Result<(), String>)> = vec![
        (
            "orbit_bee.wav",
            render_orbit(&format!("{out}/orbit_bee.wav"), SourceKind::Bee, 10.0, 1.5, 0.0, 6.0),
        ),
        (
            "orbit_noise.wav",
            render_orbit(&format!("{out}/orbit_noise.wav"), SourceKind::Noise, 10.0, 1.5, 15.0, 8.0),
        ),
        (
            "front_tone.wav",
            render_static(&format!("{out}/front_tone.wav"), SourceKind::Tone, 4.0, 0.0, 0.0, 1.5),
        ),
        (
            "rear_tone.wav",
            render_static(&format!("{out}/rear_tone.wav"), SourceKind::Tone, 4.0, 180.0, 0.0, 1.5),
        ),
        (
            "left_tone.wav",
            render_static(&format!("{out}/left_tone.wav"), SourceKind::Tone, 4.0, 90.0, 0.0, 1.5),
        ),
        (
            "elev_pad.wav",
            render_static(&format!("{out}/elev_pad.wav"), SourceKind::Pad, 6.0, 30.0, 45.0, 2.0),
        ),
        (
            "rain_left.wav",
            render_static(&format!("{out}/rain_left.wav"), SourceKind::Rain, 6.0, 60.0, 10.0, 4.0),
        ),
    ];

    let mut ok = true;
    for (name, res) in jobs {
        match res {
            Ok(()) => println!("wrote {name}"),
            Err(e) => {
                ok = false;
                eprintln!("FAILED {name}: {e}");
            }
        }
    }
    if !ok {
        std::process::exit(1);
    }
}
