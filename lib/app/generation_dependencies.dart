import 'package:muondia_ai_client/muondia_ai_client.dart';

import 'onboarding/production/onboarding_quiz_hint.dart';
import 'onboarding/production/onboarding_quiz_pipeline.dart';

/// Conecta la aplicación con el servicio de IA local (`ai/service`).
///
/// La app nunca recibe la clave de DeepSeek: solo la URL del servicio y su
/// token de sesión, que se inyectan al lanzar con `--dart-define`:
///   MUONDIA_AI_URL    (por defecto http://127.0.0.1:8787)
///   MUONDIA_AI_TOKEN
///   MUONDIA_AI_MODEL  (por defecto deepseek-flash)
final class MuondiaGenerationDependencies {
  MuondiaGenerationDependencies()
    : _client = MuondiaAiClient(
        endpoint: Uri.parse(
          const String.fromEnvironment(
            'MUONDIA_AI_URL',
            defaultValue: 'http://127.0.0.1:8787',
          ),
        ),
        authorization: const String.fromEnvironment('MUONDIA_AI_TOKEN'),
      );

  final MuondiaAiClient _client;

  static const String _model = String.fromEnvironment(
    'MUONDIA_AI_MODEL',
    defaultValue: 'deepseek-flash',
  );

  late final AiOnboardingQuizPipeline onboardingQuizPipeline =
      AiOnboardingQuizPipeline(
        client: _client,
        lunaModel: _model,
        reviewerModel: _model,
        sorterModel: _model,
      );

  late final AiOnboardingQuizHintGenerator onboardingQuizHint =
      AiOnboardingQuizHintGenerator(client: _client, model: _model);

  void close() => _client.close();
}
