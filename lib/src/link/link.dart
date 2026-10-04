import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// LAN UDP link between the listener phone (head) and beacon phones.
///
/// Discovery: a beacon broadcasts `SASB` announces on [kLinkPort] once a
/// second; a listener replies `SASH` to the sender (its address/port comes
/// from the datagram itself). Once linked, the beacon unicasts `SAST`
/// telemetry packets at ~30 Hz.
///
/// Everything is binary, big-endian, no framing beyond the datagram itself.
/// Stale packets are dropped by sequence number on the receiver.
const int kLinkPort = 47290;

const _magicAnnounce = 0x53415342; // 'SASB'
const _magicHead = 0x53415348; // 'SASH'
const _magicTelemetry = 0x53415354; // 'SAST'
const _magicRangeDelay = 0x53415344; // 'SASD' — acoustic responder delay

/// One telemetry sample from a beacon: fused quat [w,x,y,z] + gyro rad/s.
class BeaconTelemetry {
  BeaconTelemetry({
    required this.beaconId,
    required this.seq,
    required this.sentMs,
    required this.flags,
    required this.quat,
    required this.gyro,
    required this.from,
    this.name,
  });

  final int beaconId;
  final int seq;
  final int sentMs; // sender-side ms clock (for link latency estimates)
  final int flags; // low nibble: kind index; bit 0x10: sender is AP host
  final Float32List quat; // length 4
  final Float32List gyro; // length 3
  final InternetAddress from;
  final String? name; // sender device name, if it sent one

  int get kindIndex => flags & 0xF;
  bool get apHost => flags & 0x10 != 0;
}

/// One discovery announce from a beacon (id + optional name/AP flag).
class BeaconAnnounce {
  BeaconAnnounce(
      {required this.id, required this.from, this.name, this.apHost = false});
  final int id;
  final InternetAddress from;
  final String? name;
  final bool apHost;
}

Uint8List _pack(int magic, void Function(ByteData) fill, int payloadBytes) {
  final b = ByteData(4 + payloadBytes);
  b.setUint32(0, magic);
  fill(b);
  return b.buffer.asUint8List();
}

/// Announce: magic(4) id(2) flags(1) nameLen(1) name(n≤24) — the trailing
/// fields are optional so 6-byte announces from older peers still parse.
Uint8List encodeAnnounce(int beaconId, {String? name, bool apHost = false}) {
  final nb = _nameBytes(name);
  return _pack(_magicAnnounce, (b) {
    b.setUint16(4, beaconId);
    b.setUint8(6, apHost ? 0x10 : 0);
    b.setUint8(7, nb.length);
    for (var i = 0; i < nb.length; i++) {
      b.setUint8(8 + i, nb[i]);
    }
  }, 4 + nb.length);
}

List<int> _nameBytes(String? name) {
  if (name == null) return const [];
  final b = utf8.encode(name);
  return b.length <= 24 ? b : b.sublist(0, 24);
}

Uint8List encodeHead() => _pack(_magicHead, (_) {}, 0);

/// Acoustic responder delay: magic(4) id(2) delayNanos(8) = 14 B.
/// delay = t3−t2 on the beacon's audio clock (recv chirp → reply chirp).
Uint8List encodeRangeDelay(int beaconId, int delayNanos) =>
    _pack(_magicRangeDelay, (b) {
      b.setUint16(4, beaconId);
      b.setInt64(6, delayNanos);
    }, 10);

/// Layout: magic(4) id(2) seq(4) sentMs(4) flags(2) quat(16) gyro(12)
/// = 44 B, plus optional trailing nameLen(1) name(n≤24).
Uint8List encodeTelemetry({
  required int beaconId,
  required int seq,
  required int sentMs,
  required int flags,
  required Float32List quat,
  required Float32List gyro,
  String? name,
}) {
  final nb = _nameBytes(name);
  return _pack(_magicTelemetry, (b) {
    b.setUint16(4, beaconId);
    b.setUint32(6, seq);
    b.setUint32(10, sentMs);
    b.setUint16(14, flags);
    for (var i = 0; i < 4; i++) {
      b.setFloat32(16 + i * 4, quat[i], Endian.little);
    }
    for (var i = 0; i < 3; i++) {
      b.setFloat32(32 + i * 4, gyro[i], Endian.little);
    }
    b.setUint8(44, nb.length);
    for (var i = 0; i < nb.length; i++) {
      b.setUint8(45 + i, nb[i]);
    }
  }, 41 + nb.length);
}

/// Listener side: discover beacons, receive their telemetry.
class SasLink {
  RawDatagramSocket? _sock;
  final _telemetryCtl = StreamController<BeaconTelemetry>.broadcast();
  final _announceCtl = StreamController<BeaconAnnounce>.broadcast();
  final _delayCtl =
      StreamController<({int beaconId, int delayNanos})>.broadcast();
  final _lastSeq = <int, int>{};

  Stream<BeaconTelemetry> get telemetry => _telemetryCtl.stream;

  /// Acoustic responder delays from linked beacons (beaconId, t3−t2 nanos).
  Stream<({int beaconId, int delayNanos})> get rangeDelays =>
      _delayCtl.stream;

  /// Fires each time a new announce arrives (also on re-announce —
  /// treat as a heartbeat / re-link signal).
  Stream<BeaconAnnounce> get announces => _announceCtl.stream;

  /// Beacons we've announced ourselves to: beaconId → listener knows it.
  final linkedIds = <int>{};

  /// Total datagrams received — link diagnostics for the info bar.
  int rxCount = 0;

  Timer? _guardTimer;
  bool _disposed = false;
  Completer<void>? _bindRetry;
  Timer? _bindRetryTimer;

  /// Bind the fixed link port, retrying briefly — socket close() releases
  /// the port asynchronously, so a fast restart can transiently collide.
  /// The retry sleep is cancellable so dispose() can't leave a pending
  /// timer behind (it flaked the widget tests).
  Future<RawDatagramSocket> _bindLinkPort() async {
    Object? err;
    for (var i = 0; i < 20; i++) {
      if (_disposed) throw StateError('link disposed');
      try {
        return await RawDatagramSocket.bind(InternetAddress.anyIPv4,
            kLinkPort,
            reuseAddress: true);
      } on SocketException catch (e) {
        err = e;
        _bindRetry = Completer<void>();
        _bindRetryTimer = Timer(const Duration(milliseconds: 50), () {
          _bindRetryTimer = null;
          final c = _bindRetry;
          _bindRetry = null;
          c?.complete();
        });
        await _bindRetry!.future;
      }
    }
    throw err ?? StateError('link disposed');
  }

  Future<void> start() async {
    if (_disposed) return;
    try {
      _sock ??= await _bindLinkPort();
    } on StateError {
      return; // disposed mid-bind
    }
    if (_disposed) {
      _sock?.close();
      _sock = null;
      return;
    }
    _sock!.listen(_onEvent, onError: (_) {});
    // A failed send (e.g. SASH reply to an unreachable beacon) can kill
    // the socket — the closed event triggers a rebind, and this guards
    // the case where rebind itself fails (airplane mode etc.).
    _guardTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_sock == null) unawaited(_rebind());
    });
  }

  Future<void> _rebind() async {
    _sock = null;
    try {
      final s = await _bindLinkPort();
      s.listen(_onEvent, onError: (_) {});
      _sock = s;
    } catch (_) {
      // Leave null — the guard timer retries.
    }
  }

  void _onEvent(RawSocketEvent ev) {
    if (ev == RawSocketEvent.closed) {
      _sock = null;
      unawaited(_rebind());
      return;
    }
    if (ev != RawSocketEvent.read) return;
    final d = _sock!.receive();
    if (d == null || d.data.length < 4) return;
    rxCount++;
    final magic = ByteData.sublistView(d.data).getUint32(0);
    switch (magic) {
      case _magicAnnounce:
        if (d.data.length < 6) return;
        final b = ByteData.sublistView(d.data);
        String? name;
        var ap = false;
        if (d.data.length >= 8) {
          ap = b.getUint8(6) & 0x10 != 0;
          final nl = b.getUint8(7);
          if (nl > 0 && d.data.length >= 8 + nl) {
            name = utf8.decode(d.data.sublist(8, 8 + nl));
          }
        }
        _announceCtl.add(BeaconAnnounce(
            id: b.getUint16(4), from: d.address, name: name, apHost: ap));
        _ack(d.address, d.port);
      case _magicTelemetry:
        if (d.data.length < 44) return;
        _handleTelemetry(d.data, d.address);
      case _magicRangeDelay:
        if (d.data.length < 14) return;
        final b = ByteData.sublistView(d.data);
        _delayCtl
            .add((beaconId: b.getUint16(4), delayNanos: b.getInt64(6)));
    }
  }

  void _ack(InternetAddress addr, int port) {
    _sock?.send(encodeHead(), addr, port);
  }

  void _handleTelemetry(Uint8List data, InternetAddress from) {
    final b = ByteData.sublistView(data);
    final id = b.getUint16(4);
    final seq = b.getUint32(6);
    final last = _lastSeq[id];
    if (last != null && seq <= last) return; // stale/out-of-order
    _lastSeq[id] = seq;
    String? name;
    if (data.length > 44) {
      final nl = b.getUint8(44);
      if (nl > 0 && data.length >= 45 + nl) {
        name = utf8.decode(data.sublist(45, 45 + nl));
      }
    }
    _telemetryCtl.add(BeaconTelemetry(
      beaconId: id,
      seq: seq,
      sentMs: b.getUint32(10),
      flags: b.getUint16(14),
      quat: Float32List.sublistView(data, 16, 32),
      gyro: Float32List.sublistView(data, 32, 44),
      from: from,
      name: name,
    ));
  }

  void markLinked(int beaconId) => linkedIds.add(beaconId);

  void dispose() {
    _disposed = true;
    // Wake an in-flight bind retry immediately — no pending Timer left.
    _bindRetryTimer?.cancel();
    _bindRetryTimer = null;
    final c = _bindRetry;
    _bindRetry = null;
    c?.complete();
    _guardTimer?.cancel();
    _guardTimer = null;
    _sock?.close();
    _sock = null;
  }
}

/// Beacon side: announce until a listener answers, then unicast telemetry.
class SasBeacon {
  SasBeacon({required this.beaconId});

  final int beaconId;
  RawDatagramSocket? _sock;
  Timer? _announceTimer;
  InternetAddress? _listener;
  InternetAddress? _probe; // manual-link target awaiting its first SASH
  // Manual-unlink hold: announces suppressed until this time so the link
  // can't auto-reform before the user gets a chance to type a new IP.
  DateTime _holdAutoUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _probeCount = 0;
  int _kaTick = 0;
  DateTime _lastAck = DateTime.fromMillisecondsSinceEpoch(0);
  int _seq = 0;
  final _bcastAddrs = <String>{'255.255.255.255'};
  final _linkedCtl = StreamController<InternetAddress>.broadcast();
  final _probeFailCtl = StreamController<InternetAddress>.broadcast();
  final _linkLostCtl = StreamController<void>.broadcast();

  /// Advertised in announce/telemetry — the listener shows this instead
  /// of a bare beacon id, and uses [apHost] to label the link "hotspot".
  String? deviceName;
  bool apHost = false;

  /// Fires once when a listener replies to our announce — i.e. the link
  /// is verified in both directions, never claimed on send alone.
  Stream<InternetAddress> get linked => _linkedCtl.stream;

  /// The manual probe target never answered — wrong IP or unreachable.
  Stream<InternetAddress> get linkFailed => _probeFailCtl.stream;

  /// Linked listener stopped answering keepalives (network drop, app
  /// closed) — the beacon has unlinked and resumed announcing.
  Stream<void> get linkLost => _linkLostCtl.stream;

  bool get isLinked => _listener != null;
  bool get isProbing => _probe != null;

  /// Bound UDP port — diagnostics/tests (SASH replies must reach it).
  int? get localPort => _sock?.port;

  /// How long manual unlink suppresses auto-discovery. Settable for tests.
  Duration autoHoldDuration = const Duration(seconds: 30);

  /// Overrides the announce target list — test hook; real broadcasts
  /// don't loop back on every host. Rebuilt by [refreshInterfaces].
  set debugAnnounceTargets(Set<String> addrs) {
    _bcastAddrs
      ..clear()
      ..addAll(addrs);
  }

  Future<void> start() async {
    _sock ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sock!.broadcastEnabled = true;
    // Socket errors (e.g. broadcast with no route — airplane mode, test
    // sandbox) surface async on the error stream, not from send().
    _sock!.listen(_onEvent, onError: (_) {});
    await refreshInterfaces();
    _announceTimer ??=
        Timer.periodic(const Duration(seconds: 1), (_) => _announce());
    _announce();
  }

  /// (Re)build the announce targets: each interface's /24 broadcast plus
  /// the global 255.255.255.255 — some APs/hotspots drop the global form
  /// but forward the subnet-directed one (e.g. 192.168.43.255 on an
  /// Android hotspot). Re-run when the subnet changes.
  ///
  /// Order matters: a send to an unroutable broadcast address can surface
  /// an async error that CLOSES the socket, so subnet broadcasts go first
  /// and the global one last.
  Future<void> refreshInterfaces() async {
    _bcastAddrs.clear();
    for (final i
        in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (a.isLoopback) continue;
        final p = a.address.split('.');
        if (p.length == 4 && p[0] != '127' && p[0] != '169') {
          _bcastAddrs.add('${p[0]}.${p[1]}.${p[2]}.255');
        }
      }
    }
    _bcastAddrs.add('255.255.255.255');
  }

  /// A failed send can kill the socket (async error → RawSocketEvent
  /// .closed). Rebind so the next tick resumes — one announce may drop.
  Future<void> _rebind() async {
    _sock = null;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      s.listen(_onEvent, onError: (_) {});
      _sock = s;
    } catch (_) {
      // Leave null — the next announce tick retries.
    }
  }

  /// 1 Hz state machine:
  /// - linked → unicast keepalive announce every 4 s; two missed SASH
  ///   replies (>8 s silence) = link dead → unlink + [linkLost]
  /// - probing → unicast announce to the manual target; ~4 unanswered
  ///   probes = unreachable → [linkFailed]
  /// - else → broadcast announces for auto-discovery
  void _announce() {
    // Socket died from a send error and hasn't finished rebinding yet —
    // keep the state machine running (probe/keepalive counts still
    // advance) and retry the bind so the next tick can send.
    if (_sock == null) unawaited(_rebind());
    final pkt = encodeAnnounce(beaconId, name: deviceName, apHost: apHost);
    final l = _listener;
    if (l != null) {
      if (DateTime.now().difference(_lastAck) >
          const Duration(seconds: 8)) {
        _listener = null;
        _linkLostCtl.add(null);
        return;
      }
      if (++_kaTick % 4 == 0) _sock?.send(pkt, l, kLinkPort);
      return;
    }
    final p = _probe;
    if (p != null) {
      _sock?.send(pkt, p, kLinkPort);
      if (++_probeCount >= 4) {
        _probe = null;
        _probeFailCtl.add(p);
      }
      return;
    }
    // Manual-unlink hold: stay quiet so the previous listener's SASH
    // can't auto-reform the link while the user types a new IP.
    if (DateTime.now().isBefore(_holdAutoUntil)) return;
    for (final addr in _bcastAddrs) {
      _sock?.send(pkt, InternetAddress(addr), kLinkPort);
    }
  }

  /// Point the beacon at a listener manually (AP isolation fallback).
  /// This only *starts probing* — the link is established when the
  /// listener's SASH reply arrives, so "linked" is always verified.
  /// Re-targeting drops any current link so it must re-verify.
  void linkTo(InternetAddress addr) {
    _listener = null;
    _probe = addr;
    _probeCount = 0;
    _sock?.send(encodeAnnounce(beaconId, name: deviceName, apHost: apHost),
        addr, kLinkPort);
  }

  void _completeLink(InternetAddress addr) {
    _probe = null;
    _listener = addr;
    _kaTick = 0;
    _lastAck = DateTime.now();
    _linkedCtl.add(addr);
  }

  /// Drop the link target. With [holdAuto], announces pause for
  /// [autoHoldDuration] so the link can't instantly auto-reform — the
  /// window for typing a new IP. Without it, announces resume on the
  /// next timer tick (used for subnet-change re-discovery).
  void unlink({bool holdAuto = false}) {
    _listener = null;
    _probe = null;
    if (holdAuto) {
      _holdAutoUntil = DateTime.now().add(autoHoldDuration);
    }
  }

  void _onEvent(RawSocketEvent ev) {
    if (ev == RawSocketEvent.closed) {
      _sock = null;
      unawaited(_rebind());
      return;
    }
    if (ev != RawSocketEvent.read) return;
    final d = _sock!.receive();
    if (d == null || d.data.length < 4) return;
    if (ByteData.sublistView(d.data).getUint32(0) != _magicHead) return;
    if (_listener != null) {
      _lastAck = DateTime.now();
    } else if (_probe != null) {
      // Probing: only the target's own reply completes the link —
      // a stray broadcast reply mustn't sneak in.
      if (d.address == _probe) _completeLink(d.address);
    } else if (DateTime.now().isAfter(_holdAutoUntil)) {
      _completeLink(d.address);
    }
  }

  void sendTelemetry(Float32List quat, Float32List gyro,
      {int flags = 0, int sentMs = 0}) {
    final l = _listener;
    if (l == null) return;
    _sock?.send(
      encodeTelemetry(
        beaconId: beaconId,
        seq: _seq++,
        sentMs: sentMs,
        flags: flags | (apHost ? 0x10 : 0),
        quat: quat,
        gyro: gyro,
        name: deviceName,
      ),
      l,
      kLinkPort,
    );
  }

  /// Beacon role: report the acoustic responder delay (t3−t2) to the
  /// listener so it can finish the two-way range computation.
  void sendRangeDelay(int delayNanos) {
    final l = _listener;
    if (l == null) return;
    _sock?.send(encodeRangeDelay(beaconId, delayNanos), l, kLinkPort);
  }

  void dispose() {
    _announceTimer?.cancel();
    _announceTimer = null;
    _sock?.close();
    _sock = null;
    _listener = null;
    _probe = null;
  }
}
