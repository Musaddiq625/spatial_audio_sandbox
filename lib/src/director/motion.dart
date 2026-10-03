import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'scene_director.dart' show SpecSource;

/// One directed source: engine id + its spec + the position setter.
/// The id is looked up live at each tick so engine restarts (which
/// re-assign ids) keep working.
class DirectedSource {
  DirectedSource({required this.id, required this.spec, required this.setPos});
  int id;
  final SpecSource spec;
  final void Function(int id, Offset pos, double z) setPos;
  final t0 = DateTime.now();
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

  void untrack(int id) {
    _entries.removeWhere((e) => e.id == id);
    if (_entries.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void stopAll() {
    _entries.clear();
    _timer?.cancel();
    _timer = null;
  }

  int get active => _entries.length;

  void _tick(Timer _) {
    final t = DateTime.now();
    for (final e in _entries) {
      final dt = t.difference(e.t0).inMilliseconds / 1000.0;
      final s = e.spec;
      Offset p;
      if (s.orbit != null) {
        p = _orbit(s, dt);
      } else if (s.approach != null) {
        p = _approach(s, dt);
      } else {
        continue; // static sources need no ticks
      }
      e.setPos(e.id, p, s.z);
    }
  }

  Offset _orbit(SpecSource s, double t) {
    final o = s.orbit!;
    final th = 2 * math.pi * t / o.periodS + o.phaseDeg * math.pi / 180;
    final el = s.elDeg * math.pi / 180;
    return Offset(
      o.radiusM * math.cos(el) * math.cos(th),
      o.radiusM * math.cos(el) * math.sin(th),
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
}
