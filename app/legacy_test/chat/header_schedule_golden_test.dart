// Goldens (light + dark) of the header's schedule clock: the pill with its
// end-cap key at three text sizes, a single task's sheet and the list of
// several. Regenerate with
// `flutter test --update-goldens test/chat/header_schedule_golden_test.dart`.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/header_schedule_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/features/schedule_editor/time_zones.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// A Saturday afternoon on this machine's clock.
final _now = DateTime(2026, 10, 24, 15, 30);

/// This machine's zone: rules in it read the same on the local clock.
late String _zone;

ScheduleTask _daily() => ScheduleTask(
  id: 'sch-1',
  sessionId: 's1',
  kind: 'daily',
  title: '日报提醒',
  prompt: '整理今天的提交，写一段日报。',
  active: true,
  record: const {'id': 'sch-1', 'kind': 'daily'},
  time: '21:30',
  timeZone: _zone,
  scheduledAt: DateTime(2026, 10, 24, 21, 30),
);

ScheduleTask _weekly() => ScheduleTask(
  id: 'sch-2',
  sessionId: 's1',
  kind: 'weekly',
  title: '周报草稿',
  prompt: '把这周的改动整理成周报草稿。',
  active: true,
  record: const {'id': 'sch-2', 'kind': 'weekly'},
  time: '18:30',
  timeZone: _zone,
  weekdays: const [1, 2, 3, 4, 5],
  scheduledAt: DateTime(2026, 10, 26, 18, 30),
);

ScheduleTask _overdue() => ScheduleTask(
  id: 'sch-3',
  sessionId: 's1',
  kind: 'every',
  title: '检查夜间构建',
  prompt: '看一眼构建',
  active: true,
  record: const {'id': 'sch-3', 'kind': 'every'},
  everySeconds: 7200,
  scheduledAt: DateTime(2026, 10, 24, 15, 20),
);

Widget _header({double scale = 1, bool top = true}) => Builder(
  builder: (context) => MediaQuery(
    // Only the first header sits under the status bar.
    data: MediaQuery.of(context).removePadding(removeTop: !top).copyWith(textScaler: TextScaler.linear(scale)),
    child: ChatHeader(
      title: '每天的构建检查',
      status: const HeaderStatus(StatusTone.ok, '本机'),
      trailing: ModelChip(selection: testCatalog.defaultSelection, onSelected: (_) {}, grouped: true),
      onOpenDrawer: () {},
      onTitleTap: () {},
      onNewChat: () {},
    ),
  ),
);

Future<void> _pump(WidgetTester tester, Widget body, List<ScheduleTask> tasks, Brightness brightness) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(body: body),
      brightness: brightness,
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
        // The model list follows the host, which reads the on-device engine: no native runtime in tests.
        localConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        localRuntimeProvider.overrideWith(StaticRuntime.new),
        sessionsProvider.overrideWith(FakeSessions.new),
        currentSessionProvider.overrideWith(() => FixedSession('s1')),
        modelCatalogProvider.overrideWith((ref) async => testCatalog),
        sessionSchedulesProvider.overrideWith((ref, id) async => soonestFirst(tasks)),
        scheduleClockProvider.overrideWithValue(() => _now),
        deviceTimeZoneProvider.overrideWith((ref) async => _zone),
      ],
    ),
  );
  await pumpFrames(tester);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    _zone = await detectDeviceTimeZone();
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('the pill with its clock at 1, 1.3 and 2', (tester) async {
        await _pump(
          tester,
          Column(
            children: [
              _header(),
              const SizedBox(height: 32),
              _header(scale: 1.3, top: false),
              const SizedBox(height: 32),
              _header(scale: 2, top: false),
            ],
          ),
          [_daily()],
          brightness,
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/header_schedule_bar_$mode.png'));
      });

      testWidgets('one task: its sheet', (tester) async {
        await _pump(tester, Align(alignment: Alignment.topCenter, child: _header()), [_daily()], brightness);
        await tester.tap(find.byKey(const ValueKey('chat-schedule')));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/header_schedule_sheet_$mode.png'));
      });

      testWidgets('several tasks: the list', (tester) async {
        await _pump(tester, Align(alignment: Alignment.topCenter, child: _header()), [
          _weekly(),
          _daily(),
          _overdue(),
        ], brightness);
        await tester.tap(find.byKey(const ValueKey('chat-schedule')));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/header_schedule_list_$mode.png'));
      });
    });
  }
}
