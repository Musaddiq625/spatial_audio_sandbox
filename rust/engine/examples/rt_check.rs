//! Realtime smoke test: starts the engine, plays a tone to the left of the
//! listener for a couple of seconds, prints negotiated stream params.
//!   cargo run -p sas_engine --example rt_check

use sas_engine::math::Vec3;
use sas_engine::pose::PoseSlot;
use sas_engine::rt::Engine;
use sas_engine::source::SourceKind;
use std::sync::Arc;
use std::thread::sleep;
use std::time::Duration;

fn main() {
    let mut engine = Engine::start(Arc::new(PoseSlot::new())).expect("engine start failed");
    println!("engine info: {:?}", engine.info);
    engine
        .add_source(SourceKind::Tone, Vec3::new(0.5, 1.5, 0.0), 0.5, 1)
        .expect("add source");
    engine
        .add_source(SourceKind::Bee, Vec3::new(1.0, -1.0, 0.0), 0.7, 2)
        .expect("add source");
    println!("playing 3s: tone left, bee right...");
    sleep(Duration::from_secs(3));
    println!("done");
}
