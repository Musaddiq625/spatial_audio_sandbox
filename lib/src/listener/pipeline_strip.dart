import 'dart:convert';

import 'package:flutter/material.dart';

import '../director/scene_director.dart';
import 'source_style.dart';

/// The four pipeline stages as live chips: Gemma on Render (thinking
/// time + streamed chars) → compiler repairs → ElevenLabs clip progress
/// → the Rust engine. Words in the prompt that became sources are
/// highlighted in the source's own color below the strip.
class PipelineStrip extends StatelessWidget {
  const PipelineStrip({
    super.key,
    required this.describing,
    this.describeSeconds = 0,
    this.llmChars = 0,
    this.specSeconds,
    this.spec,
    this.prompt,
    this.clipDone = 0,
    this.clipTotal = 0,
    this.clipGenerating = false,
    required this.engineOn,
    required this.sourceCount,
    this.onViewSpec,
  });

  final bool describing;
  final double describeSeconds;
  final int llmChars;
  final double? specSeconds;
  final SceneSpec? spec;
  final String? prompt;
  final int clipDone;
  final int clipTotal;
  final bool clipGenerating;
  final bool engineOn;
  final int sourceCount;
  final VoidCallback? onViewSpec;

  @override
  Widget build(BuildContext context) {
    final stages = <Widget>[
      _stage(
        icon: Icons.auto_awesome,
        name: 'Gemma · Render',
        state: describing
            ? 'thinking ${describeSeconds.toStringAsFixed(0)}s'
                '${llmChars > 0 ? ' · ${(llmChars / 1000).toStringAsFixed(1)}k' : ''}'
            : specSeconds != null
                ? 'spec in ${specSeconds!.toStringAsFixed(0)}s'
                : 'idle',
        tone: describing
            ? _Tone.busy
            : specSeconds != null
                ? _Tone.done
                : _Tone.idle,
      ),
      _stage(
        icon: Icons.account_tree_outlined,
        name: 'compiler',
        state: spec == null
            ? '—'
            : spec!.report.fallback
                ? 'keyword fallback'
                : (spec!.report.summary(spec!.sources.length) ?? 'clean'),
        tone: spec == null
            ? _Tone.idle
            : spec!.report.dropped.isNotEmpty || spec!.report.fallback
                ? _Tone.warn
                : _Tone.done,
      ),
      _stage(
        icon: Icons.graphic_eq,
        name: 'ElevenLabs',
        state: clipTotal == 0
            ? '—'
            : clipGenerating
                ? '$clipDone/$clipTotal…'
                : '$clipDone/$clipTotal ready',
        tone: clipTotal == 0
            ? _Tone.idle
            : clipGenerating
                ? _Tone.busy
                : _Tone.done,
      ),
      _stage(
        icon: Icons.memory,
        name: 'Rust HRTF',
        state: engineOn ? 'live · $sourceCount src' : 'off',
        tone: engineOn ? _Tone.done : _Tone.idle,
      ),
      if (onViewSpec != null && spec != null)
        IconButton(
          key: const ValueKey('view_spec'),
          tooltip: 'view spec JSON',
          onPressed: onViewSpec,
          icon: const Icon(Icons.data_object, size: 16),
          visualDensity: VisualDensity.compact,
          color: const Color(0xFF5A6470),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: _withChevrons(stages)),
        ),
        if (prompt != null && spec != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text.rich(
              TextSpan(children: _highlight(prompt!, spec!)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9AA4B2)),
            ),
          ),
      ],
    );
  }

  static List<Widget> _withChevrons(List<Widget> stages) {
    final out = <Widget>[];
    for (var i = 0; i < stages.length; i++) {
      if (i > 0) {
        if (stages[i] is IconButton) {
          out.add(stages[i]);
          continue;
        }
        out.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 1),
          child: Icon(Icons.chevron_right, size: 12, color: Color(0xFF3A4552)),
        ));
      }
      out.add(stages[i]);
    }
    return out;
  }

  /// Words in the prompt that became sources get the source's color —
  /// the grounding the compiler enforced, made visible.
  static List<TextSpan> _highlight(String prompt, SceneSpec spec) {
    const stop = {'the', 'a', 'an', 'and', 'of', 'in', 'on', 'at', 'to',
      'my', 'me', 'i', 'am', 'is', 'it', 'some', 'end', 'out'};
    final wordColor = <String, Color>{};
    for (final s in spec.sources) {
      final c = styleFor(s.name, s.kind).color;
      for (final tok in s.name.toLowerCase().split(RegExp(r'[^a-z]+'))) {
        if (tok.length >= 3 && !stop.contains(tok)) {
          wordColor.putIfAbsent(tok, () => c);
        }
      }
    }
    final spans = <TextSpan>[];
    for (final m in RegExp(r'[a-zA-Z]+|[^a-zA-Z]+').allMatches(prompt)) {
      final w = m.group(0)!;
      final c = wordColor[w.toLowerCase()];
      spans.add(TextSpan(
        text: w,
        style: c == null
            ? null
            : TextStyle(color: c, fontWeight: FontWeight.w700),
      ));
    }
    return spans;
  }
}

enum _Tone { idle, busy, done, warn }

Widget _stage({
  required IconData icon,
  required String name,
  required String state,
  required _Tone tone,
}) {
  final color = switch (tone) {
    _Tone.idle => const Color(0xFF5A6470),
    _Tone.busy => const Color(0xFFFFB74D),
    _Tone.done => const Color(0xFF81C784),
    _Tone.warn => const Color(0xFFFFB74D),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.25)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(
          '$name ',
          style: TextStyle(fontSize: 10, color: color),
        ),
        Text(
          state,
          style: TextStyle(
            fontSize: 10,
            color: color.withValues(alpha: 0.85),
            fontFamily: 'monospace',
          ),
        ),
      ],
    ),
  );
}

/// Pretty-printed spec for the "view spec JSON" sheet — the exact JSON
/// the compiler produced (what refine() echoes back to the model).
String specPrettyJson(SceneSpec spec) =>
    const JsonEncoder.withIndent('  ')
        .convert(SceneDirector.specToJson(spec));
