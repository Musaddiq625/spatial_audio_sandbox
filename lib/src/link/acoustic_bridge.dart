import 'package:flutter/services.dart';

/// Wraps the Kotlin acoustic bridge (chirp emit/detect with audio-clock
/// timestamps). Events arrive as [type, nanos]:
///   1 = local chirp emitted at nanos (monotonic audio clock)
///   2 = remote chirp detected at nanos
///   3 = responder delay (t3−t2), beacon role only
class AcousticChannel {
  static const _events =
      EventChannel('dev.sas.spatial_audio_sandbox/acoustic');
  static const _ctl =
      MethodChannel('dev.sas.spatial_audio_sandbox/acoustic_ctl');

  /// role: 'listener' (ping originator) or 'beacon' (auto-replier).
  /// Triggers the RECORD_AUDIO runtime prompt on first call.
  Future<void> start(String role) =>
      _ctl.invokeMethod('start', {'role': role});

  /// Emit a chirp now (listener role).
  Future<void> ping() => _ctl.invokeMethod('ping');

  Future<void> stop() => _ctl.invokeMethod('stop');

  /// Raw events: [type:int, nanos:int] as Long → Dart int (exact).
  Stream<List<int>> get events => _events.receiveBroadcastStream().map((e) {
        final l = e as List<dynamic>;
        return [(l[0] as num).toInt(), (l[1] as num).toInt()];
      });
}
