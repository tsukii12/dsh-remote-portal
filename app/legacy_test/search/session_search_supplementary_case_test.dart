import 'package:dsh_app/state/session_search.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

// Deseret letters have real case pairs above the BMP. Each letter occupies
// two UTF-16 units in a title/query, unlike the uncased emoji control.
const _upper = '\u{10400}\u{10401}\u{10427}';
const _lower = '\u{10428}\u{10429}\u{1044F}';
const _changedQueries = [
  ('ASCII repeated phrase', 'A a', 'a'),
  ('supplementary repeated phrase', '\u{10400} \u{10428}', '\u{10428}'),
  ('full-width word', 'Ａ', 'A'),
  ('full-width word with supplementary case', 'Ａ \u{10400}', 'A \u{10428}'),
];

void main() {
  test('supplementary case folding retains original UTF-16 offsets', () {
    const text = 'Ａ$_upper😀Ü';
    final folded = foldForSearch(text);
    expect(folded, 'a$_lower😀ü');
    expect(folded.length, text.length);
    expect(foldForSearch(folded), folded);
  });

  test('a short lowercase query finds uppercase titles and folders', () {
    final at = DateTime(2026, 11, 4);
    final results = deriveSessionSearchResults(
      query: _lower,
      sessions: [
        searchSession('title', 'Notes $_upper', at, cwd: '/work/plain'),
        searchSession('folder', 'Other notes', at, cwd: '/work/$_upper'),
        searchSession('unrelated', 'Unrelated', at, cwd: '/work/plain'),
      ],
    );
    expect(results.showFolders, isTrue);
    expect(results.active.map((r) => r.session.sessionId).toSet(), {'title', 'folder'});
    expect(results.active.every((r) => r.byTitle), isTrue);
  });

  test('highlight ranges still index complete letters in the original text', () {
    const text = 'X\u{10400}😀\u{10401}Y';
    final ranges = matchRanges(text, searchTerms('\u{10428} \u{10429}'));
    expect(ranges, [(start: 1, end: 3), (start: 5, end: 7)]);
    expect([for (final range in ranges) text.substring(range.start, range.end)], ['\u{10400}', '\u{10401}']);
  });

  test('equivalent supplementary case queries deduplicate and reuse content hits', () {
    expect(searchTerms('$_upper $_lower Ａ'), [_lower, 'a']);
    expect(sameSearchQuery(_upper, _lower), isTrue);
    final result = deriveSessionSearchResults(
      query: _lower,
      sessions: [searchSession('content', 'Other title', DateTime(2026))],
      contentQuery: _upper,
      hits: const [(sessionId: 'content', snippet: 'A matching message')],
    );
    expect(result.active.single.session.sessionId, 'content');
    expect(result.active.single.byTitle, isFalse);
  });

  test('BMP letters, full width, emoji and unpaired units keep their behavior', () {
    expect(foldForSearch('ＡＰＩ Key　登录Ü'), 'api key 登录ü');
    expect(foldForSearch('a😀B'), 'a😀b');
    const unpaired = '\uD801x\uDC00';
    expect(foldForSearch(unpaired), unpaired);
    expect(foldForSearch(''), isEmpty);
    expect(sameSearchQuery('  A\tA　b ', 'a a b'), isTrue);
    expect(sameSearchQuery('a b', 'b a'), isFalse);
  });

  // The Host uses a literal FTS phrase: two occurrences of the same folded
  // word can find fewer documents than one. Local title terms may deduplicate,
  // but the controller must ask again when the phrase's multiplicity changes.
  for (final (label, previous, query) in _changedQueries) {
    testWidgets('changing $label requests content again', (tester) async {
      const two = (sessionId: 'two', snippet: 'two word occurrences');
      const one = (sessionId: 'one', snippet: 'one word occurrence');
      final backend = FakeContentSearch(
        results: {
          previous: (items: [two], hasMore: false),
          query: (items: [one, two], hasMore: false),
        },
      );
      final container = ProviderContainer(overrides: [sessionContentSearchProvider.overrideWithValue(backend)]);
      addTearDown(container.dispose);
      container.listen(sessionSearchProvider, (_, _) {});
      final controller = container.read(sessionSearchProvider.notifier);
      controller.setInput(TextEditingValue(text: previous));
      await tester.pump(SessionSearchController.debounce);
      expect(container.read(sessionSearchProvider).content, ContentSearchStatus.ready);
      expect(container.read(sessionSearchProvider).hits, [two]);

      controller.setInput(TextEditingValue(text: query));
      expect(container.read(sessionSearchProvider).content, ContentSearchStatus.pending);
      expect(container.read(sessionSearchProvider).hits, isEmpty);
      await tester.pump(SessionSearchController.debounce);
      expect(backend.calls, [previous, query]);
      expect(container.read(sessionSearchProvider).hits, [one, two]);
      expect(container.read(sessionSearchProvider).contentQuery, query);
      await tester.pump(Duration.zero);
    });
  }

  test('a different Host phrase cannot contribute old hits or hasMore', () {
    final sessions = [searchSession('content', 'Note', DateTime(2026))];
    const hits = [(sessionId: 'content', snippet: 'A previous content result')];
    for (final (_, previous, query) in _changedQueries) {
      final result = deriveSessionSearchResults(query: query, sessions: sessions, contentQuery: previous, hits: hits);
      expect(result.active, isEmpty, reason: '$previous -> $query');
      final view = buildSessionSearchView(
        SessionSearchState(
          text: query,
          committed: query,
          contentQuery: previous,
          content: ContentSearchStatus.ready,
          hits: hits,
          hasMore: true,
        ),
        sessions: sessions,
      );
      expect(view.results.active, isEmpty);
      expect(view.content, ContentSearchStatus.pending);
      expect(view.hasMore, isFalse);
    }
  });
}
