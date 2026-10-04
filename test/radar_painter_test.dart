import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_audio_sandbox/src/listener/levels.dart';
import 'package:spatial_audio_sandbox/src/listener/sandbox_page.dart';
import 'package:spatial_audio_sandbox/src/rust/api/engine.dart';

void paintRadar({
  List<SourceDot> sources = const [],
  Map<int, BeaconState> beacons = const {},
  double headYaw = 0,
  double sceneT = 0,
  LevelsModel? levels,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  RadarPainter(
    sources: sources,
    beacons: beacons,
    headYaw: headYaw,
    rangeM: 5,
    sceneT: sceneT,
    levels: levels,
  ).paint(canvas, const Size(360, 360));
  recorder.endRecording();
}

void main() {
  test('paints an empty radar without throwing', () {
    paintRadar();
  });

  test('paints pending / ended / far / elevated / NaN dots', () {
    final dots = [
      // pending scheduled source (countdown label path)
      SourceDot(
        id: null,
        kind: SourceKindWire.noise,
        pos: const Offset(1.2, 0.4),
        delayS: 8,
        label: 'breeze',
      )..dueAt = DateTime.now().add(const Duration(seconds: 8)),
      // ended source (dimmed "· ended" label)
      SourceDot(
        id: null,
        kind: SourceKindWire.noise,
        pos: const Offset(-1.0, 0.5),
        label: 'fire',
        endS: 12,
      )..ended = true,
      // far source clamped to the rim
      SourceDot(
        id: 3,
        kind: SourceKindWire.noise,
        pos: const Offset(60, 0),
        label: 'thunder',
      ),
      // elevated source — stalk + floor shadow + ↑m
      SourceDot(
        id: 4,
        kind: SourceKindWire.bee,
        pos: const Offset(0.8, 0.8),
        z: 2.0,
        label: 'bee',
      ),
      // NaN position — must not crash the paint pass
      SourceDot(
        id: 5,
        kind: SourceKindWire.rain,
        pos: const Offset(double.nan, 0),
        label: 'glitch',
      ),
    ];
    paintRadar(sources: dots, sceneT: 2.0);
  });

  test('paints trails and level-reactive halos', () {
    final d = SourceDot(
      id: 7,
      kind: SourceKindWire.bee,
      pos: const Offset(0.5, 0.5),
      label: 'bee',
    );
    for (var i = 0; i < 20; i++) {
      d.pushTrail();
      d.pos += const Offset(0.05, 0.02);
    }
    final levels = LevelsModel()..update(0.35, 0.08, [7], [0.5]);
    paintRadar(sources: [d], levels: levels, headYaw: 0.6);
    expect(levels.ildDb, greaterThan(0));
    expect(levels.sourceLevel(7), greaterThan(0));
  });

  test('paints the surround energy ribbon with live levels', () {
    // Loud source ahead-left + quiet one behind: the ribbon must paint
    // without throwing and take the per-source level path.
    final dots = [
      SourceDot(
        id: 11,
        kind: SourceKindWire.rain,
        pos: const Offset(0.7, 0.7),
        label: 'rain',
      ),
      SourceDot(
        id: 12,
        kind: SourceKindWire.bee,
        pos: const Offset(-1.5, 0),
        label: 'bee',
      ),
    ];
    final levels = LevelsModel()..update(0.4, 0.1, [11, 12], [0.9, 0.05]);
    paintRadar(sources: dots, levels: levels);
    expect(levels.sourceLevel(11), greaterThan(0));
  });

  test('ribbon wave speed follows directional loudness', () {
    final m = LevelsModel();
    for (var i = 0; i < 20; i++) {
      m.update(0.3, 0.3, const [], const []);
      m.updateRibbon([(math.pi / 2, 0.9)], 0.033); // loud on the left
    }
    final left = LevelsModel.ribbonBin(math.pi / 2);
    final right = LevelsModel.ribbonBin(-math.pi / 2);
    expect(m.ribbonEnergy[left], greaterThan(0.5));
    expect(m.ribbonEnergy[right], lessThan(0.05));
    // Phase advanced ~9x faster on the loud side.
    expect(m.ribbonPhase[left], greaterThan(m.ribbonPhase[right] * 5));
  });

  test('LevelsModel ballistics: instant attack, smooth release, ILD', () {
    final m = LevelsModel();
    m.update(0.5, 0.05, const [], const []);
    expect(m.left, greaterThan(0.5)); // normalized -6..-48dB window
    expect(m.right, greaterThan(0));
    expect(m.ildDb, greaterThan(5));
    // Release: silence eases down over ticks, doesn't snap to zero.
    final peak = m.left;
    m.update(0, 0, const [], const []);
    expect(m.left, lessThan(peak));
    expect(m.left, greaterThan(0));
    for (var i = 0; i < 24; i++) {
      m.update(0, 0, const [], const []);
    }
    expect(m.left, lessThan(0.5));
    m.decay();
    m.decay();
    m.decay();
    expect(m.left, lessThan(0.3));
  });
}
