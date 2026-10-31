import 'dart:convert';

import 'package:muondia_ai_client/muondia_ai_client.dart';

import 'onboarding_dimensions.dart';
import 'onboarding_quiz_ai_support.dart';
import 'onboarding_quiz_validation.dart';

// Una unidad de generación = una posición del test.
// Dart fija P, D e H; G devuelve F, Q, cuatro opciones O y la posición C.
// F es un andamiaje factual efímero de G: no entra en H, R ni en el test final.
// Las diez unidades de G se ejecutan simultáneamente y cada una se reintenta y
// valida por separado: una casilla fallida no invalida las demás.

/// La parte fija va primero y las variables (P, D, I_D, H) al final. DeepSeek
/// reutiliza el prefijo idéntico entre llamadas (caché de contexto), de modo que
/// las reglas comunes se facturan como entrada en caché.
const String onboardingQuizLunaPrompt = r'''(P,I_D,H) → F
(F,I_D) → Q
(F,Q) → O

F: afirmación factual autónoma mínima de cultura general generalista, no especializada ni de detalle.

I_D define la relación semántica que Q debe realizar, no su redacción.

Q es concisa, directa y autosuficiente, realiza I_D y tiene como máximo 160 caracteres.

F no forma parte del contexto disponible al responder Q.

Todo referente contextual de Q se resuelve en Q u O, nunca en F.

O := {o₁,o₂,o₃,o₄}, opciones distintas, plausibles, homogéneas y concisas; cada opción tiene como máximo 70 caracteres.

C := posición de la única opción correcta en O.

R := O_C

Q no contiene R ni una pista léxica evidente de R por forma, raíz, abreviación, símbolo, derivación o semejanza.

∀(Qᵢ,Rᵢ) ∈ H, Q pregunta un conocimiento materialmente distinto de Qᵢ.

R ∉ {R₁,...,Rₙ}

P := {{P}}
D := {{D}}
I_D := {{instruction}}
H := {{H}}
''';

String _historyLiteral(List<OnboardingQuizHistoryEntry> history) {
  if (history.isEmpty) return '∅';
  return '{${history.map((entry) => '(Q := ${jsonEncode(entry.question)}, R := ${jsonEncode(entry.answer)})').join(', ')}}';
}

String onboardingQuizLunaInput(
  OnboardingQuizPair slot,
  List<OnboardingQuizHistoryEntry> history,
) {
  return onboardingQuizLunaPrompt
      .replaceAll('{{P}}', slot.pivot.name)
      .replaceAll('{{D}}', slot.dimension.code)
      .replaceAll('{{instruction}}', slot.dimension.instruction)
      .replaceAll('{{H}}', _historyLiteral(history));
}

Map<String, Object?> onboardingQuizLunaSchema() => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['P', 'D', 'F', 'Q', 'O', 'C'],
  'properties': {
    'P': {'type': 'string'},
    'D': {'type': 'string'},
    'F': {'type': 'string'},
    'Q': {'type': 'string'},
    'O': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['o1', 'o2', 'o3', 'o4'],
      'properties': {
        'o1': {'type': 'string'},
        'o2': {'type': 'string'},
        'o3': {'type': 'string'},
        'o4': {'type': 'string'},
      },
    },
    'C': {
      'type': 'integer',
      'enum': [1, 2, 3, 4],
    },
  },
};

class OnboardingQuizLunaRow {
  const OnboardingQuizLunaRow({
    required this.slot,
    required this.returnedPivot,
    required this.returnedDimension,
    required this.fact,
    required this.question,
    required this.options,
    required this.correctPosition,
    required this.rawText,
  });

  final OnboardingQuizPair slot;
  final String returnedPivot;
  final String returnedDimension;
  final String fact;
  final String question;
  final List<String> options;
  final int correctPosition;
  final String rawText;

  String get correct {
    final index = correctPosition - 1;
    if (index < 0 || index >= options.length) return '';
    return options[index];
  }

  List<String> get distractors {
    final index = correctPosition - 1;
    return List.unmodifiable([
      for (var i = 0; i < options.length; i++)
        if (i != index) options[i],
    ]);
  }
}

OnboardingQuizLunaRow parseOnboardingQuizLunaRowOutput(
  String text,
  OnboardingQuizPair slot,
) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (error) {
    throw FormatException('JSON inválido: $error');
  }

  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('La salida no es un objeto JSON.');
  }
  if (decoded['P'] is! String ||
      decoded['D'] is! String ||
      decoded['F'] is! String ||
      decoded['Q'] is! String ||
      decoded['O'] is! Map<String, dynamic> ||
      decoded['C'] is! int) {
    throw const FormatException(
      'La salida no conserva la estructura P,D,F,Q,O,C esperada.',
    );
  }

  final rawOptions = decoded['O'] as Map<String, dynamic>;
  const keys = ['o1', 'o2', 'o3', 'o4'];
  if (keys.any((key) => rawOptions[key] is! String)) {
    throw const FormatException('O no contiene cuatro opciones textuales.');
  }

  return OnboardingQuizLunaRow(
    slot: slot,
    returnedPivot: decoded['P'] as String,
    returnedDimension: decoded['D'] as String,
    fact: decoded['F'] as String,
    question: decoded['Q'] as String,
    options: List.unmodifiable([
      for (final key in keys) rawOptions[key] as String,
    ]),
    correctPosition: decoded['C'] as int,
    rawText: text,
  );
}

/// Reglas deterministas de una fila de G: longitudes, cuatro opciones
/// distintas, posición correcta válida y respuesta ausente de la pregunta.
List<String> validateOnboardingQuizLunaRow(OnboardingQuizLunaRow row) {
  final problems = <String>[];
  if (row.correctPosition < 1 || row.correctPosition > row.options.length) {
    problems.add('posición correcta fuera de rango');
  }
  problems.addAll(
    validateOnboardingQuizContent(
      question: row.question,
      correct: row.correct,
      distractors: row.distractors,
    ),
  );
  return List.unmodifiable(problems);
}

class OnboardingQuizLunaFailure {
  const OnboardingQuizLunaFailure({
    required this.slot,
    required this.stage,
    required this.cause,
    this.rawText,
  });

  final OnboardingQuizPair slot;
  final String stage;
  final Object cause;
  final String? rawText;
}

/// Una casilla agotó sus intentos. Lleva el motivo del último fallo.
class OnboardingQuizLunaSlotException implements Exception {
  const OnboardingQuizLunaSlotException({
    required this.failure,
    required this.attempts,
  });

  final OnboardingQuizLunaFailure failure;
  final int attempts;

  @override
  String toString() =>
      'OnboardingQuizLunaSlotException: casilla ${failure.slot.number} '
      '(${failure.stage}) tras $attempts intento(s): ${failure.cause}';
}

typedef OnboardingQuizLunaResult = ({
  OnboardingQuizLunaRow row,
  Map<String, dynamic>? usage,
  int attempts,
});

final class AiOnboardingQuizLunaGenerator {
  AiOnboardingQuizLunaGenerator({
    required this.client,
    required this.model,
    this.maxAttempts = 3,
    this.thinking = false,
  });

  final MuondiaAiClient client;
  final String model;
  final int maxAttempts;
  final bool thinking;

  // Preguntas y respuestas finales ya usadas por cruce P×D.
  final Map<OnboardingQuizHistoryKey, List<OnboardingQuizHistoryEntry>>
      _historyByPivotDimension = {};

  List<OnboardingQuizHistoryEntry> historyFor(OnboardingQuizPair slot) =>
      List<OnboardingQuizHistoryEntry>.unmodifiable(
        _historyByPivotDimension[onboardingQuizHistoryKey(slot)] ??
            const <OnboardingQuizHistoryEntry>[],
      );

  /// Genera una casilla. Reintenta hasta [maxAttempts] veces si la llamada
  /// falla de forma transitoria, la salida no cumple la estructura o incumple
  /// las reglas locales. Solo esa casilla se regenera.
  Future<OnboardingQuizLunaResult> generateRow(
    OnboardingQuizPair slot,
    List<OnboardingQuizHistoryEntry> history,
  ) async {
    if (model.trim().isEmpty || client.authorization.trim().isEmpty) {
      throw StateError('Falta configurar el modelo o el token de IA.');
    }

    final usages = <Map<String, dynamic>?>[];
    Object? lastError;
    String? lastRaw;
    var stage = 'llamada';
    var attempts = 0;

    while (attempts < maxAttempts) {
      attempts++;
      try {
        final response = await client
            .generate(
              application: 'onboardingQuiz',
              model: model,
              input: onboardingQuizLunaInput(slot, history),
              schemaName: 'onboardingQuiz_luna_item',
              schema: onboardingQuizLunaSchema(),
              thinking: thinking,
              maxTokens: 1500,
            )
            .timeout(const Duration(seconds: 90));
        usages.add(response.usage);
        lastRaw = response.text;
        stage = 'estructura';
        final row = parseOnboardingQuizLunaRowOutput(response.text, slot);
        final problems = validateOnboardingQuizLunaRow(row);
        if (problems.isEmpty) {
          return (row: row, usage: mergeAiUsage(usages), attempts: attempts);
        }
        stage = 'validación';
        lastError = FormatException(problems.join('; '));
      } on FormatException catch (error) {
        lastError = error;
      } catch (error) {
        stage = 'llamada';
        lastError = error;
        if (!isRetryableAiError(error)) break;
      }
      if (attempts < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 300 * attempts));
      }
    }

    throw OnboardingQuizLunaSlotException(
      failure: OnboardingQuizLunaFailure(
        slot: slot,
        stage: stage,
        cause: lastError ?? StateError('La llamada no devolvió respuesta.'),
        rawText: lastRaw,
      ),
      attempts: attempts,
    );
  }

  void commitReviewedQuestions(
    List<OnboardingQuizLunaRow> rows,
    List<String> reviewedQuestions,
    List<String> reviewedAnswers,
  ) {
    if (rows.length != reviewedQuestions.length ||
        rows.length != reviewedAnswers.length) {
      throw ArgumentError('Filas, preguntas y respuestas revisadas no coinciden.');
    }

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      _historyByPivotDimension
          .putIfAbsent(
            onboardingQuizHistoryKey(row.slot),
            () => <OnboardingQuizHistoryEntry>[],
          )
          .add((
            question: reviewedQuestions[i],
            answer: reviewedAnswers[i],
          ));
    }
  }
}
