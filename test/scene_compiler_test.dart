import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/director/scene_compiler.dart';
import 'package:spatial_audio_sandbox/src/director/scene_director.dart';

/// Golden corpus: each case pairs a prompt with a screenplay the 1B
/// model plausibly emits — including its known failure modes (invented
/// sources, copied motion, wrong places) — and asserts the compiled
/// SceneSpec. The compiler must fix or drop every model mistake.
void main() {
  SceneSpec compile(String prompt, String screenplay) =>
      SceneCompiler.compile(SceneCompiler.parseScreenplay(screenplay), prompt);

  SpecSource? byName(SceneSpec s, String n) {
    for (final x in s.sources) {
      if (x.name == n) return x;
    }
    return null;
  }

  test('cave scene: fire still in front, kids wander behind, no plane',
      () {
    const prompt =
        "I am sitting in a cave in front of a fire. Behind me, some "
        "kids are playing and running around. I am roasting a chicken "
        "over the fire. After a while, a cold breeze comes and the "
        "fire goes out";
    // Deliberately bad model output: plane invented (example bleed),
    // orbit copied onto the fire, breeze given approach, chicken far.
    final spec = compile(prompt, '{"environment":"cave","sources":['
        '{"name":"fire","sound":"campfire crackling","role":"object",'
        '"place":"front","distance":"near","movement":"circle",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"kids","sound":"children playing","role":"person",'
        '"place":"behind","distance":"near","movement":"wander",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"plane","sound":"jet plane flyby","role":"vehicle",'
        '"place":"above","distance":"far","movement":"pass_left_to_right",'
        '"start":"later","ends":"never","loop":false},'
        '{"name":"chicken","sound":"chicken sizzling","role":"object",'
        '"place":"front","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"breeze","sound":"cold wind gust","role":"weather",'
        '"place":"around","distance":"close","movement":"approach",'
        '"start":"later","ends":"never","loop":true}]}');

    final fire = byName(spec, 'fire')!;
    expect(fire.orbit, isNull); // "in front of a fire" — no verb → still
    expect(fire.wander, isNull);
    expect(fire.traverse, isNull);
    expect(fire.azDeg, 0); // stays in front

    final kids = byName(spec, 'kids')!;
    expect(kids.wander, isNotNull); // "running around" → anchored wander
    expect(kids.azDeg, 180); // behind
    expect(kids.wander!.anchorAzDeg, 180); // wander stays behind

    expect(byName(spec, 'plane'), isNull); // not in prompt → dropped

    final breeze = byName(spec, 'breeze')!;
    expect(breeze.traverse, isNull);
    expect(breeze.approach, isNull);
    expect(breeze.wander, isNull); // weather bed → still
    expect(breeze.distM, greaterThanOrEqualTo(2)); // bed → pushed out
    expect(breeze.delayS, greaterThan(0)); // "after a while"

    // "the fire goes out" → fire ends + transition one-shot exists.
    expect(fire.endS, isNotNull);
    expect(fire.endS, greaterThanOrEqualTo(breeze.delayS));
    final end = spec.sources.where((s) => s.name == 'fire_end');
    expect(end, hasLength(1));
    expect(end.single.loop, isFalse);
    expect(end.single.delayS, fire.endS);
    expect(spec.environment, 'cave');
  });

  test('mountain scene: dragon traverses, beds still', () {
    const prompt =
        "I'm standing on a mountain, wind everywhere, kids playing "
        "behind me, a campfire crackling right in front, and a dragon "
        "flying past me left to right";
    final spec = compile(prompt, '{"environment":"mountain","sources":['
        '{"name":"wind","sound":"mountain wind","role":"weather",'
        '"place":"around","distance":"near","movement":"circle",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"kids","sound":"children playing","role":"person",'
        '"place":"behind","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"fire","sound":"campfire crackling","role":"object",'
        '"place":"front","distance":"close","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"dragon","sound":"dragon roar and wingbeats",'
        '"role":"creature","place":"front","distance":"near",'
        '"movement":"still","start":"beginning","ends":"never",'
        '"loop":false}]}');

    expect(byName(spec, 'wind')!.orbit, isNull); // beds can't circle
    expect(byName(spec, 'kids')!.wander, isNull); // "playing", not "running"
    final dragon = byName(spec, 'dragon')!;
    expect(dragon.traverse, isNotNull); // "flying past me left to right"
    expect(dragon.traverse!.fromAzDeg, -80);
    expect(dragon.traverse!.toAzDeg, 80);
  });

  test('bee circling in front keeps its orbit — anchored or head', () {
    const prompt = 'rain all around, a bee circling close in front of me';
    final spec = compile(prompt, '{"sources":['
        '{"name":"rain","sound":"steady rain","role":"weather",'
        '"place":"around","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"bee","sound":"bee buzzing","role":"creature",'
        '"place":"front","distance":"close","movement":"circle",'
        '"start":"beginning","ends":"never","loop":true}]}');
    final bee = byName(spec, 'bee')!;
    expect(bee.orbit, isNotNull); // "circling" IS a motion verb
  });

  test('untimed city scene: all starts zero, no phantom timing', () {
    const prompt = 'a busy city street: traffic all around, '
        'a dog barking to my right, pigeons close in front';
    final spec = compile(prompt, '{"environment":"city","sources":['
        '{"name":"traffic","sound":"city traffic","role":"ambience",'
        '"place":"around","distance":"near","movement":"still",'
        '"start":"after_seconds","start_s":2,"ends":"never","loop":true},'
        '{"name":"dog","sound":"dog barking","role":"creature",'
        '"place":"right","distance":"near","movement":"still",'
        '"start":"after_seconds","start_s":4,"ends":"never","loop":false},'
        '{"name":"pigeons","sound":"pigeons cooing","role":"creature",'
        '"place":"front","distance":"close","movement":"still",'
        '"start":"later","ends":"never","loop":true}]}');
    // No timing words → model-emitted delays are untrusted → all 0.
    expect(spec.sources.every((s) => s.delayS == 0), isTrue);
    expect(byName(spec, 'dog')!.azDeg, -90);
  });

  test('explicit "after 3 seconds" maps onto the source', () {
    const prompt = 'beside a lake, after 3 seconds thunder cracks above';
    final spec = compile(prompt, '{"environment":"lake","sources":['
        '{"name":"lake","sound":"lake water lapping","role":"weather",'
        '"place":"around","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"thunder","sound":"thunder crack","role":"event",'
        '"place":"above","distance":"far","movement":"still",'
        '"start":"after_seconds","start_s":3,"ends":"never",'
        '"loop":false}]}');
    expect(byName(spec, 'lake')!.delayS, 0);
    final th = byName(spec, 'thunder')!;
    expect(th.delayS, 3);
    expect(th.loop, isFalse); // role:event forces one-shot
    expect(th.elDeg, 60); // place:above
  });

  test('event with a matching source: music stops at scene time', () {
    const prompt = 'a radio playing jazz in front of me, '
        'later the music stops';
    final spec = compile(prompt, '{"sources":['
        '{"name":"radio","sound":"radio playing jazz","role":"object",'
        '"place":"front","distance":"near","movement":"still",'
        '"start":"beginning","ends":"with_event","loop":true}]}');
    final radio = byName(spec, 'radio')!;
    expect(radio.endS, isNotNull);
    expect(radio.endS, greaterThan(0));
  });

  test('event with no matching source still adds a transition shot', () {
    const prompt = 'rain on the window, then the lights go out';
    final spec = compile(prompt, '{"sources":['
        '{"name":"rain","sound":"rain on glass","role":"weather",'
        '"place":"front","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    final ends = spec.sources.where((s) => s.name.endsWith('_end'));
    expect(ends, hasLength(1));
    expect(ends.single.loop, isFalse);
  });

  test('verb attaches to the clause subject, not nearby nouns', () {
    // "running" describes the kids, NOT the fire — the fire must stay
    // still even though it shares the clause.
    const prompt = 'kids running around the campfire behind me';
    final spec = compile(prompt, '{"sources":['
        '{"name":"kids","sound":"children running","role":"person",'
        '"place":"behind","distance":"near","movement":"wander",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"campfire","sound":"campfire crackling","role":"object",'
        '"place":"behind","distance":"near","movement":"wander",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(byName(spec, 'kids')!.wander, isNotNull);
    expect(byName(spec, 'campfire')!.wander, isNull);
    expect(byName(spec, 'campfire')!.orbit, isNull);
  });

  test('zero grounded sources → keyword fallback, not empty scene', () {
    const prompt = 'rain and thunder';
    final spec = compile(prompt, '{"sources":['
        '{"name":"spaceship","sound":"alien engine","role":"vehicle",'
        '"place":"above","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(spec.sources, isNotEmpty);
    // The fallback sources come from prompt vocabulary, not the model's.
    expect(
      spec.sources.any((s) => _conceptsHit(s, 'rain')),
      isTrue,
    );
  });

  test('screenplay parse: enum fields validated, garbage defaults', () {
    final sp = SceneCompiler.parseScreenplay('{"environment":"cave",'
        '"sources":[{"name":"fire","sound":"crackling","role":"WIZARD",'
        '"place":"mars","distance":"near","movement":"teleport",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(sp.environment, 'cave');
    final s = sp.sources.single;
    expect(s.role, 'object'); // invalid → default
    expect(s.place, 'front');
    expect(s.movement, 'still');
  });

  test('refine: existing scene names stay grounded', () {
    // Follow-up "add wind" — the rain from the prior scene isn't in
    // the new prompt but must survive via extraGround.
    final spec = SceneCompiler.compile(
      SceneCompiler.parseScreenplay('{"sources":['
          '{"name":"rain","sound":"steady rain","role":"weather",'
          '"place":"around","distance":"near","movement":"still",'
          '"start":"beginning","ends":"never","loop":true},'
          '{"name":"wind","sound":"cold wind","role":"weather",'
          '"place":"left","distance":"near","movement":"still",'
          '"start":"beginning","ends":"never","loop":true}]}'),
      'add wind from the left',
      extraGround: ['rain'],
    );
    expect(byName(spec, 'rain'), isNotNull);
    expect(byName(spec, 'wind'), isNotNull);
  });

  test('compiled spec round-trips through parseSpec (history)', () {
    const prompt = 'kids running around behind me';
    final spec = compile(prompt, '{"sources":['
        '{"name":"kids","sound":"children playing","role":"person",'
        '"place":"behind","distance":"near","movement":"wander",'
        '"start":"beginning","ends":"never","loop":true}]}');
    final rt = SceneDirector.parseSpec(
        jsonEncode(SceneDirector.specToJson(spec)));
    expect(rt.sources, hasLength(1));
    expect(rt.sources.single.wander, isNotNull);
    expect(rt.sources.single.wander!.anchorAzDeg, 180);
  });

  // --- Regressions found by live eval against the real endpoint ---

  test('exact duplicate emission is dropped, not renamed', () {
    // The real model emitted "fire" twice, verbatim — a copy is not a
    // second source.
    final spec = compile('a campfire in front of me', '{"sources":['
        '{"name":"fire","sound":"campfire crackling","role":"object",'
        '"place":"front","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"fire","sound":"campfire crackling","role":"object",'
        '"place":"front","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(spec.sources.where((s) => s.name.startsWith('fire')),
        hasLength(1));
  });

  test('after_seconds without start_s falls back to fragment time', () {
    // Real model output: start:"after_seconds" with no start_s — the
    // "after a while" fragment's staggered time must win, not 0.
    const prompt = 'I sit by a fire. After a while, a cold breeze comes';
    final spec = compile(prompt, '{"sources":['
        '{"name":"fire","sound":"crackling fire","role":"object",'
        '"place":"front","distance":"near","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"cold breeze","sound":"wind blowing","role":"weather",'
        '"place":"around","distance":"far","movement":"still",'
        '"start":"after_seconds","ends":"never","loop":true}]}');
    expect(byName(spec, 'cold breeze')!.delayS, greaterThan(0));
    expect(byName(spec, 'fire')!.delayS, 0);
  });

  test('distance words in the piece override the model', () {
    // Real model output: "pigeons close in front" got distance:"far".
    const prompt =
        'a busy city street, pigeons close in front of me';
    final spec = compile(prompt, '{"sources":['
        '{"name":"pigeons","sound":"pigeons cooing","role":"creature",'
        '"place":"around","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    final p = byName(spec, 'pigeons')!;
    expect(p.azDeg, 0);
    expect(p.distM, lessThan(1.0)); // "close" — not the model's 6m
  });

  test('spatial words stay on their own side of "while"', () {
    // Real model output: the loon's "to my left" bled onto the waves
    // when the whole clause was one spatial context.
    const prompt =
        'waves lapping at my feet while a loon calls far to my left';
    final spec = compile(prompt, '{"sources":['
        '{"name":"waves","sound":"ocean waves lapping","role":"weather",'
        '"place":"around","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"loon","sound":"loon call","role":"creature",'
        '"place":"above","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":false}]}');
    expect(byName(spec, 'loon')!.azDeg, 90); // "to my left"
    // Waves keep the model's "around" — "to my left" isn't theirs.
    expect(byName(spec, 'waves')!.azDeg, isNot(90));
  });

  test('event role cannot kill a looping bed', () {
    // Real model labeled the fire role:"event" but loop:true + ends:
    // never — the lifecycle fields agree it is continuous.
    const prompt = 'a campfire burning in front of me';
    final spec = compile(prompt, '{"sources":['
        '{"name":"fire","sound":"campfire crackling","role":"event",'
        '"place":"front","distance":"close","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(byName(spec, 'fire')!.loop, isTrue);
  });

  test('report records dropped sources and end transitions', () {
    const prompt = 'a fire in front of me, and after a while the '
        'fire goes out';
    final spec = compile(prompt, '{"sources":['
        '{"name":"fire","sound":"campfire crackling","role":"object",'
        '"place":"front","distance":"near","movement":"still",'
        '"start":"beginning","ends":"with_event","loop":true},'
        '{"name":"dragon","sound":"dragon roar","role":"creature",'
        '"place":"behind","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(spec.report.dropped, contains('dragon'));
    expect(spec.report.ended, isNotEmpty);
    expect(spec.report.transitions, isNotEmpty);
    expect(spec.report.fallback, isFalse);
    expect(spec.report.repaired, isFalse);
    expect(spec.report.summary(spec.sources.length), contains('dropped'));
  });

  test('report flags truncation repair and keyword fallback', () {
    const prompt = 'rain around me';
    // Truncated mid-second-source — the parser salvages the first.
    final spec = compile(prompt, '{"sources":['
        '{"name":"rain","sound":"steady rain","role":"weather",'
        '"place":"around","distance":"close","movement":"still",'
        '"start":"beginning","ends":"never","loop":true},'
        '{"name":"wind","so');
    expect(spec.report.repaired, isTrue);
    expect(byName(spec, 'rain'), isNotNull);

    final fb = compile(prompt, '{"sources":['
        '{"name":"zebra","sound":"zebra sounds","role":"creature",'
        '"place":"left","distance":"far","movement":"still",'
        '"start":"beginning","ends":"never","loop":true}]}');
    expect(fb.report.fallback, isTrue);
    expect(fb.report.dropped, contains('zebra'));
  });
}

bool _conceptsHit(SpecSource s, String word) =>
    '${s.name} ${s.sound ?? ''}'.toLowerCase().contains(word);
