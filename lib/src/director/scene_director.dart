import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../rust/api/engine.dart';
import 'llm_client.dart';
import 'motion.dart';
import 'scene_compiler.dart';
import 'sfx_client.dart';

/// Per-source SFX generation status, surfaced to the UI.
enum SfxStatus { generating, ready, failed }

/// A scene the director asked for: which sources, where, how they move.
class SpecSource {
  SpecSource({
    required this.name,
    required this.kind,
    this.azDeg = 0,
    this.elDeg = 0,
    this.distM = 1.5,
    this.gain = 0.9,
    this.orbit,
    this.approach,
    this.traverse,
    this.wander,
    this.sound,
    this.loop = true,
    this.durationS = 6,
    this.delayS = 0,
  });

  final String name;
  final SourceKindWire kind;
  double azDeg;
  double elDeg;
  double distM;
  double gain;
  OrbitMotion? orbit;
  ApproachMotion? approach;
  TraverseMotion? traverse;
  WanderMotion? wander;

  /// Free-text audio description for the SFX generator. When set, the
  /// procedural [kind] plays instantly as a stand-in and is swapped for
  /// generated audio when the clip lands.
  String? sound;

  /// `loop:true` for continuous ambience beds; `false` for one-shot events.
  bool loop;

  /// Requested clip length — clamped to the SFX budget (≤12 s).
  double durationS;

  /// Authored cue: seconds after scene start when this source becomes
  /// audible. 0 = plays immediately. The page keeps the dot pending
  /// (no engine source) until the scene clock reaches it.
  double delayS;

  /// Authored end: scene-time when the source stops sounding ("the
  /// fire goes out"). Null = never ends. The page fades and removes
  /// the engine source when the scene clock passes it.
  double? endS;

  /// Scene coords: +x front, +y left, +z up. Az 0 = front, +90 = left.
  Offset get pos2d {
    final az = azDeg * math.pi / 180;
    final el = elDeg * math.pi / 180;
    return Offset(
      distM * math.cos(el) * math.cos(az),
      distM * math.cos(el) * math.sin(az),
    );
  }

  double get z => distM * math.sin(elDeg * math.pi / 180);
}

class OrbitMotion {
  OrbitMotion({
    required this.radiusM,
    required this.periodS,
    this.phaseDeg = 0,
    this.centerAzDeg = 0,
    this.centerDistM = 0,
  });
  double radiusM;
  double periodS;
  double phaseDeg;

  /// Orbit center — defaults to the listener's head (0,0). An anchored
  /// orbit circles the anchor ("around the fire"), not the head.
  double centerAzDeg;
  double centerDistM;
}

class ApproachMotion {
  ApproachMotion({required this.fromAzDeg, required this.fromDistM, required this.seconds});
  double fromAzDeg;
  double fromDistM;
  double seconds;
}

/// Linear az crossing at fixed distance — "a dragon going left to right".
class TraverseMotion {
  TraverseMotion({
    required this.fromAzDeg,
    required this.toAzDeg,
    required this.distM,
    required this.seconds,
  });
  double fromAzDeg;
  double toAzDeg;
  double distM;
  double seconds;
}

class SceneSpec {
  SceneSpec(this.sources);
  final List<SpecSource> sources;

  /// Where the scene is set ("cave", "night market") — appended to
  /// generated sound prompts so clips match the environment.
  String? environment;

  /// What the compiler had to do to the model's screenplay — surfaced
  /// in the UI (pipeline strip) so repairs are visible, not just logs.
  final report = CompileReport();
}

/// Compiler diagnostics for one spec: which model-emitted sources were
/// dropped as ungrounded, which end events / transition one-shots were
/// scheduled, whether the screenplay JSON needed truncation repair, and
/// whether the zero-grounded keyword fallback fired.
class CompileReport {
  /// Names of sources dropped because nothing in the prompt named them.
  final List<String> dropped = [];

  /// "fire ends at 12s" — authored end events resolved to a source.
  final List<String> ended = [];

  /// "fire_end @ 12s" — transition one-shots inserted for end events.
  final List<String> transitions = [];

  /// The screenplay JSON was truncated mid-stream and repaired.
  bool repaired = false;

  /// Nothing grounded — the spec came from keyword fallback sources.
  bool fallback = false;

  /// One-line summary for the pipeline strip ("2 kept · 1 dropped ·
  /// 1 transition"); null when the report carries nothing notable.
  String? summary(int kept) {
    final parts = <String>['$kept kept'];
    if (dropped.isNotEmpty) parts.add('${dropped.length} dropped');
    if (transitions.isNotEmpty) {
      parts.add('${transitions.length} transition${transitions.length > 1 ? 's' : ''}');
    }
    if (ended.isNotEmpty) parts.add('${ended.length} end');
    if (repaired) parts.add('repaired');
    if (fallback) parts.add('fallback');
    return parts.join(' · ');
  }
}

class SpecException implements Exception {
  SpecException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Preset scenes — instant examples that need no model call.
const presetPrompts = <String, String>{
  'rain + bee orbit': '{"sources":['
      '{"name":"rain","kind":"rain","az":0,"el":0,"dist":2.0,"gain":0.8},'
      '{"name":"bee","kind":"bee","az":0,"el":10,"dist":0.6,"motion":{"orbit":{"radius":0.6,"period_s":6}}}'
      ']}',
  'pad behind': '{"sources":['
      '{"name":"pad","kind":"pad","az":180,"el":10,"dist":1.8,"gain":0.9},'
      '{"name":"tone","kind":"tone","az":-60,"el":0,"dist":1.2,"gain":0.5,'
      '"motion":{"approach":{"from_az":-60,"from_dist":4.0,"seconds":8}}}'
      ']}',
  'bee chase': '{"sources":['
      '{"name":"bee","kind":"bee","az":0,"el":0,"dist":0.5,'
      '"motion":{"orbit":{"radius":0.5,"period_s":5}}},'
      '{"name":"noise","kind":"noise","az":90,"el":20,"dist":2.5,"gain":0.4}'
      ']}',
};

/// Turns a validated spec into live sources. Engine calls are injected so
/// the radar dots live in the page's `_sources` list — engine restarts
/// re-create them for free.
class SceneDirector {
  SceneDirector({
    required this.add,
    required this.remove,
    required this.setPos,
    required this.onError,
    required this.llm,
    this.sfx,
    this.upgrade,
    this.onStatus,
    this.onSceneStart,
  });

  /// (kind, x, y, z, gain, {label, spec}) -> opaque page-side handle for
  /// the new source. The handle must resolve the live engine id (ids are
  /// re-assigned on engine restart). Returns null on failure. [spec]
  /// carries authored timing (delay_s) + estimated duration so the page
  /// can schedule the source's audible start on the scene clock.
  final Future<Object?> Function(
      SourceKindWire kind, Offset pos, double z, double gain,
      {String? label, SpecSource? spec}) add;
  final void Function(Object key) remove;
  final void Function(Object key, Offset pos, double z) setPos;
  final void Function(String msg) onError;
  final LlmClient llm;

  /// SFX generator — null or unconfigured means `sound` fields degrade to
  /// procedural stand-ins (still spatialized).
  final SfxClient? sfx;

  /// Swap a directed source's audio for generated clip bytes — called
  /// per-source as each generation lands.
  final void Function(Object key, Uint8List bytes, bool looping)? upgrade;

  /// Per-source generation status for the UI.
  final void Function(String name, SfxStatus status)? onStatus;

  /// Fired at the top of every [apply] — the page anchors its scene
  /// clock to this instant (same instant motion anchors use).
  final void Function(DateTime t0)? onSceneStart;

  final _motion = MotionBank();
  final _owned = <Object>{};
  final _byName = <String, Object>{};
  SceneSpec? _lastSpec;
  DateTime _applyT0 = DateTime.now();
  bool _busy = false;

  bool get busy => _busy;
  SceneSpec? get lastSpec => _lastSpec;

  /// Pause/resume motion ticks — call on engine stop/start so radar dots
  /// freeze while the engine is off and resume on restart.
  void setMotionPaused(bool v) => _motion.paused = v;

  /// Re-anchor every tracked source's motion to [sceneT] — the master
  /// seekbar scrubs the scene clock, so positions must follow the
  /// score, not wall time.
  void seekScene(double sceneT) => _motion.seekTo(sceneT);

  static const _kinds = {
    'bee': SourceKindWire.bee,
    'rain': SourceKindWire.rain,
    'pad': SourceKindWire.pad,
    'tone': SourceKindWire.tone,
    'noise': SourceKindWire.noise,
    // 'click' excluded: one-shot probe, not a soundscape element.
  };

  /// Returns the applied spec (for prompt-history caching), null on error.
  /// [capUserLen] enforces the 500-char user-prompt limit — refine() echoes
  /// the current spec back to the model and legitimately exceeds it.
  Future<SceneSpec?> describe(
    String prompt, {
    bool capUserLen = true,
    void Function(int chars)? onProgress,
  }) async {
    if (_busy) {
      debugPrint('[director] busy — dropped prompt: "${prompt.trim()}"');
      onError('scene director is busy — wait for the current prompt');
      return null;
    }
    final p = prompt.trim();
    if (p.isEmpty) return null;
    if (capUserLen && p.length > 500) {
      onError('keep it under 500 chars');
      return null;
    }
    debugPrint('[director] prompt: "$p"');
    _busy = true;
    try {
      final raw = await llm.complete(
        _systemPrompt,
        p,
        jsonSchema: _specJsonSchema,
        onProgress: onProgress,
      );
      SceneSpec spec;
      // Existing names ground refine() — a follow-up that doesn't
      // re-mention a source shouldn't drop it.
      final ground = _byName.keys.toList();
      try {
        spec = SceneCompiler.compile(
          SceneCompiler.parseScreenplay(raw),
          p,
          extraGround: ground,
        );
      } on SpecException catch (e) {
        // One retry with the parse error fed back to the model.
        final raw2 = await llm.complete(
          _systemPrompt,
          '$p\n\n(previous output was invalid: ${e.message} — output the corrected JSON only)',
          jsonSchema: _specJsonSchema,
          onProgress: onProgress,
        );
        spec = SceneCompiler.compile(
          SceneCompiler.parseScreenplay(raw2),
          p,
          extraGround: ground,
        );
      }
      await apply(spec);
      debugPrint(
        '[director] spec applied: ${spec.sources.map((s) => '${s.name}(kind:${s.kind.name},sound:${s.sound},loop:${s.loop},dur:${s.durationS},az:${s.azDeg},dist:${s.distM},mot:${s.orbit != null ? 'orbit' : s.approach != null ? 'approach' : s.traverse != null ? 'traverse' : 'none'})').join(' | ')}',
      );
      return spec;
    } on SpecException catch (e) {
      debugPrint('[director] spec rejected (after retry): ${e.message}');
      onError('director: ${e.message}');
    } on LlmOfflineException {
      debugPrint('[director] LLM unreachable — offline');
      onError('no internet — check your connection and retry');
    } catch (e, st) {
      debugPrint('[director] FAILED: $e\n$st');
      onError('director unreachable: $e');
    } finally {
      _busy = false;
    }
    return null;
  }

  /// Direct apply — used by preset chips (no model call).
  Future<void> applyJson(String json) async {
    try {
      await apply(parseSpec(json));
    } on SpecException catch (e) {
      debugPrint('[director] applyJson rejected: ${e.message}');
      onError(e.message);
    } catch (e) {
      debugPrint('[director] applyJson FAILED: $e');
      onError('apply failed: $e');
    }
  }

  Future<void> apply(SceneSpec spec) async {
    clear();
    _lastSpec = spec;
    _applyT0 = DateTime.now();
    onSceneStart?.call(_applyT0);
    final wantSfx = spec.sources.any((s) => s.sound != null);
    final sfxOk = wantSfx && (sfx?.configured ?? false);
    debugPrint(
      '[director] apply: ${spec.sources.length} sources, wantSfx=$wantSfx sfxConfigured=${sfx?.configured}',
    );
    if (wantSfx && !sfxOk) {
      onError('ELEVENLABS_API_KEY not set — procedural stand-ins only');
    }
    for (final s in spec.sources) {
      final start = s.approach != null
          ? Offset(
              s.approach!.fromDistM * math.cos(s.approach!.fromAzDeg * math.pi / 180),
              s.approach!.fromDistM * math.sin(s.approach!.fromAzDeg * math.pi / 180),
            )
          : s.traverse != null
              ? _traversePos(s, 0)
              : s.wander != null
                  ? _wanderPos(s, 0)
                  : (s.orbit != null ? _orbitPos(s, 0) : s.pos2d);
      final key = await add(s.kind, start, s.z, s.gain,
          label: s.name, spec: s);
      if (key == null) continue;
      _owned.add(key);
      _byName[s.name] = key;
      final ds = DirectedSource(key: key, spec: s, setPos: setPos);
      // Motion is anchored to the source's *audible* start — for a
      // delayed source the negative dt keeps traverse/approach parked
      // at their from-position until its cue arrives.
      ds.t0 = _applyT0.add(
        Duration(milliseconds: (s.delayS * 1000).round()),
      );
      _motion.track(ds);
      // Stand-in is already playing — the real clip upgrades it in flight.
      if (s.sound != null && sfxOk) unawaited(_genFor(s, key));
    }
  }

  /// Generate one source's clip, swap it in, and restart its motion so a
  /// traverse/orbit begins as the real audio lands — not at apply time.
  Future<void> _genFor(SpecSource s, Object key) async {
    onStatus?.call(s.name, SfxStatus.generating);
    // Environment context: "in a cave" reaches the sound generator —
    // a fire in a cave should sound different from a beach bonfire.
    final env = _lastSpec?.environment;
    final text =
        env == null ? s.sound! : '${s.sound}, ${_envText(env)}';
    debugPrint('[sfx] ${s.name}: generating "$text" (${s.durationS}s, loop=${s.loop})');
    try {
      final bytes = await sfx!.generate(
        text,
        durationSeconds: s.durationS,
        loop: s.loop,
      );
      if (!_owned.contains(key)) {
        debugPrint('[sfx] ${s.name}: clip landed but scene was cleared');
        return;
      }
      upgrade?.call(key, bytes, s.loop);
      // Motion re-anchors to when the real audio actually begins:
      // a clip landing early keeps its scheduled cue (delay_s), a
      // late clip starts fresh at land time.
      final scheduled =
          _applyT0.add(Duration(milliseconds: (s.delayS * 1000).round()));
      final now = DateTime.now();
      _motion.restartAt(key, now.isAfter(scheduled) ? now : scheduled);
      debugPrint('[sfx] ${s.name}: ${bytes.length}B — live');
      onStatus?.call(s.name, SfxStatus.ready);
      if (!s.loop && s.delayS == 0) {
        // One-shot in an untimed scene: the engine self-removes the
        // finished source — drop the dot shortly after playback ends.
        // Authored scenes (delay_s > 0) keep the dot so the master
        // seekbar can scrub back into its window and replay it.
        final holdMs = (s.durationS * 1000).round() + 1500;
        Future.delayed(Duration(milliseconds: holdMs), () {
          if (_owned.remove(key)) {
            _motion.untrack(key);
            remove(key);
          }
        });
      }
    } catch (e) {
      debugPrint('[sfx] ${s.name}: FAILED — $e');
      onStatus?.call(s.name, SfxStatus.failed);
      onError('sfx ${s.name}: $e');
    }
  }

  /// Environment → a short acoustic context appended to every SFX
  /// request. The cache key includes it, so the same "fire" in a cave
  /// and on a beach are different clips.
  static String _envText(String env) => switch (env.toLowerCase()) {
        'cave' || 'cavern' || 'tunnel' => 'inside a large cave, echoing',
        'forest' || 'woods' || 'jungle' => 'in a dense forest',
        'city' || 'street' || 'urban' || 'market' ||
        'night market' =>
          'on a busy city street',
        'beach' || 'ocean' || 'sea' || 'harbor' => 'on a beach by the ocean',
        'room' || 'house' || 'indoors' || 'hall' => 'indoors in a room',
        'mountain' || 'peak' || 'summit' => 'on an open mountainside',
        'desert' || 'dune' => 'in an open desert',
        _ => 'in a $env',
      };

  /// Follow-up prompt mutates the current spec instead of replacing it.
  Future<void> refine(String prompt) async {
    if (_lastSpec == null) {
      await describe(prompt);
      return;
    }
    final p = prompt.trim();
    if (p.isEmpty) return;
    if (p.length > 500) {
      onError('keep it under 500 chars');
      return;
    }
    final cur = const JsonEncoder.withIndent('').convert(
      specToJson(_lastSpec!),
    );
    await describe(
      '$p\n\ncurrent scene JSON (mutate it, keep unchanged fields): $cur',
      capUserLen: false,
    );
  }

  void clear() {
    for (final key in _owned) {
      remove(key);
    }
    reset();
  }

  /// Drop bookkeeping without engine calls — for when the page already
  /// removed the sources itself (Clear All, engine stop).
  void reset() {
    _owned.clear();
    _byName.clear();
    _motion.stopAll();
  }

  void dispose() => _motion.stopAll();

  Offset _wanderPos(SpecSource s, double t) {
    final w = s.wander!;
    final az = w.anchorAzDeg * math.pi / 180;
    final el = w.anchorElDeg * math.pi / 180;
    return Offset(
      w.anchorDistM * math.cos(el) * math.cos(az),
      w.anchorDistM * math.cos(el) * math.sin(az),
    );
  }

  Offset _orbitPos(SpecSource s, double t) {
    final o = s.orbit!;
    final th = 2 * math.pi * t / o.periodS + o.phaseDeg * math.pi / 180;
    final el = s.elDeg * math.pi / 180;
    final cx = o.centerDistM * math.cos(o.centerAzDeg * math.pi / 180);
    final cy = o.centerDistM * math.sin(o.centerAzDeg * math.pi / 180);
    return Offset(
      cx + o.radiusM * math.cos(el) * math.cos(th),
      cy + o.radiusM * math.cos(el) * math.sin(th),
    );
  }

  Offset _traversePos(SpecSource s, double t) {
    final tr = s.traverse!;
    final k = (t / tr.seconds).clamp(0.0, 1.0);
    final az =
        (tr.fromAzDeg + (tr.toAzDeg - tr.fromAzDeg) * k) * math.pi / 180;
    return Offset(tr.distM * math.cos(az), tr.distM * math.sin(az));
  }

  /// Spec → JSON map; round-trips through [parseSpec]. Used by prompt
  /// history persistence and by refine()'s "current scene" echo.
  static Map<String, Object?> specToJson(SceneSpec spec) => {
        if (spec.environment != null) 'environment': spec.environment,
        'sources': spec.sources.map(_sourceJson).toList(),
      };

  static Map<String, Object?> _sourceJson(SpecSource s) => {
        'name': s.name,
        'kind': _kinds.entries.firstWhere((e) => e.value == s.kind).key,
        'az': s.azDeg,
        'el': s.elDeg,
        'dist': s.distM,
        'gain': s.gain,
        if (s.sound != null) 'sound': s.sound,
        'loop': s.loop,
        'duration_s': s.durationS,
        'delay_s': s.delayS,
        if (s.endS != null) 'end_s': s.endS,
        if (s.orbit != null)
          'motion': {
            'orbit': {
              'radius': s.orbit!.radiusM,
              'period_s': s.orbit!.periodS,
              if (s.orbit!.centerDistM != 0)
                'center_az': s.orbit!.centerAzDeg,
              if (s.orbit!.centerDistM != 0)
                'center_dist': s.orbit!.centerDistM,
            }
          }
        else if (s.wander != null)
          'motion': {
            'wander': {
              'anchor_az': s.wander!.anchorAzDeg,
              'anchor_el': s.wander!.anchorElDeg,
              'anchor_dist': s.wander!.anchorDistM,
              'az_span': s.wander!.azSpanDeg,
              'dist_span': s.wander!.distSpanM,
              'period_s': s.wander!.periodS,
            }
          }
        else if (s.approach != null)
          'motion': {
            'approach': {
              'from_az': s.approach!.fromAzDeg,
              'from_dist': s.approach!.fromDistM,
              'seconds': s.approach!.seconds
            }
          }
        else if (s.traverse != null)
          'motion': {
            'traverse': {
              'from_az': s.traverse!.fromAzDeg,
              'to_az': s.traverse!.toAzDeg,
              'dist': s.traverse!.distM,
              'seconds': s.traverse!.seconds
            }
          },
      };

  /// Parse + clamp a spec JSON string. Throws [SpecException] on anything
  /// unusable; out-of-range values are clamped, not rejected.
  static SceneSpec parseSpec(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'^```(?:json)?\s*|\s*```$'), '');
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw SpecException('no JSON object in output');
    }
    Object? decoded;
    var slice = cleaned.substring(start, end + 1);
    try {
      decoded = jsonDecode(slice);
    } catch (_) {
      // Truncated output repair: cut at the last complete source object
      // (depth returns to 2 — inside the sources array) and close it.
      var depth = 0, lastGood = -1;
      var inStr = false, esc = false;
      for (var i = 0; i < slice.length; i++) {
        final ch = slice[i];
        if (esc) {
          esc = false;
          continue;
        }
        if (ch == '\\') {
          if (inStr) esc = true;
          continue;
        }
        if (ch == '"') {
          inStr = !inStr;
          continue;
        }
        if (inStr) continue;
        if (ch == '{' || ch == '[') depth++;
        if (ch == '}' || ch == ']') {
          depth--;
          if (depth == 2 && ch == '}') lastGood = i;
        }
      }
      if (lastGood < 0) throw SpecException('malformed JSON');
      final repaired = '${slice.substring(0, lastGood + 1)}]}';
      try {
        decoded = jsonDecode(repaired);
        debugPrint('[director] repaired truncated JSON (kept sources before cutoff)');
      } catch (_) {
        throw SpecException('malformed JSON');
      }
    }
    if (decoded is! Map || decoded['sources'] is! List) {
      throw SpecException('missing "sources" array');
    }
    final list = (decoded['sources'] as List);
    if (list.isEmpty) throw SpecException('empty scene');
    if (list.length > 8) throw SpecException('too many sources (max 8)');

    final sources = <SpecSource>[];
    final seenNames = <String>{};
    for (final (i, e) in list.indexed) {
      if (e is! Map) throw SpecException('source $i is not an object');
      final kindName = (e['kind'] as String?)?.toLowerCase();
      final kind = _kinds[kindName];
      if (kind == null) {
        throw SpecException('unknown kind "${e['kind']}" (use: ${_kinds.keys.join(', ')})');
      }
      var name = (e['name'] as String?)?.trim().isNotEmpty == true
          ? (e['name'] as String).trim()
          : '$kindName$i';
      while (!seenNames.add(name)) {
        name = '${name}_'; // duplicate names — suffix to keep them distinct
      }
      final s = SpecSource(
        name: name,
        kind: kind,
        azDeg: _clampNum(e['az'], -180, 180, 0),
        elDeg: _clampNum(e['el'], -90, 90, 0),
        distM: _clampNum(e['dist'], 0.3, 30, 1.5),
        gain: _clampNum(e['gain'], 0, 1.5, 0.9),
      );
      final sound = (e['sound'] as String?)?.trim();
      // Garbage guard: a derailed generation can emit junk like "]" —
      // no letters means no EL call, the source degrades to procedural.
      if (sound != null &&
          sound.length >= 2 &&
          RegExp(r'[a-zA-Z]').hasMatch(sound)) {
        s.sound = sound;
      }
      if (e['loop'] is bool) s.loop = e['loop'] as bool;
      s.durationS = _clampNum(e['duration_s'], 0.5, 12, 6);
      s.delayS = _clampNum(e['delay_s'], 0, 120, 0);
      final endS = e['end_s'];
      if (endS is num) s.endS = endS.toDouble();
      final motion = e['motion'];
      if (motion is Map) {
        final o = motion['orbit'];
        if (o is Map) {
          s.orbit = OrbitMotion(
            radiusM: _clampNum(o['radius'], 0.3, 8, 0.6),
            periodS: _clampNum(o['period_s'], 4, 120, 8),
            phaseDeg: _clampNum(o['phase'], 0, 360, 0),
            centerAzDeg: _clampNum(o['center_az'], -180, 180, 0),
            centerDistM: _clampNum(o['center_dist'], 0, 30, 0),
          );
        }
        final w = motion['wander'];
        if (w is Map) {
          s.wander = WanderMotion(
            anchorAzDeg: _clampNum(w['anchor_az'], -180, 180, s.azDeg),
            anchorElDeg: _clampNum(w['anchor_el'], -90, 90, s.elDeg),
            anchorDistM: _clampNum(w['anchor_dist'], 0.3, 30, s.distM),
            azSpanDeg: _clampNum(w['az_span'], 0, 90, 30),
            distSpanM: _clampNum(w['dist_span'], 0, 5, 0.4),
            periodS: _clampNum(w['period_s'], 2, 60, 7),
          );
        }
        final a = motion['approach'];
        if (a is Map) {
          s.approach = ApproachMotion(
            fromAzDeg: _clampNum(a['from_az'], -180, 180, s.azDeg),
            fromDistM: _clampNum(a['from_dist'], 0.3, 30, 4),
            seconds: _clampNum(a['seconds'], 2, 30, 8),
          );
        }
        final tr = motion['traverse'];
        if (tr is Map) {
          s.traverse = TraverseMotion(
            fromAzDeg: _clampNum(tr['from_az'], -180, 180, s.azDeg),
            toAzDeg: _clampNum(tr['to_az'], -180, 180, s.azDeg),
            distM: _clampNum(tr['dist'], 0.3, 30, s.distM),
            seconds: _clampNum(tr['seconds'], 2, 30, 8),
          );
        }
      }
      sources.add(s);
    }
    final spec = SceneSpec(sources);
    final env = decoded['environment'];
    if (env is String && env.trim().isNotEmpty) {
      spec.environment = env.trim();
    }
    return spec;
  }

  static double _clampNum(Object? v, double lo, double hi, double dflt) {
    final n = (v is num) ? v.toDouble() : dflt;
    return n.clamp(lo, hi);
  }

  /// JSON schema for llama.cpp constrained decoding — a "screenplay"
  /// of fixed choices. The model picks from enums, so it cannot emit
  /// nonsense azimuths, copy motion onto static sources, or produce
  /// malformed structure. The compiler turns choices into geometry
  /// and verifies each source against the prompt.
  /// Public for tool/eval_prompts.dart — the live-check harness must
  /// use the exact production schema, not a copy that can drift.
  static const specJsonSchema = _specJsonSchema;
  static const systemPrompt = _systemPrompt;

  static const _specJsonSchema = {
    'type': 'object',
    'properties': {
      'environment': {'type': 'string'},
      'sources': {
        'type': 'array',
        'maxItems': 10,
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'sound': {'type': 'string'},
            'role': {
              'enum': [
                'ambience', 'object', 'creature', 'person', 'vehicle',
                'weather', 'event',
              ],
            },
            'place': {
              'enum': [
                'front', 'front_left', 'left', 'back_left', 'behind',
                'back_right', 'right', 'front_right', 'above', 'around',
              ],
            },
            'distance': {'enum': ['close', 'near', 'far']},
            'movement': {
              'enum': [
                'still', 'wander', 'circle', 'approach',
                'pass_left_to_right', 'pass_right_to_left',
                'pass_overhead',
              ],
            },
            'start': {'enum': ['beginning', 'after_seconds', 'later']},
            'start_s': {'type': 'number'},
            'ends': {'enum': ['never', 'after_seconds', 'with_event']},
            'end_s': {'type': 'number'},
            'loop': {'type': 'boolean'},
          },
          'required': [
            'name', 'sound', 'role', 'place', 'distance', 'movement',
            'start', 'ends', 'loop',
          ],
        },
      },
    },
    'required': ['sources'],
  };

  static const _systemPrompt = '''
You are the scene director for a binaural audio app. Turn the user's description into a JSON screenplay — output ONLY the JSON object, no prose.

List every sound the user describes — ONLY sounds they describe, never invented ones. Name each source after the thing making the sound ("dragon", "kids"), never a type word.

Fields per source:
- "sound": a short literal description for a sound-effects generator ("campfire crackling on dry wood", "children playing outdoors").
- "role": ambience (weather or background beds), object (things — fire, clock, radio), creature, person, vehicle, weather, event (a one-shot occurrence — an impact, a roar, or a transition like "the fire goes out").
- "place": front, front_left, left, back_left, behind, back_right, right, front_right, above, or around (all around the listener). Match the user's spatial words exactly.
- "distance": close (arm's reach), near (a few steps away), or far (across the space).
- "movement": still unless the user says it moves — wander (moving about near its spot), circle (circling), approach (coming closer), pass_left_to_right, pass_right_to_left, or pass_overhead.
- "start": beginning, later (an unspecified later time), or after_seconds with "start_s" (the user gave an exact time).
- "ends": never, after_seconds with "end_s", or with_event (the user says it goes out, dies, or stops).
- "loop": true for continuous sounds, false for one-shot events.

Also output "environment": where the scene is set ("cave", "forest", "night market") — one or two words.

Examples:
"in a harbor: gulls overhead, a foghorn far behind me, rope creaking close to my left" → {"environment":"harbor","sources":[{"name":"gulls","sound":"seagulls calling","role":"creature","place":"above","distance":"far","movement":"still","start":"beginning","ends":"never","loop":true},{"name":"foghorn","sound":"deep ship foghorn blowing","role":"object","place":"behind","distance":"far","movement":"still","start":"beginning","ends":"never","loop":false},{"name":"rope","sound":"thick rope creaking under tension","role":"object","place":"left","distance":"close","movement":"still","start":"beginning","ends":"never","loop":true}]}
"at a night market, crowd chatter all around, later a bell rings, then a scooter passes left to right" → {"environment":"night market","sources":[{"name":"crowd","sound":"market crowd chatter","role":"ambience","place":"around","distance":"near","movement":"still","start":"beginning","ends":"never","loop":true},{"name":"bell","sound":"small brass bell ringing twice","role":"event","place":"right","distance":"near","movement":"still","start":"later","ends":"never","loop":false},{"name":"scooter","sound":"scooter engine passing by","role":"vehicle","place":"left","distance":"near","movement":"pass_left_to_right","start":"later","ends":"never","loop":false}]}
"beside a waterfall, after 4 seconds thunder cracks above, and the radio fades out" → {"environment":"waterfall","sources":[{"name":"waterfall","sound":"waterfall rushing over rocks","role":"weather","place":"around","distance":"far","movement":"still","start":"beginning","ends":"never","loop":true},{"name":"thunder","sound":"thunder crack rolling","role":"event","place":"above","distance":"far","movement":"still","start":"after_seconds","start_s":4,"ends":"never","loop":false},{"name":"radio","sound":"old radio static and music","role":"object","place":"front","distance":"near","movement":"still","start":"beginning","ends":"with_event","loop":true}]}''';
}
