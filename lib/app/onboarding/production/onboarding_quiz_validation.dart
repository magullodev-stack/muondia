/// Validaciones locales y gratuitas de una pregunta de OnboardingQuiz.
/// Se ejecutan antes y después de la revisión por IA para no gastar llamadas
/// en filas que ya incumplen reglas deterministas.
const int onboardingQuizMaxQuestionLength = 160;
const int onboardingQuizMaxOptionLength = 70;

const String _accentsFrom = 'áàäâãéèëêíìïîóòöôõúùüûñç';
const String _accentsTo = 'aaaaa' 'eeee' 'iiii' 'ooooo' 'uuuu' 'nc';

/// Minúsculas, sin acentos ni puntuación y con espacios simples.
String normalizeQuizText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final index = _accentsFrom.indexOf(char);
    buffer.write(index >= 0 ? _accentsTo[index] : char);
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// Una opción solo con símbolos (π, ∞, φ) se normalizaría a vacío; en ese caso
// se compara el texto original para no marcar como repetidas opciones distintas.
String _comparable(String text) {
  final normalized = normalizeQuizText(text);
  return normalized.isEmpty ? text.trim().toLowerCase() : normalized;
}

bool _containsPhrase(String haystack, String needle) =>
    ' $haystack '.contains(' $needle ');

/// Devuelve los problemas encontrados; una lista vacía significa válida.
/// Los mensajes describen la regla incumplida, nunca el contenido.
List<String> validateOnboardingQuizContent({
  required String question,
  required String correct,
  required List<String> distractors,
}) {
  final problems = <String>[];
  final trimmedQuestion = question.trim();
  if (trimmedQuestion.isEmpty) {
    problems.add('pregunta vacía');
  } else if (trimmedQuestion.runes.length > onboardingQuizMaxQuestionLength) {
    problems.add('pregunta de más de $onboardingQuizMaxQuestionLength caracteres');
  }
  if (distractors.length != 3) {
    problems.add('se esperaban tres distractores');
  }
  final options = [correct, ...distractors];
  for (final option in options) {
    final trimmed = option.trim();
    if (trimmed.isEmpty) {
      problems.add('opción vacía');
    } else if (trimmed.runes.length > onboardingQuizMaxOptionLength) {
      problems.add('opción de más de $onboardingQuizMaxOptionLength caracteres');
    }
  }
  final keys = options.map(_comparable).toList();
  if (keys.toSet().length != keys.length) {
    problems.add('opciones repetidas');
  }
  final answerKey = _comparable(correct);
  if (answerKey.length >= 3 &&
      _containsPhrase(_comparable(question), answerKey)) {
    problems.add('la pregunta contiene la respuesta');
  }
  return List.unmodifiable(problems);
}
