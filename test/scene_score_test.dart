import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/listener/scene_score.dart';

void main() {
  test('barRect maps cue/end onto the bar width', () {
    // 20 s scene, 200 px bar: a source from 2 s to 8 s spans 20–80 px.
    final r = SceneScore.barRect(
        barWidth: 200, lengthS: 20, startS: 2, endS: 8);
    expect(r.left, closeTo(20, 0.01));
    expect(r.right, closeTo(80, 0.01));
  });

  test('barRect never collapses below 2 px (instant one-shots)', () {
    final r = SceneScore.barRect(
        barWidth: 200, lengthS: 20, startS: 5, endS: 5);
    expect(r.width, greaterThanOrEqualTo(2));
  });

  testWidgets('score renders lanes and reports scrub positions',
      (tester) async {
    double? scrubbed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: SceneScore(
              lengthS: 20,
              positionS: 4,
              onScrubUpdate: (v) => scrubbed = v,
              lanes: const [
                ScoreLane(
                  name: 'rain',
                  icon: Icons.water_drop,
                  color: Colors.blue,
                  startS: 0,
                  endS: 20,
                  loop: true,
                ),
                ScoreLane(
                  name: 'bee',
                  icon: Icons.bug_report,
                  color: Colors.amber,
                  startS: 2,
                  endS: 8,
                  endsWithEvent: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('scene_score')), findsOneWidget);

    // Drag near the right edge of the bar area → position near the end.
    final box = tester.getRect(find.byKey(const ValueKey('scene_score')));
    await tester.dragFrom(
      Offset(box.left + 300, box.top + 9),
      const Offset(80, 0),
    );
    expect(scrubbed, isNotNull);
    expect(scrubbed!, greaterThan(10));
  });
}
