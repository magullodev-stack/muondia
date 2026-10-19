import 'package:flutter/material.dart';

import '../app_theme.dart';

enum AuthProvider { google, apple, email }

class AuthProviderButton extends StatelessWidget {
  const AuthProviderButton({
    super.key,
    required this.provider,
    required this.onPressed,
  });

  final AuthProvider provider;
  final VoidCallback onPressed;

  String get _label => switch (provider) {
    AuthProvider.google => 'Continuar con Google',
    AuthProvider.apple => 'Continuar con Apple',
    AuthProvider.email => 'Continuar con email',
  };

  Widget _icon(double size) => switch (provider) {
    AuthProvider.google => Image.asset(
      'assets/auth/Muondia_Auth_Google_ICON.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    ),
    AuthProvider.apple => Icon(
      Icons.apple,
      size: size,
      color: Colors.white,
    ),
    AuthProvider.email => Icon(
      Icons.mail_outline_rounded,
      size: size,
      color: Colors.white,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.expand(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              // Normalizar el tamaño óptico: el PNG de Google ocupa más
              // superficie visible que los glifos de Apple y correo.
              final iconScale = switch (provider) {
                AuthProvider.google => 0.46,
                AuthProvider.apple => 0.62,
                AuthProvider.email => 0.53,
              };
              final iconSize = height * iconScale;

              return CustomPaint(
                painter: const _NeonButtonPainter(),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: height * 0.46),
                  child: Row(
                    children: [
                      SizedBox(
                        width: height * 0.94,
                        child: Center(child: _icon(iconSize)),
                      ),
                      SizedBox(width: height * 0.16),
                      Expanded(
                        child: Text(
                          _label,
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                          textAlign: TextAlign.left,
                          style: TextStyle(
                            fontFamily: MuondiaTypography.family,
                            color: Colors.white,
                            fontSize: height * 0.34,
                            height: 1,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.25,
                            shadows: const [
                              Shadow(
                                color: Color(0x805F46FF),
                                blurRadius: 7,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NeonButtonPainter extends CustomPainter {
  const _NeonButtonPainter();

  static const _borderGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0xFF00B7FF),
      Color(0xFF5A65FF),
      Color(0xFFFF20FB),
    ],
    stops: [0, 0.46, 1],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.height / 2);
    final outer = RRect.fromRectAndRadius(rect.deflate(2.5), radius);

    final fill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF19182B),
          Color(0xFF0A0912),
        ],
      ).createShader(rect);
    canvas.drawRRect(outer, fill);

    final glowWide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..shader = _borderGradient.createShader(rect)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9);
    canvas.drawRRect(outer, glowWide);

    final glowTight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..shader = _borderGradient.createShader(rect)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
    canvas.drawRRect(outer, glowTight);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = _borderGradient.createShader(rect);
    canvas.drawRRect(outer, border);

    final innerRect = rect.deflate(size.height * 0.075);
    final inner = RRect.fromRectAndRadius(
      innerRect,
      Radius.circular(innerRect.height / 2),
    );
    final innerHighlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0x66FFFFFF);
    canvas.drawRRect(inner, innerHighlight);
  }

  @override
  bool shouldRepaint(covariant _NeonButtonPainter oldDelegate) => false;
}
