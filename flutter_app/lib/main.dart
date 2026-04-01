import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'platform/xterm_backend.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: TetherApp()));
}

class TetherApp extends StatelessWidget {
  const TetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    final backend = XtermBackend();

    return MaterialApp(
      title: 'Tether',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF2D2D2D),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: HomeScreen(backend: backend),
    );
  }
}
