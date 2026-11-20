import 'package:test/test.dart';

import 'support/history_fill_harness.dart';

Map<int, List<Map<String, Object?>>> _unequalPages() => {
  11: [
    for (final seq in [7, 8, 9, 10, 11, 12]) historyFrame(seq),
  ],
  7: [
    for (final seq in [5, 6, 7]) historyFrame(seq),
  ],
  5: [
    for (final seq in [0, 1, 2, 3, 4, 5]) historyFrame(seq),
  ],
};

void main() {
  for (final sync in [false, true]) {
    test('unequal history pages keep order and filter both boundaries (sync: $sync)', () async {
      final h = await HistoryFillHarness.start(cursor: 11, pages: _unequalPages(), includeSyncEvents: sync);
      try {
        h.reconnect();
        final result = await h.guard(h.recovered.future);
        expect(result.events.map((e) => e.seq), List.generate(11, (i) => i + 1));
        expect(h.requests.map((r) => r['beforeSeq']), [11, 7, 5]);
        expect(h.requests.every((r) => r['throughSeq'] == 11 && r['maxMessages'] == 500), isTrue);
        expect(h.snapshots, hasLength(2));
      } finally {
        await h.close();
      }
      expect(h.errors, isEmpty);
    });
  }

  test('an empty usable page ends the existing non-sync repair without another request', () async {
    final pages = _unequalPages();
    pages[7] = [historyFrame(0), historyFrame(7), historyFrame(12)];
    final h = await HistoryFillHarness.start(cursor: 11, pages: pages, includeSyncEvents: false);
    try {
      h.reconnect();
      final result = await h.guard(h.recovered.future);
      expect(result.events.map((e) => e.seq), [7, 8, 9, 10, 11]);
      expect(h.requests.map((r) => r['beforeSeq']), [11, 7]);
    } finally {
      await h.close();
    }
    expect(h.errors, isEmpty);
  });

  test('default watch fills a live log gap without another snapshot', () async {
    final h = await HistoryFillHarness.start(cursor: 11, pages: _unequalPages(), includeSyncEvents: false);
    try {
      h.emitLiveGap();
      await h.guard(h.liveLast.future);
      expect(h.logs.map((e) => e.seq), List.generate(11, (i) => i + 1));
      expect(h.requests.map((r) => r['beforeSeq']), [11, 7, 5]);
      expect(h.requests.every((r) => r['throughSeq'] == 10), isTrue);
      expect(h.opens, 1);
      expect(h.snapshots, hasLength(1));
    } finally {
      await h.close();
    }
    expect(h.errors, isEmpty);
  });

  test('hasMore false stops non-sync snapshot repair at the supplied page', () async {
    final h = await HistoryFillHarness.start(
      cursor: 11,
      pages: _unequalPages(),
      includeSyncEvents: false,
      lastPages: {7},
    );
    try {
      h.reconnect();
      final result = await h.guard(h.recovered.future);
      expect(result.events.map((e) => e.seq), [5, 6, 7, 8, 9, 10, 11]);
      expect(h.requests.map((r) => r['beforeSeq']), [11, 7]);
    } finally {
      await h.close();
    }
    expect(h.errors, isEmpty);
  });

  test('a contiguous replacement snapshot does not request history', () async {
    final h = await HistoryFillHarness.start(cursor: 1, pages: {});
    try {
      h.reconnect();
      final result = await h.guard(h.recovered.future);
      expect(result.events.map((e) => e.seq), [1]);
      expect(h.requests, isEmpty);
    } finally {
      await h.close();
    }
    expect(h.errors, isEmpty);
  });

  test('cancel while a decoded history result is held does not publish or fetch another page', () async {
    final h = await HistoryFillHarness.start(cursor: 11, pages: _unequalPages());
    try {
      h.client.holdNext = true;
      h.reconnect();
      await h.guard(h.client.entered.future);
      expect(h.requests, hasLength(1));
      await h.subscription!.cancel();
      h.client.release.complete();
      await h.client.returned.future;
      await h.client.close();
      expect(h.snapshots.map((s) => s.cursor), [0]);
      expect(h.requests, hasLength(1));
    } finally {
      await h.close();
    }
    expect(h.client.attempts, hasLength(1));
    expect(h.requests, hasLength(1));
    expect(h.errors, isEmpty);
  });

  test('a held old-generation repair is not published after replacement becomes ready', () async {
    final h = await HistoryFillHarness.start(cursor: 11, pages: _unequalPages());
    try {
      h.client.holdNext = true;
      h.reconnect();
      await h.guard(h.client.entered.future);
      final oldGeneration = h.client.mux.generation;
      h.replacementComplete = true;
      final newGeneration = h.client.mux.generations.firstWhere((g) => !identical(g, oldGeneration));
      h.reconnect();
      await h.guard(newGeneration);
      h.client.release.complete();
      await h.client.returned.future;
      final result = await h.guard(h.recovered.future);
      expect(h.opens, 3);
      expect(result.events.map((e) => e.seq), List.generate(11, (i) => i + 1));
      expect(h.snapshots, hasLength(2));
      expect(result.followEpoch?.isCurrent, isTrue);
    } finally {
      await h.close();
    }
    expect(h.errors, isEmpty);
  });
}
