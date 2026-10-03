import 'package:flutter_test/flutter_test.dart';

import 'package:spatial_audio_sandbox/main.dart';

void main() {
  testWidgets('role picker smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SandboxApp());
    expect(find.text('spatial audio sandbox'), findsOneWidget);
    expect(find.text('listener'), findsOneWidget);
    expect(find.text('beacon'), findsOneWidget);
  });
}
