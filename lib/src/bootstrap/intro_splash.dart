import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:spatial_audio_sandbox/src/listener/sandbox_page.dart';

/// Animated intro shown once at boot: the radar mark fades in while
/// pulse rings bloom outward (the 3D-sound cue), then the pipeline
/// chips land and the app fades through to the sandbox. Auto-advances
/// after [_holdMs]; a tap skips immediately. All animation is bounded —
/// no infinite repeaters — so the transition always completes.
class IntroSplashPage extends StatefulWidget {
  const IntroSplashPage({super.key});

  @override
  State<IntroSplashPage> createState() => _IntroSplashPageState();
}

class _IntroSplashPageState extends State<IntroSplashPage>
    with SingleTickerProviderStateMixin {
  static const _holdMs = 3000;
  late final AnimationController _ctl;
  Timer? _advanceTimer;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..forward();
    _advanceTimer = Timer(const Duration(milliseconds: _holdMs), _go);
  }

  void _go() {
    if (_gone || !mounted) return;
    _gone = true;
    _advanceTimer?.cancel();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, _, _) => const SandboxPage(),
        transitionsBuilder: (_, a, _, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _go,
      child: Scaffold(
        body: Center(
          child: Container(
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _ctl,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(flex: 3),
                    // Radar mark + expanding rings — the "sound around you"
                    // cue. Rings bloom once over the 1900ms controller.
                    SizedBox(
                      width: 260,
                      height: 260,
                      child: CustomPaint(
                        painter: _PulsePainter(_ctl.value),
                        child: Center(
                          child: Transform.scale(
                            scale: Curves.easeOutBack.transform(
                              Interval(0, 0.45).transform(_ctl.value),
                            ),
                            child: Opacity(
                              opacity: Interval(0, 0.3).transform(_ctl.value),
                              child: Image.asset(
                                'assets/branding/brand_mark.png',
                                width: 190,
                                height: 190,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _stage(
                      _ctl.value,
                      0.35,
                      0.7,
                      child: const Text(
                        'Spatial Audio Sandbox',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE6EBF2),
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    _stage(
                      _ctl.value,
                      0.45,
                      0.8,
                      child: const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'say a place — hear it around you',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF9AA4B2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    // The pipeline as chips — the story of the stack lands
                    // before the app does.
                    _stage(
                      _ctl.value,
                      0.55,
                      0.9,
                      child: const Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: [
                          _Chip(label: 'Gemma · Render'),
                          _Chip(label: 'ElevenLabs'),
                          _Chip(label: 'Rust · HRTF · 3D'),
                        ],
                      ),
                    ),
                    const Spacer(flex: 4),
                    _stage(
                      _ctl.value,
                      0.7,
                      1.0,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 26),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFF64D8CB)
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              child: const Text(
                                'Hacktoberfest Weekend Challenge',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF64D8CB),
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              'tap to continue',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF5A6470),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Fade + slight rise for each staged element inside [start..end] of
  /// the controller.
  Widget _stage(double t, double start, double end, {required Widget child}) {
    final v = Curves.easeOut.transform(
      Interval(start, end).transform(t).clamp(0.0, 1.0),
    );
    return Opacity(
      opacity: v,
      child: Transform.translate(
        offset: Offset(0, 10 * (1 - v)),
        child: child,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF16202B),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
      ),
    );
  }
}

/// Expanding concentric rings — three staggered pulses radiating from
/// the mark, like sources blooming outward in space.
class _PulsePainter extends CustomPainter {
  const _PulsePainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      // Staggered windows so rings chase each other outward.
      final start = 0.15 + i * 0.22;
      final end = math.min(start + 0.45, 1.0);
      if (t <= start || t >= end + 0.1) continue;
      final p = Interval(start, end).transform(t).clamp(0.0, 1.0);
      final r = 95 + 34 * Curves.easeOut.transform(p);
      final alpha = (1 - p) * 0.5;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF64D8CB).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t;
}
