import 'dart:convert';

import 'package:muondia_ai_client/muondia_ai_client.dart';

import 'onboarding_quiz_ai_support.dart';
import 'onboarding_quiz_pipeline.dart';

/// Pista conceptual de una pregunta; no modifica las reglas ni las respuestas.
final class AiOnboardingQuizHintGenerator {
  const AiOnboardingQuizHintGenerator({
    required this.client,
    required this.model,
  });

  final MuondiaAiClient client;
  final String model;

  Future<String> generate(OnboardingQuizFinalQuestion question) async {
    if (client.authorization.trim().isEmpty || model.trim().isEmpty) {
      throw StateError('Falta la configuración de Pista IA.');
    }

    final prompt = [
      'Eres una ayuda educativa para un test contrarreloj.',
      'Ofrece una sola pista conceptual breve (máximo 25 palabras) que ayude a razonar.',
      'No reveles la solución, su letra, su posición, su valor ni una paráfrasis.',
      'No copies ni cites ninguna de las cuatro opciones.',
      'No des instrucciones para seleccionar una opción concreta.',
      'Devuelve exclusivamente el JSON solicitado.',
      'DATOS:',
      jsonEncode({
        'tematica': question.pivot,
        'pregunta': question.question,
        'opciones': question.options,
        'respuesta_correcta_para_evitar_revelarla': question.correct,
      }),
    ].join('\n');

    // Hay un cronómetro en pantalla: un solo reintento y sin razonamiento.
    return retryAi(
      () async {
        final response = await client
            .generate(
              application: 'onboardingQuiz-hint',
              model: model,
              input: prompt,
              schemaName: 'onboarding_quiz_hint',
              schema: {
                'type': 'object',
                'additionalProperties': false,
                'required': ['pista'],
                'properties': {
                  'pista': {'type': 'string'},
                },
              },
              thinking: false,
              maxTokens: 300,
            )
            .timeout(const Duration(seconds: 20));

        return validateOnboardingQuizHint(response.text, question);
      },
      attempts: 2,
      backoff: const Duration(milliseconds: 200),
    );
  }
}

String validateOnboardingQuizHint(
  String responseText,
  OnboardingQuizFinalQuestion question,
) {
  const invalid = FormatException('La pista de IA no es válida.');
  final Object? decoded;
  try {
    decoded = jsonDecode(responseText);
  } on FormatException {
    throw invalid;
  }
  if (decoded is! Map<String, dynamic> ||
      decoded.length != 1 ||
      decoded['pista'] is! String) {
    throw invalid;
  }
  final hint = (decoded['pista'] as String).trim();
  if (hint.isEmpty || hint.length > 220 || hint.split(RegExp(r'\s+')).length > 35) {
    throw invalid;
  }
  final normalizedHint = hint.toLowerCase();
  if (question.options.any(
    (option) => option.trim().length > 2 &&
        normalizedHint.contains(option.trim().toLowerCase()),
  )) {
    throw invalid;
  }
  return hint;
}
