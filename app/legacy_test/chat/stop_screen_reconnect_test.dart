import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

class _Host extends Notifier<AsyncValue<HostConnection?>> {
  @override
  AsyncValue<HostConnection?> build() => AsyncData(fakeConnection);

  void use(DshClient client) => state = AsyncData(HostConnection(hostId: '', client: client, isLocal: true));
}

final _host = NotifierProvider<_Host, AsyncValue<HostConnection?>>(_Host.new);

class _LateChat extends FakeChatController {
  _LateChat(super.sessionId, super.initial);
  final lost = Completer<List<PendingPrompt>>();

  @override
  Future<List<PendingPrompt>> cancel() {
    cancels++;
    return lost.future;
  }

  @override
  Future<List<PendingPrompt>> sendNow(PendingPrompt prompt) {
    sentNow.add(prompt.requestId);
    return lost.future;
  }
}

const _text = '只属于旧主机的消息';
final _prompt = PendingPrompt(
  requestId: 'old-prompt',
  text: _text,
  time: DateTime(2026, 10, 27),
  mode: SendMode.queue,
  inboxId: 'old-inbox',
  slot: InboxSlot.nextTurn,
);

Future<ProviderContainer> _screen(WidgetTester tester, _LateChat chat) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 'same-id');
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        for (final override in harness.overrides)
          if (override.origin != activeConnectionProvider && override.origin != chatProvider) override,
        activeConnectionProvider.overrideWith((ref) => ref.watch(_host)),
        chatProvider.overrideWith2((_) => chat),
      ],
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
}

String _composer(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<void> _replace(WidgetTester tester, ProviderContainer container) async {
  final replacement = DshClient(DshConnection(Uri.parse('http://127.0.0.1:10')));
  addTearDown(replacement.close);
  container.read(_host.notifier).use(replacement);
  await pumpFrames(tester);
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final replace in [false, true]) {
    testWidgets('late failed send restores only its connection: replace=$replace', (tester) async {
      final chat = _LateChat('same-id', const ChatState(loading: false));
      final result = Completer<bool>();
      chat.sendResult = result.future;
      final container = await _screen(tester, chat);
      await tester.enterText(find.byType(TextField), _text);
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await tester.pump();
      expect(chat.sent, [_text]);
      expect(_composer(tester), isEmpty);
      if (replace) await _replace(tester, container);
      result.complete(false);
      await pumpFrames(tester);
      expect(_composer(tester), replace ? isEmpty : _text);
      if (replace) expect(container.read(draftStoreProvider).drafts['same-id']?.text, isNot(_text));
      await _dispose(tester);
    });
  }

  for (final sendNow in [false, true]) {
    testWidgets('late inbox recovery cannot populate replacement composer: sendNow=$sendNow', (tester) async {
      final chat = _LateChat(
        'same-id',
        ChatState(loading: false, running: true, pending: sendNow ? [_prompt] : const []),
      );
      final container = await _screen(tester, chat);
      if (sendNow) {
        await tester.tap(find.text('立即发送'));
      } else {
        await tester.tap(find.byIcon(AppIcons.stopGenerating));
      }
      await tester.pump();
      if (sendNow) {
        expect(chat.sentNow, ['old-prompt']);
      } else {
        expect(chat.cancels, 1);
      }
      await _replace(tester, container);
      chat.lost.complete([_prompt]);
      await pumpFrames(tester);
      expect(_composer(tester), isEmpty);
      expect(container.read(draftStoreProvider).drafts['same-id']?.text, isNot(_text));
      await _dispose(tester);
    });
  }
}
