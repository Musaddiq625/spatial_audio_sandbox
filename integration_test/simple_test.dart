import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/main.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';
import 'package:spatial_audio_sandbox/src/rust/api/simple.dart';
import 'package:spatial_audio_sandbox/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  test('Dart<->Rust round trip', () {
    expect(greet(name: 'SAS'), 'Hello, SAS!');
  });

  test('engine starts and accepts sources', () async {
    final info = await engineStart();
    expect(info.sampleRate, greaterThan(0));
    expect(info.channels, 2);
    final id = await addSource(
      kind: SourceKindWire.tone,
      x: 0.5,
      y: 1.0,
      z: 0,
      gain: 0.3,
    );
    expect(id, greaterThan(0));
    setSourcePosition(id: id, x: 1.0, y: 0.5, z: 0);
    setHeadPose(w: 1, x: 0, y: 0, z: 0, gx: 0, gy: 0, gz: 0);
    await removeSource(id: id);
    await engineStop();
  });

  testWidgets('App boots to sandbox', (WidgetTester tester) async {
    await tester.pumpWidget(const SandboxApp());
    expect(find.text('spatial audio sandbox'), findsOneWidget);
  });
}
