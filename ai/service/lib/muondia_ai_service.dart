import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Development-only bridge. Application prompts and schemas remain caller-owned.
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
            provider ?? Uri.parse('https://api.openai.com/v1/responses'),
        _log = log ?? ((event) => stderr.writeln(jsonEncode(event))) {
    if (apiKey.trim().isEmpty || token.trim().isEmpty) {
      throw ArgumentError('Se requieren credenciales del servidor.');
    }
    // Validar antes de anunciar el servicio; nunca incluir secretos en errores.
    if (!RegExp(r'^sk-[!-~]+$').hasMatch(apiKey) ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(apiKey)) {
      throw ArgumentError('Clave OpenAI inválida: caracteres no permitidos.');
    }
    if (_provider.scheme != 'https' &&
        !(_provider.scheme == 'http' &&
            ['127.0.0.1', 'localhost', '::1'].contains(_provider.host))) {
      throw ArgumentError(
          'El proveedor debe usar HTTPS o loopback de pruebas.');
    }
  }

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
        await _send(request, 200,
            {'service': 'muondia-ai', 'protocol': 1, 'pid': pid,
             'capabilities': {'imageInput': true}});
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
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$')
              .hasMatch(body['application'] as String) ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,64}$')
              .hasMatch(body['schemaName'] as String) ||
          (body['input'] as String).length > 32000 ||
          body['schema'] is! Map<String, dynamic>) {
        await _send(request, 400, {'error': 'invalid_request'});
        return;
      }
      // Image bytes are supplied only by the authenticated Muondia client.
      // Validate before forwarding to Responses; never log pixel payloads.
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
          if (raw.length < 24 || raw.length > 3145728 ||
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
      _log({'error': 'connection_or_response_failure', 'type': error.runtimeType.toString(), 'detail': _safe(error.toString())});
      try {
        await _send(request, 502, {'error': 'connection_or_response_failure'});
      } catch (_) {
        // The caller may have disconnected.
      }
    } finally {
      http?.close(force: true);
    }
  }

  Future<({int status, Map<String, Object?> body})> _generate(
    HttpClient http,
    Map<String, dynamic> body,
  ) async {
    final upstream = await http.postUrl(_provider);
    upstream.followRedirects = false;
    upstream.headers.contentType = ContentType.json;
    upstream.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiKey');
    upstream.write(jsonEncode({
      'model': body['model'],
      'input': body['image'] is Map
          ? [
              {
                'role': 'user',
                'content': [
                  {'type': 'input_text', 'text': body['input']},
                  {
                    'type': 'input_image',
                    'image_url': 'data:image/png;base64,' +
                        (body['image']['data'] as String),
                  },
                ],
              }
            ]
          : body['input'],
      'store': false,
      'text': {
        'format': {
          'type': 'json_schema',
          'name': body['schemaName'],
          'strict': true,
          'schema': body['schema'],
        },
      },
    }));
    final response = await upstream.close();
    final text = await utf8.decoder.bind(response).join();
    Object? payload;
    try {
      payload = jsonDecode(text);
    } on FormatException {
      payload = null;
    }
    final requestId = _safe(response.headers.value('x-request-id'));
    if (response.statusCode != 200) {
      final error = payload is Map ? payload['error'] : null;
      final diagnostic = <String, Object?>{
        'providerStatus': response.statusCode,
        'requestId': requestId,
        for (final field in ['code', 'type', 'param', 'message'])
          if (error is Map && error[field] is String)
            field: _safe(error[field]),
      };
      return (
        status: 502,
        body: {'error': 'provider_rejected', 'diagnostic': diagnostic}
      );
    }
    if (payload is! Map ||
        payload['status'] != 'completed' ||
        payload['output'] is! List) {
      return (
        status: 502,
        body: {
          'error': 'incomplete_or_invalid_response',
          'diagnostic': {
            'requestId': requestId,
            'status': _safe(payload is Map ? payload['status'] : null),
            'reason': _safe(
                payload is Map && payload['incomplete_details'] is Map
                    ? payload['incomplete_details']['reason']
                    : null),
          },
        }
      );
    }
    final texts = <String>[];
    for (final item in payload['output'] as List) {
      if (item is! Map || item['content'] is! List) continue;
      for (final part in item['content'] as List) {
        if (part is! Map) continue;
        if (part['type'] == 'refusal') {
          return (
            status: 502,
            body: {
              'error': 'provider_refusal',
              'diagnostic': {'requestId': requestId}
            }
          );
        }
        if (part['type'] == 'output_text' && part['text'] is String) {
          texts.add(part['text'] as String);
        }
      }
    }
    if (texts.isEmpty) {
      return (status: 502, body: {'error': 'missing_output_text'});
    }
    final usage = payload['usage'];
    return (
      status: 200,
      body: {
        'text': texts.join(),
        if (usage is Map)
          'usage': {
            for (final entry in {
              'inputTokens': 'input_tokens',
              'outputTokens': 'output_tokens',
              'totalTokens': 'total_tokens'
            }.entries)
              if (usage[entry.value] is int) entry.key: usage[entry.value],
            if (usage['output_tokens_details'] is Map &&
                usage['output_tokens_details']['reasoning_tokens'] is int)
              'reasoningTokens': usage['output_tokens_details']['reasoning_tokens'],
            if (usage['input_tokens_details'] is Map &&
                usage['input_tokens_details']['cached_tokens'] is int)
              'cachedInputTokens': usage['input_tokens_details']['cached_tokens'],
          },
      }
    );
  }
}
