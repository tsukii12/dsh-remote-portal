import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in [
    'current',
    'reject',
    'current error',
    'host click',
    'host ABA',
    'reconnect',
    'card removed',
    'card ABA',
    'readOnly',
    'late error',
    'late success',
    'busy replacement',
  ]) {
    testWidgets('group approval $mode', (t) async {
      usePhoneView(t);
      final fixture =
          jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_group_approval.json').readAsStringSync()) as Map;
      final approval = Map<String, Object?>.from(fixture['approval'] as Map);
      Map<String, Object?> team() => {
        ...sampleTeam(),
        'work': {
          'approvals': [approval],
        },
      };
      final fa = FakeDsBotTransport(team: team())..helloOnFeed = false;
      final fb = FakeDsBotTransport(team: team())..helloOnFeed = false;
      // Keep pending approvals on unchanged state reads too; the generic
      // support transport otherwise projects an empty approval list.
      fa.handlers['state'] = (_) => team();
      fb.handlers['state'] = (_) => team();
      var reconnected = false;
      final pending = Completer<Object?>();
      final newPending = Completer<Object?>();
      fa.handlers['approval-answer'] = (_) =>
          (mode.startsWith('late') || mode == 'busy replacement' || mode == 'current error') ? pending.future : true;
      fb.handlers['approval-answer'] = (_) => mode == 'busy replacement' ? newPending.future : true;
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await t.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, shown, _) => shown ? const RoomChatPage(roomId: 'r1') : const SizedBox(),
          ),
          overrides: [
            activeHostProvider.overrideWith(_Host.new),
            activeConnectionProvider.overrideWith((ref) {
              final h = ref.watch(activeHostProvider);
              return AsyncData(
                HostConnection(client: fakeConnection.client, isLocal: h.isLocal, kind: h.kind, hostId: h.id),
              );
            }),
            dsBotApiFactoryProvider.overrideWithValue((c) => DsBotApi((c.hostId == HostRef.none.id) && !reconnected ? fa : fb)),
          ],
        ),
      );
      await frames(t);
      final c = ProviderScope.containerOf(t.element(find.byType(GroupApprovalCard)));
      final answer = t.widget<GroupApprovalCard>(find.byType(GroupApprovalCard)).onAnswer!;
      Future<void>? request;
      final delayed = mode.startsWith('late') || mode == 'current error' || mode == 'busy replacement';
      if (delayed) {
        if (mode == 'busy replacement') {
          await t.tap(find.text('允许本次'));
          await t.pump();
          expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '允许本次')).onPressed, isNull);
        } else {
          request = answer(true);
        }
      }
      if (mode.startsWith('host') || mode.startsWith('late')) {
        c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        if (mode == 'host ABA') c.read(activeHostProvider.notifier).select(HostRef.none);
        if (delayed) await frames(t);
      }
      if (mode == 'reconnect' || mode == 'busy replacement') {
        final oldApi = c.read(dsBotProvider.notifier).api;
        reconnected = true;
        c.read(dsBotProvider.notifier).retry();
        await frames(t);
        expect(c.read(dsBotProvider.notifier).api, isNot(same(oldApi)));
      }
      if (mode.startsWith('card')) {
        fa.handlers['state'] = (_) => {
          ...sampleTeam(),
          'work': {'approvals': []},
        };
        await c.read(dsBotProvider.notifier).refresh();
        if (mode == 'card ABA') {
          fa.handlers['state'] = (_) => team();
          await c.read(dsBotProvider.notifier).refresh();
        }
      }
      if (mode == 'readOnly') {
        fa.handlers['state'] = (_) => {...team(), 'readOnly': 'another-dsh'};
        await c.read(dsBotProvider.notifier).refresh();
      }
      final stateBefore = fb.endpoints.where((v) => v == 'state').length;
      if (mode == 'busy replacement') {
        expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '允许本次')).onPressed, isNotNull);
        await t.tap(find.text('允许本次'));
        await t.pump();
      }
      if (delayed) {
        if (mode == 'late success' || mode == 'busy replacement') {
          pending.complete(true);
        } else {
          final error = fixture['stale']['error'];
          pending.completeError(DshRemoteException(error['code'], error['message']));
        }
        if (request != null) await request;
      } else {
        await answer(mode != 'reject');
      }
      await frames(t);
      if (mode == 'busy replacement') {
        expect(
          t.widget<FilledButton>(find.widgetWithText(FilledButton, '允许本次')).onPressed,
          isNull,
          reason: 'old completion cannot release new pending answer',
        );
        newPending.complete(true);
        await frames(t);
        expect(fb.endpoints.where((v) => v == 'approval-answer').length, 1);
      } else {
        expect(
          fb.endpoints.where((v) => v == 'approval-answer'),
          isEmpty,
          reason: 'old group card cannot address next Host',
        );
      }
      if (mode.startsWith('late')) {
        expect(
          fb.endpoints.where((v) => v == 'state').length,
          stateBefore,
          reason: 'old completion cannot refresh new Host',
        );
      }
      expect(find.byType(SnackBar), mode == 'current error' ? findsOneWidget : findsNothing);
      if (mode == 'current' || mode == 'reject' || mode == 'current error') {
        expect(fa.calls.where((v) => v.$1 == 'approval-answer').map((v) => v.$2), [
          {'id': approval['id'], 'choice': mode == 'reject' ? 'reject' : 'allow'},
        ]);
      } else if (!delayed) {
        expect(fa.endpoints.where((v) => v == 'approval-answer'), isEmpty);
      }
      if (mode == 'card ABA') {
        final fresh = t.widget<GroupApprovalCard>(find.byType(GroupApprovalCard)).onAnswer;
        expect(fresh, isNotNull);
        await fresh!(true);
        expect(fa.endpoints.where((v) => v == 'approval-answer').length, 1);
        await answer(true);
        expect(fa.endpoints.where((v) => v == 'approval-answer').length, 1);
      }
      expect(t.takeException(), isNull);
    });
  }

  // A feed hello from a restarted host re-opens the connection (W2-09), so the
  // old card's closure and its late reply die with the old API; a compatible
  // restart shows the approval again on the new API only.
  for (final compatible in [true, false]) {
    testWidgets('group approval after a host restart, compatible=$compatible', (t) async {
      usePhoneView(t);
      final fixture =
          jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_group_approval.json').readAsStringSync()) as Map;
      final approval = Map<String, Object?>.from(fixture['approval'] as Map);
      Map<String, Object?> team() => {
        ...sampleTeam(),
        'work': {
          'approvals': [approval],
        },
      };
      final fa = FakeDsBotTransport(team: team())..helloOnFeed = false;
      final fb = FakeDsBotTransport(team: team())..helloOnFeed = false;
      fa.handlers['state'] = (_) => team();
      fb.handlers['state'] = (_) => team();
      fb.handlers['hello'] = (_) => {
        ...fb.helloAnswer(),
        'boot': 'boot-2',
        if (!compatible) ...{'api': null, 'apiMin': 2, 'apiMax': 2},
      };
      final pending = Completer<Object?>();
      fa.handlers['approval-answer'] = (_) => pending.future;
      fb.handlers['approval-answer'] = (_) => true;
      var opens = 0;
      await t.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: const RoomChatPage(roomId: 'r1'),
          overrides: [
            ...dsBotOverrides(fa)..removeAt(1),
            dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(opens++ == 0 ? fa : fb)),
          ],
        ),
      );
      await frames(t);
      final c = ProviderScope.containerOf(t.element(find.byType(GroupApprovalCard)));
      final oldApi = c.read(dsBotProvider.notifier).api;
      final answer = t.widget<GroupApprovalCard>(find.byType(GroupApprovalCard)).onAnswer!;
      final request = answer(true);
      fa.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-2', 'seq': 0});
      await frames(t);
      expect(c.read(dsBotProvider.notifier).api, isNot(same(oldApi)));
      expect(c.read(dsBotProvider).hello?.boot, 'boot-2');
      final stateBefore = fb.endpoints.where((v) => v == 'state').length;
      final error = fixture['stale']['error'];
      pending.completeError(DshRemoteException(error['code'], error['message']));
      await request;
      await frames(t);
      expect(find.byType(SnackBar), findsNothing, reason: 'the old host\'s late error stays with it');
      expect(fb.endpoints.where((v) => v == 'state').length, stateBefore);
      await answer(false);
      expect(fa.endpoints.where((v) => v == 'approval-answer').length, 1);
      expect(fb.endpoints.where((v) => v == 'approval-answer'), isEmpty);
      if (compatible) {
        final current = t.widget<GroupApprovalCard>(find.byType(GroupApprovalCard)).onAnswer;
        expect(current, isNotNull);
        await current!(false);
        expect(fb.calls.where((v) => v.$1 == 'approval-answer').map((v) => v.$2), [
          {'id': approval['id'], 'choice': 'reject'},
        ]);
      } else {
        expect(find.byType(GroupApprovalCard), findsNothing);
      }
      expect(t.takeException(), isNull);
    });
  }
}
