import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/key_constants.dart';
import 'package:spatial_audio_sandbox/src/listener/calibration_sheet.dart';

/// Records every call — widget tests assert the sheet drives the
/// session correctly without the native engine.
class FakeAudio implements TestAudioApi {
  int enters = 0, exits = 0, stops = 0, plays = 0, paramCalls = 0;
  bool engineFails = false;
  ({int session, int trial, int remainingMs}) stat =
      (session: 0, trial: 0, remainingMs: 0);
  bool? lastDirect;
  double? lastAz, lastBalance, lastLevel;

  @override
  Future<void> enter(int token) async {
    if (engineFails) throw StateError('engine not running');
    enters++;
  }

  @override
  void exit(int token) => exits++;

  @override
  Future<void> play({
    required int token,
    required int trial,
    required bool direct,
    required double az,
    required double level,
    required double balance,
  }) async {
    if (engineFails) throw StateError('engine not running');
    plays++;
    lastDirect = direct;
    lastAz = az;
    lastLevel = level;
    lastBalance = balance;
    stat = (session: token, trial: trial, remainingMs: 1150);
  }

  @override
  void stop(int token) {
    stops++;
    stat = (session: stat.session, trial: 0, remainingMs: 0);
  }

  @override
  void params({
    required int token,
    required double az,
    required double level,
    required double balance,
  }) =>
      paramCalls++;

  @override
  ({int session, int trial, int remainingMs}) status() => stat;
}

Widget _host(FakeAudio audio, {bool engineOn = true, bool startOk = true}) {
  return MaterialApp(
    home: Scaffold(
      body: CalibrationSheet(
        audio: audio,
        engineOn: engineOn,
        onStartEngine: () async => startOk,
      ),
    ),
  );
}

void main() {
  testWidgets('opens silent — no session, no sound until a tap',
      (tester) async {
    final audio = FakeAudio();
    await tester.pumpWidget(_host(audio));
    expect(audio.enters, 0);
    expect(audio.plays, 0);
    expect(find.byKey(KeyConstants.soundCheckSheet), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Test left ear plays a left-only direct chime',
      (tester) async {
    final audio = FakeAudio();
    await tester.pumpWidget(_host(audio));
    await tester.tap(find.byKey(KeyConstants.testLeftEar));
    await tester.pumpAndSettle();
    expect(audio.enters, 1);
    expect(audio.plays, 1);
    expect(audio.lastDirect, isTrue);
    expect(audio.lastBalance, -1.0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(audio.stops, 1, reason: 'close must stop the trial');
    expect(audio.exits, 1, reason: 'close must end the session');
  });

  testWidgets('Stop sound silences the trial', (tester) async {
    final audio = FakeAudio();
    await tester.pumpWidget(_host(audio));
    await tester.tap(find.byKey(KeyConstants.testLeftEar));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(KeyConstants.stopSound));
    await tester.pump();
    expect(audio.stops, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('engine-off path starts the engine first', (tester) async {
    final audio = FakeAudio();
    await tester.pumpWidget(_host(audio, engineOn: false));
    await tester.tap(find.byKey(KeyConstants.testLeftEar));
    await tester.pumpAndSettle();
    expect(audio.plays, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed engine start surfaces an error, plays nothing',
      (tester) async {
    final audio = FakeAudio()..engineFails = true;
    await tester.pumpWidget(_host(audio, engineOn: false, startOk: false));
    await tester.tap(find.byKey(KeyConstants.testLeftEar));
    await tester.pumpAndSettle();
    expect(audio.plays, 0);
    expect(find.textContaining('failed'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('quiz hides under Advanced and plays one spatial trial',
      (tester) async {
    final audio = FakeAudio();
    await tester.pumpWidget(_host(audio));
    expect(find.byKey(KeyConstants.quizPlay), findsNothing);
    await tester.tap(find.byKey(KeyConstants.advancedToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(KeyConstants.quizPlay), findsOneWidget);
    // Answer buttons are disabled before a question.
    final leftBtn = tester.widget<OutlinedButton>(
        find.byKey(KeyConstants.quizLeft));
    expect(leftBtn.onPressed, isNull);
    await tester.tap(find.byKey(KeyConstants.quizPlay));
    await tester.pumpAndSettle();
    expect(audio.plays, 1);
    expect(audio.lastDirect, isFalse, reason: 'quiz must be spatial');
    // Question is hidden — no position text leaks the side.
    await tester.tap(find.byKey(KeyConstants.quizLeft));
    await tester.pump();
    expect(find.textContaining('it was'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mode switch stops the current trial', (tester) async {
    final audio = FakeAudio();
    await tester.pumpWidget(_host(audio));
    await tester.tap(find.byKey(KeyConstants.testLeftEar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spatial position'));
    await tester.pump();
    expect(audio.stops, greaterThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
  });
}
