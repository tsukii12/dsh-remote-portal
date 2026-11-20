// The header's schedule clock: shown only while the conversation has active
// tasks; one task opens its page (rule, next runs, 立即运行, 管理), more open
// a list; a failed refresh keeps the clock; the key reads out what it opens.

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/header_schedule_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/header_schedule.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/features/schedule_editor/time_zones.dart';
import 'package:dsh_app/ui/features/schedules_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart';
import 'support/harness.dart';

/// A Saturday afternoon on this machine's clock.
final _now = DateTime(2026, 10, 24, 15, 30);

/// This machine's zone: rules in it read the same on the local clock.
late String _zone;

ScheduleTask _daily({String id = 'sch-1', String title = '日报提醒', DateTime? next}) => ScheduleTask(
  id: id,
  sessionId: 's1',
  kind: 'daily',
  title: title,
  prompt: '$title：整理今天的提交，写一段日报。',
  active: true,
  record: {'id': id, 'kind': 'daily', 'title': title},
  time: '21:30',
  timeZone: _zone,
  scheduledAt: next ?? DateTime(2026, 10, 24, 21, 30),
);

ScheduleTask _every() => ScheduleTask(
  id: 'sch-2',
  sessionId: 's1',
  kind: 'every',
  title: '检查夜间构建',
  prompt: '看一眼构建',
  active: true,
  record: const {'id': 'sch-2', 'kind': 'every'},
  everySeconds: 7200,
  scheduledAt: DateTime(2026, 10, 24, 15, 20),
);

class _Schedules {
  _Schedules(this.tasks);
  List<ScheduleTask> tasks;
  bool fail = false;
  int reads = 0;

  Future<List<ScheduleTask>?> read() async {
    reads++;
    if (fail) throw const DshRemoteException('internal_error', 'boom');
    // As the real source orders them.
    return soonestFirst(tasks);
  }
}

List<Override> _overrides(DshClient client, _Schedules schedules) => [
  activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
  sessionsProvider.overrideWith(FakeSessions.new),
  currentSessionProvider.overrideWith(() => FixedSession('s1')),
  modelCatalogProvider.overrideWith((ref) async => testCatalog),
  sessionSchedulesProvider.overrideWith((ref, id) => schedules.read()),
  scheduleClockProvider.overrideWithValue(() => _now),
  deviceTimeZoneProvider.overrideWith((ref) async => _zone),
  // What 「管理」's detail page reads.
  schedulesProvider.overrideWith((ref) async => schedules.tasks),
  scheduleHistoryProvider.overrideWith((ref, task) async => const ScheduleHistory()),
];

Future<void> _pump(WidgetTester tester, DshClient client, _Schedules schedules, {VoidCallback? onTitleTap}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: ChatHeader(
            title: '每天的构建检查',
            status: const HeaderStatus(StatusTone.ok, '本机'),
            trailing: ModelChip(selection: testCatalog.defaultSelection, onSelected: (_) {}, grouped: true),
            onOpenDrawer: () {},
            onNewChat: () {},
            onTitleTap: onTitleTap ?? () {},
          ),
        ),
      ),
      overrides: _overrides(client, schedules),
    ),
  );
  await pumpFrames(tester);
}

final _key = find.byKey(const ValueKey('chat-schedule'));

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;

  setUpAll(() async {
    await loadTestFonts();
    _zone = await detectDeviceTimeZone();
  });

  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
  });
  tearDown(() => client.close());

  testWidgets('no tasks: no clock, the pill keeps 16 on both sides', (tester) async {
    await _pump(tester, client, _Schedules([]));
    expect(_key, findsNothing);
    final pill = tester.getRect(find.byKey(const ValueKey('chat-title-pill')));
    final title = tester.getRect(find.text('每天的构建检查'));
    final status = tester.getRect(find.text('本机'));
    expect(title.left - pill.left, 16);
    expect(pill.right - (title.right > status.right ? title.right : status.right), moreOrLessEquals(16, epsilon: 0.5));
  });

  testWidgets('one task: the clock opens its page, not the conversation', (tester) async {
    var titleTaps = 0;
    await _pump(tester, client, _Schedules([_daily()]), onTitleTap: () => titleTaps++);
    expect(_key, findsOneWidget);
    await tester.tap(_key);
    await tester.pumpAndSettle();
    expect(titleTaps, 0);
    expect(find.byType(ScheduleTaskSheetPage), findsOneWidget);
    expect(find.text('日报提醒'), findsOneWidget);
    expect(find.text('每天 21:30'), findsOneWidget);
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('今天 21:30'), findsOneWidget);
    expect(find.text('6 小时后'), findsOneWidget);
    expect(find.text('明天 21:30'), findsOneWidget);
    expect(find.text('周一 21:30'), findsOneWidget);
    expect(find.text('立即运行'), findsOneWidget);
    expect(find.text('管理'), findsOneWidget);
  });

  testWidgets('a tap just beside the key still lands on it', (tester) async {
    var titleTaps = 0;
    await _pump(tester, client, _Schedules([_daily()]), onTitleTap: () => titleTaps++);
    final key = tester.getRect(find.byKey(const ValueKey('chat-schedule-key')));
    final pill = tester.getRect(find.byKey(const ValueKey('chat-title-pill')));
    // Between the status line and the key, and in the inset under it.
    await tester.tapAt(Offset(key.left - 4, key.center.dy));
    await tester.pumpAndSettle();
    expect(find.byType(HeaderScheduleSheet), findsOneWidget);
    Navigator.of(tester.element(find.byType(HeaderScheduleSheet))).pop();
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(key.center.dx, pill.bottom - 1));
    await tester.pumpAndSettle();
    expect(find.byType(HeaderScheduleSheet), findsOneWidget);
    expect(titleTaps, 0);
  });

  testWidgets('「管理」 closes the sheet and opens the detail page', (tester) async {
    await _pump(tester, client, _Schedules([_daily()]));
    await tester.tap(_key);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-manage')));
    await tester.pumpAndSettle();
    expect(find.byType(HeaderScheduleSheet), findsNothing);
    expect(find.byType(ScheduleDetailPage), findsOneWidget);
  });

  testWidgets('「立即运行」 sends the instruction here and closes', (tester) async {
    carrier.handlers['session/prompt'] = (_) => {'accepted': true};
    await _pump(tester, client, _Schedules([_daily()]));
    await tester.tap(_key);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-run-now')));
    await tester.pumpAndSettle();
    final request = carrier.argsOf('session/prompt').single['request']! as Map<String, Object?>;
    expect(request['sessionId'], 's1');
    expect(request['mode'], 'queue');
    expect(request['content'], [
      {'type': 'text', 'text': '日报提醒：整理今天的提交，写一段日报。'},
    ]);
    expect(find.byType(HeaderScheduleSheet), findsNothing);
  });

  testWidgets('「立即运行」 failing says so and stays open', (tester) async {
    carrier.handlers['session/prompt'] = (_) => throw const DshRemoteException('internal_error', 'boom');
    await _pump(tester, client, _Schedules([_daily()]));
    await tester.tap(_key);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-run-now')));
    await tester.pumpAndSettle();
    expect(find.text('没能发送'), findsOneWidget);
    expect(find.byType(HeaderScheduleSheet), findsOneWidget);
    expect(find.text('立即运行'), findsOneWidget, reason: 'can try again');
  });

  testWidgets('more tasks: a list, soonest first; a row opens its page', (tester) async {
    await _pump(tester, client, _Schedules([_daily(), _every()]));
    await tester.tap(_key);
    await tester.pumpAndSettle();
    expect(find.byType(ScheduleTaskSheetList), findsOneWidget);
    expect(find.text('自动化任务'), findsOneWidget);
    // The interval task is ten minutes overdue: it leads, in warning.
    final overdue = find.text('每 2 小时 · 已逾期 10 分钟');
    final upcoming = find.text('每天 21:30 · 下次 今天 21:30');
    expect(overdue, findsOneWidget);
    expect(upcoming, findsOneWidget);
    expect(tester.getRect(overdue).top, lessThan(tester.getRect(upcoming).top));
    await tester.tap(find.text('日报提醒'));
    await tester.pumpAndSettle();
    expect(find.byType(ScheduleTaskSheetPage), findsOneWidget);
    expect(find.text('6 小时后'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(ScheduleTaskSheetList), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the clock and offers a retry', (tester) async {
    final schedules = _Schedules([_daily()]);
    await _pump(tester, client, schedules);
    expect(_key, findsOneWidget);
    schedules.fail = true;
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatHeader)));
    container.invalidate(sessionSchedulesProvider('s1'));
    await pumpFrames(tester);
    expect(_key, findsOneWidget);
    await tester.tap(_key);
    await tester.pumpAndSettle();
    expect(find.text('今天 21:30'), findsOneWidget);
    expect(find.text('没能刷新'), findsOneWidget);
    schedules.fail = false;
    final before = schedules.reads;
    await tester.tap(find.text('没能刷新'));
    await tester.pumpAndSettle();
    expect(schedules.reads, before + 1);
    expect(find.text('没能刷新'), findsNothing);
  });

  testWidgets('the task ending while open: 已结束, still manageable', (tester) async {
    final schedules = _Schedules([_daily()]);
    await _pump(tester, client, schedules);
    await tester.tap(_key);
    await tester.pumpAndSettle();
    schedules.tasks = [];
    ProviderScope.containerOf(tester.element(find.byType(ChatHeader))).invalidate(sessionSchedulesProvider('s1'));
    await tester.pumpAndSettle();
    expect(find.text('已结束'), findsOneWidget);
    expect(find.text('接下来'), findsNothing);
    expect(find.text('日报提醒'), findsOneWidget, reason: 'last copy kept');
    expect(find.text('管理'), findsOneWidget);
    // The header lets the clock go once the sheet closes.
    await tester.tap(find.byType(SheetDragHandle));
    await tester.pumpAndSettle();
    expect(_key, findsNothing);
  });

  testWidgets('the key reads out what it opens', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, client, _Schedules([_daily()]));
    final node = tester.getSemantics(find.byKey(const ValueKey('cap')));
    final data = node.getSemanticsData();
    expect(data.label, '自动化任务：日报提醒，下次今天 21:30');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    // The pill keeps its own label; the key isn't merged into it.
    expect(find.bySemanticsLabel(RegExp('每天的构建检查')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('每天的构建检查.*自动化任务')), findsNothing);
    semantics.dispose();
  });
}
