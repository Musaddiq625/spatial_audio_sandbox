import 'package:flutter/material.dart';
import 'package:spatial_audio_sandbox/src/rust/frb_generated.dart';
import 'package:spatial_audio_sandbox/src/listener/sandbox_page.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const SandboxApp());
}

class SandboxApp extends StatelessWidget {
  const SandboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spatial Audio Sandbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
      ),
      home: const SandboxPage(),
    );
  }
}
