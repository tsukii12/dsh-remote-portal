// What a character's model brings of its own: its expressions and motions
// (model3.json), with the names the person gave them and whether the AI may
// use them. Any model, not only hers: these are what make an imported model
// more than a face that follows the cursor. The stage plays them by their raw
// names (stage.js `playMotion`, own expressions); the AI writes the labels as
// marks, `[表情:脸红]` or `[动作:挥手]`, like her built-in ones.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_reply.dart';

/// What the stage found in the model when it loaded.
@immutable
class CompanionModelInfo {
  const CompanionModelInfo({this.expressions = const [], this.motions = const []});

  final List<String> expressions;
  final List<String> motions;

  static CompanionModelInfo fromMessage(Map<Object?, Object?> message) {
    List<String> names(Object? value) => [
      if (value is List)
        for (final name in value)
          if (name is String && name.isNotEmpty) name,
    ];
    return CompanionModelInfo(expressions: names(message['expressions']), motions: names(message['motions']));
  }
}

enum CompanionMoveKind { expression, motion }

@immutable
class CompanionMove {
  const CompanionMove({required this.kind, required this.raw, required this.label, required this.ai});

  final CompanionMoveKind kind;

  /// Its name in the model, which the stage plays it by.
  final String raw;

  /// What the AI and the person call it.
  final String label;

  /// Whether the AI is told it may use it.
  final bool ai;

  CompanionMove copyWith({String? label, bool? ai}) =>
      CompanionMove(kind: kind, raw: raw, label: label ?? this.label, ai: ai ?? this.ai);
}

/// A readable name for one of a model's own: no folder, no `.exp3.json`, no
/// leading numbering (`04 脸红` → `脸红`).
String companionMoveLabel(String raw) {
  var name = raw.split('/').last;
  name = name.replaceAll(RegExp(r'\.(exp3|motion3)\.json$', caseSensitive: false), '');
  name = name.replaceFirst(RegExp(r'^[\s\d_\-.]+'), '').trim();
  return name.isEmpty ? raw : name;
}

/// Parts a model switches on and off (a hidden tail, a watermark) rather than
/// feelings: the AI isn't offered them unless the person says so.
final _switchLike = RegExp(r'消失|隐藏|水印|切换|开关|显示|hide|toggle|switch|watermark|\boff\b', caseSensitive: false);

/// A model's idle loops: hers is her own, so they aren't offered either.
final _idleLike = RegExp(r'^idle', caseSensitive: false);

/// A name that reads as a word (`脸红`, `TapBody`), not a glyph (`》《`, `X X`):
/// only those are offered to the AI unless the person renames them.
final _wordLike = RegExp(r'\p{L}{2,}', unicode: true);

@immutable
class CompanionMoves {
  const CompanionMoves({this.expressions = const [], this.motions = const []});

  final List<CompanionMove> expressions;
  final List<CompanionMove> motions;

  bool get isEmpty => expressions.isEmpty && motions.isEmpty;

  /// The model's moves, named and allowed as the person left them ([saved]), or
  /// as the model names them.
  static CompanionMoves from(CompanionModelInfo info, Map<String, Object?> saved) {
    CompanionMove move(CompanionMoveKind kind, String raw) {
      final key = _key(kind, raw);
      final kept = saved[key];
      final label = companionMoveLabel(raw);
      final suggested =
          _wordLike.hasMatch(label) &&
          (kind == CompanionMoveKind.expression ? !_switchLike.hasMatch(label) : !_idleLike.hasMatch(raw));
      return CompanionMove(
        kind: kind,
        raw: raw,
        label: kept is Map && kept['label'] is String && (kept['label'] as String).trim().isNotEmpty
            ? (kept['label'] as String).trim()
            : label,
        ai: kept is Map && kept['ai'] is bool ? kept['ai'] as bool : suggested,
      );
    }

    return CompanionMoves(
      expressions: _distinct([for (final raw in info.expressions) move(CompanionMoveKind.expression, raw)]),
      motions: _distinct([for (final raw in info.motions) move(CompanionMoveKind.motion, raw)]),
    );
  }

  /// Two moves of a kind never share a label (a mark could only reach one of
  /// them): later ones get a number, `脸红 2`.
  static List<CompanionMove> _distinct(List<CompanionMove> moves) {
    final taken = <String>{};
    return [
      for (final m in moves)
        () {
          var label = m.label;
          for (var n = 2; taken.contains(label.toLowerCase()); n++) {
            label = _numbered(m.label, n);
          }
          taken.add(label.toLowerCase());
          return label == m.label ? m : m.copyWith(label: label);
        }(),
    ];
  }

  static String _key(CompanionMoveKind kind, String raw) => '${kind == CompanionMoveKind.expression ? 'e' : 'm'}:$raw';

  /// [next] in place of the move it renames or switches; a label another move
  /// of its kind already has gets a number.
  CompanionMoves replaced(CompanionMove next) {
    final others = next.kind == CompanionMoveKind.expression ? expressions : motions;
    final taken = {
      for (final m in others)
        if (m.raw != next.raw) m.label.toLowerCase(),
    };
    var label = next.label;
    for (var n = 2; taken.contains(label.toLowerCase()); n++) {
      label = _numbered(next.label, n);
    }
    final settled = label == next.label ? next : next.copyWith(label: label);
    return CompanionMoves(
      expressions: [for (final m in expressions) m.kind == settled.kind && m.raw == settled.raw ? settled : m],
      motions: [for (final m in motions) m.kind == settled.kind && m.raw == settled.raw ? settled : m],
    );
  }

  /// [label] with a number after it, cut short so a mark can still carry it.
  static String _numbered(String label, int n) {
    final suffix = ' $n';
    final room = 40 - suffix.length;
    if (label.length <= room) return '$label$suffix';
    // Whole characters only (an emoji is two code units).
    final kept = StringBuffer();
    for (final c in label.characters) {
      if (kept.length + c.length > room) break;
      kept.write(c);
    }
    return '${kept.toString().trimRight()}$suffix';
  }

  /// How many of each kind the AI is told about, at most.
  static const most = 24;

  /// Whether this one is offered to the AI: allowed, and not a name one of her
  /// own marks already answers to.
  static bool _offered(CompanionMove m) =>
      m.ai &&
      companionMarkLabelFits(m.label) &&
      !companionMarkKnown(
        m.kind == CompanionMoveKind.expression ? CompanionMarkKind.emotion : CompanionMarkKind.action,
        m.label,
      );

  /// The ones the AI is told about: allowed, readable, the first [most].
  Iterable<CompanionMove> get offeredExpressions => expressions.where(_offered).take(most);
  Iterable<CompanionMove> get offeredMotions => motions.where(_offered).take(most);

  /// Label → raw name, for the marks the AI may write: exactly the ones it was told.
  Map<String, String> get emotionLabels => {for (final m in offeredExpressions) m.label: m.raw};

  Map<String, String> get actionLabels => {for (final m in offeredMotions) m.label: m.raw};

  /// Told to the AI after her built-in marks; null when nothing is offered.
  String? rules() {
    final faces = [for (final m in offeredExpressions) '[表情:${m.label}]'];
    final moves = [for (final m in offeredMotions) '[动作:${m.label}]'];
    if (faces.isEmpty && moves.isEmpty) return null;
    return [
      '这个角色还有自己的表情和动作，同样写成标记，界面会执行：',
      if (faces.isNotEmpty) '- 表情：${faces.join(' ')}',
      if (moves.isNotEmpty) '- 动作：${moves.join(' ')}',
    ].join('\n');
  }

  /// Changes whenever what the AI is told changes.
  String get fingerprint => (rules() ?? '').hashCode.toString();

  /// The fingerprint of telling nothing.
  static String get noneFingerprint => ''.hashCode.toString();

  Map<String, Object?> toJson() => {
    for (final m in [...expressions, ...motions]) _key(m.kind, m.raw): {'label': m.label, 'ai': m.ai},
  };
}

String _prefsKey(String character) => 'companion_moves_${base64Url.encode(utf8.encode(character))}';

/// What the person set for [character]'s own moves.
Future<Map<String, Object?>> companionMovesSaved(String character) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey(character));
    final decoded = raw == null ? null : jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : const {};
  } on Object {
    return const {};
  }
}

Future<void> companionMovesSave(String character, CompanionMoves moves) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey(character), jsonEncode(moves.toJson()));
}
