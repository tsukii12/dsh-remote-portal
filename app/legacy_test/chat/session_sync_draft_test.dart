// Regression cases adapted from the G54 R1 independent review. The screen,
// controller, draft store and loopback HTTP/WS path remain real.
import 'dart:io';

import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/session_sync_host.dart';

List<String> writes(SyncHarness h) => h.methods
    .where((method) => const ['session/cancel', 'session/updateQueue', 'session/prompt'].contains(method))
    .toList();

Future<void> settleIo(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 250; i++) {
    if (ready()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('UI/IO condition did not become true');
}

Future<void> mount(WidgetTester tester, SyncHarness h) =>
    tester.pumpWidget(UncontrolledProviderScope(container: h.container, child: testApp(const ChatScreen())));

final _overrides = Expando<List<Override>>();

class _SequenceSessions extends FakeSessions {
  final _ids = ['S', 'T'];

  @override
  Future<String> create({bool autoApprove = true}) async => _ids.removeAt(0);
}

Future<SyncHarness> beginFirstSend(WidgetTester tester, {FakeSessions? sessions, bool withImage = false}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final ui = ChatHarness(created: 'S');
  final overrides = [
    // Pet state is unrelated to the composer wait and stays read-only here.
    petScopedStateProvider.overrideWith((ref, scope) => const PetState()),
    for (final override in ui.overrides)
      if (override.origin != activeConnectionProvider &&
          override.origin != chatProvider &&
          (sessions == null || override.origin != sessionsProvider))
        override,
    if (sessions != null) sessionsProvider.overrideWith(() => sessions),
  ];
  late SyncHarness h;
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      h = await SyncHarness.start(initialSnapshot: false, overrides: overrides);
    }, RealSyncHttp()),
  );
  _overrides[h] = overrides;
  await mount(tester, h);
  await pumpFrames(tester);
  if (withImage) {
    tester
        .state<EditableTextState>(find.byType(EditableText))
        .insertContent(KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://test/first', data: tinyPng));
    await tester.pump();
  }
  await tester.enterText(find.byType(TextField), 'retained first draft');
  await tester.pump();
  expect(h.container.read(draftStoreProvider).drafts['new']?.text, 'retained first draft');
  await tester.tap(find.byIcon(AppIcons.send));
  await tester.pump();
  expect(h.container.read(currentSessionProvider), 'S');
  expect(tester.widget<Composer>(find.byType(Composer)).busy, isTrue);
  expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'retained first draft');
  expect(writes(h), isEmpty);
  return h;
}

Future<void> disposeHarness(WidgetTester tester, SyncHarness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 600));
  // Drain peripheral read-only HTTP work before shutting down the real host.
  // Advancing only fake time leaves its real socket replies undelivered.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 1));
  }
  await tester.runAsync(() async {
    await h.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('regression: first draft survives screen disposal before the first snapshot', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      final before = h.container.read(draftStoreProvider);
      syncTrace('r2/draft-before-dispose', {
        'current': h.container.read(currentSessionProvider),
        'input': tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'drafts': {for (final e in before.drafts.entries) e.key: e.value.text},
        'writes': writes(h),
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      await mount(tester, h);
      await pumpFrames(tester);
      final input = tester.widget<TextField>(find.byType(TextField)).controller!.text;
      syncTrace('r2/draft-after-remount', {
        'current': h.container.read(currentSessionProvider),
        'input': input,
        'drafts': {for (final e in h.container.read(draftStoreProvider).drafts.entries) e.key: e.value.text},
        'writes': writes(h),
      });
      expect(input, 'retained first draft', reason: 'No prompt was sent and the first snapshot is still held');
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  testWidgets('regression: waiting first send cannot block a different synchronized session', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      h.container.read(currentSessionProvider.notifier).select('T');
      await tester.pump();
      await settleIo(tester, () => h.follows.length == 2);
      await tester.runAsync(() async {
        h.follows.last.socket.item(h.follows.last.id, {
          ...syncSnapshot(1),
          'header': {...(syncSnapshot(1)['header']! as Map<String, Object?>), 'id': 'T'},
        });
      });
      await settleIo(tester, () => h.container.read(chatProvider('T')).controlReady);
      await tester.enterText(find.byType(TextField), 'send to synchronized T');
      await tester.pump();
      final composer = tester.widget<Composer>(find.byType(Composer));
      expect(composer.busy, isFalse, reason: 'T is usable immediately, before advancing the old wait');
      // Retiring S changes the send key; wait only for its existing animation.
      await pumpFrames(tester);
      await tester.tap(find.byIcon(AppIcons.send), warnIfMissed: false);
      await settleIo(tester, () => writes(h).isNotEmpty);
      expect(writes(h), ['session/prompt']);
      expect((h.boundary.single['request'] as Map)['sessionId'], 'T');
      syncTrace('r2/session-switch-while-waiting', {
        'current': h.container.read(currentSessionProvider),
        'sReady': h.state.controlReady,
        'tReady': h.container.read(chatProvider('T')).controlReady,
        'composerReady': composer.sessionReady,
        'composerBusy': composer.busy,
        'input': composer.controller.text,
        'writesAfterTap': writes(h),
      });
      await tester.pump(const Duration(seconds: 11));
      await pumpFrames(tester);
      syncTrace('r2/session-switch-after-deadline', {
        'current': h.container.read(currentSessionProvider),
        'sReady': h.state.controlReady,
        'tReady': h.container.read(chatProvider('T')).controlReady,
        'composerBusy': tester.widget<Composer>(find.byType(Composer)).busy,
        'writes': writes(h),
      });
      expect(composer.busy, isFalse, reason: 'The wait belongs to S; T already has its complete baseline');
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  testWidgets('regression control: editing a waiting first draft prevents stale automatic send', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      await tester.enterText(find.byType(TextField), 'revised first draft');
      await tester.pump();
      await tester.runAsync(() async {
        h.follows.last.socket.item(h.follows.last.id, syncSnapshot(1));
      });
      await settleIo(tester, () => h.state.controlReady);
      await pumpFrames(tester);
      expect(writes(h), isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'revised first draft');
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      await tester.tap(find.byIcon(AppIcons.send));
      await settleIo(tester, () => writes(h).isNotEmpty);
      expect(writes(h), ['session/prompt']);
      syncTrace('r2/edited-draft-control', h.boundary);
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  testWidgets('first-wait text and attachments survive timeout and page remount', (tester) async {
    final h = await beginFirstSend(tester, withImage: true);
    try {
      final saved = h.container.read(draftStoreProvider).drafts;
      expect(saved['new'], isNull);
      expect(saved['S']!.text, 'retained first draft');
      expect(saved['S']!.attachments, hasLength(1));
      await tester.enterText(find.byType(TextField), 'edited text with two images');
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .insertContent(KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://test/second', data: tinyPng));
      await tester.pump(const Duration(seconds: 11));
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      expect(h.state.notice, isNotNull, reason: 'A current timeout still explains why it did not send');
      final attachments = h.container.read(draftStoreProvider).drafts['S']!.attachments;
      expect(attachments, hasLength(2));
      expect(writes(h), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      await mount(tester, h);
      await pumpFrames(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'edited text with two images');
      expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, attachments);
      await tester.tap(find.descendant(of: find.byType(ComposerTray), matching: find.byIcon(AppIcons.close)).first);
      await tester.pump();
      expect(h.container.read(draftStoreProvider).drafts['S']!.attachments, [attachments.last]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      await mount(tester, h);
      await pumpFrames(tester);
      expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, [attachments.last]);
      expect(writes(h), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  for (final outcome in ['snapshot', 'timeout', 'failure']) {
    testWidgets('retired S wait $outcome cannot release the newer T wait', (tester) async {
      final h = await beginFirstSend(tester, sessions: _SequenceSessions());
      try {
        final old = h.follows.single;
        await tester.pump(const Duration(seconds: 3));
        h.container.read(currentSessionProvider.notifier).select(null);
        await tester.pump();
        expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
        await tester.enterText(find.byType(TextField), 'new T draft');
        await pumpFrames(tester);
        await tester.tap(find.byIcon(AppIcons.send));
        await tester.pump();
        await settleIo(tester, () => h.follows.length == 2);
        expect(h.container.read(currentSessionProvider), 'T');
        expect(tester.widget<Composer>(find.byType(Composer)).busy, isTrue);
        switch (outcome) {
          case 'snapshot':
            await tester.runAsync(() async => old.socket.item(old.id, syncSnapshot(1)));
            await settleIo(tester, () => h.state.controlReady);
          case 'timeout':
            await tester.pump(const Duration(milliseconds: 7500));
            expect(h.state.notice, isNull, reason: 'The retired wait no longer owns timeout feedback');
          case 'failure':
            await tester.runAsync(() async {
              old.socket.send({
                'type': 'error',
                'streamId': old.id,
                'error': {'code': 'session/denied', 'message': 'Controlled old-session failure'},
              });
            });
            await settleIo(tester, () => h.state.streamLost);
        }
        await tester.pump();
        expect(tester.widget<Composer>(find.byType(Composer)).busy, isTrue);
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'new T draft');
        expect(h.container.read(draftStoreProvider).drafts['S']!.text, 'retained first draft');
        expect(h.container.read(draftStoreProvider).drafts['T']!.text, 'new T draft');
        expect(h.container.read(chatProvider('T')).notice, isNull);
        expect(h.container.read(chatProvider('T')).error, isNull);
        expect(writes(h), isEmpty);
        final next = h.follows.last;
        await tester.runAsync(() async {
          next.socket.item(next.id, {
            ...syncSnapshot(1),
            'header': {...(syncSnapshot(1)['header']! as Map<String, Object?>), 'id': 'T'},
          });
        });
        await settleIo(tester, () => writes(h).isNotEmpty);
        expect(writes(h), ['session/prompt']);
        final request = h.boundary.single['request'] as Map;
        expect(request['sessionId'], 'T');
        expect((request['content'] as List).single['text'], 'new T draft');
        expect(h.container.read(draftStoreProvider).drafts['S']!.text, 'retained first draft');
        expect(tester.takeException(), isNull);
      } finally {
        await disposeHarness(tester, h);
      }
    });
  }

  testWidgets('S to T to S never revives the original send intent', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      h.container.read(currentSessionProvider.notifier).select('T');
      await tester.pump();
      h.container.read(currentSessionProvider.notifier).select('S');
      await tester.pump();
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      final first = h.follows.first;
      await tester.runAsync(() async => first.socket.item(first.id, syncSnapshot(1)));
      await settleIo(tester, () => h.state.controlReady);
      await pumpFrames(tester);
      expect(writes(h), isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'retained first draft');
      await tester.tap(find.byIcon(AppIcons.send));
      await settleIo(tester, () => writes(h).isNotEmpty);
      expect(writes(h), ['session/prompt']);
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  testWidgets('a disposed screen cannot send or clear the remounted draft after a late snapshot', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      await mount(tester, h);
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField), 'remounted draft');
      final first = h.follows.first;
      await tester.runAsync(() async => first.socket.item(first.id, syncSnapshot(1)));
      await settleIo(tester, () => h.state.controlReady);
      await pumpFrames(tester);
      expect(writes(h), isEmpty);
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'remounted draft');
      expect(h.container.read(draftStoreProvider).drafts['S']!.text, 'remounted draft');
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  testWidgets('connection removal and return do not revive a waiting first send', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      void connection(HostConnection? value) => h.container.updateOverrides([
        ..._overrides[h]!,
        activeConnectionProvider.overrideWithValue(AsyncData(value)),
      ]);
      connection(null);
      await tester.pump();
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      connection(HostConnection(hostId: '', client: h.client, isLocal: true));
      await tester.pump();
      await settleIo(tester, () => h.follows.length >= 2);
      final latest = h.follows.last;
      await tester.runAsync(() async => latest.socket.item(latest.id, syncSnapshot(1)));
      await settleIo(tester, () => h.state.controlReady);
      await pumpFrames(tester);
      expect(writes(h), isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'retained first draft');
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });

  testWidgets('a new mux generation needs a new send gesture after the first-snapshot wait', (tester) async {
    final h = await beginFirstSend(tester);
    try {
      final generation = h.client.mux.generation;
      await tester.runAsync(() async => h.client.mux.reconnect());
      await settleIo(tester, () => h.follows.length >= 2 && !identical(h.client.mux.generation, generation));
      final latest = h.follows.last;
      await tester.runAsync(() async => latest.socket.item(latest.id, syncSnapshot(1)));
      await settleIo(tester, () => h.state.controlReady);
      await pumpFrames(tester);
      expect(writes(h), isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'retained first draft');
      expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
      await tester.tap(find.byIcon(AppIcons.send));
      await settleIo(tester, () => writes(h).isNotEmpty);
      expect(writes(h), ['session/prompt']);
      expect(tester.takeException(), isNull);
    } finally {
      await disposeHarness(tester, h);
    }
  });
}
