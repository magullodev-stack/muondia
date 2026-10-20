import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app_theme.dart';
import 'app/auth/auth_entry_page.dart';
import 'app/auth/auth_service.dart';
import 'app/auth/email_auth_page.dart';

void main() => runApp(const MuondiaApp());

class MuondiaApp extends StatefulWidget {
  const MuondiaApp({
    super.key,
    this.auth = const UnconfiguredAuthService(),
  });

  final AuthService auth;

  @override
  State<MuondiaApp> createState() => _MuondiaAppState();
}

class _MuondiaAppState extends State<MuondiaApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  static const _visual = MethodChannel('muondia/visual');

  late final _routeObserver = _MuondiaRouteObserver(_reportRoute);
  bool _safePreview = kDebugMode;
  String? _reportedLocation;

  AuthService get _activeAuth => _safePreview
      ? const UnconfiguredAuthService()
      : widget.auth;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _visual.setMethodCallHandler(_onVisualRequest);
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportRoute());
    }
  }

  /// Solo nombres de pantallas: nunca se transmite identidad ni credenciales.
  void _reportRoute() {
    if (!kDebugMode || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final name = _routeObserver.current?.settings.name;
      final state = name == '/auth/email' ? 'email' : 'inicio';
      final location = '${_safePreview ? 'preview' : 'real'}:auth:$state';
      if (location == _reportedLocation) return;
      _reportedLocation = location;
      _visual.invokeMethod<void>('setActiveLocation', {
        'mode': _safePreview ? 'preview' : 'real',
        'experience': 'auth',
        'state': state,
      }).catchError((Object _) {
        // La inspección visual no puede bloquear la navegación de Muondia.
      });
    });
  }

  Future<void> _onVisualRequest(MethodCall call) async {
    if (!kDebugMode || !mounted) return;
    if (call.method == 'openRealFlow') {
      // Sin proveedor configurado no existe todavía un recorrido real.
      if (widget.auth is UnconfiguredAuthService) return;
      setState(() => _safePreview = false);
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
      _reportRoute();
      return;
    }
    if (call.method != 'openState') return;
    final args = call.arguments;
    if (args is! Map || args['experience'] != 'auth') return;
    final state = args['state'];
    if (state != 'inicio' && state != 'email') return;

    setState(() => _safePreview = true);
    final nav = _navigatorKey.currentState;
    nav?.popUntil((route) => route.isFirst);
    if (state == 'email') {
      nav?.push<void>(MaterialPageRoute(
        settings: const RouteSettings(name: '/auth/email'),
        builder: (_) => EmailAuthPage(auth: _activeAuth),
      ));
    } else {
      _reportRoute();
    }
  }

  @override
  void dispose() {
    if (kDebugMode) _visual.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    navigatorObservers: [_routeObserver],
    title: 'Muondia',
    debugShowCheckedModeBanner: false,
    theme: muondiaTheme,
    home: AuthEntryPage(auth: _activeAuth),
  );
}

/// Observa las pantallas, ignorando diálogos y otros overlays pasajeros.
class _MuondiaRouteObserver extends NavigatorObserver {
  _MuondiaRouteObserver(this.notify);
  final VoidCallback notify;
  final List<Route<dynamic>> _pages = [];

  Route<dynamic>? get current => _pages.isEmpty ? null : _pages.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _pages.add(route);
    notify();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
    notify();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
    notify();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final position = _pages.indexOf(oldRoute);
      if (position != -1) {
        if (newRoute != null) {
          _pages[position] = newRoute;
        } else {
          _pages.removeAt(position);
        }
      }
    }
    notify();
  }
}
