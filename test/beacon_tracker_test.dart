import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/listener/beacon_tracker.dart';
import 'package:spatial_audio_sandbox/src/link/link.dart';

/// Build a yaw quat [w,x,y,z] that rotates the device +Y axis (top edge)
/// onto the given world direction [v] (unit, horizontal plane).
Float32List aimQuat(double vx, double vy) {
  // Rotation about z by ψ maps +Y → (−sinψ, cosψ). Solve for ψ.
  final psi = math.atan2(-vx, vy);
  final h = psi / 2;
  return Float32List.fromList([math.cos(h), 0, 0, math.sin(h)]);
}

BeaconTelemetry tele(int id, Float32List quat) => BeaconTelemetry(
      beaconId: id,
      seq: 0,
      sentMs: 0,
      flags: 0,
      quat: quat,
      gyro: Float32List(3),
      from: InternetAddress.loopbackIPv4,
    );

void main() {
  test('aimed beacon: bearing tracks where the beacon is, relative to head',
      () {
    var headYaw = 0.0;
    final tr = AimedBeaconTracker(headYawRad: () => headYaw);

    // Beacon sits due north of listener (bearing 0), aiming back south.
    // beacon→listener dir = (0,-1) → aim +Y onto it.
    tr.onTelemetry(tele(1, aimQuat(0, -1)));
    final s0 = tr.sample!;
    // Calibrated front → azimuth ~0 → dot at (d, 0) = straight ahead.
    expect(s0.pos.dx, closeTo(tr.distanceM, 0.05));
    expect(s0.pos.dy.abs(), lessThan(0.3));

    // Beacon walks to the listener's left (west): l→b dir = (-1, 0) →
    // beacon→listener = (1,0).
    for (var i = 0; i < 40; i++) {
      tr.onTelemetry(tele(1, aimQuat(1, 0)));
    }
    final s1 = tr.sample!;
    // +y = left on the radar.
    expect(s1.pos.dy, greaterThan(tr.distanceM * 0.8),
        reason: 'beacon at west should land on +y (left)');

    // Listener turns head left (+π/2): a fixed beacon should rotate the
    // opposite way on the radar — back toward front.
    headYaw = math.pi / 2;
    for (var i = 0; i < 40; i++) {
      tr.onTelemetry(tele(1, aimQuat(1, 0)));
    }
    final s2 = tr.sample!;
    expect(s2.pos.dx, greaterThan(tr.distanceM * 0.8),
        reason: 'head left + beacon west => beacon in front');
  });
}
