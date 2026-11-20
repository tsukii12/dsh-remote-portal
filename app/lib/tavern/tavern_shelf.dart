// 书架 (docs/design/roleplay-roadmap.md P1): how the characters are ordered
// and which are kept at the front. Kept on this phone, not in the tavern.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 最近聊过 (the engine's own order: newest chat, else newest import), by
/// name, or 最近导入.
enum TavernShelfOrder { recent, name, imported }

class TavernShelf {
  const TavernShelf({this.order = TavernShelfOrder.recent, this.favorites = const {}});

  final TavernShelfOrder order;

  /// Character ids kept first.
  final Set<String> favorites;

  TavernShelf copyWith({TavernShelfOrder? order, Set<String>? favorites}) =>
      TavernShelf(order: order ?? this.order, favorites: favorites ?? this.favorites);
}

/// [characters] as the shelf shows them: favourites first, each part in
/// [shelf]'s order. Equal keys keep the list's own order.
List<TavernCharacter> tavernShelfSort(List<TavernCharacter> characters, TavernShelf shelf) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime recent(TavernCharacter c) => c.lastChatAt ?? c.importedAt ?? epoch;
  int byOrder(TavernCharacter a, TavernCharacter b) => switch (shelf.order) {
    TavernShelfOrder.recent => recent(b).compareTo(recent(a)),
    TavernShelfOrder.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    TavernShelfOrder.imported => (b.importedAt ?? epoch).compareTo(a.importedAt ?? epoch),
  };
  final indexed = characters.indexed.toList()
    ..sort((x, y) {
      final (i, a) = x;
      final (j, b) = y;
      final fa = shelf.favorites.contains(a.id), fb = shelf.favorites.contains(b.id);
      if (fa != fb) return fa ? -1 : 1;
      final c = byOrder(a, b);
      return c != 0 ? c : i.compareTo(j);
    });
  return [for (final (_, c) in indexed) c];
}

class TavernShelfController extends Notifier<TavernShelf> {
  static const orderKey = 'tavern.shelf.order';
  static const favoritesKey = 'tavern.shelf.favorites';

  /// Set once changed here: a late read never undoes it.
  var _changed = false;

  @override
  TavernShelf build() {
    unawaited(_load());
    return const TavernShelf();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loaded = TavernShelf(
        order: TavernShelfOrder.values.asNameMap()[prefs.getString(orderKey)] ?? TavernShelfOrder.recent,
        favorites: {...?prefs.getStringList(favoritesKey)},
      );
      if (!_changed && ref.mounted) state = loaded;
    } catch (_) {
      // No preferences backend (tests): the defaults.
    }
  }

  Future<void> setOrder(TavernShelfOrder order) async {
    _changed = true;
    state = state.copyWith(order: order);
    await _save((prefs) => prefs.setString(orderKey, order.name));
  }

  Future<void> setFavorite(String characterId, bool favorite) async {
    _changed = true;
    final favorites = {...state.favorites};
    favorite ? favorites.add(characterId) : favorites.remove(characterId);
    state = state.copyWith(favorites: favorites);
    await _save((prefs) => prefs.setStringList(favoritesKey, favorites.toList()..sort()));
  }

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }
}

final tavernShelfProvider = NotifierProvider<TavernShelfController, TavernShelf>(TavernShelfController.new);
