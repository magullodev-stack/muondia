import 'dart:math' as math;

import 'auth_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../../development/visual_layers.dart';
import 'auth_provider_button.dart';
import 'email_auth_page.dart';

class AuthEntryPage extends StatefulWidget {
  const AuthEntryPage({super.key, required this.auth});

  final AuthService auth;

  @override
  State<AuthEntryPage> createState() => _AuthEntryPageState();
}

class _AuthEntryPageState extends State<AuthEntryPage> {
  late final TapGestureRecognizer _termsRecognizer;
  late final TapGestureRecognizer _privacyRecognizer;
  bool _providerBusy = false;

  @override
  void initState() {
    super.initState();
    _termsRecognizer = TapGestureRecognizer()
      ..onTap = () =>
          _showUnavailable('Los términos de uso todavía no están disponibles.');
    _privacyRecognizer = TapGestureRecognizer()
      ..onTap = () => _showUnavailable(
        'El contenido de privacidad todavía no está disponible.',
      );
  }

  @override
  void dispose() {
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

  Future<void> _showUnavailable(String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );

  Future<void> _openEmail() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => EmailAuthPage(auth: widget.auth)),
    );
  }

  Future<void> _signInWithProvider(AuthProvider provider) async {
    if (_providerBusy) return;
    setState(() => _providerBusy = true);
    try {
      switch (provider) {
        case AuthProvider.google:
          await widget.auth.signInWithGoogle();
        case AuthProvider.apple:
          await widget.auth.signInWithApple();
        case AuthProvider.email:
          return;
      }
    } on AuthFailure catch (failure) {
      if (!mounted || failure.code == AuthFailureCode.cancelled) return;
      if (failure.code == AuthFailureCode.notConfigured ||
          failure.code == AuthFailureCode.providerNotReady) {
        final name = provider == AuthProvider.google ? 'Google' : 'Apple';
        _showMessage('El acceso con $name aún no está configurado en Muondia.');
      } else if (failure.code == AuthFailureCode.network) {
        _showMessage('No hay conexión. Comprueba tu red e inténtalo de nuevo.');
      } else {
        _showMessage('No se ha podido completar el acceso.');
      }
    } catch (_) {
      if (mounted) _showMessage('No se ha podido completar el acceso.');
    } finally {
      if (mounted) setState(() => _providerBusy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    const legalShadow = [
      Shadow(color: Color(0xE6000000), offset: Offset(0, 1), blurRadius: 3),
    ];
    const legalBase = TextStyle(
      color: Color(0xFFF5F2FF),
      fontSize: 14,
      height: 1.35,
      fontWeight: FontWeight.w700,
      shadows: legalShadow,
    );
    const legalLink = TextStyle(
      color: Colors.white,
      decoration: TextDecoration.underline,
      decorationColor: Colors.white,
      fontSize: 14,
      height: 1.35,
      fontWeight: FontWeight.w800,
      shadows: legalShadow,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.black,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        key: const Key('muondia-auth-entry'),
        backgroundColor: Colors.black,
        body: SafeArea(
          top: true,
          bottom: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Recortar tambien las transformaciones ampliadas, no solo el Stack.
              ClipRect(
                child: const _AuthParallaxArt(),
              ),
              // Un único mensaje, con una sola tipografía y estilo.
              // La posición aprovecha la franja azul sin tocar el robot.
              LayoutBuilder(
                builder: (context, constraints) {
                  final welcomeSize = math.min(
                    30.0,
                    math.max(27.0, constraints.maxWidth * 0.083),
                  );
                  final welcomeStyle = TextStyle(
                    fontFamily: MuondiaTypography.family,
                    fontSize: welcomeSize,
                    fontWeight: FontWeight.w900,
                    height: 0.96,
                    color: Colors.white,
                    shadows: const [
                      Shadow(
                        color: Color(0xDA061234),
                        offset: Offset(0, 2),
                        blurRadius: 5,
                      ),
                    ],
                  );

                  final logoWidth = math.min(
                    constraints.maxWidth * 0.64,
                    250.0,
                  );
                  final logoHeight = math.min(
                    logoWidth / 3,
                    constraints.maxHeight * 0.10,
                  );

                  return Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 410),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Opacity(
                              opacity: MuondiaVisualLayers.showLogo ? 1 : 0,
                              child: Image.asset(
                                'assets/auth/Logotipo_MuondIA.png',
                                key: const Key('muondia-auth-logo'),
                                width: logoWidth,
                                height: logoHeight,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '¡Qué alegría\nverte por aquí!',
                              key: const Key('muondia-auth-welcome-title'),
                              textAlign: TextAlign.center,
                              style: welcomeStyle,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '¿Empezamos?',
                              key: const Key('muondia-auth-welcome-question'),
                              textAlign: TextAlign.center,
                              style: welcomeStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final buttonWidth = math.min(
                    constraints.maxWidth * 0.86,
                    420.0,
                  );
                  final buttonHeight = buttonWidth / 5.82;

                  Widget providerButton({
                    required Key key,
                    required AuthProvider provider,
                    required VoidCallback onPressed,
                  }) {
                    return SizedBox(
                      key: key,
                      width: buttonWidth,
                      height: buttonHeight,
                      child: AuthProviderButton(
                        provider: provider,
                        onPressed: onPressed,
                      ),
                    );
                  }

                  // Botones y condiciones comparten el mismo bloque inferior.
                  // El espacio entre ambos no depende de la altura del móvil.
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          providerButton(
                            key: const Key('muondia-auth-button-google'),
                            provider: AuthProvider.google,
                            onPressed: () =>
                                _signInWithProvider(AuthProvider.google),
                          ),
                          const SizedBox(height: 8),
                          providerButton(
                            key: const Key('muondia-auth-button-apple'),
                            provider: AuthProvider.apple,
                            onPressed: () =>
                                _signInWithProvider(AuthProvider.apple),
                          ),
                          const SizedBox(height: 8),
                          providerButton(
                            key: const Key('muondia-auth-button-email'),
                            provider: AuthProvider.email,
                            onPressed: _openEmail,
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text.rich(
                                TextSpan(
                                  style: legalBase.copyWith(
                                    fontFamily: MuondiaTypography.family,
                                  ),
                                  children: [
                                    const TextSpan(
                                      text: 'Al continuar, aceptas los ',
                                    ),
                                    TextSpan(
                                      text: 'Términos de uso',
                                      style: legalLink.copyWith(
                                        fontFamily: MuondiaTypography.family,
                                      ),
                                      recognizer: _termsRecognizer,
                                    ),
                                    const TextSpan(text: '\ny la '),
                                    TextSpan(
                                      text: 'Política de privacidad',
                                      style: legalLink.copyWith(
                                        fontFamily: MuondiaTypography.family,
                                      ),
                                      recognizer: _privacyRecognizer,
                                    ),
                                    const TextSpan(text: '.'),
                                  ],
                                ),
                                key: const Key('muondia-auth-legal'),
                                maxLines: 2,
                                softWrap: false,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La composición conserva fondo y robot sobre el lienzo original.
/// El fondo permanece fijo mientras el robot mantiene un movimiento suave.
class _AuthParallaxArt extends StatefulWidget {
  const _AuthParallaxArt();

  @override
  State<_AuthParallaxArt> createState() => _AuthParallaxArtState();
}

class _AuthParallaxArtState extends State<_AuthParallaxArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  )..repeat();

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  Widget _movingLayer({
    required String name,
    required String asset,
    required double x,
    required double y,
    double scale = 1,
    bool visible = true,
  }) {
    return Opacity(
      opacity: visible ? 1 : 0,
      child: Transform.translate(
        key: Key('muondia-auth-parallax-$name'),
        offset: Offset(x, y),
        child: Transform.scale(
          scale: scale,
          child: Image.asset(
            asset,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _motion,
        builder: (context, _) {
          final angle = _motion.value * 2 * math.pi;
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              // El PNG original tiene márgenes oscuros integrados.
              // Ampliar solo el fondo elimina las franjas sin alterar
              // las coordenadas de robot y botones.
              Transform.scale(
                key: const Key('muondia-auth-background-fill'),
                scale: 1.30,
                child: Opacity(
                  opacity: MuondiaVisualLayers.showBackground ? 1 : 0,
                  child: Image.asset(
                    'assets/auth/Background.png',
                    key: const Key('muondia-auth-background'),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
              _movingLayer(
                name: 'robot',
                asset: 'assets/auth/Robot.png',
                visible: MuondiaVisualLayers.showRobot,
                x: 0,
                y: -12 + math.cos(angle + 1.4) * 4,
                scale: 1.005 + math.sin(angle + 1.4) * 0.004,
              ),
            ],
          );
        },
      ),
    );
  }
}
