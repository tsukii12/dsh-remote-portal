// 全部功能 logic: deep-link targets (what the DSH Web bridge receives), the
// feature catalog's invariants, and the Chinese wording of schedule rules,
// job states and presets.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/engine_settings/runtime_settings_pages.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/features/feature_format.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

ScheduleTask task(
  String kind, {
  bool active = true,
  int? everySeconds,
  String? time,
  List<int> weekdays = const [],
  String? expression,
  DateTime? scheduledAt,
  DateTime? lastDeliveredAt,
}) => ScheduleTask(
  id: 'sch-$kind',
  sessionId: 's1',
  kind: kind,
  title: kind,
  prompt: 'p',
  active: active,
  record: const {},
  everySeconds: everySeconds,
  time: time,
  timeZone: 'Asia/Shanghai',
  weekdays: weekdays,
  expression: expression,
  scheduledAt: scheduledAt,
  lastDeliveredAt: lastDeliveredAt,
);

void main() {
  group('DshWebTarget', () {
    test('serializes only what is set, as the bridge reads it', () {
      expect(const DshWebTarget().toJson(), isEmpty);
      expect(const DshWebTarget().isHome, isTrue);
      expect(const DshWebTarget(panel: DshWebPanel.schedules).toJson(), {'panel': 'schedules'});
      expect(const DshWebTarget(settings: DshWebSettings.agentPresets).toJson(), {'settings': 'agent-presets'});
      expect(const DshWebTarget(pluginItem: ['Agent 循环', 'Agent loop']).toJson(), {
        'pluginItem': ['Agent 循环', 'Agent loop'],
      });
      expect(const DshWebTarget(sessionId: 'session-1', rightbar: DshWebRightbar.terminal).toJson(), {
        'session': 'session-1',
        'rightbar': 'terminal',
      });
      expect(const DshWebTarget(sidebar: true).toJson(), {'sidebar': true});
    });

    test('openScript is a guarded call with JSON-escaped data', () {
      const target = DshWebTarget(pluginItem: ["it's \"quoted\"</script>"]);
      final script = target.openScript;
      expect(script, startsWith('window.__dshAppOpen && window.__dshAppOpen('));
      final json = script.substring(script.indexOf('(', 'window.__dshAppOpen && '.length) + 1, script.lastIndexOf(')'));
      expect(jsonDecode(json), {
        'pluginItem': ["it's \"quoted\"</script>"],
      });
    });

    test('inSession keeps the destination and swaps the session', () {
      const files = DshWebTarget(rightbar: DshWebRightbar.files);
      expect(files.inSession('s9'), const DshWebTarget(sessionId: 's9', rightbar: DshWebRightbar.files));
      expect(files.inSession(null), files);
    });

    test('bridge results become a short Chinese line on a miss', () {
      expect(DshWebOpenResult.parse('{"ok":true,"step":null}')!.problem, isNull);
      expect(DshWebOpenResult.parse('{"ok":false,"step":"pluginItem"}')!.problem, contains('没找到这个插件'));
      expect(DshWebOpenResult.parse('{"ok":false}')!.problem, isNotNull);
      expect(DshWebOpenResult.parse('not json'), isNull);
    });

    test('the bridge script knows every key the app sends', () {
      final js = File('assets/web/dsh_web_open.js').readAsStringSync();
      for (final p in DshWebPanel.values) {
        expect(js, contains("${p.key}: ["), reason: 'panel ${p.key}');
      }
      for (final s in DshWebSettings.values) {
        expect(js, contains(RegExp("'?${RegExp.escape(s.key)}'?: \\[")), reason: 'settings ${s.key}');
      }
      for (final r in DshWebRightbar.values) {
        expect(js, contains("${r.key}: ["), reason: 'rightbar ${r.key}');
      }
      expect(js, contains('window.__dshAppOpen = function'));
      expect(js, contains("'dsh.sessions.current'"));
    });
  });

  group('feature catalog', () {
    final items = [for (final s in featureSections) ...s.items];

    test('ids are unique and every item has a way in', () {
      expect(items.map((i) => i.id).toSet(), hasLength(items.length));
      for (final item in items) {
        expect(item.native != null || item.action != null || item.web != null, isTrue, reason: item.id);
        expect(item.summary, isNotEmpty, reason: item.id);
      }
    });

    test('native terminal and global settings have no redundant web fallback', () {
      final terminal = items.firstWhere((i) => i.id == 'terminal');
      expect(terminal.needsSession, isTrue);
      expect(terminal.webOnly, isFalse);
      final page = terminal.native!('s1');
      expect(page, isA<TerminalPage>());
      expect((page as TerminalPage).sessionId, 's1');
      expect(terminal.webFor(null), isNull);
      expect(terminal.webFor('s1'), isNull);
      // Settings left 全部功能 for 设置; their links still open the page.
      expect(pageForId('agent-loop', null), isA<AgentLoopSettingsPage>());
    });

    test('official surfaces named in the parity table are all present', () {
      // In 全部功能, or (settings) in 设置 by the same link id.
      final ids = {...items.map((i) => i.id), ...SettingsIndex.linkIds};
      expect(
        ids,
        containsAll([
          'schedules',
          'jobs',
          'plan-goal',
          'skills',
          'subagents',
          'agent-team',
          'permission',
          'agent-presets',
          'workspaces',
          'terminal',
          'files',
          'models',
          'agent-loop',
          'web-search',
          'shell-settings',
          'subagent-settings',
          'general',
          'plugin-inventory',
          'cordis',
          'reference',
          'cot-translation',
          'voice-input',
          'account',
          'community',
          'ds-bot',
          'share-profile',
        ]),
      );
    });

    test('only the web itself is web-only now', () {
      expect(
        [
          for (final i in items)
            if (i.webOnly) i.id,
        ],
        ['web'],
      );
    });
  });

  group('wording', () {
    test('schedule rules', () {
      expect(scheduleRule(task('daily', time: '09:00')), '每天 09:00');
      expect(scheduleRule(task('daily', time: '09:00:30.000')), '每天 09:00:30');
      expect(scheduleRule(task('weekly', time: '09:00', weekdays: [1, 2, 3, 4, 5])), '每个工作日 09:00');
      expect(scheduleRule(task('weekly', time: '18:30', weekdays: [3, 1])), '每周一、三 18:30');
      expect(scheduleRule(task('weekly', time: '10:00', weekdays: [6, 7])), '每个周末 10:00');
      expect(scheduleRule(task('every', everySeconds: 7200)), '每 2 小时');
      expect(scheduleRule(task('every', everySeconds: 60)), '每分钟');
      expect(scheduleRule(task('every', everySeconds: 90)), '每 90 秒');
      // Cron reads like the builder rule it states, else the official sentence.
      expect(scheduleRule(task('cron', expression: '0 9 * * 1')), '每周一 09:00');
      expect(scheduleRule(task('cron', expression: '*/15 9-17 * * 1-5')), '周一至周五 09 至 17 点内每 15 分钟');
      expect(scheduleRule(task('at')), '仅一次');
    });

    test('relative times and summaries', () {
      final now = DateTime(2026, 10, 24, 15);
      expect(formatWhen(DateTime(2026, 10, 24, 9, 5), now: now), '今天 09:05');
      expect(formatWhen(DateTime(2026, 10, 25, 9), now: now), '明天 09:00');
      expect(formatWhen(DateTime(2026, 10, 23, 21, 15), now: now), '昨天 21:15');
      expect(formatWhen(DateTime(2026, 11, 2, 8), now: now), '11月2日 08:00');
      expect(formatWhen(DateTime(2025, 1, 3, 8), now: now), '2025年1月3日 08:00');
      expect(
        scheduleSummary(
          task('daily', time: '09:00', scheduledAt: DateTime(2026, 10, 25, 9)),
          now: now,
        ),
        '每天 09:00 · 下次 明天 09:00',
      );
      expect(
        scheduleSummary(task('at', active: false, lastDeliveredAt: DateTime(2026, 10, 24, 8)), now: now),
        '已结束 · 今天 08:00 运行过',
      );
    });

    test('job states', () {
      final now = DateTime(2026, 10, 24, 15);
      final running = JobInfo(
        id: 'j1',
        kind: 'bash',
        label: 'npm run dev',
        status: 'running',
        startedAt: now.subtract(const Duration(minutes: 3, seconds: 5)),
        progress: 'ready on :5173',
      );
      expect(jobSummary(running, now: now), '运行中 · 已运行 3 分 05 秒 · ready on :5173');
      final done = JobInfo(
        id: 'j2',
        kind: 'bash',
        label: 'make',
        status: 'failed',
        startedAt: now.subtract(const Duration(seconds: 40)),
        finishedAt: now.subtract(const Duration(seconds: 28)),
      );
      expect(jobSummary(done, now: now), '失败 · 用时 12 秒');
    });

    test('preset names follow the official copy', () {
      expect(permissionName('workspace-write'), '工作区内修改');
      expect(permissionName('my-preset', '我的预设'), '我的预设');
      expect(agentPresetName(const AgentPresetInfo(id: 'cordis')), '创造模式');
      expect(agentPresetName(const AgentPresetInfo(id: 'mine', name: '我的')), '我的');
      expect(agentPresetName(const AgentPresetInfo(id: 'mine')), 'mine');
    });
  });

  group('slash palette', () {
    const skill = SlashCommand(
      name: 'code-review',
      label: 'code-review',
      description: '审查改动',
      hint: '',
      kind: SlashCommandKind.skill,
    );
    const clash = SlashCommand(
      name: 'compact',
      label: 'compact',
      description: 'a skill named like a command',
      hint: '',
      kind: SlashCommandKind.skill,
    );
    final host = parseCommandList([
      {'name': 'compact', 'definitionId': '@deepseek-ai/dsh-command-compact'},
      {'name': 'deploy', 'description': 'Ship it'},
    ]);

    test('skills come last and never shadow app or host commands', () {
      final all = mergeSlashCommands(host, skills: const [skill, clash]);
      expect(all.map((c) => c.name), ['new', 'model', 'compact', 'export', 'features', 'deploy', 'code-review']);
      expect(all.firstWhere((c) => c.name == 'compact').kind, SlashCommandKind.host);
      expect(all.firstWhere((c) => c.name == 'features').label, '全部功能');
    });

    test('a skill takes free text and gets its own icon', () {
      final all = mergeSlashCommands(host, skills: const [skill]);
      expect(resolveSlashCommand(all, 'code-review')?.kind, SlashCommandKind.skill);
      expect(PaletteContent.of(all, '/code-review 看看 auth 模块'), isNull, reason: 'the argument is already there');
      expect(slashIcon(skill), isNot(slashIconFor('code-review')));
      expect(resolveSlashCommand(all, '全部功能')?.name, 'features');
    });
  });
}
