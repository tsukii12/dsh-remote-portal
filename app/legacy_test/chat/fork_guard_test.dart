import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

class _ForkController extends FakeChatController {
  _ForkController(super.sessionId, super.initial) {
    branchPoints[2] = 3;
  }
  final gate = Completer<ForkOutcome?>();
  @override
  Future<ForkOutcome?> branchAfter(AssistantChatItem item) {
    branched.add(item.seq!);
    return gate.future;
  }
}

class _Harness extends ChatHarness {
  _Harness() : super(session: 's1');
  late _ForkController controller;
  @override
  List<Override> get overrides {
    final list = super.overrides;
    list.removeLast(); // The harness's final override is chatProvider.
    list.add(
      chatProvider.overrideWith2(
        (id) => id == 's1'
            ? controller = _ForkController(id, ChatState(loading: false, items: [user(1, 'q'), assistant(2, 'a')]))
            : FakeChatController(id, const ChatState(loading: false)),
      ),
    );
    return list;
  }
}

void main() {
  setUpAll(loadTestFonts);
  testWidgets('repeated fork taps share one operation and preserve button geometry', (tester) async {
    usePhoneView(tester);
    final harness = _Harness();
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 4);
    final branch = find.byTooltip('从这里分叉');
    await tester.tap(branch);
    await tester.tap(branch);
    await tester.pump();
    expect(harness.controller.branched, [2]);
    expect(find.descendant(of: branch, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    final button = find.ancestor(of: branch, matching: find.byType(IconButton));
    final copy = find.byTooltip('复制');
    expect(tester.getSize(button), const Size(36, 36));
    expect(tester.getSize(branch), tester.getSize(copy));
    harness.controller.gate.complete(const ForkOutcome('fork-session'));
    await pumpFrames(tester, 4);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(container.read(currentSessionProvider), 'fork-session');
  });
}
