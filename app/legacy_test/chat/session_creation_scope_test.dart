// The screen, draft store, controller, mux/follow and prompt/model/command RPCs
// are real. Only create completion and the loopback Host's replies are staged.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_sync_draft_test.dart' as fixture;
import 'support/harness.dart';
import 'support/session_sync_host.dart';

class _HeldSessions extends FakeSessions {
  final pending = <Completer<String>>[];

  @override
  Future<String> create({bool autoApprove = true}) {
    final request = Completer<String>();
    pending.add(request);
    return request.future;
  }

  void finish(int index, {String id = 'S', bool fail = false}) {
    final request = pending[index];
    if (fail) {
      request.completeError(StateError('Controlled create failure'));
    } else {
      request.complete(id);
    }
  }
}

class _CreationHarness {
  _CreationHarness(this.h, this.sessions, this.overrides);
  final SyncHarness h;
  final _HeldSessions sessions;
  final List<Override> overrides;

  static Future<_CreationHarness> start(WidgetTester tester, {ReplyHold? hold}) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final ui = ChatHarness();
    final sessions = _HeldSessions();
    final overrides = [
      petScopedStateProvider.overrideWith((ref, scope) => const PetState()),
      for (final override in ui.overrides)
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
    h.host.handlers['session/selectModel'] = (args) => {
      'ok': true,
      'value': {'selected': args['request']},
    };
    h.host.handlers['commands/execute'] = (_) => {
      'ok': true,
      'value': {'commandId': 'command-1', 'success': true},
    };
    await fixture.mount(tester, h);
    await pumpFrames(tester);
    return _CreationHarness(h, sessions, overrides);
  }

  String? get selected => h.container.read(currentSessionProvider);
  Map<String, ChatDraft> get drafts => h.container.read(draftStoreProvider).drafts;
  bool busy(WidgetTester tester) => tester.widget<Composer>(find.byType(Composer)).busy;
  String input(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

  void select(String? id) => h.container.read(currentSessionProvider.notifier).select(id);

  void connection(HostConnection? value) =>
      h.container.updateOverrides([...overrides, activeConnectionProvider.overrideWithValue(AsyncData(value))]);

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> baseline(WidgetTester tester, String id) async {
    // S is the harness's first follower; each newly selected target is last.
    await fixture.settleIo(tester, () => id == 'S' || h.follows.length >= 2);
    final follow = id == 'S' ? h.follows.first : h.follows.last;
    await tester.runAsync(() async {
      follow.socket.item(follow.id, {
        ...syncSnapshot(1),
        'header': {...(syncSnapshot(1)['header']! as Map<String, Object?>), 'id': id},
      });
    });
    await fixture.settleIo(tester, () => h.container.read(chatProvider(id)).controlReady);
  }

  void trace(WidgetTester tester, String name) => syncTrace('r3/$name', {
    'current': selected,
    'input': input(tester),
    'busy': busy(tester),
    'drafts': {for (final entry in drafts.entries) entry.key: entry.value.text},
    'attachments': {for (final entry in drafts.entries) entry.key: entry.value.attachments.length},
    'writes': fixture.writes(h),
    'boundary': h.boundary,
    'creates': sessions.pending.length,
  });

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (final (index, pending) in sessions.pending.indexed) {
      if (!pending.isCompleted) pending.complete('cleanup-$index');
    }
    await fixture.disposeHarness(tester, h);
  }
}

const _model = ModelSelection(provider: 'provider', model: 'first-model');
const _nextModel = ModelSelection(provider: 'provider', model: 'next-model');

void _expectPrompt(_CreationHarness c, String sessionId, String text) {
  expect(fixture.writes(c.h), ['session/prompt']);
  final request = c.h.boundary.single['request']! as Map;
  expect(request['sessionId'], sessionId);
  expect((request['content']! as List).single['text'], text);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a new chat is filed only after its own creation succeeds', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      final view = c.h.container.read(drawerViewProvider.notifier);
      final folder = await view.createFolder('Work');
      c.h.container.read(pendingSessionFolderProvider.notifier).select(folder);
      await c.typeAndSend(tester, 'file this conversation');
      expect(c.sessions.pending, hasLength(1));
      c.sessions.finish(0);
      await pumpFrames(tester);
      expect(c.selected, 'S');
      expect(c.h.container.read(drawerViewProvider).folderOf['S'], folder);
      expect(c.h.container.read(pendingSessionFolderProvider), isNull);
      await c.baseline(tester, 'S');
      await fixture.settleIo(tester, () => fixture.writes(c.h).isNotEmpty);
      _expectPrompt(c, 'S', 'file this conversation');
    } finally {
      await c.close(tester);
    }
  });

  testWidgets('a retired new-chat request cannot file its late result', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      final view = c.h.container.read(drawerViewProvider.notifier);
      final folder = await view.createFolder('Work');
      c.h.container.read(pendingSessionFolderProvider.notifier).select(folder);
      await c.typeAndSend(tester, 'old request');
      c.select('T');
      await tester.pump();
      c.sessions.finish(0);
      await pumpFrames(tester);
      expect(c.selected, 'T');
      expect(c.h.container.read(drawerViewProvider).folderOf, isEmpty);
      expect(c.h.container.read(pendingSessionFolderProvider), isNull);
    } finally {
      await c.close(tester);
    }
  });

  testWidgets('late creation preserves new A and T B without consuming the pending model', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      c.h.container.read(pendingModelProvider.notifier).select(_model);
      await c.typeAndSend(tester, 'new A');
      expect(c.sessions.pending, hasLength(1));
      c.select('T');
      await tester.pump();
      expect(c.busy(tester), isFalse, reason: 'Creating S cannot lock the selected T');
      await c.baseline(tester, 'T');
      await tester.enterText(find.byType(TextField), 'T B');
      c.sessions.finish(0);
      await pumpFrames(tester);
      c.trace(tester, 'late-create-after-T');
      expect(c.selected, 'T');
      expect(c.input(tester), 'T B');
      expect(c.drafts['new']!.text, 'new A');
      expect(c.drafts['T']!.text, 'T B');
      expect(c.drafts['S'], isNull);
      expect(c.h.container.read(pendingModelProvider), _model);
      expect(c.h.methods.where((m) => m == 'session/selectModel'), isEmpty);
      expect(fixture.writes(c.h), isEmpty);
      await c.typeAndSend(tester, 'T B');
      await fixture.settleIo(tester, () => fixture.writes(c.h).isNotEmpty);
      _expectPrompt(c, 'T', 'T B');
      expect(c.drafts['new']!.text, 'new A');
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });

  testWidgets('new T new in one event turn permanently retires creation', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      await c.typeAndSend(tester, 'new A');
      c.select('T');
      c.select(null);
      await tester.pump();
      expect(c.busy(tester), isFalse);
      c.sessions.finish(0);
      await pumpFrames(tester);
      c.trace(tester, 'new-T-new-ABA');
      expect(c.selected, isNull);
      expect(c.input(tester), 'new A');
      expect(c.drafts['new']!.text, 'new A');
      expect(c.drafts['S'], isNull);
      expect(fixture.writes(c.h), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });

  for (final fail in [false, true]) {
    for (final next in ['create', 'sync']) {
      testWidgets('retired create ${fail ? 'failure' : 'success'} cannot release newer $next busy', (tester) async {
        final c = await _CreationHarness.start(tester);
        try {
          await c.typeAndSend(tester, 'old A');
          c.select('T');
          c.select(null);
          await tester.pump();
          expect(c.busy(tester), isFalse);
          await c.typeAndSend(tester, 'new B');
          expect(c.sessions.pending, hasLength(2));
          if (next == 'sync') {
            c.sessions.finish(1, id: 'T');
            await tester.pump();
          }
          expect(c.busy(tester), isTrue);
          final syncingMessage = next == 'sync' ? tester.widget<ErrorBanner>(find.byType(ErrorBanner)).message : null;
          c.sessions.finish(0, fail: fail);
          await pumpFrames(tester);
          c.trace(tester, 'old-${fail ? 'failure' : 'success'}-new-$next');
          expect(c.selected, next == 'create' ? isNull : 'T');
          expect(c.busy(tester), isTrue);
          expect(c.input(tester), 'new B');
          expect(c.drafts[next == 'create' ? 'new' : 'T']!.text, 'new B');
          expect(c.drafts['S'], isNull);
          expect(fixture.writes(c.h), isEmpty);
          if (next == 'sync') {
            // The existing informational synchronizing banner is legitimate.
            expect(tester.widget<ErrorBanner>(find.byType(ErrorBanner)).message, syncingMessage);
            expect(c.h.container.read(chatProvider('T')).error, isNull);
            expect(c.h.container.read(chatProvider('T')).notice, isNull);
          } else {
            expect(find.byType(ErrorBanner), findsNothing);
          }
          final target = next == 'create' ? 'U' : 'T';
          if (next == 'create') {
            c.sessions.finish(1, id: target);
            await tester.pump();
          }
          await c.baseline(tester, target);
          await fixture.settleIo(tester, () => fixture.writes(c.h).isNotEmpty);
          _expectPrompt(c, target, 'new B');
          expect(c.busy(tester), isFalse);
          if (next == 'sync') {
            c.select(null);
            await pumpFrames(tester);
            expect(find.byType(ErrorBanner), findsNothing, reason: 'No old local create error was hidden behind T');
          }
          expect(tester.takeException(), isNull);
        } finally {
          await c.close(tester);
        }
      });
    }
  }

  testWidgets('current create failure retains draft and a new gesture can complete after a real baseline', (
    tester,
  ) async {
    final c = await _CreationHarness.start(tester);
    try {
      await c.typeAndSend(tester, 'retry A');
      c.sessions.finish(0, fail: true);
      await pumpFrames(tester);
      expect(c.selected, isNull);
      expect(c.busy(tester), isFalse);
      expect(c.input(tester), 'retry A');
      expect(c.drafts['new']!.text, 'retry A');
      expect(find.byType(ErrorBanner), findsOneWidget);
      await c.typeAndSend(tester, 'retry A');
      expect(c.sessions.pending, hasLength(2));
      c.sessions.finish(1);
      await tester.pump();
      expect(c.selected, 'S');
      expect(c.drafts['new'], isNull);
      expect(c.drafts['S']!.text, 'retry A');
      expect(c.busy(tester), isTrue);
      expect(fixture.writes(c.h), isEmpty);
      await c.baseline(tester, 'S');
      await fixture.settleIo(tester, () => fixture.writes(c.h).isNotEmpty);
      _expectPrompt(c, 'S', 'retry A');
      expect(c.drafts['S'], isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });

  testWidgets('a disposed creation cannot alter the remounted page or release its new creation', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      await c.typeAndSend(tester, 'before dispose');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      await fixture.mount(tester, c.h);
      await pumpFrames(tester);
      expect(c.input(tester), 'before dispose');
      await c.typeAndSend(tester, 'after remount');
      expect(c.sessions.pending, hasLength(2));
      c.sessions.finish(0);
      await pumpFrames(tester);
      c.trace(tester, 'disposed-create-remounted');
      expect(c.selected, isNull);
      expect(c.busy(tester), isTrue);
      expect(c.input(tester), 'after remount');
      expect(c.drafts['new']!.text, 'after remount');
      expect(c.drafts['S'], isNull);
      expect(fixture.writes(c.h), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });

  for (final replace in [false, true]) {
    testWidgets('creation cannot regain ownership after client ${replace ? 'replacement' : 'removal and return'}', (
      tester,
    ) async {
      final c = await _CreationHarness.start(tester);
      SyncHarness? replacement;
      try {
        await c.typeAndSend(tester, 'client A');
        if (replace) {
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              replacement = await SyncHarness.start(initialSnapshot: false);
            }, RealSyncHttp()),
          );
          c.connection(HostConnection(hostId: '', client: replacement!.client, isLocal: true));
          await tester.pump();
        } else {
          c.connection(null);
          await tester.pump();
          expect(c.busy(tester), isFalse);
          c.connection(HostConnection(hostId: '', client: c.h.client, isLocal: true));
          await tester.pump();
        }
        expect(c.busy(tester), isFalse);
        c.sessions.finish(0);
        await pumpFrames(tester);
        c.trace(tester, 'client-${replace ? 'replacement' : 'ABA'}');
        expect(c.selected, isNull);
        expect(c.input(tester), 'client A');
        expect(c.drafts['new']!.text, 'client A');
        expect(c.drafts['S'], isNull);
        expect(fixture.writes(c.h), isEmpty);
        if (replacement != null) expect(fixture.writes(replacement!), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await c.close(tester);
        if (replacement != null) await tester.runAsync(() => replacement!.close());
      }
    });
  }

  testWidgets('the same client with a new mux cannot use the old creation result', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      await c.typeAndSend(tester, 'generation A');
      final generation = c.h.client.mux.generation;
      await tester.runAsync(() async => c.h.client.mux.reconnect());
      await fixture.settleIo(
        tester,
        () => c.h.follows.length >= 2 && !identical(c.h.client.mux.generation, generation),
      );
      c.sessions.finish(0);
      await pumpFrames(tester);
      c.trace(tester, 'mux-retirement');
      expect(c.selected, isNull);
      expect(c.busy(tester), isFalse);
      expect(c.drafts['new']!.text, 'generation A');
      expect(c.drafts['S'], isNull);
      expect(fixture.writes(c.h), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });

  for (final edit in ['text', 'attachment']) {
    testWidgets('editing $edit during create cannot send or erase old content when the baseline is already ready', (
      tester,
    ) async {
      final c = await _CreationHarness.start(tester);
      try {
        await c.typeAndSend(tester, 'original A');
        await c.baseline(tester, 'S');
        if (edit == 'text') {
          await tester.enterText(find.byType(TextField), 'edited B');
        } else {
          tester
              .state<EditableTextState>(find.byType(EditableText))
              .insertContent(
                KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://test/created', data: tinyPng),
              );
        }
        c.sessions.finish(0);
        await pumpFrames(tester);
        c.trace(tester, 'edited-$edit-ready');
        expect(c.selected, 'S');
        expect(c.busy(tester), isFalse);
        expect(c.input(tester), edit == 'text' ? 'edited B' : 'original A');
        expect(c.drafts['S']!.text, edit == 'text' ? 'edited B' : 'original A');
        expect(c.drafts['S']!.attachments, hasLength(edit == 'attachment' ? 1 : 0));
        expect(fixture.writes(c.h), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await c.close(tester);
      }
    });
  }

  testWidgets('new chat keeps default-save warning through model selection, first prompt and fresh snapshot', (
    tester,
  ) async {
    final c = await _CreationHarness.start(tester);
    try {
      c.h.host.handlers['session/selectModel'] = (args) => {
        'ok': true,
        'value': {
          'selected': args['request'],
          'defaultSave': {'status': 'failed', 'code': 'settings/default-save-failed'},
        },
      };
      c.h.container.read(pendingModelProvider.notifier).select(_model);
      await c.typeAndSend(tester, 'first prompt after model choice');
      c.sessions.finish(0);
      await fixture.settleIo(tester, () => c.h.container.read(chatProvider('S')).defaultModelSaveFailed);
      await c.baseline(tester, 'S');
      await fixture.settleIo(tester, () => fixture.writes(c.h).isNotEmpty && !c.busy(tester));
      _expectPrompt(c, 'S', 'first prompt after model choice');
      expect(c.h.container.read(chatProvider('S')).model!.toJson(), _model.toJson());
      expect(c.h.container.read(chatProvider('S')).error, isNull);
      expect(c.h.container.read(chatProvider('S')).defaultModelSaveFailed, isTrue);
      expect(find.text(appL10n.engineModelDefaultSaveFailed), findsOneWidget);
      final banner = tester.widget<ErrorBanner>(find.byType(ErrorBanner));
      expect(banner.message, appL10n.engineModelDefaultSaveFailed);
      banner.onDismiss!();
      await pumpFrames(tester);
      expect(c.h.container.read(chatProvider('S')).defaultModelSaveFailed, isFalse);
      expect(find.text(appL10n.engineModelDefaultSaveFailed), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });

  testWidgets('late model completion cannot send S or release a newer creation and its model', (tester) async {
    final hold = ReplyHold()..arm('session/selectModel');
    final c = await _CreationHarness.start(tester, hold: hold);
    try {
      c.h.container.read(pendingModelProvider.notifier).select(_model);
      await c.typeAndSend(tester, 'S A');
      c.sessions.finish(0);
      await fixture.settleIo(tester, () => hold.received!.isCompleted);
      expect(c.selected, 'S');
      expect(c.busy(tester), isTrue);
      expect(c.drafts['S']!.text, 'S A');
      c.select(null);
      await tester.pump();
      c.h.container.read(pendingModelProvider.notifier).select(_nextModel);
      await c.typeAndSend(tester, 'U B');
      expect(c.sessions.pending, hasLength(2));
      hold.finish();
      await pumpFrames(tester);
      c.trace(tester, 'model-completion-new-create');
      expect(c.selected, isNull);
      expect(c.busy(tester), isTrue);
      expect(c.input(tester), 'U B');
      expect(c.drafts['S']!.text, 'S A');
      expect(c.drafts['new']!.text, 'U B');
      expect(c.h.container.read(pendingModelProvider), _nextModel);
      expect(fixture.writes(c.h), isEmpty);
      c.sessions.finish(1, id: 'U');
      await fixture.settleIo(tester, () => c.h.methods.where((m) => m == 'session/selectModel').length == 2);
      await c.baseline(tester, 'U');
      await fixture.settleIo(tester, () => fixture.writes(c.h).isNotEmpty);
      _expectPrompt(c, 'U', 'U B');
      expect(c.h.container.read(pendingModelProvider), isNull);
      expect(c.h.container.read(chatProvider('U')).model!.toJson(), _nextModel.toJson());
      expect(c.drafts['S']!.text, 'S A');
      expect(tester.takeException(), isNull);
    } finally {
      hold.finish();
      await c.close(tester);
    }
  });

  for (final retire in [false, true]) {
    testWidgets('host slash creation ${retire ? 'retires on navigation' : 'still executes in its own session'}', (
      tester,
    ) async {
      final c = await _CreationHarness.start(tester);
      try {
        await c.typeAndSend(tester, '/compact');
        expect(c.sessions.pending, hasLength(1));
        if (retire) {
          c.select('T');
          await tester.pump();
          await tester.enterText(find.byType(TextField), 'T B');
        }
        c.sessions.finish(0);
        await pumpFrames(tester);
        if (retire) {
          expect(c.selected, 'T');
          expect(c.input(tester), 'T B');
          expect(c.drafts['new']!.text, '/compact');
          expect(c.drafts['T']!.text, 'T B');
          expect(c.drafts['S'], isNull);
          expect(c.h.methods.where((m) => m == 'commands/execute'), isEmpty);
        } else {
          await fixture.settleIo(tester, () => c.h.methods.contains('commands/execute'));
          expect(c.selected, 'S');
          expect(c.input(tester), isEmpty);
          expect(c.h.methods.where((m) => m == 'commands/execute'), hasLength(1));
        }
        expect(c.busy(tester), isFalse);
        expect(fixture.writes(c.h), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await c.close(tester);
      }
    });
  }

  testWidgets('an already synchronized S T S change also retires the pre-send continuation', (tester) async {
    final c = await _CreationHarness.start(tester);
    try {
      c.select('S');
      await tester.pump();
      await c.baseline(tester, 'S');
      await tester.enterText(find.byType(TextField), 'S A');
      // The actual Composer callback begins synchronously; its first await is
      // _ensureSession even for an existing session. Navigate before it resumes.
      tester.widget<Composer>(find.byType(Composer)).onSend();
      c.select('T');
      c.select('S');
      await pumpFrames(tester);
      c.trace(tester, 'ready-S-T-S-ABA');
      expect(c.selected, 'S');
      expect(c.input(tester), 'S A');
      expect(c.drafts['S']!.text, 'S A');
      expect(c.sessions.pending, isEmpty);
      expect(fixture.writes(c.h), isEmpty);
      expect(c.busy(tester), isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await c.close(tester);
    }
  });
}
