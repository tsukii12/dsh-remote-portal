import 'dart:convert';

import 'package:test/test.dart';

import 'support/history_fill_harness.dart';

void main() {
  var globalSample = 0;
  for (final pageSize in [20, 100]) {
    for (final pageCount in [20, 50, 100]) {
      for (var sample = 1; sample <= 3; sample++) {
        final sampleInScale = sample;
        final sampleId = ++globalSample;
        test('history repair measurement: $pageCount pages of $pageSize records sample $sampleInScale', () async {
          // Construct all fixed server records before the stopwatch. This is a
          // server dataset, not an implementation of the client's collection.
          final count = pageCount * pageSize;
          final pages = <int, List<Map<String, Object?>>>{
            for (var start = 1; start <= count; start += pageSize)
              start + pageSize: [for (var seq = start; seq < start + pageSize; seq++) historyFrame(seq)],
          };
          final h = await HistoryFillHarness.start(cursor: count + 1, pages: pages);
          try {
            final watch = Stopwatch()..start();
            h.reconnect();
            final result = await h.guard(h.recovered.future);
            watch.stop();
            expect(result.events.map((e) => e.seq), List.generate(count + 1, (i) => i + 1));
            expect(h.requests, hasLength(pageCount));
            expect(h.requests.every((r) => r['throughSeq'] == count + 1 && r['maxMessages'] == 500), isTrue);
            // Informational sample: no machine-dependent speed assertion.
            print(
              jsonEncode({
                'measurement': 'watch_history_repair_end_to_end',
                'globalSample': sampleId,
                'sampleInScale': sampleInScale,
                'pageCount': pageCount,
                'pageSize': pageSize,
                'historyRecords': count,
                'elapsedMicros': watch.elapsedMicroseconds,
                'includes': 'mux reconnect, loopback RPC, JSON decode, DTOs, repair, snapshot publication',
              }),
            );
          } finally {
            await h.close();
          }
          expect(h.errors, isEmpty);
        });
      }
    }
  }
}
