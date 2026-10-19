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
    'model': 'gpt-4.1-mini',
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

  setUp(() async {
    logs.clear();
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    service = MuondiaAiService(
        apiKey: key,
        token: token,
        provider: Uri.parse('http://127.0.0.1:${provider.port}/v1/responses'),
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
    if (authorization != null)
      request.headers.set('authorization', authorization);
    if (method == 'POST') request.write(raw ?? jsonEncode(payload ?? body));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>
    );
  }

  test(
      'Responses: esquema estricto, clave solo al proveedor y extracción de texto/uso',
      () async {
    final served = provider.first.then((request) async {
      expect(request.uri.path, '/v1/responses');
      expect(request.headers.value('authorization'), 'Bearer $key');
      final input = jsonDecode(await utf8.decoder.bind(request).join());
      expect(input['model'], 'gpt-4.1-mini');
      expect(input['input'], body['input']);
      expect(input['store'], false);
      expect(input['text']['format'], {
        'type': 'json_schema',
        'name': 'test_result',
        'strict': true,
        'schema': body['schema'],
      });
      request.response.write(jsonEncode({
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': '{"value":"ok"}'}
            ]
          }
        ],
        'usage': {'input_tokens': 12, 'output_tokens': 8, 'total_tokens': 20},
      }));
      await request.response.close();
    });
    final result = await call();
    await served;
    expect(result.status, 200);
    expect(result.body['text'], '{"value":"ok"}');
    expect(result.body['usage'],
        {'inputTokens': 12, 'outputTokens': 8, 'totalTokens': 20});
    expect(jsonEncode(logs), isNot(contains('Generate a value')));
    expect(jsonEncode(logs), isNot(contains('{"value"')));
  });

  for (final status in [400, 401, 403, 429, 500]) {
    test('diagnóstico del proveedor HTTP $status sin credenciales', () async {
      final served = provider.first.then((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.set('x-request-id', 'req-test');
        request.response.write(jsonEncode({
          'error': {
            'type': 'invalid_request_error',
            'code': 'invalid_json_schema',
            'param': 'text.format.schema',
            'message':
                'Unsupported minItems. $key $token Bearer leaked sk-partial***key',
          }
        }));
        await request.response.close();
      });
      final result = await call();
      await served;
      expect(result.status, 502);
      final diagnostic = result.body['diagnostic'];
      expect(diagnostic['providerStatus'], status);
      expect(diagnostic['requestId'], 'req-test');
      expect(diagnostic['param'], 'text.format.schema');
      expect(diagnostic['message'], contains('Unsupported minItems'));
      for (final output in [jsonEncode(result.body), jsonEncode(logs)]) {
        for (final secret in [key, token, 'leaked', 'sk-partial']) {
          expect(output, isNot(contains(secret)));
        }
      }
    });
  }

  test('envía un PNG nativo junto al texto solo desde Muondia', () async {
    final bytes = [137, 80, 78, 71, 13, 10, 26, 10, ...List.filled(20, 0)];
    final encoded = base64Encode(bytes);
    final served = provider.first.then((request) async {
      final incoming = jsonDecode(await utf8.decoder.bind(request).join());
      final messages = incoming['input'] as List;
      expect(messages.length, 1);
      final content = messages.first['content'] as List;
      expect(content.first['type'], 'input_text');
      expect(content.first['text'], 'Generate a value');
      expect(content.last['type'], 'input_image');
      expect(content.last['image_url'], 'data:image/png;base64,$encoded');
      request.response.write(jsonEncode({
        'status': 'completed',
        'output': [{'content': [{'type': 'output_text', 'text': '{"value":"ok"}'}]}]
      }));
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
    expect((await call(path: '/health', method: 'GET')).body['service'],
        'muondia-ai');
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

  for (final response in [
    'not json',
    jsonEncode({
      'status': 'incomplete',
      'incomplete_details': {'reason': 'max_output_tokens'}
    }),
    jsonEncode({'status': 'completed', 'output': []}),
    jsonEncode({
      'status': 'completed',
      'output': [
        {
          'content': [
            {'type': 'refusal', 'refusal': 'No'}
          ]
        }
      ]
    }),
  ]) {
    test('no trata una salida incompleta o rechazada como éxito: $response',
        () async {
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
}
