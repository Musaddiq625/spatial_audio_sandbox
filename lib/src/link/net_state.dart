import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Network state for the UDP link — polled from interface addresses, no
/// plugin needed. "online" means a LAN-capable interface has an IPv4;
/// mobile data does NOT count (the link is local-network only).
enum NetState { offline, wifi, hotspotHost }

class NetSnapshot {
  const NetSnapshot(this.state, this.ip, this.apHost);
  final NetState state;

  /// Preferred local IPv4 — the AP interface's when hosting, else Wi-Fi's.
  final String? ip;

  /// This phone is hosting a hotspot (has an ap*/swlan*/softap* interface
  /// with an address). Remote peers learn this via the telemetry flag.
  final bool apHost;

  bool get online => state != NetState.offline;
}

/// Watches interface addresses every [period]; emits a [NetSnapshot] on
/// the broadcast stream only when something actually changed.
class NetMonitor {
  static const period = Duration(seconds: 2);
  static final _lanIf = RegExp(r'^(wlan|p2p|en|eth)');
  static final _apIf = RegExp(r'^(ap|swlan|softap)');

  final _ctl = StreamController<NetSnapshot>.broadcast();
  Timer? _timer;
  NetSnapshot _current = const NetSnapshot(NetState.offline, null, false);

  Stream<NetSnapshot> get changes => _ctl.stream;
  NetSnapshot get current => _current;

  void start() {
    _timer ??= Timer.periodic(period, (_) => _poll());
    unawaited(_poll());
  }

  Future<void> _poll() async {
    String? wlanIp, apIp;
    var ap = false;
    try {
      for (final i
          in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        final name = i.name.toLowerCase();
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          if (_apIf.hasMatch(name)) {
            ap = true;
            apIp ??= a.address;
          } else if (_lanIf.hasMatch(name)) {
            wlanIp ??= a.address;
          }
        }
      }
    } catch (_) {
      return; // keep last snapshot on transient failures
    }
    final online = wlanIp != null || apIp != null;
    final s = NetSnapshot(
        !online
            ? NetState.offline
            : (ap ? NetState.hotspotHost : NetState.wifi),
        apIp ?? wlanIp,
        ap);
    if (s.state != _current.state ||
        s.ip != _current.ip ||
        s.apHost != _current.apHost) {
      _current = s;
      _ctl.add(s);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Device display name for the link UI ("Pixel 6 Pro", …) via the
/// platform channel; falls back to the OS name off-Android.
Future<String> deviceName() async {
  _nameCache ??= await _fetchDeviceName();
  return _nameCache!;
}

String? _nameCache;

Future<String> _fetchDeviceName() async {
  if (Platform.isAndroid) {
    try {
      final n = await const MethodChannel('dev.sas.spatial_audio_sandbox/device')
          .invokeMethod<String>('getDeviceName');
      if (n != null && n.isNotEmpty) return n;
    } catch (_) {}
    return 'android';
  }
  return Platform.operatingSystem;
}
