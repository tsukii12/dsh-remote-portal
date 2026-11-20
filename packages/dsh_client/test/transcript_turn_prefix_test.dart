import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import '../tool/benchmark_turn_prefix.dart' as fixture;
import 'transcript_incremental_test.dart' show norm;
import 'support/transcript_full_build_oracle.dart' as original;

// The oracle is the unchanged full-log public fold, not an alternate prefix
// algorithm. Compare every public trace/span value, not only object identity.
void check(ChatTranscript transcript) {
  expect(norm(transcript.turns), norm(traceTurns(transcript.events)));
}

void main() {
  test('replacement preserves original finished-reuse values', () {
    final transcript = ChatTranscript();
    final reference = original.ChatTranscript();
    void apply(SessionLogEvent event) {
      transcript.apply(event);
      reference.apply(event);
      expect(norm(transcript.turns), norm(reference.turns));
    }

    for (final event in fixture.history(3)) {
      apply(event);
    }
    apply(
      fixture.event(5, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'cancelled'},
      }),
    );
    final page = HistoryPage([
      fixture.event(3, 'step/end', {'turn': 1, 'step': 2}),
    ], false);
    transcript.prependHistory(page);
    reference.prependHistory(page);
    expect(norm(transcript.turns), norm(reference.turns));
    apply(fixture.event(18, 'turn/start', {'turn': 4}));
  });

  test('empty result stays growable and noncontiguous seqs retain full values', () {
    final transcript = ChatTranscript();
    final empty = transcript.turns;
    expect(empty, isEmpty);
    for (final event in fixture.history(2)) {
      transcript.apply(fixture.event(event.seq * 10, event.type, event.data));
      check(transcript);
    }
    empty.add(transcript.turns.first);
    empty.clear();
    transcript.turns.add(transcript.turns.first);
    transcript.turns.removeLast();
    transcript.apply(fixture.event(120, 'turn/start', {'turn': 3}));
    check(transcript);
  });

  test('sequential appends preserve full values and completed identities', () {
    final transcript = ChatTranscript();
    for (final event in fixture.history(3)) {
      transcript.apply(event);
      check(transcript);
    }
    final finished = [...transcript.turns];
    transcript.apply(fixture.event(18, 'turn/start', {'turn': 4}));
    for (final event in fixture.steps(19, 4)) {
      transcript.apply(event);
      check(transcript);
      for (var i = 0; i < finished.length; i++) {
        expect(identical(transcript.turns[i], finished[i]), isTrue);
      }
    }
    transcript.apply(
      fixture.event(119, 'turn/end', {
        'turn': 4,
        'reason': {'kind': 'completed'},
      }),
    );
    check(transcript);
    // Several appended events may arrive between getter calls.
    transcript.apply(fixture.event(120, 'turn/start', {'turn': 5}));
    for (final event in fixture.steps(121, 5)) {
      transcript.apply(event);
    }
    check(transcript);
  });

  test('implicit interruptions and missing turn ends remain in full fold', () {
    final transcript = ChatTranscript();
    for (final event in fixture.history(3).where((event) => event.type != 'turn/end')) {
      transcript.apply(event);
      check(transcript);
    }
    expect(transcript.turns.first.endSeq, isNull);
    expect(transcript.turns.first.running, isFalse);
    for (final event in fixture.steps(18, 3)) {
      transcript.apply(event);
      check(transcript);
    }
  });

  test('returned list mutation cannot discard the retained historical prefix', () {
    final transcript = ChatTranscript();
    for (final event in fixture.history(3)) {
      transcript.apply(event);
    }
    transcript.turns.clear();
    transcript.apply(fixture.event(18, 'turn/start', {'turn': 4}));
    check(transcript);
    expect(transcript.turns, hasLength(4));
  });

  test('history and reordered input invalidate the prefix', () {
    final transcript = ChatTranscript();
    final history = fixture.history(4);
    for (final event in history.skip(12)) {
      transcript.apply(event);
    }
    check(transcript);
    transcript.prependHistory(HistoryPage(history.take(12).toList(), false));
    check(transcript);
    // Same-seq and older delivery must take the full rebuild path. Use
    // unchanged DTO values to preserve the existing finished reuse contract.
    transcript.apply(history[13]);
    check(transcript);
    transcript.apply(history[1]);
    check(transcript);
    transcript.apply(fixture.event(24, 'turn/start', {'turn': 5}));
    check(transcript);
  });

  test('snapshot and resync replace rather than append the trace prefix', () {
    final transcript = ChatTranscript();
    for (final event in fixture.history(4)) {
      transcript.apply(event);
    }
    check(transcript);
    for (final resync in [false, true]) {
      final events = fixture.history(2);
      transcript.apply(
        parseFollowFrame('own', {
          'type': 'snapshot',
          'header': {'id': 'own', 'version': 4, 'createdAt': 1700000000000},
          'cursor': 11,
          'records': events
              .map(
                (event) => {
                  'event': {
                    'seq': event.seq,
                    'time': event.time.millisecondsSinceEpoch,
                    'type': event.type,
                    'data': event.data,
                  },
                },
              )
              .toList(),
          'hasMore': false,
        }, isResync: resync),
      );
      check(transcript);
      expect(transcript.turns, hasLength(2));
    }
  });
}
