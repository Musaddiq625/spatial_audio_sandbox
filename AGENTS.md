# Spatial Audio Sandbox

Head-tracked binaural audio sandbox: Flutter UI + pure-Rust DSP engine.
Android-first (Pixel 6 Pro target), macOS used for DSP development.

## Layout

- `rust/` — FRB crate `rust_lib_spatial_audio_sandbox` (cdylib + staticlib).
  API surface in `rust/src/api/`; `src/api/engine.rs` is the engine bridge.
- `rust/engine/` — `sas_engine`: pure-Rust DSP crate, **no FRB deps**
  (tests run clean). Contains mixer, synthetic HRTF set, convolvers,
  procedural sources, pose seqlock, cpal + oboe IO backends.
- `lib/` — Dart UI, organized under `lib/src/` (entry: `lib/main.dart`).
  `src/listener/` = listener role: `sandbox_page.dart` (radar canvas +
  controls), `pose_channel.dart` (Android pose EventChannel ->
  `setHeadPose`), `beacon_tracker.dart` (aimed/acoustic tracking).
  `src/beacon/` = beacon role: `beacon_page.dart`.
  `src/link/` = shared link layer: `link.dart` (UDP), `net_state.dart`,
  `acoustic_bridge.dart` (chirp channel). `src/rust/` = FRB bindings.
- `android/.../MainActivity.kt` — game rotation vector + gyro sensor bridge.

## Commands

Use `fvm flutter` for all Flutter commands (Flutter 3.44.5 via FVM).

- Rust engine unit tests: `cd rust && cargo test -p sas_engine`
- Render S2 ear-test WAVs: `cargo run -p sas_engine --example render_wavs -- <outdir>`
- RT audio smoke test (desktop speakers): `cargo run -p sas_engine --example rt_check`
- Android Rust check: `cd rust && cargo ndk -t arm64-v8a check`
- Regenerate FRB bindings after editing `rust/src/api/`: `flutter_rust_bridge_codegen generate`
- macOS pods after changing the rust_builder podspec: `cd macos && rm Podfile.lock && pod install`

## Beacon link (branch `beacon`)

`lib/src/link/link.dart` — UDP port 47290. `SASB` announce / `SASH` listener reply /
`SAST` telemetry / `SASD` acoustic delay. `linked` is always *verified*: it
fires only after a `SASH` reply — manual `linkTo()` probes (~4 × 1 Hz), and
while linked a keepalive announce goes out every 4 s (>8 s silence = link
lost → auto-unlink). UDP send errors can CLOSE a RawDatagramSocket — both
sides rebind on `RawSocketEvent.closed` and keep a retry guard.

## Conventions

- Scene coords: +x front, +y left, +z up. Azimuth: 0=front, +90=left (SOFA).
- Audio callback is allocation-free: commands via `rtrb`, pose via seqlock.
- HRIR changes crossfade over 128 samples; first assignment must use
  `init_hrir` (no fade) or the click ILD inverts during the ramp.
