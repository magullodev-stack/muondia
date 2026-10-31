import 'dart:async';
import 'dart:io';

import 'package:muondia_ai_client/muondia_ai_client.dart';

/// Errores transitorios del servicio, de la red o de la salida del modelo que
/// merece la pena reintentar. Credenciales, saldo, rechazos del proveedor y
/// peticiones inválidas se propagan sin reintento.
bool isRetryableAiError(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is FormatException) {
    return true;
  }
  if (error is MuondiaAiException) {
    // Una respuesta cortada por límite de tokens fallaría igual otra vez.
    if (error.diagnostic?['reason'] == 'length') return false;
    if (error.statusCode == 504) return true;
    const transient = {
      'request_timeout',
      'invalid_structured_output',
      'missing_output_text',
      'incomplete_or_invalid_response',
      'connection_or_response_failure',
    };
    if (transient.contains(error.code)) return true;
    final status = error.diagnostic?['providerStatus'];
    return status == 429 || (status is int && status >= 500);
  }
  return false;
}

/// Ejecuta [run] hasta [attempts] veces con espera creciente entre intentos.
Future<T> retryAi<T>(
  Future<T> Function() run, {
  int attempts = 3,
  Duration backoff = const Duration(milliseconds: 400),
}) async {
  for (var attempt = 1;; attempt++) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= attempts || !isRetryableAiError(error)) rethrow;
      await Future<void>.delayed(backoff * attempt);
    }
  }
}

/// Suma el uso de varias llamadas. Ignora las que no informan de un campo, de
/// modo que un uso parcial no descarta todo el total.
Map<String, dynamic>? mergeAiUsage(Iterable<Map<String, dynamic>?> usages) {
  const keys = [
    'inputTokens',
    'outputTokens',
    'totalTokens',
    'reasoningTokens',
    'cachedInputTokens',
  ];
  final result = <String, dynamic>{};
  for (final usage in usages) {
    if (usage == null) continue;
    for (final key in keys) {
      final value = usage[key];
      if (value is int && value >= 0) {
        result[key] = ((result[key] as int?) ?? 0) + value;
      }
    }
  }
  return result.isEmpty ? null : result;
}
