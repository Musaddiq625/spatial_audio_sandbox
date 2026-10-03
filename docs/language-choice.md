# Language Choice: Why Rust — and When C++ Would Be Better

An honest comparison of what language should own the DSP/audio layer of this
project — not advocacy, just engineering.

**TL;DR**: Rust and C++ are the only two languages that can correctly do this
job. Rust wins on correctness in the exact places this code is dangerous
(lock-free rings, seqlocks); C++ wins on DSP library ecosystem and hiring.
Performance is a wash. Replacing Rust with C++ is a lateral move; replacing it
with anything else is a regression.

---

## 1. What the language has to survive

The audio layer (`rust/engine/` — `sas_engine`) lives under the harshest
constraints in the app:

| Requirement | Reality |
|---|---|
| **Real-time callback** | An ~4.5 ms deadline, ~10,000+ times per second. A missed deadline = an audible click/dropout. |
| **Zero allocation on the audio thread** | Any `malloc` can block; any GC pause is fatal to the deadline. |
| **Lock-free concurrency** | UI commands enter via `rtrb` rings; head pose via an atomic seqlock. Mutexes on the audio path = priority inversion risk. |
| **Cross-compile to Android** | Must build an `.so` for arm64-v8a via the NDK. |
| **C ABI boundary** | Dart must call into it (via `flutter_rust_bridge` generating the FFI). |
| **Testable on desktop** | Same code must run `cargo test`/`rt_check`/`render_wavs` on macOS — and it does. |

This eliminates most languages before the comparison even starts.

## 2. The candidate pool

| Language | Verdict | One-line reason |
|---|---|---|
| **Rust** ✅ current | Right tool | Meets every constraint; safety exactly where this code is dangerous |
| **C++** | The only true peer | Same real-time capability; loses on correctness, wins on ecosystem |
| Zig | Viable, niche | Same perf class; weaker safety, younger toolchain, smaller DSP ecosystem |
| Kotlin/Java | ❌ | GC pauses in the callback = audible glitches; requires JNI anyway |
| Go | ❌ | GC **and** cgo call overhead ~100ns+ per call — structurally wrong |
| C#/.NET | ❌ | Wrong runtime for an Android audio callback; GC |
| Swift | ❌ | iOS-only — irrelevant to an Android-first app |
| JS/TS | ❌ | JIT/GC; cannot drive an Oboe/AAudio callback |
| C | ⚠️ | Technically works; strictly worse than C++ for an owned engine — more UB surface, fewer abstractions |

## 3. Rust vs C++ — the actual technical difference

Since C++ is the only real alternative, this is where the honest comparison lives.

### Where they are identical

- **Performance**: same compilers back ends (LLVM), same native code, same
  zero-cost abstractions. A convolution in Rust and C++ run at the same speed.
- **Real-time capability**: both can write allocation-free, lock-free code.
- **Android story**: both go through the NDK and produce `.so` files.
- **FFI cost**: both expose a C ABI; Dart's call overhead is identical.

Performance is **not** the differentiator — anyone claiming Rust is "faster
than C++" or vice versa for this workload is wrong. It's a wash.

### Where C++ genuinely wins

| Area | Why C++ is ahead |
|---|---|
| **DSP library ecosystem** | JUCE (full audio framework), KFR (SIMD DSP), rubberband (time-stretch), libpd, Faust-generated code, vendor codec/DSP libs — most are C++-only. Rust would need FFI wrappers for each. |
| **SIMD tooling** | Mature intrinsics + libraries + decades of DSP code optimized with them. Rust's `std::simd` is still nightly-only; stable Rust relies on autovectorization. For a scalar-friendly mixer like ours this is theoretical, but it matters if per-sample math ever gets heavy. |
| **Hiring** | C++ audio engineers exist in large numbers; Rust audio engineers are rare. Irrelevant for a solo project — very relevant if the team grows. |
| **Existing code reuse** | Virtually every mature spatial-audio/HRIR/HRTF codebase (e.g., BSP libraries, SOFA loaders, game audio engines) is C++. |

### Where Rust genuinely wins

| Area | Why Rust is ahead **for this codebase** |
|---|---|
| **Lock-free correctness** | `rtrb` rings + `PoseSlot` seqlock are the #1 Heisenbug source in audio apps. In C++, a data race, torn read, or use-after-free *compiles fine* and fails intermittently under load. In Rust, the compiler **refuses** the unsafe patterns — the seqlock can't be written incorrectly without `unsafe` blocks that stand out in review. |
| **FFI generation** | `flutter_rust_bridge` auto-generates the entire Dart↔Rust boundary from the API file. C++ would mean hand-written JNI + hand-written Dart FFI — hundreds of lines of manual glue. |
| **Dev loop already built** | `cargo test`, `cargo ndk`, workspace layout, `render_wavs`/`rt_check` examples — the whole verification harness exists and is one command. |
| **Memory safety without GC** | Rust is the *only* mainstream language offering C++ performance **and** compile-time memory safety. Every other safe language pays with a garbage collector. |
| **Sunk cost that isn't sunk** | The engine is written, tested, and working — switching languages rewrites the *correct* part of the app. |

### The honest verdict on Rust vs C++

**If starting from scratch**: it's a genuine coin flip — pick C++ if your
roadmap needs JUCE/Faust/vendor DSP libraries or you'll hire audio engineers;
pick Rust if you value correctness-in-lock-free-code and the FRB ecosystem.

**For this project**: Rust is ahead because the dangerous parts are already
written and verified, and the FFI/tooling investment is made. The C++
advantages are all *availability* advantages (libraries, people) — none are
*capability* advantages over the code that exists.

## 4. Edge cases — matched

| Scenario | What actually happens | Winner |
|---|---|---|
| **Seqlock torn-write race** | Pose struct overwritten mid-read → corrupted quat → audio snaps wildly | Rust (compile-time prevention vs C++'s "be careful") |
| **Ring overflow at 30Hz** | `rtrb` push on full ring → `Err` → drop; in C++ raw code, easy to write an unchecked write → silent heap corruption | Rust |
| **Future heavy SIMD mixing** | 16+ sources × HRIR convolution → scalar math insufficient | C++ (mature SIMD libs) — though Rust nightly `std::simd` or FFI to a C++ lib also works |
| **Need a C++-only lib** (Faust code, codec, spatialization lib) | Wrap via FFI **from Rust** — no port needed | Neither — the right move is wrapping, not rewriting |
| **Audio callback misses deadline** | Click/dropout — identical in both; caused by allocation/blocking, not language | Tie — discipline, not language |
| **Dart FFI glue maintenance** | Rust: regenerate bindings in one command. C++: hand-maintain JNI + FFI forever | Rust |
| **Desktop DSP testing** | Same code, `cargo test` — C++ needs a separate harness (doable, just not built) | Rust (as-built) |
| **Hire an audio dev** | Pool is C++-heavy | C++ |
| **Weekly intermittent crackle in production** | The classic lock-free race symptom — nearly impossible to reproduce in C++; in Rust that bug class is largely eliminated at compile time | Rust |
| **Battery/CPU efficiency** | Identical native code | Tie |

## 5. Plain English — for developers who don't know Rust

**Why can't we just use Kotlin/Java/Dart for the audio engine?**
Imagine a drummer keeping perfect 4.5 ms time, 10,000 times a second. A garbage
collector is a band manager who can tap the drummer's shoulder *at any moment*
and say "hold on, let me tidy up" — usually for a millisecond, occasionally for
ten. For most of your app that pause is invisible. Inside an audio callback,
every pause is an audible click. Audio engines must be written in languages
where nothing — no manager, no cleanup — can interrupt the drummer. That
narrows the field to exactly two: C++ and Rust.

**So what does Rust add that C++ doesn't?**
C++ trusts the programmer completely — like giving a professional chef a very
sharp knife and saying "be careful." Pros handle it, but everyone occasionally
bleeds, and in audio code the cuts are *invisible*: memory races that corrupt
data once in a thousand runs, on one device, under load, and can never be
reproduced in the debugger. Rust is the same knife **with a guard** — the
compiler physically won't let you write the dangerous pattern without
explicitly marking it `unsafe`, which acts as a giant red flag in code review.
You get C++'s speed with the dangerous parts fenced off at compile time.

**What's the trade-off?**
Rust's guard rails mean more fights with the compiler up front (the language
literally rejects code that compiles-fine-but-breaks-later in C++), a smaller
library ecosystem, and a smaller hiring pool. C++ has 40 years of audio
libraries; Rust has maybe 8 — though what exists (like `rustfft`, `rtrb`,
`cpal`, `oboe` bindings) covers this project's needs.

**The boundary in this app:**
```
Flutter/Dart  →  speaks commands & pose  →  Rust engine  →  audio hardware
   "what to play, where, how loud"           "the actual math, glitch-free"
```
Dart decides *what*; Rust decides *how*, on a deadline. Rust's job isn't to be
the whole app — it's to be the one layer where correctness-under-deadline is
non-negotiable.

## 6. When to revisit this choice

Rust stays the right answer **unless** one of these becomes true:

- A C++-only library becomes a hard requirement (then: wrap it via FFI, don't port)
- Per-sample CPU becomes the bottleneck and you need mature SIMD tooling
- The project grows to a team where C++ hiring reality outweighs the safety wins

Until then: the Rust layer isn't just adequate — it's the strongest part of
the architecture, because the places it would fail in any other language are
the places this app's correctness lives.
