import 'package:flutter/material.dart';
import 'package:spatial_audio_sandbox/src/rust/frb_generated.dart';
import 'package:spatial_audio_sandbox/src/listener/sandbox_page.dart';
import 'package:spatial_audio_sandbox/src/beacon/beacon_page.dart';

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
      home: const RolePicker(),
    );
  }
}

/// Launch-time role picker: this device is either the listener (head +
/// earphones, current sandbox) or a beacon (movable sound source).
class RolePicker extends StatelessWidget {
  const RolePicker({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('spatial audio sandbox', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.headphones),
              label: const Text('listener'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SandboxPage())),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.sensors),
              label: const Text('beacon'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const BeaconPage())),
            ),
          ],
        ),
      ),
    );
  }
}
