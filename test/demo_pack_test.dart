import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/director/demo_pack.dart';
import 'package:spatial_audio_sandbox/src/director/scene_director.dart';

void main() {
  test('every bundled demo spec parses and plays keyless', () {
    for (final d in demoScenes) {
      expect(d['recorded'], isTrue);
      expect(d['prompt'], isA<String>());

      // The spec must survive the exact path history replay uses —
      // a bad bundled spec would throw on first launch.
      final spec = SceneDirector.parseSpec(jsonEncode(d['spec']));
      expect(spec.sources.length, greaterThanOrEqualTo(2),
          reason: d['prompt'] as String);
      for (final s in spec.sources) {
        expect(s.delayS, greaterThanOrEqualTo(0));
        if (s.endS != null) {
          expect(s.endS!, greaterThan(s.delayS));
        }
      }
      // Round-trip: specToJson output must re-parse identically.
      final rt = SceneDirector.parseSpec(
          jsonEncode(SceneDirector.specToJson(spec)));
      expect(rt.sources.length, spec.sources.length);
    }
  });
}
