import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'scene_director.dart' show SpecSource;

/// Slow drift around an anchor — "kids running around behind me" stays
/// *behind you* instead of circling your head. Two incommensurate sine
/// sums on azimuth and distance give organic, non-repeating motion.
class WanderMotion {
  WanderMotion({
    required this.anchorAzDeg,
    this.anchorElDeg = 0,
    required this.anchorDistM,
    this.azSpanDeg = 30,
    this.distSpanM = 0.4,
    this.periodS = 7,
  });
  double anchorAzDeg;
  double anchorElDeg;
  double anchorDistM;
  double azSpanDeg;
  double distSpanM;
  double periodS;
}

/// One directed source: opaque page-side handle + its spec + the position
/// setter. The key resolves to the live engine id inside [setPos], so
/// engine restarts (which re-assign ids) keep working.
class DirectedSource {
  DirectedSource({required this.key, required this.spec, required this.setPos});
  final Object key;
  final SpecSource spec;
  final void Function(Object key, Offset pos, double z) setPos;
  DateTime t0 = DateTime.now();
}

/// Drives moving sources: a ~30 Hz tick that evaluates each source's
/// motion path and pushes positions through the FRB setter — the same
/// call the radar drag handler uses.
class MotionBank {
  final _entries = <DirectedSource>[];
  Timer? _timer;
  static const _tickMs = 33;

  void track(DirectedSource s) {
    _entries.add(s);
    _timer ??= Timer.periodic(const Duration(milliseconds: _tickMs), _tick);
  }

  void untrack(Object key) {
    _entries.removeWhere((e) => e.key == key);
    if (_entries.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Restart a source's motion clock — e.g. its generated clip just
  /// landed, so a traverse should sweep from the start now, not from the
  /// moment the spec was applied.
  void restart(Object key) => restartAt(key, DateTime.now());

  /// Restart anchored at an explicit instant — a delayed source whose
  /// clip landed early anchors to its scheduled cue, not land time.
  void restartAt(Object key, DateTime t0) {
    for (final e in _entries) {
      if (e.key == key) e.t0 = t0;
    }
  }

  /// Re-anchor every tracked source to [sceneT] on the scene clock —
  /// a master seekbar scrub or an engine restart resume. t0 shifts so
  /// (now - t0) == sceneT - delay_s, i.e. motion follows the score.
  void seekTo(double sceneT) {
    final now = DateTime.now();
    for (final e in _entries) {
      final local = sceneT - e.spec.delayS;
      e.t0 = now.subtract(
        Duration(milliseconds: (local * 1000).round()),
      );
    }
  }

  void stopAll() {
    _entries.clear();
    _timer?.cancel();
    _timer = null;
  }

  int get active => _entries.length;

  /// Engine stopped — freeze the radar animation; tracked entries keep
  /// their t0 so unpausing resumes the orbit at its natural phase.
  bool paused = false;

  void _tick(Timer _) {
    if (paused) return;
    final t = DateTime.now();
    for (final e in _entries) {
      final dt = t.difference(e.t0).inMilliseconds / 1000.0;
      final s = e.spec;
      Offset p;
      if (s.wander != null) {
        p = _wander(s, dt);
      } else if (s.orbit != null) {
        p = _orbit(s, dt);
      } else if (s.approach != null) {
        p = _approach(s, dt);
      } else if (s.traverse != null) {
        p = _traverse(s, dt);
      } else {
        continue; // static sources need no ticks
      }
      e.setPos(e.key, p, s.z);
    }
  }

  Offset _wander(SpecSource s, double t) {
    final w = s.wander!;
    // Two incommensurate sines — reads as aimless movement, not a
    // mechanical ellipse.
    final az = (w.anchorAzDeg +
            math.sin(2 * math.pi * t / w.periodS) * w.azSpanDeg) *
        math.pi /
        180;
    final dist = w.anchorDistM +
        math.sin(2 * math.pi * t / (w.periodS * 1.37) + 1.3) *
            w.distSpanM;
    final el = w.anchorElDeg * math.pi / 180;
    return Offset(
      dist * math.cos(el) * math.cos(az),
      dist * math.cos(el) * math.sin(az),
    );
  }

  Offset _orbit(SpecSource s, double t) {
    final o = s.orbit!;
    final th = 2 * math.pi * t / o.periodS + o.phaseDeg * math.pi / 180;
    final el = s.elDeg * math.pi / 180;
    // Orbit center: head (0,0) or the source's anchor — "around the
    // fire behind you" circles the fire, not your head.
    final cx = o.centerDistM * math.cos(o.centerAzDeg * math.pi / 180);
    final cy = o.centerDistM * math.sin(o.centerAzDeg * math.pi / 180);
    return Offset(
      cx + o.radiusM * math.cos(el) * math.cos(th),
      cy + o.radiusM * math.cos(el) * math.sin(th),
    );
  }

  Offset _approach(SpecSource s, double t) {
    final a = s.approach!;
    final k = (t / a.seconds).clamp(0.0, 1.0);
    final fromAz = a.fromAzDeg * math.pi / 180;
    final toAz = s.azDeg * math.pi / 180;
    final az = fromAz + (toAz - fromAz) * k;
    final dist = a.fromDistM + (s.distM - a.fromDistM) * k;
    return Offset(dist * math.cos(az), dist * math.sin(az));
  }

  Offset _traverse(SpecSource s, double t) {
    final tr = s.traverse!;
    final k = (t / tr.seconds).clamp(0.0, 1.0);
    final az =
        (tr.fromAzDeg + (tr.toAzDeg - tr.fromAzDeg) * k) * math.pi / 180;
    return Offset(tr.distM * math.cos(az), tr.distM * math.sin(az));
  }
}
