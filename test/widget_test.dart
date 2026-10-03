import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spatial_audio_sandbox/main.dart';
import 'package:spatial_audio_sandbox/src/listener/sandbox_page.dart';

void main() {
  testWidgets('listener sandbox boots directly', (WidgetTester tester) async {
    await tester.pumpWidget(const SandboxApp());
    expect(find.byType(SandboxPage), findsOneWidget);
    expect(find.text('Spatial Audio Sandbox'), findsOneWidget);
    // Unmount so the page's dispose() cancels its timers before teardown.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
