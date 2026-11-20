// 资源库 › 世界书 › one book (docs/design/roleplay-ui.md §9): its entries by
// order, a switch each, one opened in the same editor a card's book uses, a
// new one added, an old one deleted. The book is read whole (lorebook) and
// written whole (putLorebook); a book kept in ST's own world-info shape is
// turned into the editor's field names and back (tavern_book_entry.dart).

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_book_entry.dart';
import '../../tavern/tavern_provider.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_lorebook_page.dart';
import 'tavern_lorebooks_page.dart';

/// A library book as the page shows it: its name, whether it is kept in ST's
/// own shape, and its entries (in the card's field names) highest order first.
typedef TavernLibraryBook = ({String name, bool native, List<TavernBookEntry> entries});

/// [raw]'s entries where they are kept: ST's own map by uid, or a list.
Object? _entriesOf(Map<String, Object?> raw) => raw['entries'];

final tavernLibraryBookProvider = FutureProvider.autoDispose.family<TavernLibraryBook?, String>((ref, id) async {
  ref.watch(tavernLorebooksProvider);
  final tavern = ref.watch(tavernProvider);
  final raw = await tavern.lorebook(id);
  if (raw == null) return null;
  final summaries = (await tavern.listLorebooks()).where((b) => b.id == id);
  final entries = _entriesOf(raw);
  final native = entries is Map;
  final List<TavernBookEntry> list = switch (entries) {
    final Map<String, Object?> byUid => [
      for (final (i, e) in byUid.values.indexed)
        if (e is Map<String, Object?>) (index: i, entry: tavernNativeToCard(e)),
    ],
    final List<Object?> items => [
      for (final (i, e) in items.indexed)
        if (e is Map<String, Object?>) (index: i, entry: e),
    ],
    _ => [],
  };
  num order(TavernBookEntry e) => switch (e.entry['insertion_order']) {
    final num n => n,
    _ => 0,
  };
  // Stable: equal orders keep the book's own order.
  final sorted = [...list]..sort((a, b) => order(b).compareTo(order(a)));
  final name = summaries.firstOrNull?.name ?? (raw['name'] is String ? raw['name']! as String : id);
  return (name: name, native: native, entries: sorted);
});

/// A library book: each edit reads the whole book, changes the one entry (in
/// its own shape) and writes the whole book back.
class TavernLibraryBookHome implements TavernEntryHome {
  const TavernLibraryBookHome(this.bookId);

  final String bookId;

  Future<void> _edit(Tavern tavern, void Function(Map<String, Object?> raw) change) async {
    final stored = await tavern.lorebook(bookId);
    if (stored == null) throw StateError('The lorebook is gone.');
    // A copy to change: what the engine handed out stays as it was.
    final raw = jsonDecode(jsonEncode(stored)) as Map<String, Object?>;
    change(raw);
    await tavern.putLorebook(bookId, raw);
  }

  @override
  Future<void> add(Tavern tavern, Map<String, Object?> entry) => _edit(tavern, (raw) {
    switch (_entriesOf(raw)) {
      case final Map<String, Object?> byUid:
        // The next free uid, as ST numbers them.
        final used = [
          for (final e in byUid.values)
            if (e case {'uid': final int uid}) uid,
        ];
        final uid = [...used, ...byUid.keys.map(int.tryParse).nonNulls].fold(-1, (a, b) => a > b ? a : b) + 1;
        byUid['$uid'] = {'uid': uid, ...tavernCardToNative(entry), 'displayIndex': byUid.length};
      case final List<Object?> items:
        items.add(entry);
      default:
        raw['entries'] = {
          '0': {'uid': 0, ...tavernCardToNative(entry), 'displayIndex': 0},
        };
    }
  });

  @override
  Future<void> update(Tavern tavern, int index, Map<String, Object?> changes) => _edit(tavern, (raw) {
    switch (_entriesOf(raw)) {
      case final Map<String, Object?> byUid:
        final key = byUid.keys.elementAt(index);
        byUid[key] = tavernMergeEntry(byUid[key]! as Map<String, Object?>, tavernCardToNative(changes));
      case final List<Object?> items:
        items[index] = tavernMergeEntry(items[index]! as Map<String, Object?>, changes);
      default:
        throw RangeError.index(index, const [], 'index');
    }
  });

  @override
  Future<void> delete(Tavern tavern, int index) => _edit(tavern, (raw) {
    switch (_entriesOf(raw)) {
      case final Map<String, Object?> byUid:
        byUid.remove(byUid.keys.elementAt(index));
      case final List<Object?> items:
        items.removeAt(index);
      default:
        throw RangeError.index(index, const [], 'index');
    }
  });

  @override
  void refresh(WidgetRef ref) => ref
    ..invalidate(tavernLorebooksProvider)
    ..invalidate(tavernLibraryBookProvider(bookId));
}

class TavernLibraryBookPage extends ConsumerWidget {
  const TavernLibraryBookPage({super.key, required this.bookId});

  final String bookId;

  static Route<void> route(String bookId) =>
      MaterialPageRoute<void>(builder: (_) => TavernLibraryBookPage(bookId: bookId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final home = TavernLibraryBookHome(bookId);
    final book = ref.watch(tavernLibraryBookProvider(bookId)).value;
    void open(TavernBookEntry? entry) =>
        unawaited(Navigator.of(context).push(TavernLorebookEntryPage.routeIn(home, entry: entry)));
    Future<void> setEnabled(int index, bool on) async {
      await home.update(ref.read(tavernProvider), index, {'enabled': on});
      home.refresh(ref);
    }

    return AppPage.list(
      title: book?.name ?? l10n.tavernLorebook,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-library-book-add'),
          icon: AppIcons.add,
          tooltip: l10n.tavernLorebookAdd,
          onPressed: () => open(null),
        ),
      ],
      children: [
        if (book == null)
          const QuietSpinner()
        else if (book.entries.isEmpty)
          Padding(
            key: const ValueKey('tavern-library-book-empty'),
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
            child: Text(
              l10n.tavernLorebookStart,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
            ),
          )
        else
          SettingsSection(
            key: const ValueKey('tavern-library-book'),
            title: l10n.tavernLorebookEntries(book.entries.length),
            footer: Text(l10n.tavernLibraryBookNote),
            children: [
              for (final (i, e) in book.entries.indexed)
                TavernBookEntryRow(
                  key: ValueKey('tavern-library-entry-$i'),
                  entry: e.entry,
                  onOpen: () => open(e),
                  onEnabled: (on) => unawaited(setEnabled(e.index, on)),
                ),
            ],
          ),
      ],
    );
  }
}
