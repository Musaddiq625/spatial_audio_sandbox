import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:spatial_audio_sandbox/src/link/link.dart';

/// A position estimate for a remote beacon, in scene coords
/// (x = meters in front of the listener's head, y = meters left).
class BeaconSample {
  BeaconSample({
    required this.beaconId,
    required this.pos,
    required this.distanceM,
    required this.mode,
    required this.at,
  });
  final int beaconId;
  final Offset pos;
  final double distanceM;
  final String mode; // 'aimed', 'acoustic', 'cam', ...
  final DateTime at;

  Duration get age => DateTime.now().difference(at);
  bool get stale => age > const Duration(milliseconds: 1500);
}

/// Minimal quat×vector rotation: v' = q ⊗ v ⊗ conj(q). q = [w,x,y,z].
void _rotVec(List<double> q, List<double> v, List<double> out) {
  final w = q[0], x = q[1], y = q[2], z = q[3];
  // t = 2 * cross(q.xyz, v)
  final tx = 2 * (y * v[2] - z * v[1]);
  final ty = 2 * (z * v[0] - x * v[2]);
  final tz = 2 * (x * v[1] - y * v[0]);
  out[0] = v[0] + w * tx + (y * tz - z * ty);
  out[1] = v[1] + w * ty + (z * tx - x * tz);
  out[2] = v[2] + w * tz + (x * ty - y * tx);
}

/// Aimed-bearing tracker: the beacon user keeps the phone's top edge
/// (device +Y) pointed at the listener. The beacon's forward direction in
/// world space then points beacon→listener; flipping it gives the
/// listener→beacon bearing. Both phones' rotvec yaw origins differ by a
/// constant — [calibrateFront] absorbs it at aim time.
class AimedBeaconTracker {
  AimedBeaconTracker({required this.headYawRad});

  /// Current listener head yaw (radians, same convention as the radar's
  /// display yaw — already recenter-adjusted).
  final double Function() headYawRad;

  /// Manual distance estimate — aimed mode has no ranging.
  double distanceM = 1.5;

  /// Live distance from acoustic ranging (nullable — falls back to the
  /// manual [distanceM] when null). Set by the listener's acoustic ranger.
  double? acousticM;
  static const _distEma = 0.3;
  double _smoothDist = 0;
  DateTime? _lastFeed;

  /// Feed a raw acoustic range estimate; EMA-smoothed before use.
  void feedDistance(double meters) {
    _smoothDist = _smoothDist == 0
        ? meters
        : _smoothDist + _distEma * (meters - _smoothDist);
    acousticM = _smoothDist.clamp(0.3, 8.0);
    _lastFeed = DateTime.now();
  }

  /// Drop the acoustic estimate — back to manual distance (e.g. user
  /// override, or the acoustic path went silent).
  void clearAcoustic() {
    acousticM = null;
    _smoothDist = 0;
    _lastFeed = null;
  }

  /// Acoustic feed went quiet — callers should treat distance as manual.
  bool get acousticStale =>
      acousticM != null &&
      (_lastFeed == null ||
          DateTime.now().difference(_lastFeed!) >
              const Duration(seconds: 3));

  /// Yaw offset between the beacon's world frame and the listener's.
  double _frameOffset = 0;
  bool _calibrated = false;

  // Smoothed unit direction (listener→beacon) in the listener's frame.
  double _dirX = 1, _dirY = 0;
  static const _ema = 0.25;

  BeaconSample? sample;

  /// Raw world bearing of the beacon from the listener (radians, world
  /// frame: atan2(east, north) — clockwise-positive about sky+Z, matching
  /// the quat-yaw convention used for the head display).
  double _rawBearing(Float32List q) {
    // Beacon device +Y (top edge) rotated into world = beacon→listener dir.
    // Android world frame: x=east, y=north, z=sky — bearing lives in the
    // horizontal (x,y) plane.
    final out = [0.0, 0.0, 0.0];
    _rotVec([q[0], q[1], q[2], q[3]], [0, 1, 0], out);
    // listener→beacon is the opposite direction.
    return math.atan2(-out[0], -out[1]);
  }

  /// Call when the user confirms: beacon is pointed at the listener's head
  /// AND roughly in front of them. Latches the yaw frame offset.
  ///
  /// World bearings are clockwise-positive (compass convention) while scene
  /// azimuth is counter-clockwise-positive (front→left), so the raw bearing
  /// is subtracted, not added: rel = offset − raw − headYaw.
  void calibrateFront(BeaconTelemetry t) {
    _frameOffset = _rawBearing(t.quat) + headYawRad();
    _calibrated = true;
  }

  void onTelemetry(BeaconTelemetry t) {
    if (acousticStale) clearAcoustic(); // auto-fallback to manual distance
    if (!_calibrated) calibrateFront(t); // first packet calibrates implicitly
    final rel = _frameOffset - _rawBearing(t.quat) - headYawRad();
    // EMA on the unit vector (wrap-safe), then back to an angle.
    final dx = math.cos(rel), dy = math.sin(rel);
    _dirX += _ema * (dx - _dirX);
    _dirY += _ema * (dy - _dirY);
    final az = math.atan2(_dirY, _dirX);
    final dist = acousticM ?? distanceM;
    sample = BeaconSample(
      beaconId: t.beaconId,
      pos: Offset(dist * math.cos(az), dist * math.sin(az)),
      distanceM: dist,
      mode: acousticM == null ? 'aimed' : 'acoustic',
      at: DateTime.now(),
    );
  }
}
