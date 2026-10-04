import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../rust/api/engine.dart';
import 'motion.dart';
import 'scene_director.dart';

/// A "screenplay" source — what the LLM emits. Fixed-choice fields only;
/// the compiler turns them into geometry and validates them against the
/// user's prompt. The model names and describes; the compiler decides
/// numbers, so the model can't hallucinate azimuths or motions.
class ScreenplaySource {
  String name = '';
  String sound = '';
  String role = 'object';
  String place = 'front';
  String distance = 'near';
  String movement = 'still';
  String start = 'beginning';
  double startS = 0;
  String ends = 'never';
  double endS = 0;
  bool loop = true;
}

class Screenplay {
  String? environment;
  final sources = <ScreenplaySource>[];
}

/// Screenplay → compiled [SceneSpec]. Pure functions for testability.
class SceneCompiler {
  // ── fixed-choice tables ──────────────────────────────────────────

  static const roles = {
    'ambience', 'object', 'creature', 'person', 'vehicle', 'weather',
    'event',
  };
  static const places = {
    'front', 'front_left', 'left', 'back_left', 'behind', 'back_right',
    'right', 'front_right', 'above', 'around',
  };
  static const distances = {'close', 'near', 'far'};
  static const movements = {
    'still', 'wander', 'circle', 'approach', 'pass_left_to_right',
    'pass_right_to_left', 'pass_overhead',
  };
  static const starts = {'beginning', 'after_seconds', 'later'};
  static const endings = {'never', 'after_seconds', 'with_event'};

  static const _placeAz = {
    'front': 0.0, 'front_left': 45.0, 'left': 90.0, 'back_left': 135.0,
    'behind': 180.0, 'back_right': -135.0, 'right': -90.0,
    'front_right': -45.0, 'above': 0.0, 'around': 0.0,
  };
  static const _distM = {'close': 0.6, 'near': 1.8, 'far': 6.0};

  /// Words that anchor a source at a place, checked in the prompt clause
  /// BEFORE the model's place is trusted (explicit words win).
  static final _spatialWords = [
    (RegExp(r'in front|ahead|facing'), 'front'),
    (RegExp(r'behind|at my back'), 'behind'),
    (RegExp(r'to my left|on my left|left of me|left side'), 'left'),
    (RegExp(r'to my right|on my right|right of me|right side'), 'right'),
    (RegExp(r'above|overhead|over my head|in the sky'), 'above'),
    (RegExp(r'all around|everywhere|surrounds|around me'), 'around'),
  ];

  /// Motion verbs. Matched against the clause the source lives in — no
  /// verb, no motion, no matter what the model emitted.
  static final _motionWords = [
    (RegExp(r'circl|orbit|around my head|around me\b.*(?:fly|buzz|insect|bee|mosquito)'), 'circle'),
    (RegExp(r'run(?:ning|s)? around|chasing|running about|wander|roam|moving around|playing around'), 'wander'),
    (RegExp(r'approach|coming (?:closer|toward|at me)|getting closer|walks? toward'), 'approach'),
    (RegExp(r'left to right|l-?to-?r'), 'pass_left_to_right'),
    (RegExp(r'right to left|r-?to-?l'), 'pass_right_to_left'),
    (RegExp(r'overhead|over my head|above me.*(?:fly|pass|cross)|fly(?:ing)? over|passes? overhead'), 'pass_overhead'),
    (RegExp(r'fly(?:ing|ies|s)? (?:past|by)|flies? (?:past|by)|passes? (?:by|past)|go(?:es)? (?:past|by)|swoops? (?:past|by)|crosses?\b|sweep'), 'pass'),
  ];

  /// End-of-life verbs — the source stops sounding at that scene time.
  static final _endPattern = RegExp(
    r'(go(?:es)? out|dies? down|dies?|stops?|fades? (?:away|out)|'
    r'burns? out|falls? silent|goes? quiet|is put out|'
    r'gets? extinguished|fizzles? out|turns? off|shuts? off)',
    caseSensitive: false,
  );

  /// Noun→concept groups. A source is grounded if any word in its name
  /// or sound shares a group with a word in the prompt (or appears
  /// verbatim). Keeps "campfire" grounding to "fire".
  static const _concepts = [
    ['fire', 'campfire', 'flame', 'flames', 'bonfire', 'hearth', 'embers',
      'fireplace', 'candle'],
    ['kid', 'kids', 'children', 'child', 'youth', 'toddler', 'playground'],
    ['wind', 'breeze', 'gust', 'gusts', 'draft', 'gale', 'storm', 'blizzard',
      'howl'],
    ['bee', 'bees', 'wasp', 'fly', 'flies', 'mosquito', 'insect', 'bug',
      'buzz', 'dragonfly', 'gnat'],
    ['rain', 'drizzle', 'downpour', 'shower', 'monsoon', 'sprinkles'],
    ['water', 'river', 'stream', 'ocean', 'sea', 'waves', 'waterfall',
      'lake', 'creek', 'brook', 'trickle', 'splash'],
    ['bird', 'birds', 'crow', 'owl', 'seagull', 'gull', 'gulls', 'sparrow',
      'hawk', 'pigeon', 'duck', 'rooster'],
    ['dog', 'puppy', 'hound', 'bark', 'barking'],
    ['cat', 'kitten', 'meow', 'purr'],
    ['car', 'vehicle', 'truck', 'bus', 'traffic', 'motorcycle', 'scooter',
      'motorbike'],
    ['plane', 'airplane', 'jet', 'aircraft', 'helicopter', 'chopper',
      'drone'],
    ['chicken', 'hen', 'meat', 'sizzle', 'roast', 'cooking', 'grill',
      'barbecue', 'bbq', 'steak', 'fish', 'sausage'],
    ['music', 'song', 'melody', 'guitar', 'piano', 'radio', 'drum', 'drums',
      'violin', 'band', 'tune', 'jukebox'],
    ['people', 'crowd', 'person', 'voices', 'voice', 'someone', 'everyone',
      'audience', 'chatter', 'talking', 'conversation'],
    ['footsteps', 'steps', 'walking', 'treading'],
    ['door', 'doors', 'slam', 'creak'],
    ['thunder', 'lightning', 'rumble', 'storm'],
    ['dragon', 'monster', 'beast', 'creature', 'roar'],
    ['cricket', 'crickets', 'night', 'nocturnal'],
    ['frog', 'frogs', 'toad', 'croak'],
    ['siren', 'alarm', 'horn', 'klaxon', 'bell', 'bells', 'chime', 'chimes'],
    ['clock', 'tower', 'tick', 'ticking'],
    ['train', 'locomotive', 'rail', 'subway', 'metro'],
    ['boat', 'ship', 'harbor', 'sail', 'anchor', 'foghorn'],
    ['leaves', 'leaf', 'rustle', 'forest', 'trees', 'branch', 'woods',
      'jungle'],
    ['snow', 'winter', 'frost', 'ice'],
    ['cave', 'tunnel', 'echo', 'cavern', 'drip', 'dripping'],
    ['whistle', 'whistling'],
    ['glass', 'bottle', 'clink'],
    ['wood', 'log', 'logs', 'timber', 'split'],
    ['wolf', 'howl', 'wolves', 'coyote'],
    ['horse', 'gallop', 'hooves', 'neigh'],
    ['cow', 'moo', 'cattle'],
    ['sheep', 'lamb', 'baa'],
    ['pig', 'oink'],
    ['mouse', 'squeak', 'rat', 'rodent'],
    ['snake', 'hiss', 'rattle'],
    ['lion', 'tiger', 'roar', 'growl'],
    ['elephant', 'trumpet'],
    ['monkey', 'ape', 'chatter'],
    ['whale', 'dolphin'],
    ['gunshot', 'shot', 'bang', 'explosion', 'blast'],
    ['scream', 'screaming', 'shout', 'yell'],
    ['laugh', 'laughter', 'giggle'],
    ['cry', 'crying', 'sob', 'weep'],
    ['cough', 'sneeze'],
    ['snore', 'snoring'],
    ['breath', 'breathing', 'sigh'],
    ['typing', 'keyboard', 'typewriter', 'click'],
    ['phone', 'ring', 'ringing', 'vibrate', 'buzz'],
    ['machine', 'engine', 'motor', 'factory', 'generator', 'hum'],
    ['fan', 'vent', 'air conditioner', 'ac'],
    ['water', 'faucet', 'tap', 'shower', 'bath'],
    ['saw', 'hammer', 'drill', 'construction', 'worksite'],
    ['church', 'organ', 'choir', 'hymn'],
    ['desert', 'dune', 'sand'],
    ['mountain', 'peak', 'summit', 'cliff'],
    ['crow', 'rooster', 'hen', 'farm', 'barnyard'],
  ];

  static const _stopwords = {
    'the', 'a', 'an', 'and', 'of', 'in', 'on', 'at', 'to', 'for', 'with',
    'my', 'me', 'i', 'is', 'it', 'some', 'sound', 'audio', 'ambience',
    'noise', 'kind', 'type', 'sounds', 'playing', 'over', 'under',
  };

  // ── screenplay parsing ───────────────────────────────────────────

  /// Parse the model's screenplay JSON. Throws [SpecException] on
  /// anything unusable. Values outside the fixed lists fall back to
  /// role-based defaults (the grammar should prevent them anyway).
  static Screenplay parseScreenplay(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'^```(?:json)?\s*|\s*```$'), '');
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw SpecException('no JSON object in output');
    }
    Object? decoded;
    final slice = cleaned.substring(start, end + 1);
    try {
      decoded = jsonDecode(slice);
    } catch (_) {
      decoded = _repairedDecode(slice);
    }
    if (decoded is! Map || decoded['sources'] is! List) {
      throw SpecException('missing "sources" array');
    }
    final list = decoded['sources'] as List;
    if (list.isEmpty) throw SpecException('empty scene');
    if (list.length > 10) throw SpecException('too many sources (max 10)');

    final sp = Screenplay();
    final env = decoded['environment'];
    if (env is String && env.trim().isNotEmpty) {
      sp.environment = env.trim();
    }
    final seenNames = <String>{};
    for (final (i, e) in list.indexed) {
      if (e is! Map) throw SpecException('source $i is not an object');
      var name = (e['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) name = 'source$i';
      while (!seenNames.add(name)) {
        name = '${name}_'; // dedupe
      }
      final s = ScreenplaySource()
        ..name = name
        ..sound = ((e['sound'] as String?) ?? '').trim()
        ..role = _pick(e['role'], roles, 'object')
        ..place = _pick(e['place'], places, 'front')
        ..distance = _pick(e['distance'], distances, 'near')
        ..movement = _pick(e['movement'], movements, 'still')
        ..start = _pick(e['start'], starts, 'beginning')
        ..startS = _num(e['start_s'], 0)
        ..ends = _pick(e['ends'], endings, 'never')
        ..endS = _num(e['end_s'], 0)
        ..loop = e['loop'] is bool ? e['loop'] as bool : true;
      sp.sources.add(s);
    }
    return sp;
  }

  /// JSON decode fallback: a screenplay cut off mid-array still yields
  /// its complete sources — cut at the last fully-closed source object
  /// (depth back to 2) and close the document.
  static Object? _repairedDecode(String slice) {
    var depth = 0, lastGood = -1;
    var inStr = false, esc = false;
    for (var i = 0; i < slice.length; i++) {
      final ch = slice[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (ch == '\\') {
        if (inStr) esc = true;
        continue;
      }
      if (ch == '"') {
        inStr = !inStr;
        continue;
      }
      if (inStr) continue;
      if (ch == '{' || ch == '[') depth++;
      if (ch == '}' || ch == ']') {
        depth--;
        if (depth == 2 && ch == '}') lastGood = i;
      }
    }
    if (lastGood < 0) throw SpecException('malformed JSON');
    try {
      final d = jsonDecode('${slice.substring(0, lastGood + 1)}]}');
      debugPrint('[compiler] repaired truncated screenplay');
      return d;
    } catch (_) {
      throw SpecException('malformed JSON');
    }
  }

  static String _pick(Object? v, Set<String> allowed, String dflt) {
    final s = (v as String?)?.toLowerCase().trim();
    return s != null && allowed.contains(s) ? s : dflt;
  }

  static double _num(Object? v, double dflt) =>
      (v is num) ? v.toDouble() : dflt;

  // ── prompt clause analysis ───────────────────────────────────────

  /// Split the prompt into clauses — sentences plus sequencing
  /// conjunctions, so "kids play behind me, and then a plane crosses"
  /// becomes two clauses with separate spatial/timing contexts. Each
  /// clause reports whether a sequencing word ("then", "after that",
  /// "meanwhile") split it off — "then the lights go out" keeps its
  /// later-in-the-scene meaning even though the word itself was the
  /// delimiter.
  static List<({String text, bool sequenced})> _splitClauses(
      String prompt) {
    final re = RegExp(
        r'[.!?;]|\band then\b|\bthen\b|\bafter that\b|\bmeanwhile\b');
    final out = <({String text, bool sequenced})>[];
    var last = 0, seq = false;
    final p = prompt.toLowerCase();
    for (final m in re.allMatches(p)) {
      final part = p.substring(last, m.start).trim();
      if (part.isNotEmpty) out.add((text: part, sequenced: seq));
      final sep = m.group(0)!;
      seq = sep.contains('then') ||
          sep.contains('after that') ||
          sep.contains('meanwhile');
      last = m.end;
    }
    final tail = p.substring(last).trim();
    if (tail.isNotEmpty) out.add((text: tail, sequenced: seq));
    return out;
  }

  /// Clause texts only — for grounding and motion checks.
  static List<String> clauses(String prompt) =>
      _splitClauses(prompt).map((c) => c.text).toList();

  /// Tokens that can ground a source — from its name and sound.
  static List<String> _sourceTokens(ScreenplaySource s) {
    final raw = '${s.name} ${s.sound}'.toLowerCase();
    return raw
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.length >= 3 && !_stopwords.contains(w))
        .toSet()
        .toList();
  }

  /// Does [word] appear in [text], directly or via a shared concept
  /// group? Word-boundary match — "car" doesn't hit "cart".
  static bool _wordIn(String word, String text) {
    if (RegExp('\\b${RegExp.escape(word)}s?\\b').hasMatch(text)) {
      return true;
    }
    for (final g in _concepts) {
      if (g.contains(word) || g.contains('${word}s')) {
        if (g.any((w) => RegExp('\\b${RegExp.escape(w)}s?\\b')
            .hasMatch(text))) {
          return true;
        }
      }
    }
    return false;
  }

  /// Two words are related when equal, plural-linked, or in the same
  /// concept group — "kids"~children, "fire"~campfire.
  static bool _related(String a, String b) {
    if (a == b || '${a}s' == b || a == '${b}s') return true;
    for (final g in _concepts) {
      if ((g.contains(a) || g.contains('${a}s')) &&
          (g.contains(b) || g.contains('${b}s'))) {
        return true;
      }
    }
    return false;
  }

  /// Does a motion verb at [vStart..vEnd] in [clause] have [s] as its
  /// subject? "kids running around the campfire" — running's subject
  /// is the kids, not the campfire. The subject is the content-word
  /// phrase immediately before the verb (or after it, for verb-first
  /// clauses like "running water").
  static bool _subjectMatches(
      String clause, int vStart, int vEnd, ScreenplaySource s) {
    List<String> content(String text) => text
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.length >= 3 && !_stopwords.contains(w))
        .toList();
    var subject = content(clause.substring(0, vStart));
    if (subject.length > 3) subject = subject.sublist(subject.length - 3);
    if (subject.isEmpty) {
      subject = content(clause.substring(vEnd)).take(3).toList();
    }
    final toks = _sourceTokens(s);
    return subject.any((w) => toks.any((t) => _related(w, t)));
  }

  /// The first motion verb in the clause whose subject is this source.
  /// A verb describing a different noun can't move this source — this
  /// is what stops a "fire in front" from inheriting "running around".
  static String? _clauseMovement(String clause, ScreenplaySource s) {
    for (final (re, mv) in _motionWords) {
      final m = re.firstMatch(clause);
      if (m == null) continue;
      if (_subjectMatches(clause, m.start, m.end, s)) return mv;
    }
    return null;
  }

  /// The fragment inside [clauseIdx] that names this source — comma
  /// fragments scope spatial words and timing so "a dog barking to my
  /// right, pigeons close in front" doesn't bleed "in front" onto the
  /// dog.
  static _Frag? _fragFor(
      ScreenplaySource s, int clauseIdx, List<_Frag> frags) {
    final toks = _sourceTokens(s);
    final inClause = frags.where((f) => f.clauseIdx == clauseIdx).toList();
    if (inClause.isEmpty) return null;
    _Frag? best = inClause.last;
    var hits = 0;
    for (final f in inClause) {
      final h = toks.where((t) => _wordIn(t, f.text)).length;
      if (h >= hits && h > 0) {
        hits = h;
        best = f;
      }
    }
    return best;
  }

  /// Spatial text for a fragment: its own comma-fragment, extended one
  /// fragment back when it carries no spatial word — "behind me, some
  /// kids are playing" keeps "behind" attached to the kids.
  static String _spatialCtx(_Frag? frag, List<_Frag> frags) {
    if (frag == null) return '';
    var ctx = frag.text;
    if (!_spatialWords.any((w) => w.$1.hasMatch(ctx))) {
      final idx = frags.indexOf(frag);
      if (idx > 0 && frags[idx - 1].clauseIdx == frag.clauseIdx) {
        ctx = '${frags[idx - 1].text},$ctx';
      }
    }
    return ctx;
  }

  /// The clause index a source's tokens live in, or -1 when nothing in
  /// the prompt mentions it — i.e. the model invented it.
  static int _matchClause(ScreenplaySource s, List<String> clauses) {
    final toks = _sourceTokens(s);
    if (toks.isEmpty) return -1;
    var best = -1, bestHits = 0;
    for (var i = 0; i < clauses.length; i++) {
      final hits = toks.where((t) => _wordIn(t, clauses[i])).length;
      if (hits > bestHits) {
        best = i;
        bestHits = hits;
      }
    }
    return bestHits > 0 ? best : -1;
  }

  // ── compile ──────────────────────────────────────────────────────

  /// Turn a validated screenplay into a [SceneSpec]. [prompt] grounds
  /// every source: unmentioned sources are dropped, explicit spatial
  /// words override the model's place, and motion requires a verb.
  /// [extraGround] lets refine() pass existing scene names so they
  /// aren't dropped when the follow-up prompt doesn't re-mention them.
  static SceneSpec compile(
    Screenplay sp,
    String prompt, {
    List<String> extraGround = const [],
  }) {
    final clsRec = _splitClauses(prompt);
    final cls = clsRec.map((c) => c.text).toList();
    final spec = SceneSpec(<SpecSource>[])
      ..environment = sp.environment;
    final out = <SpecSource>[];

    // Timing words (or an end-event) make this a timed scene. Without
    // them the model's start/end fields are untrusted — a screenplay
    /// can't invent timing the user never asked for.
    final timed = RegExp(r'\b(after|then|later|suddenly|eventually)\b',
            caseSensitive: false)
            .hasMatch(prompt.toLowerCase()) ||
        cls.any(_endPattern.hasMatch);

    // Fragment-level times. Comma fragments inside each clause share
    // the running time unless they carry their own marker — "beside a
    // lake, after 3 seconds thunder" times the thunder at 3s, not the
    // lake. Markers stagger by +4 s; an explicit "after N" sets N.
    final frags = <_Frag>[];
    var last = 0.0;
    for (var ci = 0; ci < cls.length; ci++) {
      final sequenced = clsRec[ci].sequenced;
      var first = true;
      for (final f in cls[ci].split(',')) {
        final afterN =
            RegExp(r'after\s*(\d+(?:\.\d+)?)', caseSensitive: false)
                .firstMatch(f);
        double t;
        bool marker;
        if (afterN != null) {
          last = double.parse(afterN.group(1)!);
          t = last;
          marker = true;
        } else if (RegExp(
                r'after a while|a bit later|\blater\b|eventually|'
                r'suddenly|after that|meanwhile',
                caseSensitive: false)
            .hasMatch(f)) {
          last += 4;
          t = last;
          marker = true;
        } else if (sequenced && first) {
          // Clause opened by "then"/"after that" — the split word was
          // the marker; stagger this fragment's time.
          last += 4;
          t = last;
          marker = true;
        } else {
          t = last;
          marker = false;
        }
        frags.add(_Frag(ci, f, t, marker));
        first = false;
      }
    }

    for (final s in sp.sources) {
      final ci = _matchClause(s, cls);
      final grounded = ci >= 0 ||
          extraGround.any((n) => _wordIn(n, '${s.name} ${s.sound}'.toLowerCase())) ||
          extraGround.any((n) => _sourceTokens(s).any((t) => _wordIn(t, n)));
      if (!grounded) {
        debugPrint('[compiler] dropped "${s.name}": not in prompt');
        continue;
      }
      final clause = ci >= 0 ? cls[ci] : '';
      final frag = _fragFor(s, ci, frags);
      final compiled = _compileSource(
        s,
        clause,
        _spatialCtx(frag, frags),
        timed ? (frag?.time ?? 0) : 0,
        timed: timed,
        marked: frag?.marker ?? false,
      );
      out.add(compiled);
    }

    // Events: "<noun> goes out / dies / stops" in a fragment → end_s on
    // the *nearest-named* compiled source + a transition one-shot at
    // its position and the fragment's scene time.
    if (timed) {
      for (final f in frags) {
        final m = _endPattern.firstMatch(f.text);
        if (m == null) continue;
        final subject = f.text.substring(0, m.start);
        // The dying thing is the source named closest to the verb —
        // "a cold breeze comes and the fire goes out" ends the fire,
        // not the breeze.
        final words = subject.split(RegExp(r'[^a-z]+'));
        SpecSource? target;
        var best = -1;
        for (final c in out) {
          var lastHit = -1;
          final toks = _sourceTokens2(c);
          for (var i = 0; i < words.length; i++) {
            if (words[i].length >= 3 &&
                toks.any((t) => _related(words[i], t))) {
              lastHit = i;
            }
          }
          if (lastHit > best) {
            best = lastHit;
            target = c;
          }
        }
        final t = f.time;
        if (target != null) {
          target.endS = math.max(t, target.delayS + 1);
          debugPrint('[compiler] ${target.name} ends at ${target.endS}s');
        }
        final name = target?.name ?? _nounBefore(subject);
        out.add(SpecSource(
          name: '${name}_end',
          kind: SourceKindWire.noise,
          azDeg: target?.azDeg ?? 0,
          elDeg: target?.elDeg ?? 0,
          distM: target?.distM ?? 1.5,
          gain: 0.9,
          sound: '${target?.sound ?? name} dying out, fading away',
          loop: false,
          durationS: 4,
          delayS: t,
        ));
        debugPrint('[compiler] transition one-shot "${name}_end" at ${t}s');
      }
    }

    // Fallback: nothing grounded — build procedural sources from nouns
    // the prompt actually contains, so the scene isn't empty.
    if (out.isEmpty) {
      debugPrint('[compiler] zero grounded sources — keyword fallback');
      out.addAll(_fallbackSources(cls));
    }

    // A "with_event" marker that no end-clause resolved means the model
    // expected an event that isn't there — treat it as never-ending.
    for (final s in out) {
      if (s.endS == -1) s.endS = null;
    }
    spec.sources.addAll(out);
    return spec;
  }

  static List<String> _sourceTokens2(SpecSource s) =>
      '${s.name} ${s.sound ?? ''}'
          .toLowerCase()
          .split(RegExp(r'[^a-z]+'))
          .where((w) => w.length >= 3 && !_stopwords.contains(w))
          .toList();

  /// Last content-word before an end verb — names the transition clip.
  static String _nounBefore(String subject) {
    final ws = subject
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.length >= 3 && !_stopwords.contains(w))
        .toList();
    return ws.isEmpty ? 'sound' : ws.last;
  }

  static SpecSource _compileSource(
      ScreenplaySource s, String clause, String spatialCtx,
      double fragTime,
      {required bool timed, required bool marked}) {
    // Place: explicit spatial words in the source's fragment override
    // the model's choice.
    var place = s.place;
    for (final (re, pl) in _spatialWords) {
      if (re.hasMatch(spatialCtx)) {
        place = pl;
        break;
      }
    }
    final az = _placeAz[place] ?? 0;
    final el = place == 'above' ? 60.0 : 0.0;
    final isBed = s.role == 'ambience' || s.role == 'weather' ||
        place == 'around';
    var dist = _distM[s.distance] ?? 1.8;
    if (isBed && dist < 2) dist = 2.5;

    // Movement: only a verb whose subject is THIS source can move it —
    // the model's movement is a hint, never trusted on its own.
    var movement = _clauseMovement(clause, s) ?? 'still';
    if (movement == 'pass') {
      movement = switch (s.movement) {
        'pass_left_to_right' || 'pass_right_to_left' ||
        'pass_overhead' =>
          s.movement,
        _ => 'pass_left_to_right', // "past" without direction
      };
    }
    if (isBed && movement != 'still' && movement != 'circle') {
      movement = 'still'; // beds never chase/traverse
    }
    if (s.movement != movement && s.movement != 'still') {
      debugPrint(
        '[compiler] ${s.name}: movement "${s.movement}" → "$movement" '
        '(clause check)',
      );
    }

    // Timing: 'beginning' means 0 unless the source's fragment itself
    // carries a sequencing marker (the model mislabeled a "then X"
    // source); 'later' uses the fragment's staggered time.
    final delay = !timed
        ? 0.0
        : switch (s.start) {
            'after_seconds' => s.startS.clamp(0, 120),
            'later' => fragTime > 0 ? fragTime : 4.0,
            _ => marked ? fragTime : 0.0,
          };
    final isEvent = s.role == 'event';
    final loop = isEvent ? false : s.loop;

    final src = SpecSource(
      name: s.name,
      kind: _kindFor(s),
      azDeg: az,
      elDeg: el,
      distM: dist,
      gain: isBed ? 0.8 : 0.9,
      sound: s.sound.isEmpty ? s.name : s.sound,
      loop: loop,
      durationS: isEvent ? 4 : (loop ? 8 : 5),
      delayS: delay.toDouble(),
    );
    src.endS = !timed
        ? null
        : switch (s.ends) {
            'after_seconds' => s.endS.clamp(0, 600).toDouble(),
            'with_event' => -1, // marker — resolved by the event pass
            _ => null,
          };
    _attachMotion(src, movement, place, az, el, dist);
    return src;
  }

  static void _attachMotion(SpecSource s, String movement, String place,
      double az, double el, double dist) {
    switch (movement) {
      case 'wander':
        s.wander = WanderMotion(
          anchorAzDeg: az,
          anchorElDeg: el,
          anchorDistM: dist,
          azSpanDeg: 30,
          distSpanM: 0.4,
          periodS: 7,
        );
      case 'circle':
        // Head-centered only when the source is all around; otherwise
        // the circle is centered on its anchor ("around the fire").
        s.orbit = OrbitMotion(
          radiusM: place == 'around' ? 0.8 : 0.6,
          periodS: place == 'around' ? 12 : 8,
          centerAzDeg: place == 'around' ? 0 : az,
          centerDistM: place == 'around' ? 0 : dist,
        );
      case 'approach':
        s.approach = ApproachMotion(
          fromAzDeg: az,
          fromDistM: 8,
          seconds: 8,
        );
      case 'pass_left_to_right':
        s.traverse = TraverseMotion(
          fromAzDeg: -80, toAzDeg: 80, distM: dist, seconds: 6,
        );
      case 'pass_right_to_left':
        s.traverse = TraverseMotion(
          fromAzDeg: 80, toAzDeg: -80, distM: dist, seconds: 6,
        );
      case 'pass_overhead':
        s.elDeg = 45;
        s.traverse = TraverseMotion(
          fromAzDeg: -80, toAzDeg: 80, distM: dist, seconds: 6,
        );
    }
  }

  /// Procedural stand-in kind from role + vocabulary — the spec still
  /// needs a kind until the generated clip lands.
  static SourceKindWire _kindFor(ScreenplaySource s) {
    final t = '${s.name} ${s.sound}'.toLowerCase();
    bool has(List<String> ws) =>
        ws.any((w) => RegExp('\\b$w').hasMatch(t));
    if (has(['rain', 'drizzle', 'downpour', 'monsoon'])) {
      return SourceKindWire.rain;
    }
    if (has(['bee', 'wasp', 'mosquito', 'buzz', 'fly', 'insect'])) {
      return SourceKindWire.bee;
    }
    if (has(['music', 'melody', 'choir', 'hymn', 'pad', 'hum'])) {
      return SourceKindWire.pad;
    }
    if (has(['tone', 'beep', 'sine', 'alarm', 'whistle'])) {
      return SourceKindWire.tone;
    }
    return SourceKindWire.noise;
  }

  /// Last-resort sources built purely from prompt vocabulary — used
  /// when the model returns nothing grounded.
  static List<SpecSource> _fallbackSources(List<String> cls) {
    final out = <SpecSource>[];
    var i = 0;
    for (final c in cls) {
      for (final g in _concepts) {
        final hit = g.firstWhere(
          (w) => RegExp('\\b${RegExp.escape(w)}s?\\b').hasMatch(c),
          orElse: () => '',
        );
        if (hit.isEmpty) continue;
        var az = 0.0;
        for (final (re, pl) in _spatialWords) {
          if (re.hasMatch(c)) {
            az = _placeAz[pl] ?? 0;
            break;
          }
        }
        out.add(SpecSource(
          name: hit,
          kind: SourceKindWire.noise,
          azDeg: az,
          distM: 1.8,
          sound: hit,
          loop: true,
          durationS: 8,
          delayS: i == 0 ? 0 : i * 4.0,
        ));
        i++;
        break; // one source per clause
      }
    }
    return out;
  }
}

/// A comma-fragment inside a clause: the unit that scopes a source's
/// spatial words and scene time. [marker] = the fragment carries its
/// own sequencing word ("after N", "then", "later").
class _Frag {
  _Frag(this.clauseIdx, this.text, this.time, this.marker);
  final int clauseIdx;
  final String text;
  final double time;
  final bool marker;
}
