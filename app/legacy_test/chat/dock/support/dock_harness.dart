import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/goal_dock_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/dock/chat_dock.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';
import 'goal_fakes.dart';

/// Tue 2026-10-20 15:00 (as the strip goldens): a fixed turn clock.
final dockNow = DateTime(2026, 10, 20, 15);

const todosRunning = [
  TodoItem('找到重复提交的原因', 'completed'),
  TodoItem('给提交加锁', 'completed'),
  TodoItem('补一个连点测试', 'completed'),
  TodoItem('跑测试', 'in_progress'),
  TodoItem('更新 README 的运行说明', 'pending'),
  TodoItem('整理改动说明', 'pending'),
  TodoItem('提交前再看一遍', 'pending'),
];

const todosDone = [
  TodoItem('找到重复提交的原因', 'completed'),
  TodoItem('给提交加锁', 'completed'),
  TodoItem('补一个连点测试', 'completed'),
];

/// The strip of a running `flutter test`, as the chat shows it under the dock.
RunActivity dockStrip() => RunActivity(
  kind: ActivityKind.tool,
  title: '跑',
  detail: 'flutter test test/auth',
  detailIsCode: true,
  since: dockNow.subtract(const Duration(seconds: 9)),
  turnStart: dockNow.subtract(const Duration(seconds: 47)),
);

/// A chat column as in ChatScreen: 12 from the sides, dock, strip, composer.
class DockHarness {
  DockHarness({ChatState state = const ChatState(loading: false), FakeGoalBackend? backend})
    : initial = state,
      backend = backend ?? FakeGoalBackend(canRead: false);

  final ChatState initial;
  final FakeGoalBackend backend;
  final controllers = <String, FakeChatController>{};

  FakeChatController get chat => controllers['s1']!;

  Future<void> pump(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool strip = false,
    bool composer = true,
    bool deck = false,
    bool disableAnimations = false,
    Widget? above,
    Size? viewSize,
  }) async {
    usePhoneView(tester);
    if (viewSize != null) tester.view.physicalSize = viewSize * 2;
    addTearDown(backend.close);
    final input = TextEditingController();
    addTearDown(input.dispose);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: disableAnimations),
            child: Scaffold(
              body: AppBackdrop(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?above,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 40),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (deck)
                            BackdropGroup(
                              child: DockStack(
                                cards: [
                                  const TodoDockSlot(sessionId: 's1'),
                                  const GoalDockSlot(sessionId: 's1'),
                                  if (strip)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      // As the chat page: the count shows on the strip while the todo bar is folded behind it.
                                      child: Consumer(
                                        builder: (context, ref, _) => ActivityStrip(
                                          activity: dockStrip(),
                                          todoProgress: ref.watch(dockFoldedProvider),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            )
                          else ...[
                            const ChatDock(sessionId: 's1'),
                            if (strip)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: ActivityStrip(activity: dockStrip()),
                              ),
                          ],
                          if (composer)
                            Composer(
                              controller: input,
                              connected: true,
                              running: strip,
                              onSend: () {},
                              onStop: () {},
                              leading: AttachButton(onPressed: () {}),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        brightness: brightness,
        overrides: [
          goalBackendProvider.overrideWithValue(backend),
          chatProvider.overrideWith2((id) => controllers[id] = FakeChatController(id, initial)),
        ],
      ),
    );
    await pumpFrames(tester, 4);
  }

  /// The log moves on.
  Future<void> emit(WidgetTester tester, ChatState state) async {
    chat.emit(state);
    await pumpFrames(tester, 6);
  }
}
