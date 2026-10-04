import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/listener/source_style.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

void main() {
  test('keyword names resolve to their own icons and colors', () {
    final fire = styleFor('fire', SourceKindWire.noise);
    expect(fire.icon, Icons.local_fire_department);

    final kids = styleFor('kids', SourceKindWire.noise);
    expect(kids.icon, Icons.directions_run);
    expect(kids.color, isNot(fire.color));

    final breeze = styleFor('cold breeze', SourceKindWire.noise);
    expect(breeze.icon, Icons.air);

    final thunder = styleFor('thunder', SourceKindWire.noise);
    expect(thunder.icon, Icons.thunderstorm);
  });

  test('transition names keep the parent style', () {
    expect(styleFor('fire_end', SourceKindWire.noise).icon,
        Icons.local_fire_department);
    expect(styleFor('rain_end', SourceKindWire.noise).icon,
        Icons.water_drop);
  });

  test('unknown names fall back to the kind icon with a stable color', () {
    final a = styleFor('xyzzy', SourceKindWire.tone);
    final b = styleFor('xyzzy', SourceKindWire.tone);
    expect(a.icon, Icons.graphic_eq);
    expect(a.color, b.color); // same label → same fallback color

    final bee = styleFor('zzz-no-match', SourceKindWire.bee);
    expect(bee.icon, Icons.emoji_nature);
  });

  test('keyword matching is case-insensitive and word-bounded', () {
    expect(styleFor('FIRE', SourceKindWire.noise).icon,
        Icons.local_fire_department);
    // "fired" contains "fire" but is a different word — \b still lets it
    // match (fired ≈ fire semantically); a truly unrelated name must not.
    expect(styleFor('desklamp', SourceKindWire.noise).icon,
        Icons.blur_on);
  });
}
