import 'dart:convert';
import 'dart:io';

import '../lib/muondia_ai_service.dart';

Future<void> main() async {
  final env = Platform.environment;
  final key = env['MUONDIA_DEEPSEEK_API_KEY'] ?? '';
  final token = env['MUONDIA_AI_TOKEN'] ?? '';
  final readyPath = env['MUONDIA_AI_READY_FILE'];
  if (key.trim().isEmpty || token.trim().isEmpty || readyPath == null) {
    stderr.writeln(
        'Falta la configuración privada del servicio. Usa scripts/ai.ps1 -Iniciar.');
    exitCode = 1;
    return;
  }
  try {
    final service = MuondiaAiService(apiKey: key, token: token);
    final requestedPort = int.tryParse(env['MUONDIA_AI_PORT'] ?? '') ?? 0;
    if (requestedPort < 0 || requestedPort > 65535) {
      throw const FormatException('Invalid service port');
    }
    final server = await service.start(port: requestedPort);
    final file = File(readyPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
        jsonEncode({
          'service': 'muondia-ai',
          'pid': pid,
          'endpoint': 'http://127.0.0.1:${server.port}',
          'token': token,
        }),
        flush: true);
    stdout.writeln('Muondia IA disponible en 127.0.0.1:${server.port}');
  } catch (_) {
    stderr.writeln('No se pudo iniciar el servicio Dart.');
    exitCode = 1;
  }
}
