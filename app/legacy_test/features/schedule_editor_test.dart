// 新建 / 编辑自动化任务: the run-time builder, the requests behind saving
// (`schedule/update` with `change`; creation through the conversation's
// `schedule_create`), 立即运行, symmetry of the weekday keys, and goldens
// (light + dark). Regenerate the goldens with
// `flutter test --update-goldens test/features/schedule_editor_test.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/chat/widgets/schedule_question_body.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/search_capsule.dart';
import 'package:dsh_app/ui/features/schedule_editor/schedule_draft.dart';
import 'package:dsh_app/ui/features/schedule_editor/schedule_editor_page.dart';
import 'package:dsh_app/ui/features/schedule_editor/schedule_pickers.dart';
import 'package:dsh_app/ui/features/schedules_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SegmentedPill;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';
import '../notify/schedule_authorization_checks.dart';

/// Saturday 2026-10-24 15:20 in Shanghai.
final _now = DateTime.utc(2026, 10, 24, 7, 20);

SessionSummary _session(String id, String title) => SessionSummary(
  sessionId: id,
  updatedAt: _now,
  running: false,
  blank: false,
  agentAvailable: false,
  cwd: '/root/workspace',
  projections: SessionProjections(1, {'title': title}),
);

class _Sessions extends SessionsController {
  int creates = 0;

  @override
  Future<List<SessionSummary>> build() async => [_session('s1', '修复登录按钮重复提交'), _session('s2', '每天的构建检查')];

  @override
  Future<String> create({bool autoApprove = true}) async {
    creates++;
    return 'new-1';
  }

  @override
  Future<void> refresh() async {}
}

class _ActiveHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;

  void switchHost() => state = const HostRef.portal('next-host');
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

Map<String, Object?> _entry(String id, String kind, Map<String, Object?> fields, {String session = 's1'}) => {
  'id': id,
  'kind': kind,
  'title': '日报提醒',
  'prompt': '整理昨天的提交，发我一段摘要。',
  'scheduledAt': '2026-10-25T01:00:00.000Z',
  ...fields,
  'sessionId': session,
  'status': 'active',
};

final _daily = _entry('sch-1', 'daily', {'time': '09:00:00.000', 'timeZone': 'Asia/Shanghai'});

final _rrule = {
  ..._entry('sch-2', 'rrule', {'rrule': 'DTSTART;TZID=Asia/Shanghai:20261025T090000\nRRULE:FREQ=DAILY;COUNT=3'}),
  'target': {'kind': 'new'},
  'involvedSessionIds': ['s1'],
  'updatedAt': '2026-10-24T00:00:00.000Z',
};

ScheduleTask _task(Map<String, Object?> entry) => ScheduleTask.fromJson(entry)!;

void main() {
  setUpAll(loadTestFonts);

  late FakePluginCarrier carrier;
  late DshClient client;
  late _Sessions sessions;

  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    sessions = _Sessions();
  });
  tearDown(() => client.close());

  List<Override> overrides() => [
    activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
    activeHostProvider.overrideWith(_ActiveHost.new),
    sessionsProvider.overrideWith(() => sessions),
    settingsProvider.overrideWith(_Settings.new),
    localRuntimeProvider.overrideWith(StaticRuntime.new),
    deviceTimeZoneProvider.overrideWith((ref) async => 'Asia/Shanghai'),
    hostWorkspacesProvider.overrideWith(
      (ref) async => const [
        Workspace(workspaceId: 'w1', path: '/root/workspace', title: 'workspace', sessionIds: []),
        Workspace(workspaceId: 'w2', path: '/root/blog', title: 'blog', sessionIds: []),
      ],
    ),
    modelCatalogProvider.overrideWith((ref) async => testCatalog),
  ];

  Future<void> pump(WidgetTester tester, Widget page, {Brightness brightness = Brightness.light}) async {
    usePhoneView(tester);
    await tester.pumpWidget(testApp(page, brightness: brightness, overrides: overrides()));
    await pumpFrames(tester, 6);
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.4);
    await pumpFrames(tester);
  }

  test('schedule authorization uses real mux replay and scoped human responses', runScheduleAuthorizationChecks);

  group('authorization', () {
    testWidgets('complete Host task is readable and can be explicitly authorized from the editor', (tester) async {
      final result = Completer<Object?>();
      final payload = jsonDecode(File('test/chat/fixtures/schedule_authorization_request.json').readAsStringSync());
      carrier.handlers[r'$events/result'] = (_) => null;
      carrier.handlers['schedule/update'] = (_) {
        carrier.link!.push({
          'type': 'waterfall',
          'event': 'user-questions/request',
          'eventId': 'complete-question',
          'agentId': 's1',
          'request': payload,
        });
        return result.future;
      };
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '新名字');
      await tester.tap(find.text('保存'));
      await pumpFrames(tester);
      expect(find.text('合成每日检查'), findsOneWidget);
      expect(find.textContaining('1. 检查合成项目，保留完整结果与换行。\n2.'), findsOneWidget);
      final submit = find.widgetWithText(FilledButton, '提交');
      await tester.ensureVisible(submit);
      await pumpFrames(tester);
      expect(submit.hitTestable(), findsOneWidget);
      expect(find.text('授权 / Authorize').hitTestable(), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      final scroll = find.descendant(of: find.byType(ScheduleQuestionBody), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.text('null'), 220, scrollable: scroll, maxScrolls: 40);
      expect(find.text('null').hitTestable(), findsOneWidget);
      expect(carrier.argsOf(r'$events/result'), isEmpty);
      await tester.tap(find.text('授权 / Authorize'));
      await tester.pump();
      expect(carrier.argsOf(r'$events/result'), isEmpty);
      await tester.tap(submit);
      await pumpFrames(tester);
      expect(carrier.argsOf(r'$events/result').single, {
        'clientId': 'client-1',
        'eventId': 'complete-question',
        'outcome': {
          'kind': 'result',
          'value': {
            'answers': [
              {
                'id': 'dsh-go-schedule-authorization-synthetic',
                'selected': ['授权 / Authorize'],
              },
            ],
          },
        },
      });
      expect(find.byType(QuestionCard), findsNothing);
      result.complete({'id': 'sch-1', 'updated': false, 'code': 'schedule_conflict'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    Future<Completer<Object?>> pendingEdit(WidgetTester tester) async {
      final result = Completer<Object?>();
      carrier.handlers[r'$events/result'] = (_) => null;
      carrier.handlers['schedule/update'] = (_) {
        carrier.link!.push(scheduleQuestionFrame('edit-question'));
        return result.future;
      };
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '新名字');
      await tester.tap(find.text('保存'));
      await pumpFrames(tester);
      return result;
    }

    testWidgets('fast edit request is visible in full and waits for explicit selection and submit', (tester) async {
      final result = await pendingEdit(tester);
      expect(find.byType(QuestionCard), findsOneWidget);
      final card = tester.widget<QuestionCard>(find.byType(QuestionCard));
      expect(find.text(card.request.questions.single.question), findsOneWidget);
      expect(card.request.questions.single.question, contains('complete instruction'));
      expect(find.text('授权 / Authorize'), findsOneWidget);
      expect(find.text('拒绝 / Reject'), findsOneWidget);
      expect(carrier.argsOf(r'$events/result'), isEmpty);
      final submit = find.widgetWithText(FilledButton, '提交');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(find.text('授权 / Authorize'));
      await tester.pump();
      expect(carrier.argsOf(r'$events/result'), isEmpty, reason: 'selection alone is not consent');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await pumpFrames(tester);
      final response = carrier.argsOf(r'$events/result').single;
      expect(response['eventId'], 'edit-question');
      expect(response['outcome'], {
        'kind': 'result',
        'value': {
          'answers': [
            {
              'id': 'dsh-go-schedule-authorization-edit-question',
              'selected': ['授权 / Authorize'],
            },
          ],
        },
      });
      expect(find.byType(QuestionCard), findsNothing);
      result.complete({'id': 'sch-1', 'updated': false, 'code': 'schedule_conflict'});
      await tester.pumpAndSettle();
    });

    testWidgets('withdrawal removes the card and its held callback cannot answer', (tester) async {
      final result = await pendingEdit(tester);
      final card = tester.widget<QuestionCard>(find.byType(QuestionCard));
      carrier.link!.push({'type': 'cancel', 'eventId': 'edit-question'});
      await card.onAnswer(card.request, [
        QuestionAnswer(card.request.questions.single.id, selected: ['授权 / Authorize']),
      ]);
      await pumpFrames(tester);
      expect(find.byType(QuestionCard), findsNothing);
      expect(carrier.argsOf(r'$events/result'), isEmpty);
      result.complete({'id': 'sch-1', 'updated': false, 'code': 'schedule_conflict'});
      await tester.pumpAndSettle();
    });

    testWidgets('leaving the editor rejects only the old pending request', (tester) async {
      final result = await pendingEdit(tester);
      final card = tester.widget<QuestionCard>(find.byType(QuestionCard));
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpFrames(tester);
      await card.onAnswer(card.request, [
        QuestionAnswer(card.request.questions.single.id, selected: ['授权 / Authorize']),
      ]);
      expect(carrier.argsOf(r'$events/result').single['outcome'], {
        'kind': 'rejected',
        'error': {'name': 'UserQuestionError', 'message': 'declined'},
      });
      result.complete({'id': 'sch-1', 'updated': false, 'code': 'authorization_required'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Host selection retires the old card before the replacement connection resolves', (tester) async {
      final result = await pendingEdit(tester);
      final card = tester.widget<QuestionCard>(find.byType(QuestionCard));
      final container = ProviderScope.containerOf(tester.element(find.byType(ScheduleEditorPage)));
      (container.read(activeHostProvider.notifier) as _ActiveHost).switchHost();
      await pumpFrames(tester);
      expect(find.byType(QuestionCard), findsNothing);
      expect((carrier.argsOf(r'$events/result').single['outcome']! as Map)['kind'], 'rejected');
      await card.onAnswer(card.request, [
        QuestionAnswer(card.request.questions.single.id, selected: ['授权 / Authorize']),
      ]);
      expect(carrier.argsOf(r'$events/result'), hasLength(1));
      result.complete({'id': 'sch-1', 'updated': true, 'record': _daily});
      await tester.pumpAndSettle();
      expect(
        find.byType(ScheduleEditorPage),
        findsOneWidget,
        reason: 'old RPC completion cannot pop the new Host page',
      );
    });

    testWidgets('creation observes its new session before the prompt can emit a question', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => <Object?>[];
      carrier.handlers[r'$events/result'] = (_) => null;
      carrier.handlers['session/prompt'] = (_) {
        carrier.link!.push(scheduleQuestionFrame('create-question', session: 'new-1'));
        return {'accepted': true};
      };
      await pump(tester, ScheduleEditorPage(now: _now));
      await tester.enterText(find.widgetWithText(TextField, '比如：每日站会提醒'), '日报');
      await tester.enterText(find.byType(TextField).at(1), '写日报');
      await tester.tap(find.text('创建'));
      await pumpFrames(tester);
      expect(find.byType(QuestionCard), findsOneWidget);
      expect(tester.widget<QuestionCard>(find.byType(QuestionCard)).request.sessionId, 'new-1');
      expect(carrier.argsOf(r'$events/result'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpFrames(tester);
      expect((carrier.argsOf(r'$events/result').single['outcome']! as Map)['kind'], 'rejected');
      // Let the existing creation wait release its timers after leaving.
      await tester.pump(const Duration(minutes: 2, seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('edit', () {
    testWidgets('a custom rule is shown as such and a new name leaves it alone', (tester) async {
      carrier.handlers['schedule/edit'] = (args) {
        final request = args['request']! as Map<String, Object?>;
        return {..._rrule, ...(request['patch']! as Map<String, Object?>)};
      };
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          ScheduleEditorPage(task: _task(_rrule), now: _now),
          overrides: overrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自定义'), findsOneWidget);
      expect(find.text('仅一次'), findsNothing, reason: 'not the one-shot the builder would read it as');

      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '周报提醒');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      final request = carrier.argsOf('schedule/edit').single['request']! as Map<String, Object?>;
      expect(request['patch'], {'title': '周报提醒'}, reason: 'the rule is not sent back');
    });

    testWidgets('switching to 工作日 sends a weekly change with the new name', (tester) async {
      carrier.handlers['schedule/update'] = (args) {
        final request = args['request']! as Map<String, Object?>;
        return {
          'id': 'sch-1',
          'updated': true,
          'record': {
            ...(request['expected']! as Map<String, Object?>),
            'kind': 'weekly',
            'title': request['title'],
            'weekdays': [1, 2, 3, 4, 5],
          },
        };
      };
      ScheduleTask? saved;
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async => saved = await Navigator.of(context).push<ScheduleTask>(
                  MaterialPageRoute(
                    builder: (_) => ScheduleEditorPage(task: _task(_daily), now: _now),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          overrides: overrides(),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('编辑自动化任务'), findsWidgets);
      expect(find.text('每天 09:00'), findsOneWidget, reason: 'preview');
      expect(find.text('明天 09:00'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '站会提醒');
      await tester.tap(find.text('重复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('工作日').last);
      await tester.pumpAndSettle();
      expect(find.text('每个工作日 09:00'), findsOneWidget);
      expect(find.text('10月26日 周一 09:00'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('schedule/update').single, {
        'request': {
          'sessionId': 's1',
          'id': 'sch-1',
          'expected': {
            'id': 'sch-1',
            'kind': 'daily',
            'title': '日报提醒',
            'prompt': '整理昨天的提交，发我一段摘要。',
            'scheduledAt': '2026-10-25T01:00:00.000Z',
            'time': '09:00:00.000',
            'timeZone': 'Asia/Shanghai',
          },
          'title': '站会提醒',
          'change': {
            'kind': 'weekly',
            'weekly': {
              'time': '09:00:00',
              'time_zone': 'Asia/Shanghai',
              'weekdays': [1, 2, 3, 4, 5],
            },
          },
        },
      });
      expect(saved?.kind, 'weekly');
      expect(saved?.title, '站会提醒');
    });

    testWidgets('only the name changed: no run-time change is sent', (tester) async {
      carrier.handlers['schedule/update'] = (args) => {
        'id': 'sch-1',
        'updated': true,
        'record': {...(_daily..remove('status')), 'title': '新名字'},
      };
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '新名字');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final request = carrier.argsOf('schedule/update').single['request']! as Map;
      expect(request.containsKey('change'), isFalse);
      expect(request['title'], '新名字');
      expect(request.containsKey('prompt'), isFalse);
    });

    testWidgets('a refused update shows a short reason and stays', (tester) async {
      carrier.handlers['schedule/update'] = (_) => {'id': 'sch-1', 'updated': false, 'code': 'schedule_conflict'};
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '新名字');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('任务刚被改过，返回后再试'), findsOneWidget);
      expect(find.byType(ScheduleEditorPage), findsOneWidget);
    });

    testWidgets('高级: cron is checked as it is typed and described', (tester) async {
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      await tester.tap(find.text('重复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级'));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, '0 9 * * *');
      expect(field, findsOneWidget, reason: 'the daily rule as an expression');
      await tester.enterText(field, '0 9 * *');
      await pumpFrames(tester);
      expect(find.text('需要 5 段，现在是 4 段'), findsWidgets);
      await tester.enterText(find.byType(TextField).last, '30 8 * * 1-5');
      await pumpFrames(tester);
      expect(find.text('周一至周五 08:30'), findsOneWidget);
      expect(find.text('10月26日 周一 08:30'), findsOneWidget);
    });

    testWidgets('间隔 and 每月 save as every_seconds and cron', (tester) async {
      final sent = <Object?>[];
      carrier.handlers['schedule/update'] = (args) {
        sent.add((args['request']! as Map)['change']);
        return {'id': 'sch-1', 'updated': false, 'code': 'schedule_conflict'};
      };
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      Future<void> repeat(String label) async {
        await reveal(tester, find.text('重复'));
        await tester.tap(find.text('重复'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await repeat('间隔');
      expect(find.byType(IntervalRow), findsOneWidget);
      expect(find.text('时区'), findsNothing, reason: 'a fixed rate has no zone');
      await tester.enterText(find.descendant(of: find.byType(IntervalRow), matching: find.byType(TextField)), '30');
      await tester.tap(find.text('分钟'));
      await pumpFrames(tester);
      expect(find.text('每 30 分钟'), findsOneWidget);
      expect(find.text('今天 15:50'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      await repeat('每月');
      await tester.tap(find.text('日期'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('15 日'));
      await pumpFrames(tester);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('每月 15、24 日 09:00'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(sent, [
        {'kind': 'every', 'every_seconds': 1800},
        {
          'kind': 'cron',
          'cron': {'expression': '0 9 15,24 * *', 'time_zone': 'Asia/Shanghai'},
        },
      ]);
    });

    testWidgets('fields left empty are flagged in place', (tester) async {
      await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
      await tester.enterText(find.widgetWithText(TextField, '日报提醒'), '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('填写名称'), findsOneWidget);
      expect(carrier.argsOf('schedule/update'), isEmpty);
    });
  });

  group('create', () {
    testWidgets('asks a new conversation to schedule_create, waits for the task, opens it', (tester) async {
      var created = false;
      carrier.handlers['schedule/catalog'] = (_) => [
        if (created)
          _entry('sch-new', 'weekly', {
            'time': '09:00:00.000',
            'timeZone': 'Asia/Shanghai',
            'weekdays': [1, 2, 3, 4, 5],
          }, session: 'new-1')..['title'] = '站会提醒',
      ];
      carrier.handlers['schedule/history'] = (_) => {
        'id': 'sch-new',
        'records': <Object?>[],
        'earlierRecordsUnavailable': false,
        'earlierRecordsPruned': false,
        'retention': {'days': 30, 'records': 200},
      };
      carrier.handlers['session/selectModel'] = (args) => {
        'provider': 'deepseek-official',
        'model': 'deepseek-flash',
        'reasoningEffort': 'high',
      };
      carrier.handlers['session/prompt'] = (args) {
        created = true;
        return {'accepted': true};
      };
      await pump(tester, SchedulesPage(now: _now));
      await tester.tap(find.byTooltip('新建'));
      await tester.pumpAndSettle();
      expect(find.text('新建自动化任务'), findsWidgets);

      await tester.enterText(find.widgetWithText(TextField, '比如：每日站会提醒'), '站会提醒');
      await tester.enterText(find.byType(TextField).at(1), '整理昨天的提交，发我摘要');
      await tester.tap(find.text('重复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('工作日').last);
      await tester.pumpAndSettle();

      await reveal(tester, find.text('模型'));
      expect(find.text('新对话'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget, reason: 'workspace');
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('V41 Flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SheetDragHandle));
      await tester.pumpAndSettle();

      await tester.tap(find.text('创建'));
      await tester.pump();
      expect(find.text('正在对话里创建'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(sessions.creates, 1);
      expect(carrier.argsOf('session/selectModel').single['request'], containsPair('model', 'deepseek-flash'));
      final prompt = carrier.argsOf('session/prompt').single['request']! as Map;
      expect(prompt['sessionId'], 'new-1');
      expect(prompt['clientTimeZone'], 'Asia/Shanghai');
      final text = ((prompt['content']! as List).single as Map)['text']! as String;
      expect(text, startsWith('新建自动化任务「站会提醒」：每个工作日 09:00。\n只调用一次 schedule_create'));
      final json = text.substring(text.indexOf('{'), text.lastIndexOf('}') + 1);
      expect(jsonDecode(json), {
        'title': '站会提醒',
        'prompt': '整理昨天的提交，发我摘要',
        'weekly': {
          'time': '09:00:00',
          'time_zone': 'Asia/Shanghai',
          'weekdays': [1, 2, 3, 4, 5],
        },
      });
      expect(find.byType(ScheduleDetailPage), findsOneWidget);
      expect(find.text('已创建'), findsOneWidget);
    });

    testWidgets('another workspace: the conversation is created in it; a retry reuses it', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => <Object?>[];
      carrier.handlers['session/create'] = (_) => {'sessionId': 'ws-1', 'agentPreset': 'standard'};
      carrier.handlers['session/prompt'] = (_) => throw const DshRemoteException('gateway/bad-request', 'nope');
      await pump(tester, ScheduleEditorPage(now: _now));
      await tester.enterText(find.widgetWithText(TextField, '比如：每日站会提醒'), '日报');
      await tester.enterText(find.byType(TextField).at(1), '写日报');
      await reveal(tester, find.text('工作区'));
      await tester.tap(find.text('工作区'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('blog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('session/create').single, {
        'request': {'workspaceId': 'w2'},
      });
      expect(sessions.creates, 0);
      expect(find.text('没能创建：引擎没有接受这个请求'), findsOneWidget);
      expect(find.text('刚建的对话'), findsOneWidget);

      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('session/create'), hasLength(1), reason: 'the retry reuses the conversation');
      expect(carrier.argsOf('session/prompt'), hasLength(2));
    });

    testWidgets('an existing conversation gets the request; a turn without a task fails softly', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => <Object?>[];
      carrier.handlers['session/prompt'] = (_) => {'accepted': true};
      await pump(tester, ScheduleEditorPage(now: _now));
      await tester.enterText(find.widgetWithText(TextField, '比如：每日站会提醒'), '日报');
      await tester.enterText(find.byType(TextField).at(1), '写日报');
      await reveal(tester, find.text('对话'));
      await tester.tap(find.text('对话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每天的构建检查'));
      await tester.pumpAndSettle();
      expect(find.text('模型'), findsNothing, reason: 'the conversation keeps its own model');

      await tester.tap(find.text('创建'));
      await tester.pump();
      await tester.pump(const Duration(minutes: 2, seconds: 5));
      await tester.pumpAndSettle();
      expect(sessions.creates, 0);
      expect((carrier.argsOf('session/prompt').single['request']! as Map)['sessionId'], 's2');
      expect(find.text('没能创建：还没等到结果'), findsOneWidget);
      expect(find.text('去对话里看看'), findsOneWidget);
    });
  });

  group('detail', () {
    testWidgets('立即运行 sends the instruction into its conversation', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => [_daily];
      carrier.handlers['schedule/history'] = (_) => {
        'id': 'sch-1',
        'records': <Object?>[],
        'earlierRecordsUnavailable': false,
        'earlierRecordsPruned': false,
        'retention': {'days': 30, 'records': 200},
      };
      carrier.handlers['session/prompt'] = (_) => {'accepted': true};
      await pump(tester, ScheduleDetailPage(task: _task(_daily), now: _now));
      await reveal(tester, find.text('立即运行'));
      await tester.tap(find.text('立即运行'));
      await tester.pumpAndSettle();
      final request = carrier.argsOf('session/prompt').single['request']! as Map;
      expect(request['sessionId'], 's1');
      expect(request['mode'], 'queue');
      expect(((request['content']! as List).single as Map)['text'], '整理昨天的提交，发我一段摘要。');
      expect(find.text('已发进对话'), findsOneWidget);
      expect(find.text('编辑任务'), findsOneWidget);
    });
  });

  group('list search', () {
    testWidgets('filters by name, instruction and rule; clears', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => [
        _daily,
        _entry('sch-2', 'weekly', {
          'title': '周报草稿',
          'prompt': '汇总本周合并的 PR',
          'time': '18:30:00.000',
          'timeZone': 'Asia/Shanghai',
          'weekdays': [1, 2, 3, 4, 5],
        }),
        _entry('sch-3', 'every', {'title': '检查夜间构建', 'prompt': '看看构建是否通过', 'everySeconds': 7200}),
      ];
      await pump(tester, SchedulesPage(now: _now));
      expect(find.text('日报提醒'), findsOneWidget);

      Future<void> search(String q) async {
        await tester.enterText(find.byType(SearchCapsule), q);
        await tester.pumpAndSettle();
      }

      await search('构建');
      expect(find.text('检查夜间构建'), findsOneWidget);
      expect(find.text('日报提醒'), findsNothing);
      await search('合并的 PR');
      expect(find.text('周报草稿'), findsOneWidget);
      expect(find.text('检查夜间构建'), findsNothing);
      await search('工作日');
      expect(find.text('周报草稿'), findsOneWidget, reason: 'matches the rule 每个工作日 18:30');
      expect(find.text('日报提醒'), findsNothing);
      await search('没有这个');
      expect(find.text('没有匹配的任务'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('清除'));
      await tester.pumpAndSettle();
      expect(find.text('日报提醒'), findsOneWidget);
      expect(find.text('检查夜间构建'), findsOneWidget);
    });

    testWidgets('geometry: the search capsule lines up with the filter pill, 16 from the screen edges', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => [_daily];
      await pump(tester, SchedulesPage(now: _now));
      final field = tester.getRect(find.byType(SearchCapsule));
      final pill = tester.getRect(find.byType(SegmentedPill<ScheduleFilter>));
      expect(field.left, moreOrLessEquals(16, epsilon: 0.01));
      expect(390 - field.right, moreOrLessEquals(16, epsilon: 0.01));
      expect(field.left, moreOrLessEquals(pill.left, epsilon: 0.01));
      expect(field.right, moreOrLessEquals(pill.right, epsilon: 0.01));
      expect(field.height, 44);
      final glass = tester.getRect(
        find.descendant(of: find.byType(SearchCapsule), matching: find.byIcon(AppIcons.search)),
      );
      expect(glass.center.dx - field.left, moreOrLessEquals(22, epsilon: 0.01), reason: 'centred in its 44 slot');
      expect(glass.center.dy, moreOrLessEquals(field.center.dy, epsilon: 0.01));
    });
  });

  group('geometry', () {
    testWidgets('weekday keys: equal gaps, equal insets from the card edges', (tester) async {
      await pump(
        tester,
        ScheduleEditorPage(
          task: _task(
            _entry('sch-2', 'weekly', {
              'time': '18:30:00.000',
              'timeZone': 'Asia/Shanghai',
              'weekdays': [1, 3, 5],
            }),
          ),
          now: _now,
        ),
      );
      final picker = find.byType(WeekdayPicker);
      await reveal(tester, picker);
      final card = tester.getRect(find.ancestor(of: picker, matching: find.byType(Material)).first);
      final keys = [
        for (final e in find.descendant(of: picker, matching: find.byType(DayKey)).evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      expect(keys, hasLength(7));
      expect(keys.first.left - card.left, moreOrLessEquals(card.right - keys.last.right, epsilon: 0.01));
      expect(keys.first.left - card.left, moreOrLessEquals(16, epsilon: 0.01));
      final gaps = [for (var i = 1; i < 7; i++) keys[i].left - keys[i - 1].right];
      for (final g in gaps) {
        expect(g, moreOrLessEquals(gaps.first, epsilon: 0.01));
      }
      for (final k in keys) {
        expect(k.width, moreOrLessEquals(k.height, epsilon: 0.01));
        expect(k.center.dy, moreOrLessEquals(keys.first.center.dy, epsilon: 0.01));
      }
    });
  });

  testWidgets('geometry: 间隔 field and unit pill share height and centre, 16 from the card edges', (tester) async {
    await pump(tester, ScheduleEditorPage(task: _task(_entry('sch-3', 'every', {'everySeconds': 7200})), now: _now));
    final row = find.byType(IntervalRow);
    await reveal(tester, row);
    final card = tester.getRect(find.ancestor(of: row, matching: find.byType(Material)).first);
    final field = tester.getRect(find.descendant(of: row, matching: find.byType(TextField)));
    final pill = tester.getRect(find.descendant(of: row, matching: find.byType(SegmentedPill<IntervalUnit>)));
    expect(field.height, moreOrLessEquals(pill.height, epsilon: 0.01));
    expect(field.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.01));
    expect(card.right - pill.right, moreOrLessEquals(16, epsilon: 0.01));
    final label = tester.getRect(find.descendant(of: row, matching: find.text('每')));
    expect(label.left - card.left, moreOrLessEquals(16, epsilon: 0.01));
  });

  testWidgets('time-zone sheet: the shared search capsule filters and clears', (tester) async {
    await pump(tester, ScheduleEditorPage(task: _task(_daily), now: _now));
    await reveal(tester, find.text('时区'));
    await tester.tap(find.text('时区'));
    await tester.pumpAndSettle();
    final search = find.byType(SearchCapsule);
    expect(search, findsOneWidget);
    expect(find.text('常用'), findsOneWidget);
    await tester.enterText(find.descendant(of: search, matching: find.byType(TextField)), '纽约');
    await tester.pump();
    expect(find.text('常用'), findsNothing);
    expect(find.text('纽约'), findsWidgets);
    await tester.tap(find.byIcon(AppIcons.clear));
    await tester.pump();
    expect(find.text('常用'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('new task', (tester) async {
        await pump(tester, ScheduleEditorPage(now: _now), brightness: brightness);
        await tester.enterText(find.widgetWithText(TextField, '比如：每日站会提醒'), '站会提醒');
        await tester.enterText(find.byType(TextField).at(1), '整理昨天的提交，发我一段摘要');
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/schedule_editor_new_$mode.png'));
      });

      testWidgets('edit, weekly in another zone', (tester) async {
        await pump(
          tester,
          ScheduleEditorPage(
            task: _task(
              _entry('sch-2', 'weekly', {
                'time': '09:00:00.000',
                'timeZone': 'America/New_York',
                'weekdays': [1, 3, 5],
              }),
            ),
            now: _now,
          ),
          brightness: brightness,
        );
        await reveal(tester, find.byType(SchedulePreview));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/schedule_editor_edit_$mode.png'));
      });

      testWidgets('time-zone sheet', (tester) async {
        await pump(
          tester,
          ScheduleEditorPage(task: _task(_daily), now: _now),
          brightness: brightness,
        );
        await reveal(tester, find.text('时区'));
        await tester.tap(find.text('时区'));
        await tester.pumpAndSettle();
        expect(find.textContaining('本机'), findsOneWidget);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/schedule_zone_sheet_$mode.png'));
      });
    });
  }

  test('labels', () {
    expect(repeatLabels.values, ['每天', '工作日', '每周', '每月', '间隔', '仅一次', '高级']);
    expect(zoneLabel('Asia/Shanghai', at: _now), '上海 · UTC+08:00');
  });
}
