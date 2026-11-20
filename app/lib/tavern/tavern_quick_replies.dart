// 快速回复 (docs/design/roleplay-ui.md §6): lines you send often, one tap from
// the composer. Kept in preferences, the same for every chat; the quick
// replies a card carries come later, with the engine's support.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TavernQuickReplies extends Notifier<List<String>> {
  static const key = 'tavern.quickReplies';

  /// Set once the list has been read or changed: a late read never undoes an edit.
  bool _settled = false;

  @override
  List<String> build() {
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    List<String>? stored;
    try {
      stored = (await SharedPreferences.getInstance()).getStringList(key);
    } catch (_) {
      // No preferences backend (tests): none.
    }
    if (_settled) return;
    _settled = true;
    state = List.unmodifiable(stored ?? const <String>[]);
  }

  /// Replaces the list; blank lines are dropped.
  Future<void> set(List<String> replies) async {
    _settled = true;
    state = List.unmodifiable([
      for (final r in replies)
        if (r.trim().isNotEmpty) r,
    ]);
    try {
      await (await SharedPreferences.getInstance()).setStringList(key, state);
    } catch (_) {}
  }

  Future<void> add(String reply) => set([...state, reply]);

  Future<void> replaceAt(int index, String reply) => set([...state]..[index] = reply);

  Future<void> removeAt(int index) => set([...state]..removeAt(index));
}

final tavernQuickRepliesProvider = NotifierProvider<TavernQuickReplies, List<String>>(TavernQuickReplies.new);
