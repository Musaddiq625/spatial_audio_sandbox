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
}
