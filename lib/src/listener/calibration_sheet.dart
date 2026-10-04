import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:spatial_audio_sandbox/src/listener/pose_channel.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

/// Left/right localization calibration: a pulsed noise burst at a set or
/// random azimuth, a Left/Right quiz that scores accuracy per angle, and
/// live tuning sliders for the spatial engine.
///
/// While open, the head-pose stream is paused (phone drift can't bias a
/// judgment of a static source) and recentered; it's restored on close.
/// Everything else — source add/remove, gain pulsing, spatial params —
/// goes straight to the bridge; no scene state is touched.
class CalibrationSheet extends StatefulWidget {
  const CalibrationSheet({
    super.key,
    required this.pose,
    required this.engineOn,
    required this.width,
    required this.wet,
    required this.ildDb,
    required this.onSpatial,
    required this.onStartEngine,
  });

  final PoseBridge pose;
  final bool engineOn;
  final double width, wet, ildDb;
  final void Function(double width, double wet, double ildDb) onSpatial;
  final Future<void> Function() onStartEngine;

  @override
  State<CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<CalibrationSheet> {
  static const _dist = 1.5;
  static const _angles = [15, 30, 45, 60, 90];

  int? _sourceId;
  double _az = 45; // degrees, + = left
  bool _pausedPose = false;
  Timer? _pulse;
  bool _pulseOn = false;
  bool _pulsing = false;

  // Quiz state.
  bool _quiz = false;
  double? _quizAz;
  final _score = <int, List<int>>{}; // angle -> [correct, total]
  int _quizCorrect = 0, _quizTotal = 0;
  String _feedback = '';

  // Local copies — a modal bottom sheet is a separate route, so parent
  // setState won't rebuild it. The parent gets notified via onSpatial.
  late double _w = widget.width;
  late double _wt = widget.wet;
  late double _ild = widget.ildDb;

  @override
  void initState() {
    super.initState();
    if (widget.pose.isLive) {
      widget.pose.stop();
      _pausedPose = true;
      // Latch "forward" = however the user is holding the phone now.
      recenter();
    }
    if (widget.engineOn) _spawn();
  }

  /// The sheet is a separate route — widget.engineOn is the value at
  /// open time. Once we've spawned, the engine is up regardless.
  bool get _engineUp => widget.engineOn || _sourceId != null;

  Future<void> _spawn() async {
    if (_sourceId != null) return;
    final id = await addSource(
      kind: SourceKindWire.noise,
      x: _dist * math.cos(_az * math.pi / 180),
      y: _dist * math.sin(_az * math.pi / 180),
      z: 0,
      gain: _pulsing ? 0.0 : 0.65,
    );
    _sourceId = id;
    if (mounted) setState(() {});
  }

  void _setAz(double azDeg) {
    _az = azDeg;
    final id = _sourceId;
    if (id != null) {
      setSourcePosition(
        id: id,
        x: _dist * math.cos(azDeg * math.pi / 180),
        y: _dist * math.sin(azDeg * math.pi / 180),
        z: 0,
      );
    }
    setState(() {});
  }

  /// Bursts: ~300 ms on / 500 ms off through the engine's gain slew —
  /// the onset transient is the cue steady beds don't give you.
  void _togglePulse() {
    if (_pulsing) {
      _pulse?.cancel();
      _pulse = null;
      _pulsing = false;
      final id = _sourceId;
      if (id != null) setSourceGain(id: id, gain: 0.65);
    } else {
      _pulsing = true;
      _pulse = Timer.periodic(const Duration(milliseconds: 800), (_) {
        _pulseOn = !_pulseOn;
        final id = _sourceId;
        if (id != null) setSourceGain(id: id, gain: _pulseOn ? 0.65 : 0.0);
      });
    }
    setState(() {});
  }

  /// One quiz round: pick a random angle+side, burst twice, wait for the
  /// Left/Right answer.
  void _quizPlay() {
    final rng = math.Random();
    final a = _angles[rng.nextInt(_angles.length)];
    final side = rng.nextBool() ? 1.0 : -1.0;
    _quizAz = a * side;
    _setAz(_quizAz!);
    _feedback = 'listen…';
    setState(() {});
  }

  void _answer(bool guessedLeft) {
    if (_quizAz == null) return;
    final correctLeft = _quizAz! > 0;
    final ok = guessedLeft == correctLeft;
    final a = _quizAz!.abs().round();
    final s = _score.putIfAbsent(a, () => [0, 0]);
    s[1]++;
    if (ok) {
      s[0]++;
      _quizCorrect++;
    }
    _quizTotal++;
    _feedback = ok
        ? 'correct — it was ${correctLeft ? "left" : "right"} $a°'
        : 'wrong — it was ${correctLeft ? "left" : "right"} $a°';
    _quizAz = null;
    setState(() {});
  }

  @override
  void dispose() {
    _pulse?.cancel();
    final id = _sourceId;
    if (id != null) removeSource(id: id);
    if (_pausedPose) {
      widget.pose.start();
      recenter();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hearing, size: 18),
                const SizedBox(width: 8),
                const Text('ear calibration — left/right',
                    style: TextStyle(fontSize: 14)),
                const Spacer(),
                if (!_engineUp)
                  FilledButton.tonal(
                    onPressed: () async {
                      await w.onStartEngine();
                      if (mounted) _spawn();
                    },
                    child: const Text('start engine'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _pausedPose
                  ? 'head tracking paused while open'
                  : 'no head tracking — static test',
              style: const TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
            ),
            const Divider(height: 20),

            // ── manual position ────────────────────────────────
            if (!_quiz) ...[
              Row(children: [
                for (final a in [-90, -45, -20, 0, 20, 45, 90])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(
                        a == 0
                            ? 'C'
                            : '${a < 0 ? "R" : "L"}${a.abs()}°',
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: _az.round() == a,
                      onSelected: (_) => _setAz(a.toDouble()),
                    ),
                  ),
              ]),
              Row(children: [
                const Text('azimuth',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
                Expanded(
                  child: Slider(
                    value: _az,
                    min: -90,
                    max: 90,
                    label: '${_az.round()}°',
                    onChanged: _setAz,
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '${_az.round()}°',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9AA4B2)),
                  ),
                ),
              ]),
            ],

            // ── pulse + quiz ───────────────────────────────────
            Row(children: [
              FilledButton.tonalIcon(
                onPressed: _engineUp ? _togglePulse : null,
                icon: Icon(_pulsing ? Icons.stop : Icons.graphic_eq,
                    size: 16),
                label: Text(_pulsing ? 'stop bursts' : 'burst noise'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: w.engineOn
                    ? () => setState(() {
                          _quiz = !_quiz;
                          _quizAz = null;
                          _feedback = '';
                          if (!_pulsing) _togglePulse();
                        })
                    : null,
                icon: const Icon(Icons.quiz, size: 16),
                label: Text(_quiz ? 'exit quiz' : 'quiz me'),
              ),
              const Spacer(),
              if (_quiz)
                FilledButton(
                  onPressed: _engineUp ? _quizPlay : null,
                  child: const Text('play'),
                ),
            ]),
            if (_quiz) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _quizAz != null ? () => _answer(true) : null,
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('left'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _quizAz != null ? () => _answer(false) : null,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text('right'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                '$_feedback   score $_quizCorrect/$_quizTotal',
                style: const TextStyle(fontSize: 12),
              ),
              if (_score.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _score.entries
                        .map((e) =>
                            '${e.key}°: ${e.value[0]}/${e.value[1]}')
                        .join('   '),
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9AA4B2)),
                  ),
                ),
            ],
            const Divider(height: 20),

            // ── live tuning ────────────────────────────────────
            const Text('tuning (live)',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
            _tuneRow('width', _w, 0.5, 2.0, '×${_w.toStringAsFixed(1)}',
                (v) {
              setState(() => _w = v);
              w.onSpatial(v, _wt, _ild);
            }),
            _tuneRow('extra ILD', _ild, 0, 20, '${_ild.round()}dB', (v) {
              setState(() => _ild = v);
              w.onSpatial(_w, _wt, v);
            }),
            _tuneRow('reverb', _wt, 0, 0.4, _wt.toStringAsFixed(2), (v) {
              setState(() => _wt = v);
              w.onSpatial(_w, v, _ild);
            }),
          ],
        ),
      ),
    );
  }

  Widget _tuneRow(String label, double v, double lo, double hi, String txt,
          ValueChanged<double> f) =>
      Row(children: [
        SizedBox(
          width: 64,
          child: Text(label,
              style:
                  const TextStyle(fontSize: 11, color: Color(0xFF9AA4B2))),
        ),
        Expanded(
          child: Slider(value: v, min: lo, max: hi, onChanged: f),
        ),
        SizedBox(
          width: 56,
          child: Text(txt,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF9AA4B2))),
        ),
      ]);
}
