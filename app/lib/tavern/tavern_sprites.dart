// 视觉小说的表情图 (docs/design/roleplay-roadmap.md P1, T16f): a card's own
// `emotion` pictures stand in for the card face, one picked for each page by
// what its words show.

import 'package:dsh_tavern/dsh_tavern.dart';

import 'tavern_live2d.dart' show tavernEmotionIn;

/// [assets]' expression pictures on this phone, by name (lower case). Cards
/// call them `emotion` (V3) or, now and then, `expression`.
Map<String, String> tavernSprites(Iterable<TavernCharacterAsset>? assets) => {
  for (final a in assets ?? const <TavernCharacterAsset>[])
    if ((a.type == 'emotion' || a.type == 'expression') &&
        (a.localPath ?? '').isNotEmpty &&
        (a.name ?? '').trim().isNotEmpty)
      a.name!.trim().toLowerCase(): a.localPath!,
};

/// The picture for a page of hers: a sprite named in its words (the first
/// one), else one for the feeling the words show, else her neutral one;
/// null when the card has none of these (the card face then). A [marker]
/// ([表情:x], tavern_markers.dart) comes first: a sprite of that name, else
/// one for the feeling it names.
String? tavernSpriteFor(Map<String, String> sprites, String text, {String? marker}) {
  if (sprites.isEmpty) return null;
  if (marker != null) {
    if (sprites[marker.toLowerCase()] case final path?) return path;
    if (tavernEmotionIn(marker) case final feeling?) {
      for (final name in _names[feeling]!) {
        if (sprites[name] case final path?) return path;
      }
    }
  }
  final lower = text.toLowerCase();
  int? first;
  String? named;
  for (final MapEntry(key: name, value: path) in sprites.entries) {
    if (_neutral.contains(name)) continue;
    // A Latin name as a word ("joy", not "enjoy"); any other at least two characters long.
    final RegExp pattern;
    if (RegExp(r'^[a-z0-9_ -]+$').hasMatch(name)) {
      pattern = RegExp('\\b${RegExp.escape(name)}\\b');
    } else if (name.runes.length >= 2) {
      pattern = RegExp(RegExp.escape(name));
    } else {
      continue;
    }
    final at = pattern.firstMatch(lower)?.start;
    if (at != null && (first == null || at < first)) {
      first = at;
      named = path;
    }
  }
  if (named != null) return named;
  if (tavernEmotionIn(text) case final feeling?) {
    for (final name in _names[feeling]!) {
      if (sprites[name] case final path?) return path;
    }
  }
  for (final name in _neutral) {
    if (sprites[name] case final path?) return path;
  }
  return null;
}

/// What cards name the pictures for each feeling the words can show: ST's
/// expression labels first, then plain English and Chinese.
const _names = {
  'happy': ['joy', 'amusement', 'excitement', 'happy', 'smile', 'laugh', '开心', '高兴', '微笑', '笑'],
  'shy': ['embarrassment', 'shy', 'blush', '害羞', '脸红'],
  'surprised': ['surprise', 'realization', 'surprised', 'shock', '惊讶', '吃惊'],
  'angry': ['anger', 'annoyance', 'angry', 'mad', '生气', '愤怒'],
  'sad': ['sadness', 'grief', 'sad', 'cry', 'crying', '难过', '伤心', '哭'],
  'worried': ['nervousness', 'fear', 'worried', 'nervous', 'anxious', '担心', '紧张', '不安'],
  'confused': ['confusion', 'curiosity', 'confused', 'thinking', '疑惑', '困惑'],
};

const _neutral = ['neutral', 'default', 'idle', 'normal', 'calm', '平静', '默认', '正常'];
