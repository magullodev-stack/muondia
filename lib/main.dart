import 'package:flutter/material.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'test image/quiz_background.png',
                fit: BoxFit.cover,
              ),
            ),
            Center(child: Text('Muondia: prueba automatica')),
          ],
        ),
      ),
    );
  }
}
