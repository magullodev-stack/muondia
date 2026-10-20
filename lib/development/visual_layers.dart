/// Estado visual temporal de las capas en una sesión de desarrollo.
/// Los ojos no editan Dart ni alteran Git.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract final class MuondiaVisualLayers {
  static const names = <String>{'background', 'robot', 'logo', 'googleIcon'};
  static final hidden = ValueNotifier<Set<String>>(<String>{});

  static void setVisible(String name, bool visible) {
    if (!kDebugMode || !names.contains(name)) return;
    final next = <String>{...hidden.value};
    if (visible) {
      next.remove(name);
    } else {
      next.add(name);
    }
    if (!setEquals(hidden.value, next)) hidden.value = next;
  }
}

/// Oculta visualmente, manteniendo tamaño, posición y el widget original.
class MuondiaVisualLayer extends StatelessWidget {
  const MuondiaVisualLayer({
    super.key,
    required this.name,
    required this.child,
  });

  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return child;
    return ValueListenableBuilder<Set<String>>(
      valueListenable: MuondiaVisualLayers.hidden,
      child: child,
      builder: (context, hidden, child) => Opacity(
        opacity: hidden.contains(name) ? 0 : 1,
        child: child,
      ),
    );
  }
}
