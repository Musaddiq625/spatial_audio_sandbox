import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// ElevenLabs text-to-SFX client. Key is injected at build time:
///   flutter run --dart-define=ELEVENLABS_API_KEY=sk_...
///
/// One call = one source's audio (~2–5 s, ~40 credits per generated
/// second). Three-layer cache keyed by (text|duration|loop): memory →
/// disk → API. Prompt-history replays and app restarts never re-bill.
class SfxClient {
  static const _apiKey = String.fromEnvironment('ELEVENLABS_API_KEY');
  static const _timeout = Duration(seconds: 45);

  final _cache = <String, Uint8List>{};
  Future<Directory>? _dir;

  bool get configured => _apiKey.isNotEmpty;

  Future<Directory> _cacheDir() => _dir ??= getApplicationDocumentsDirectory()
      .then((d) => Directory('${d.path}/sfx_cache').create(recursive: true));

  Future<File> _fileFor(String key) async =>
      File('${(await _cacheDir()).path}/${md5.convert(utf8.encode(key))}');

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
    if (hit != null) {
      debugPrint('[sfx] "$text": memory cache hit');
      return hit;
    }

    // Disk hit — survives restarts; cached prompts replay fully offline.
    try {
      final f = await _fileFor(key);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        _cache[key] = bytes;
        debugPrint('[sfx] "$text": disk cache hit (${bytes.length}B)');
        return bytes;
      }
    } catch (e) {
      // A cached clip that can't be read falls through to the API —
      // that silently spends credits, so it must be visible.
      debugPrint('[sfx] "$text": disk cache read failed ($e) — hitting API');
    }

    debugPrint('[sfx] "$text": calling ElevenLabs…');
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
      debugPrint('[sfx] "$text": api ${res.statusCode} — ${res.body}');
      throw StateError('sfx http ${res.statusCode}');
    }
    final bytes = res.bodyBytes;
    debugPrint('[sfx] "$text": api 200, ${bytes.length}B');
    _cache[key] = bytes;
    try {
      await (await _fileFor(key)).writeAsBytes(bytes, flush: true);
    } catch (_) {/* cache write is best-effort */}
    return bytes;
  }
}
