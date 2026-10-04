// Live-check: send golden prompts to the real Gemma endpoint with the
// production system prompt + schema, run the screenplay through the
// compiler, and print what the scene would actually be — what you'd
// hear. Catches the failure modes unit tests can't: model drift, slot
// pollution, schema misfires.
//
// Opt-in — skipped by default so CI stays offline:
//   fvm flutter test test/live_eval_test.dart \
//     --dart-define=LIVE_EVAL=true \
//     --dart-define=LLM_ENDPOINT=https://sas-llm.onrender.com

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spatial_audio_sandbox/src/director/scene_compiler.dart';
import 'package:spatial_audio_sandbox/src/director/scene_director.dart';

const _endpoint = String.fromEnvironment('LLM_ENDPOINT');
const _live = bool.fromEnvironment('LIVE_EVAL');

const _golden = [
  // The user's reported failure: fire must stay still in front, kids
  // wander behind, breeze delayed, fire must end with a transition —
  // and NO plane.
  'I am sitting in a cave in front of a fire. Behind me, some kids '
      'are playing and running around. I am roasting a chicken over '
      'the fire. After a while, a cold breeze comes and the fire goes out',
  // Authored timing + traverse.
  "I'm standing on a huge mountain, wind everywhere, kids playing "
      'behind me, a campfire crackling right in front, and a dragon '
      'flying past me left to right',
  // Explicit seconds.
  "I'm in rain, after 2 seconds a cold breeze, then a plane crosses "
      'left to right',
  // Untimed — every source must start at 0.
  'a busy city street: traffic all around, a dog barking to my right, '
      'pigeons close in front',
  // Single static bed — smallest possible scene.
  'a quiet forest at night, crickets all around me',
  // One transition only.
  'music playing on an old radio, then the radio dies',
  // Unusual vocabulary — grounding must map, not drop.
  'waves lapping at my feet while a loon calls far to my left',
];

Future<String> _chat(String user) async {
  final res = await http
      .post(
        Uri.parse('$_endpoint/v1/chat/completions'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'messages': [
            {'role': 'system', 'content': SceneDirector.systemPrompt},
            {'role': 'user', 'content': user},
          ],
          'temperature': 0.2,
          'max_tokens': 1536,
          'stream': false,
          'response_format': {
            'type': 'json_object',
            'schema': SceneDirector.specJsonSchema,
          },
        }),
      )
      .timeout(const Duration(minutes: 4)); // CPU prompt eval is slow
  if (res.statusCode != 200) {
    throw StateError('http ${res.statusCode}: ${res.body}');
  }
  final j = jsonDecode(res.body) as Map;
  return ((j['choices'] as List).first as Map)['message']['content']
      as String;
}

String _motionOf(SpecSource s) => s.orbit != null
    ? 'orbit(${s.orbit!.periodS}s, center:${s.orbit!.centerAzDeg}°)'
    : s.traverse != null
        ? 'traverse(${s.traverse!.fromAzDeg}→${s.traverse!.toAzDeg})'
        : s.approach != null
            ? 'approach'
            : s.wander != null
                ? 'wander(az:${s.wander!.anchorAzDeg})'
                : 'still';

void main() {
  test(
    'live eval — golden prompts through real Gemma + compiler',
    () async {
      for (final p in _golden) {
        stdout.writeln('\n=== "$p"');
        final sw = Stopwatch()..start();
        try {
          final raw = await _chat(p);
          stdout.writeln('model (${sw.elapsed.inSeconds}s): $raw');
          final spec = SceneCompiler.compile(
              SceneCompiler.parseScreenplay(raw), p);
          stdout.writeln('  env: ${spec.environment}');
          for (final s in spec.sources) {
            final end = s.endS != null ? ', end:${s.endS}s' : '';
            stdout.writeln('  • ${s.name.padRight(12)} az:${s.azDeg} '
                'dist:${s.distM}m ${_motionOf(s)} delay:${s.delayS}s$end '
                '${s.loop ? "loop" : "one-shot"} "${s.sound}"');
          }
        } catch (e) {
          stdout.writeln('FAILED (${sw.elapsed.inSeconds}s): $e');
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: !_live,
  );
}
