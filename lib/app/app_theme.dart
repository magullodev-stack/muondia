import 'package:flutter/material.dart';

/// Design System v1: identidad visual particular de Muondia.

abstract final class MuondiaPalette {
  static const background = Color(0xFF38149B);
  static const backgroundLight = Color(0xFF7838F2);
  static const backgroundDark = Color(0xFF29116F);

  static const primary = Color(0xFF6931DD);
  static const primaryLight = Color(0xFFAB73FF);

  static const foreground = Colors.white;
  static const foregroundMuted = Color(0xFFD8CBFF);

  static const ink = Color(0xFF21163B);
  static const surface = Color(0xFFF7F5FB);
  static const surfaceElevated = Color(0xFFFFFFFF);
  static const inkMuted = Color(0xFF625B74);
  static const divider = Color(0xFFDED8EA);

  // Reservados para estado, no para identificar modalidades.
  static const success = Color(0xFF16C77A);
  static const error = Color(0xFFFF4D67);
  static const warning = Color(0xFFFFC83D);
  static const accent = warning;
  static const info = Color(0xFF4DB9ED);

  // Identidad visual de la navegación inferior de Muondia.
  static const navSurfaceStart = Color(0xFF7049CF);
  static const navSurfaceEnd = Color(0xFF4B2C9C);
  static const navBorder = Color(0xFF9974E9);

  static const navActiveText = Color(0xFF5126BB);
  static const navInactiveText = Color(0xFFE9DEFF);

  static const navBackgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [navSurfaceStart, navSurfaceEnd],
  );

  static const navActiveGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xDDFBEFFF), Color(0xC4E9CEFF)],
  );

  static const salaStart = Color(0xFFFFEBA0);
  static const salaEnd = Color(0xFFFFBA4C);

  static const versusStart = Color(0xFF91F1FC);
  static const versusEnd = Color(0xFF22C5E9);

  static const estudioStart = Color(0xFFB9F89D);
  static const estudioEnd = Color(0xFF57DE74);

  static const backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [backgroundLight, background, backgroundDark],
  );

  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF9A62FF), Color(0xFF6935E9), Color(0xFF8845F5)],
  );
}

/// Jerarquía tipográfica propia de Muondia.
///
/// La familia se registra localmente en pubspec.yaml.
/// Los estilos se comparten entre la aplicación y sus modalidades.
abstract final class MuondiaTypography {
  static const family = 'Nunito';

  static const brand = TextStyle(
    fontFamily: family,
    color: MuondiaPalette.foreground,
    fontSize: 47,
    fontWeight: FontWeight.w900,
    letterSpacing: -2.2,
    height: 0.95,
  );
  static const screenTitle = TextStyle(
    fontFamily: family,
    fontSize: 28,
    fontWeight: FontWeight.w900,
  );
  static const sectionTitle = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w800,
  );
  static const cardTitle = TextStyle(
    fontFamily: family,
    fontSize: 31,
    fontWeight: FontWeight.w900,
    letterSpacing: -0.7,
    height: 0.98,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
  static const bodySecondary = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: MuondiaPalette.inkMuted,
  );
  static const label = TextStyle(
    fontFamily: family,
    fontSize: 16,
    fontWeight: FontWeight.w800,
  );
  static const caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: MuondiaPalette.inkMuted,
  );
}

abstract final class MuondiaSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class MuondiaRadii {
  static const small = 12.0;
  static const medium = 18.0;
  static const card = 24.0;
  static const hero = 28.0;
  static const pill = 1000.0;
}

abstract final class MuondiaShadows {
  static const card = <BoxShadow>[
    BoxShadow(color: Color(0x1C000000), blurRadius: 10, offset: Offset(0, 4)),
  ];
  static const elevated = <BoxShadow>[
    BoxShadow(color: Color(0x28000000), blurRadius: 14, offset: Offset(0, 6)),
  ];
}

abstract final class MuondiaDurations {
  static const fast = Duration(milliseconds: 180);
  static const normal = Duration(milliseconds: 240);
  static const curve = Curves.easeOutCubic;
}

abstract final class MuondiaLayout {
  static const maxWidth = 640.0;
  static const horizontalPadding = 12.0;
}

// Las pantallas Material aún no migradas conservan un escenario claro.
// AppShell aplica explícitamente el escenario oscuro de Muondia.
final ThemeData muondiaTheme = ThemeData(
  useMaterial3: true,
  fontFamily: MuondiaTypography.family,
  colorScheme: ColorScheme.fromSeed(seedColor: MuondiaPalette.primary).copyWith(
    primary: MuondiaPalette.primary,
    onPrimary: MuondiaPalette.foreground,
    surface: MuondiaPalette.surface,
    onSurface: MuondiaPalette.ink,
    onSurfaceVariant: MuondiaPalette.inkMuted,
    outlineVariant: MuondiaPalette.divider,
    // Material usa un rojo más oscuro para texto de error sobre superficie
    // clara; el coral canónico sigue disponible en MuondiaPalette para estado.
  ),
  scaffoldBackgroundColor: MuondiaPalette.surface,
  dividerColor: MuondiaPalette.divider,
  textTheme: const TextTheme(
    headlineSmall: MuondiaTypography.screenTitle,
    titleLarge: MuondiaTypography.sectionTitle,
    bodyLarge: MuondiaTypography.body,
    bodyMedium: MuondiaTypography.bodySecondary,
    labelLarge: MuondiaTypography.label,
    bodySmall: MuondiaTypography.caption,
  ),
);
