// What the drawer's folder and multi-select controls do:
// the flows behind the sheets, bulk 归档 / 置顶 / 移到文件夹, and the undo
// toasts. Archiving follows the single-row archive in sessions_drawer.dart
// (hide at once; stop running work and archive when the undo window ends).
// Permanent session deletion lives in session_deletion.dart and has no undo;
// deleting a folder here keeps its conversations and can be undone.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/connection_state.dart';
import '../../../state/hosts_state.dart';
import '../../../state/read_list_identity.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import 'folder_sheets.dart';
import '../session_search_page.dart' show showSessionSearch;
import 'archive_notice.dart';
import '../../common/brief_notice.dart';

void _toast(ScaffoldMessengerState? messenger, String text, {String? undoLabel, VoidCallback? onUndo}) {
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      persist: false,
      action: onUndo == null ? null : SnackBarAction(label: undoLabel ?? appL10n.shellUndo, onPressed: onUndo),
    ),
  );
}

/// 「对话列表」: the sheet, then what was picked in it.
Future<void> openDrawerViewOptions(BuildContext context, WidgetRef ref, {VoidCallback? onClose}) async {
  final action = await showDrawerViewSheet(context);
  if (!context.mounted || action == null) return;
  switch (action) {
    case DrawerViewAction.archived:
      final sessionId = await showSessionSearch(context, archivedOnly: true);
      if (sessionId == null || !context.mounted) return;
      ref.read(currentSessionProvider.notifier).select(sessionId);
      onClose?.call();
    case DrawerViewAction.newFolder:
      await createFolderFlow(context, ref);
    case DrawerViewAction.manageFolders:
      await showManageFolders(context, onEdit: (folder) => editFolderFlow(context, ref, folder));
    case DrawerViewAction.select:
      ref.read(drawerSelectionProvider.notifier).start();
  }
}

/// 新建文件夹, filing [sessionIds] in it. Returns the new folder's id.
Future<String?> createFolderFlow(BuildContext context, WidgetRef ref, {List<String> sessionIds = const []}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = container.read(activeHostProvider);
  var retired = false;
  final subscription = container.listen(activeHostProvider, (_, next) {
    if (next != owner) retired = true;
  });
  bool owned() => !retired && !subscription.closed;
  try {
    final view = ref.read(drawerViewProvider.notifier);
    final draft = await showFolderEditor(context, takenNames: ref.read(drawerViewProvider).folders.map((f) => f.name));
    if (!context.mounted || draft == null || !owned()) return null;
    return await view.createFolder(
      draft.name,
      tint: draft.tint,
      emoji: draft.emoji,
      sessionIds: sessionIds,
      isCurrent: owned,
    );
  } finally {
    subscription.close();
  }
}

/// 编辑 a folder's name and mark.
Future<void> editFolderFlow(BuildContext context, WidgetRef ref, DrawerFolder folder) async {
  final view = ref.read(drawerViewProvider.notifier);
  final draft = await showFolderEditor(
    context,
    initial: folder,
    takenNames: ref.read(drawerViewProvider).folders.where((f) => f.id != folder.id).map((f) => f.name),
  );
  if (draft == null) return;
  await view.updateFolder(folder.id, name: draft.name, tint: () => draft.tint, emoji: () => draft.emoji);
}

/// Long press on a folder: start a chat, edit, or delete the folder.
/// Deleting keeps its conversations; undo puts the folder back.
Future<void> folderActionsFlow(
  BuildContext context,
  WidgetRef ref,
  DrawerFolder folder, {
  VoidCallback? onNewChat,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = container.read(activeHostProvider);
  var retired = false;
  final subscription = container.listen(activeHostProvider, (_, next) {
    if (next != owner) retired = true;
  });
  bool owned() => !retired && !subscription.closed;
  Future<void>? undo;
  try {
    final action = await showFolderActionSheet(context, folder);
    if (!context.mounted || action == null || !owned()) return;
    switch (action) {
      case FolderAction.newChat:
        if (ref.read(drawerViewProvider).byId(folder.id) == null) return;
        ref.read(currentSessionProvider.notifier).select(null);
        ref.read(pendingSessionFolderProvider.notifier).select(folder.id);
        onNewChat?.call();
      case FolderAction.edit:
        await editFolderFlow(context, ref, folder);
      case FolderAction.delete:
        final messenger = ScaffoldMessenger.maybeOf(context);
        final view = ref.read(drawerViewProvider.notifier);
        final removed = await view.deleteFolder(folder.id, isCurrent: owned);
        if (removed == null || !owned() || messenger == null || !messenger.mounted) return;
        final notice = messenger.showUndoNotice(
          appL10n.shellFolderDeleted(folder.name),
          undoLabel: appL10n.shellUndo,
          window: const Duration(seconds: 4),
          onUndo: () {
            if (!owned()) return;
            undo = view.restoreFolder(removed.$1, removed.$2, isCurrent: owned);
          },
        );
        await notice.closed;
        // Keep the lease through restore's own await, even if the action closes
        // its Snackbar first. Container disposal closes the subscription itself.
        await undo;
    }
  } finally {
    subscription.close();
  }
}

/// 移到文件夹 for [ids] (one row, or the multi-select). Ends multi-select
/// once something moved.
Future<void> moveToFolderFlow(BuildContext context, WidgetRef ref, List<String> ids) async {
  if (ids.isEmpty) return;
  final view = ref.read(drawerViewProvider);
  final viewNotifier = ref.read(drawerViewProvider.notifier);
  final selection = ref.read(drawerSelectionProvider.notifier);
  final folderOf = view.folderOf;
  final homes = {for (final id in ids) folderOf[id]};
  final listed = {for (final s in ref.read(drawerScopeProvider)?.sessions ?? const <SessionSummary>[]) s.sessionId};
  final pick = await showMoveToFolderSheet(
    context,
    folders: view.folders,
    counts: {for (final f in view.folders) f.id: f.sessionIds.where(listed.contains).length},
    currentFolder: homes.length == 1 ? homes.first : null,
    anyFiled: homes.any((h) => h != null),
  );
  if (!context.mounted || pick == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  String? target;
  switch (pick) {
    case PickFolder(:final folderId):
      target = folderId;
    case PickNoFolder():
      target = null;
    case PickNewFolder():
      // The editor files them; undo takes them back out (the folder stays).
      final before = {for (final id in ids) id: folderOf[id]};
      final id = await createFolderFlow(context, ref, sessionIds: ids);
      if (id == null) return;
      selection.end();
      final name = ref.read(drawerViewProvider).byId(id)?.name ?? '';
      _toast(messenger, appL10n.shellMovedToFolder(name), onUndo: () => viewNotifier.restoreAssignments(before));
      return;
  }
  final previous = await viewNotifier.moveSessions(ids, target);
  selection.end();
  final name = target == null ? null : ref.read(drawerViewProvider).byId(target)?.name;
  _toast(
    messenger,
    name == null ? appL10n.shellMovedOutOfFolder : appL10n.shellMovedToFolder(name),
    onUndo: () => viewNotifier.restoreAssignments(previous),
  );
}

/// Bulk 置顶: pins the chosen conversations, or unpins them when all are
/// pinned already.
Future<void> pinSelectionFlow(BuildContext context, WidgetRef ref) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final chosen = container.read(drawerSelectionProvider);
  final ids = chosen?.toList() ?? const [];
  if (ids.isEmpty) return;
  final selectedHost = container.read(activeHostProvider);
  final connection = container.read(readListLiveConnectionProvider);
  if (connection == null) return;
  final generation = connection.client.mux.generation;
  final ready = connection.client.mux.lastReadyGenerationNumber;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final route = ModalRoute.of(context);
  final registry = container.read(workspacesProvider.notifier);
  final selection = container.read(drawerSelectionProvider.notifier);
  final pinned = container.read(workspacesProvider).pinnedSessionIds.toSet();
  final unpin = ids.every(pinned.contains);
  // A return to A cannot revive a batch retired while B was selected. Keep
  // ownership independent of the drawer widget, which can close mid-request.
  var retired = false;
  final hostChanges = container.listen(activeHostProvider, (_, next) {
    if (next != selectedHost) retired = true;
  });
  final liveChanges = container.listen(readListLiveConnectionProvider, (_, next) {
    if (!identical(next, connection)) retired = true;
  });
  bool owned() {
    if (retired || hostChanges.closed || liveChanges.closed) return false;
    try {
      final host = hostChanges.read();
      final live = liveChanges.read();
      return !retired &&
          !hostChanges.closed &&
          !liveChanges.closed &&
          host == selectedHost &&
          identical(live, connection) &&
          identical(connection.client.mux.generation, generation) &&
          connection.client.mux.lastReadyGenerationNumber == ready;
    } on StateError {
      // A synchronous dependency notification can dispose the scope while a
      // subscription read is flushing. An unavailable owner cannot continue.
      retired = true;
      return false;
    }
  }

  var done = 0;
  try {
    // Pinned last ends up first: preserve the original bottom-up order.
    for (final id in unpin ? ids : ids.reversed.where((id) => !pinned.contains(id))) {
      if (!owned()) return;
      try {
        await (unpin ? registry.unpinSession(id) : registry.pinSession(id));
        if (!owned()) return;
        done++;
      } catch (_) {
        if (!owned()) return;
        // Count a same-owner failure below and continue the requested batch.
      }
    }
    if (!owned() || !identical(container.read(drawerSelectionProvider), chosen)) return;
    selection.end();
    // Ending selection may synchronously create a new selection or switch Host.
    if (!owned() ||
        container.read(drawerSelectionProvider) != null ||
        !context.mounted ||
        messenger == null ||
        !messenger.mounted ||
        !(route?.isCurrent ?? true)) {
      return;
    }
    if (done == 0) {
      _toast(messenger, unpin ? appL10n.shellUnpinFailed : appL10n.shellPinFailed);
      return;
    }
    messenger.showBriefNotice(unpin ? appL10n.shellChatsUnpinned(done) : appL10n.shellChatsPinned(done));
  } finally {
    hostChanges.close();
    liveChanges.close();
  }
}

/// Bulk 归档: one undo window for the selected batch; running work stops when
/// it is archived.
Future<void> archiveSelectionFlow(BuildContext context, WidgetRef ref) async {
  final selection = ref.read(drawerSelectionProvider);
  final ids = selection?.toList() ?? const <String>[];
  if (ids.isEmpty) return;
  final running = {
    for (final s in ref.read(sessionsProvider).value ?? const <SessionSummary>[])
      if (s.running) s.sessionId,
  };
  final text = ids.any(running.contains)
      ? appL10n.shellChatsStoppedArchived(ids.length)
      : appL10n.shellChatsArchived(ids.length);
  final host = ref.read(activeHostProvider);
  final connection = ref.read(activeConnectionProvider).value;
  final generation = connection?.client.mux.generation;
  final readyGeneration = connection?.client.mux.lastReadyGenerationNumber;
  unawaited(scheduleArchiveNotice(context, ref, ids, text));
  // Scheduling clears the current conversation synchronously. A listener may
  // change Host or start a new selection, even with exactly the same IDs.
  if (!context.mounted ||
      ref.read(activeHostProvider) != host ||
      !identical(ref.read(activeConnectionProvider).value, connection) ||
      !identical(connection?.client.mux.generation, generation) ||
      connection?.client.mux.lastReadyGenerationNumber != readyGeneration ||
      !identical(ref.read(drawerSelectionProvider), selection)) {
    return;
  }
  ref.read(drawerSelectionProvider.notifier).end();
}
