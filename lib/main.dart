import 'package:flutter/material.dart';

import 'app/app_theme.dart';
import 'app/auth/auth_entry_page.dart';
import 'app/auth/auth_service.dart';

void main() => runApp(const MuondiaApp());

class MuondiaApp extends StatelessWidget {
  const MuondiaApp({
    super.key,
    this.auth = const UnconfiguredAuthService(),
  });

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Muondia',
      debugShowCheckedModeBanner: false,
      theme: muondiaTheme,
      home: AuthEntryPage(auth: auth),
    );
  }
}
