// Subagents as first-class conversations: the 子代理 tab's lineage tree, the
// header's 「N 个子代理」 capsule and sheet, and a child conversation's
// breadcrumb back to its parent (no model chip there: a child's model is its
// parent's to route). Goldens in light and dark; header geometry measured.
//
//   flutter test --update-goldens test/agents/lineage_test.dart

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_app/ui/agents/agent_widgets.dart';
import 'package:dsh_app/ui/agents/header_agents.dart';
import 'package:dsh_app/ui/agents/lineage_sheet.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart' show GlassSurface;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import 'support.dart';

ChatState _parentChat() => ChatState(
  loading: false,
  title: '修复登录重复提交',
  items: [
    user(1, '把登录的重复提交修好，顺便补测试'),
    assistant(2, '我派三个子代理分头处理：审查改动、补测试、查 CI 日志。'),
    tool('call-1', 'subagent', {
      'description': '审查改动',
      'prompt': '审查 lib/auth 下的改动',
    }, result: 'started subagent $reviewerId'),
    tool('call-2', 'subagent', {'description': '补连点的测试', 'prompt': '给登录页补连点的组件测试'}, status: ToolStatus.running),
  ],
);

ChatState _childChat() => ChatState(
  loading: false,
  title: 'Review the login fix',
  items: [user(1, '审查 lib/auth 下的改动，结果用 send_message 发回上级对话。'), assistant(2, '改动没问题：提交中禁用按钮，`finally` 里复位。建议补一个连点测试。')],
);

List<Override> _overrides(ChatHarness harness) => [
  ...harness.overrides,
  ...agentsOverrides(sampleAgentSessions()),
  workspaceSourceProvider.overrideWith((ref, id) => null),
  workspaceRootProvider.overrideWith((ref, id) => null),
];

ChatHarness _harness(String session) =>
    ChatHarness(session: session, states: {parentId: _parentChat(), reviewerId: _childChat()});

Future<ProviderContainer> _pumpChat(
  WidgetTester tester,
  String session, {
  Brightness brightness = Brightness.light,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(const ChatScreen(), brightness: brightness, overrides: _overrides(_harness(session))),
  );
  await pumpFrames(tester, 6);
  return ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
}

Future<ProviderContainer> _pumpTab(WidgetTester tester, {Brightness brightness = Brightness.light}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      const SessionDetailPage(sessionId: parentId, initialTab: SessionTab.subagents),
      brightness: brightness,
      overrides: _overrides(_harness(parentId)),
    ),
  );
  await pumpFrames(tester, 8);
  return ProviderScope.containerOf(tester.element(find.byType(SessionDetailPage)));
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 24, 14, 30);
  });
  setUp(() => runClock = () => agentsNow);
  tearDown(() => runClock = DateTime.now);

  group('details tab', () {
    testWidgets('the tree: states, nesting, the dispatch log under it', (tester) async {
      await _pumpTab(tester);
      expect(find.text('3 个子代理'), findsOneWidget);
      expect(find.text('审查改动'), findsWidgets);
      expect(find.text('对照官方文档'), findsOneWidget);
      expect(find.text('已完成'), findsWidgets);
      expect(find.text('运行中'), findsOneWidget);
      expect(find.text('出错'), findsOneWidget);
      expect(find.text('派活记录'), findsOneWidget);
      // The running child's time ticks from its open turn.
      expect(find.textContaining('47 秒'), findsOneWidget);
      // The nested child sits one indent further in.
      final top = tester.getRect(
        find.descendant(of: find.widgetWithText(SubagentRow, '审查改动'), matching: find.byType(AgentAvatar)),
      );
      final nested = tester.getRect(
        find.descendant(of: find.widgetWithText(SubagentRow, '对照官方文档'), matching: find.byType(AgentAvatar)),
      );
      expect(nested.left - top.left, closeTo(SubagentRow.indent, 0.01));
    });

    testWidgets('a row opens that conversation, routed through its parent', (tester) async {
      final container = await _pumpTab(tester);
      await tester.tap(find.widgetWithText(SubagentRow, '补连点的测试'));
      await pumpFrames(tester, 4);
      expect(container.read(currentSessionProvider), testsId);
      expect(
        fakeConnection.client.subagentRoute(testsId),
        const SubagentAddress(parentSessionId: parentId, childSessionId: testsId, mode: SubagentMode.continuable),
      );
    });
  });

  group('header', () {
    testWidgets('the hidden busy dot stops ticking once no child runs (#1094)', (tester) async {
      Finder mutedDot() => find.descendant(
        of: find.byType(HeaderAgentsKey),
        matching: find.byWidgetPredicate((w) => w is TickerMode && !w.enabled),
      );
      await _pumpChat(tester, parentId);
      expect(mutedDot(), findsNothing);

      final idle = {
        for (final MapEntry(:key, :value) in sampleAgentSessions().entries)
          key: key == testsId ? value.copyWith(running: false) : value,
      };
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [
            ..._harness(parentId).overrides,
            ...agentsOverrides(idle),
            workspaceSourceProvider.overrideWith((ref, id) => null),
            workspaceRootProvider.overrideWith((ref, id) => null),
          ],
        ),
      );
      await pumpFrames(tester, 6);
      expect(find.byType(HeaderAgentsKey), findsOneWidget);
      expect(mutedDot(), findsOneWidget);
    });

    testWidgets('「N 个子代理」 opens the sheet; a row opens the child', (tester) async {
      final container = await _pumpChat(tester, parentId);
      final key = find.byType(HeaderAgentsKey);
      expect(key, findsOneWidget);
      expect(find.descendant(of: key, matching: find.text('3')), findsOneWidget);
      expect(find.bySemanticsLabel('3 个子代理，1 个运行中'), findsOneWidget);
      await tester.tap(key);
      await pumpFrames(tester, 8);
      expect(find.byType(LineageSheet), findsOneWidget);
      expect(find.text('3 个子代理'), findsOneWidget);
      await tester.tap(find.widgetWithText(SubagentRow, '审查改动'));
      await pumpFrames(tester, 8);
      expect(find.byType(LineageSheet), findsNothing);
      expect(container.read(currentSessionProvider), reviewerId);
    });

    testWidgets('a child: breadcrumb back, named by its task, no model chip', (tester) async {
      final container = await _pumpChat(tester, reviewerId);
      expect(find.byType(HeaderBackKey), findsOneWidget);
      expect(find.text('修复登录重复提交'), findsOneWidget);
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.text('审查改动')), findsOneWidget);
      expect(find.byType(ModelChip), findsNothing);
      // 「‹ 上级对话」 replaces ≡, so there is no 新对话 key to mirror it.
      expect(find.byKey(const ValueKey('chat-new-chat')), findsNothing);
      // Its own child: one more level down.
      expect(find.descendant(of: find.byType(HeaderAgentsKey), matching: find.text('1')), findsOneWidget);
      await tester.tap(find.byType(HeaderBackKey));
      await pumpFrames(tester, 4);
      expect(container.read(currentSessionProvider), parentId);
    });

    testWidgets('nothing changes without subagents', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [..._harness(parentId).overrides, hostSessionsProvider.overrideWithValue(const {})],
        ),
      );
      await pumpFrames(tester, 6);
      expect(find.byType(HeaderAgentsKey), findsNothing);
      expect(find.byType(HeaderBackKey), findsNothing);
      expect(find.byKey(const ValueKey('chat-new-chat')), findsOneWidget);
      expect(find.byIcon(AppIcons.menu), findsOneWidget);
    });

    testWidgets('geometry: one height, even gaps, symmetric insets', (tester) async {
      await _pumpChat(tester, parentId);
      final menu = tester.getRect(
        find.ancestor(of: find.byIcon(AppIcons.menu), matching: find.byType(GlassSurface)).first,
      );
      final capsule = tester.getRect(
        find.descendant(of: find.byType(HeaderAgentsKey), matching: find.byType(GlassSurface)).first,
      );
      final title = tester.getRect(find.ancestor(of: find.text('修复登录重复提交'), matching: find.byType(GlassSurface)).first);
      expect(capsule.height, closeTo(44, 0.01));
      expect(capsule.height, closeTo(menu.height, 0.01));
      expect(capsule.center.dy, closeTo(menu.center.dy, 0.01));
      expect(capsule.left - title.right, greaterThanOrEqualTo(8 - 0.01));
      // Glyph and count sit 14 in from each end, centred on one line.
      final glyph = tester.getRect(
        find.descendant(of: find.byType(HeaderAgentsKey), matching: find.byType(SizedBox)).first,
      );
      final count = tester.getRect(find.descendant(of: find.byType(HeaderAgentsKey), matching: find.text('3')));
      expect(glyph.left - capsule.left, closeTo(HeaderAgentsKey.padding, 0.01));
      expect(capsule.right - count.right, closeTo(HeaderAgentsKey.padding, 0.01));
      expect(glyph.center.dy, closeTo(capsule.center.dy, 0.5));
      expect(count.center.dy, closeTo(capsule.center.dy, 0.5));
    });

    testWidgets('geometry: the breadcrumb key', (tester) async {
      await _pumpChat(tester, reviewerId);
      final key = tester.getRect(
        find.descendant(of: find.byType(HeaderBackKey), matching: find.byType(GlassSurface)).first,
      );
      final arrow = tester.getRect(find.byIcon(AppIcons.back));
      final label = tester.getRect(find.text('修复登录重复提交'));
      expect(key.height, closeTo(44, 0.01));
      expect(arrow.left - key.left, closeTo(HeaderBackKey.padding, 0.01));
      expect(key.right - label.right, closeTo(HeaderBackKey.padding, 0.01));
      expect(arrow.center.dy, closeTo(key.center.dy, 0.5));
      expect(label.center.dy, closeTo(key.center.dy, 0.5));
      expect(key.width, lessThanOrEqualTo(HeaderBackKey.maxWidth + 0.01));
      // 12 from the screen edge, like the drawer key it replaces.
      expect(key.left, closeTo(12, 0.01));
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('golden: details tab ($mode)', (tester) async {
      await _pumpTab(tester, brightness: brightness);
      await expectLater(find.byType(SessionDetailPage), matchesGoldenFile('goldens/subagents_tab_$mode.png'));
    });

    testWidgets('golden: header and sheet ($mode)', (tester) async {
      await _pumpChat(tester, parentId, brightness: brightness);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/subagents_header_$mode.png'));
      await tester.tap(find.byType(HeaderAgentsKey));
      await pumpFrames(tester, 8);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/subagents_sheet_$mode.png'));
    });

    testWidgets('golden: child conversation ($mode)', (tester) async {
      await _pumpChat(tester, reviewerId, brightness: brightness);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/subagent_chat_$mode.png'));
    });
  }
}
