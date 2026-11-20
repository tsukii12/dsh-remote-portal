// UNRUN: fixed f87 + PLUGIN-UNDO-V2 + ARCHIVE-DELAY-V3 combination.
// Real HomeShell/settings/plugins routes and real production undo controllers.
import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/common/undo_notice_window.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/support/fake_plugin_host.dart' show bundleJson;
import '../plugins/support/notice_on_top.dart';
import '../shell/golden_harness.dart';
import '../workspace/support.dart';

class _Host extends FakeWorkspaceHost {
  final archiveReply = Completer<void>();
  final removeReply = Completer<void>();
  bool installed = true;
  bool holdRemove = false;
  Map<String, Object?> get bundle => bundleJson('cross-flow-b', title: 'Cross B');

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'workspace/archiveSession') {
      calls.add((endpoint, args));
      await archiveReply.future;
      archived = ['s1'];
      push({'type': 'archived', 'archivedSessionIds': archived});
      return RpcOk({'archivedSessionIds': archived});
    }
    if (endpoint == 'pluginManager/listBundles') {
      calls.add((endpoint, args));
      return RpcOk([if (installed) bundle]);
    }
    if (endpoint == 'pluginManager/removeBundle') {
      calls.add((endpoint, args));
      if (holdRemove) await removeReply.future;
      installed = false;
      return RpcOk({'stage': 'remove', 'target': 'cross-flow-b', 'changed': true, 'application': 'applied'});
    }
    return super.call(endpoint, args, timeout: timeout);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
}

Future<(_Host, ProviderContainer, ScaffoldMessengerState, Route<dynamic>)> _start(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final host = _Host();
  host.seedSession('s1', 'Archive A', DateTime.utc(2026, 10, 28));
  host.seedWorkspace('/root/code', title: 'Project', sessionIds: ['s1']);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: workspaceOverrides(
        host,
        current: 's1',
        prefs: const WorkspacePrefs(loaded: true, selected: 'ws-1'),
      ),
    ),
  );
  await _settle(tester);
  final context = tester.element(find.byType(HomeShell));
  final container = ProviderScope.containerOf(context);
  final client = container.read(activeConnectionProvider).value!.client;
  addTearDown(() async {
    if (!host.archiveReply.isCompleted) host.archiveReply.complete();
    if (!host.removeReply.isCompleted) host.removeReply.complete();
    await client.close();
  });
  return (host, container, ScaffoldMessenger.of(context), ModalRoute.of(context)!);
}

Future<void> _archive(WidgetTester tester) async {
  await tester.longPress(find.widgetWithText(SessionTile, 'Archive A'));
  await _settle(tester);
  await tester.tap(find.text('归档'));
  await _settle(tester);
}

Future<Route<dynamic>> _openPlugins(WidgetTester tester, ScaffoldMessengerState root) async {
  // f87 visible route is drawer Settings -> Plugins, not the unused enum case.
  if (find.byTooltip('设置').hitTestable().evaluate().isEmpty) {
    await tester.dragFrom(const Offset(1, 300), const Offset(320, 0));
    await _settle(tester);
  }
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
  await _settle(tester);
  final settings = tester.element(find.byType(SettingsScreen));
  final pluginTile = find.text(settings.l10n.hubPlugins);
  await tester.scrollUntilVisible(
    pluginTile,
    300,
    scrollable: find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(pluginTile);
  await tester.pumpAndSettle();
  expect(pluginTile.hitTestable(), findsOneWidget);
  await tester.tap(pluginTile);
  await _settle(tester);
  final page = tester.element(find.byType(PluginsScreen));
  expect(identical(ScaffoldMessenger.of(page), root), isTrue);
  return ModalRoute.of(page)!;
}

Future<PendingPluginRemoval> _remove(
  WidgetTester tester,
  ProviderContainer container,
  _Host host,
  ScaffoldMessengerState root,
) async {
  await tester.tap(find.text('Cross B'));
  await _settle(tester);
  expect(identical(ScaffoldMessenger.of(tester.element(find.byType(BundleSheet))), root), isTrue);
  await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
  await _settle(tester);
  await tester.tap(find.widgetWithText(FilledButton, '卸载'));
  await _settle(tester);
  expect(find.byType(BundleSheet), findsNothing);
  expect(container.read(installedPluginsProvider).value, isEmpty);
  expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
  expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
  // Same-name schedule returns existing handle; assertions above establish the UI created it.
  final pending = container.read(installedPluginsProvider.notifier).scheduleRemoval(PluginBundle.fromJson(host.bundle));
  addTearDown(() {
    if (pending.canUndo) pending.cancel();
  });
  expect(pending.canUndo, isTrue);
  return pending;
}

Future<void> _backHome(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回')); // Plugins -> Settings.
  await _settle(tester);
  await tester.tap(find.byTooltip('返回')); // Settings -> HomeShell.
  await _settle(tester);
}

void main() {
  testWidgets('control plugin undo survives page return and cancels before dispatch', (tester) async {
    final (host, container, root, homeRoute) = await _start(tester);
    final pluginRoute = await _openPlugins(tester, root);
    final pending = await _remove(tester, container, host, root);
    await _backHome(tester);
    expect(homeRoute.isCurrent, isTrue);
    expect(pluginRoute.isCurrent, isFalse);
    expect(pending.canUndo, isTrue);
    expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pump(const Duration(seconds: 5));
    expect(await pending.done, isNull);
    expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
    expect(container.read(installedPluginsProvider).value, hasLength(1));
  });

  testWidgets('late archive result cannot hide still-cancellable plugin undo on returned HomeShell', (tester) async {
    final (host, container, root, homeRoute) = await _start(tester);
    await _archive(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect(host.archiveReply.isCompleted, isFalse);
    final pluginRoute = await _openPlugins(tester, root);
    final pending = await _remove(tester, container, host, root);
    await _backHome(tester);
    expect(homeRoute.isCurrent, isTrue);
    expect(pluginRoute.isCurrent, isFalse);
    expect(pending.canUndo, isTrue);
    expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
    final before = tester.widget<SnackBar>(find.byType(SnackBar)).content as Text;
    expect(before.data, contains('Cross B'));
    expect(snackBarOnTop(tester, before.data!), isTrue);
    host.archiveReply.complete();
    await _settle(tester);
    expect(pending.canUndo, isTrue, reason: 'B is still in its pre-dispatch window');
    expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
    expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
    final after = tester.widget<SnackBar>(find.byType(SnackBar)).content as Text;
    expect(after.data, contains('Cross B'));
    expect(snackBarOnTop(tester, after.data!), isTrue);
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pump(const Duration(seconds: 5));
    expect(await pending.done, isNull);
    expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
  });

  testWidgets('control retired plugin owner route does not overwrite a later archive undo', (tester) async {
    final (host, container, root, homeRoute) = await _start(tester);
    host.holdRemove = true;
    final pluginRoute = await _openPlugins(tester, root);
    await _remove(tester, container, host, root);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(host.argsOf('pluginManager/removeBundle'), hasLength(1));
    await _backHome(tester);
    expect(pluginRoute.isCurrent, isFalse);
    expect(homeRoute.isCurrent, isTrue);
    // HomeShell closed the drawer when navigating; use its real opening drag.
    await tester.dragFrom(const Offset(1, 300), const Offset(320, 0));
    await _settle(tester);
    await _archive(tester);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    host.removeReply.complete();
    await _settle(tester);
    expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
    expect(find.text('已归档「Archive A」'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });
  testWidgets('new plugin waiting sends the previous waiting archive at once', (tester) async {
    final (host, container, root, _) = await _start(tester);
    await _archive(tester);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    // The pending snackbar covers f87's bottom Settings button. Dismiss the
    // visible bar by its real swipe gesture; the underlying waiting plan is
    // still sent at once when the later plugin plan takes over the shared slot.
    await tester.drag(find.byType(SnackBar), const Offset(0, 150));
    await tester.pumpAndSettle();
    await _openPlugins(tester, root);
    final pending = await _remove(tester, container, host, root);
    expect(host.argsOf('workspace/archiveSession'), hasLength(1), reason: 'A lost its notice, so it is sent now');
    expect(find.text('已卸载「Cross B」'), findsOneWidget);
    expect(container.read(sessionsProvider).value!.map((row) => row.sessionId), isNot(contains('s1')));
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pump(const Duration(seconds: 5));
    expect(await pending.done, isNull);
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
  });

  testWidgets('new archive waiting sends the previous waiting plugin removal at once', (tester) async {
    final (host, container, root, _) = await _start(tester);
    await _openPlugins(tester, root);
    final pending = await _remove(tester, container, host, root);
    await _backHome(tester);
    await tester.dragFrom(const Offset(1, 300), const Offset(320, 0));
    await _settle(tester);
    await _archive(tester);
    expect((await pending.done)!.succeeded, isTrue, reason: 'B lost its notice, so it is sent now');
    expect(find.text('已归档「Archive A」'), findsOneWidget);
    expect(container.read(installedPluginsProvider).value, isEmpty);
    expect(host.argsOf('pluginManager/removeBundle'), hasLength(1));
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    expect(host.argsOf('pluginManager/removeBundle'), hasLength(1));
  });
  for (final duringClaim in [false, true]) {
    for (final validC in [false, true]) {
      testWidgets('a newer plan sends A instead of restoring its selection: claim=$duringClaim validC=$validC', (
        tester,
      ) async {
        final (host, container, root, _) = await _start(tester);
        host.seedSession('s2', 'Second', DateTime.utc(2026, 10, 28));
        host.workspaces.first['sessionIds'] = ['s1', 's2'];
        host.push({'type': 'upsert', 'workspace': host.workspaces.first});
        await container.read(sessionsProvider.notifier).refresh();
        await container.read(installedPluginsProvider.future);
        await _settle(tester);
        await _archive(tester); // Real A UI and controller; current was cleared.
        expect(container.read(currentSessionProvider), isNull);
        final sessions = container.read(sessionsProvider.notifier);
        final plugins = container.read(installedPluginsProvider.notifier);
        PendingSessionArchive? bArchive;
        PendingSessionArchive? cArchive;
        PendingPluginRemoval? bPlugin;
        PendingPluginRemoval? cPlugin;
        UndoNoticeLease? cLease;
        var fired = false;
        final listener = container.listen(currentSessionProvider, (_, next) {
          if (next != 's1' || fired) return;
          fired = true;
          final cIntent = reserveUndoNotice(root);
          try {
            if (duringClaim) {
              final c = sessions.scheduleArchive([validC ? 's2' : 'missing']);
              cArchive = c;
              cLease = cIntent.claim(
                identity: c,
                canUndo: () => c.canUndo,
                cancel: c.cancel,
                commit: c.commitNow,
                windowClosed: c.windowClosed,
              );
            } else {
              final c = plugins.scheduleRemoval(PluginBundle.fromJson(validC ? host.bundle : bundleJson('missing')));
              cPlugin = c;
              cLease = cIntent.claim(
                identity: c,
                canUndo: () => c.canUndo,
                cancel: c.cancel,
                commit: c.commitNow,
                windowClosed: c.windowClosed,
              );
            }
          } on DshClosedException {
            expect(validC, isFalse);
          }
        });
        addTearDown(() {
          listener.close();
          for (final p in [bArchive, cArchive]) {
            if (p != null) {
              if (p.canUndo) p.cancel();
              p.release();
            }
          }
          for (final p in [bPlugin, cPlugin]) {
            if (p != null && p.canUndo) p.cancel();
          }
        });
        final bIntent = reserveUndoNotice(root);
        UndoNoticeLease? bLease;
        if (duringClaim) {
          final b = plugins.scheduleRemoval(PluginBundle.fromJson(host.bundle));
          bPlugin = b;
          bLease = bIntent.claim(
            identity: b,
            canUndo: () => b.canUndo,
            cancel: b.cancel,
            commit: b.commitNow,
            windowClosed: b.windowClosed,
          );
        } else {
          final b = sessions.scheduleArchive(['s2']);
          bArchive = b;
          bLease = bIntent.claim(
            identity: b,
            canUndo: () => b.canUndo,
            cancel: b.cancel,
            commit: b.commitNow,
            windowClosed: b.windowClosed,
          );
        }
        // A listener that would schedule C if A's selection came back never runs.
        expect(fired, isFalse, reason: 'A is sent, not dropped, so its selection is not restored');
        expect(cLease, isNull);
        expect(bLease!.isCurrent, isTrue);
        expect(bArchive?.canUndo ?? bPlugin!.canUndo, isTrue);
        await _settle(tester);
        expect(host.argsOf('workspace/archiveSession'), hasLength(1));
        expect(host.argsOf('pluginManager/removeBundle'), isEmpty);
      });
    }
  }
}
