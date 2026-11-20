import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
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
  @override
  void select(HostRef value) => state = value;
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_pending_cards.json').readAsStringSync()) as Map;
  FakeDsBotTransport fake(String kind) =>
      FakeDsBotTransport(team: (fixture['${kind}State']['value'] as Map).cast<String, Object?>())..helloOnFeed = false;
  Future<ProviderContainer> open(
    WidgetTester t,
    FakeDsBotTransport old,
    FakeDsBotTransport next, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    usePhoneView(t);
    t.view.physicalSize = const Size(640, 1688);
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      goldenApp(
        brightness: brightness,
        home: const BotChatPage(botId: 'writer'),
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWith((ref) {
            final h = ref.watch(activeHostProvider);
            return AsyncData(
              HostConnection(
                client: fakeConnection.client,
                label: h.id,
                isLocal: h.isLocal,
                kind: h.kind,
                hostId: h.id,
              ),
            );
          }),
          dsBotApiFactoryProvider.overrideWithValue((c) => DsBotApi((c.hostId == HostRef.none.id) ? old : next)),
        ],
      ),
    );
    await frames(t);
    return ProviderScope.containerOf(t.element(find.byType(BotChatPage)));
  }

  String endpoint(String kind) => kind == 'question' ? 'answer-question' : 'view-reply';
  Future<void> answer(WidgetTester t, String kind) async {
    await t.tap(find.text(kind == 'question' ? 'Synthetic A' : 'A'));
    await t.pump();
    await t.tap(find.text('发送'));
    await frames(t);
  }

  DshRemoteException failure(String kind) {
    final error = fixture[kind == 'question' ? 'failedAnswer' : 'failedView']['error'] as Map;
    return DshRemoteException(error['code'] as String, error['message'] as String);
  }

  testWidgets('updating a background view does not reset the visible question choice', (t) async {
    final old = fake('question');
    final c = await open(t, old, fake('question'));
    await t.tap(find.text('Synthetic A'));
    await t.pump();
    old.handlers['state'] = (_) => {
      ...(fixture['questionState']['value'] as Map).cast<String, Object?>(),
      'views': fixture['viewState']['value']['views'],
    };
    await c.read(dsBotProvider.notifier).refresh();
    await frames(t);
    final send = find.ancestor(of: find.text('发送'), matching: find.byType(FilledButton));
    expect(t.widget<FilledButton>(send).onPressed, isNotNull);
  });
  for (final failed in [false, true]) {
    testWidgets('foreground question retires old view ${failed ? 'failure' : 'success'} without a frame', (t) async {
      final old = fake('view');
      final pending = Completer<Object?>();
      old.handlers['view-reply'] = (_) => pending.future;
      final c = await open(t, old, fake('view'));
      await answer(t, 'view');
      old.handlers['state'] = (_) => {
        ...(fixture['viewState']['value'] as Map).cast<String, Object?>(),
        'questions': fixture['questionState']['value']['questions'],
      };
      await c.read(dsBotProvider.notifier).refresh();
      final before = old.endpoints.where((e) => e == 'state').length;
      // The status is new, while the old widget is still mounted until a frame.
      if (failed) {
        pending.completeError(failure('view'));
      } else {
        pending.complete(true);
      }
      await frames(t);
      expect(find.text('Synthetic question?'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(old.endpoints.where((e) => e == 'state').length, before);
    });
  }
  for (final kind in ['question', 'view']) {
    for (final aba in [false, true]) {
      for (final failed in [false, true]) {
        testWidgets('old $kind ${failed ? 'failure' : 'success'} after ${aba ? 'ABA' : 'host'} is isolated', (t) async {
          final old = fake(kind), next = fake(kind);
          final pending = Completer<Object?>();
          old.handlers[endpoint(kind)] = (_) => pending.future;
          final c = await open(t, old, next);
          await answer(t, kind);
          expect(old.endpoints.where((e) => e == endpoint(kind)), hasLength(1));
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
          await frames(t);
          if (aba) {
            c.read(activeHostProvider.notifier).select(HostRef.none);
            await frames(t);
          }
          expect(c.read(dsBotProvider).ready, isTrue);
          final active = aba ? old : next;
          final before = active.endpoints.where((e) => e == 'state').length;
          if (failed) {
            pending.completeError(failure(kind));
          } else {
            pending.complete(true);
          }
          await frames(t);
          expect(find.byType(SnackBar), findsNothing);
          expect(active.endpoints.where((e) => e == 'state').length, before);
          expect(t.takeException(), isNull);
        });
      }
    }
    for (final failed in [false, true]) {
      testWidgets('current $kind ${failed ? 'failure can retry' : 'success refreshes its team'}', (t) async {
        final old = fake(kind);
        old.handlers[endpoint(kind)] = (_) {
          if (failed) throw failure(kind);
          return true;
        };
        await open(t, old, fake(kind));
        final before = old.endpoints.where((e) => e == 'state').length;
        await answer(t, kind);
        expect(old.endpoints.where((e) => e == endpoint(kind)), hasLength(1));
        expect(find.byType(SnackBar), failed ? findsOneWidget : findsNothing);
        expect(old.endpoints.where((e) => e == 'state').length, before + (failed ? 0 : 1));
        if (failed) {
          old.handlers[endpoint(kind)] = (_) => true;
          await t.tap(find.text('发送'));
          await frames(t);
          expect(old.endpoints.where((e) => e == endpoint(kind)), hasLength(2));
        }
      });
    }
    testWidgets('old $kind completion cannot clear new target busy', (t) async {
      final old = fake(kind), next = fake(kind);
      final oldPending = Completer<Object?>(), newPending = Completer<Object?>();
      old.handlers[endpoint(kind)] = (_) => oldPending.future;
      next.handlers[endpoint(kind)] = (_) => newPending.future;
      final c = await open(t, old, next);
      await answer(t, kind);
      c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
      await frames(t);
      await answer(t, kind);
      expect(next.endpoints.where((e) => e == endpoint(kind)), hasLength(1));
      oldPending.completeError(failure(kind));
      await frames(t);
      final send = find.ancestor(of: find.text('发送'), matching: find.byType(FilledButton));
      expect(t.widget<FilledButton>(send).onPressed, isNull);
      expect(find.byType(SnackBar), findsNothing);
      newPending.complete(true);
      await frames(t);
    });
  }
}
