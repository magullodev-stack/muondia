/// Contrato de autenticación propio de Muondia, sin credenciales.
abstract interface class AuthService {
  Future<void> signInWithGoogle();
  Future<void> signInWithApple();
  Future<void> signInWithEmail({
    required String email,
    required String password,
  });
  Future<void> registerWithEmail({
    required String email,
    required String password,
  });
  Future<void> sendPasswordReset({required String email});
}

enum AuthFailureCode {
  notConfigured,
  invalidEmail,
  weakPassword,
  wrongCredentials,
  emailAlreadyInUse,
  userDisabled,
  network,
  tooManyRequests,
  providerNotReady,
  cancelled,
  unknown,
}

final class AuthFailure implements Exception {
  const AuthFailure(this.code);
  final AuthFailureCode code;
}

/// Muestra Auth sin conectarse al proyecto de identidad anterior.
/// No crea sesiones ficticias ni da accesos por válidos.
final class UnconfiguredAuthService implements AuthService {
  const UnconfiguredAuthService();

  Never _unavailable() => throw const AuthFailure(AuthFailureCode.notConfigured);

  @override
  Future<void> signInWithGoogle() async { _unavailable(); }

  @override
  Future<void> signInWithApple() async { _unavailable(); }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async { _unavailable(); }

  @override
  Future<void> registerWithEmail({
    required String email,
    required String password,
  }) async { _unavailable(); }

  @override
  Future<void> sendPasswordReset({required String email}) async {
    _unavailable();
  }
}
