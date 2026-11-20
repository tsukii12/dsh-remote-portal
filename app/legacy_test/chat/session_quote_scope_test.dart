// R4 quote ownership: actual page, controller, draft store, client and
// loopback HTTP/WS. Create completion and host replies are controlled.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/quote_chip.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_sync_draft_test.dart' as ui;
import 'support/harness.dart';
import 'support/session_sync_host.dart';

class _QueuedCreate extends FakeSessions {
  final pending = <Completer<String>>[];
  @override
  Future<String> create({bool autoApprove = true}) {
    final next = Completer<String>();
    pending.add(next);
    return next.future;
  }
}

class _QuoteFlow {
  _QuoteFlow(this.h, this.sessions, this.overrides);
  final SyncHarness h;
  final _QueuedCreate sessions;
  final List<Override> overrides;

  static Future<_QuoteFlow> start(WidgetTester tester, {ReplyHold? hold, bool modelFails = false}) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final sessions = _QueuedCreate();
    final overrides = <Override>[
      petScopedStateProvider.overrideWith((ref, scope) => const PetState()),
      for (final override in ChatHarness().overrides)
        if (override.origin != activeConnectionProvider &&
            override.origin != chatProvider &&
            override.origin != sessionsProvider)
          override,
      sessionsProvider.overrideWith(() => sessions),
    ];
    late SyncHarness h;
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        h = await SyncHarness.start(initialSnapshot: false, overrides: overrides, hold: hold);
      }, RealSyncHttp()),
    );
    installHandlers(h, modelFails: modelFails);
    await ui.mount(tester, h);
    await pumpFrames(tester);
    return _QuoteFlow(h, sessions, overrides);
  }

  static void installHandlers(SyncHarness h, {bool modelFails = false}) {
    h.host.handlers['session/selectModel'] = (args) => modelFails
        ? {
            'ok': false,
            'error': {'code': 'gateway/internal', 'message': 'Controlled late model error', 'details': {}},
          }
        : {
            'ok': true,
            'value': {'selected': args['request']},
          };
    h.host.handlers['commands/execute'] = (_) => {
      'ok': true,
      'value': {
        'commandId': 'review-command',
        'result': {'kind': 'success', 'text': 'done'},
      },
    };
  }

  String? get selected => h.container.read(currentSessionProvider);
  Map<String, ChatDraft> get drafts => h.container.read(draftStoreProvider).drafts;
  String input(WidgetTester t) => t.widget<TextField>(find.byType(TextField)).controller!.text;
  bool busy(WidgetTester t) => t.widget<Composer>(find.byType(Composer)).busy;
  void select(String? id) => h.container.read(currentSessionProvider.notifier).select(id);
  void replaceClient(SyncHarness next) => h.container.updateOverrides([
    ...overrides,
    activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: next.client, isLocal: true))),
  ]);

  Future<void> send(WidgetTester tester, String value) async {
    await tester.enterText(find.byType(TextField), value);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> baseline(WidgetTester tester, String id) async {
    await ui.settleIo(tester, () => id == 'S' || h.follows.length > 1);
    final f = id == 'S' ? h.follows.first : h.follows.last;
    await tester.runAsync(
      () async => f.socket.item(f.id, {
        ...syncSnapshot(1),
        'header': {...(syncSnapshot(1)['header']! as Map<String, Object?>), 'id': id},
      }),
    );
    await ui.settleIo(tester, () => h.container.read(chatProvider(id)).controlReady);
  }

  void observe(WidgetTester tester, String name, {Map<String, Object?> more = const {}}) {
    syncTrace('r4-quote/$name', {
      'selected': selected,
      'input': input(tester),
      'busy': busy(tester),
      'drafts': {for (final e in drafts.entries) e.key: e.value.text},
      'quotes': h.container.read(composerQuoteProvider),
      'model': selected == null ? null : h.container.read(chatProvider(selected!)).model?.toJson(),
      'writes': ui.writes(h),
      'boundary': h.boundary,
      ...more,
    });
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (final (i, request) in sessions.pending.indexed) {
      if (!request.isCompleted) request.complete('cleanup-$i');
    }
    await ui.disposeHarness(tester, h);
  }
}

const _a = ModelSelection(provider: 'review', model: 'old-A');
const _currentB = ModelSelection(provider: 'review', model: 'current-B');

void _prompt(SyncHarness h, String id, String body) {
  expect(ui.writes(h), ['session/prompt']);
  final request = h.boundary.single['request']! as Map;
  expect(request['sessionId'], id);
  expect((request['content']! as List).single['text'], body);
}

Future<void> _reachModel(WidgetTester tester, _QuoteFlow r, ReplyHold hold, String text) async {
  r.h.container.read(pendingModelProvider.notifier).select(_a);
  await r.send(tester, text);
  expect(r.sessions.pending, hasLength(1));
  r.sessions.pending.first.complete('S');
  await ui.settleIo(tester, () => hold.received!.isCompleted);
  expect(r.selected, 'S');
  expect(r.busy(tester), isTrue);
  expect(ui.writes(r.h), isEmpty);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a quote added during model wait survives and the next gesture sends it', (tester) async {
    final hold = ReplyHold()..arm('session/selectModel');
    final r = await _QuoteFlow.start(tester, hold: hold);
    try {
      await _reachModel(tester, r, hold, 'same typed body');
      await r.baseline(tester, 'S');
      tester.widget<ChatList>(find.byType(ChatList)).onQuote!('new quoted passage');
      await tester.pump();
      expect(tester.widget<QuoteChip>(find.byType(QuoteChip)).quote, 'new quoted passage');
      hold.finish();
      await ui.settleIo(tester, () => !r.busy(tester));
      await pumpFrames(tester);
      r.observe(tester, 'added-before-next-gesture');
      expect(ui.writes(r.h), isEmpty);
      expect(r.input(tester), 'same typed body');
      expect(r.drafts['S']!.text, 'same typed body');
      expect(r.h.container.read(composerQuoteProvider), {'S': 'new quoted passage'});
      await r.send(tester, 'same typed body');
      await ui.settleIo(tester, () => ui.writes(r.h).isNotEmpty);
      _prompt(r.h, 'S', '> new quoted passage\n\nsame typed body');
      expect(r.h.container.read(composerQuoteProvider), isEmpty);
      r.observe(tester, 'added-then-actively-sent');
      expect(tester.takeException(), isNull);
    } finally {
      hold.finish();
      await r.close(tester);
    }
  });

  for (final readyBeforeModel in [true, false]) {
    testWidgets('an unchanged new-draft quote migrates and sends with snapshot before model=$readyBeforeModel', (
      tester,
    ) async {
      final hold = ReplyHold()..arm('session/selectModel');
      final r = await _QuoteFlow.start(tester, hold: hold);
      try {
        final quotes = r.h.container.read(composerQuoteProvider.notifier);
        quotes.set('new', 'original new quote');
        quotes.set('T', 'other session quote');
        final observed = <Map<String, String>>[];
        final subscription = r.h.container.listen(composerQuoteProvider, (_, next) => observed.add(next));
        await _reachModel(tester, r, hold, 'current body');
        expect(r.h.container.read(composerQuoteProvider), {'S': 'original new quote', 'T': 'other session quote'});
        expect(observed, [
          {'S': 'original new quote', 'T': 'other session quote'},
        ], reason: 'Migration has no observable cleared or duplicated intermediate quote');
        subscription.close();
        expect(tester.widget<QuoteChip>(find.byType(QuoteChip)).quote, 'original new quote');
        if (readyBeforeModel) await r.baseline(tester, 'S');
        hold.finish();
        if (!readyBeforeModel) {
          await pumpFrames(tester);
          expect(r.input(tester), 'current body');
          expect(r.busy(tester), isTrue);
          expect(ui.writes(r.h), isEmpty);
          await r.baseline(tester, 'S');
        }
        await ui.settleIo(tester, () => ui.writes(r.h).isNotEmpty);
        _prompt(r.h, 'S', '> original new quote\n\ncurrent body');
        expect(r.h.container.read(composerQuoteProvider), {'T': 'other session quote'});
        r.observe(tester, 'unchanged-sent-$readyBeforeModel');
        expect(tester.takeException(), isNull);
      } finally {
        hold.finish();
        await r.close(tester);
      }
    });
  }

  for (final remove in [false, true]) {
    testWidgets('a migrated quote ${remove ? 'removed' : 'replaced'} during model wait needs a new gesture', (
      tester,
    ) async {
      final hold = ReplyHold()..arm('session/selectModel');
      final r = await _QuoteFlow.start(tester, hold: hold);
      try {
        r.h.container.read(composerQuoteProvider.notifier).set('new', 'original new quote');
        await _reachModel(tester, r, hold, 'body kept');
        await r.baseline(tester, 'S');
        expect(r.h.container.read(composerQuoteProvider)['S'], 'original new quote');
        if (remove) {
          tester.widget<QuoteChip>(find.byType(QuoteChip)).onRemove();
        } else {
          tester.widget<ChatList>(find.byType(ChatList)).onQuote!('replacement quote');
        }
        await tester.pump();
        hold.finish();
        await ui.settleIo(tester, () => !r.busy(tester));
        await pumpFrames(tester);
        expect(ui.writes(r.h), isEmpty);
        expect(r.input(tester), 'body kept');
        expect(r.drafts['S']!.text, 'body kept');
        expect(r.h.container.read(composerQuoteProvider)['S'], remove ? null : 'replacement quote');
        await r.send(tester, 'body kept');
        await ui.settleIo(tester, () => ui.writes(r.h).isNotEmpty);
        _prompt(r.h, 'S', remove ? 'body kept' : '> replacement quote\n\nbody kept');
        expect(r.h.container.read(composerQuoteProvider), isEmpty);
        r.observe(tester, 'edited-quote-sent-$remove');
        expect(tester.takeException(), isNull);
      } finally {
        hold.finish();
        await r.close(tester);
      }
    });
  }

  testWidgets('a quote added during a waiting host command preserves it as a message', (tester) async {
    final hold = ReplyHold()..arm('session/selectModel');
    final r = await _QuoteFlow.start(tester, hold: hold);
    try {
      await _reachModel(tester, r, hold, '/compact');
      await r.baseline(tester, 'S');
      tester.widget<ChatList>(find.byType(ChatList)).onQuote!('command context');
      await tester.pump();
      hold.finish();
      await ui.settleIo(tester, () => !r.busy(tester));
      await pumpFrames(tester);
      expect(r.h.methods.where((method) => method == 'commands/execute'), isEmpty);
      expect(ui.writes(r.h), isEmpty);
      expect(r.input(tester), '/compact');
      expect(r.h.container.read(composerQuoteProvider)['S'], 'command context');
      await r.send(tester, '/compact');
      await ui.settleIo(tester, () => ui.writes(r.h).isNotEmpty);
      _prompt(r.h, 'S', '> command context\n\n/compact');
      expect(r.h.methods.where((method) => method == 'commands/execute'), isEmpty);
      r.observe(tester, 'host-command-became-quoted-message');
      expect(tester.takeException(), isNull);
    } finally {
      hold.finish();
      await r.close(tester);
    }
  });

  testWidgets('a failed initial model retains the draft until a successful choice and new send', (tester) async {
    final hold = ReplyHold()..arm('session/selectModel');
    final r = await _QuoteFlow.start(tester, hold: hold, modelFails: true);
    try {
      await _reachModel(tester, r, hold, 'body after model failure');
      await r.baseline(tester, 'S');
      hold.finish();
      await ui.settleIo(tester, () => !r.busy(tester));
      await pumpFrames(tester);
      expect(ui.writes(r.h), isEmpty);
      expect(r.input(tester), 'body after model failure');
      expect(r.drafts['S']!.text, 'body after model failure');
      expect(r.h.container.read(chatProvider('S')).error, isNotNull);
      _QuoteFlow.installHandlers(r.h);
      bool? changed;
      r.h.container.read(chatProvider('S').notifier).setModel(_currentB).then((value) => changed = value);
      await ui.settleIo(tester, () => changed != null);
      expect(changed, isTrue);
      expect(r.h.container.read(chatProvider('S')).model!.toJson(), _currentB.toJson());
      await r.send(tester, 'body after model failure');
      await ui.settleIo(tester, () => ui.writes(r.h).isNotEmpty);
      _prompt(r.h, 'S', 'body after model failure');
      r.observe(tester, 'current-model-failed-then-active-send');
      expect(tester.takeException(), isNull);
    } finally {
      hold.finish();
      await r.close(tester);
    }
  });

  testWidgets('a superseded initial model cannot resume sending while the new choice still waits', (tester) async {
    final hold = ReplyHold()..arm('session/selectModel');
    final r = await _QuoteFlow.start(tester, hold: hold);
    Completer<void>? oldRelease;
    try {
      await _reachModel(tester, r, hold, 'body for chosen model');
      await r.baseline(tester, 'S');
      oldRelease = hold.release;
      hold.arm('session/selectModel');
      bool? changed;
      r.h.container.read(chatProvider('S').notifier).setModel(_currentB).then((value) => changed = value);
      await ui.settleIo(tester, () => hold.received!.isCompleted);
      oldRelease!.complete();
      await ui.settleIo(tester, () => !r.busy(tester));
      await pumpFrames(tester);
      expect(changed, isNull);
      expect(ui.writes(r.h), isEmpty);
      expect(r.input(tester), 'body for chosen model');
      expect(r.drafts['S']!.text, 'body for chosen model');
      expect(r.h.container.read(chatProvider('S')).model!.toJson(), _currentB.toJson());
      hold.finish();
      await ui.settleIo(tester, () => changed != null);
      expect(changed, isTrue);
      await r.send(tester, 'body for chosen model');
      await ui.settleIo(tester, () => ui.writes(r.h).isNotEmpty);
      _prompt(r.h, 'S', 'body for chosen model');
      r.observe(tester, 'superseded-model-then-active-send');
      expect(tester.takeException(), isNull);
    } finally {
      if (oldRelease case final release? when !release.isCompleted) release.complete();
      hold.finish();
      await r.close(tester);
    }
  });
}
