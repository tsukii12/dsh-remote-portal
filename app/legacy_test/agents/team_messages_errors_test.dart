import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/agents/team_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart' show ListPageCard;
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show FixedSession, loadTestFonts, pumpFrames, testCatalog, usePhoneView;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

enum _Read { failed, closed, empty, message }

class _Client extends DshClient {
  _Client({this.prefix = 'SYNTHETIC', this.defaultRead = _Read.message})
    : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final String prefix;
  _Read defaultRead;
  final modes = <String, _Read>{};
  final calls = <String, int>{};
  final finished = <String, int>{};
  Completer<void>? gate;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) async* {
    calls.update(sessionId, (n) => n + 1, ifAbsent: () => 1);
    try {
      if (gate case final pending?) await pending.future;
      final mode = modes[sessionId] ?? defaultRead;
      if (mode == _Read.failed) throw StateError('SYNTHETIC member read failure');
      if (mode == _Read.closed) return;
      final order = {parentId: 1, reviewerId: 3, testsId: 2}[sessionId]!;
      yield SessionSnapshotEvent.fromJson(sessionId, {
        'cursor': mode == _Read.empty ? -1 : order,
        'hasMore': false,
        'records': [
          if (mode == _Read.message)
            {
              'type': 'event',
              'event': {
                'seq': order,
                'time': 1792822300000 + order * 1000,
                'type': 'user/message',
                'data': {
                  'id': 'm$order',
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': '$prefix $sessionId'},
                  ],
                  'source': {'kind': 'team-message', 'senderId': parentId, 'senderName': 'lead'},
                },
              },
            },
        ],
      });
    } finally {
      finished.update(sessionId, (n) => n + 1, ifAbsent: () => 1);
    }
  }
}

class _SelectedConnection extends Notifier<HostConnection> {
  _SelectedConnection(this.initial);
  final HostConnection initial;

  @override
  HostConnection build() => initial;

  void select(HostConnection next) => state = next;
}

final _selectedConnection = NotifierProvider<_SelectedConnection, HostConnection>(
  () => throw UnimplementedError('test override required'),
);

Future<ProviderContainer> _open(WidgetTester tester, _Client client) async {
  addTearDown(client.close);
  usePhoneView(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: const TeamPage(),
      overrides: [
        _selectedConnection.overrideWith(() => _SelectedConnection(HostConnection(hostId: '', client: client, isLocal: true))),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_selectedConnection))),
        currentSessionProvider.overrideWith(() => FixedSession(parentId)),
        modelCatalogProvider.overrideWith((ref) async => testCatalog),
        localSafeModeProvider.overrideWithValue(false),
        hostSessionsProvider.overrideWithValue(sampleAgentSessions(withTeam: true)),
        teamProvider.overrideWith2((leadId) => FakeTeam(leadId, sampleTeam())),
        installedPluginsProvider.overrideWith(() => FakeInstalled(const [])),
      ],
    ),
  );
  await pumpFrames(tester, 8);
  await tester.tap(find.text(appL10n.botsMessages));
  await pumpFrames(tester, 8);
  return ProviderScope.containerOf(tester.element(find.byType(TeamPage)));
}

void _expectCalls(_Client client, int each) {
  expect(client.calls, {parentId: each, reviewerId: each, testsId: each});
  expect(client.subagentRoute(reviewerId)?.parentSessionId, parentId);
  expect(client.subagentRoute(testsId)?.parentSessionId, parentId);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final failure in [_Read.failed, _Read.closed]) {
    testWidgets('all members $failure shows failure and retry, not an empty inbox', (tester) async {
      final client = _Client(defaultRead: failure);
      await _open(tester, client);
      expect(find.text(appL10n.botsMessagesReadFailed), findsOneWidget);
      expect(find.text(appL10n.botsNoMemberMessages), findsNothing);
      _expectCalls(client, 1);
      await pumpFrames(tester, 10);
      _expectCalls(client, 1);

      client.defaultRead = _Read.message;
      await tester.tap(find.text(appL10n.commonRetry));
      await pumpFrames(tester, 8);
      expect(find.text(appL10n.botsMessagesReadFailed), findsNothing);
      for (final id in [parentId, reviewerId, testsId]) {
        expect(find.text('SYNTHETIC $id'), findsOneWidget);
      }
      _expectCalls(client, 2);
      expect(client.finished, client.calls);
      expect(tester.takeException(), isNull);
    });
  }

  for (final readable in [_Read.message, _Read.empty]) {
    testWidgets('partial failure retains $readable rows and offers retry', (tester) async {
      final client = _Client(defaultRead: readable)..modes[reviewerId] = _Read.failed;
      await _open(tester, client);
      // Rows that were read stay under a one-line notice; with none, the
      // failure takes the empty inbox's place.
      final notice = readable == _Read.message ? appL10n.botsMessagesIncomplete : appL10n.botsMessagesReadFailed;
      expect(find.text(notice), findsOneWidget);
      expect(
        find.text(readable == _Read.message ? appL10n.botsMessagesReadFailed : appL10n.botsMessagesIncomplete),
        findsNothing,
      );
      expect(find.text(appL10n.botsNoMemberMessages), findsNothing);
      for (final id in [parentId, testsId]) {
        expect(find.text('SYNTHETIC $id'), readable == _Read.message ? findsOneWidget : findsNothing);
      }
      expect(find.text('SYNTHETIC $reviewerId'), findsNothing);
      _expectCalls(client, 1);
      if (readable == _Read.message) {
        // The notice line sits centred between the tabs and the card.
        final tabs = tester.getRect(find.byWidgetPredicate((widget) => widget is SegmentedPill));
        final line = tester.getRect(find.ancestor(of: find.text(notice), matching: find.byType(TextButton)));
        final card = tester.getRect(find.byType(ListPageCard));
        expect(line.top - tabs.bottom, 16);
        expect(card.top - line.bottom, 16);
      }

      client.modes.clear();
      await tester.tap(find.text(readable == _Read.message ? notice : appL10n.commonRetry));
      await pumpFrames(tester, 8);
      expect(find.text(notice), findsNothing);
      expect(find.text(appL10n.botsNoMemberMessages), readable == _Read.empty ? findsOneWidget : findsNothing);
      if (readable == _Read.message) expect(find.text('SYNTHETIC $reviewerId'), findsOneWidget);
      _expectCalls(client, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('all readable empty snapshots remain a genuine empty inbox', (tester) async {
    final client = _Client(defaultRead: _Read.empty);
    await _open(tester, client);
    expect(find.text(appL10n.botsNoMemberMessages), findsOneWidget);
    expect(find.text(appL10n.botsMessagesReadFailed), findsNothing);
    expect(find.text(appL10n.commonRetry), findsNothing);
    _expectCalls(client, 1);
    expect(client.finished, client.calls);
    expect(tester.takeException(), isNull);
  });

  testWidgets('readable messages retain newest-first order and no failure notice', (tester) async {
    final client = _Client();
    await _open(tester, client);
    final ys = [
      for (final id in [reviewerId, testsId, parentId]) tester.getTopLeft(find.text('SYNTHETIC $id')).dy,
    ];
    expect(ys[0], lessThan(ys[1]));
    expect(ys[1], lessThan(ys[2]));
    expect(find.text(appL10n.botsMessagesReadFailed), findsNothing);
    expect(find.text(appL10n.botsNoMemberMessages), findsNothing);
    _expectCalls(client, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late failed reads from host A do not replace host B messages', (tester) async {
    final a = _Client(prefix: 'SYNTHETIC A', defaultRead: _Read.failed)..gate = Completer<void>();
    final container = await _open(tester, a);
    _expectCalls(a, 1);
    final b = _Client(prefix: 'SYNTHETIC B');
    addTearDown(b.close);
    container.read(_selectedConnection.notifier).select(HostConnection(hostId: '', client: b, isLocal: true));
    await pumpFrames(tester, 8);
    expect(find.text('SYNTHETIC B $parentId'), findsOneWidget);
    _expectCalls(b, 1);

    a.gate!.complete();
    await pumpFrames(tester, 8);
    expect(find.text(appL10n.botsMessagesReadFailed), findsNothing);
    expect(find.text(appL10n.botsNoMemberMessages), findsNothing);
    expect(find.text('SYNTHETIC B $parentId'), findsOneWidget);
    expect(a.finished, a.calls);
    expect(tester.takeException(), isNull);
  });
}
