import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/archive_notice.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_actions.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'support.dart';

class _Host extends DrawerHost {
  final archiveReply = Completer<RpcResult>();

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    if (endpoint != 'workspace/archiveSession') return super.call(endpoint, args, timeout: timeout);
    calls.add((endpoint, args));
    return archiveReply.future;
  }
}

class _Flow {
  _Flow(Future<void> operation) {
    done = operation.then((_) {
      completed = true;
    });
  }

  late final Future<void> done;
  bool completed = false;
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences(super.data) : super.withData();

  bool requested = false;
  final reply = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.drawer.view.local.local') {
      requested = true;
      await reply.future;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<_Preferences> _holdFolderWrite() async {
  final prefs = await SharedPreferences.getInstance();
  final previous = SharedPreferencesStorePlatform.instance;
  final store = _Preferences({for (final key in prefs.getKeys()) 'flutter.$key': prefs.get(key)!});
  SharedPreferencesStorePlatform.instance = store;
  addTearDown(() {
    if (!store.reply.isCompleted) store.reply.complete();
    SharedPreferencesStorePlatform.instance = previous;
  });
  return store;
}

const _folder = DrawerFolder(id: 'f1', name: 'Folder', sessionIds: ['s2']);
const _view = DrawerView(loaded: true, folders: [_folder]);

Future<(_Host, ProviderContainer, BuildContext)> _start(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(storedView(_view));
  final host = _Host();
  host.seedSession('s1', 'Archive A', DateTime.utc(2026, 10, 28, 10));
  host.seedSession('s2', 'Folder member', DateTime.utc(2026, 10, 28, 9));
  host.seedWorkspace('/root/code', sessionIds: ['s1', 's2']);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: workspaceOverrides(host, current: 's1', prefs: const WorkspacePrefs(loaded: true)),
    ),
  );
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(HomeShell));
  final container = ProviderScope.containerOf(context);
  final client = container.read(activeConnectionProvider).value!.client;
  addTearDown(() async {
    if (!host.archiveReply.isCompleted) {
      host.archiveReply.complete(const RpcError(DshRemoteException('fixture/archive-denied', 'denied')));
    }
    await client.close();
  });
  expect(container.read(drawerViewProvider).byId('f1'), isNotNull);
  return (host, container, context);
}

Future<_Flow> _deleteFolder(WidgetTester tester, BuildContext context) async {
  final flow = _Flow(folderActionsFlow(context, context as WidgetRef, _folder));
  await tester.pumpAndSettle();
  await tester.tap(find.text('删除文件夹'));
  await tester.idle();
  return flow;
}

_Flow _archive(BuildContext context) =>
    _Flow(scheduleArchiveNotice(context, context as WidgetRef, ['s1'], appL10n.shellChatArchived('Archive A')));

void main() {
  testWidgets('late archive failure ends a replaced folder undo flow', (tester) async {
    final (host, container, context) = await _start(tester);
    final archive = _archive(context);
    await tester.pumpAndSettle();
    await tester.pump(SessionsController.archiveUndoWindow);
    await tester.pumpAndSettle();
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect(archive.completed, isFalse);

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('earlier notice')));
    await tester.pumpAndSettle();
    final folder = await _deleteFolder(tester, context);
    expect(container.read(drawerViewProvider).folders, isEmpty);
    expect(folder.completed, isFalse);

    // The old request can return during the bar's exit animation, without
    // another fast user gesture or a second deletion operation.
    host.archiveReply.complete(const RpcError(DshRemoteException('fixture/archive-denied', 'denied')));
    await tester.pumpAndSettle();
    expect(archive.completed, isTrue);
    expect(find.text(appL10n.shellArchiveFailed), findsOneWidget);
    expect(container.read(sessionsProvider).value!.map((row) => row.sessionId), contains('s1'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(folder.completed, isTrue, reason: 'the replaced notice must release the folder flow and its Host listener');
    await folder.done;
    await archive.done;
    expect(container.read(drawerViewProvider).folders, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a newer archive undo ends a queued folder flow and remains cancellable', (tester) async {
    final (host, container, context) = await _start(tester);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('earlier notice')));
    await tester.pumpAndSettle();
    final write = await _holdFolderWrite();
    final folder = await _deleteFolder(tester, context);
    expect(write.requested, isTrue);
    await tester.pumpAndSettle();
    // Preference persistence can finish while the next real menu is open.
    // Its completion puts up the folder notice just before the archive tap.
    await tester.longPress(find.widgetWithText(SessionTile, 'Archive A'));
    await tester.pumpAndSettle();
    write.reply.complete();
    await tester.idle();
    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.shellChatArchived('Archive A')), findsOneWidget);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    await tester.tap(find.widgetWithText(SnackBarAction, appL10n.shellUndo));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(folder.completed, isTrue);
    await folder.done;
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    expect(container.read(sessionsProvider).value!.map((row) => row.sessionId), contains('s1'));
    expect(container.read(drawerViewProvider).folders, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a folder undo keeps its four second window and then retires its callback', (tester) async {
    final (_, container, context) = await _start(tester);
    final folder = await _deleteFolder(tester, context);
    await tester.pump();
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    // Start the window clock when the entrance actually completes, rather
    // than at its last interpolated frame (value 1 can still be forward).
    for (var frame = 0; frame < 30 && bar.animation!.status != AnimationStatus.completed; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(bar.animation!.status, AnimationStatus.completed);
    final undo = bar.action!.onPressed;
    await tester.pump(const Duration(milliseconds: 3999));
    expect(find.text(appL10n.shellFolderDeleted(_folder.name)), findsOneWidget);
    expect(folder.completed, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(folder.completed, isTrue);
    await folder.done;
    undo();
    await tester.pump();
    expect(container.read(drawerViewProvider).folders, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder undo still waits for restoring the persisted view', (tester) async {
    final (_, container, context) = await _start(tester);
    final folder = await _deleteFolder(tester, context);
    await tester.pumpAndSettle();
    expect(container.read(drawerViewProvider).folders, isEmpty);
    final write = await _holdFolderWrite();
    await tester.tap(find.widgetWithText(SnackBarAction, appL10n.shellUndo));
    await tester.pumpAndSettle();
    expect(write.requested, isTrue);
    expect(folder.completed, isFalse, reason: 'the notice closed but restoring preferences is still pending');
    write.reply.complete();
    await tester.pump();
    expect(folder.completed, isTrue);
    await folder.done;
    expect(container.read(drawerViewProvider).toJson(), _view.toJson());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('drawer.view.local.local'), storedView(_view)['drawer.view.local.local']);
    expect(tester.takeException(), isNull);
  });
}
