import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spatial_audio_sandbox/src/director/demo_pack.dart';
import 'package:spatial_audio_sandbox/src/director/llm_client.dart';
import 'package:spatial_audio_sandbox/src/director/scene_director.dart';
import 'package:spatial_audio_sandbox/src/director/sfx_client.dart';
import 'package:spatial_audio_sandbox/src/key_constants.dart';
import 'package:spatial_audio_sandbox/src/link/acoustic_bridge.dart';
import 'package:spatial_audio_sandbox/src/listener/beacon_tracker.dart';
import 'package:spatial_audio_sandbox/src/listener/calibration_sheet.dart';
import 'package:spatial_audio_sandbox/src/link/link.dart';
import 'package:spatial_audio_sandbox/src/link/net_state.dart';
import 'package:spatial_audio_sandbox/src/listener/levels.dart';
import 'package:spatial_audio_sandbox/src/listener/pipeline_strip.dart';
import 'package:spatial_audio_sandbox/src/listener/pose_channel.dart';
import 'package:spatial_audio_sandbox/src/listener/scene_score.dart';
import 'package:spatial_audio_sandbox/src/listener/source_style.dart';
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
    this.endS,
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

  /// Scene-time when the source stops sounding ("the fire goes out").
  /// The ticker fades+removes the engine source; scrubbing back below
  /// it revives the source. Null = never ends.
  double? endS;
  bool ended = false; // sceneT is past endS — paints dimmed on radar
  bool ending = false; // fade-out in flight — re-entry guard

  DateTime? dueAt; // sceneT0 + delayS — set when the dot is pending
  bool adding = false; // async engine-add in flight — tick re-entry guard
  bool addFailed = false; // engine add threw — stops tick retries until
  // a scene seek or engine restart gives it a fresh attempt

  /// Recent plan positions for the comet trail — pushed by
  /// _directedSetPos / radar drags; the painter draws it faded.
  final List<Offset> trail = [];
  void pushTrail() {
    trail.add(pos);
    if (trail.length > 48) trail.removeAt(0);
  }
  void clearTrail() => trail.clear();

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
  _PromptEntry(this.prompt, {this.recorded = false});
  final String prompt;

  /// Bundled demo-pack entry — a recorded Gemma run. Shown labeled;
  /// never persisted (it's already in the bundle).
  final bool recorded;
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
    final e = _PromptEntry(prompt, recorded: raw['recorded'] == true);
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
class BeaconState {
  BeaconState({required this.tracker});
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
  final _beacons = <int, BeaconState>{};
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
  // Spatial tuning — must match the Rust mixer defaults.
  double _width = 1.3; // L/R separation exaggeration
  final double _wet = 0.08; // reverb send
  final double _ildDb = 10.0; // extra far-ear cut span at full lateral

  void _sendSpatial() {
    if (_engineOn) {
      setSpatialParams(width: _width, wet: _wet, ildDb: _ildDb);
    }
  }
  int _nextPaletteIdx = 0;
  Timer? _statsTimer;
  Timer? _levelsTimer;
  final _promptCtl = TextEditingController();
  late final SceneDirector _director;

  /// Live stereo + per-source loudness polled from the mixer (~30 Hz)
  /// — drives the ear meters, ILD readout, and reactive halos.
  final _levels = LevelsModel();

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
    _levelsTimer?.cancel();
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
    _radarTick.dispose();
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
      () => BeaconState(tracker: tracker),
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
      await _stopEngine(clearScene: true);
    } else {
      await _startEngine();
    }
  }

  /// [clearScene]: the UI stop button tears the scene down with the
  /// engine. The network-offline path keeps sources — they get
  /// re-added on reconnect.
  Future<void> _stopEngine({bool clearScene = false}) async {
    _director.setMotionPaused(true); // freeze directed dots on the radar
    _scrubbing = false; // drop any in-flight scrub commit
    _scrubT = null;
    _pausedT = null;
    _levelsTimer?.cancel();
    _levelsTimer = null;
    _levels.decay(); // meters settle to silence, no frozen bars
    _radarTick.value++;
    if (clearScene) _clearAll(); // remove pushes flush while engine lives
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

  /// Latch the current device orientation as "facing forward" — engine
  /// pose AND radar heading, so they can never disagree.
  void _applyRecenter() {
    recenter();
    _yawAtRecenter = _displayYawRaw();
    _virtualYaw = 0;
  }

  Future<void> _startEngine() async {
    try {
      final info = await engineStart();
      _applyRecenter(); // engine start = "forward is where I face now"
      // A fresh Mixer forgets tuning — re-send user prefs.
      setSpatialParams(width: _width, wet: _wet, ildDb: _ildDb);
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
      // ~30 Hz level poll: reads the mixer's atomics (never the engine
      // mutex) and repaints just the radar.
      _levelsTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
        final w = getLevels();
        _levels.update(w.left, w.right, w.sourceIds, w.sourceLevels);
        _radarTick.value++;
      });
      _syncSeekTicker(); // file sources re-added — playheads ticking again
    } catch (e) {
      _toast('engine start failed: $e');
    }
  }

  Future<void> _createBeaconSource(BeaconState b) async {
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
      endS: spec?.endS,
    );
    setState(() => _sources.add(dot));
    // Let the radar paint the dot before its sound can start — the
    // user watches sources appear, then hears them.
    await _waitFrame();
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

  /// One rendered frame — used to sequence "dot on radar, then audio"
  /// so a source's sound never precedes its marker.
  Future<void> _waitFrame() {
    final c = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => c.complete());
    return c.future;
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
    // Warm the engine's decode cache now — when the cue fires (or the
    // stand-in upgrade happens below), addFileSource hits the cache and
    // skips the mp3 decode entirely.
    unawaited(
      prepareFileSource(bytes: bytes).catchError(
        (Object e) => debugPrint('[sfx] ${dot.label}: prepare failed — $e'),
      ),
    );
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

  /// Radar repaint signal — bumped by motion ticks instead of setState
  /// so position updates repaint the canvas without rebuilding the page.
  final _radarTick = ValueNotifier<int>(0);

  /// Per-source clip status for the "compiling audio" prompt status and
  /// chip spinners — cleared on each scene apply.
  final _clipStatus = <String, SfxStatus>{};
  _PromptEntry? _activePrompt; // entry that produced the live scene

  /// Non-null = the scene is paused at this score position. Freezing
  /// the clock stops cues, endings, and the wrap check for free.
  double? _pausedT;
  bool _repeat = true;
  _PromptEntry? _selectedPrompt;

  double get _sceneT {
    final paused = _pausedT;
    if (paused != null) return paused;
    final t0 = _sceneT0;
    if (t0 == null) return 0;
    return DateTime.now().difference(t0).inMilliseconds / 1000;
  }

  /// Composition length = latest authored end (delay + clip duration,
  /// estimated until the real decode lands), or an explicit end_s —
  /// "the fire goes out at 12s" extends the scene to 12s even when the
  /// fire's clip is shorter. 0 = no scene on the clock.
  double get _sceneLen => _sources.fold(
        0.0,
        (m, d) => d.estDurS > 0
            ? math.max(
                m,
                math.max(
                  d.delayS + (d.fileDurS ?? d.estDurS),
                  d.endS ?? 0,
                ),
              )
            : m,
      );

  void _onSceneStart(DateTime t0) {
    _sceneT0 = t0;
    _clipStatus.clear();
    _scrubbing = false; // a stale drag must not commit onto the new scene
    _scrubT = null;
    _pausedT = null; // a fresh scene is never born paused
    // A new scene assumes you're facing the way you want "front" to be.
    _applyRecenter();
  }

  void _syncSeekTicker() {
    // Ticks whenever a scene is on the clock — not just while sources
    // are pending/failed. Otherwise the end-of-scene wrap check dies
    // the moment all sources go live and repeat/off never fires.
    final active = _engineOn && _sceneLen > 0;
    if (active) {
      _seekTicker ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        // No mid-drag or paused work: wraps and pending adds would
        // fight the preview and flood the 64-slot command queue.
        if (!mounted || _scrubbing || _pausedT != null) return;
        final len = _sceneLen;
        if (len > 0 && _sceneT > len) {
          if (_repeat) {
            _sceneSeek(_sceneT % len); // scene wraps — composition repeats
          } else {
            // Repeat off: park the playhead at the end and pause —
            // gains ramp to 0, motion freezes. Resume replays from 0.
            _sceneT0 = DateTime.now()
                .subtract(Duration(milliseconds: (len * 1000).round()));
            _pauseScene();
          }
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

  /// Scene-time sync: end sources past their end_s (fade → remove),
  /// then realize any pending/finished dots whose cue has arrived.
  void _ensurePendingAdds() {
    if (!_engineOn) return;
    final t = _sceneT;
    for (final dot in _sources) {
      final pastEnd = dot.endS != null && t >= dot.endS!;
      dot.ended = pastEnd; // visual flag follows the score
      if (pastEnd) {
        _endDot(dot);
        continue;
      }
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

  /// Fade out a source whose end_s passed, then remove the engine
  /// source once the smoothed gain has rung down. A scrub back below
  /// end_s during the fade cancels the removal.
  void _endDot(SourceDot dot) {
    final id = dot.id;
    if (id == null || dot.ending) return;
    dot.ending = true;
    setSourceGain(id: id, gain: 0);
    debugPrint('[scene] ${dot.label}: ending at ${dot.endS}s');
    unawaited(Future.delayed(const Duration(milliseconds: 400), () {
      dot.ending = false;
      // Still ended + same source? Remove it. A mid-fade scrub-back
      // leaves dot.ended false or a fresh id — either way this is stale.
      if (dot.ended && dot.id == id) {
        if (_engineOn) removeSource(id: id);
        dot.id = null;
      }
    }));
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

  /// Scene pause — same mute/freeze shape as the scrub drag: live
  /// sources gain→0 (the Rust ramp smooths it), motion freezes, and
  /// _sceneT returns the frozen position so cues/endings can't fire.
  void _pauseScene() {
    if (_pausedT != null) return;
    _scrubbing = false; // a scrub-in-flight must not commit over a pause
    _scrubT = null;
    _pausedT = _sceneT;
    for (final dot in _sources) {
      final id = dot.id;
      if (id != null) setSourceGain(id: id, gain: 0);
    }
    _director.setMotionPaused(true);
    setState(() {});
  }

  void _resumeScene() {
    final t = _pausedT;
    if (t == null) return;
    // Resuming a scene paused at/after its end replays from the top —
    // _sceneSeek(0) revives ended dots and re-dates every cue.
    _pausedT = null;
    if (t >= _sceneLen && _sceneLen > 0) {
      _sceneSeek(0);
    } else {
      _sceneT0 = DateTime.now()
          .subtract(Duration(milliseconds: (t * 1000).round()));
      if (_engineOn) {
        _director.seekScene(t); // motion anchors follow the score, not
        // wall time — without this a paused orbit would jump ahead.
      }
    }
    if (_engineOn) {
      _director.setMotionPaused(false);
      for (final dot in _sources) {
        final id = dot.id;
        if (id != null && !dot.ended) {
          setSourceGain(id: id, gain: dot.gain);
        }
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
    if (_pausedT != null) _pausedT = t; // scrubbing while paused stays paused
    _director.seekScene(t);
    for (final dot in _sources) {
      if (dot.estDurS <= 0) continue; // manual sources aren't on the score
      dot.dueAt = _sceneT0!.add(
        Duration(milliseconds: (dot.delayS * 1000).round()),
      );
      dot.addFailed = false;
      final local = t - dot.delayS;
      // Past its authored end ("the fire goes out") — same silence path
      // as a source before its cue; scrubbing back revives it.
      final pastEnd = dot.endS != null && t >= dot.endS!;
      dot.ended = pastEnd;
      if (local < 0 || pastEnd) {
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
      if (_engineOn && dot.id != null && !dot.finished) {
        // Restore gain — cancels a mid-fade end and the scrub preview
        // mute in one idempotent write.
        setSourceGain(id: dot.id!, gain: dot.gain);
        if (dot.isFile) {
          final dur = dot.fileDurS ?? 0;
          if (dur > 0) {
            final pos = dot.looping ? local % dur : local.clamp(0.0, dur);
            seekSource(id: dot.id!, posS: pos);
            dot.fileT0 = DateTime.now()
                .subtract(Duration(milliseconds: (pos * 1000).round()));
          }
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

  /// Scene score — one lane per authored source on the master clock,
  /// doubling as the scrubber. Cues, loops, and authored end events are
  /// drawn so the composition is visible without hearing it.
  Widget _scoreSection() {
    final len = _sceneLen;
    final t = _scrubT ?? (len > 0 ? _sceneT % len : 0.0);
    final live = _engineOn && len > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        children: [
          SceneScore(
            lanes: _scoreLanes(),
            lengthS: len,
            positionS: t,
            onScrubStart: live ? _scrubStart : null,
            onScrubUpdate: live ? _scrubMove : null,
            onScrubEnd: live ? _scrubEnd : null,
          ),
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _repeat = !_repeat),
                icon: Icon(
                  _repeat ? Icons.repeat_on : Icons.repeat,
                  size: 16,
                ),
                color: _repeat
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFF9AA4B2),
                tooltip: _repeat ? 'scene repeats' : 'scene plays once',
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              Text(
                '${t.toStringAsFixed(1)} / ${len.toStringAsFixed(1)}s',
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF9AA4B2),
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<ScoreLane> _scoreLanes() => [
        for (final s in _sources.where((d) => d.estDurS > 0))
          () {
            final style = styleFor(s.label, s.kind);
            return ScoreLane(
              name: s.label,
              icon: style.icon,
              color: style.color,
              startS: s.delayS,
              endS: s.endS ??
                  (s.looping
                      ? _sceneLen
                      : math.min(s.delayS + s.estDurS, _sceneLen)),
              loop: s.looping,
              pending: s.pending,
              ended: s.ended,
              isFile: s.isFile,
              endsWithEvent: s.endS != null,
            );
          }(),
      ];

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
    // Sub-centimeter jitter isn't worth a cross-isolate call or a paint.
    if ((pos - dot.pos).distance < 0.01 && (z - dot.z).abs() < 0.01) {
      return;
    }
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
    dot.pushTrail();
    dot.pos = pos;
    dot.z = z;
    // Repaint only the radar — NOT the whole page. setState here ran
    // per-source per-motion-tick (~90 rebuilds/s of the full control
    // panel); a listenable repaint drives just the CustomPaint.
    _radarTick.value++;
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
      // Bundled recorded runs always lead — instant keyless demos for
      // anyone who installs the APK. Not persisted (they're in the
      // bundle), immune to the history cap.
      for (final d in demoScenes) {
        final e = _PromptEntry.fromJson(d);
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
      _prompts
          .where((e) => !e.recorded)
          .map((e) => jsonEncode(e.toJson()))
          .toList(),
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
      _selectedPrompt = entry; // the submitted prompt is selected
      // FIFO cap — drop oldest user entries; bundled demo scenes don't
      // count against the cap.
      while (_prompts.where((e) => !e.recorded).length > _historyCap) {
        _prompts.removeAt(_prompts.indexWhere((e) => !e.recorded));
      }
    });
    // Engine spins up in parallel with Gemma's ~40 s think — the scene
    // lands ready to play instead of failing adds onto a dead engine.
    if (!_engineOn) unawaited(_startEngine());
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

  /// Play/pause for the selected history entry: pause an actively
  /// playing scene, resume a paused one, or (re)apply the spec —
  /// starting the engine itself when needed.
  Future<void> _playEntry(_PromptEntry e) async {
    final playing = _engineOn &&
        _pausedT == null &&
        _activePrompt == e &&
        _sources.isNotEmpty;
    if (playing) {
      _pauseScene();
      return;
    }
    if (_pausedT != null && _activePrompt == e) {
      _resumeScene();
      return;
    }
    final spec = e.spec;
    if (spec == null) return;
    _activePrompt = e;
    if (!_engineOn) await _startEngine();
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
    _pausedT = null;
    _scrubbing = false;
    _scrubT = null;
    _syncSeekTicker();
    setState(() {});
  }

  /// Sound check lifecycle: the scene clock + motion freeze for the
  /// duration of the sheet (engine-side, the diagnostic session also
  /// gates normal output to silence). A scene that was paused stays
  /// paused; a playing one resumes at the same score position — the
  /// DSP freeze preserved every playhead, so no reseek is needed.
  Future<void> _openSoundCheck() async {
    final wasPaused = _pausedT != null;
    if (!wasPaused) _pauseScene();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => CalibrationSheet(
        audio: EngineTestAudio(),
        engineOn: _engineOn,
        onStartEngine: () async {
          await _startEngine();
          return _engineOn;
        },
      ),
    );
    // Only resume what WE paused — a scene paused before the sheet
    // stays paused.
    if (!wasPaused && _pausedT != null && mounted) _resumeScene();
  }

  void _removeSource(SourceDot s) {
    final id = s.id;
    if (id != null) removeSource(id: id);
    setState(() => _sources.remove(s));
    _syncSeekTicker();
  }

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

  static String _promptLabel(String p) => p;
      // p.length > 30 ? '${p.substring(0, 29)}…' : p;

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
          IconButton(
            tooltip: 'lab — dev controls',
            key: KeyConstants.labButton,
            onPressed: _openLab,
            icon: const Icon(Icons.science_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'sound check (L/R test)',
            key: KeyConstants.soundCheckButton,
            onPressed: _openSoundCheck,
            icon: const Icon(Icons.hearing, size: 20),
          ),
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
          // Headphone hint — the demo reads wrong on speakers; also
          // explains the app to anyone watching a screen recording.
          Container(
            width: double.infinity,
            color: const Color(0xFF16202B),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.headphones, size: 13, color: Color(0xFF64D8CB)),
                SizedBox(width: 6),
                Text(
                  'Wear headphones — sounds play around you in 3D',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
                ),
              ],
            ),
          ),
          // _infoBar(),
          Expanded(child: _radar()),
          _legend(),
          // Controls shrink-wrap but never crowd out the radar — a long
          // scene's score + chips scroll instead of overflowing.
          Flexible(
            child: SingleChildScrollView(child: _controls()),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 3),
            child: Center(
              child: Text(
                'Built with ❤️\nby Musaddiq625',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: Color(0xFF5A6470),
                  height: 1.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One prominent card per linked beacon — identity + live telemetry +
  /// unlink, kept out of the scene/devices chip groups.
  Widget _beaconCard(int id, BeaconState b) {
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

  /// Visual key for the radar language — readable without sound.
  Widget _legend() => const Padding(
    padding: EdgeInsets.fromLTRB(12, 0, 12, 2),
    child: Row(
      children: [
        Text(
          'hollow = behind  ·  tail = motion  ·  stalk = height',
          style: TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
        ),
        Spacer(),
        Text(
          'L/R bars = real output',
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
          onPanStart: (d) {
            _dragTarget = _hitTest(
              d.localPosition,
              c.biggest.center(Offset.zero),
              scale,
            );
            // Desktop only: dragging empty space turns the virtual head
            // so world-locked sources stay put while you "look around".
            _headDragging = _dragTarget == null && !_pose.isLive;
          },
          onPanUpdate: (d) =>
              _onRadarDrag(d, c.biggest.center(Offset.zero), scale),
          onPanEnd: (_) {
            _dragTarget = null;
            _headDragging = false;
          },
          onLongPressStart: (d) =>
              _onRadarLongPress(d, c.biggest.center(Offset.zero), scale),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: RadarPainter(
                sources: _sources,
                beacons: _beacons,
                headYaw: _displayYaw,
                rangeM: _rangeM,
                sceneT: _sceneT,
                levels: _levels,
                repaint: _radarTick,
              ),
              child: const SizedBox.expand(),
            ),
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
  bool _headDragging = false;

  void _onRadarDrag(DragUpdateDetails d, Offset center, double scale) {
    if (_headDragging) {
      // Turn the head toward the pointer: screen-up is yaw 0, left is
      // + — same convention as the nose wedge. Recenter offset keeps
      // the engine pose and the displayed heading in agreement.
      final local = d.localPosition - center;
      if (local.distance < 8) return; // dead zone — avoid flip jitter
      _virtualYaw = math.atan2(-local.dx, -local.dy) + _yawAtRecenter;
      _pose.useVirtualHead(_virtualYaw);
      setState(() {});
      return;
    }
    final s = _dragTarget;
    if (s == null) return;
    final local = d.localPosition;
    final scene = Offset(
      -(local.dy - center.dy) / scale,
      -(local.dx - center.dx) / scale,
    );
    s.pushTrail();
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
          const Padding(
            padding: EdgeInsets.only(top: 4, left: 2),
            child: Text(
              'describe any scene — the AI builds it as 3D sound around you',
              style: TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: PipelineStrip(
              describing: _describing,
              describeSeconds: _describeStarted == null
                  ? 0
                  : DateTime.now()
                          .difference(_describeStarted!)
                          .inMilliseconds /
                      1000,
              llmChars: _llmChars,
              specSeconds: _activePrompt?.specSeconds,
              spec: _director.lastSpec,
              prompt: _activePrompt?.prompt,
              clipDone: _clipStatus.values
                  .where((s) => s != SfxStatus.generating)
                  .length,
              clipTotal: _director.lastSpec?.sources
                      .where((s) => s.sound != null)
                      .length ??
                  0,
              clipGenerating: _clipStatus.values
                  .any((s) => s == SfxStatus.generating),
              engineOn: _engineOn,
              sourceCount: _sources.length,
            ),
          ),
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'try:',
                style: TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
              ),
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
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'add:',
                style: TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
              ),
              for (final k in SourceKindWire.values.where(
                (k) => k != SourceKindWire.click,
              ))
                _KindChip(
                  kind: k,
                  color: _kindColors[k]!,
                  onTap: () => _addSource(k),
                ),
            ],
          ),
          if (_prompts.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<_PromptEntry>(
                    initialValue:
                        _prompts.contains(_selectedPrompt) ? _selectedPrompt : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                    hint: const Text(
                      'previous scenes',
                      style: TextStyle(fontSize: 12),
                    ),
                    items: [
                      for (final e in _prompts.reversed)
                        DropdownMenuItem(
                          value: e,
                          child: Text(
                            '${e.recorded ? '[recorded] ' : ''}'
                            '${_promptLabel(e.prompt)}',
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (e) =>
                        setState(() => _selectedPrompt = e),
                  ),
                ),
              ],
            ),
            if (_selectedPrompt != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Builder(
                      builder: (context) {
                        final e = _selectedPrompt!;
                        final playing = _engineOn &&
                            _pausedT == null &&
                            _activePrompt == e &&
                            _sources.isNotEmpty;
                        final pausedHere =
                            _pausedT != null && _activePrompt == e;
                        return IconButton(
                          onPressed: e.spec == null
                              ? null
                              : () => _playEntry(e),
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            size: 20,
                          ),
                          tooltip: playing
                              ? 'pause scene'
                              : pausedHere
                                  ? 'resume scene'
                                  : 'play scene',
                          visualDensity: VisualDensity.compact,
                        );
                      },
                    ),
                    IconButton(
                      onPressed: () =>
                          setState(() => _repeat = !_repeat),
                      icon: Icon(
                        _repeat ? Icons.repeat_on : Icons.repeat,
                        size: 18,
                      ),
                      color: _repeat
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0xFF9AA4B2),
                      tooltip:
                          _repeat ? 'scene repeats' : 'scene plays once',
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        _selectedPrompt!.spec == null
                            ? 'Gemma… ${DateTime.now().difference(_selectedPrompt!.startedAt).inSeconds}s'
                            : _selectedPrompt == _activePrompt &&
                                    _clipStatus.values.any(
                                      (s) => s == SfxStatus.generating,
                                    )
                                ? 'compiling audio '
                                    '${_clipStatus.values.where((s) => s != SfxStatus.generating).length}'
                                    '/${_clipStatus.length}…'
                                : _selectedPrompt!.specSeconds != null
                                    ? 'spec in ${_selectedPrompt!.specSeconds!.toStringAsFixed(0)}s'
                                        '${_selectedPrompt == _activePrompt && _clipStatus.isNotEmpty ? ' · audio ready' : ''}'
                                    : 'saved',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF9AA4B2),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (_sceneLen > 0) _scoreSection(),
          // Per-clip bars only for sources outside the authored score —
          // scene sources are scrubbed by the master bar above.
          for (final s
              in _sources.where((d) => d.isFile && d.estDurS <= 0))
            _seekRow(s),
        ],
      ),
    );
  }

  /// Lab sheet: dev bench — manual sources, spatial tuning, beacon/link
  /// controls. Everything a demo viewer doesn't need lives here.
  Future<void> _openLab() {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LabView(page: this),
    );
  }
}

/// Dev-bench sheet content. Owns a slow tick so countdown labels inside
/// the sheet stay fresh without rebuilding the page.
class _LabView extends StatefulWidget {
  const _LabView({required this.page});
  final _SandboxPageState page;

  @override
  State<_LabView> createState() => _LabViewState();
}

class _LabViewState extends State<_LabView> {
  Timer? _tick;

  _SandboxPageState get page => widget.page;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    return SafeArea(
      key: KeyConstants.labSheet,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A4552),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'lab — dev controls',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            _labLabel('add a source'),
            Wrap(
              spacing: 6,
              children: [
                for (final k in SourceKindWire.values.where(
                  (k) => k != SourceKindWire.click,
                ))
                  _KindChip(
                    kind: k,
                    color: _kindColors[k]!,
                    onTap: () {
                      page._addSource(k);
                      setState(() {});
                    },
                  ),
              ],
            ),
            if (page._sources.isNotEmpty) ...[
              _labLabel('live sources'),
              Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: () {
                      page._clearAll();
                      setState(() {});
                    },
                    child: const Text('Clear All'),
                  ),
                  for (final s in page._sources)
                    InputChip(
                      label: Text(
                        s.ended
                            ? '${s.label} · ended'
                            : s.pending && s.dueAt != null
                                ? '${s.label} · in ${math.max(0, (s.delayS - page._sceneT).ceil())}s'
                                : s.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: s.pending || s.ended
                              ? (_kindColors[s.kind] ?? Colors.white)
                                  .withValues(alpha: 0.45)
                              : _kindColors[s.kind] ?? Colors.white,
                        ),
                      ),
                      avatar: switch (page._clipStatus[s.label]) {
                        SfxStatus.failed => const Icon(
                            Icons.error_outline,
                            size: 14,
                            color: Color(0xFFE57373),
                          ),
                        SfxStatus.generating => const SizedBox(
                            width: 12,
                            height: 12,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        _ => s.isFile
                            ? const Icon(Icons.audio_file, size: 14)
                            : null,
                      },
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () {
                        page._removeSource(s);
                        setState(() {});
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            _labLabel('spatial tuning'),
            Row(
              children: [
                const Text(
                  'width',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
                ),
                Expanded(
                  child: Slider(
                    value: page._width,
                    min: 0.5,
                    max: 2.0,
                    label: 'L/R ×${page._width.toStringAsFixed(1)}',
                    onChanged: (v) {
                      setState(() => page._width = v);
                      page._sendSpatial();
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '×${page._width.toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9AA4B2),
                    ),
                  ),
                ),
              ],
            ),
            if (!page._pose.isLive)
              Row(
                children: [
                  const Text(
                    'virtual head',
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
                  ),
                  Expanded(
                    child: Slider(
                      value: page._virtualYaw,
                      min: -math.pi,
                      max: math.pi,
                      label:
                          '${(page._virtualYaw * 180 / math.pi).round()}°',
                      onChanged: (v) {
                        setState(() => page._virtualYaw = v);
                        page._pose.useVirtualHead(v);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${(page._virtualYaw * 180 / math.pi).round()}°',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9AA4B2),
                      ),
                    ),
                  ),
                ],
              ),
            if (page._announced.isNotEmpty) ...[
              _labLabel('devices'),
              Wrap(
                spacing: 6,
                children: [
                  for (final a in page._announced.values)
                    ActionChip(
                      label: Text(
                        'link ${a.name ?? "beacon ${a.id}"}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF80DEEA),
                        ),
                      ),
                      onPressed: () {
                        page._linkBeacon(a.id);
                        setState(() {});
                      },
                    ),
                ],
              ),
            ],
            for (final e in page._beacons.entries)
              page._beaconCard(e.key, e.value),
            if (page._beacons.isNotEmpty)
              Row(
                children: [
                  const Text(
                    'beacon dist',
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
                  ),
                  if (page._beacons.values.first.tracker.acousticM ==
                      null) ...[
                    Expanded(
                      child: Slider(
                        value: page
                            ._beacons.values.first.tracker.distanceM,
                        min: 0.3,
                        max: 8,
                        label:
                            '${page._beacons.values.first.tracker.distanceM.toStringAsFixed(1)} m',
                        onChanged: (v) => setState(
                          () => page._beacons.values.first.tracker
                              .distanceM = v,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${page._beacons.values.first.tracker.distanceM.toStringAsFixed(1)}m',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9AA4B2),
                        ),
                      ),
                    ),
                  ] else ...[
                    Expanded(
                      child: Text(
                        'acoustic ${page._beacons.values.first.tracker.acousticM!.toStringAsFixed(1)}m — live',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF80DEEA),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => page._beacons.values.first.tracker
                            .clearAcoustic(),
                      ),
                      child: const Text('manual'),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _labLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          t,
          style: const TextStyle(fontSize: 10, color: Color(0xFF5A6470)),
        ),
      );
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

/// The radar: top-down scene view. Front = up. Badges carry an icon +
/// color per source (see source_style.dart), behind-you sources are
/// hollow, elevated ones float on a stalk above their floor shadow,
/// motion leaves a fading trail, halos breathe with the real output
/// level, and L/R bars beside the head show the actual stereo bus.
class RadarPainter extends CustomPainter {
  RadarPainter({
    required this.sources,
    required this.beacons,
    required this.headYaw,
    required this.rangeM,
    required this.sceneT,
    this.levels,
    super.repaint,
  });
  final List<SourceDot> sources;
  final Map<int, BeaconState> beacons;
  final double headYaw; // radians; >0 = turned left
  final double rangeM;
  final double sceneT;
  final LevelsModel? levels;

  /// TextPainter layout is the painter's hot cost — cache by content.
  static final _tpCache = <String, TextPainter>{};

  static TextPainter _tp(String text, TextStyle style) {
    final key = '$text|${style.hashCode}';
    if (_tpCache.length > 256) _tpCache.clear();
    return _tpCache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
  }

  static TextPainter _icon(IconData icon, double size, Color color) => _tp(
        String.fromCharCode(icon.codePoint),
        TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      );

  /// Scene offset → canvas point, clamped to the edge ring so far
  /// sources ride the rim instead of vanishing off-canvas.
  static Offset _toCanvas(Offset scene, Offset center, double scale, double rMax) {
    var v = Offset(-scene.dy * scale, -scene.dx * scale);
    if (!v.dx.isFinite || !v.dy.isFinite) return center;
    if (v.distance > rMax) v *= rMax / v.distance;
    return center + v;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rMax = math.min(size.width, size.height) / 2 - 24;
    final scale = rMax / rangeM;
    final animT = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final lvl = levels;

    // ── backdrop: dark disc + shaded front half ("in front" reads at
    // a glance) + ±30° field-of-view cone.
    canvas.drawCircle(center, rMax, Paint()..color = const Color(0xFF0B0F16));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: rMax),
      math.pi,
      math.pi,
      false,
      Paint()..color = const Color(0xFF4FC3F7).withValues(alpha: 0.045),
    );
    final fovPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    for (final a in const [-30.0, 30.0]) {
      final rad = (a - 90) * math.pi / 180;
      canvas.drawLine(
        center,
        center + Offset(math.cos(rad), math.sin(rad)) * rMax,
        fovPaint,
      );
    }

    // ── rings with meter marks + crosshair axes.
    final ringPaint = Paint()
      ..color = const Color(0xFF26303C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = const Color(0xFF1B222C)
      ..strokeWidth = 1;
    for (final r in [1.0, 2.0, 3.0, 4.0, 5.0]) {
      canvas.drawCircle(center, r * scale, ringPaint);
      if (r < rangeM) {
        _tp(
          '${r.toInt()}m',
          const TextStyle(fontSize: 8, color: Color(0xFF3A4552)),
        ).paint(canvas, center + Offset(3, -r * scale - 3));
      }
    }
    canvas.drawLine(
      center + Offset(-rMax, 0),
      center + Offset(rMax, 0),
      axisPaint,
    );
    canvas.drawLine(
      center + Offset(0, -rMax),
      center + Offset(0, rMax),
      axisPaint,
    );

    // ── compass + heading readout.
    const compassStyle = TextStyle(
      fontSize: 9,
      color: Color(0xFF5A6470),
      fontWeight: FontWeight.w600,
      letterSpacing: 1.2,
    );
    _tp('FRONT', compassStyle)
        .paint(canvas, center + Offset(-16, -rMax - 15));
    _tp('BEHIND', compassStyle)
        .paint(canvas, center + Offset(-19, rMax + 5));
    _tp('L', compassStyle).paint(canvas, center + Offset(-rMax - 13, -5));
    _tp('R', compassStyle).paint(canvas, center + Offset(rMax + 7, -5));
    var deg = (headYaw * 180 / math.pi) % 360;
    if (deg > 180) deg -= 360;
    if (deg < -180) deg += 360;
    _tp(
      'hdg ${deg.round()}°',
      const TextStyle(
        fontSize: 10,
        color: Color(0xFF5A6470),
        fontFamily: 'monospace',
      ),
    ).paint(canvas, const Offset(8, 6));

    // ── sources: trail → guide line → stalk/shadow → badge → label.
    for (final s in sources) {
      final p = _toCanvas(s.pos, center, scale, rMax);
      final style = styleFor(s.label, s.kind);
      // Pending sources (cue hasn't arrived) and ended ones paint
      // dimmed — the composed plan is visible before and after it
      // sounds.
      final a = s.pending || s.ended ? 0.35 : 1.0;
      final srcLvl =
          (s.id == null ? 0.0 : (lvl?.sourceLevel(s.id!) ?? 0.0)) * a;

      final tr = s.trail;
      if (tr.length > 1 && !s.ended) {
        for (var i = 1; i < tr.length; i++) {
          final p0 = _toCanvas(tr[i - 1], center, scale, rMax);
          final p1 = _toCanvas(tr[i], center, scale, rMax);
          canvas.drawLine(
            p0,
            p1,
            Paint()
              ..color = style.color
                  .withValues(alpha: (0.04 + 0.30 * (i / tr.length)) * a)
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round,
          );
        }
      }

      if (!s.pending && !s.ended && s.id != null) {
        canvas.drawLine(
          center,
          p,
          Paint()
            ..color = style.color.withValues(alpha: 0.06 + 0.16 * srcLvl)
            ..strokeWidth = 1,
        );
      }

      // Elevation: the badge floats on a stalk above its floor shadow —
      // the shadow stays at the true plan position.
      final zPx = (s.z * scale * 0.55).clamp(-rMax * 0.4, rMax * 0.4);
      final elevated = zPx.abs() > 3;
      final badgeP = p - Offset(0, zPx);
      if (elevated) {
        canvas.drawOval(
          Rect.fromCenter(center: p, width: 18, height: 6),
          Paint()..color = Colors.black.withValues(alpha: 0.5 * a),
        );
        canvas.drawLine(
          p,
          badgeP,
          Paint()
            ..color = style.color.withValues(alpha: 0.5 * a)
            ..strokeWidth = 1,
        );
      }

      // Halo breathes with the source's real output level; above ~0.3 a
      // ripple ring expands out of the badge.
      if (srcLvl > 0.02) {
        canvas.drawCircle(
          badgeP,
          11 + 15 * srcLvl,
          Paint()..color = style.color.withValues(alpha: 0.20 * srcLvl),
        );
        if (srcLvl > 0.3) {
          final ph = (animT * 1.1) % 1.0;
          canvas.drawCircle(
            badgeP,
            12 + ph * 14,
            Paint()
              ..color = style.color.withValues(alpha: (1 - ph) * 0.35)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        }
      } else {
        canvas.drawCircle(
          badgeP,
          11,
          Paint()..color = style.color.withValues(alpha: 0.12 * a),
        );
      }

      // Badge body: filled in front of the listener, hollow ring behind
      // — the "behind you" cue survives even in a static screenshot.
      final behind = s.pos.dx < 0;
      if (behind) {
        canvas.drawCircle(
          badgeP,
          9.5,
          Paint()..color = const Color(0xFF0B0F16).withValues(alpha: a),
        );
        canvas.drawCircle(
          badgeP,
          9.5,
          Paint()
            ..color = style.color.withValues(alpha: a)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      } else {
        canvas.drawCircle(
          badgeP,
          10,
          Paint()..color = style.color.withValues(alpha: 0.9 * a),
        );
      }
      final iconTp = _icon(
        style.icon,
        11,
        behind
            ? style.color.withValues(alpha: a)
            : const Color(0xFF0B0F16).withValues(alpha: 0.95 * a),
      );
      iconTp.paint(
        canvas,
        badgeP - Offset(iconTp.width / 2, iconTp.height / 2),
      );

      // Label: name · distance, plus countdown / ended / height.
      var text = '${s.label} · ${s.pos.distance.toStringAsFixed(1)}m';
      if (s.pending) {
        text =
            '${s.label} · in ${math.max(0, (s.delayS - sceneT)).ceil()}s';
      } else if (s.ended) {
        text = '${s.label} · ended';
      }
      if (elevated) {
        text += s.z >= 0
            ? ' ↑${s.z.toStringAsFixed(1)}m'
            : ' ↓${(-s.z).toStringAsFixed(1)}m';
      }
      final lt = _tp(
        text,
        TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: style.color.withValues(alpha: a),
        ),
      );
      final lp = badgeP + Offset(-lt.width / 2, elevated ? -26 : 12);
      lt.paint(
        canvas,
        Offset(lp.dx.clamp(4.0, size.width - lt.width - 4), lp.dy),
      );
    }

    // ── beacons: ringed dot + telemetry label, gray when stale.
    for (final b in beacons.values) {
      final s = b.sample;
      if (s == null) continue;
      final stale = s.stale;
      final p = _toCanvas(s.pos, center, scale, rMax);
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
      _tp(label, TextStyle(fontSize: 9, color: color))
          .paint(canvas, p + const Offset(-18, 14));
    }

    // ── head wedge on top of sources; ears glow with real channel levels.
    final eL = lvl?.left ?? 0;
    final eR = lvl?.right ?? 0;
    final headPaint = Paint()..color = const Color(0xFF4CAF50);
    final nose =
        center + Offset(-math.sin(headYaw) * 20, -math.cos(headYaw) * 20);
    final leftEar = center +
        Offset(-math.sin(headYaw + 2.5) * 10, -math.cos(headYaw + 2.5) * 10);
    final rightEar = center +
        Offset(-math.sin(headYaw - 2.5) * 10, -math.cos(headYaw - 2.5) * 10);
    canvas.drawPath(
      Path()..addPolygon([nose, leftEar, rightEar], true),
      headPaint,
    );
    canvas.drawCircle(center, 5, Paint()..color = const Color(0xFF4CAF50));
    // Ear glow: saturation follows the live meter so "which side is
    // loud" is readable even with sound off.
    canvas.drawCircle(
      leftEar,
      3.5 + 3 * eL,
      Paint()
        ..color = Color.lerp(
          const Color(0xFF5A6470),
          const Color(0xFF4FC3F7),
          eL,
        )!,
    );
    canvas.drawCircle(
      rightEar,
      3.5 + 3 * eR,
      Paint()
        ..color = Color.lerp(
          const Color(0xFF5A6470),
          const Color(0xFFFF8A65),
          eR,
        )!,
    );

    // ── stereo HUD: L/R bars at the canvas edges (they mirror the
    // headphone channels, not radar north) + ILD readout under the head.
    if (lvl != null) {
      _earBar(canvas, Offset(10, center.dy - 24), eL, 'L');
      _earBar(canvas, Offset(size.width - 16, center.dy - 24), eR, 'R');
      final ild = lvl.ildDb;
      if (ild.abs() > 0.5) {
        final it = _tp(
          'ILD ${ild > 0 ? '+' : ''}${ild.toStringAsFixed(0)} dB',
          const TextStyle(
            fontSize: 10,
            fontFamily: 'monospace',
            color: Color(0xFF9AA4B2),
          ),
        );
        it.paint(canvas, center + Offset(-it.width / 2, 28));
      }
    }
  }

  /// One vertical meter bar: dark well + colored fill from the bottom.
  static void _earBar(Canvas canvas, Offset topLeft, double v, String tag) {
    const h = 48.0, w = 6.0;
    const color = Color(0xFF4FC3F7);
    final fill = tag == 'L' ? color : const Color(0xFFFF8A65);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(topLeft.dx, topLeft.dy, w, h),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF1A2230),
    );
    final fh = h * v.clamp(0.0, 1.0);
    if (fh > 0.5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(topLeft.dx, topLeft.dy + h - fh, w, fh),
          const Radius.circular(3),
        ),
        Paint()..color = fill,
      );
    }
    _tp(tag, TextStyle(fontSize: 8, color: fill))
        .paint(canvas, topLeft + const Offset(0, h + 3));
  }

  @override
  bool shouldRepaint(RadarPainter old) => true;
}
