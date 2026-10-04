# Spatial Audio Sandbox

Describe a place in plain words — *"I'm in the rain and a bee is
circling my head"* — and this app builds it as a live binaural 3D audio
scene on your headphones. A Gemma model plans the scene, a deterministic
compiler grounds it against your prompt, ElevenLabs generates each
sound, and a real-time Rust mixer renders every source through HRTF
convolution while head tracking keeps the world anchored as you turn.

Built for the DEV **Hacktoberfest Weekend Challenge: Build for a
Friend** — for anyone who wishes they were somewhere else: describe the
place, put on headphones, be there.

## The pipeline (visible in-app)

```
prompt ──► Gemma on Render ──► SceneCompiler ──► ElevenLabs ──► Rust HRTF
         screenplay JSON      grounding/timing   per-source      spatial mix
                              repairs            clips           + head pose
```

- **Gemma (hosted on Render)** writes a constrained *screenplay* JSON —
  sources, places, movement verbs, start/end cues. The schema is
  enforced, so the model chooses from enums rather than emitting
  geometry.
- **`SceneCompiler` (Dart)** splits your prompt into clauses, grounds
  every model source against the words you actually wrote (invented
  sources are dropped), resolves *"then the fire goes out"* into timed
  end events + transition one-shots, and repairs truncated JSON. Its
  work is reported in the UI pipeline strip — dropped sources,
  transitions, repairs, all visible.
- **ElevenLabs** turns each source's `sound` text into a clip
  (4-layer cache: memory → disk → bundled assets → API).
- **Rust engine** (`rust/engine`, crate `sas_engine`) mixes sources on a
  lock-free real-time callback — `rtrb` command queue, pose seqlock,
  synthetic HRTF with physically-modeled head shadow (ILD/ITD grow and
  collapse the way ears actually hear them), room reverb, and per-source
  level meters.

## What you see while you listen

The radar is built to make spatial audio legible *silently* — for
screenshots, screen recordings, and judges without headphones:

- **Source badges** — each source gets an icon + color (fire, bee,
  rain, kids…), not identical gray dots.
- **Radar chrome** — FRONT/BEHIND/L/R labels, range rings, a
  field-of-view cone, live heading readout, head-orientation wedge.
- **Trails & depth cues** — moving sources leave comet tails; sources
  behind render hollow; elevated ones ride stalks over floor shadows.
- **Real stereo meters** — L/R bars and an ILD readout driven by the
  engine's actual output (lock-free atomics, ~30 Hz), plus per-source
  halos that breathe with real loudness — a helicopter crossing visibly
  hands its energy from the L bar to the R bar.
- **Scene score** — one lane per source on the master timeline:
  cue-in, loop hatching, end-event flags, draggable playhead.
- **Pipeline strip** — the four stages above as live chips with times
  and counts; prompt words highlight in the color of the source they
  became; *view spec* shows the exact JSON Gemma wrote.

## Head tracking

- **Android** — game-rotation-vector sensor over an `EventChannel`;
  turn your phone and the scene stays put in the world.
- **macOS desktop** — drag the radar to rotate a virtual head.
- Modes: full 3D or yaw-only (`set_yaw_only`), auto-recenter on engine
  start / scene start, manual recenter button.

## Keyless demo

Three recorded Gemma runs ship in `lib/src/director/demo_pack.dart` and
seed the scene history on first launch (labeled `[recorded]`). They
play with **no Render endpoint and no ElevenLabs key** — each source
falls back to its procedural stand-in while radar, meters, motion,
score, and pipeline strip all work live.

To bundle *real* clips for a fully-offline demo: run a scene once with
a key, then copy the generated files from the app's `sfx_cache/` into
`assets/clips/` verbatim (filenames are already the cache's md5 scheme —
see `assets/clips/README.md`).

## Run it

```bash
# prerequisites: Flutter 3.44+ (fvm), Rust toolchain, cargo-ndk

fvm flutter pub get
flutter_rust_bridge_codegen generate   # if lib/src/rust/ is stale

# macOS (DSP dev path)
fvm flutter run -d macos

# Android (full experience: head tracking + device audio)
fvm flutter run -d <device>

# with live LLM + SFX
fvm flutter run \
  --dart-define=RENDER_BASE=https://<your-render-service>.onrender.com \
  --dart-define=ELEVENLABS_API_KEY=sk_...
```

> **Never commit keys.** `--dart-define` compiles the key into the
> binary — don't ship a keyed APK publicly, and rotate a key that has
> appeared in screenshots or logs.

## Tests

```bash
cd rust && cargo test -p sas_engine        # DSP engine unit tests
cd rust && cargo ndk -t arm64-v8a check    # Android audio backend
fvm flutter analyze && fvm flutter test    # Dart analysis + suite
```

## Honest limitations

- The HRTF is **synthetic** (parametric head-shadow + ITD model, not a
  measured SOFA set) — convincing left/right/front/back, less so for
  elevation and front/back confusion.
- Procedural stand-ins (`bee`, `rain`, `pad`, `tone`, `noise`) are
  placeholders until ElevenLabs clips land — with a key they upgrade
  in place.
- Gemma on Render takes tens of seconds for a spec; the UI streams the
  wait (elapsed time, received chars) rather than hiding it.
- The beacon/link subsystem (`SasLink`, UDP port 47290) is an earlier
  two-device experiment that remains in the Lab sheet — unrelated to
  the prompt-to-scene pipeline.

## AI assistance & prior work

Built iteratively with an AI coding agent (Devin). The Rust mixer/HRTF
core, pose channel, and beacon link existed before this submission
window; the prompt→scene pipeline, scene compiler, director, meters,
radar visualizations, calibration session, and demo pack were built
during it. See git history for the boundary.
