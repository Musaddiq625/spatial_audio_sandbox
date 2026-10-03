import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/link/link.dart';

void main() {
  // One listener per file — mirrors production (one link, many senders)
  // and sidesteps the async port release between tests.
  late SasLink link;

  setUpAll(() async {
    link = SasLink();
    await link.start();
  });
  tearDownAll(() => link.dispose());

  Future<RawDatagramSocket> sender() =>
      RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

  test('telemetry packet round-trips through a real socket pair', () async {
    final quat = Float32List.fromList([1.0, 0.1, -0.2, 0.3]);
    final gyro = Float32List.fromList([0.5, -1.5, 2.5]);

    final got = link.telemetry.first;
    final tx = await sender();
    tx.send(
      encodeTelemetry(
          beaconId: 42,
          seq: 7,
          sentMs: 123456,
          flags: 3,
          quat: quat,
          gyro: gyro),
      InternetAddress.loopbackIPv4,
      kLinkPort,
    );

    final t = await got.timeout(const Duration(seconds: 2));
    expect(t.beaconId, 42);
    expect(t.seq, 7);
    expect(t.sentMs, 123456);
    expect(t.flags, 3);
    for (var i = 0; i < 4; i++) {
      expect(t.quat[i], closeTo(quat[i], 1e-6));
    }
    for (var i = 0; i < 3; i++) {
      expect(t.gyro[i], closeTo(gyro[i], 1e-6));
    }

    tx.close();
  });

  test('SasLink drops out-of-order sequence numbers', () async {
    final seen = <int>[];
    final sub = link.telemetry.listen((t) => seen.add(t.seq));

    final quat = Float32List.fromList([1, 0, 0, 0]);
    final gyro = Float32List.fromList([0, 0, 0]);
    final tx = await sender();
    for (final seq in [5, 4, 6, 6, 9]) {
      tx.send(
        encodeTelemetry(
            beaconId: 1, seq: seq, sentMs: 0, flags: 0, quat: quat, gyro: gyro),
        InternetAddress.loopbackIPv4,
        kLinkPort,
      );
    }
    await Future.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    tx.close();
    expect(seen, [5, 6, 9]);
  });

  test('announce carries device name + ap flag', () async {
    final got = link.announces.first;

    final tx = await sender();
    tx.send(
      encodeAnnounce(99, name: 'Pixel 6 Pro', apHost: true),
      InternetAddress.loopbackIPv4,
      kLinkPort,
    );

    final a = await got.timeout(const Duration(seconds: 2));
    expect(a.id, 99);
    expect(a.name, 'Pixel 6 Pro');
    expect(a.apHost, isTrue);

    tx.close();
  });

  test('telemetry name + flags round-trip', () async {
    final got = link.telemetry.firstWhere((t) => t.beaconId == 5);

    final tx = await sender();
    tx.send(
      encodeTelemetry(
          beaconId: 5,
          seq: 1,
          sentMs: 0,
          flags: 2 | 0x10, // kind=pad, AP host
          quat: Float32List.fromList([1, 0, 0, 0]),
          gyro: Float32List(3),
          name: 'moto'),
      InternetAddress.loopbackIPv4,
      kLinkPort,
    );

    final t = await got.timeout(const Duration(seconds: 2));
    expect(t.name, 'moto');
    expect(t.kindIndex, 2);
    expect(t.apHost, isTrue);

    tx.close();
  });

  test('manual link probes; link completes on the SASH reply', () async {
    final beacon = SasBeacon(beaconId: 7);
    await beacon.start();

    final got = beacon.linked.first; // subscribe before the probe lands
    beacon.linkTo(InternetAddress.loopbackIPv4);
    expect(beacon.isLinked, isFalse); // unverified — probe in flight
    expect(beacon.isProbing, isTrue);

    // The listener acks the unicast probe announce → verified link.
    await got.timeout(const Duration(seconds: 3));
    expect(beacon.isLinked, isTrue);
    expect(beacon.isProbing, isFalse);

    link.markLinked(7);
    expect(link.linkedIds, contains(7));

    beacon.dispose();
  });

  test('unlink(holdAuto) pauses auto-discovery; SASH is ignored meanwhile',
      () async {
    final beacon = SasBeacon(beaconId: 9)
      ..autoHoldDuration = const Duration(milliseconds: 800);
    await beacon.start();
    // Loopback as the "broadcast" target — real broadcasts don't loop
    // back to a same-host listener on macOS.
    beacon.debugAnnounceTargets = {'127.0.0.1'};

    // Auto-link: announce → shared listener replies SASH → verified.
    await beacon.linked.first.timeout(const Duration(seconds: 3));
    expect(beacon.isLinked, isTrue);

    beacon.unlink(holdAuto: true);
    expect(beacon.isLinked, isFalse);

    // While the hold lasts, even a crafted SASH can't relink us, and no
    // announces leave (probing/broadcast branches are quiet).
    final tx = await sender();
    tx.send(encodeHead(), InternetAddress.loopbackIPv4, beacon.localPort!);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(beacon.isLinked, isFalse);

    // After the hold, announces resume and the listener's reply relinks.
    await beacon.linked.first.timeout(const Duration(seconds: 3));
    expect(beacon.isLinked, isTrue);

    tx.close();
    beacon.dispose();
  });

  test('manual probe to a dead address reports failure', () async {
    final beacon = SasBeacon(beaconId: 8);
    // Set the probe target before start() so the beacon never broadcasts
    // (probing suppresses announces) — otherwise the shared listener
    // would answer and auto-link.
    beacon.linkTo(InternetAddress('192.0.2.1')); // TEST-NET, unreachable
    await beacon.start();
    final dead =
        await beacon.linkFailed.first.timeout(const Duration(seconds: 6));
    expect(dead, InternetAddress('192.0.2.1'));
    expect(beacon.isLinked, isFalse);

    beacon.dispose();
  });
}
