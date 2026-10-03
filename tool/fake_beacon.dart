// ignore_for_file: avoid_print
// Fake beacon for desktop testing of the link + tracker path.
// Announces to a listener on 127.0.0.1:47290, waits for the SASH reply,
// then streams telemetry with a beacon "pointing direction" that slowly
// rotates — the linked source on the radar should orbit the head.
//
//   dart run tool/fake_beacon.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:spatial_audio_sandbox/src/link/link.dart';

void main() async {
  final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final listener = InternetAddress.loopbackIPv4;

  Uint8List telemetry(int seq, double azRad) {
    // Quat: yaw rotation so device +Y (top edge) points at bearing azRad.
    // Aim at listener = face opposite to the beacon's bearing from it.
    final a = azRad + math.pi;
    final h = a / 2;
    return encodeTelemetry(
      beaconId: 4242,
      seq: seq,
      sentMs: DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF,
      flags: 0, // kind index 0 = bee
      quat: Float32List.fromList([math.cos(h), 0, 0, math.sin(h)]),
      gyro: Float32List(3),
      name: 'fake beacon',
    );
  }

  var linked = false;
  var seq = 0;
  final t0 = DateTime.now();

  sock.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = sock.receive();
    if (d == null || d.data.length < 4) return;
    if (ByteData.sublistView(d.data).getUint32(0) == 0x53415348) {
      linked = true;
      print('linked — streaming telemetry');
    }
  });

  final ann = encodeAnnounce(4242, name: 'fake beacon');
  Timer.periodic(const Duration(seconds: 1), (_) {
    if (!linked) sock.send(ann, listener, kLinkPort);
  });
  sock.send(ann, listener, kLinkPort);

  Timer.periodic(const Duration(milliseconds: 33), (_) {
    if (!linked) return;
    final t = DateTime.now().difference(t0).inMilliseconds / 1000;
    final az = t * 0.6; // ~0.6 rad/s orbit
    sock.send(telemetry(seq++, az), listener, kLinkPort);
  });

  print('fake beacon announcing on loopback…');
}
