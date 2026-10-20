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
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  static const _visual = MethodChannel('muondia/visual');

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _visual.setMethodCallHandler(_onVisualState);
    }
  }

  Future<void> _onVisualState(MethodCall call) async {
    if (!kDebugMode || !mounted || call.method != 'openState') return;
    final arguments = call.arguments;
    if (arguments is! Map || arguments['experience'] != 'auth') return;
    final state = arguments['state'];
    if (state != 'inicio' && state != 'email') return;

    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    navigator.popUntil((route) => route.isFirst);
    if (state == 'email') {
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => EmailAuthPage(auth: widget.auth),
        ),
      );
    }
  }

  @override
  void dispose() {
    if (kDebugMode) {
      _visual.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Muondia',
      debugShowCheckedModeBanner: false,
      theme: muondiaTheme,
      home: AuthEntryPage(auth: widget.auth),
    );
  }
}
