// Exercise the public archive flow during a synchronous selection notification.
import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/archive_notice.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';

void main() {
  testWidgets('same-id public archive flow rejected by route during selection notification releases safely', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = FakeWorkspaceHost();
    host.seedSession('s1', 'Archive reentry', DateTime.utc(2026, 10, 28));
    host.seedWorkspace('/root/code', title: 'Project', sessionIds: ['s1']);
    late BuildContext flowContext;
    late WidgetRef flowRef;
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Consumer(
          builder: (context, ref, _) {
            flowContext = context;
            flowRef = ref;
            return HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true);
          },
        ),
        overrides: workspaceOverrides(
          host,
          current: 's1',
          prefs: const WorkspacePrefs(loaded: true, selected: 'ws-1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    addTearDown(container.read(activeConnectionProvider).value!.client.close);
    expect(container.read(workspacesProvider).ready, isTrue);
    expect(container.read(currentSessionProvider), 's1');
    container.read(drawerSelectionProvider.notifier).start('s1');
    await tester.pump();
    var entered = false;
    var routeWasCovered = false;
    Future<void>? inner;
    final errors = <Object>[];
    final sub = container.listen(currentSessionProvider, (_, next) {
      if (next != null || entered) return;
      entered = true;
      final oldRoute = ModalRoute.of(flowContext)!;
      unawaited(
        Navigator.of(flowContext).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('cover')))),
      );
      routeWasCovered = !oldRoute.isCurrent;
      inner = scheduleArchiveNotice(flowContext, flowRef, ['s1'], '已归档 1 个对话').catchError((
        Object error,
        StackTrace stack,
      ) {
        errors.add(error);
      });
    });
    addTearDown(sub.close);
    await tester.tap(find.descendant(of: find.byType(SelectionActionBar), matching: find.text('归档')));
    await tester.pump();
    expect(entered, isTrue, reason: 'Outer real action must reach current.select(null).');
    expect(routeWasCovered, isTrue, reason: 'The public inner flow must take its route rejection branch.');
    expect(inner, isNotNull);
    await inner;
    expect(errors, isEmpty, reason: 'Route rejection must not access an uninitialized release callback.');
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
