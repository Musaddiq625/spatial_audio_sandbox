import 'dart:math' as math;

/// Live stereo + per-source loudness for the radar, fed by the Rust
/// mixer's per-block RMS atomics (polled ~30 Hz — see getLevels()).
/// Raw RMS lands here; the model applies instant-attack /
/// ~250 ms-release ballistics and a dB→0..1 map so the painter only
/// ever reads display-ready values.
class LevelsModel {
  /// Smoothed master bus levels, 0..1 display space.
  double left = 0;
  double right = 0;
  double _lRms = 0;
  double _rRms = 0;

  /// engine source id → smoothed level (0..1). Ids not reported this
  /// poll are dropped so stale ids can't ghost a removed source.
  final _src = <int, double>{};

  double sourceLevel(int id) => _src[id] ?? 0;

  /// Interaural level difference in dB — + means louder in the left ear.
  /// Computed on smoothed RMS, not the normalized display value.
  double get ildDb =>
      20 * (math.log((_lRms + 1e-6) / (_rRms + 1e-6)) / math.ln10);

  /// One poll. RMS → display: -48 dB..-6 dB maps onto 0..1.
  void update(double l, double r, List<int> ids, List<double> levels) {
    _lRms = _smooth(_lRms, l);
    _rRms = _smooth(_rRms, r);
    left = _norm(_lRms);
    right = _norm(_rRms);
    final seen = <int>{};
    for (var i = 0; i < ids.length && i < levels.length; i++) {
      seen.add(ids[i]);
      _src[ids[i]] = _smooth(
        _src[ids[i]] ?? 0,
        _norm(levels[i]),
      );
    }
    _src.removeWhere((id, _) => !seen.contains(id));
  }

  /// Engine stopped — ease everything toward silence so the HUD calms
  /// instead of freezing at the last level.
  void decay() {
    left = _smooth(left, 0);
    right = _smooth(right, 0);
    _lRms = 0;
    _rRms = 0;
    _src.updateAll((_, v) => v * 0.85);
    _src.removeWhere((_, v) => v < 0.02);
  }

  // Attack = instant (peak-like feel), release ≈ 250 ms at 33 ms polls.
  static double _smooth(double cur, double target) =>
      target > cur ? target : cur + (target - cur) * 0.12;

  static double _norm(double rms) =>
      ((20 * (math.log(rms + 1e-9) / math.ln10) + 48) / 42)
          .clamp(0.0, 1.0);
}
