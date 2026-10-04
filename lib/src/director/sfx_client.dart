import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// ElevenLabs text-to-SFX client. Key is injected at build time:
///   flutter run --dart-define=ELEVENLABS_API_KEY=sk_...
///
/// One call = one source's audio (~2–5 s, ~40 credits per generated
/// second). Four-layer cache keyed by (text|duration|loop): memory →
/// disk → bundled assets → API. Prompt-history replays, app restarts,
/// and the recorded demo pack never re-bill — bundled clips resolve
/// even without a key.
class SfxClient {
  static const _apiKey = String.fromEnvironment('ELEVENLABS_API_KEY');
  static const _timeout = Duration(seconds: 45);

  final _cache = <String, Uint8List>{};
  Future<Directory>? _dir;
  static Set<String>? _assetIndex;

  bool get configured => _apiKey.isNotEmpty;

  /// Bundled clips live at `assets/clips/<md5>.mp3` — the same filename
  /// filename the disk cache uses, so a recorded run can be copied
  /// straight out of the app's sfx_cache directory into the bundle.
  /// Resolves without an API key; that's the offline demo path.
  Future<Uint8List?> _assetHit(String key) async {
    try {
      _assetIndex ??= (await AssetManifest.loadFromAssetBundle(rootBundle))
          .listAssets()
          .where((a) => a.startsWith('assets/clips/'))
          .toSet();
      final path = 'assets/clips/${md5.convert(utf8.encode(key))}.mp3';
      if (!_assetIndex!.contains(path)) return null;
      return (await rootBundle.load(path)).buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

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

    // Bundled demo clips resolve keyless — the recorded scenes ship
    // their audio with the app.
    final bundled = await _assetHit(key);
    if (bundled != null) {
      _cache[key] = bundled;
      debugPrint('[sfx] "$text": bundled demo clip (${bundled.length}B)');
      return bundled;
    }

    if (!configured) {
      throw StateError('ELEVENLABS_API_KEY not set — run with --dart-define');
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
