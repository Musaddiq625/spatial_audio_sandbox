import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/director/scene_director.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

void main() {
  test('parses a full spec with orbit', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"name":"rain","kind":"rain","az":0,"dist":2},'
        '{"name":"bee","kind":"bee","az":0,"dist":0.5,'
        '"motion":{"orbit":{"radius":0.5,"period_s":6}}}]}');
    expect(s.sources.length, 2);
    final bee = s.sources[1];
    expect(bee.kind, SourceKindWire.bee);
    expect(bee.orbit?.radiusM, 0.5);
  });

  test('clamps out-of-range values', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"pad","az":999,"dist":0.01,"gain":99,"el":-500}]}');
    final p = s.sources.single;
    expect(p.azDeg, 180);
    expect(p.distM, 0.3);
    expect(p.gain, 1.5);
    expect(p.elDeg, -90);
  });

  test('floors fast orbits', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"bee","motion":{"orbit":{"radius":0.5,"period_s":0.5}}}]}');
    expect(s.sources.single.orbit!.periodS, 4);
  });

  test('strips markdown fences', () {
    final s = SceneDirector.parseSpec(
        '```json\n{"sources":[{"kind":"tone"}]}\n```');
    expect(s.sources.single.kind, SourceKindWire.tone);
  });

  test('defaults name and fills missing fields', () {
    final s = SceneDirector.parseSpec('{"sources":[{"kind":"rain"}]}');
    final r = s.sources.single;
    expect(r.name, 'rain0');
    expect(r.distM, 1.5);
    expect(r.gain, 0.9);
  });

  test('rejects unknown kind', () {
    expect(
      () => SceneDirector.parseSpec('{"sources":[{"kind":"thunder"}]}'),
      throwsA(isA<SpecException>()),
    );
  });

  test('rejects click (one-shot probe)', () {
    expect(
      () => SceneDirector.parseSpec('{"sources":[{"kind":"click"}]}'),
      throwsA(isA<SpecException>()),
    );
  });

  test('rejects empty, oversized, and non-json input', () {
    expect(() => SceneDirector.parseSpec('{"sources":[]}'),
        throwsA(isA<SpecException>()));
    expect(() => SceneDirector.parseSpec('hello there'),
        throwsA(isA<SpecException>()));
    expect(
      () => SceneDirector.parseSpec(
          '{"sources":[${List.filled(9, '{"kind":"bee"}').join(',')}]}'),
      throwsA(isA<SpecException>()),
    );
  });

  test('all preset specs parse cleanly', () {
    for (final json in presetPrompts.values) {
      final s = SceneDirector.parseSpec(json);
      expect(s.sources, isNotEmpty);
    }
  });

  test('parses sound/loop/duration fields', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"noise","sound":"campfire crackling","loop":true,"duration_s":8},'
        '{"kind":"bee","sound":"dragon roar","loop":false,"duration_s":99}]}');
    final fire = s.sources[0];
    expect(fire.sound, 'campfire crackling');
    expect(fire.loop, isTrue);
    expect(fire.durationS, 8);
    final dragon = s.sources[1];
    expect(dragon.loop, isFalse);
    expect(dragon.durationS, 12); // clamped to the SFX budget
  });

  test('defaults loop/duration when omitted', () {
    final s = SceneDirector.parseSpec('{"sources":[{"kind":"rain"}]}');
    expect(s.sources.single.loop, isTrue);
    expect(s.sources.single.durationS, 6);
    expect(s.sources.single.sound, isNull);
  });

  test('parses traverse motion', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"noise","az":0,"motion":{"traverse":{"from_az":-80,"to_az":80,"dist":2.5,"seconds":6}}}]}');
    final tr = s.sources.single.traverse!;
    expect(tr.fromAzDeg, -80);
    expect(tr.toAzDeg, 80);
    expect(tr.distM, 2.5);
    expect(tr.seconds, 6);
  });

  test('traverse clamps out-of-range values', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"noise","motion":{"traverse":{"from_az":-400,"to_az":400,"dist":0.01,"seconds":99}}}]}');
    final tr = s.sources.single.traverse!;
    expect(tr.fromAzDeg, -180);
    expect(tr.toAzDeg, 180);
    expect(tr.distM, 0.3);
    expect(tr.seconds, 30);
  });

  test('repairs a response truncated mid-source (max_tokens hit)', () {
    // Cut mid-way through the third source object — the two complete
    // ones survive, the partial one is dropped.
    final truncated = '{"sources":['
        '{"name":"wind","kind":"noise","az":0,"dist":8},'
        '{"name":"kids","kind":"noise","az":180,"dist":4},'
        '{"name":"dragon","kind":"noise","az":0,"motion":{"traver';
    final s = SceneDirector.parseSpec(truncated);
    expect(s.sources.length, 2);
    expect(s.sources[1].name, 'kids');
  });

  test('rejects truncation with no complete source', () {
    // Nested braces exist but no source object ever closed — repair
    // finds nothing to keep.
    expect(
      () => SceneDirector.parseSpec('{"sources":[{"a":{"b":1}'),
      throwsA(isA<SpecException>()),
    );
  });

  test('parses delay_s authored cues', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"rain","delay_s":0},'
        '{"kind":"noise","delay_s":2},'
        '{"kind":"noise","delay_s":4.5}]}');
    expect(s.sources[0].delayS, 0);
    expect(s.sources[1].delayS, 2);
    expect(s.sources[2].delayS, 4.5);
  });

  test('defaults and clamps delay_s', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"rain"},'
        '{"kind":"noise","delay_s":-5},'
        '{"kind":"noise","delay_s":999}]}');
    expect(s.sources[0].delayS, 0); // missing → immediate
    expect(s.sources[1].delayS, 0); // negative → clamped
    expect(s.sources[2].delayS, 120); // capped
  });

  test('delay_s round-trips through specToJson', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"name":"breeze","kind":"noise","delay_s":2,"duration_s":6}]}');
    final json = SceneDirector.specToJson(s);
    final rt = SceneDirector.parseSpec(jsonEncode(json));
    expect(rt.sources.single.delayS, 2);
    expect(rt.sources.single.name, 'breeze');
  });

  test('drops garbage sound values (derailment guard)', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"kind":"noise","sound":"]"},'
        '{"kind":"noise","sound":"42"},'
        '{"kind":"noise","sound":"campfire crackling"}]}');
    expect(s.sources[0].sound, isNull); // punctuation-only → procedural
    expect(s.sources[1].sound, isNull); // digits-only → procedural
    expect(s.sources[2].sound, 'campfire crackling');
  });

  test('inferTiming maps "after N" cues onto later sources', () {
    final s = SceneDirector.parseSpec('{"sources":['
        '{"name":"rain","kind":"rain"},'
        '{"name":"breeze","kind":"noise"},'
        '{"name":"plane","kind":"noise"}]}');
    SceneDirector.inferTiming(
      s,
      "I'm in rain, after 2 seconds a cold breeze, then a plane passes",
    );
    expect(s.sources[0].delayS, 0); // bed stays immediate
    expect(s.sources[1].delayS, 2); // "after 2" → breeze
    expect(s.sources[2].delayS, 4); // "then" → next staggered cue
  });

  test('inferTiming is a no-op without timing words or with model cues',
      () {
    final quiet = SceneDirector.parseSpec('{"sources":['
        '{"kind":"rain"},{"kind":"bee"}]}');
    SceneDirector.inferTiming(quiet, 'rain all around, a bee circling');
    expect(quiet.sources.every((s) => s.delayS == 0), isTrue);

    final authored = SceneDirector.parseSpec('{"sources":['
        '{"kind":"rain"},{"kind":"noise","delay_s":7}]}');
    SceneDirector.inferTiming(authored, 'rain, then after 2 seconds wind');
    expect(authored.sources[1].delayS, 7); // model's delay_s wins
  });
}
