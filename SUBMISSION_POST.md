# Submission draft — Hacktoberfest Weekend Challenge: Build for a Friend

<!-- EDIT BEFORE POSTING:
     - Fill in the [friend] placeholders with a real person + real quote
       (or remove the hand-off paragraph and keep the honest framing).
     - Attach the demo video + 2–3 screenshots where marked.
     - Submit at https://dev.to/challenges/hf26 — Weekend Challenge only.
     - Add the template's required front-matter when posting on dev.to. -->

## What I Built

**Spatial Audio Sandbox** — describe a place in plain words and the app
builds it as a live binaural 3D scene on headphones. "I'm in the rain
and a bee is circling my head" becomes rain around you, a bee orbiting
your head, and thunder arriving behind you on cue — all rendered in
real time through a Rust HRTF mixer with head tracking, so the world
stays anchored when you turn.

The whole pipeline is visible while you listen: a radar shows every
source moving in 3D, stereo meters show which ear is actually receiving
energy, and a scene-score timeline lays out when each sound cues and
ends — so you can *see* the spatial audio in a screen recording.

## Who it's for

<!-- THE FRIEND — be specific and real. The rules require one real
     person. Fill in, e.g.: -->

My friend **[NAME]**, who **[real problem — e.g. "can't sleep in noisy
hotel rooms on work trips" / "misses the sound of home while studying
abroad"]**. [One honest sentence about what you made for them and why
spatial audio specifically helps them.]

### Hand-off

<!-- ONLY include this section if a real person actually tried it.
     Quote them verbatim with their permission. Otherwise delete the
     heading entirely — the rules make hand-off a bonus, not required. -->

I sent [NAME] the APK/video on [date]. Their reaction: "[real quote]".
What I changed after their feedback: [real change, if any].

## How the partner tech is load-bearing

**Gemma on Render** isn't a text box on top — it authors a constrained
*screenplay* JSON: sources, positions, movement verbs, start/end cues.
Every demo scene in the app exists because the model wrote it.

**ElevenLabs** generates each source's audio from its `sound` text; a
4-layer cache (memory → disk → bundled assets → API) means replays and
restarts never re-bill.

**The hard part — a deterministic compiler in between.** The model
hallucinates: invented sources ("a plane" in a cave prompt), motion
copied onto static objects, truncated JSON mid-stream. `SceneCompiler`
grounds every source against the actual prompt words, resolves "then
the fire goes out" into timed end-events, repairs truncation — and
reports all of it to the UI, so you can watch it fix the model.

## Demo

[VIDEO/GIF: prompt typed → pipeline strip ticks → radar fills with
labeled moving sources → meters show the bee crossing L→R → head turn
holds the scene in place]

[SCREENSHOT: radar with fire/kids/breeze badges + trails]
[SCREENSHOT: scene score lanes + pipeline strip]

## What went wrong (the honest bit)

- **The rear seam.** Moving a source behind your head produced an
  instant ~26 dB image swap between ears — two stacked discontinuities:
  the HRTF's ILD saturated at 90° and never returned to symmetric at
  dead-rear, and the width-exaggeration clamp pinned everything past
  ~92° to fixed points. Fixed in `cd28297` with a seam-sweep test that
  asserts <4 dB per 5° step.
- **A fade livelock.** `signum(+0.0) = +1.0` — the scene-fade
  oscillated between 0 and 0.001 forever, leaking the scene at ~0.1%
  under diagnostic tests. Found by measuring, not hearing.
- **Model reality.** The 1B screenplay model needs literal grounding —
  the compiler drops ~1 invented source per scene and that drop is now
  *visible* in the pipeline strip instead of silent.

## Testing status

29 Rust engine tests (including allocation-free audio-callback and
rear-seam regression tests), 66 Dart tests across compiler goldens,
radar painter, scene score, demo pack, and the calibration sheet.
Not yet handed to a non-developer — [update if that changes before the
deadline].

## AI disclosure

Built iteratively with an AI coding agent. The Rust mixer/HRTF core and
pose channel predate this window; the prompt→scene pipeline, compiler,
director, meters, all visualizations, and demo pack were built during
it — see git history.
