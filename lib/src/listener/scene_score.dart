import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// One lane of the scene score: the window of master-scene time during
/// which a source is audible. Looping clips hatch; authored end events
/// get a flag; sources that have ended go dim.
class ScoreLane {
  const ScoreLane({
    required this.name,
    required this.icon,
    required this.color,
    required this.startS,
    required this.endS,
    this.loop = false,
    this.pending = false,
    this.ended = false,
    this.isFile = false,
    this.endsWithEvent = false,
  });

  final String name;
  final IconData icon;
  final Color color;

  /// Cue-in time on the master clock.
  final double startS;

  /// Audible end: authored endS, else cue+clip length, else scene end.
  final double endS;

  /// The clip repeats within its window — drawn as hatching.
  final bool loop;
  final bool pending;
  final bool ended;

  /// A decoded file clip (solid bar) vs a procedural stand-in (dashed).
  final bool isFile;

  /// endS came from an authored end event — flag marker.
  final bool endsWithEvent;
}

/// A multi-lane timeline — one lane per authored source — that doubles
/// as the master scrubber. Drag horizontally to seek; the same two-phase
/// scrub protocol as the old thin slider.
class SceneScore extends StatelessWidget {
  const SceneScore({
    super.key,
    required this.lanes,
    required this.lengthS,
    required this.positionS,
    this.onScrubStart,
    this.onScrubUpdate,
    this.onScrubEnd,
  });

  static const double gutterW = 22;
  static const double laneH = 18;
  static const double topPad = 7;

  final List<ScoreLane> lanes;
  final double lengthS;
  final double positionS;
  final VoidCallback? onScrubStart;
  final ValueChanged<double>? onScrubUpdate;
  final ValueChanged<double>? onScrubEnd;

  /// Pure layout for tests: the bar rect of a lane given the drawing
  /// width (excluding the icon gutter).
  static Rect barRect({
    required double barWidth,
    required double lengthS,
    required double startS,
    required double endS,
  }) {
    final x0 = (startS / lengthS) * barWidth;
    final x1 = (endS / lengthS) * barWidth;
    return Rect.fromLTRB(x0, 0, math.max(x1, x0 + 2), laneH - 6);
  }

  @override
  Widget build(BuildContext context) {
    final h = topPad + lanes.length * laneH;
    return LayoutBuilder(
      builder: (context, cons) {
        final barW = cons.maxWidth - gutterW;
        double posOf(double dx) =>
            ((dx - gutterW) / barW).clamp(0.0, 1.0) * lengthS;
        return GestureDetector(
          key: const ValueKey('scene_score'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragDown: (d) {
            onScrubStart?.call();
            onScrubUpdate?.call(posOf(d.localPosition.dx));
          },
          onHorizontalDragUpdate: (d) =>
              onScrubUpdate?.call(posOf(d.localPosition.dx)),
          onHorizontalDragEnd: (_) => onScrubEnd?.call(positionS),
          onTapDown: (d) {
            onScrubStart?.call();
            onScrubUpdate?.call(posOf(d.localPosition.dx));
            onScrubEnd?.call(posOf(d.localPosition.dx));
          },
          child: CustomPaint(
            size: Size(cons.maxWidth, h),
            painter: _ScorePainter(
              lanes: lanes,
              lengthS: lengthS,
              positionS: positionS,
            ),
          ),
        );
      },
    );
  }
}

class _ScorePainter extends CustomPainter {
  _ScorePainter({
    required this.lanes,
    required this.lengthS,
    required this.positionS,
  });

  final List<ScoreLane> lanes;
  final double lengthS;
  final double positionS;

  @override
  void paint(Canvas canvas, Size size) {
    final barW = size.width - SceneScore.gutterW;
    final laneArea = Rect.fromLTWH(
        SceneScore.gutterW, 0, barW, size.height - SceneScore.topPad);

    // Quarter-time ticks + labels.
    for (var q = 0; q <= 4; q++) {
      final x = SceneScore.gutterW + barW * q / 4;
      canvas.drawLine(
        Offset(x, size.height - SceneScore.topPad + 1),
        Offset(x, size.height - 1),
        Paint()..color = const Color(0xFF2A323E),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '${(lengthS * q / 4).toStringAsFixed(0)}s',
          style: const TextStyle(fontSize: 7, color: Color(0xFF5A6470)),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas,
          Offset(
              (x - tp.width / 2).clamp(SceneScore.gutterW.toDouble(),
                  size.width - tp.width),
              size.height - SceneScore.topPad));
    }

    for (var i = 0; i < lanes.length; i++) {
      final lane = lanes[i];
      final y = i * SceneScore.laneH;
      final local = SceneScore.barRect(
          barWidth: barW,
          lengthS: lengthS,
          startS: lane.startS,
          endS: lane.endS);
      final rect = local.translate(SceneScore.gutterW, y + 3);
      final alpha = lane.ended ? 0.22 : lane.pending ? 0.35 : 0.55;

      // Icon in the gutter.
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(lane.icon.codePoint),
          style: TextStyle(
            fontFamily: lane.icon.fontFamily,
            package: lane.icon.fontPackage,
            fontSize: 12,
            color: lane.color.withValues(alpha: lane.ended ? 0.4 : 0.9),
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset((SceneScore.gutterW - tp.width) / 2, y + 3));

      // Baseline track for the lane.
      canvas.drawRect(
        Rect.fromLTWH(SceneScore.gutterW, rect.center.dy - 0.5, barW, 1),
        Paint()..color = const Color(0xFF1A212B),
      );

      final fill = Paint()
        ..color = lane.color.withValues(alpha: alpha);
      canvas.drawRect(rect, fill);

      // Loop hatching.
      if (lane.loop) {
        canvas.save();
        canvas.clipRect(rect);
        final hatch = Paint()
          ..color = lane.color.withValues(alpha: alpha + 0.25)
          ..strokeWidth = 1;
        for (var x = rect.left - rect.height;
            x < rect.right;
            x += 5) {
          canvas.drawLine(Offset(x, rect.bottom),
              Offset(x + rect.height, rect.top), hatch);
        }
        canvas.restore();
      }

      // Stand-in (procedural) border vs decoded-file solid.
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = lane.color.withValues(alpha: lane.isFile ? 0.9 : 0.45);
      canvas.drawRect(rect, border);

      // End-event flag.
      if (lane.endsWithEvent) {
        final fx = rect.right;
        final flag = Path()
          ..moveTo(fx, rect.top - 4)
          ..lineTo(fx + 5, rect.top - 1)
          ..lineTo(fx, rect.top + 2)
          ..close();
        canvas.drawPath(
            flag, Paint()..color = lane.color);
        canvas.drawLine(Offset(fx, rect.top - 4), Offset(fx, rect.bottom),
            Paint()
              ..color = lane.color.withValues(alpha: 0.8)
              ..strokeWidth = 1);
      }
    }

    // Playhead + grabber.
    final px = SceneScore.gutterW + barW * (positionS / lengthS);
    canvas.drawLine(
      Offset(px, 0),
      Offset(px, size.height - SceneScore.topPad),
      Paint()
        ..color = const Color(0xFF64D8CB)
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(Offset(px, 2.5), 2.5,
        Paint()..color = const Color(0xFF64D8CB));
    canvas.drawRect(
        laneArea,
        Paint()
          ..color = Colors.transparent);
  }

  @override
  bool shouldRepaint(_ScorePainter old) =>
      old.positionS != positionS || old.lanes != lanes;
}
