// Another page hands a word to the chat composer — 技能 › 「在对话里用」 /
// 「新对话里用」 put `/name` there.
//
// The official client applies a skill as plain text, with no method of its
// own: picking it in the "/" menu writes `/name ` into the editor
// (dsh-client-ui-skill `onPick`), and the Host loads the skill from any
// whitespace-bounded `/name` in the message it receives (dsh-tool-skill, the
// "/name gesture"). The app does the same.

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show TextEditingValue, TextSelection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'phone_skill_use.dart';

/// The confirmation once the word is in the composer.
String get composerInsertedText => appL10n.stateComposerInserted;

/// A word waiting for the chat composer.
@immutable
class ComposerInsert {
  const ComposerInsert({required this.token, required this.sessionId, this.skill}) : phoneSkill = null;

  /// `/name` for [skill] in [sessionId]'s composer (null: a new conversation).
  const ComposerInsert.skill(String name, {required this.sessionId}) : token = '/$name', skill = name, phoneSkill = null;

  ComposerInsert.phoneRoute(PreparedPhoneSkill prepared)
      : token = '', sessionId = prepared.origin.sessionId, skill = null, phoneSkill = prepared;

  /// A route remains in a read-only in-memory card, never in the ordinary draft.
  final PreparedPhoneSkill? phoneSkill;

  /// Goes in at the caret as a word of its own.
  final String token;

  /// Whose composer: a conversation, or null for the new-chat screen.
  final String? sessionId;

  /// The skill [token] calls. Sending it is then always a message: a new
  /// conversation has no skill list yet, and the bare name must not be taken
  /// for a command that merely starts the same way.
  final String? skill;

  @override
  bool operator ==(Object other) =>
      other is ComposerInsert && other.token == token && other.sessionId == sessionId && other.skill == skill && identical(other.phoneSkill, phoneSkill);

  @override
  int get hashCode => Object.hash(token, sessionId, skill, phoneSkill);

  @override
  String toString() => 'ComposerInsert($token → ${sessionId ?? 'new'})';
}

/// One [ComposerInsert] at a time. The page that asks calls [request] and goes
/// back to the chat; the chat screen applies it and calls [take] (also on its
/// first frame, when it was asked before it was built).
class ComposerInsertController extends Notifier<ComposerInsert?> {
  PreparedPhoneSkill? _awaitingConsumer;
  @override
  ComposerInsert? build() {
    ref.onDispose(() {
      final pending = _awaitingConsumer;
      _awaitingConsumer = null;
      if (pending != null) unawaited(pending.discard());
    });
    return null;
  }

  void request(ComposerInsert insert) {
    final old = _awaitingConsumer;
    if (old != null && !identical(old, insert.phoneSkill)) unawaited(old.discard());
    _awaitingConsumer = insert.phoneSkill;
    state = insert;
  }

  /// The pending insert, once; clears it.
  ComposerInsert? take() {
    final insert = state;
    _awaitingConsumer = null;
    state = null;
    return insert;
  }
}

final composerInsertProvider = NotifierProvider<ComposerInsertController, ComposerInsert?>(
  ComposerInsertController.new,
);

/// [value] with [token] at the caret as a word of its own — the Host only
/// reads a `/name` with whitespace (or the ends of the text) on both sides:
///
/// - a space goes before it unless the caret starts the text or follows
///   whitespace;
/// - a space goes after it unless whitespace follows, and the caret ends up
///   after that space either way, ready for the request;
/// - no caret (never focused) means the end of the text; a selected range is
///   kept and the word goes after it;
/// - when the text already has [token] as a word, nothing is added and the
///   caret moves after it.
TextEditingValue insertComposerToken(TextEditingValue value, String token) {
  final text = value.text;
  final existing = _wordIndex(text, token);
  if (existing != null) {
    var end = existing + token.length;
    if (end < text.length && _isSpace(text, end)) end++;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: end),
    );
  }
  final selection = value.selection;
  final at = selection.isValid ? selection.end.clamp(0, text.length) : text.length;
  final before = at > 0 && !_isSpace(text, at - 1) ? ' ' : '';
  final spaceAfter = at < text.length && _isSpace(text, at);
  final insert = '$before$token${spaceAfter ? '' : ' '}';
  return TextEditingValue(
    text: text.replaceRange(at, at, insert),
    selection: TextSelection.collapsed(offset: at + insert.length + (spaceAfter ? 1 : 0)),
  );
}

final _space = RegExp(r'\s');

bool _isSpace(String text, int index) => _space.hasMatch(text[index]);

/// Where [token] stands as a whole word in [text], if it does.
int? _wordIndex(String text, String token) {
  if (token.isEmpty) return null;
  var from = 0;
  while (true) {
    final i = text.indexOf(token, from);
    if (i < 0) return null;
    final end = i + token.length;
    final startsWord = i == 0 || _isSpace(text, i - 1);
    final endsWord = end == text.length || _isSpace(text, end);
    if (startsWord && endsWord) return i;
    from = i + 1;
  }
}
