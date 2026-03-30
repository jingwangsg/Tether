// Demo 4 — Flutter PlatformView with a plain red NSView.
// Validates FlutterPlatformViewFactory / AppKitView infrastructure.
//
// Success criteria:
//   - Red NSView fills the Flutter window
//   - Resizing the window correctly resizes the red view
//
// Run: flutter run -d macos (from demos/demo4_flutter_view/)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const Demo4App());
}

class Demo4App extends StatelessWidget {
  const Demo4App({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Demo 4 — PlatformView',
      debugShowCheckedModeBanner: false,
      home: _Demo4Home(),
    );
  }
}

class _Demo4Home extends StatelessWidget {
  const _Demo4Home();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppKitView(
        viewType: 'demo/colored_view',
        creationParams: <String, dynamic>{},
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
