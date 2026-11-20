// The Agent Teams panel: roster with roles and states, the task board in
// three calm groups, the members' messages, and switching the bundle on from
// the page when it is off. Goldens of every tab in light and dark.
//
//   flutter test --update-goldens test/agents/team_page_test.dart

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/agents/team_page.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show FixedSession, fakeConnection, testCatalog;
import '../providers/support.dart' show goldenTall, settle;
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

List<Override> _overrides({TeamSnapshot? team, FakeInstalled? installed, String session = parentId}) => [
  activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
  currentSessionProvider.overrideWith(() => FixedSession(session)),
  modelCatalogProvider.overrideWith((ref) async => testCatalog),
  localSafeModeProvider.overrideWithValue(false),
  ...agentsOverrides(
    sampleAgentSessions(withTeam: team != null),
    team: team,
    messages: sampleMessages(),
    installed: installed,
  ),
];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  TeamSnapshot? team,
  FakeInstalled? installed,
  Widget? home,
}) async {
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: home ?? const TeamPage(),
      brightness: Brightness.light,
      overrides: _overrides(team: team, installed: installed),
    ),
  );
  await settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

void main() {
  setUp(() => runClock = () => agentsNow);
  tearDown(() => runClock = DateTime.now);

  testWidgets('roster: roles, states, the current conversation tagged', (tester) async {
    await _pump(tester, team: sampleTeam());
    expect(find.text('lead'), findsOneWidget);
    expect(find.text('reviewer'), findsOneWidget);
    expect(find.text('tester'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.textContaining('负责人'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('1 位成员在工作'), findsOneWidget);
  });

  testWidgets('a teammate opens its conversation through the Lead', (tester) async {
    await tester.runAsync(loadGoldenFonts);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1688);
    addTearDown(tester.view.reset);
    // Pushed over a first route, as from the chat header.
    await tester.pumpWidget(
      goldenApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(TeamPage.route()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        brightness: Brightness.light,
        overrides: _overrides(team: sampleTeam()),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(TeamPage)));
    await tester.tap(find.text('tester'));
    await settle(tester);
    expect(find.byType(TeamPage), findsNothing);
    expect(container.read(currentSessionProvider), testsId);
    expect(fakeConnection.client.subagentRoute(testsId)?.parentSessionId, parentId);
  });

  testWidgets('team tabs have three equal segments without duplicate counts', (tester) async {
    await _pump(tester, team: sampleTeam());
    final pill = find.byWidgetPredicate((widget) => widget is SegmentedPill);
    final rects = <Rect>[];
    for (final label in ['成员', '任务', '消息']) {
      final text = find.descendant(of: pill, matching: find.text(label));
      expect(text, findsOneWidget);
      rects.add(tester.getRect(find.ancestor(of: text, matching: find.byType(GestureDetector)).first));
    }
    expect(rects[0].width, closeTo(rects[1].width, .5));
    expect(rects[1].width, closeTo(rects[2].width, .5));
    expect(rects[0].height, closeTo(rects[2].height, .5));
  });

  testWidgets('tasks: three groups, a sheet with the details', (tester) async {
    await _pump(tester, team: sampleTeam());
    await tester.tap(find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedPill), matching: find.text('任务')));
    await settle(tester);
    expect(find.text('待办 · 2'), findsOneWidget);
    expect(find.text('进行中 · 1'), findsOneWidget);
    expect(find.text('完成 · 1'), findsOneWidget);
    expect(find.textContaining('等 task-2'), findsOneWidget);
    expect(find.textContaining('未分配'), findsOneWidget);
    await tester.tap(find.text('给提交按钮加防抖'));
    await settle(tester);
    expect(find.text('提交中禁用按钮，请求结束再恢复。'), findsOneWidget);
    expect(find.text('lib/auth/'), findsOneWidget);
  });

  testWidgets('messages: newest first, sender → recipient', (tester) async {
    await _pump(tester, team: sampleTeam());
    await tester.tap(find.text('消息'));
    await settle(tester);
    final first = tester.getTopLeft(find.textContaining('第二个返回 409'));
    final second = tester.getTopLeft(find.textContaining('防抖改好后'));
    expect(first.dy, lessThan(second.dy));
    expect(find.textContaining('reviewer'), findsWidgets);
  });

  testWidgets('bundle off: switch it on from the page', (tester) async {
    final installed = FakeInstalled([teamBundleOff]);
    await _pump(tester, installed: installed);
    expect(find.text('智能体团队未开启'), findsOneWidget);
    await tester.tap(find.text('开启团队'));
    await settle(tester);
    expect(installed.switched, [(agentTeamBundle, true)]);
  });

  testWidgets('bundle on but no Team yet: a retry, no switch', (tester) async {
    const on = PluginBundle(
      name: agentTeamBundle,
      official: true,
      optional: true,
      enabled: true,
      availability: 'installation',
    );
    await _pump(tester, installed: FakeInstalled([on]));
    expect(find.text('没能读到团队'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('开启团队'), findsNothing);
  });

  testWidgets('a host without the bundle says so, nothing to press', (tester) async {
    await _pump(tester, installed: FakeInstalled(const []));
    expect(find.text('这台主机没有智能体团队'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  goldenTall('team_members', () => const TeamPage(), overrides: () => _overrides(team: sampleTeam()));

  goldenTall(
    'team_tasks',
    height: 1000,
    () => const TeamPage(),
    overrides: () => _overrides(team: sampleTeam()),
    before: (tester) async {
      runClock = () => agentsNow;
      await tester.tap(
        find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedPill), matching: find.text('任务')),
      );
      await settle(tester);
    },
  );

  goldenTall(
    'team_messages',
    () => const TeamPage(),
    overrides: () => _overrides(team: sampleTeam()),
    before: (tester) async {
      await tester.tap(find.text('消息'));
      await settle(tester);
    },
  );

  goldenTall(
    'team_off',
    () => const TeamPage(),
    overrides: () => _overrides(installed: FakeInstalled([teamBundleOff])),
  );
}
