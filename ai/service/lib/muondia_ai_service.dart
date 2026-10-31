import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'json_schema_validator.dart';

/// Development-only bridge to DeepSeek (Chat Completions, JSON Output).
/// Application prompts and schemas remain caller-owned.
///
/// DeepSeek only guarantees syntactically valid JSON (`json_object`), so the
/// schema travels in the system prompt and the result is validated here before
/// it is returned. An empty or non-conforming answer is retried once.
class MuondiaAiService {
  MuondiaAiService({
    required String apiKey,
    required String token,
    Uri? provider,
    this.timeout = const Duration(seconds: 75),
    void Function(Map<String, Object?>)? log,
  })  : _apiKey = apiKey,
        _token = token,
        _provider =
            provider ?? Uri.parse('https://api.deepseek.com/chat/completions'),
        _log = log ?? ((event) => stderr.writeln(jsonEncode(event))) {
    if (apiKey.trim().isEmpty || token.trim().isEmpty) {
      throw ArgumentError('Se requieren credenciales del servidor.');
    }
    // Validar antes de anunciar el servicio; nunca incluir secretos en errores.
    if (!RegExp(r'^sk-[!-~]+$').hasMatch(apiKey) ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(apiKey)) {
      throw ArgumentError('Clave DeepSeek inválida: caracteres no permitidos.');
    }
    if (_provider.scheme != 'https' &&
        !(_provider.scheme == 'http' &&
            ['127.0.0.1', 'localhost', '::1'].contains(_provider.host))) {
      throw ArgumentError(
          'El proveedor debe usar HTTPS o loopback de pruebas.');
    }
  }

  static const _maxAttempts = 2;
  static const _defaultMaxTokens = 8192;
  static const _maxMaxTokens = 32768;

  final String _apiKey;
  final String _token;
  final Uri _provider;
  final Duration timeout;
  final void Function(Map<String, Object?>) _log;
  HttpServer? _server;

  Future<HttpServer> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_handle);
    return server;
  }

  Future<void> close() async => _server?.close(force: true);

  String _safe(Object? value) {
    var text = value is String ? value : '';
    for (final secret in [_apiKey, _token]) {
      text = text.replaceAll(secret, '[redacted]');
    }
    text = text.replaceAll(RegExp(r'sk-[A-Za-z0-9_*\-]+'), '[redacted]');
    text = text.replaceAll(
        RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer [redacted]');
    text = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
    return text.length > 2000 ? text.substring(0, 2000) : text;
  }

  bool _authorized(String? authorization) {
    final expected = utf8.encode('Bearer $_token');
    final actual = utf8.encode(authorization ?? '');
    var mismatch = expected.length ^ actual.length;
    for (var i = 0; i < expected.length; i++) {
      mismatch |= expected[i] ^ (i < actual.length ? actual[i] : 0);
    }
    return mismatch == 0;
  }

  Future<void> _send(
      HttpRequest request, int status, Map<String, Object?> body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    HttpClient? http;
    try {
      if (!_authorized(
          request.headers.value(HttpHeaders.authorizationHeader))) {
        await _send(request, 401, {'error': 'unauthorized'});
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/health') {
        await _send(request, 200, {
          'service': 'muondia-ai',
          'protocol': 1,
          'pid': pid,
          'provider': 'deepseek',
          'capabilities': {'imageInput': true, 'thinking': true},
        });
        return;
      }
      if (request.uri.path != '/v1/generate') {
        await _send(request, 404, {'error': 'not_found'});
        return;
      }
      if (request.method != 'POST') {
        await _send(request, 405, {'error': 'method_not_allowed'});
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 5 * 1024 * 1024) {
          await _send(request, 413, {'error': 'request_too_large'});
          return;
        }
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        await _send(request, 400, {'error': 'invalid_json'});
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        await _send(request, 400, {'error': 'invalid_request'});
        return;
      }
      final body = decoded;
      for (final field in ['application', 'model', 'input', 'schemaName']) {
        if (body[field] is! String || (body[field] as String).trim().isEmpty) {
          await _send(request, 400, {'error': '${field}_required'});
          return;
        }
      }
      final maxTokens = body['maxTokens'];
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$')
              .hasMatch(body['application'] as String) ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,64}$')
              .hasMatch(body['schemaName'] as String) ||
          (body['input'] as String).length > 32000 ||
          body['schema'] is! Map<String, dynamic> ||
          (body['thinking'] != null && body['thinking'] is! bool) ||
          (maxTokens != null &&
              (maxTokens is! int || maxTokens < 1 || maxTokens > _maxMaxTokens))) {
        await _send(request, 400, {'error': 'invalid_request'});
        return;
      }
      // Image bytes are supplied only by the authenticated Muondia client.
      // Validate before forwarding to the provider; never log pixel payloads.
      final image = body['image'];
      if (image != null) {
        if (body['application'] != 'muondia' ||
            image is! Map<String, dynamic> ||
            image['mimeType'] != 'image/png' ||
            image['data'] is! String ||
            (image['data'] as String).length > 4194304) {
          await _send(request, 400, {'error': 'invalid_image'});
          return;
        }
        try {
          final raw = base64Decode(image['data'] as String);
          const signature = [137, 80, 78, 71, 13, 10, 26, 10];
          if (raw.length < 24 ||
              raw.length > 3145728 ||
              !List.generate(signature.length, (i) => i)
                  .every((i) => raw[i] == signature[i])) {
            throw const FormatException('Invalid PNG');
          }
        } on FormatException {
          await _send(request, 400, {'error': 'invalid_image'});
          return;
        }
      }
      final watch = Stopwatch()..start();
      http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final result = await _generate(http, body).timeout(timeout);
      _log({
        'application': _safe(body['application']),
        'model': _safe(body['model']),
        'durationMs': watch.elapsedMilliseconds,
        'status': result.status,
        if (result.body['diagnostic'] != null)
          'diagnostic': result.body['diagnostic'],
        if (result.body['usage'] != null) 'usage': result.body['usage'],
      });
      await _send(request, result.status, result.body);
    } on TimeoutException {
      _log({'error': 'request_timeout'});
      await _send(request, 504, {'error': 'request_timeout'});
    } catch (error) {
      // Never print arbitrary exceptions: they can contain headers or request data.
      _log({
        'error': 'connection_or_response_failure',
        'type': error.runtimeType.toString(),
        'detail': _safe(error.toString())
      });
      try {
        await _send(request, 502, {'error': 'connection_or_response_failure'});
      } catch (_) {
        // The caller may have disconnected.
      }
    } finally {
      http?.close(force: true);
    }
  }

  /// DeepSeek JSON Output requires the word "json" and an example of the
  /// expected structure in the prompt. The system message comes first and is
  /// identical for every call with the same schema, which favours context
  /// caching.
  String _systemPrompt(String schemaName, Map<String, dynamic> schema) =>
      'Responde únicamente con un objeto JSON válido: sin texto adicional, '
      'sin comentarios y sin bloques de código markdown. El objeto debe '
      'cumplir exactamente este JSON Schema (nombre: $schemaName) y no puede '
      'incluir propiedades que el esquema no declare.\n'
      'JSON Schema: ${jsonEncode(schema)}\n'
      'Ejemplo de estructura: ${jsonEncode(exampleFromSchema(schema))}';

  Future<({int status, Map<String, Object?> body})> _generate(
    HttpClient http,
    Map<String, dynamic> body,
  ) async {
    final usage = <String, int>{};
    var last = _Attempt.failure('missing_output_text');
    var attempts = 0;
    while (attempts < _maxAttempts) {
      attempts++;
      last = await _attempt(http, body);
      last.usage.forEach((key, value) => usage[key] = (usage[key] ?? 0) + value);
      if (!last.retry) break;
    }
    final result = last.result;
    if (result.status == 200) {
      return (
        status: 200,
        body: {
          'text': result.body['text'],
          'attempts': attempts,
          if (usage.isNotEmpty) 'usage': usage,
        }
      );
    }
    final diagnostic = <String, Object?>{
      ...?(result.body['diagnostic'] as Map<String, Object?>?),
      if (attempts > 1) 'attempts': attempts,
    };
    return (
      status: result.status,
      body: {
        ...result.body,
        if (diagnostic.isNotEmpty) 'diagnostic': diagnostic,
        if (usage.isNotEmpty) 'usage': usage,
      }
    );
  }

  Future<_Attempt> _attempt(HttpClient http, Map<String, dynamic> body) async {
    final schema = body['schema'] as Map<String, dynamic>;
    final image = body['image'];
    final upstream = await http.postUrl(_provider);
    upstream.followRedirects = false;
    upstream.headers.contentType = ContentType.json;
    upstream.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiKey');
    upstream.write(jsonEncode({
      'model': body['model'],
      'messages': [
        {
          'role': 'system',
          'content': _systemPrompt(body['schemaName'] as String, schema),
        },
        {
          'role': 'user',
          'content': image is Map
              ? [
                  {'type': 'text', 'text': body['input']},
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url': 'data:image/png;base64,${image['data']}',
                    },
                  },
                ]
              : body['input'],
        },
      ],
      'response_format': {'type': 'json_object'},
      // Structured generation is faster and cheaper without the reasoning
      // phase; callers opt in with `thinking: true`.
      'thinking': {'type': body['thinking'] == true ? 'enabled' : 'disabled'},
      'max_tokens': body['maxTokens'] ?? _defaultMaxTokens,
      'stream': false,
    }));
    final response = await upstream.close();
    final text = await utf8.decoder.bind(response).join();
    Object? payload;
    try {
      payload = jsonDecode(text);
    } on FormatException {
      payload = null;
    }
    final requestId = _safe(response.headers.value('x-ds-trace-id') ??
        response.headers.value('x-request-id'));
    if (response.statusCode != 200) {
      final error = payload is Map ? payload['error'] : null;
      final diagnostic = <String, Object?>{
        'providerStatus': response.statusCode,
        'requestId': requestId,
        for (final field in ['code', 'type', 'param', 'message'])
          if (error is Map && error[field] is String)
            field: _safe(error[field]),
      };
      // 402 means the account has no balance: surface it as its own code so the
      // operator knows to top up instead of debugging the request.
      return _Attempt(
        status: 502,
        body: {
          'error': response.statusCode == 402
              ? 'provider_insufficient_balance'
              : 'provider_rejected',
          'diagnostic': diagnostic,
        },
        retry: false,
      );
    }
    final usage = _usage(payload is Map ? payload['usage'] : null);
    final choices = payload is Map ? payload['choices'] : null;
    final choice =
        choices is List && choices.isNotEmpty && choices.first is Map
            ? choices.first as Map
            : null;
    if (choice == null) {
      return _Attempt.failure('incomplete_or_invalid_response',
          diagnostic: {'requestId': requestId}, usage: usage);
    }
    final reason = choice['finish_reason'];
    if (reason == 'content_filter') {
      return _Attempt(
        status: 502,
        body: {
          'error': 'provider_refusal',
          'diagnostic': {'requestId': requestId}
        },
        retry: false,
        usage: usage,
      );
    }
    if (reason != 'stop') {
      // `length` would fail again with the same budget; transient provider
      // states (`insufficient_system_resource`, `aborted`) are worth a retry.
      return _Attempt.failure(
        'incomplete_or_invalid_response',
        diagnostic: {'requestId': requestId, 'reason': _safe(reason)},
        retry: reason == 'insufficient_system_resource' || reason == 'aborted',
        usage: usage,
      );
    }
    final message = choice['message'];
    final content = message is Map && message['content'] is String
        ? (message['content'] as String).trim()
        : '';
    if (content.isEmpty) {
      // Documented behaviour: non-JSON output is blanked by the provider.
      return _Attempt.failure('missing_output_text',
          diagnostic: {'requestId': requestId}, retry: true, usage: usage);
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(content);
    } on FormatException {
      return _Attempt.failure('invalid_structured_output',
          diagnostic: {'requestId': requestId, 'reason': 'invalid_json'},
          retry: true,
          usage: usage);
    }
    final problems = validateJsonSchema(parsed, schema);
    if (problems.isNotEmpty) {
      // Paths and rules only: generated content never reaches logs.
      return _Attempt.failure('invalid_structured_output',
          diagnostic: {
            'requestId': requestId,
            'reason': 'schema_mismatch',
            'schemaErrors': problems.take(5).map(_safe).toList(),
          },
          retry: true,
          usage: usage);
    }
    return _Attempt(
        status: 200, body: {'text': content}, retry: false, usage: usage);
  }

  Map<String, int> _usage(Object? usage) {
    if (usage is! Map) return const {};
    int? read(Object? value) => value is int ? value : null;
    final details = usage['completion_tokens_details'];
    final promptDetails = usage['prompt_tokens_details'];
    final values = <String, int?>{
      'inputTokens': read(usage['prompt_tokens']),
      'outputTokens': read(usage['completion_tokens']),
      'totalTokens': read(usage['total_tokens']),
      'reasoningTokens':
          details is Map ? read(details['reasoning_tokens']) : null,
      'cachedInputTokens': read(usage['prompt_cache_hit_tokens']) ??
          (promptDetails is Map ? read(promptDetails['cached_tokens']) : null),
    };
    return {
      for (final entry in values.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
  }
}

class _Attempt {
  const _Attempt({
    required this.status,
    required this.body,
    required this.retry,
    this.usage = const {},
  });

  factory _Attempt.failure(
    String error, {
    Map<String, Object?>? diagnostic,
    bool retry = false,
    Map<String, int> usage = const {},
  }) =>
      _Attempt(
        status: 502,
        body: {'error': error, if (diagnostic != null) 'diagnostic': diagnostic},
        retry: retry,
        usage: usage,
      );

  final int status;
  final Map<String, Object?> body;
  final bool retry;
  final Map<String, int> usage;

  ({int status, Map<String, Object?> body}) get result =>
      (status: status, body: body);
}
