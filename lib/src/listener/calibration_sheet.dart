import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:spatial_audio_sandbox/src/key_constants.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

/// Thin interface over the engine's diagnostic session — injectable so
/// widget tests don't need the native library.
abstract class TestAudioApi {
  Future<void> enter(int token);
  void exit(int token);
  Future<void> play({
    required int token,
    required int trial,
    required bool direct,
    required double az,
    required double level,
    required double balance,
  });
  void stop(int token);
  void params({
    required int token,
    required double az,
    required double level,
    required double balance,
  });
  ({int session, int trial, int remainingMs}) status();
}

/// Production implementation — straight to the FRB bridge (the calls
/// are synchronous; the Futures let the sheet await them uniformly).
class EngineTestAudio implements TestAudioApi {
  @override
  Future<void> enter(int token) async => diagEnter(token: token);
  @override
  void exit(int token) => diagExit(token: token);
  @override
  Future<void> play({
    required int token,
    required int trial,
    required bool direct,
    required double az,
    required double level,
    required double balance,
  }) async =>
      diagPlay(
        token: token,
        trial: trial,
        direct: direct,
        az: az,
        level: level,
        balance: balance,
      );
  @override
  void stop(int token) => diagStop(token: token);
  @override
  void params({
    required int token,
    required double az,
    required double level,
    required double balance,
  }) =>
      diagParams(token: token, az: az, level: level, balance: balance);
  @override
  ({int session, int trial, int remainingMs}) status() {
    final s = diagStatus();
    return (session: s.session, trial: s.trial, remainingMs: s.remainingMs);
  }
}

/// Sound check — deliberately simple: prove the headphone channels
/// first (raw left/both/right output), then test spatial positioning.
/// No sound plays until a button is tapped, and every sound is a short
/// chime pair that stops by itself.
class CalibrationSheet extends StatefulWidget {
  const CalibrationSheet({
    super.key,
    required this.audio,
    required this.engineOn,
    required this.onStartEngine,
  });

  final TestAudioApi audio;
  final bool engineOn;

  /// Returns true if the engine is running afterward.
  final Future<bool> Function() onStartEngine;

  @override
  State<CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<CalibrationSheet> {
  static const _angles = [15, 30, 45, 60, 90];

  final int _token =
      (DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF) | 0x40000000;
  int _nextTrial = 1;
  bool _sessionOpen = false;
  bool _starting = false;
  bool _engineUp = false;
  String _status = 'ready';
  Timer? _poll;

  // Mode: false = headphone check, true = spatial position.
  bool _spatial = false;

  // Headphone check state.
  double _balance = 0.0; // -1 left .. +1 right

  // Spatial state — UI convention: -90 = left, +90 = right.
  double _pos = 45.0;

  // Shared test volume (0..1).
  double _level = 0.8;

  // Quiz.
  int? _quizAzDeg; // engine azimuth of the hidden question, + = left
  bool _awaiting = false;
  final _score = <int, List<int>>{}; // angle -> [correct, total]
  int _correct = 0, _total = 0;
  String _feedback = '';

  /// Engine azimuth (rad, + = left) for the spatial slider position.
  double get _azRad => -_pos * math.pi / 180;

  @override
  void initState() {
    super.initState();
    _engineUp = widget.engineOn;
    _poll = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      final s = widget.audio.status();
      // A finished quiz trial unlocks the answer buttons.
      if (_awaiting && s.trial == 0) {
        setState(() => _status = 'which side was it?');
      } else if (s.trial != 0) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_sessionOpen) {
      widget.audio.stop(_token);
      widget.audio.exit(_token);
    }
    super.dispose();
  }

  Future<bool> _ensureEngine() async {
    if (_engineUp) return true;
    if (_starting) return false;
    _starting = true;
    setState(() => _status = 'starting audio…');
    final ok = await widget.onStartEngine().catchError((_) => false);
    if (mounted) {
      setState(() {
        _starting = false;
        _engineUp = ok;
        _status = ok ? 'ready' : 'audio failed to start — check output';
      });
    }
    return ok;
  }

  Future<void> _enter() async {
    if (_sessionOpen) return;
    try {
      await widget.audio.enter(_token);
      _sessionOpen = true;
    } catch (e) {
      if (mounted) setState(() => _status = 'session failed: $e');
      rethrow;
    }
  }

  /// Every sound goes through here — one trial at a time, always
  /// finite (the engine's chime ends on its own).
  Future<void> _play({required bool direct, double? az}) async {
    if (!await _ensureEngine()) return;
    try {
      await _enter();
      final trial = _nextTrial++;
      await widget.audio.play(
        token: _token,
        trial: trial,
        direct: direct,
        az: az ?? _azRad,
        level: _level,
        balance: _balance,
      );
      if (mounted) setState(() => _status = 'playing…');
    } catch (e) {
      if (mounted) setState(() => _status = 'play failed: $e');
    }
  }

  void _stop() {
    if (_sessionOpen) widget.audio.stop(_token);
    setState(() => _status = 'stopped');
  }

  void _tune({double? balance, double? pos, double? level}) {
    setState(() {
      if (balance != null) _balance = balance;
      if (pos != null) _pos = pos;
      if (level != null) _level = level;
    });
    // Live retune — never while a quiz question is hidden.
    if (_sessionOpen && !_awaiting) {
      widget.audio.params(
        token: _token,
        az: _azRad,
        level: _level,
        balance: _balance,
      );
    }
  }

  // ── quiz ──────────────────────────────────────────────────────

  Future<void> _quizPlay() async {
    final rng = math.Random();
    final a = _angles[rng.nextInt(_angles.length)];
    final side = rng.nextBool() ? 1 : -1;
    _quizAzDeg = a * side;
    _feedback = '';
    _awaiting = true;
    setState(() => _status = 'listen…');
    await _play(direct: false, az: _quizAzDeg! * math.pi / 180);
  }

  void _answer(bool guessedLeft) {
    final az = _quizAzDeg;
    if (!_awaiting || az == null) return;
    final correctLeft = az > 0;
    final ok = guessedLeft == correctLeft;
    final a = az.abs();
    final s = _score.putIfAbsent(a, () => [0, 0]);
    s[1]++;
    if (ok) {
      s[0]++;
      _correct++;
    }
    _total++;
    _feedback = ok
        ? 'correct — it was ${correctLeft ? "left" : "right"} $a°'
        : 'wrong — it was ${correctLeft ? "left" : "right"} $a°';
    _quizAzDeg = null;
    _awaiting = false;
    setState(() => _status = 'ready');
  }

  // ── build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      key: KeyConstants.soundCheckSheet,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.hearing, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Sound check', style: TextStyle(fontSize: 15)),
                ),
              ]),
              const SizedBox(height: 2),
              const Text(
                'Use headphones. Other sounds pause while testing.',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
              ),
              const SizedBox(height: 10),

              // ── mode ──────────────────────────────────────────
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.headphones, size: 16),
                    label: Text('Headphone check'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.surround_sound, size: 16),
                    label: Text('Spatial position'),
                  ),
                ],
                selected: {_spatial},
                onSelectionChanged: (s) {
                  _stop();
                  setState(() => _spatial = s.first);
                },
              ),
              const SizedBox(height: 12),

              if (!_spatial) _headphoneCheck() else _spatialTest(),

              const Divider(height: 24),

              // ── shared: volume + stop ─────────────────────────
              Row(children: [
                const SizedBox(
                  width: 76,
                  child: Text('Test volume',
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFF9AA4B2))),
                ),
                Expanded(
                  child: Slider(
                    key: KeyConstants.volumeSlider,
                    value: _level,
                    min: 0,
                    max: 1,
                    onChanged: (v) => _tune(level: v),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('${(_level * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF9AA4B2))),
                ),
              ]),
              Row(children: [
                FilledButton.tonalIcon(
                  key: KeyConstants.stopSound,
                  onPressed: _stop,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop sound'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _status,
                    key: KeyConstants.statusText,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9AA4B2)),
                  ),
                ),
                if (_starting)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ]),

              // ── advanced: quiz ────────────────────────────────
              ExpansionTile(
                key: KeyConstants.advancedToggle,
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Advanced — left/right quiz',
                    style: TextStyle(fontSize: 12)),
                onExpansionChanged: (open) {
                  _stop();
                  setState(() {
                    _awaiting = false;
                    _quizAzDeg = null;
                    _feedback = '';
                  });
                },
                children: [_quizBody()],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headphoneCheck() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonal(
            key: KeyConstants.testLeftEar,
            onPressed: _starting
                ? null
                : () {
                    _balance = -1;
                    _play(direct: true);
                  },
            child: const Text('Test left ear'),
          ),
          FilledButton.tonal(
            key: KeyConstants.testBothEars,
            onPressed: _starting
                ? null
                : () {
                    _balance = 0;
                    _play(direct: true);
                  },
            child: const Text('Test both'),
          ),
          FilledButton.tonal(
            key: KeyConstants.testRightEar,
            onPressed: _starting
                ? null
                : () {
                    _balance = 1;
                    _play(direct: true);
                  },
            child: const Text('Test right ear'),
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Each plays two short chimes on that channel only.',
          style: TextStyle(fontSize: 10, color: Color(0xFF9AA4B2)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(
            width: 76,
            child: Text('Balance',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
          ),
          Expanded(
            child: Slider(
              key: KeyConstants.balanceSlider,
              value: _balance,
              min: -1,
              max: 1,
              divisions: 20,
              label: _balance == 0
                  ? 'equal'
                  : _balance < 0
                      ? 'left ${(-_balance * 100).round()}%'
                      : 'right ${(_balance * 100).round()}%',
              onChanged: (v) => _tune(balance: v),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              _balance == 0
                  ? 'equal'
                  : _balance < 0
                      ? 'L${(-_balance * 100).round()}%'
                      : 'R${(_balance * 100).round()}%',
              style:
                  const TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
            ),
          ),
        ]),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            key: KeyConstants.balancePlay,
            onPressed: () => _play(direct: true),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Play balance test'),
          ),
          OutlinedButton.icon(
            key: KeyConstants.balanceReset,
            onPressed: () => _tune(balance: 0),
            icon: const Icon(Icons.center_focus_strong, size: 16),
            label: const Text('Reset'),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'If a one-ear test is equally loud in both ears, check system '
            'mono audio or headphone settings.',
            style: TextStyle(fontSize: 10, color: Color(0xFF9AA4B2)),
          ),
        ),
      ],
    );
  }

  Widget _spatialTest() {
    final label = _pos == 0
        ? 'front'
        : _pos < 0
            ? '${-_pos.round()}° left'
            : '${_pos.round()}° right';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in [-45.0, 0.0, 45.0])
            ChoiceChip(
              label: Text(
                p == 0 ? 'Front' : p < 0 ? 'L45' : 'R45',
                style: const TextStyle(fontSize: 11),
              ),
              selected: _pos == p,
              onSelected: (_) => _tune(pos: p),
            ),
        ]),
        Row(children: [
          const SizedBox(
            width: 76,
            child: Text('Left — Right',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
          ),
          Expanded(
            child: Slider(
              key: KeyConstants.positionSlider,
              value: _pos,
              min: -90,
              max: 90,
              label: label,
              onChanged: (v) => _tune(pos: v),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF9AA4B2))),
          ),
        ]),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            key: KeyConstants.playSpatial,
            onPressed: () => _play(direct: false),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Play test sound'),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Spatial sound can reach both ears — listen for which side '
            'it comes from.',
            style: TextStyle(fontSize: 10, color: Color(0xFF9AA4B2)),
          ),
        ),
      ],
    );
  }

  Widget _quizBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Row(children: [
          FilledButton(
            key: KeyConstants.quizPlay,
            onPressed: _awaiting || _starting ? null : _quizPlay,
            child: Text(_awaiting ? 'listening…' : 'Play question'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _feedback.isEmpty
                  ? 'A hidden position plays once. Tap Left or Right '
                      'when the chime ends.'
                  : _feedback,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              key: KeyConstants.quizLeft,
              onPressed: _awaiting ? () => _answer(true) : null,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('left'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              key: KeyConstants.quizRight,
              onPressed: _awaiting ? () => _answer(false) : null,
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('right'),
            ),
          ),
        ]),
        if (_total > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'score $_correct/$_total'
              '${_score.isEmpty ? '' : '   ${_score.entries.map((e) => '${e.key}°: ${e.value[0]}/${e.value[1]}').join('  ')}'}',
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF9AA4B2)),
            ),
          ),
      ],
    );
  }
}
