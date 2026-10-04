import 'package:flutter/material.dart';

import '../rust/api/engine.dart';

/// Visual identity for a scene source. Compiled sources all arrive as
/// `kind: noise` dots — the name/sound text is what distinguishes fire
/// from kids from breeze, so the style key is the label, with the
/// procedural kind as the fallback for palette-added sources.
class SourceStyle {
  const SourceStyle(this.icon, this.color);
  final IconData icon;
  final Color color;
}

/// Keyword → (icon, color). First match wins — earlier rows are more
/// specific. Keywords mirror the compiler's concept groups so the names
/// Gemma emits (and the transition names like "fire_end") map cleanly.
/// (Not const: RegExp isn't const-constructible.)
final _table = <(RegExp, IconData, Color)>[
  (RegExp(r'fire|flame|campfire|bonfire|ember|hearth|fireplace|candle'),
      Icons.local_fire_department, Color(0xFFFF7043)),
  (RegExp(r'kid|child|toddler|playground|laugh|giggle|playing'),
      Icons.directions_run, Color(0xFF81C784)),
  (RegExp(r'wind|breeze|gust|gale|blizzard|draft|howl'), Icons.air,
      Color(0xFF90CAF9)),
  (RegExp(r'bee|wasp|mosquito|insect|buzz|dragonfly|gnat|flies'),
      Icons.emoji_nature, Color(0xFFFFC107)),
  (RegExp(r'rain|drizzle|downpour|shower|monsoon|sprinkle'), Icons.water_drop,
      Color(0xFF4FC3F7)),
  (RegExp(r'thunder|lightning|storm|rumble'), Icons.thunderstorm,
      Color(0xFF9575CD)),
  (RegExp(r'water|river|stream|ocean|sea\b|waves|lake|creek|waterfall|drip'),
      Icons.water, Color(0xFF4DD0E1)),
  (RegExp(r'bird|crow|owl|seagull|gull|sparrow|hawk|pigeon|rooster'),
      Icons.flutter_dash, Color(0xFF80CBC4)),
  (RegExp(r'dog|puppy|hound|bark'), Icons.pets, Color(0xFFA1887F)),
  (RegExp(r'cat|kitten|meow|purr'), Icons.cruelty_free, Color(0xFFCE93D8)),
  (RegExp(r'plane|airplane|jet\b|helicopter|chopper|drone|aircraft'),
      Icons.flight, Color(0xFFB0BEC5)),
  (RegExp(r'dragon|monster|beast|creature|roar'), Icons.whatshot,
      Color(0xFFEF5350)),
  (RegExp(r'chicken|hen|sizzle|roast|cooking|grill|barbecue|meat|steak'),
      Icons.outdoor_grill, Color(0xFFBCAAA4)),
  (RegExp(r'music|song|melody|guitar|piano|radio|drum|violin|band|jukebox'),
      Icons.music_note, Color(0xFFBA68C8)),
  (RegExp(r'voice|talk|whisper|crowd|people|conversation|chatter|person'),
      Icons.record_voice_over, Color(0xFF7986CB)),
  (RegExp(r'footstep|walking|steps\b|tread'), Icons.directions_walk,
      Color(0xFFAED581)),
  (RegExp(r'car\b|traffic|truck|bus\b|vehicle|motorcycle|scooter'),
      Icons.directions_car, Color(0xFF90A4AE)),
  (RegExp(r'train|locomotive|subway|metro'), Icons.train, Color(0xFF78909C)),
  (RegExp(r'bell|chime|alarm|siren|klaxon|horn'), Icons.notifications_active,
      Color(0xFFFFD54F)),
  (RegExp(r'clock|tick'), Icons.schedule, Color(0xFFB0BEC5)),
  (RegExp(r'cricket|night\b|nocturnal'), Icons.nights_stay, Color(0xFF5C6BC0)),
  (RegExp(r'frog|toad|croak'), Icons.spa, Color(0xFF9CCC65)),
  (RegExp(r'door|slam|creak'), Icons.meeting_room, Color(0xFF8D6E63)),
  (RegExp(r'heartbeat|breath|snore|sigh'), Icons.favorite, Color(0xFFF06292)),
  (RegExp(r'phone|ringing|vibrate'), Icons.phone_iphone, Color(0xFF64B5F6)),
  (RegExp(r'machine|engine|motor|factory|generator|hum\b|fan\b|vent'),
      Icons.settings, Color(0xFF90A4AE)),
  (RegExp(r'leaves|leaf|rustle|tree|forest|woods|jungle|branch'), Icons.park,
      Color(0xFF66BB6A)),
  (RegExp(r'wolf|coyote|owl'), Icons.dark_mode, Color(0xFF7E57C2)),
  (RegExp(r'keyboard|typing|typewriter|click'), Icons.keyboard,
      Color(0xFFA1887F)),
  (RegExp(r'gunshot|shot\b|bang|explosion|blast'), Icons.flash_on,
      Color(0xFFFF5722)),
  (RegExp(r'whistle'), Icons.sports, Color(0xFF4DB6AC)),
  (RegExp(r'scream|shout|yell|cry|crying|sob'), Icons.mood_bad,
      Color(0xFFE57373)),
  (RegExp(r'boat|ship|sail|anchor|foghorn|harbor'), Icons.directions_boat,
      Color(0xFF4DD0E1)),
  (RegExp(r'snow|winter|frost|ice\b'), Icons.ac_unit, Color(0xFF81D4FA)),
  (RegExp(r'cave|tunnel|echo|cavern'), Icons.terrain, Color(0xFF8D6E63)),
  (RegExp(r'saw\b|hammer|drill|construction|worksite'), Icons.build,
      Color(0xFFFFB74D)),
  (RegExp(r'church|organ|choir|hymn'), Icons.church, Color(0xFFBA68C8)),
  (RegExp(r'horse|gallop|hooves|neigh'), Icons.pets, Color(0xFF8D6E63)),
  (RegExp(r'whale|dolphin'), Icons.waves, Color(0xFF4DD0E1)),
];

/// Rotation palette for names no keyword claims — stable by label hash
/// so the same source keeps the same color across rebuilds.
const _fallbackColors = [
  Color(0xFFF06292),
  Color(0xFF4DD0E1),
  Color(0xFFAED581),
  Color(0xFF9575CD),
  Color(0xFFFFB74D),
  Color(0xFF64B5F6),
  Color(0xFFE57373),
  Color(0xFF4DB6AC),
];

/// Icon per procedural kind — used when the label matches no keyword.
IconData _kindIcon(SourceKindWire kind) => switch (kind) {
      SourceKindWire.bee => Icons.emoji_nature,
      SourceKindWire.rain => Icons.water_drop,
      SourceKindWire.pad => Icons.music_note,
      SourceKindWire.tone => Icons.graphic_eq,
      SourceKindWire.click => Icons.touch_app,
      SourceKindWire.noise => Icons.blur_on,
    };

/// Resolve the badge for a source: keyword match on the label first
/// ("fire_end" still reads as fire), else the kind's icon + a stable
/// hash color.
SourceStyle styleFor(String label, SourceKindWire kind) {
  final l = label.toLowerCase();
  for (final (re, icon, color) in _table) {
    if (re.hasMatch(l)) return SourceStyle(icon, color);
  }
  var h = 0;
  for (final c in l.codeUnits) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return SourceStyle(
    _kindIcon(kind),
    _fallbackColors[h % _fallbackColors.length],
  );
}
