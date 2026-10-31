import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muondia_ai_service/muondia_ai_service.dart';

void main() {
  late HttpServer provider;
  late MuondiaAiService service;
  late HttpClient http;
  late Uri endpoint;
  final logs = <Map<String, Object?>>[];
  const key = 'sk-test-secret-key';
  const token = 'local-secret-token';
  final body = {
    'application': 'muondia',
    'model': 'deepseek-flash',
    'input': 'Generate a value',
    'schemaName': 'test_result',
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'value': {'type': 'string'}
      },
      'required': ['value']
    },
  };

  /// Chat Completions response with a single choice.
  String completion(String? content,
          {String finish = 'stop', Map<String, Object?>? usage}) =>
      jsonEncode({
        'choices': [
          {
            'index': 0,
            'finish_reason': finish,
            'message': {'role': 'assistant', 'content': content},
          }
        ],
        if (usage != null) 'usage': usage,
      });

  setUp(() async {
    logs.clear();
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    service = MuondiaAiService(
        apiKey: key,
        token: token,
        provider:
            Uri.parse('http://127.0.0.1:${provider.port}/chat/completions'),
        log: logs.add,
        timeout: const Duration(seconds: 2));
    final server = await service.start();
    endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await service.close();
    await provider.close(force: true);
  });

  Future<({int status, Map<String, dynamic> body})> call({
    Object? payload,
    String path = '/v1/generate',
    String method = 'POST',
    String? authorization = 'Bearer local-secret-token',
    String? raw,
  }) async {
    final request = await http.openUrl(method, endpoint.resolve(path));
    if (authorization != null) {
      request.headers.set('authorization', authorization);
    }
    if (method == 'POST') request.write(raw ?? jsonEncode(payload ?? body));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>
    );
  }

  /// Serves [responses] in order, one per provider request, and records the
  /// decoded request bodies.
  List<Map<String, dynamic>> serve(List<String> responses) {
    final received = <Map<String, dynamic>>[];
    var index = 0;
    provider.listen((request) async {
      received.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      final next = responses[index < responses.length ? index : responses.length - 1];
      index++;
      request.response.write(next);
      await request.response.close();
    });
    return received;
  }

  test(
      'Chat Completions: JSON Output, clave solo al proveedor y extracción de texto/uso',
      () async {
    final served = provider.first.then((request) async {
      expect(request.uri.path, '/chat/completions');
      expect(request.headers.value('authorization'), 'Bearer $key');
      final input = jsonDecode(await utf8.decoder.bind(request).join());
      expect(input['model'], 'deepseek-flash');
      expect(input['response_format'], {'type': 'json_object'});
      expect(input['thinking'], {'type': 'disabled'});
      expect(input['max_tokens'], 8192);
      expect(input['stream'], false);
      final messages = input['messages'] as List;
      expect(messages.length, 2);
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], contains('JSON'));
      expect(messages.first['content'], contains('test_result'));
      expect(messages.first['content'], contains('"additionalProperties":false'));
      expect(messages.first['content'], contains('{"value":"texto"}'));
      expect(messages.last, {'role': 'user', 'content': body['input']});
      request.response.write(completion('{"value":"ok"}', usage: {
        'prompt_tokens': 12,
        'completion_tokens': 8,
        'total_tokens': 20,
        'prompt_cache_hit_tokens': 4,
        'prompt_cache_miss_tokens': 8,
        'completion_tokens_details': {'reasoning_tokens': 3},
      }));
      await request.response.close();
    });
    final result = await call();
    await served;
    expect(result.status, 200);
    expect(result.body['text'], '{"value":"ok"}');
    expect(result.body['attempts'], 1);
    expect(result.body['usage'], {
      'inputTokens': 12,
      'outputTokens': 8,
      'totalTokens': 20,
      'reasoningTokens': 3,
      'cachedInputTokens': 4,
    });
    expect(jsonEncode(logs), isNot(contains('Generate a value')));
    expect(jsonEncode(logs), isNot(contains('{"value"')));
  });

  test('thinking y maxTokens opcionales se reenvían al proveedor', () async {
    final received = serve([completion('{"value":"ok"}')]);
    final result = await call(payload: {
      ...body,
      'thinking': true,
      'maxTokens': 2000,
    });
    expect(result.status, 200);
    expect(received.single['thinking'], {'type': 'enabled'});
    expect(received.single['max_tokens'], 2000);
    expect((await call(payload: {...body, 'thinking': 'yes'})).status, 400);
    expect((await call(payload: {...body, 'maxTokens': 0})).status, 400);
    expect((await call(payload: {...body, 'maxTokens': 32769})).status, 400);
  });

  for (final status in [400, 401, 403, 429, 500]) {
    test('diagnóstico del proveedor HTTP $status sin credenciales', () async {
      final served = provider.first.then((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.set('x-ds-trace-id', 'req-test');
        request.response.write(jsonEncode({
          'error': {
            'type': 'invalid_request_error',
            'code': 'invalid_request',
            'param': 'response_format',
            'message':
                'Unsupported format. $key $token Bearer leaked sk-partial***key',
          }
        }));
        await request.response.close();
      });
      final result = await call();
      await served;
      expect(result.status, 502);
      expect(result.body['error'], 'provider_rejected');
      final diagnostic = result.body['diagnostic'];
      expect(diagnostic['providerStatus'], status);
      expect(diagnostic['requestId'], 'req-test');
      expect(diagnostic['param'], 'response_format');
      expect(diagnostic['message'], contains('Unsupported format'));
      for (final output in [jsonEncode(result.body), jsonEncode(logs)]) {
        for (final secret in [key, token, 'leaked', 'sk-partial']) {
          expect(output, isNot(contains(secret)));
        }
      }
    });
  }

  test('saldo agotado (402) se distingue de otros rechazos', () async {
    final served = provider.first.then((request) async {
      await request.drain<void>();
      request.response.statusCode = 402;
      request.response.write(jsonEncode({
        'error': {'message': 'Insufficient Balance', 'type': 'unknown_error'}
      }));
      await request.response.close();
    });
    final result = await call();
    await served;
    expect(result.status, 502);
    expect(result.body['error'], 'provider_insufficient_balance');
    expect(result.body['diagnostic']['providerStatus'], 402);
  });

  test('envía un PNG nativo junto al texto solo desde Muondia', () async {
    final bytes = [137, 80, 78, 71, 13, 10, 26, 10, ...List.filled(20, 0)];
    final encoded = base64Encode(bytes);
    final served = provider.first.then((request) async {
      final incoming = jsonDecode(await utf8.decoder.bind(request).join());
      final messages = incoming['messages'] as List;
      expect(messages.length, 2);
      final content = messages.last['content'] as List;
      expect(content.first, {'type': 'text', 'text': 'Generate a value'});
      expect(content.last['type'], 'image_url');
      expect(content.last['image_url']['url'], 'data:image/png;base64,$encoded');
      request.response.write(completion('{"value":"ok"}'));
      await request.response.close();
    });
    final result = await call(payload: {
      ...body,
      'application': 'muondia',
      'image': {'mimeType': 'image/png', 'data': encoded},
    });
    await served;
    expect(result.status, 200);
    expect(jsonEncode(logs), isNot(contains(encoded)));
    expect((await call(payload: {
      ...body,
      'application': 'otro',
      'image': {'mimeType': 'image/png', 'data': encoded},
    })).status, 400);
    expect((await call(payload: {
      ...body,
      'application': 'muondia',
      'image': {'mimeType': 'image/png', 'data': 'not-png'},
    })).status, 400);
  });

  test('autenticación y rutas se comprueban antes de llamar al proveedor',
      () async {
    expect((await call(authorization: null)).status, 401);
    expect((await call(authorization: 'Bearer incorrect')).status, 401);
    final health = (await call(path: '/health', method: 'GET')).body;
    expect(health['service'], 'muondia-ai');
    expect(health['provider'], 'deepseek');
    expect((await call(path: '/other')).status, 404);
    expect((await call(method: 'GET')).status, 405);
  });

  test('rechaza JSON, campos, esquema y tamaño inválidos', () async {
    expect((await call(raw: 'not json')).status, 400);
    expect((await call(payload: [])).status, 400);
    for (final field in [
      'application',
      'model',
      'input',
      'schemaName',
      'schema'
    ]) {
      expect((await call(payload: {...body, field: null})).status, 400);
    }
    expect((await call(raw: 'x' * (5 * 1024 * 1024 + 1))).status, 413);
    expect((await call(payload: {...body, 'input': 'x' * 32001})).status, 400);
  });

  group('salida estructurada', () {
    test('reintenta una vez si el contenido llega vacío y acumula el uso',
        () async {
      final received = serve([
        completion('', usage: {'prompt_tokens': 10, 'completion_tokens': 1}),
        completion('{"value":"ok"}',
            usage: {'prompt_tokens': 10, 'completion_tokens': 5}),
      ]);
      final result = await call();
      expect(result.status, 200);
      expect(result.body['text'], '{"value":"ok"}');
      expect(result.body['attempts'], 2);
      expect(result.body['usage'], {'inputTokens': 20, 'outputTokens': 6});
      expect(received.length, 2);
    });

    test('reintenta si no cumple el esquema y falla sin filtrar contenido',
        () async {
      final received = serve([
        completion('{"value":42,"secret":"contenido-generado"}'),
      ]);
      final result = await call();
      expect(received.length, 2);
      expect(result.status, 502);
      expect(result.body['error'], 'invalid_structured_output');
      final diagnostic = result.body['diagnostic'];
      expect(diagnostic['reason'], 'schema_mismatch');
      expect(diagnostic['attempts'], 2);
      expect(diagnostic['schemaErrors'],
          containsAll([contains(r'$.value'), contains(r'$.secret')]));
      for (final output in [jsonEncode(result.body), jsonEncode(logs)]) {
        expect(output, isNot(contains('contenido-generado')));
      }
    });

    test('JSON inválido se reintenta y no se trata como éxito', () async {
      final received = serve([completion('no es json')]);
      final result = await call();
      expect(received.length, 2);
      expect(result.status, 502);
      expect(result.body['error'], 'invalid_structured_output');
      expect(result.body, isNot(contains('text')));
    });

    test('finish_reason length no se reintenta ni devuelve JSON truncado',
        () async {
      final received = serve([completion('{"value":"cor', finish: 'length')]);
      final result = await call();
      expect(received.length, 1);
      expect(result.status, 502);
      expect(result.body['error'], 'incomplete_or_invalid_response');
      expect(result.body['diagnostic']['reason'], 'length');
      expect(result.body, isNot(contains('text')));
    });

    test('content_filter se informa como rechazo del proveedor', () async {
      final received = serve([completion('', finish: 'content_filter')]);
      final result = await call();
      expect(received.length, 1);
      expect(result.status, 502);
      expect(result.body['error'], 'provider_refusal');
    });

    test('insufficient_system_resource se reintenta', () async {
      final received = serve([
        completion('', finish: 'insufficient_system_resource'),
        completion('{"value":"ok"}'),
      ]);
      final result = await call();
      expect(received.length, 2);
      expect(result.status, 200);
    });
  });

  for (final response in [
    'not json',
    jsonEncode({'choices': []}),
    jsonEncode({'error': 'unexpected'}),
  ]) {
    test('no trata una respuesta incompleta como éxito: $response', () async {
      final served = provider.first.then((request) async {
        await request.drain<void>();
        request.response.write(response);
        await request.response.close();
      });
      final result = await call();
      await served;
      expect(result.status, 502);
      expect(result.body, isNot(contains('text')));
    });
  }

  test('timeout devuelve error recuperable', () async {
    provider.listen((request) {
      request.drain<void>();
    });
    expect((await call()).status, 504);
  });

  test('no admite transporte remoto sin TLS', () {
    expect(
        () => MuondiaAiService(
            apiKey: key,
            token: token,
            provider: Uri.parse('http://example.com')),
        throwsArgumentError);
  });

  test('el proveedor por defecto es DeepSeek sobre HTTPS', () {
    // Construir sin `provider` no abre conexiones; solo valida la clave.
    expect(() => MuondiaAiService(apiKey: key, token: token), returnsNormally);
    expect(() => MuondiaAiService(apiKey: 'no-prefix', token: token),
        throwsArgumentError);
  });
}
