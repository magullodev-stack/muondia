import 'auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../../development/visual_layers.dart';

enum EmailAuthMode {
  signIn,
  register,
}

class EmailAuthPage extends StatefulWidget {
  const EmailAuthPage({
    super.key,
    required this.auth,
  });

  final AuthService auth;

  @override
  State<EmailAuthPage> createState() => _EmailAuthPageState();
}

class _EmailAuthPageState extends State<EmailAuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  EmailAuthMode _mode = EmailAuthMode.signIn;
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    if (_mode == EmailAuthMode.register &&
        _password.text != _confirmation.text) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (_mode == EmailAuthMode.signIn) {
        await widget.auth.signInWithEmail(
          email: _email.text,
          password: _password.text,
        );
      } else {
        await widget.auth.registerWithEmail(
          email: _email.text,
          password: _password.text,
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop();
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() => _error = _failureMessage(failure));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No se ha podido completar el acceso.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resetPassword() async {
    FocusScope.of(context).unfocus();

    final email = _email.text.trim();
    if (!_looksLikeEmail(email)) {
      setState(() => _error = 'Introduce primero un email válido.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await widget.auth.sendPasswordReset(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Te hemos enviado un enlace para restablecer la contraseña.',
          ),
        ),
      );
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() => _error = _failureMessage(failure));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _setMode(EmailAuthMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _error = null;
      _confirmation.clear();
    });
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Introduce tu email.';
    if (!_looksLikeEmail(email)) return 'Introduce un email válido.';
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Introduce tu contraseña.';
    if (_mode == EmailAuthMode.register && password.length < 6) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }
    return null;
  }

  bool _looksLikeEmail(String value) {
    final at = value.indexOf('@');
    final dot = value.lastIndexOf('.');
    return at > 0 && dot > at + 1 && dot < value.length - 1;
  }

  String _failureMessage(AuthFailure failure) {
    return switch (failure.code) {
      AuthFailureCode.notConfigured =>
        'El servicio de acceso todavía no está configurado.',
      AuthFailureCode.invalidEmail => 'El email no es válido.',
      AuthFailureCode.weakPassword => 'La contraseña es demasiado débil.',
      AuthFailureCode.wrongCredentials =>
        'El email o la contraseña no son correctos.',
      AuthFailureCode.emailAlreadyInUse =>
        'Ya existe una cuenta con este email.',
      AuthFailureCode.userDisabled => 'Esta cuenta está desactivada.',
      AuthFailureCode.network =>
        'No hay conexión. Comprueba tu red e inténtalo de nuevo.',
      AuthFailureCode.tooManyRequests =>
        'Demasiados intentos. Espera un poco y vuelve a probar.',
      AuthFailureCode.providerNotReady =>
        'Este método de acceso todavía no está disponible.',
      AuthFailureCode.cancelled => 'Acceso cancelado.',
      AuthFailureCode.unknown =>
        'No se ha podido completar el acceso.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final creating = _mode == EmailAuthMode.register;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.black,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        key: const Key('muondia-email-auth'),
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // En Android edge-to-edge, el fondo ampliado no debe pintar
            // sobre la barra de estado ni sobre la barra de navegacion.
            SafeArea(
              top: true,
              bottom: true,
              child: ClipRect(
                child: Transform.scale(
                  scale: 1.30,
                  child: Opacity(
                    opacity: MuondiaVisualLayers.showBackground ? 1 : 0,
                    child: Image.asset(
                      'assets/auth/Background.png',
                      key: const Key('muondia-email-auth-background'),
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Volver',
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 460),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xD90B0913),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: const Color(0x667C63FF),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x66000000),
                                  blurRadius: 28,
                                  offset: Offset(0, 14),
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: AutofillGroup(
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'Continuar con email',
                                        textAlign: TextAlign.center,
                                        style: MuondiaTypography.screenTitle
                                            .copyWith(
                                          color: Colors.white,
                                          fontSize: 26,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        creating
                                            ? 'Crea tu cuenta de Muondia.'
                                            : 'Entra en tu cuenta de Muondia.',
                                        textAlign: TextAlign.center,
                                        style: MuondiaTypography.bodySecondary
                                            .copyWith(
                                          color: const Color(0xFFC9C1DD),
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      SegmentedButton<EmailAuthMode>(
                                        segments: const [
                                          ButtonSegment(
                                            value: EmailAuthMode.signIn,
                                            label: Text('Iniciar sesión'),
                                          ),
                                          ButtonSegment(
                                            value: EmailAuthMode.register,
                                            label: Text('Crear cuenta'),
                                          ),
                                        ],
                                        selected: {_mode},
                                        onSelectionChanged: _submitting
                                            ? null
                                            : (selection) =>
                                                _setMode(selection.single),
                                        style: ButtonStyle(
                                          foregroundColor:
                                              const WidgetStatePropertyAll(
                                            Colors.white,
                                          ),
                                          backgroundColor:
                                              WidgetStateProperty.resolveWith(
                                            (states) => states.contains(
                                              WidgetState.selected,
                                            )
                                                ? MuondiaPalette.primary
                                                : const Color(0x331C1630),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      TextFormField(
                                        key: const Key(
                                          'muondia-email-auth-email',
                                        ),
                                        controller: _email,
                                        enabled: !_submitting,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        textInputAction: TextInputAction.next,
                                        autofillHints: const [
                                          AutofillHints.email,
                                        ],
                                        autocorrect: false,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        decoration: _inputDecoration(
                                          label: 'Email',
                                          icon: Icons.email_outlined,
                                        ),
                                        validator: _validateEmail,
                                      ),
                                      const SizedBox(height: 14),
                                      TextFormField(
                                        key: const Key(
                                          'muondia-email-auth-password',
                                        ),
                                        controller: _password,
                                        enabled: !_submitting,
                                        obscureText: _obscurePassword,
                                        textInputAction: creating
                                            ? TextInputAction.next
                                            : TextInputAction.done,
                                        autofillHints: [
                                          creating
                                              ? AutofillHints.newPassword
                                              : AutofillHints.password,
                                        ],
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        decoration: _inputDecoration(
                                          label: 'Contraseña',
                                          icon: Icons.lock_outline_rounded,
                                        ).copyWith(
                                          suffixIcon: IconButton(
                                            tooltip: _obscurePassword
                                                ? 'Mostrar contraseña'
                                                : 'Ocultar contraseña',
                                            onPressed: _submitting
                                                ? null
                                                : () => setState(
                                                      () => _obscurePassword =
                                                          !_obscurePassword,
                                                    ),
                                            icon: Icon(
                                              _obscurePassword
                                                  ? Icons.visibility_outlined
                                                  : Icons
                                                      .visibility_off_outlined,
                                              color:
                                                  const Color(0xFFBDB4D0),
                                            ),
                                          ),
                                        ),
                                        validator: _validatePassword,
                                        onFieldSubmitted: creating
                                            ? null
                                            : (_) => _submit(),
                                      ),
                                      if (creating) ...[
                                        const SizedBox(height: 14),
                                        TextFormField(
                                          key: const Key(
                                            'muondia-email-auth-confirm',
                                          ),
                                          controller: _confirmation,
                                          enabled: !_submitting,
                                          obscureText: _obscurePassword,
                                          textInputAction:
                                              TextInputAction.done,
                                          autofillHints: const [
                                            AutofillHints.newPassword,
                                          ],
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                          decoration: _inputDecoration(
                                            label: 'Repite la contraseña',
                                            icon: Icons.lock_reset_outlined,
                                          ),
                                          validator: (value) {
                                            if ((value ?? '').isEmpty) {
                                              return 'Repite tu contraseña.';
                                            }
                                            return null;
                                          },
                                          onFieldSubmitted: (_) => _submit(),
                                        ),
                                      ],
                                      if (_error != null) ...[
                                        const SizedBox(height: 16),
                                        Text(
                                          _error!,
                                          key: const Key(
                                            'muondia-email-auth-error',
                                          ),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Color(0xFFFF8293),
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 22),
                                      SizedBox(
                                        height: 54,
                                        child: FilledButton(
                                          key: const Key(
                                            'muondia-email-auth-submit',
                                          ),
                                          onPressed:
                                              _submitting ? null : _submit,
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                MuondiaPalette.primary,
                                            foregroundColor: Colors.white,
                                            textStyle:
                                                MuondiaTypography.label.copyWith(
                                              fontSize: 17,
                                            ),
                                          ),
                                          child: _submitting
                                              ? const SizedBox.square(
                                                  dimension: 22,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2.4,
                                                    color: Colors.white,
                                                  ),
                                                )
                                              : Text(
                                                  creating
                                                      ? 'Crear cuenta'
                                                      : 'Iniciar sesión',
                                                ),
                                        ),
                                      ),
                                      if (!creating) ...[
                                        const SizedBox(height: 8),
                                        TextButton(
                                          onPressed: _submitting
                                              ? null
                                              : _resetPassword,
                                          child: const Text(
                                            'He olvidado mi contraseña',
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFBDB4D0)),
      prefixIcon: Icon(icon, color: const Color(0xFFBDB4D0)),
      filled: true,
      fillColor: const Color(0x99130F20),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0x665B4C7A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(
          color: Color(0xFF9E72FF),
          width: 1.6,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: MuondiaPalette.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(
          color: MuondiaPalette.error,
          width: 1.6,
        ),
      ),
    );
  }
}
