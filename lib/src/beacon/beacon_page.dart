import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:spatial_audio_sandbox/src/link/acoustic_bridge.dart';
import 'package:spatial_audio_sandbox/src/link/link.dart';
import 'package:spatial_audio_sandbox/src/link/net_state.dart';

/// Beacon role: this phone IS a movable sound source. It streams its
/// rotation-vector pose over UDP to the listener at ~30 Hz and shows a
/// marker/status screen. The listener's radar plots it and the engine
/// spatializes whatever kind was picked here.
class BeaconPage extends StatefulWidget {
  const BeaconPage({super.key});

  @override
  State<BeaconPage> createState() => _BeaconPageState();
}

class _BeaconPageState extends State<BeaconPage> {
  static const _poseChannel = EventChannel(
    'dev.sas.spatial_audio_sandbox/pose',
  );
  static const _sendPeriod = Duration(milliseconds: 33); // ~30 Hz

  late final SasBeacon _beacon;
  final _acoustic = AcousticChannel();
  final _net = NetMonitor();
  StreamSubscription<NetSnapshot>? _netSub;
  StreamSubscription<dynamic>? _poseSub;
  StreamSubscription<List<int>>? _acousticSub;
  Timer? _sendTimer;
  Float32List? _latest;
  String _kind = 'Bee';
  String _status = 'announcing…';
  String _localIp = '?';
  int _sent = 0;
  final _ipCtl = TextEditingController(text: '10.110.197.206');

  static const _kinds = ['Bee', 'Rain', 'Pad', 'Tone', 'Noise'];

  @override
  void initState() {
    super.initState();
    _beacon = SasBeacon(beaconId: Random().nextInt(0xFFFF));
    _start();
  }

  Future<void> _start() async {
    _beacon.deviceName = await deviceName();
    await _beacon.start();
    _beacon.linked.listen((addr) {
      if (mounted) setState(() => _status = 'linked → ${addr.address}');
    });
    _beacon.linkFailed.listen((addr) {
      if (mounted) {
        setState(
          () => _status = 'no reply from ${addr.address} — check IP/network',
        );
      }
    });
    _beacon.linkLost.listen((_) {
      if (mounted) setState(() => _status = 'link lost — announcing…');
    });
    _net.start();
    _netSub = _net.changes.listen(_onNet);
    _localIp = _net.current.ip ?? '?';
    if (defaultTargetPlatform == TargetPlatform.android) {
      _poseSub = _poseChannel.receiveBroadcastStream().listen((data) {
        if (data is Float32List && data.length >= 7) _latest = data;
      }, onError: (e) => debugPrint('beacon pose error: $e'));
    }
    _sendTimer = Timer.periodic(_sendPeriod, (_) => _tick());
    if (!mounted) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Beacon acoustic role: hear the listener's chirp, reply, and report
      // the responder delay (t3−t2) back over UDP.
      _acoustic.start('beacon');
      _acousticSub = _acoustic.events.listen((e) {
        if (e[0] == 3) _beacon.sendRangeDelay(e[1]);
      });
    } else {
      setState(() => _status = 'desktop beacon — no sensors, still announces');
    }
  }

  /// Network transitions: keep the AP flag + local IP current, and when
  /// the subnet itself moves (Wi-Fi → hotspot, new DHCP lease) drop the
  /// dead unicast target so announces resume and the link re-forms.
  Future<void> _onNet(NetSnapshot s) async {
    if (!mounted) return;
    _beacon.apHost = s.apHost;
    final ipChanged = s.ip != null && s.ip != _localIp;
    if (ipChanged) {
      _localIp = s.ip!;
      await _beacon.refreshInterfaces();
      if (_beacon.isLinked) {
        _beacon.unlink();
        _status = 'announcing…';
      }
    }
    if (!s.online) _status = 'offline — not sending';
    setState(() {});
  }

  void _tick() {
    final s = _latest;
    if (s == null) return;
    _beacon.sendTelemetry(
      Float32List.sublistView(s, 0, 4),
      Float32List.sublistView(s, 4, 7),
      flags: _kinds.indexOf(_kind) & 0xF,
      sentMs: DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF,
    );
    if (mounted && _beacon.isLinked && ++_sent % 30 == 0) {
      setState(() {}); // refresh sent counter once a second
    }
  }

  void _manualLink() {
    try {
      final addr = InternetAddress(_ipCtl.text.trim());
      _beacon.linkTo(addr); // probes; "linked" fires only on the reply
      setState(() => _status = 'probing ${_ipCtl.text.trim()}…');
    } on ArgumentError {
      setState(() => _status = 'bad IP');
    }
  }

  void _unlink() {
    // Hold auto-discovery briefly — otherwise the listener answers the
    // next announce and re-links before a new IP can be typed.
    _beacon.unlink(holdAuto: true);
    setState(
      () => _status =
          'unlinked — auto-discovery paused ${(_beacon.autoHoldDuration).inSeconds}s',
    );
  }

  @override
  void dispose() {
    _sendTimer?.cancel();
    _netSub?.cancel();
    _net.dispose();
    _poseSub?.cancel();
    _acousticSub?.cancel();
    _acoustic.stop();
    _beacon.dispose();
    _ipCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('beacon', style: TextStyle(fontSize: 16)),
        ),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_net.current.online)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A3200),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFC107)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.wifi_off, size: 18, color: Color(0xFFFFC107)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'no LAN — turn on Wi-Fi or host/join a hotspot',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFFFC107),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Big bright tile — doubles as a visual marker later.
              Container(
                height: 140,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _kind.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                children: [
                  for (final k in _kinds)
                    ChoiceChip(
                      label: Text(k),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'status: $_status',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFF9AA4B2),
                ),
              ),
              Text(
                'sent: $_sent packets — ip $_localIp — ${_net.current.state == NetState.hotspotHost ? 'hotspot' : _net.current.state.name}',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFF9AA4B2),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'aimed mode: point the top edge of this phone at the listener.',
                style: TextStyle(fontSize: 12, color: Color(0xFF9AA4B2)),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipCtl,
                      enabled: !_beacon.isLinked,
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'listener IP (manual fallback)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _beacon.isLinked ? _unlink : _manualLink,
                    child: Text(
                      _beacon.isLinked
                          ? 'unlink'
                          : (_beacon.isProbing ? 'probing…' : 'link'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
