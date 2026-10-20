/// Visibilidad de capas en las vistas de desarrollo de Muondia.
/// El explorador modifica exclusivamente estas cuatro constantes.
/// En una compilación release todas las imágenes permanecen visibles.
import 'package:flutter/foundation.dart';

abstract final class MuondiaVisualLayers {
  static const bool background = true;
  static const bool robot = true;
  static const bool logo = true;
  static const bool googleIcon = true;

  static bool get showBackground => !kDebugMode || background;
  static bool get showRobot => !kDebugMode || robot;
  static bool get showLogo => !kDebugMode || logo;
  static bool get showGoogleIcon => !kDebugMode || googleIcon;
}
