import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

/// Bridges the Android pose EventChannel ([w,x,y,z,gx,gy,gz] float32) into
/// the engine's `setHeadPose`. On platforms without the channel (desktop),
/// [useVirtualHead] drives the same call from a yaw slider.
class PoseBridge {
  static const _channel = EventChannel('dev.sas.spatial_audio_sandbox/pose');

  StreamSubscription<dynamic>? _sub;

  /// Last quaternion seen, for the UI's heading display.
  final ValueNotifier<List<double>?> lastQuat = ValueNotifier(null);

  bool get isLive => _sub != null;

  void start() {
    // The pose EventChannel only exists on Android — skip elsewhere so
    // desktop runs use the virtual-head slider instead of throwing.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _sub ??= _channel.receiveBroadcastStream().listen(
      (data) {
        if (data is Float32List && data.length >= 7) {
          setHeadPose(
            w: data[0],
            x: data[1],
            y: data[2],
            z: data[3],
            gx: data[4],
            gy: data[5],
            gz: data[6],
          );
          lastQuat.value = [data[0], data[1], data[2], data[3]];
        }
      },
      onError: (e) => debugPrint('pose channel error: $e'),
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// Desktop/manual fallback: feed a yaw-only pose (radians, + = turn left).
  void useVirtualHead(double yawRad) {
    final h = yawRad / 2;
    final c = math.cos(h);
    final s = math.sin(h);
    setHeadPose(w: c, x: 0, y: 0, z: s, gx: 0, gy: 0, gz: 0);
    lastQuat.value = [c, 0, 0, s];
  }
}
