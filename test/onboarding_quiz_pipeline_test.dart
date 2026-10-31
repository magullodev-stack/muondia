import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:muondia/app/onboarding/production/onboarding_dimensions.dart';
import 'package:muondia/app/onboarding/production/onboarding_prompt_g.dart';
import 'package:muondia/app/onboarding/production/onboarding_prompt_r.dart';
import 'package:muondia/app/onboarding/production/onboarding_quiz_ai_support.dart';
import 'package:muondia/app/onboarding/production/onboarding_quiz_hint.dart';
import 'package:muondia/app/onboarding/production/onboarding_quiz_pipeline.dart';
import 'package:muondia/app/onboarding/production/onboarding_quiz_validation.dart';
import 'package:muondia_ai_client/muondia_ai_client.dart';

typedef _Reply = ({int status, Map<String, Object?> body});
typedef _Responder = _Reply Function(String application, int nth);

_Reply _ok(String text) => (
  status: 200,
  body: {
    'text': text,
    'usage': {'inputTokens': 10, 'outputTokens': 5, 'totalTokens': 15},
  },
);

String _rowJson(int n) => jsonEncode({
  'P': 'Tema',
  'D': 'D01',
  'F': 'Hecho $n',
  'Q': 'Pregunta número $n sobre el tema',
  'O': {
    'o1': 'Alfa $n',
    'o2': 'Beta $n',
    'o3': 'Gamma $n',
    'o4': 'Delta $n',
  },
  'C': 1,
});

// Dos opciones iguales: la validación local la rechaza.
final String _badRowJson = jsonEncode({
  'P': 'Tema',
  'D': 'D01',
  'F': 'Hecho',
  'Q': 'Pregunta con opciones repetidas',
  'O': {'o1': 'Igual', 'o2': 'Igual', 'o3': 'Otra', 'o4': 'Distinta'},
  'C': 1,
});

_Reply _standard(String application, int nth) {
  switch (application) {
    case 'onboardingQuiz':
      return _ok(_rowJson(nth));
    case 'onboardingQuiz-review':
      return _ok('{"correcciones":[]}');
    case 'onboardingQuiz-sort':
      return _ok('{"Orden":[10,9,8,7,6,5,4,3,2,1]}');
  }
  return (status: 400, body: {'error': 'unknown_application'});
}

Future<({MuondiaAiClient client, Map<String, int> calls})> _start(
  _Responder respond,
) async {
  final calls = <String, int>{};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    final application = body['application'] as String;
    calls[application] = (calls[application] ?? 0) + 1;
    final reply = respond(application, calls[application]!);
    request.response.statusCode = reply.status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(reply.body));
    await request.response.close();
  });
  final client = MuondiaAiClient(
    endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    authorization: 'token',
  );
  addTearDown(() async {
    client.close();
    await server.close(force: true);
  });
  return (client: client, calls: calls);
}

AiOnboardingQuizPipeline _pipeline(MuondiaAiClient client) =>
    AiOnboardingQuizPipeline(
      client: client,
      lunaModel: 'deepseek-flash',
      reviewerModel: 'deepseek-flash',
    );

OnboardingQuizLunaRow _row({
  String question = 'Pregunta de prueba',
  List<String> options = const ['Alfa', 'Beta', 'Gamma', 'Delta'],
  int correctPosition = 1,
}) => OnboardingQuizLunaRow(
  slot: (
    number: 1,
    pivot: onboardingQuizPivots.first,
    dimension: onboardingQuizDimensions.first,
  ),
  returnedPivot: 'Tema',
  returnedDimension: 'D01',
  fact: 'Hecho',
  question: question,
  options: options,
  correctPosition: correctPosition,
  rawText: '{}',
);

void main() {
  group('validación local', () {
    test('acepta una pregunta correcta', () {
      expect(
        validateOnboardingQuizContent(
          question: '¿Cuál es la capital de Francia?',
          correct: 'París',
          distractors: ['Lyon', 'Marsella', 'Niza'],
        ),
        isEmpty,
      );
    });

    test('rechaza longitudes, opciones repetidas y respuesta en la pregunta', () {
      expect(
        validateOnboardingQuizContent(
          question: 'x' * 161,
          correct: 'A',
          distractors: ['B', 'C', 'D'],
        ),
        isNotEmpty,
      );
      expect(
        validateOnboardingQuizContent(
          question: '¿Qué es?',
          correct: 'y' * 71,
          distractors: ['B', 'C', 'D'],
        ),
        isNotEmpty,
      );
      // Mayúsculas y acentos no hacen distintas a dos opciones.
      expect(
        validateOnboardingQuizContent(
          question: '¿Qué es?',
          correct: 'Árbol',
          distractors: ['arbol', 'Roca', 'Río'],
        ),
        contains('opciones repetidas'),
      );
      expect(
        validateOnboardingQuizContent(
          question: '¿Qué ciudad es París?',
          correct: 'París',
          distractors: ['Lyon', 'Marsella', 'Niza'],
        ),
        contains('la pregunta contiene la respuesta'),
      );
    });

    test('opciones solo con símbolos no se consideran repetidas', () {
      expect(
        validateOnboardingQuizContent(
          question: '¿Qué constante relaciona circunferencia y diámetro?',
          correct: 'π',
          distractors: ['e', 'φ', '∞'],
        ),
        isEmpty,
      );
    });

    test('una fila de G con posición correcta fuera de rango no es válida', () {
      expect(
        validateOnboardingQuizLunaRow(_row(correctPosition: 5)),
        isNotEmpty,
      );
      expect(validateOnboardingQuizLunaRow(_row()), isEmpty);
    });
  });

  group('revisión y orden', () {
    test('una corrección que rompe las reglas locales se descarta', () {
      final row = _row();
      final review = OnboardingQuizReviewResult(
        patches: [
          // d1 igual a R: opciones repetidas, se conserva la fila original.
          OnboardingQuizReviewPatch(
            number: 1,
            changes: [
              OnboardingQuizReviewChange(field: 'd1', value: row.correct),
            ],
          ),
          // Corrección válida de la pregunta.
          const OnboardingQuizReviewPatch(
            number: 2,
            changes: [
              OnboardingQuizReviewChange(field: 'Q', value: 'Pregunta nueva'),
            ],
          ),
        ],
        calls: const [],
        usage: null,
      );
      final items = applyOnboardingQuizReview(List.filled(10, row), review);
      expect(items[0].distractors, row.distractors);
      expect(items[0].question, row.question);
      expect(items[1].question, 'Pregunta nueva');
      expect(items[2].question, row.question);
    });

    test('el orden debe ser una permutación de 1 a 10', () {
      final items = applyOnboardingQuizReview(
        List.filled(10, _row()),
        const OnboardingQuizReviewResult(patches: [], calls: [], usage: null),
      );
      expect(
        () => applyOnboardingQuizOrder(items, [1, 1, 3, 4, 5, 6, 7, 8, 9, 10]),
        throwsArgumentError,
      );
      expect(
        applyOnboardingQuizOrder(items, [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]),
        hasLength(10),
      );
    });
  });

  group('reintentos', () {
    test('retryAi reintenta fallos transitorios y devuelve el resultado', () async {
      var calls = 0;
      final result = await retryAi(() async {
        calls++;
        if (calls < 3) {
          throw const MuondiaAiException(502, code: 'request_timeout');
        }
        return 'ok';
      }, backoff: Duration.zero);
      expect(result, 'ok');
      expect(calls, 3);
    });

    test('retryAi no reintenta saldo agotado ni errores de credenciales', () async {
      var calls = 0;
      await expectLater(
        retryAi<void>(() async {
          calls++;
          throw const MuondiaAiException(
            502,
            code: 'provider_insufficient_balance',
            diagnostic: {'providerStatus': 402},
          );
        }, backoff: Duration.zero),
        throwsA(isA<MuondiaAiException>()),
      );
      expect(calls, 1);
    });
  });

  group('pipeline', () {
    test('genera diez preguntas con cuatro opciones y suma el uso', () async {
      final service = await _start(_standard);
      final result = await _pipeline(service.client).generateDetailed(
        planRandom: Random(1),
        optionRandom: Random(2),
      );

      expect(result.questions, hasLength(10));
      expect({for (final q in result.questions) q.question}, hasLength(10));
      for (final question in result.questions) {
        expect(question.options, hasLength(4));
        expect(question.options, contains(question.correct));
      }
      expect(result.attempts, everyElement(1));
      expect(result.sortFallback, isFalse);
      // El orden devuelto por el servicio falso invierte las diez preguntas.
      expect(
        result.questions.first.question,
        result.correctedItems.last.question,
      );
      expect(service.calls['onboardingQuiz'], 10);
      expect(service.calls['onboardingQuiz-review'], 10);
      expect(service.calls['onboardingQuiz-sort'], 1);
      expect(result.usage?['totalTokens'], 15 * 21);
    });

    test('solo se regenera la casilla fallida', () async {
      final service = await _start((application, nth) {
        if (application == 'onboardingQuiz' && nth == 1) {
          return _ok(_badRowJson);
        }
        return _standard(application, nth);
      });
      final result = await _pipeline(service.client).generateDetailed();

      expect(result.questions, hasLength(10));
      expect(service.calls['onboardingQuiz'], 11);
      expect(service.calls['onboardingQuiz-review'], 10);
      expect(result.attempts.where((attempts) => attempts == 2), hasLength(1));
      expect(result.attempts.where((attempts) => attempts == 1), hasLength(9));
    });

    test('si falla la ordenación se conserva el orden de generación', () async {
      final service = await _start((application, nth) {
        if (application == 'onboardingQuiz-sort') {
          return (
            status: 502,
            body: {
              'error': 'provider_rejected',
              'diagnostic': {'providerStatus': 500},
            },
          );
        }
        return _standard(application, nth);
      });
      final result = await _pipeline(service.client).generateDetailed();

      expect(result.sortFallback, isTrue);
      expect(result.questions, hasLength(10));
      expect(
        result.questions.first.question,
        result.correctedItems.first.question,
      );
      expect(service.calls['onboardingQuiz-sort'], 3);
    });

    test('un error no reintentable falla sin gastar llamadas de más', () async {
      final service = await _start((application, nth) {
        if (application == 'onboardingQuiz') {
          return (
            status: 502,
            body: {
              'error': 'provider_insufficient_balance',
              'diagnostic': {'providerStatus': 402},
            },
          );
        }
        return _standard(application, nth);
      });

      await expectLater(
        _pipeline(service.client).generate(),
        throwsA(isA<OnboardingQuizLunaSlotException>()),
      );
      expect(service.calls['onboardingQuiz'], 10);
      expect(service.calls['onboardingQuiz-review'], isNull);
    });

    test('prefetch genera una sola vez y generate recoge el resultado', () async {
      final service = await _start(_standard);
      final pipeline = _pipeline(service.client);

      pipeline.prefetch();
      pipeline.prefetch();
      final first = await pipeline.generate();
      expect(first, hasLength(10));
      expect(service.calls['onboardingQuiz'], 10);

      // El resultado precargado se consume una vez: la siguiente petición
      // genera un test nuevo.
      final second = await pipeline.generate();
      expect(second, hasLength(10));
      expect(service.calls['onboardingQuiz'], 20);
    });
  });

  group('pista', () {
    const question = (
      pivot: 'Geografía',
      question: '¿Cuál es la capital de Francia?',
      correct: 'París',
      options: ['París', 'Lyon', 'Marsella', 'Niza'],
    );

    test('acepta una pista que no copia las opciones', () {
      expect(
        validateOnboardingQuizHint(
          '{"pista":"Piensa en la ciudad del río Sena."}',
          question,
        ),
        'Piensa en la ciudad del río Sena.',
      );
    });

    test('rechaza pistas que citan una opción o que no son JSON válido', () {
      expect(
        () => validateOnboardingQuizHint(
          '{"pista":"Es la ciudad de París."}',
          question,
        ),
        throwsFormatException,
      );
      expect(
        () => validateOnboardingQuizHint('no es json', question),
        throwsFormatException,
      );
    });

    test('la pista se pide al servicio con el esquema esperado', () async {
      final service = await _start((application, nth) {
        return _ok('{"pista":"Piensa en el río Sena."}');
      });
      final hint = await AiOnboardingQuizHintGenerator(
        client: service.client,
        model: 'deepseek-flash',
      ).generate(question);
      expect(hint, 'Piensa en el río Sena.');
      expect(service.calls['onboardingQuiz-hint'], 1);
    });
  });
}
