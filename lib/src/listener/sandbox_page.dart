import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spatial_audio_sandbox/src/director/llm_client.dart';
import 'package:spatial_audio_sandbox/src/director/scene_director.dart';
import 'package:spatial_audio_sandbox/src/director/sfx_client.dart';
import 'package:spatial_audio_sandbox/src/link/acoustic_bridge.dart';
import 'package:spatial_audio_sandbox/src/listener/beacon_tracker.dart';
import 'package:spatial_audio_sandbox/src/link/link.dart';
import 'package:spatial_audio_sandbox/src/link/net_state.dart';
import 'package:spatial_audio_sandbox/src/listener/pose_channel.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

/// Scene-space position: `front` meters ahead (+x), `left` meters left (+y).
/// Elevation lives in `z` — the radar draws only x/y.
class SourceDot {
  SourceDot({
    required this.id,
    required this.kind,
    required this.pos,
    this.gain = 1.0,
    this.z = 0,
    this.delayS = 0,
    this.estDurS = 0,
    String? label,
  }) : label = label ?? kind.name;
  int? id; // live engine id — null while pending (scheduled, not yet
  // audible). Re-assigned when the engine restarts (old ids die with it)
  final SourceKindWire kind;
  Offset pos; // (front, left), meters
  double gain;
  double z; // up, meters
  String label; // spec name or kind name — shown on the radar + chips

  /// Authored cue from the spec: seconds after scene start when this
  /// source becomes audible. estDurS > 0 marks a scene-authored dot
  /// (manual palette dots have 0 and stay off the master seekbar).
  double delayS;
  double estDurS;
  DateTime? dueAt; // sceneT0 + delayS — set when the dot is pending
  bool adding = false; // async engine-add in flight — tick re-entry guard
  bool addFailed = false; // engine add threw — stops tick retries until
  // a scene seek or engine restart gives it a fresh attempt

  /// Pending: authored dot with no live engine source yet (its cue
  /// hasn't arrived, or the scene was scrubbed back before it).
  bool get pending => id == null;

  /// Finished: a one-shot file source the engine already dropped —
  /// playhead reached the end. The dot stays for master-bar scrubbing
  /// (seeking back into its window revives it) but is stale in Rust.
  bool get finished {
    final dur = fileDurS, t0 = fileT0;
    if (!isFile || looping || dur == null || t0 == null) return false;
    return DateTime.now().difference(t0).inMilliseconds >= dur * 1000;
  }

  /// Needs an engine source: pending, or a finished one-shot sitting
  /// inside its play window again after a scrub.
  bool get needsSource => pending || finished;

  /// Decoded-clip bytes once SFX generation lands (the procedural `kind`
  /// is only the stand-in). Kept so engine restarts re-add the file
  /// source without another generation call.
  Uint8List? fileBytes;
  bool looping = true;
  bool get isFile => fileBytes != null;

  /// Real decoded clip length + playhead anchor — the seekbar's position
  /// is estimated locally as (now - fileT0), not polled from Rust.
  double? fileDurS;
  DateTime? fileT0;
}

/// A sent prompt + the spec it generated — the chip replays the cached
/// spec without another model call. spec stays null while generating.
/// Serializes for SharedPreferences so history survives restarts.
class _PromptEntry {
  _PromptEntry(this.prompt);
  final String prompt;
  SceneSpec? spec;
  final startedAt = DateTime.now();
  double? specSeconds; // filled when the spec lands

  Map<String, Object?> toJson() => {
    'prompt': prompt,
    if (spec != null) 'spec': SceneDirector.specToJson(spec!),
  };

  static _PromptEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final prompt = raw['prompt'] as String?;
    if (prompt == null) return null;
    final e = _PromptEntry(prompt);
    final spec = raw['spec'];
    if (spec != null) {
      try {
        e.spec = SceneDirector.parseSpec(jsonEncode(spec));
      } on SpecException {
        return null;
      }
    }
    return e;
  }
}

const _kindColors = {
  SourceKindWire.bee: Color(0xFFFFC107),
  SourceKindWire.rain: Color(0xFF4FC3F7),
  SourceKindWire.pad: Color(0xFFBA68C8),
  SourceKindWire.tone: Color(0xFF81C784),
  SourceKindWire.noise: Color(0xFFE0E0E0),
  SourceKindWire.click: Color(0xFFFF8A65),
};

// Beacon kind indices must match _kinds in beacon_page.dart.
const _beaconKinds = [
  SourceKindWire.bee,
  SourceKindWire.rain,
  SourceKindWire.pad,
  SourceKindWire.tone,
  SourceKindWire.noise,
];

/// A remote beacon bound to an engine source — position arrives over UDP.
class _BeaconState {
  _BeaconState({required this.tracker});
  final AimedBeaconTracker tracker;
  int? sourceId; // null until engine source is created
  SourceKindWire? kind; // decoded from telemetry flags
  String? name; // remote device name (Build.MODEL), from announce/telemetry
  bool apHost = false; // remote phone is hosting the hotspot
  BeaconSample? sample;
  DateTime lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
}

class SandboxPage extends StatefulWidget {
  const SandboxPage({super.key});

  @override
  State<SandboxPage> createState() => _SandboxPageState();
}

class _SandboxPageState extends State<SandboxPage> {
  final _pose = PoseBridge();
  final _sources = <SourceDot>[];
  final _link = SasLink();
  final _beacons = <int, _BeaconState>{};
  final _announced = <int, BeaconAnnounce>{}; // seen but not bound yet
  final _net = NetMonitor();
  StreamSubscription<NetSnapshot>? _netSub;
  bool _stoppedByNet = false; // engine was force-stopped on network loss
  bool _peerApHost = false; // any linked/announced peer hosts the hotspot
  StreamSubscription<BeaconTelemetry>? _teleSub;
  StreamSubscription<BeaconAnnounce>? _announceSub;
  final _acoustic = AcousticChannel();
  StreamSubscription<List<int>>? _acousticSub;
  StreamSubscription<({int beaconId, int delayNanos})>? _delaySub;
  Timer? _pingTimer;
  int _lastEmitNs = 0; // listener audio-clock t1
  int _lastRecvNs = 0; // listener audio-clock t4
  final _delayNs = <int, int>{}; // beaconId → responder delay (t3−t2)
  static const _speedOfSound = 343.0; // m/s
  String _localIp = '?';
  EngineInfoWire? _info;
  bool _engineOn = false;
  // double _predictMs = 0;
  double _virtualYaw = 0; // radians, desktop fallback
  double _yawAtRecenter = 0;
  int _nextPaletteIdx = 0;
  Timer? _statsTimer;
  final _promptCtl = TextEditingController();
  late final SceneDirector _director;

  static const _rangeM = 5.0; // radar half-width in meters

  @override
  void initState() {
    super.initState();
    _director = SceneDirector(
      llm: LlmClient(),
      sfx: SfxClient(),
      onError: _toast,
      add: _directedAdd,
      remove: _directedRemove,
      setPos: _directedSetPos,
      upgrade: _directedUpgrade,
      onStatus: _sfxStatus,
      onSceneStart: _onSceneStart,
    );
    _pose.start();
    _link.start();
    unawaited(_loadPrompts());
    _announceSub = _link.announces.listen((a) {
      if (a.apHost) _peerApHost = true;
      if (mounted && !_beacons.containsKey(a.id)) {
        setState(() => _announced[a.id] = a);
      }
    });
    _teleSub = _link.telemetry.listen(_onTelemetry);
    _delaySub = _link.rangeDelays.listen(
      (d) => _delayNs[d.beaconId] = d.delayNanos,
    );
    _net.start();
    _netSub = _net.changes.listen(_onNet);
    _localIp = _net.current.ip ?? '?';
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_engineOn) return;
      final i = engineInfo();
      if (i != null && mounted) setState(() => _info = i);
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _seekTicker?.cancel();
    _describeTicker?.cancel();
    _pose.stop();
    _netSub?.cancel();
    _net.dispose();
    _teleSub?.cancel();
    _announceSub?.cancel();
    _delaySub?.cancel();
    _acousticSub?.cancel();
    _pingTimer?.cancel();
    _acoustic.stop();
    _link.dispose();
    _promptCtl.dispose();
    _director.dispose();
    super.dispose();
  }

  // ----- beacon link -----

  /// Network transitions: engine dies on offline (restored on reconnect
  /// only if the monitor stopped it), IP label follows the interface.
  Future<void> _onNet(NetSnapshot s) async {
    if (!mounted) return;
    if (s.online) {
      _localIp = s.ip ?? _localIp;
      if (_stoppedByNet) {
        _stoppedByNet = false;
        await _startEngine();
      }
      setState(() {});
      return;
    }
    // offline
    setState(() {});
    if (_engineOn) {
      _stoppedByNet = true;
      await _stopEngine();
      if (mounted) _toast('network lost — engine stopped');
    }
  }

  void _onTelemetry(BeaconTelemetry t) {
    if (t.apHost) _peerApHost = true;
    final b = _beacons[t.beaconId];
    if (b == null) {
      // Remember the kind flag so binding can pick the right source later.
      // Telemetry from an unannounced beacon (manual link path) still
      // surfaces it as a link candidate.
      if (t.kindIndex < _beaconKinds.length) {
        _pendingKind[t.beaconId] = t.kindIndex;
      }
      if (!_announced.containsKey(t.beaconId)) {
        setState(
          () => _announced[t.beaconId] = BeaconAnnounce(
            id: t.beaconId,
            from: t.from,
            name: t.name,
            apHost: t.apHost,
          ),
        );
      }
      return;
    }
    b.name ??= t.name;
    if (t.apHost) b.apHost = true;
    // The beacon can switch kind live; the generator is baked into the
    // engine source, so recreate it on change.
    final newKind = t.kindIndex < _beaconKinds.length
        ? _beaconKinds[t.kindIndex]
        : null;
    if (newKind != null && b.kind != newKind) {
      final swap = b.kind != null && b.sourceId != null;
      b.kind = newKind;
      if (swap) {
        removeSource(id: b.sourceId!);
        b.sourceId = null;
        unawaited(_createBeaconSource(b));
      }
    }
    b.lastSeen = DateTime.now();
    b.tracker.onTelemetry(t);
    b.sample = b.tracker.sample;
    final s = b.sample;
    if (s != null && b.sourceId != null) {
      setSourcePosition(id: b.sourceId!, x: s.pos.dx, y: s.pos.dy, z: 0);
    }
    if (mounted) setState(() {});
  }

  final _pendingKind = <int, int>{};

  Future<void> _linkBeacon(int beaconId) async {
    final ann = _announced.remove(beaconId);
    _link.markLinked(beaconId);
    final tracker = AimedBeaconTracker(headYawRad: () => _displayYaw);
    final b = _beacons.putIfAbsent(
      beaconId,
      () => _BeaconState(tracker: tracker),
    );
    b.name ??= ann?.name;
    if (ann?.apHost == true) b.apHost = true;
    final kindIdx = _pendingKind[beaconId];
    if (kindIdx != null) b.kind = _beaconKinds[kindIdx];
    if (_engineOn) await _createBeaconSource(b);
    _startRanging();
    setState(() {});
  }

  // ----- acoustic ranging (two-way chirp ping) -----

  void _startRanging() {
    if (_pingTimer != null) return;
    _acoustic.start('listener');
    _acousticSub = _acoustic.events.listen(_onAcousticEvent);
    _pingTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_beacons.isNotEmpty) _acoustic.ping();
    });
  }

  void _onAcousticEvent(List<int> e) {
    switch (e[0]) {
      case 1:
        _lastEmitNs = e[1];
      case 2:
        _lastRecvNs = e[1];
        _finishRange();
      case 3:
        break; // responder delay — only produced on the beacon
    }
  }

  /// d = c·((t4−t1) − (t3−t2))/2 — both clocks are per-device audio clocks,
  /// so the constant software latencies cancel out.
  ///
  /// Single-beacon only: simultaneous replies would collide acoustically and
  /// the t1/t4 pairing would be ambiguous. With >1 beacon linked we just
  /// keep aimed-mode distance.
  void _finishRange() {
    if (_beacons.length != 1) return;
    final b = _beacons.values.first;
    final delayNs = _delayNs[_beacons.keys.first];
    if (_lastEmitNs == 0 || _lastRecvNs == 0 || delayNs == null) return;
    final flightNs = _lastRecvNs - _lastEmitNs - delayNs;
    _lastEmitNs = _lastRecvNs = 0; // consumed
    // Sanity: responder delay <300 ms, two-way flight <40 ms (~14 m).
    // A mis-paired t1/t4 or stale delay would otherwise slam the
    // distance to the 8 m clamp.
    if (delayNs < 0 || delayNs > 300000000) return;
    if (flightNs < 0 || flightNs > 40000000) return;
    b.tracker.feedDistance(_speedOfSound * flightNs / 2e9);
  }

  Future<void> _toggleEngine() async {
    if (_engineOn) {
      await _stopEngine();
    } else {
      await _startEngine();
    }
  }

  Future<void> _stopEngine() async {
    _director.setMotionPaused(true); // freeze directed dots on the radar
    _scrubbing = false; // drop any in-flight scrub commit
    _scrubT = null;
    await engineStop();
    // The engine dropped every source — ids are now stale.
    for (final b in _beacons.values) {
      b.sourceId = null;
    }
    setState(() {
      _engineOn = false;
      _info = null;
    });
    _syncSeekTicker();
  }

  Future<void> _startEngine() async {
    try {
      final info = await engineStart();
      // Fresh engine has no sources — re-add local dots and linked beacons.
      for (final s in _sources) {
        if (s.pending) continue; // not due — the ticker realizes it
        s.addFailed = false;
        if (s.isFile) {
          final info = await addFileSource(
            bytes: s.fileBytes!,
            looping: s.looping,
            x: s.pos.dx,
            y: s.pos.dy,
            z: s.z,
            gain: s.gain,
          );
          s.id = info.id;
          s.fileDurS = info.durationS;
          // Resume at the scene-score position, not from 0.
          final local = _sceneT - s.delayS;
          if (s.estDurS > 0 && local > 0 && info.durationS > 0) {
            final pos = s.looping
                ? local % info.durationS
                : local.clamp(0.0, info.durationS);
            seekSource(id: info.id, posS: pos);
            s.fileT0 = DateTime.now()
                .subtract(Duration(milliseconds: (pos * 1000).round()));
          } else {
            s.fileT0 = DateTime.now();
          }
        } else {
          s.id = await addSource(
            kind: s.kind,
            x: s.pos.dx,
            y: s.pos.dy,
            z: s.z,
            gain: s.gain,
          );
        }
      }
      for (final b in _beacons.values) {
        await _createBeaconSource(b);
      }
      _director.setMotionPaused(false); // resume orbit ticks (live ids)
      _director.seekScene(_sceneT); // motion re-anchors to the score
      setState(() {
        _engineOn = true;
        _info = info;
      });
      _syncSeekTicker(); // file sources re-added — playheads ticking again
    } catch (e) {
      _toast('engine start failed: $e');
    }
  }

  Future<void> _createBeaconSource(_BeaconState b) async {
    if (b.sourceId != null) return;
    final p = b.sample?.pos ?? const Offset(1.5, 0);
    try {
      b.sourceId = await addSource(
        kind: b.kind ?? SourceKindWire.bee,
        x: p.dx,
        y: p.dy,
        z: 0,
        gain: 0.9,
      );
    } catch (e) {
      _toast('beacon source failed: $e');
    }
  }

  Future<void> _addSource(SourceKindWire kind) async {
    if (!_engineOn) {
      _toast('start the engine first');
      return;
    }
    // Scatter new sources around the head so drags are interesting.
    const spots = [
      Offset(1.4, 0.6),
      Offset(-1.0, -1.4),
      Offset(2.4, -0.8),
      Offset(0.6, 1.8),
      Offset(-1.8, 0.9),
      Offset(1.0, -2.2),
    ];
    final p = spots[_nextPaletteIdx++ % spots.length];
    try {
      final id = await addSource(kind: kind, x: p.dx, y: p.dy, z: 0, gain: 0.9);
      setState(() => _sources.add(SourceDot(id: id, kind: kind, pos: p)));
    } catch (e) {
      _toast('add source failed: $e');
    }
  }

  // ----- scene director -----

  Future<Object?> _directedAdd(
    SourceKindWire kind,
    Offset pos,
    double z,
    double gain, {
    String? label,
    SpecSource? spec,
  }) async {
    if (!_engineOn) {
      _toast('start the engine first');
      return null;
    }
    final dot = SourceDot(
      id: null,
      kind: kind,
      pos: pos,
      gain: gain,
      z: z,
      label: label,
      delayS: spec?.delayS ?? 0,
      estDurS: spec?.durationS ?? 0,
    );
    setState(() => _sources.add(dot));
    final delay = dot.delayS;
    if (delay <= 0) {
      // Immediate cue — add the engine source right away.
      if (!await _realizeDot(dot)) {
        setState(() => _sources.remove(dot)); // don't linger as pending
        return null;
      }
    } else {
      // Scheduled cue — pending dot, no engine source yet. The seek
      // ticker's _ensurePendingAdds realizes it at sceneT >= delay.
      dot.dueAt = _sceneT0?.add(
        Duration(milliseconds: (delay * 1000).round()),
      );
      debugPrint('[scene] ${dot.label}: due in ${delay.toStringAsFixed(1)}s');
      _syncSeekTicker(); // start ticking so the pending add fires
    }
    return dot;
  }

  /// Create the engine source for a dot that has none — procedural or
  /// file depending on whether the clip has landed. Returns true if a
  /// live engine id exists afterward.
  Future<bool> _realizeDot(SourceDot dot) async {
    if (dot.id != null || dot.adding || !_engineOn) return dot.id != null;
    dot.adding = true;
    try {
      if (dot.isFile) {
        final info = await addFileSource(
          bytes: dot.fileBytes!,
          looping: dot.looping,
          x: dot.pos.dx,
          y: dot.pos.dy,
          z: dot.z,
          gain: dot.gain,
        );
        dot.id = info.id;
        dot.fileDurS = info.durationS;
      } else {
        dot.id = await addSource(
          kind: dot.kind,
          x: dot.pos.dx,
          y: dot.pos.dy,
          z: dot.z,
          gain: dot.gain,
        );
      }
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      _toast('add source failed: $e');
      return false;
    } finally {
      dot.adding = false;
    }
  }

  /// Stand-in → generated clip: same dot, new engine source. If the
  /// engine is off, the bytes are stashed and the restart re-adds the
  /// file source directly.
  Future<void> _directedUpgrade(
    Object key,
    Uint8List bytes,
    bool looping,
  ) async {
    final dot = key as SourceDot;
    dot.fileBytes = bytes;
    dot.looping = looping;
    _syncSeekTicker(); // isFile just flipped — its row should appear
    if (!_engineOn || dot.id == null) {
      // Pending (or engine off): stash the bytes — _ensurePendingAdds
      // realizes the dot as a file source directly at its cue.
      return;
    }
    try {
      removeSource(id: dot.id!);
      final info = await addFileSource(
        bytes: bytes,
        looping: looping,
        x: dot.pos.dx,
        y: dot.pos.dy,
        z: dot.z,
        gain: dot.gain,
      );
      dot.id = info.id;
      dot.fileDurS = info.durationS;
      dot.fileT0 = DateTime.now();
      debugPrint('[sfx] ${dot.label}: file source live (id ${dot.id}, ${info.durationS.toStringAsFixed(1)}s)');
    } catch (e) {
      debugPrint('[sfx] ${dot.label}: addFileSource failed — $e');
      _toast('file source failed: $e');
    }
  }

  /// Scene clock: authored cues (delay_s) on a shared timeline — the
  /// master seekbar scrubs it, the ticker realizes pending sources at
  /// their cue and wraps the composition at scene length.
  DateTime? _sceneT0;
  Timer? _seekTicker;

  /// Per-source clip status for the "compiling audio" prompt status and
  /// chip spinners — cleared on each scene apply.
  final _clipStatus = <String, SfxStatus>{};
  _PromptEntry? _activePrompt; // entry that produced the live scene

  double get _sceneT {
    final t0 = _sceneT0;
    if (t0 == null) return 0;
    return DateTime.now().difference(t0).inMilliseconds / 1000;
  }

  /// Composition length = latest authored end (delay + clip duration,
  /// estimated until the real decode lands). 0 = no scene on the clock
  /// (manual palette dots only).
  double get _sceneLen => _sources.fold(
        0.0,
        (m, d) => d.estDurS > 0
            ? math.max(m, d.delayS + (d.fileDurS ?? d.estDurS))
            : m,
      );

  void _onSceneStart(DateTime t0) {
    _sceneT0 = t0;
    _clipStatus.clear();
    _scrubbing = false; // a stale drag must not commit onto the new scene
    _scrubT = null;
  }

  void _syncSeekTicker() {
    final active =
        _engineOn && _sources.any((s) => s.isFile || s.needsSource);
    if (active) {
      _seekTicker ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        // No mid-drag work: wraps and pending adds would fight the
        // preview and flood the 64-slot command queue.
        if (!mounted || _scrubbing) return;
        final len = _sceneLen;
        if (len > 0 && _sceneT >= len) {
          _sceneSeek(_sceneT % len); // scene wraps — composition repeats
        }
        _ensurePendingAdds();
        setState(() {});
      });
    } else {
      _seekTicker?.cancel();
      _seekTicker = null;
    }
    if (mounted) setState(() {});
  }

  /// Realize any pending/finished authored dots whose cue has arrived.
  void _ensurePendingAdds() {
    if (!_engineOn) return;
    final t = _sceneT;
    for (final dot in _sources) {
      if (!dot.needsSource || dot.adding || dot.addFailed) continue;
      final local = t - dot.delayS;
      if (local < 0) continue;
      if (dot.finished && dot.id != null) {
        // A finished one-shot only revives inside its play window.
        final dur = dot.fileDurS ?? 0;
        if (dur <= 0 || local >= dur) continue;
        dot.id = null; // engine already dropped it — id was stale
      }
      unawaited(_realizeAt(dot, local));
    }
  }

  Future<void> _realizeAt(SourceDot dot, double local) async {
    final dur = dot.fileDurS;
    if (dot.isFile && !dot.looping && dur != null && local >= dur) {
      // Missed cue: the clip landed (or the engine restarted) after its
      // window fully expired — replay it once rather than stay silent.
      debugPrint('[scene] ${dot.label}: missed cue — replaying');
      local = 0;
    }
    if (!await _realizeDot(dot)) {
      dot.addFailed = true;
      return;
    }
    // fileDurS may only exist now — addFileSource just decoded it.
    final d = dot.fileDurS;
    if (dot.isFile && dot.id != null && d != null && d > 0) {
      final pos = dot.looping ? local % d : local.clamp(0.0, d);
      seekSource(id: dot.id!, posS: pos);
      dot.fileT0 = DateTime.now()
          .subtract(Duration(milliseconds: (pos * 1000).round()));
    } else {
      dot.fileT0 = DateTime.now();
    }
    debugPrint('[scene] ${dot.label}: live at ${local.toStringAsFixed(1)}s');
  }

  /// Two-phase scene scrub: while dragging it's a muted visual preview
  /// (no engine writes — a per-pixel burst of seeks would silently
  /// overflow the 64-slot command queue, which is why scrubbing used to
  /// only reposition the first sources). On release, one atomic commit.
  bool _scrubbing = false;
  double? _scrubT;

  void _scrubStart() {
    _scrubbing = true;
    _director.setMotionPaused(true); // freeze radar/motion while held
    // Mute every live source — the "pause" while previewing. Per-source
    // SetGain silently no-ops on stale ids, so this is safe wholesale.
    for (final dot in _sources) {
      final id = dot.id;
      if (id != null) setSourceGain(id: id, gain: 0);
    }
  }

  void _scrubMove(double v) {
    _scrubT = v;
    // Preview anchor only — chips/time text track the finger. Zero
    // engine calls here; the commit happens on release.
    _sceneT0 = DateTime.now()
        .subtract(Duration(milliseconds: (v * 1000).round()));
    setState(() {});
  }

  void _scrubEnd(double v) {
    if (!_scrubbing) return; // scene changed mid-drag — drop the commit
    _scrubbing = false;
    _scrubT = null;
    _sceneSeek(v); // the one atomic burst: seeks, removes, pending adds
    if (_engineOn) {
      _director.setMotionPaused(false);
      for (final dot in _sources) {
        final id = dot.id;
        if (id != null) setSourceGain(id: id, gain: dot.gain);
      }
    }
    setState(() {});
  }

  /// Master-bar commit: re-anchor the scene clock, motion anchors, and
  /// every authored dot's engine source to the new scene time.
  void _sceneSeek(double t) {
    if (_sceneT0 == null) return;
    _sceneT0 = DateTime.now()
        .subtract(Duration(milliseconds: (t * 1000).round()));
    _director.seekScene(t);
    for (final dot in _sources) {
      if (dot.estDurS <= 0) continue; // manual sources aren't on the score
      dot.dueAt = _sceneT0!.add(
        Duration(milliseconds: (dot.delayS * 1000).round()),
      );
      dot.addFailed = false;
      final local = t - dot.delayS;
      if (local < 0) {
        // Before its cue — go silent: drop the engine source, the dot
        // becomes pending and re-realizes on a forward scrub/tick.
        if (dot.id != null) {
          final id = dot.id!;
          dot.id = null;
          if (_engineOn) {
            unawaited(removeSource(id: id).catchError(
              (e) => debugPrint(
                '[scene] ${dot.label}: remove failed — $e',
              ),
            ));
          }
        }
        continue;
      }
      if (_engineOn && dot.isFile && dot.id != null && !dot.finished) {
        final dur = dot.fileDurS ?? 0;
        if (dur > 0) {
          final pos = dot.looping ? local % dur : local.clamp(0.0, dur);
          seekSource(id: dot.id!, posS: pos);
          dot.fileT0 = DateTime.now()
              .subtract(Duration(milliseconds: (pos * 1000).round()));
        }
      }
    }
    _ensurePendingAdds();
    setState(() {});
  }

  /// Estimated playhead position — local clock, wraps for loops,
  /// clamps for one-shots.
  double _filePos(SourceDot d) {
    final t0 = d.fileT0;
    final dur = d.fileDurS;
    if (t0 == null || dur == null || dur <= 0) return 0;
    final e = DateTime.now().difference(t0).inMilliseconds / 1000;
    return d.looping ? e % dur : e.clamp(0.0, dur);
  }

  void _seekTo(SourceDot d, double pos) {
    if (d.finished) {
      // Engine already dropped the one-shot — route through the revive
      // path (re-add + seek) instead of seeking a dead id.
      d.id = null;
      unawaited(_realizeAt(d, pos));
      return;
    }
    if (_engineOn && d.id != null) seekSource(id: d.id!, posS: pos);
    // Re-anchor the local estimate to the new playhead.
    d.fileT0 = DateTime.now().subtract(
      Duration(milliseconds: (pos * 1000).round()),
    );
    setState(() {});
  }

  /// Master seekbar — one bar for the whole composed scene. Scrubs the
  /// scene clock: every clip's playhead, pending schedule, and motion
  /// anchor follows (delay_i), so "breeze at 2s, plane at 4s" replays
  /// exactly as authored.
  Widget _sceneRow() {
    final len = _sceneLen;
    final t = _scrubT ?? (len > 0 ? _sceneT % len : 0.0);
    final live = _engineOn && len > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 60,
            child: Text(
              'scene',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  value: t.clamp(0.0, len > 0 ? len : 1),
                  max: len > 0 ? len : 1,
                  onChangeStart: live ? (_) => _scrubStart() : null,
                  onChanged: live ? _scrubMove : null,
                  onChangeEnd: live ? _scrubEnd : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 74,
            child: Text(
              '${t.toStringAsFixed(1)} / ${len.toStringAsFixed(1)}s',
              style: const TextStyle(fontSize: 10, color: Color(0xFF9AA4B2)),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _seekRow(SourceDot d) {
    final pos = _filePos(d);
    final dur = d.fileDurS ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              d.label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: dur > 0 ? pos.clamp(0.0, dur) : 0,
                  max: dur > 0 ? dur : 1,
                  onChanged: _engineOn && dur > 0
                      ? (v) => _seekTo(d, v)
                      : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 74,
            child: Text(
              '${pos.toStringAsFixed(1)} / ${dur.toStringAsFixed(1)}s',
              style: const TextStyle(fontSize: 10, color: Color(0xFF9AA4B2)),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  void _sfxStatus(String name, SfxStatus status) {
    _clipStatus[name] = status;
    // No per-source toasts — the logs, the landed file chip, and the
    // seekbars already show progress. Failures still toast.
    if (status == SfxStatus.failed) {
      _toast('$name: generation failed');
    }
    if (mounted) setState(() {});
  }

  void _directedRemove(Object key) {
    final dot = key as SourceDot;
    final id = dot.id;
    if (id != null) removeSource(id: id);
    setState(() => _sources.remove(dot));
    _syncSeekTicker();
  }

  // key is the SourceDot — its engine id is read live, so motion ticks
  // keep working after an engine restart re-assigns ids.
  void _directedSetPos(Object key, Offset pos, double z) {
    final dot = key as SourceDot;
    final id = dot.id;
    if (_engineOn && id != null) {
      try {
        setSourcePosition(id: id, x: pos.dx, y: pos.dy, z: z);
      } catch (e) {
        // Engine may have already dropped the source (one-shot finished
        // between ticks) — keep the radar dot moving regardless.
        debugPrint('[motion] ${dot.label}: setSourcePosition failed — $e');
      }
    }
    dot.pos = pos;
    dot.z = z;
    if (mounted) setState(() {});
  }

  /// A sent prompt + its generated spec — the chip replays it without
  /// another model call. spec stays null while the model is thinking.
  /// Persisted to SharedPreferences; clips live in the SfxClient disk
  /// cache, so a restart + chip tap replays fully offline.
  final _prompts = <_PromptEntry>[];
  static const _historyKey = 'prompt_history_v1';
  static const _historyCap = 20;

  Future<void> _loadPrompts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_historyKey) ?? const [];
      for (final s in raw) {
        final e = _PromptEntry.fromJson(jsonDecode(s));
        if (e != null && e.spec != null) _prompts.add(e);
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[history] load failed, starting empty: $e');
    }
  }

  Future<void> _savePrompts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _historyKey,
      _prompts.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  bool _describing = false;
  DateTime? _describeStarted;
  int _llmChars = 0;
  Timer? _describeTicker;

  Future<void> _describe() async {
    final t = _promptCtl.text.trim();
    if (t.isEmpty || _describing) return;
    final entry = _PromptEntry(t);
    setState(() {
      _describing = true;
      _describeStarted = DateTime.now();
      _llmChars = 0;
      _prompts.add(entry);
      // FIFO cap — drop oldest completed entries.
      while (_prompts.length > _historyCap) {
        _prompts.removeAt(0);
      }
    });
    _describeTicker?.cancel();
    _describeTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    try {
      entry.spec = await _director.describe(
        t,
        onProgress: (n) => _llmChars = n,
      );
      if (entry.spec == null) {
        _prompts.remove(entry);
      } else {
        entry.specSeconds =
            DateTime.now().difference(entry.startedAt).inMilliseconds / 1000;
        _activePrompt = entry;
        _promptCtl.clear();
        unawaited(_savePrompts());
      }
    } finally {
      _describeTicker?.cancel();
      _describeTicker = null;
      if (mounted) setState(() => _describing = false);
    }
  }

  Future<void> _replay(_PromptEntry e) async {
    final spec = e.spec;
    if (spec == null) return;
    _activePrompt = e;
    await _director.apply(spec);
  }

  // Future<void> _demoScene() async {
  //   await _addSource(SourceKindWire.bee);
  //   await _addSource(SourceKindWire.rain);
  //   await _addSource(SourceKindWire.pad);
  // }

  void _clearAll() {
    for (final s in _sources) {
      final id = s.id;
      if (id != null) removeSource(id: id);
    }
    _sources.clear();
    _director.reset();
    _sceneT0 = null;
    _scrubbing = false;
    _scrubT = null;
    _syncSeekTicker();
    setState(() {});
  }

  void _removeSource(SourceDot s) {
    final id = s.id;
    if (id != null) removeSource(id: id);
    setState(() => _sources.remove(s));
    _syncSeekTicker();
  }

  // void _recenter() {
  //   recenter();
  //   _yawAtRecenter = _displayYawRaw();
  //   _virtualYaw = 0;
  // }

  double _displayYawRaw() {
    final q = _pose.lastQuat.value;
    if (q == null) return _virtualYaw;
    // yaw = atan2(2(wz+xy), 1-2(y^2+z^2))
    return math.atan2(
      2 * (q[0] * q[3] + q[1] * q[2]),
      1 - 2 * (q[2] * q[2] + q[3] * q[3]),
    );
  }

  double get _displayYaw => _displayYawRaw() - _yawAtRecenter;

  String? _lastToast;
  DateTime _lastToastAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _toast(String msg) {
    // One prompt can trigger the same toast per source (e.g. "start the
    // engine first" × N sources) — dedup identical messages in a window.
    final now = DateTime.now();
    if (msg == _lastToast &&
        now.difference(_lastToastAt) < const Duration(seconds: 3)) {
      return;
    }
    _lastToast = msg;
    _lastToastAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  static String _promptLabel(String p) =>
      p.length > 30 ? '${p.substring(0, 29)}…' : p;

  // ----- layout -----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Spatial Audio Sandbox',
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          // IconButton(
          //   tooltip: 'recenter head',
          //   onPressed: _recenter,
          //   icon: const Icon(Icons.center_focus_strong),
          // ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: _toggleEngine,
              icon: Icon(_engineOn ? Icons.stop : Icons.play_arrow, size: 18),
              label: Text(_engineOn ? 'stop' : 'start'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // _infoBar(),
          Expanded(child: _radar()),
          _legend(),
          _controls(),
        ],
      ),
    );
  }

  /// One prominent card per linked beacon — identity + live telemetry +
  /// unlink, kept out of the scene/devices chip groups.
  Widget _beaconCard(int id, _BeaconState b) {
    final s = b.sample;
    final stale = s?.stale ?? true;
    final accent = stale ? const Color(0xFF5A6470) : const Color(0xFF80DEEA);
    final status = s == null
        ? 'waiting for telemetry'
        : (stale ? 'stale' : 'linked');
    final detail = s == null
        ? status
        : '$status — ${s.mode} · ${s.distanceM.toStringAsFixed(1)} m · '
              '${s.age.inMilliseconds} ms ago';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2230),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.smartphone, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.name ?? 'beacon $id',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF9AA4B2),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _removeBeacon(id),
            child: const Text('unlink'),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String t) => SizedBox(
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        t,
        style: const TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
      ),
    ),
  );

  /// Visual language for the radar: solid dot = authored source, ringed
  /// dot = real device tracked over UDP.
  Widget _legend() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
    child: Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Color(0xFF9AA4B2),
            shape: BoxShape.circle,
          ),
        ),
        const Text(
          ' scene source',
          style: TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
        ),
        const SizedBox(width: 14),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF80DEEA), width: 1.5),
          ),
        ),
        const Text(
          ' device',
          style: TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
        ),
      ],
    ),
  );

  // Widget _infoBar() {
  //   final i = _info;
  //   final sensor = _pose.isLive
  //       ? 'sensor: live'
  //       : 'sensor: none (virtual head)';
  //   final linked = _beacons.isEmpty
  //       ? (_announced.isEmpty ? 'no beacons' : 'beacon seen')
  //       : 'beacons: ${_beacons.length}';
  //   final net = switch (_net.current.state) {
  //     NetState.offline => 'offline',
  //     NetState.hotspotHost => 'hotspot',
  //     NetState.wifi =>
  //       (_peerApHost || _beacons.values.any((b) => b.apHost))
  //           ? 'hotspot'
  //           : 'wifi',
  //   };
  //   final rx = 'rx ${_link.rxCount}';
  //   const base = TextStyle(
  //     fontSize: 11,
  //     fontFamily: 'monospace',
  //     color: Color(0xFF9AA4B2),
  //   );
  //   final pre = i == null
  //       ? 'engine off — $sensor — $linked — '
  //       : '${i.backend}/${i.api}  ${i.sampleRate}Hz ${i.channels}ch  '
  //             'burst ${i.framesPerBurst}  buf ${i.bufferSizeFrames}/${i.bufferCapacityFrames}  '
  //             '${i.performanceMode}/${i.sharingMode}  '
  //             'latency ${i.latencyMs == null ? "n/a" : "${i.latencyMs!.toStringAsFixed(1)}ms"} — $sensor — $linked — ';
  //   return Container(
  //     width: double.infinity,
  //     color: const Color(0xFF12161F),
  //     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  //     child: Text.rich(
  //       TextSpan(
  //         style: base,
  //         children: [
  //           TextSpan(text: pre),
  //           TextSpan(
  //             text: net,
  //             style: TextStyle(
  //               color: _net.current.state == NetState.offline
  //                   ? const Color(0xFFE57373)
  //                   : const Color(0xFF9AA4B2),
  //             ),
  //           ),
  //           TextSpan(text: ' — $rx — ip $_localIp'),
  //         ],
  //       ),
  //     ),
  //   );
  // }

  Widget _radar() {
    return LayoutBuilder(
      builder: (context, c) {
        final size = math.min(c.maxWidth, c.maxHeight);
        final scale = (size / 2 - 24) / _rangeM;
        return GestureDetector(
          onPanStart: (d) => _dragTarget = _hitTest(
            d.localPosition,
            c.biggest.center(Offset.zero),
            scale,
          ),
          onPanUpdate: (d) =>
              _onRadarDrag(d, c.biggest.center(Offset.zero), scale),
          onPanEnd: (_) => _dragTarget = null,
          onLongPressStart: (d) =>
              _onRadarLongPress(d, c.biggest.center(Offset.zero), scale),
          child: CustomPaint(
            painter: _RadarPainter(
              sources: _sources,
              beacons: _beacons,
              headYaw: _displayYaw,
              rangeM: _rangeM,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  SourceDot? _hitTest(Offset local, Offset center, double scale) {
    for (final s in _sources) {
      var v = Offset(-s.pos.dy * scale, -s.pos.dx * scale);
      if (v.distance > _rangeM * scale) {
        v *= _rangeM * scale / v.distance; // far dots ride the edge ring
      }
      if ((local - (center + v)).distance < 26) return s;
    }
    return null;
  }

  SourceDot? _dragTarget;

  void _onRadarDrag(DragUpdateDetails d, Offset center, double scale) {
    final s = _dragTarget;
    if (s == null) return;
    final local = d.localPosition;
    final scene = Offset(
      -(local.dy - center.dy) / scale,
      -(local.dx - center.dx) / scale,
    );
    setState(() => s.pos = scene);
    final id = s.id;
    if (id != null) {
      setSourcePosition(id: id, x: scene.dx, y: scene.dy, z: s.z);
    }
  }

  void _onRadarLongPress(LongPressStartDetails d, Offset center, double scale) {
    final s = _hitTest(d.localPosition, center, scale);
    if (s != null) {
      _removeSource(s);
      return;
    }
    final bid = _hitTestBeacon(d.localPosition, center, scale);
    if (bid != null) _removeBeacon(bid);
  }

  int? _hitTestBeacon(Offset local, Offset center, double scale) {
    for (final e in _beacons.entries) {
      final s = e.value.sample;
      if (s == null) continue;
      final v = Offset(-s.pos.dy * scale, -s.pos.dx * scale);
      final clamped = v.distance > _rangeM * scale
          ? v * (_rangeM * scale / v.distance)
          : v;
      if ((local - (center + clamped)).distance < 26) return e.key;
    }
    return null;
  }

  void _removeBeacon(int id) {
    final b = _beacons.remove(id);
    if (b?.sourceId != null) removeSource(id: b!.sourceId!);
    _delayNs.remove(id);
    setState(() {});
  }

  Widget _controls() {
    return Container(
      color: const Color(0xFF12161F),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in _beacons.entries) _beaconCard(e.key, e.value),
          _sectionLabel('scene director'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _promptCtl,
                  enabled: !_describing,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText:
                        'e.g. "rain everywhere, a bee circling my head"',
                    hintStyle: TextStyle(fontSize: 12),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => _describe(),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: _describing ? null : _describe,
                icon: _describing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 20),
                tooltip: 'direct scene',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (_describing)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 2),
              child: Text(
                'Gemma… ${DateTime.now().difference(_describeStarted!).inSeconds}s'
                '${_llmChars > 0 ? ' · receiving spec (${(_llmChars / 1000).toStringAsFixed(1)}k chars)' : ''}',
                style: const TextStyle(fontSize: 10, color: Color(0xFF9AA4B2)),
              ),
            ),
          Wrap(
            spacing: 6,
            children: [
              for (final e in presetPrompts.entries)
                ActionChip(
                  label: Text(
                    e.key,
                    style: const TextStyle(fontSize: 11),
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _director.applyJson(e.value),
                ),
            ],
          ),
          if (_prompts.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in _prompts.reversed)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        e.spec == null
                            ? Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                label: Text(
                                  _promptLabel(e.prompt),
                                  style: const TextStyle(fontSize: 11),
                                ),
                              )
                            : ActionChip(
                                visualDensity: VisualDensity.compact,
                                tooltip: e.prompt,
                                avatar: const Icon(
                                  Icons.auto_awesome,
                                  size: 14,
                                ),
                                label: Text(
                                  _promptLabel(e.prompt),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onPressed: () => _replay(e),
                              ),
                        const SizedBox(width: 6),
                        Text(
                          e.spec == null
                              ? 'Gemma… ${DateTime.now().difference(e.startedAt).inSeconds}s'
                              : e == _activePrompt &&
                                      _clipStatus.values.any(
                                        (s) => s == SfxStatus.generating,
                                      )
                                  ? 'compiling audio '
                                      '${_clipStatus.values.where((s) => s != SfxStatus.generating).length}'
                                      '/${_clipStatus.length}…'
                                  : e.specSeconds != null
                                      ? 'spec in ${e.specSeconds!.toStringAsFixed(0)}s'
                                          '${e == _activePrompt && _clipStatus.isNotEmpty ? ' · audio ready' : ''}'
                                      : 'saved',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF9AA4B2),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (_sceneLen > 0) _sceneRow(),
          // Per-clip bars only for sources outside the authored score —
          // scene sources are scrubbed by the master bar above.
          for (final s
              in _sources.where((d) => d.isFile && d.estDurS <= 0))
            _seekRow(s),
          _sectionLabel('Scenes:'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final k in SourceKindWire.values.where(
                (k) => k != SourceKindWire.click,
              ))
                _KindChip(
                  kind: k,
                  color: _kindColors[k]!,
                  onTap: () => _addSource(k),
                ),
              // TextButton(onPressed: _demoScene, child: const Text('demo scene')),
            ],
          ),
          const SizedBox(height: 6),
          if (_sources.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                TextButton(
                  onPressed: _clearAll,
                  child: const Text('Clear All'),
                ),
                for (final s in _sources)
                  InputChip(
                    label: Text(
                      s.pending && s.dueAt != null
                          ? '${s.label} · in ${math.max(0, (s.delayS - _sceneT).ceil())}s'
                          : s.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: s.pending
                            ? (_kindColors[s.kind] ?? Colors.white)
                                .withValues(alpha: 0.45)
                            : _kindColors[s.kind] ?? Colors.white,
                      ),
                    ),
                    avatar: switch (_clipStatus[s.label]) {
                      SfxStatus.failed => const Icon(
                          Icons.error_outline,
                          size: 14,
                          color: Color(0xFFE57373),
                        ),
                      SfxStatus.generating => const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      _ => s.isFile
                          ? const Icon(Icons.audio_file, size: 14)
                          : null,
                    },
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () => _removeSource(s),
                    visualDensity: VisualDensity.compact,
                  ),
                // TextButton(onPressed: _demoScene, child: const Text('demo scene')),
              ],
            ),
          if (_announced.isNotEmpty) ...[
            _sectionLabel('devices'),
            Wrap(
              spacing: 6,
              children: [
                for (final a in _announced.values)
                  ActionChip(
                    label: Text(
                      'link ${a.name ?? "beacon ${a.id}"}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF80DEEA),
                      ),
                    ),
                    onPressed: () => _linkBeacon(a.id),
                  ),
              ],
            ),
          ],
          if (_beacons.isNotEmpty)
            Row(
              children: [
                const Text(
                  'beacon dist',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
                ),
                if (_beacons.values.first.tracker.acousticM == null) ...[
                  Expanded(
                    child: Slider(
                      value: _beacons.values.first.tracker.distanceM,
                      min: 0.3,
                      max: 8,
                      label:
                          '${_beacons.values.first.tracker.distanceM.toStringAsFixed(1)} m',
                      onChanged: (v) => setState(
                        () => _beacons.values.first.tracker.distanceM = v,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_beacons.values.first.tracker.distanceM.toStringAsFixed(1)}m',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9AA4B2),
                      ),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: Text(
                      'acoustic ${_beacons.values.first.tracker.acousticM!.toStringAsFixed(1)}m — live',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF80DEEA),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => _beacons.values.first.tracker.clearAcoustic(),
                    ),
                    child: const Text('manual'),
                  ),
                ],
              ],
            ),
          // Row(
          //   children: [
          //     const Text('predict', style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
          //     Expanded(
          //       child: Slider(
          //         value: _predictMs,
          //         max: 300,
          //         divisions: 30,
          //         label: '${_predictMs.round()} ms',
          //         onChanged: (v) {
          //           setState(() => _predictMs = v);
          //           setPredictMs(ms: v);
          //         },
          //       ),
          //     ),
          //     SizedBox(
          //       width: 56,
          //       child: Text('${_predictMs.round()}ms', style: const TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
          //     ),
          //   ],
          // ),
          if (!_pose.isLive)
            Row(
              children: [
                const Text(
                  'virtual head',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
                ),
                Expanded(
                  child: Slider(
                    value: _virtualYaw,
                    min: -math.pi,
                    max: math.pi,
                    label: '${(_virtualYaw * 180 / math.pi).round()}°',
                    onChanged: (v) {
                      setState(() => _virtualYaw = v);
                      _pose.useVirtualHead(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '${(_virtualYaw * 180 / math.pi).round()}°',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9AA4B2),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.kind,
    required this.color,
    required this.onTap,
  });
  final SourceKindWire kind;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(kind.name, style: TextStyle(fontSize: 12, color: color)),
      onPressed: onTap,
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.5)),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.sources,
    required this.beacons,
    required this.headYaw,
    required this.rangeM,
  });
  final List<SourceDot> sources;
  final Map<int, _BeaconState> beacons;
  final double headYaw; // radians; >0 = turned left
  final double rangeM;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = (math.min(size.width, size.height) / 2 - 24) / rangeM;

    final ringPaint = Paint()
      ..color = const Color(0xFF26303C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = const Color(0xFF1B222C)
      ..strokeWidth = 1;

    for (final r in [1.0, 2.0, 3.0, 4.0, 5.0]) {
      canvas.drawCircle(center, r * scale, ringPaint);
    }
    canvas.drawLine(
      center + Offset(-rangeM * scale, 0),
      center + Offset(rangeM * scale, 0),
      axisPaint,
    );
    canvas.drawLine(
      center + Offset(0, -rangeM * scale),
      center + Offset(0, rangeM * scale),
      axisPaint,
    );

    // Heading wedge: headYaw>0 (turned left) => wedge sweeps left on screen.
    final headPaint = Paint()..color = const Color(0xFF4CAF50);
    final nose =
        center + Offset(-math.sin(headYaw) * 20, -math.cos(headYaw) * 20);
    final leftEar =
        center +
        Offset(-math.sin(headYaw + 2.5) * 10, -math.cos(headYaw + 2.5) * 10);
    final rightEar =
        center +
        Offset(-math.sin(headYaw - 2.5) * 10, -math.cos(headYaw - 2.5) * 10);
    canvas.drawPath(
      Path()..addPolygon([nose, leftEar, rightEar], true),
      headPaint,
    );
    canvas.drawCircle(center, 5, Paint()..color = const Color(0xFF4CAF50));

    // Sources. Dots beyond the range ring clamp to the edge (like
    // beacons) instead of vanishing off-canvas.
    for (final s in sources) {
      var v = Offset(-s.pos.dy * scale, -s.pos.dx * scale);
      if (v.distance > rangeM * scale) {
        v *= rangeM * scale / v.distance;
      }
      final p = center + v;
      final color = _kindColors[s.kind] ?? Colors.white;
      // Pending sources (authored cue hasn't arrived) paint dimmed —
      // the composed plan is visible before it sounds.
      final a = s.pending ? 0.35 : 1.0;
      canvas.drawCircle(
        p,
        10,
        Paint()..color = color.withValues(alpha: 0.25 * a),
      );
      canvas.drawCircle(p, 6, Paint()..color = color.withValues(alpha: a));
      final tp = TextPainter(
        text: TextSpan(
          text: s.label,
          style: TextStyle(fontSize: 9, color: color.withValues(alpha: a)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p + const Offset(-14, 10));
    }

    // Beacons: ringed dot + telemetry label, gray when stale. Dots beyond
    // the radar range ride the edge ring instead of vanishing off-canvas.
    for (final b in beacons.values) {
      final s = b.sample;
      if (s == null) continue;
      final stale = s.stale;
      var v = Offset(-s.pos.dy * scale, -s.pos.dx * scale);
      if (v.distance > rangeM * scale) {
        v *= rangeM * scale / v.distance;
      }
      final p = center + v;
      final color = stale
          ? const Color(0xFF5A6470)
          : (_kindColors[b.kind] ?? const Color(0xFF80DEEA));
      canvas.drawCircle(
        p,
        13,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(p, 6, Paint()..color = color);
      final label =
          '${b.name ?? b.kind?.name ?? "beacon"} ${s.mode} ${s.distanceM.toStringAsFixed(1)}m';
      final btp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: 9, color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      btp.paint(canvas, p + const Offset(-18, 14));
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}
