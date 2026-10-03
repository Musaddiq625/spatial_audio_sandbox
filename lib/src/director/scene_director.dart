import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../rust/api/engine.dart';
import 'llm_client.dart';
import 'motion.dart';
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
    this.sound,
    this.loop = true,
    this.durationS = 6,
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

  /// Free-text audio description for the SFX generator. When set, the
  /// procedural [kind] plays instantly as a stand-in and is swapped for
  /// generated audio when the clip lands.
  String? sound;

  /// `loop:true` for continuous ambience beds; `false` for one-shot events.
  bool loop;

  /// Requested clip length — clamped to the SFX budget (≤12 s).
  double durationS;

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
  OrbitMotion({required this.radiusM, required this.periodS, this.phaseDeg = 0});
  double radiusM;
  double periodS;
  double phaseDeg;
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
  });

  /// (kind, x, y, z, gain, {label}) -> opaque page-side handle for the new
  /// source. The handle must resolve the live engine id (ids are
  /// re-assigned on engine restart). Returns null on failure.
  final Future<Object?> Function(
      SourceKindWire kind, Offset pos, double z, double gain,
      {String? label}) add;
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

  final _motion = MotionBank();
  final _owned = <Object>{};
  final _byName = <String, Object>{};
  SceneSpec? _lastSpec;
  bool _busy = false;

  bool get busy => _busy;
  SceneSpec? get lastSpec => _lastSpec;

  /// Pause/resume motion ticks — call on engine stop/start so radar dots
  /// freeze while the engine is off and resume on restart.
  void setMotionPaused(bool v) => _motion.paused = v;

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
      try {
        spec = parseSpec(raw);
      } on SpecException catch (e) {
        // One retry with the parse error fed back to the model.
        final raw2 = await llm.complete(
          _systemPrompt,
          '$p\n\n(previous output was invalid: ${e.message} — output the corrected JSON only)',
          jsonSchema: _specJsonSchema,
          onProgress: onProgress,
        );
        spec = parseSpec(raw2);
      }
      await apply(spec);
      debugPrint(
        '[director] spec applied: ${spec.sources.map((s) => '${s.name}(kind:${s.kind.name},sound:${s.sound},loop:${s.loop},dur:${s.durationS},az:${s.azDeg},dist:${s.distM},mot:${s.orbit != null ? 'orbit' : s.approach != null ? 'approach' : s.traverse != null ? 'traverse' : 'none'})').join(' | ')}',
      );
      return spec;
    } on SpecException catch (e) {
      debugPrint('[director] spec rejected (after retry): ${e.message}');
      onError('director: ${e.message}');
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
              : (s.orbit != null ? _orbitPos(s, 0) : s.pos2d);
      final key = await add(s.kind, start, s.z, s.gain, label: s.name);
      if (key == null) continue;
      _owned.add(key);
      _byName[s.name] = key;
      _motion.track(DirectedSource(key: key, spec: s, setPos: setPos));
      // Stand-in is already playing — the real clip upgrades it in flight.
      if (s.sound != null && sfxOk) unawaited(_genFor(s, key));
    }
  }

  /// Generate one source's clip, swap it in, and restart its motion so a
  /// traverse/orbit begins as the real audio lands — not at apply time.
  Future<void> _genFor(SpecSource s, Object key) async {
    onStatus?.call(s.name, SfxStatus.generating);
    debugPrint('[sfx] ${s.name}: generating "${s.sound}" (${s.durationS}s, loop=${s.loop})');
    try {
      final bytes = await sfx!.generate(
        s.sound!,
        durationSeconds: s.durationS,
        loop: s.loop,
      );
      if (!_owned.contains(key)) {
        debugPrint('[sfx] ${s.name}: clip landed but scene was cleared');
        return;
      }
      upgrade?.call(key, bytes, s.loop);
      _motion.restart(key);
      debugPrint('[sfx] ${s.name}: ${bytes.length}B — live');
      onStatus?.call(s.name, SfxStatus.ready);
      if (!s.loop) {
        // One-shot: the engine self-removes the finished source — drop
        // the dot shortly after playback ends.
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

  Offset _orbitPos(SpecSource s, double t) {
    final o = s.orbit!;
    final th = 2 * math.pi * t / o.periodS + o.phaseDeg * math.pi / 180;
    final el = s.elDeg * math.pi / 180;
    return Offset(
      o.radiusM * math.cos(el) * math.cos(th),
      o.radiusM * math.cos(el) * math.sin(th),
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
        if (s.orbit != null)
          'motion': {
            'orbit': {'radius': s.orbit!.radiusM, 'period_s': s.orbit!.periodS}
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
    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned.substring(start, end + 1));
    } catch (_) {
      throw SpecException('malformed JSON');
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
      if (sound != null && sound.isNotEmpty) s.sound = sound;
      if (e['loop'] is bool) s.loop = e['loop'] as bool;
      s.durationS = _clampNum(e['duration_s'], 0.5, 12, 6);
      final motion = e['motion'];
      if (motion is Map) {
        final o = motion['orbit'];
        if (o is Map) {
          s.orbit = OrbitMotion(
            radiusM: _clampNum(o['radius'], 0.3, 8, 0.6),
            periodS: _clampNum(o['period_s'], 4, 120, 8),
            phaseDeg: _clampNum(o['phase'], 0, 360, 0),
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
    return SceneSpec(sources);
  }

  static double _clampNum(Object? v, double lo, double hi, double dflt) {
    final n = (v is num) ? v.toDouble() : dflt;
    return n.clamp(lo, hi);
  }

  /// JSON schema for llama.cpp constrained decoding — the model cannot emit
  /// a `kind` outside the enum or malformed structure. Range clamps in
  /// [parseSpec] still apply for value sanity.
  static const _specJsonSchema = {
    'type': 'object',
    'properties': {
      'sources': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'kind': {
              'enum': ['bee', 'rain', 'pad', 'tone', 'noise'],
            },
            'az': {'type': 'number'},
            'el': {'type': 'number'},
            'dist': {'type': 'number'},
            'gain': {'type': 'number'},
            'sound': {'type': 'string'},
            'loop': {'type': 'boolean'},
            'duration_s': {'type': 'number'},
            'motion': {'type': 'object'},
          },
          'required': [
            'name', 'kind', 'sound', 'loop', 'duration_s',
            'az', 'el', 'dist', 'gain',
          ],
        },
      },
    },
    'required': ['sources'],
  };

  static const _systemPrompt = '''
You are the scene director for a binaural audio app. Turn the user's description into a JSON scene spec — output ONLY the JSON object, no prose.

Kinds: bee (any buzzing insect — fly, mosquito, wasp), rain (steady hiss+droplets, good surround bed), pad (warm slow chord), tone (pure sine), noise (static/wind/ocean/waterfall texture). Map fanciful requests to the nearest kind ("ocean"→noise, "campfire"→noise, "meditation"→pad).

Coordinates: az=0 front, +90 left, -90 right, ±180 behind. el=+deg above the head plane. dist in meters (0.3 close-up … 30 far). Max 8 sources. Orbit periods ≥4s or the spatial image smears. Words like "behind"/"left"/"above" must be reflected in az/el.

Per-source motion — whenever the user says a source orbits, approaches, flies past, or crosses space (left→right, front→behind, sweeping by), you MUST attach a "motion" object to that source: "motion":{"orbit":{"radius":m,"period_s":s}} for circling, "motion":{"approach":{"from_az":deg,"from_dist":m,"seconds":s}} for a source flying toward the listener, or "motion":{"traverse":{"from_az":deg,"to_az":deg,"dist":m,"seconds":s}} for a source crossing space. A source described as moving but left without "motion" is a bug — static sources have no "motion" key.

Every source MUST have "sound": a short literal audio description for a sound-effects generator ("campfire crackling on dry wood", "children playing outdoors", "dragon roar with heavy wing beats"). Never omit it. "loop":true for continuous ambience (beds, weather, crowds), false for one-shot events (a flyby, a roar, thunder). "duration_s": 4-10 for loops, 3-6 for one-shots.

Examples:
"rain all around, bee circling close in front" → {"sources":[{"name":"rain","kind":"rain","sound":"steady rain falling outdoors","loop":true,"duration_s":8,"az":0,"el":0,"dist":2.0,"gain":1.0},{"name":"bee","kind":"bee","sound":"bee buzzing","loop":true,"duration_s":6,"az":0,"el":0.2,"dist":0.5,"gain":1.0,"motion":{"orbit":{"radius":0.5,"period_s":6}}}]}
"wind howling behind me, a fly around my head" → {"sources":[{"name":"wind","kind":"noise","sound":"cold wind howling","loop":true,"duration_s":8,"az":180,"el":0,"dist":8.0,"gain":0.8},{"name":"fly","kind":"bee","sound":"fly buzzing close","loop":true,"duration_s":6,"az":0,"el":0.2,"dist":0.5,"gain":1.0,"motion":{"orbit":{"radius":0.4,"period_s":5}}}]}
"a dragon flying past me left to right, campfire in front" → {"sources":[{"name":"fire","kind":"noise","sound":"campfire crackling","loop":true,"duration_s":8,"az":0,"el":0,"dist":1.5,"gain":0.9},{"name":"dragon","kind":"noise","sound":"dragon roar with heavy wing beats","loop":false,"duration_s":6,"az":0,"el":10,"dist":2.5,"gain":1.0,"motion":{"traverse":{"from_az":-80,"to_az":80,"dist":2.5,"seconds":6}}}]}''';
}
