import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// OpenAI-compatible chat client for the self-hosted llama.cpp endpoint.
/// Endpoint is injected at build time:
///   flutter run --dart-define=LLM_ENDPOINT=https://sas-llm.onrender.com
class LlmClient {
  static const _endpoint = String.fromEnvironment('LLM_ENDPOINT');
  /// Inter-chunk gap limit. Must cover the longest quiet phase: prompt
  /// eval (~750 tokens on 2 vCPUs ≈ 60-100 s cold) before the first
  /// token. Mid-generation gaps are sub-second, so exceeding this means
  /// the stream is genuinely dead, not slow.
  static const _stallTimeout = Duration(seconds: 120);
  static const _connectTimeout = Duration(seconds: 30);

  bool get configured => _endpoint.isNotEmpty;

  /// One chat completion; returns the assistant message content.
  /// [jsonSchema] enables llama.cpp constrained decoding — output is
  /// guaranteed to match the schema at the token level.
  ///
  /// Streams SSE: on this CPU endpoint prompt-eval alone can take a
  /// minute before the first token, so timeouts apply to *gaps between
  /// chunks*, not the whole request — a slow-but-alive generation is
  /// never killed.
  Future<String> complete(
    String system,
    String user, {
    Map<String, dynamic>? jsonSchema,
    void Function(int chars)? onProgress,
  }) async {
    if (!configured) {
      throw StateError('LLM_ENDPOINT not set — run with --dart-define');
    }
    debugPrint('[llm] → $_endpoint (${system.length + user.length} chars in)');
    final req = http.Request(
      'POST',
      Uri.parse('$_endpoint/v1/chat/completions'),
    )
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'temperature': 0.2,
        'max_tokens': 1024,
        'stream': true,
        if (jsonSchema != null)
          'response_format': {
            'type': 'json_object',
            'schema': jsonSchema,
          },
      });

    final res = await http.Client()
        .send(req)
        .timeout(_connectTimeout); // headers — prompt eval follows
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      debugPrint('[llm] ← http ${res.statusCode}: $body');
      throw StateError('llm http ${res.statusCode}');
    }
    debugPrint('[llm] stream open — prompt eval, waiting for tokens…');

    final buf = StringBuffer();
    var lastLog = 0;
    try {
      await for (final line in res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(_stallTimeout)) {
        final l = line.trim();
        if (!l.startsWith('data:')) continue;
        final data = l.substring(5).trim();
        if (data == '[DONE]') break;
        final Object? j = jsonDecode(data);
        if (j is! Map) continue;
        final err = j['error'];
        if (err != null) throw StateError('llm stream error: $err');
        final choices = j['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'] as Map?;
        final piece = delta?['content'] as String?;
        if (piece != null) {
          buf.write(piece);
          onProgress?.call(buf.length);
          if (buf.length - lastLog >= 256) {
            lastLog = buf.length;
            debugPrint('[llm] … ${buf.length} chars received');
          }
        }
      }
    } on TimeoutException {
      debugPrint('[llm] stream stalled >${_stallTimeout.inSeconds}s after ${buf.length} chars');
      throw StateError('llm stream stalled (${buf.length} chars received)');
    }

    final content = buf.toString();
    debugPrint('[llm] ← spec (${content.length} chars): $content');
    return content;
  }
}
