import 'dart:convert';

import 'package:muondia_ai_client/muondia_ai_client.dart';

import 'onboarding_prompt_g.dart';
import 'onboarding_quiz_ai_support.dart';

/// Reglas fijas primero y el ítem variable al final, para aprovechar la caché
/// de contexto de DeepSeek entre las diez revisiones.
const String onboardingQuizReviewPrompt = r'''O := {R,d1,d2,d3}

C := {o ∈ O : o responde correctamente a Q}

A := {a ∈ Q : a requiere un referente contextual y referente(a,Q,O) = ∅}

C = {R} ⇒ Δ = ∅

C ≠ {R} ⇒ Δ contiene únicamente correcciones de R,d1,d2,d3 necesarias para que C = {R}.

A = ∅ ⇒ Q' = Q

A ≠ ∅ ⇒ Q' difiere de Q únicamente en sustituir cada a ∈ A por un referente explícito inferido de Q,O,R.

Cualquier otra modificación de Q está prohibida.

t := {{ITEM}}
''';

String onboardingQuizReviewItemLiteral(OnboardingQuizLunaRow row) => [
  'Q: ${row.question}',
  'R: ${row.correct}',
  'd1: ${row.distractors[0]}',
  'd2: ${row.distractors[1]}',
  'd3: ${row.distractors[2]}',
].join('\n');

String onboardingQuizReviewInput(OnboardingQuizLunaRow row) =>
    onboardingQuizReviewPrompt.replaceAll('{{ITEM}}', onboardingQuizReviewItemLiteral(row));

Map<String, Object?> onboardingQuizReviewSchema() => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['correcciones'],
  'properties': {
    'correcciones': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['campo', 'valor'],
        'properties': {
          'campo': {
            'type': 'string',
            'enum': ['Q', 'R', 'd1', 'd2', 'd3'],
          },
          'valor': {'type': 'string'},
        },
      },
    },
  },
};

class OnboardingQuizReviewChange {
  const OnboardingQuizReviewChange({
    required this.field,
    required this.value,
  });

  final String field;
  final String value;
}

class OnboardingQuizReviewPatch {
  const OnboardingQuizReviewPatch({
    required this.number,
    required this.changes,
  });

  final int number;
  final List<OnboardingQuizReviewChange> changes;
}

class OnboardingQuizReviewCall {
  const OnboardingQuizReviewCall({
    required this.number,
    required this.input,
    required this.rawText,
    required this.changes,
    required this.usage,
  });

  final int number;
  final String input;
  final String rawText;
  final List<OnboardingQuizReviewChange> changes;
  final Map<String, dynamic>? usage;
}

class OnboardingQuizReviewResult {
  const OnboardingQuizReviewResult({
    required this.patches,
    required this.calls,
    required this.usage,
  });

  final List<OnboardingQuizReviewPatch> patches;
  final List<OnboardingQuizReviewCall> calls;
  final Map<String, dynamic>? usage;
}

List<OnboardingQuizReviewChange> parseOnboardingQuizReviewItemOutput(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (error) {
    throw FormatException('JSON de revisión inválido: $error');
  }

  if (decoded is! Map<String, dynamic> ||
      decoded['correcciones'] is! List) {
    throw const FormatException(
      'La revisión no conserva la estructura correcciones.',
    );
  }

  final changes = <OnboardingQuizReviewChange>[];
  final seenFields = <String>{};

  for (final rawChange in decoded['correcciones'] as List) {
    if (rawChange is! Map<String, dynamic> ||
        rawChange['campo'] is! String ||
        rawChange['valor'] is! String) {
      throw const FormatException('Corrección estructuralmente inválida.');
    }

    final field = rawChange['campo'] as String;
    if (!const {'Q', 'R', 'd1', 'd2', 'd3'}.contains(field) ||
        !seenFields.add(field)) {
      throw const FormatException(
        'Cada campo revisable puede corregirse una sola vez.',
      );
    }

    changes.add(
      OnboardingQuizReviewChange(
        field: field,
        value: rawChange['valor'] as String,
      ),
    );
  }

  return List.unmodifiable(changes);
}

final class AiOnboardingQuizReviewer {
  AiOnboardingQuizReviewer({
    required this.client,
    required this.model,
    this.thinking = false,
  });

  final MuondiaAiClient client;
  final String model;

  /// El razonamiento de DeepSeek puede mejorar la comprobación de «una única
  /// opción correcta», a costa de latencia y tokens. Desactivado por defecto.
  final bool thinking;

  Future<OnboardingQuizReviewResult> review(List<OnboardingQuizLunaRow> rows) async {
    if (rows.length != 10) {
      throw ArgumentError('La revisión requiere diez filas de G.');
    }

    final calls = await Future.wait([
      for (var i = 0; i < rows.length; i++) reviewOne(i + 1, rows[i]),
    ]);

    return OnboardingQuizReviewResult(
      patches: List.unmodifiable([
        for (final call in calls)
          if (call.changes.isNotEmpty)
            OnboardingQuizReviewPatch(
              number: call.number,
              changes: call.changes,
            ),
      ]),
      calls: List.unmodifiable(calls),
      usage: mergeAiUsage(calls.map((call) => call.usage)),
    );
  }

  /// Revisa una sola fila. Se reintenta ante fallos transitorios o salida mal
  /// formada.
  Future<OnboardingQuizReviewCall> reviewOne(
    int number,
    OnboardingQuizLunaRow row,
  ) {
    final input = onboardingQuizReviewInput(row);
    return retryAi(() async {
      final response = await client
          .generate(
            application: 'onboardingQuiz-review',
            model: model,
            input: input,
            schemaName: 'onboardingQuiz_review_item',
            schema: onboardingQuizReviewSchema(),
            thinking: thinking,
            maxTokens: 1000,
          )
          .timeout(const Duration(seconds: 90));

      return OnboardingQuizReviewCall(
        number: number,
        input: input,
        rawText: response.text,
        changes: parseOnboardingQuizReviewItemOutput(response.text),
        usage: response.usage,
      );
    });
  }
}
