import 'dart:convert';

import 'package:muondia_ai_client/muondia_ai_client.dart';

import 'onboarding_quiz_ai_support.dart';

/// Reglas fijas primero y el test variable al final (caché de contexto).
const String onboardingQuizSortPrompt = r'''G := persona no especialista con conocimientos generales

p(n) := P(conocer Rₙ dado Qₙ | G)

Orden := (n₁,...,n₁₀)

p(n₁) ≥ ... ≥ p(n₁₀)

T := {{TEST}}
''';

class OnboardingQuizSortItem {
  const OnboardingQuizSortItem({
    required this.question,
    required this.correct,
  });

  final String question;
  final String correct;
}

String onboardingQuizSortTestLiteral(List<OnboardingQuizSortItem> items) {
  if (items.length != 10) {
    throw ArgumentError('La ordenación requiere diez preguntas revisadas.');
  }

  return [
    for (var i = 0; i < items.length; i++)
      [
        '${i + 1}.',
        'Q: ${items[i].question}',
        'R: ${items[i].correct}',
      ].join('\n'),
  ].join('\n\n');
}

String onboardingQuizSortInput(List<OnboardingQuizSortItem> items) =>
    onboardingQuizSortPrompt.replaceAll('{{TEST}}', onboardingQuizSortTestLiteral(items));

/// `minItems`/`maxItems` fijan diez elementos: el servicio rechaza (y reintenta)
/// una lista de otra longitud antes de que llegue a la aplicación.
Map<String, Object?> onboardingQuizSortSchema() => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['Orden'],
  'properties': {
    'Orden': {
      'type': 'array',
      'minItems': 10,
      'maxItems': 10,
      'items': {
        'type': 'integer',
        'enum': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      },
    },
  },
};

class OnboardingQuizSortResult {
  const OnboardingQuizSortResult({
    required this.order,
    required this.rawText,
    required this.usage,
  });

  final List<int> order;
  final String rawText;
  final Map<String, dynamic>? usage;
}

OnboardingQuizSortResult parseOnboardingQuizSortOutput(
  String text, {
  Map<String, dynamic>? usage,
}) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (error) {
    throw FormatException('JSON de ordenación inválido: $error');
  }

  if (decoded is! Map<String, dynamic> || decoded['Orden'] is! List) {
    throw const FormatException(
      'La ordenación no conserva la estructura Orden.',
    );
  }

  final rawOrder = decoded['Orden'] as List;
  if (rawOrder.length != 10 || rawOrder.any((value) => value is! int)) {
    throw const FormatException('Orden debe contener diez números.');
  }

  final order = [for (final value in rawOrder) value as int];
  if (order.toSet().length != 10 ||
      order.any((value) => value < 1 || value > 10)) {
    throw const FormatException(
      'Orden debe ser una permutación de 1 a 10.',
    );
  }

  return OnboardingQuizSortResult(
    order: List.unmodifiable(order),
    rawText: text,
    usage: usage,
  );
}

final class AiOnboardingQuizSorter {
  AiOnboardingQuizSorter({
    required this.client,
    required this.model,
    this.thinking = false,
  });

  final MuondiaAiClient client;
  final String model;
  final bool thinking;

  /// Se reintenta ante fallos transitorios o una permutación inválida. Si aun
  /// así falla, el llamador decide el orden de reserva.
  Future<OnboardingQuizSortResult> sort(List<OnboardingQuizSortItem> items) {
    final input = onboardingQuizSortInput(items);
    return retryAi(() async {
      final response = await client
          .generate(
            application: 'onboardingQuiz-sort',
            model: model,
            input: input,
            schemaName: 'onboardingQuiz_sort',
            schema: onboardingQuizSortSchema(),
            thinking: thinking,
            maxTokens: 500,
          )
          .timeout(const Duration(seconds: 90));

      return parseOnboardingQuizSortOutput(
        response.text,
        usage: response.usage,
      );
    });
  }
}
