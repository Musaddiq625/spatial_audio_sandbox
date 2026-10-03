import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// OpenAI-compatible chat client for the self-hosted llama.cpp endpoint.
/// Endpoint is injected at build time:
///   flutter run --dart-define=LLM_ENDPOINT=https://sas-llm.onrender.com
class LlmClient {
  static const _endpoint = String.fromEnvironment('LLM_ENDPOINT');
  static const _timeout = Duration(seconds: 60); // CPU inference is slow

  bool get configured => _endpoint.isNotEmpty;

  /// One chat completion; returns the assistant message content.
  /// [jsonSchema] enables llama.cpp constrained decoding — output is
  /// guaranteed to match the schema at the token level.
  Future<String> complete(
    String system,
    String user, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    if (!configured) {
      throw StateError('LLM_ENDPOINT not set — run with --dart-define');
    }
    final res = await http
        .post(
          Uri.parse('$_endpoint/v1/chat/completions'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'temperature': 0.2,
            'max_tokens': 512,
            if (jsonSchema != null)
              'response_format': {
                'type': 'json_object',
                'schema': jsonSchema,
              },
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw StateError('llm http ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map;
    final choices = body['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw StateError('llm returned no choices');
    }
    return (choices.first['message']?['content'] as String?) ?? '';
  }
}
