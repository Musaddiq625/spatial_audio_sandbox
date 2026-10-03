//! sas_engine — pure-Rust spatial audio engine core.
//!
//! No FFI deps in here: the Flutter bridge crate wraps this. Everything on the
//! audio hot path is allocation-free after startup.

pub mod math;
pub mod pose;
pub mod hrtf;
pub mod convolve;
pub mod source;
pub mod mix;
pub mod render;
pub mod rt;

#[cfg(not(target_os = "android"))]
pub mod cpal_io;
#[cfg(target_os = "android")]
pub mod oboe_io;

pub const SAMPLE_RATE: f32 = 48_000.0;
