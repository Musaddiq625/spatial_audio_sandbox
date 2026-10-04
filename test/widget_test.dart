import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spatial_audio_sandbox/main.dart';
import 'package:spatial_audio_sandbox/src/bootstrap/intro_splash.dart';
import 'package:spatial_audio_sandbox/src/listener/sandbox_page.dart';

void main() {
  testWidgets('intro splash shows branding then reaches the sandbox',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SandboxApp());

    // First frame: the branded intro, not the sandbox yet.
    expect(find.byType(IntroSplashPage), findsOneWidget);
    expect(find.byType(SandboxPage), findsNothing);
    expect(find.text('Spatial Audio Sandbox'), findsOneWidget);
    expect(find.text('Hacktoberfest Weekend Challenge'), findsOneWidget);
    expect(find.text('Gemma · Render'), findsOneWidget);

    // The intro auto-advances — the sandbox lands after the hold.
    await tester.pump(const Duration(milliseconds: 2700));
    await tester.pumpAndSettle();
    expect(find.byType(SandboxPage), findsOneWidget);
    // The credit is pinned to the viewport bottom — outside the
    // scrollable controls, so it renders even on a short page.
    expect(find.text('Built with ❤️ by Musaddiq625'), findsOneWidget);

    // Unmount so the page's dispose() cancels its timers before teardown.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tap skips the intro immediately', (WidgetTester tester) async {
    await tester.pumpWidget(const SandboxApp());
    expect(find.byType(IntroSplashPage), findsOneWidget);

    await tester.tap(find.byType(IntroSplashPage));
    await tester.pumpAndSettle();
    expect(find.byType(SandboxPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
