// 技能 › 「在对话里用」 / 「新对话里用」. Both put `/name ` into a composer
// (the official client applies a skill by its literal text) and go back to
// the chat; a project skill takes the new conversation into its workspace.
// Goldens: the skill sheet, light and dark. Regenerate with
// `flutter test --update-goldens test/features/skill_use_test.dart`.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/composer_insert.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart' show SheetActions;
import 'package:dsh_app/ui/features/skill_use.dart';
import 'package:dsh_app/ui/features/skills_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

const _workspaceRoot = '/root/workspace/dsh-app';

const _skills = [
  SkillInfo(name: 'code-review', description: '按团队规范审查改动，列出问题和修改建议。', path: '/root/.dsh/skills/code-review/SKILL.md'),
  SkillInfo(
    name: 'pdf',
    description: '读取、拆分、合并 PDF，提取表格和文字。',
    whenToUse: '用户给了 PDF 文件时',
    path: '$_workspaceRoot/.dsh/skills/pdf/SKILL.md',
  ),
];

const _app = Workspace(workspaceId: 'w-app', path: _workspaceRoot, title: 'dsh-app', sessionIds: ['s1']);

const _notes = Workspace(workspaceId: 'w-notes', path: '/root/workspace/notes', title: 'notes', sessionIds: ['s2']);

class _Sessions extends SessionsController {
  @override
  Future<List<SessionSummary>> build() async => const [];
}

class _Current extends CurrentSessionController {
  @override
  String? build() => 's1';
}

class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready, workspaces: [_app, _notes]);
}

class _Prefs extends WorkspacePrefsController {
  _Prefs(this.initial);
  final String? initial;

  @override
  WorkspacePrefs build() => WorkspacePrefs(loaded: true, selected: initial);

  @override
  Future<void> select(String? workspaceId) async => state = state.copyWith(selected: () => workspaceId);
}

SessionSummary _summary(String id, {String? origin}) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24),
  running: false,
  blank: false,
  agentAvailable: true,
  cwd: _workspaceRoot,
  origin: origin,
);

List<Override> _overrides({bool subagent = false, String? selected}) => [
  activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
  localRuntimeProvider.overrideWith(StaticRuntime.new),
  sessionsProvider.overrideWith(_Sessions.new),
  currentSessionProvider.overrideWith(_Current.new),
  skillsProvider.overrideWith((ref, id) async => _skills),
  hostSessionsProvider.overrideWithValue({'s1': _summary('s1', origin: subagent ? 'subagent' : null)}),
  workspacesProvider.overrideWith(_Workspaces.new),
  workspacePrefsProvider.overrideWith(() => _Prefs(selected)),
];

/// The chat (a stand-in) with the skill page pushed over it.
Future<ProviderContainer> _open(
  WidgetTester tester, {
  bool subagent = false,
  String? selected,
  Brightness brightness = Brightness.light,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      const Scaffold(body: Center(child: Text('聊天'))),
      brightness: brightness,
      overrides: _overrides(subagent: subagent, selected: selected),
    ),
  );
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(MaterialPageRoute<void>(builder: (_) => const SkillsPage(sessionId: 's1')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('/pdf'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(SkillsPage)));
}

void main() {
  setUpAll(loadTestFonts);

  group('the sheet', () {
    testWidgets('two actions of equal size, the primary on the right', (tester) async {
      await _open(tester);
      final fresh = tester.getRect(find.widgetWithText(OutlinedButton, SkillUseActions.freshLabel));
      final here = tester.getRect(find.widgetWithText(FilledButton, SkillUseActions.hereLabel));
      expect(find.byType(FilledButton), findsOneWidget, reason: 'one primary');
      expect(fresh.height, SheetActions.height);
      expect(here.height, SheetActions.height);
      expect(fresh.width, moreOrLessEquals(here.width, epsilon: 0.5));
      expect(fresh.top, here.top);
      expect(here.left - fresh.right, moreOrLessEquals(12, epsilon: 0.5));
      // Mirror insets: both edges on the sheet gutter.
      expect(fresh.left, moreOrLessEquals(kSheetGutter, epsilon: 0.5));
      expect(390 - here.right, moreOrLessEquals(kSheetGutter, epsilon: 0.5));
      // No copy button.
      expect(find.textContaining('复制'), findsNothing);
    });

    testWidgets('fits a 360dp phone with large text', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(720, 1560);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(testApp(const SkillsPage(sessionId: 's1'), overrides: _overrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/pdf'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in [SkillUseActions.hereLabel, SkillUseActions.freshLabel]) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      }
    });

    testWidgets('a subagent conversation offers only a new one', (tester) async {
      await _open(tester, subagent: true);
      expect(find.text(SkillUseActions.hereLabel), findsNothing);
      expect(find.widgetWithText(FilledButton, SkillUseActions.freshLabel), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('using a skill', () {
    testWidgets('在对话里用: back to the chat, `/pdf` for this conversation', (tester) async {
      final container = await _open(tester);
      await tester.tap(find.text(SkillUseActions.hereLabel));
      await tester.pumpAndSettle();
      expect(find.byType(SkillsPage), findsNothing);
      expect(find.text('聊天'), findsOneWidget);
      expect(container.read(composerInsertProvider), ComposerInsert.skill('pdf', sessionId: 's1'));
      // The drawer's workspace is left alone.
      expect(container.read(workspacePrefsProvider).selected, isNull);
    });

    testWidgets('新对话里用: a new conversation, in the skill\'s workspace', (tester) async {
      final container = await _open(tester, selected: 'w-notes');
      await tester.tap(find.text(SkillUseActions.freshLabel));
      await tester.pumpAndSettle();
      expect(find.byType(SkillsPage), findsNothing);
      expect(container.read(composerInsertProvider), ComposerInsert.skill('pdf', sessionId: null));
      expect(container.read(workspacePrefsProvider).selected, 'w-app');
    });
  });

  group('skillWorkspaceSwitch', () {
    String? target(SkillInfo skill, {String session = 's1', String? selected}) =>
        skillWorkspaceSwitch(skill: skill, sessionId: session, workspaces: const [_app, _notes], selected: selected);

    const project = SkillInfo(name: 'pdf', description: '', path: '$_workspaceRoot/.dsh/skills/pdf/SKILL.md');

    test('a project skill takes the conversation\'s workspace', () {
      expect(target(project), 'w-app', reason: 'from 全部对话');
      expect(target(project, selected: 'w-notes'), 'w-app');
    });

    test('already there: no switch', () {
      expect(target(project, selected: 'w-app'), isNull);
    });

    test('global and plugin skills work anywhere', () {
      expect(target(const SkillInfo(name: 'a', description: '', path: '/root/.dsh/skills/a/SKILL.md')), isNull);
      expect(target(const SkillInfo(name: 'b', description: '')), isNull);
    });

    test('a sibling folder with the same prefix is not inside', () {
      expect(
        target(const SkillInfo(name: 'c', description: '', path: '${_workspaceRoot}2/.dsh/skills/c/SKILL.md')),
        isNull,
      );
    });

    test('a conversation outside every workspace keeps the selection', () {
      expect(target(project, session: 'loose'), isNull);
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: skill sheet ($mode)', (tester) async {
      await _open(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/skill_sheet_$mode.png'));
    });
  }
}
