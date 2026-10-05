---
title: I told an AI "put me in the rain with a bee circling my head" — and heard it orbit my ears
published: true
description: Natural-language prompts become live binaural scenes — Flutter + Rust HRTF engine, Gemma-3-1B on Render, ElevenLabs audio.
tags: devchallenge, weekendchallenge, hf26challenge
---

*This is a submission for the [Hacktoberfest Weekend Challenge: Build for a Friend](https://dev.to/challenges/hacktoberfest-weekend-2026-10-01)*

*Spatial Audio Sandbox — describe a scene, hear it in 3D*

*Flutter + Rust HRTF engine · Gemma-3-1B on Render · ElevenLabs · head-tracked on Android + macOS*

## What I Built

**Spatial (3D) Audio Sandbox** — describe a place in plain words and the app builds it
as a live binaural 3D scene on your headphones. "I'm in the rain and a bee is
circling my head" becomes rain around you, a bee orbiting your head, and thunder
arriving behind you on cue — rendered in real time through a Rust HRTF mixer
with head tracking, so the world stays anchored when you turn.

I built it for a friend — and for anyone who can describe a place. Whatever
scene he imagines is the scene he gets: rain to sleep to, a forest to focus
in, a city he misses. He writes it; it plays around him.

The whole pipeline is visible while you listen: a radar shows every source
moving in 3D, stereo meters show which ear is receiving energy, and a
scene-score timeline lays out when each sound cues and ends — you can *see*
the spatial audio in a screen recording.

## Demo
▶ Watch the demo video (Google Drive)
{% embed https://drive.google.com/file/d/1dOTja8ntQY8rZTfu22VS-nfiofh3jHgH/view %}

Headphones recommended — the video captures the binaural mix, so the bee
actually circles your ears if you're wearing earbuds.

## Code

{% github Musaddiq625/spatial_audio_sandbox %}

Flutter UI + pure-Rust DSP engine bridged with flutter_rust_bridge. Android and
macOS. MIT. Three recorded Gemma scenes are bundled, so the repo demo plays
with no API keys.

## How I Built It

The pipeline: **prompt → Gemma on Render → SceneCompiler → ElevenLabs → Rust HRTF**.

- **Gemma-3-1B-it (Q4_K_M, ctx 4096)** served by llama.cpp in Docker on Render's
  2 GB standard plan — weights baked into the image at build time. It authors a
  constrained *screenplay* JSON: sources, positions, movement verbs, end cues.
- **`SceneCompiler` (Dart)** is the part I'm proudest of — the model
  hallucinates (it invented "a plane" in a cave prompt), so a deterministic
  pass grounds every source against the prompt's actual words, drops invented
  ones, resolves "then the fire goes out" into timed end events, and repairs
  truncated JSON. Its drops and repairs are visible in the UI pipeline strip.
- **ElevenLabs** generates each source's clip; a 4-layer cache (memory → disk →
  bundled assets → API) means replays never re-bill.
- **Rust engine** mixes on an allocation-free, lock-free audio callback —
  rtrb command queue, pose seqlock, synthetic HRTF with physically-modeled head
  shadow. Because a GC pause in the callback is an audible click.

## Why Does Open Innovation Matter?

Every load-bearing piece is open or open-weight. The model weights are the
portable part: the same Dockerfile line that pulls `gemma-3-1b-it` could pull
any GGUF — the app doesn't care whose checkpoint writes the screenplay JSON.
On a closed API that schema would be hostage to a vendor, every scene would
bill per call, and "it still works offline" would be impossible. Here the
keyless demo path runs end-to-end without keys.

## Prize Categories

- **Best Use of Gemma** — the scene's author is gemma-3-1b-it, open weights served
  on my own endpoint.
- **Best Use of Render** — Render is the inference host (Docker service running
  llama.cpp).
- **Best Use of ElevenLabs** — every generated source's audio comes from the SFX
  API.

Built with ❤️ by Musaddiq625