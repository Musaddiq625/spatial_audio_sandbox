import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// ElevenLabs text-to-SFX client. Key is injected at build time:
///   flutter run --dart-define=ELEVENLABS_API_KEY=sk_...
///
/// One call = one source's audio (~2–5 s, ~40 credits per generated
/// second). Results are memoized by (text|duration|loop) so prompt-history
/// replays and engine restarts never re-bill.
class SfxClient {
  static const _apiKey = String.fromEnvironment('ELEVENLABS_API_KEY');
  static const _timeout = Duration(seconds: 45);

  final _cache = <String, Uint8List>{};

  bool get configured => _apiKey.isNotEmpty;

  /// text → compressed audio bytes (mp3_44100_128 — the universal format;
  /// the Rust side decodes whatever it gets). `loop` asks the model for a
  /// seamlessly looping clip; `durationSeconds` ≤ 30 (the director clamps
  /// tighter for cost).
  Future<Uint8List> generate(
    String text, {
    double? durationSeconds,
    bool loop = false,
  }) async {
    if (!configured) {
      throw StateError('ELEVENLABS_API_KEY not set — run with --dart-define');
    }
    final key =
        '${text.trim().toLowerCase()}|${durationSeconds ?? 0}|$loop';
    final hit = _cache[key];
    if (hit != null) return hit;

    final res = await http
        .post(
          Uri.https('api.elevenlabs.io', '/v1/sound-generation', const {
            'output_format': 'mp3_44100_128',
          }),
          headers: {
            'xi-api-key': _apiKey,
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'text': text.trim(),
            'prompt_influence': 0.4,
            'loop': loop,
            'duration_seconds': ?durationSeconds,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw StateError('sfx http ${res.statusCode}');
    }
    final bytes = res.bodyBytes;
    _cache[key] = bytes;
    return bytes;
  }
}
