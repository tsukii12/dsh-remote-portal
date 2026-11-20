import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/sessions_state.dart';
import '../../../state/connection_state.dart';
import '../../../state/hosts_state.dart';
import '../../common/brief_notice.dart';
import '../../common/undo_notice_window.dart';

/// Both drawer entry points: hides [ids] at once and shows [text] (「已归档…」)
/// with 撤销 for the undo window; the Host archives them when it ends. Only
/// what makes [text] untrue is reported afterwards: rows that could not be
/// archived, or a plan dropped without 撤销 before anything was sent.
Future<void> scheduleArchiveNotice(BuildContext context, WidgetRef ref, List<String> ids, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final route = ModalRoute.of(context);
  final selected = ref.read(activeHostProvider);
  final connection = ref.read(activeConnectionProvider).value;
  final generation = connection?.client.mux.generation;
  final ready = connection?.client.mux.lastReadyGenerationNumber;
  final intent = reserveUndoNotice(messenger);
  PendingSessionArchive pending;
  try {
    pending = ref.read(sessionsProvider.notifier).scheduleArchive(ids);
  } catch (_) {
    bool owned() =>
        context.mounted &&
        messenger.mounted &&
        (route?.isCurrent ?? true) &&
        intent.isCurrent &&
        ref.read(activeHostProvider) == selected &&
        identical(ref.read(activeConnectionProvider).value, connection) &&
        identical(connection?.client.mux.generation, generation) &&
        connection?.client.mux.lastReadyGenerationNumber == ready;
    await publishAfterUndoNotice(messenger, owned, () {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(l10n.shellArchiveFailed)));
    });
    return;
  }
  if (!pending.owned || !pending.canUndo || !messenger.mounted || !(route?.isCurrent ?? true)) {
    pending.cancel();
    pending.release();
    return;
  }
  final lease = intent.claim(
    identity: pending,
    canUndo: () => pending.canUndo,
    cancel: pending.cancel,
    commit: pending.commitNow,
    windowClosed: pending.windowClosed,
  );
  if (lease == null) {
    pending.release();
    return;
  }
  if (!identical(lease.intent, intent)) return;
  if (!pending.owned ||
      !pending.canUndo ||
      !lease.isCurrent ||
      !intent.isCurrent ||
      !messenger.mounted ||
      !(route?.isCurrent ?? true)) {
    pending.cancel();
    pending.release();
    return;
  }
  final notice = messenger.showUndoNotice(
    text,
    undoLabel: l10n.shellUndo,
    onUndo: pending.undo,
    window: SessionsController.archiveUndoWindow,
  );
  lease.attach(messenger, notice);
  try {
    final result = await pending.done;
    final String failure;
    if (result == null) {
      // 撤销 is the user's own doing; once sending started, the reloaded list
      // tells what the Host did.
      if (pending.undone || pending.sent) return;
      failure = l10n.shellArchiveFailed;
    } else if (result.failed.isEmpty) {
      return;
    } else {
      failure = result.archived.isEmpty
          ? l10n.shellArchiveFailed
          : l10n.shellChatsArchivedPartial(result.archived.length, result.failed.length);
    }
    // The same Host's screen, even across a reconnect: its rows came back.
    bool owned() =>
        messenger.mounted && (route?.isCurrent ?? true) && container.read(activeHostProvider) == selected;
    await publishAfterUndoNotice(messenger, owned, () {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(failure)));
    });
  } finally {
    pending.release();
  }
}
