import 'dart:math';

import 'package:muondia_ai_client/muondia_ai_client.dart';

import 'onboarding_dimensions.dart';
import 'onboarding_prompt_g.dart';
import 'onboarding_prompt_r.dart';
import 'onboarding_prompt_s.dart';
import 'onboarding_quiz_ai_support.dart';
import 'onboarding_quiz_validation.dart';

typedef OnboardingQuizFinalQuestion = ({
  String pivot,
  String question,
  String correct,
  List<String> options,
});

class OnboardingQuizReviewedItem {
  const OnboardingQuizReviewedItem({
    required this.source,
    required this.question,
    required this.correct,
    required this.distractors,
  });

  final OnboardingQuizLunaRow source;
  final String question;
  final String correct;
  final List<String> distractors;
}

class OnboardingQuizPipelineResult {
  const OnboardingQuizPipelineResult({
    required this.plan,
    required this.lunaRows,
    required this.review,
    required this.correctedItems,
    required this.sort,
    required this.sortFallback,
    required this.reviewedItems,
    required this.questions,
    required this.produceDuration,
    required this.sortDuration,
    required this.attempts,
    required this.usage,
  });

  final List<OnboardingQuizPair> plan;
  final List<OnboardingQuizLunaRow> lunaRows;
  final OnboardingQuizReviewResult review;
  final List<OnboardingQuizReviewedItem> correctedItems;

  /// `null` si la ordenación falló y se usó el orden de generación.
  final OnboardingQuizSortResult? sort;
  final bool sortFallback;
  final List<OnboardingQuizReviewedItem> reviewedItems;
  final List<OnboardingQuizFinalQuestion> questions;

  /// Generación y revisión, encadenadas por casilla.
  final Duration produceDuration;
  final Duration sortDuration;

  /// Intentos de generación por casilla (1 = a la primera).
  final List<int> attempts;

  /// Uso total de todas las llamadas del test.
  final Map<String, dynamic>? usage;
}

/// Aplica las correcciones del revisor. Si el resultado incumple las reglas
/// locales (opciones repetidas, textos demasiado largos...), conserva la fila
/// original de G, que ya las había superado.
List<OnboardingQuizReviewedItem> applyOnboardingQuizReview(
  List<OnboardingQuizLunaRow> rows,
  OnboardingQuizReviewResult review,
) {
  if (rows.length != 10) {
    throw ArgumentError('OnboardingQuiz requiere diez filas.');
  }

  final patchesByNumber = {
    for (final patch in review.patches) patch.number: patch,
  };

  return List.unmodifiable([
    for (var i = 0; i < rows.length; i++)
      _applyReviewPatch(
        rows[i],
        patchesByNumber[i + 1],
      ),
  ]);
}

OnboardingQuizReviewedItem _applyReviewPatch(
  OnboardingQuizLunaRow row,
  OnboardingQuizReviewPatch? patch,
) {
  final original = OnboardingQuizReviewedItem(
    source: row,
    question: row.question,
    correct: row.correct,
    distractors: row.distractors,
  );
  if (patch == null || patch.changes.isEmpty) return original;

  var question = row.question;
  var correct = row.correct;
  final distractors = [...row.distractors];

  for (final change in patch.changes) {
    switch (change.field) {
      case 'Q':
        question = change.value;
        break;
      case 'R':
        correct = change.value;
        break;
      case 'd1':
        distractors[0] = change.value;
        break;
      case 'd2':
        distractors[1] = change.value;
        break;
      case 'd3':
        distractors[2] = change.value;
        break;
    }
  }

  final problems = validateOnboardingQuizContent(
    question: question,
    correct: correct,
    distractors: distractors,
  );
  if (problems.isNotEmpty) return original;

  return OnboardingQuizReviewedItem(
    source: row,
    question: question,
    correct: correct,
    distractors: List.unmodifiable(distractors),
  );
}

List<OnboardingQuizSortItem> buildOnboardingQuizSortItems(
  List<OnboardingQuizReviewedItem> items,
) => List.unmodifiable([
  for (final item in items)
    OnboardingQuizSortItem(
      question: item.question,
      correct: item.correct,
    ),
]);

List<OnboardingQuizReviewedItem> applyOnboardingQuizOrder(
  List<OnboardingQuizReviewedItem> items,
  List<int> order,
) {
  if (items.length != 10 ||
      order.length != 10 ||
      order.toSet().length != 10 ||
      order.any((value) => value < 1 || value > 10)) {
    throw ArgumentError('OnboardingQuiz requiere una permutación de 1 a 10.');
  }

  return List.unmodifiable([
    for (final number in order) items[number - 1],
  ]);
}

List<OnboardingQuizFinalQuestion> buildOnboardingQuizFinalQuestions(
  List<OnboardingQuizReviewedItem> reviewedItems, {
  Random? random,
}) {
  final rng = random ?? Random();
  return List.unmodifiable([
    for (final item in reviewedItems)
      (
        pivot: item.source.slot.pivot.name,
        question: item.question,
        correct: item.correct,
        options: List<String>.unmodifiable(
          [item.correct, ...item.distractors]..shuffle(rng),
        ),
      ),
  ]);
}

typedef _Produced = ({
  OnboardingQuizLunaResult generated,
  OnboardingQuizReviewCall review,
});

final class AiOnboardingQuizPipeline {
  AiOnboardingQuizPipeline({
    required MuondiaAiClient client,
    required String lunaModel,
    required String reviewerModel,
    String? sorterModel,
    bool lunaThinking = false,
    bool reviewThinking = false,
    bool sortThinking = false,
  }) : luna = AiOnboardingQuizLunaGenerator(
         client: client,
         model: lunaModel,
         thinking: lunaThinking,
       ),
       reviewer = AiOnboardingQuizReviewer(
         client: client,
         model: reviewerModel,
         thinking: reviewThinking,
       ),
       sorter = AiOnboardingQuizSorter(
         client: client,
         model: sorterModel ?? reviewerModel,
         thinking: sortThinking,
       );

  final AiOnboardingQuizLunaGenerator luna;
  final AiOnboardingQuizReviewer reviewer;
  final AiOnboardingQuizSorter sorter;

  final Map<OnboardingQuizHistoryKey, int> _usageByPair = {};
  Future<List<OnboardingQuizFinalQuestion>>? _prefetched;

  Map<OnboardingQuizHistoryKey, int> get usageByPair =>
      Map.unmodifiable(_usageByPair);

  /// Empieza a generar el test en segundo plano (p. ej. al completar el
  /// registro o durante la secuencia de introducción). La siguiente llamada a
  /// [generate] recoge ese resultado en lugar de pedir otro. Si no hay usuario
  /// esperando, un fallo se descarta sin ruido y [generate] volverá a intentarlo.
  void prefetch() {
    if (_prefetched != null) return;
    final pending = generateDetailed().then((result) => result.questions);
    pending.ignore();
    _prefetched = pending;
  }

  Future<List<OnboardingQuizFinalQuestion>> generate() {
    final pending = _prefetched;
    _prefetched = null;
    if (pending != null) return pending;
    return generateDetailed().then((result) => result.questions);
  }

  Future<OnboardingQuizPipelineResult> generateDetailed({
    Random? planRandom,
    Random? optionRandom,
  }) async {
    final plan = selectOnboardingQuizPairs(
      planRandom ?? Random(),
      usageByPair: _usageByPair,
    );
    final histories = [for (final slot in plan) luna.historyFor(slot)];

    // Cada casilla encadena generar → revisar sin esperar a las demás, y cada
    // paso se reintenta por separado: una casilla lenta o fallida no retrasa ni
    // invalida las otras nueve.
    final produceWatch = Stopwatch()..start();
    final produced = await Future.wait<_Produced>([
      for (var i = 0; i < plan.length; i++)
        _produce(i + 1, plan[i], histories[i]),
    ]);
    produceWatch.stop();

    final lunaRows = [for (final item in produced) item.generated.row];
    final calls = [for (final item in produced) item.review];
    final review = OnboardingQuizReviewResult(
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

    final correctedItems = applyOnboardingQuizReview(lunaRows, review);

    // La ordenación mejora la experiencia pero no la corrección del test: si
    // falla tras sus reintentos se conserva el orden de generación.
    final sortWatch = Stopwatch()..start();
    OnboardingQuizSortResult? sort;
    try {
      sort = await sorter.sort(buildOnboardingQuizSortItems(correctedItems));
    } catch (_) {
      sort = null;
    }
    sortWatch.stop();

    final reviewedItems = applyOnboardingQuizOrder(
      correctedItems,
      sort?.order ?? [for (var i = 1; i <= 10; i++) i],
    );

    luna.commitReviewedQuestions(
      correctedItems.map((item) => item.source).toList(growable: false),
      correctedItems.map((item) => item.question).toList(growable: false),
      correctedItems.map((item) => item.correct).toList(growable: false),
    );

    final questions = buildOnboardingQuizFinalQuestions(
      reviewedItems,
      random: optionRandom,
    );

    for (final slot in plan) {
      _usageByPair.update(
        onboardingQuizHistoryKey(slot),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    return OnboardingQuizPipelineResult(
      plan: List.unmodifiable(plan),
      lunaRows: List.unmodifiable(lunaRows),
      review: review,
      correctedItems: correctedItems,
      sort: sort,
      sortFallback: sort == null,
      reviewedItems: reviewedItems,
      questions: questions,
      produceDuration: produceWatch.elapsed,
      sortDuration: sortWatch.elapsed,
      attempts: List.unmodifiable([
        for (final item in produced) item.generated.attempts,
      ]),
      usage: mergeAiUsage([
        for (final item in produced) item.generated.usage,
        review.usage,
        sort?.usage,
      ]),
    );
  }

  Future<_Produced> _produce(
    int number,
    OnboardingQuizPair slot,
    List<OnboardingQuizHistoryEntry> history,
  ) async {
    final generated = await luna.generateRow(slot, history);
    final review = await reviewer.reviewOne(number, generated.row);
    return (generated: generated, review: review);
  }
}
