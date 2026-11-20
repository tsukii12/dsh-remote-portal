import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/share/share_entry.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Connection states played by the test.
class _Mux extends DshMux {
  _Mux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();

  @override
  Stream<DshConnectionState> get states => connection.stream;
}

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  late final _mux = _Mux(carrier);
  final watches = <StreamController<DshEvent>>[];
  int cancellations = 0;
  final optionsSeen = <WatchOptions>[];
  String? requestId;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    optionsSeen.add(options);
    final stream = StreamController<DshEvent>(onCancel: () => cancellations++);
    watches.add(stream);
    return stream.stream;
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    this.requestId = requestId;
    return requestId!;
  }

  @override
  _Mux get mux => _mux;
}

SessionSnapshotEvent _snapshot(String text, {String? requestId}) => SessionSnapshotEvent.fromJson('a', {
  'cursor': 1,
  'records': [
    {
      'event': {
        'seq': 1,
        'time': 1792700000000,
        'type': 'user/message',
        'data': {
          'id': 'message',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'user', 'rpcId': requestId ?? 'old'},
        },
      },
    },
  ],
});

ProviderContainer _container(_Client client) => ProviderContainer(
  overrides: [
    activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, label: '本机', isLocal: true))),
  ],
);

class _ShareChat extends ChatController {
  _ShareChat(super.sessionId, this.onDisposed);
  final VoidCallback onDisposed;
  @override
  ChatState build() {
    ref.onDispose(onDisposed);
    return const ChatState(
      loading: false,
      items: [AssistantChatItem(id: 'a1', seq: 1, text: '分享的回复', reasoning: '')],
    );
  }
}

void main() {
  testWidgets(
    'only a live interaction lease permits activation; preview and background stay passive',
    (tester) async {
      final client = _Client();
      final container = _container(client);
      final sub = container.listen(chatProvider('a'), (_, _) {});
      final chat = container.read(chatProvider('a').notifier);
      // The passive follow keeps its baseline when an interaction starts.
      client.watches.single.add(_snapshot('内容'));
      await tester.pump();
      expect(client.optionsSeen.single.activationAllowed!(), isFalse);
      var foreground = true;
      final leave = chat.beginInteraction(() => foreground);
      expect(client.optionsSeen.last.activate, isTrue);
      expect(client.optionsSeen.last.activationAllowed!(), isTrue);
      expect(
        client.optionsSeen.length,
        1,
        reason: 'interaction never replaces the main follow',
      );
      foreground = false;
      expect(client.optionsSeen.last.activationAllowed!(), isFalse);
      foreground = true;
      expect(client.optionsSeen.last.activationAllowed!(), isTrue);
      leave();
      expect(client.optionsSeen.last.activationAllowed!(), isFalse);
      sub.close();
      container.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'regaining a lease never replaces either pending or ready primary follow',
    (tester) async {
      final client = _Client();
      final container = _container(client);
      final sub = container.listen(chatProvider('a'), (_, _) {});
      final chat = container.read(chatProvider('a').notifier);
      for (final ready in [false, true]) {
        if (ready) {
          client.watches.single.add(_snapshot('内容'));
          await tester.pump();
        }
        for (var i = 0; i < 3; i++) {
          final leave = chat.beginInteraction(() => true);
          expect(client.optionsSeen.single.activationAllowed!(), isTrue);
          leave();
          expect(client.optionsSeen.single.activationAllowed!(), isFalse);
        }
        expect(client.optionsSeen.length, 1);
        expect(client.cancellations, 0);
      }
      sub.close();
      container.dispose();
      await tester.pump();
    },
  );

  testWidgets('sharing an unopened conversation retains it while the panel is up', (tester) async {
    var disposed = 0;
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => shareConversation(context, 'unopened'), child: const Text('分享')),
          ),
        ),
        overrides: [chatProvider.overrideWith2((id) => _ShareChat(id, () => disposed++))],
      ),
    );
    await tester.tap(find.text('分享'));
    await pumpFrames(tester);
    expect(find.byType(ShareCard), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    expect(disposed, 0);
    final card = tester.widget<ShareCard>(find.byType(ShareCard));
    expect((card.content.blocks.single as ShareAnswer).markdown, '分享的回复');
    Navigator.of(tester.element(find.byType(ShareCard))).pop();
    await pumpFrames(tester);
    expect(disposed, 1);
  });

  testWidgets('a lost stream follows again once reconnected, keeping what it had', (tester) async {
    final client = _Client();
    final container = _container(client);
    final sub = container.listen(chatProvider('a'), (_, _) {});
    final chat = container.read(chatProvider('a').notifier);
    client.watches.single.add(_snapshot('旧内容'));
    await tester.pump(const Duration(milliseconds: 40));
    unawaited(chat.send('待回显'));
    await tester.pump();
    client.watches.single.addError(StateError('gone'));
    await client.watches.single.close();
    await tester.pump();
    expect(sub.read().error, '对话同步中断');
    expect(sub.read().streamLost, isTrue);
    expect(sub.read().items.whereType<UserChatItem>().single.text, '旧内容');
    expect(sub.read().pending, hasLength(1));
    client.mux.connection.add(DshConnectionState.connected);
    await tester.pump();
    expect(client.watches, hasLength(2));
    client.watches.last.add(_snapshot('待回显', requestId: client.requestId));
    await tester.pump(const Duration(milliseconds: 40));
    expect(sub.read().pending, isEmpty);
    expect(sub.read().streamLost, isFalse);
    expect(sub.read().error, isNull);
    // Reconnected while following: nothing to reopen.
    client.mux.connection.add(DshConnectionState.connected);
    await tester.pump();
    expect(client.watches, hasLength(2));
    sub.close();
    container.dispose();
  });

  testWidgets('not-found returns to a new chat without a word', (tester) async {
    final client = _Client();
    final container = _container(client);
    container.read(currentSessionProvider.notifier).select('a');
    final sub = container.listen(chatProvider('a'), (_, _) {});
    client.watches.single.addError(const DshRemoteException('session/not-found', 'gone'));
    await tester.pump(const Duration(seconds: 3));
    expect(container.read(currentSessionProvider), isNull);
    expect(sub.read().error, isNull);
    expect(sub.read().streamLost, isFalse);
    sub.close();
    container.dispose();
  });

  testWidgets('a new connection keeps the history until its snapshot', (tester) async {
    final first = _Client();
    final second = _Client();
    final container = _container(first);
    final sub = container.listen(chatProvider('a'), (_, _) {});
    first.watches.single.add(_snapshot('旧内容'));
    await tester.pump(const Duration(milliseconds: 40));
    container.updateOverrides([activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null))]);
    await tester.pump();
    expect(sub.read().items.whereType<UserChatItem>().single.text, '旧内容');
    expect(sub.read().loading, isFalse);
    expect(sub.read().running, isFalse);
    expect(sub.read().approvals, isEmpty);
    container.updateOverrides([
      activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: second, label: '本机', isLocal: true))),
    ]);
    await tester.pump();
    expect(sub.read().items.whereType<UserChatItem>().single.text, '旧内容');
    second.watches.single.add(_snapshot('新内容'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(sub.read().items.whereType<UserChatItem>().single.text, '新内容');
    sub.close();
    container.dispose();
  });

  testWidgets('an idle conversation goes after a minute; a quick return reuses it', (tester) async {
    final client = _Client();
    final container = _container(client);
    var sub = container.listen(chatProvider('a'), (_, _) {});
    final original = container.read(chatProvider('a').notifier);
    client.watches.single.add(_snapshot('内容'));
    await tester.pump(const Duration(milliseconds: 40));
    sub.close();
    await tester.pump(const Duration(seconds: 30));
    sub = container.listen(chatProvider('a'), (_, _) {});
    expect(container.read(chatProvider('a').notifier), same(original));
    expect(sub.read().loading, isFalse);
    sub.close();
    await tester.pump(const Duration(seconds: 61));
    expect(client.cancellations, 1);
    container.dispose();
  });

  for (final condition in ['running', 'pending', 'autoApprove']) {
    testWidgets('$condition keeps an unwatched conversation until idle', (tester) async {
      final client = _Client();
      final container = _container(client);
      final sub = container.listen(chatProvider('a'), (_, _) {});
      final chat = container.read(chatProvider('a').notifier);
      switch (condition) {
        case 'running':
          client.watches.single.add(const SessionStatusEvent('a', true));
        case 'pending':
          // A send is pending only after the follow supplied its baseline.
          client.watches.single.add(SessionSnapshotEvent.fromJson('a', {'cursor': -1, 'records': <Object?>[]}));
          await tester.pump(const Duration(milliseconds: 40));
          unawaited(chat.send('待回显'));
        default:
          chat.setAutoApprove(true);
      }
      await tester.pump(const Duration(milliseconds: 40));
      sub.close();
      await tester.pump(const Duration(seconds: 90));
      expect(client.cancellations, 0);
      switch (condition) {
        case 'running':
          client.watches.single.add(const SessionStatusEvent('a', false));
        case 'pending':
          client.watches.single.add(_snapshot('待回显', requestId: client.requestId));
        default:
          chat.setAutoApprove(false);
      }
      await tester.pump(const Duration(seconds: 61));
      expect(client.cancellations, 1);
      container.dispose();
    });
  }
}
