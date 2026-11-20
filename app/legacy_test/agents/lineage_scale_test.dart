import 'dart:collection';
import 'dart:convert';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountedSessions extends MapView<String, SessionSummary> {
  _CountedSessions(super.map);
  int rowsVisited = 0;
  @override
  Iterable<SessionSummary> get values sync* {
    for (final row in super.values) {
      rowsVisited++;
      yield row;
    }
  }
}

SessionSummary _summary(String id, {String? parent, int order = 0, List<Map<String, Object>>? catalog}) =>
    SessionSummary(
      sessionId: id,
      updatedAt: DateTime.utc(2026).add(Duration(seconds: order)),
      running: false,
      blank: false,
      agentAvailable: false,
      parentSessionId: parent,
      origin: parent == null ? null : 'subagent',
      projections: SessionProjections(1, {'subagentCatalog': ?catalog}),
    );

Map<String, SessionSummary> _wide(int count) => {
  'root': _summary('root'),
  for (var i = count - 1; i >= 0; i--) 'child-$i': _summary('child-$i', parent: 'root', order: i),
};

void main() {
  test('wide lineage scans the session snapshot once, including leaf nodes', () {
    final sessions = _CountedSessions(_wide(200));
    final nodes = buildLineage('root', sessions);
    expect(nodes.map((n) => n.id), [for (var i = 0; i < 200; i++) 'child-$i']);
    expect(nodes.every((n) => n.children.isEmpty), isTrue);
    expect(sessions.rowsVisited, lessThanOrEqualTo(sessions.length));
  });
  test('catalog ordering, repeated ids and missing rows retain first visit', () {
    final sessions = _wide(4);
    sessions['root'] = _summary(
      'root',
      catalog: [
        {'id': 'child-2', 'mode': 'continuable', 'label': 'first'},
        {'id': 'missing', 'mode': 'external', 'label': 'external'},
        {'id': 'child-2', 'mode': 'continuable', 'label': 'duplicate'},
      ],
    );
    final nodes = buildLineage('root', sessions);
    expect(nodes.map((n) => n.id), ['child-2', 'missing', 'child-0', 'child-1', 'child-3']);
    expect(nodes.first.label, 'first');
    expect(nodes[1].openable, isFalse);
    expect(nodes[1].state, AgentRunState.idle);
  });
  test('depth and caller supplied seen set retain traversal boundaries', () {
    final sessions = <String, SessionSummary>{
      for (var i = 0; i < 12; i++) '$i': _summary('$i', parent: i == 0 ? null : '${i - 1}'),
    };
    final nodes = buildLineage('0', sessions);
    expect(nodes.single.flattened.map((n) => n.id), [for (var i = 1; i <= 9; i++) '$i']);
    expect(buildLineage('0', sessions, depth: 9), isEmpty);
    final seen = <String>{'0', '2'};
    expect(buildLineage('0', sessions, seen: seen).single.children, isEmpty);
    expect(seen, {'0', '1', '2'});
  });
  test('a fresh snapshot reflects removal and reparenting without cached indexes', () {
    final sessions = _wide(3);
    expect(buildLineage('root', sessions), hasLength(3));
    sessions.remove('child-0');
    sessions['child-1'] = _summary('child-1', parent: 'other');
    expect(buildLineage('root', sessions).map((n) => n.id), ['child-2']);
    expect(buildLineage('other', sessions).single.id, 'child-1');
  });
  test('optional production-entry measurement', () {
    for (final count in [200, 2000, 10000]) {
      final sessions = _wide(count);
      for (var i = 0; i < 3; i++) {
        expect(buildLineage('root', sessions), hasLength(count));
      }
      final samples = <int>[];
      for (var i = 0; i < 7; i++) {
        final watch = Stopwatch()..start();
        final nodes = buildLineage('root', sessions);
        watch.stop();
        samples.add(watch.elapsedMicroseconds);
        expect(nodes.map((n) => n.id), [for (var j = 0; j < count; j++) 'child-$j']);
      }
      final sorted = [...samples]..sort();
      // Component timing, not a frame, ANR or memory claim.
      // Structured output for this opt-in benchmark, never application logging.
      // ignore: avoid_print
      print('LINEAGE_MEASURE ${jsonEncode({'children': count, 'samples_us': samples, 'median_us': sorted[3]})}');
    }
  }, skip: !const bool.fromEnvironment('LINEAGE_MEASURE'));
}
