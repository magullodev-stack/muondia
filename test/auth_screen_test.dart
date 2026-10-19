import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muondia/main.dart';
import 'package:muondia/app/auth/auth_entry_page.dart';
import 'package:muondia/app/auth/email_auth_page.dart';

void main() {
  testWidgets('Auth muestra el arte de Muondia y los tres proveedores',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const MuondiaApp());
    await tester.pump();

    expect(find.byType(AuthEntryPage), findsOneWidget);
    expect(find.byKey(const Key('muondia-auth-logo')), findsOneWidget);
    expect(find.text('¡Qué alegría\nverte por aquí!'), findsOneWidget);
    expect(find.text('¿Empezamos?'), findsOneWidget);
    for (final provider in ['google', 'apple', 'email']) {
      expect(find.byKey(Key('muondia-auth-button-$provider')), findsOneWidget);
    }
    expect(find.byKey(const Key('muondia-auth-background')), findsOneWidget);
    expect(find.byKey(const Key('muondia-auth-parallax-robot')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('El botón de email abre el formulario propio de Muondia',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const MuondiaApp());
    await tester.pump();
    await tester.tap(find.byKey(const Key('muondia-auth-button-email')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(EmailAuthPage), findsOneWidget);
    expect(find.text('Iniciar sesión'), findsWidgets);
    expect(find.text('Crear cuenta'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
