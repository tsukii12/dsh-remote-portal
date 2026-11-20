// Permanent deletion is separate from archive and never has an undo window.
import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/session_deletion_state.dart';
import '../../../state/sessions_state.dart';
import '../../common/app_dialog.dart';
import '../../theme/app_icons.dart';
import '../sessions_drawer.dart' show sessionTitle;

/// A disabled destructive control always explains why it cannot be used.
///
/// Three distinct situations, three different answers: still finding out
/// ("checking" / "temporarily unavailable"), the Host's own refusal, and a
/// deletion that is fine to offer. "Not answered yet" is never reported as
/// "this host does not support it".
String? sessionDeletionDisabledReason(
  BuildContext context, {
  required AsyncValue<SessionDeletionSupport> available,
  required bool busy,
  required Iterable<SessionSummary> sessions,
  required Iterable<String> ids,
}) {
  final l10n = context.l10n;
  if (busy) return l10n.shellDeletingChats;
  if (available.hasError) return l10n.shellDeleteUnavailable;
  if (available.isLoading) return l10n.shellDeleteChecking;
  // Exhaustive on purpose: a new capability state must decide its copy here,
  // and "not asked yet" can never quietly borrow the Host's refusal.
  final String? capability = switch (available.value) {
    null || SessionDeletionSupport.unknown =>
      // No live connection or no ready mux generation: nothing was asked, so
      // say "try again once connected", not "unsupported".
      l10n.shellDeleteUnavailable,
    SessionDeletionSupport.supported => null,
    SessionDeletionSupport.unsupported => l10n.shellDeleteUnsupported,
  };
  if (capability != null) return capability;
  final rows = {for (final row in sessions) row.sessionId: row};
  if (ids.any((id) => rows[id] == null)) return l10n.shellDeleteInventoryChanged;
  if (ids.any((id) => rows[id]!.running)) return l10n.shellDeleteRunning;
  return null;
}

class SessionDeleteTile extends ConsumerWidget {
  const SessionDeleteTile({
    super.key,
    required this.ids,
    required this.onTap,
    required this.owner,
    this.archived = false,
  });

  final List<String> ids;
  final VoidCallback onTap;
  final SessionDeletionOwner? owner;

  /// Validate against the live archive instead of the drawer's visible rows.
  final bool archived;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(drawerScopeProvider);
    final reason = sessionDeletionDisabledReason(
      context,
      available: ref.watch(sessionDeletionAvailableProvider),
      busy: ref.watch(sessionDeletionBusyProvider),
      sessions: archived
          ? ref.read(sessionsProvider.notifier).archivedSessions
          : scope?.sessions ?? const <SessionSummary>[],
      ids: ids,
    );
    final current = owner?.isCurrent(ref) == true;
    final enabled = current && reason == null && scope?.readOnly == false;
    final color = Theme.of(context).colorScheme.error;
    return ListTile(
      key: const ValueKey('session-delete-action'),
      enabled: enabled,
      leading: Icon(AppIcons.delete, color: enabled ? color : null),
      title: Text(context.l10n.shellDeletePermanently, style: TextStyle(color: enabled ? color : null)),
      subtitle: Text(!current ? context.l10n.shellDeleteOwnerChanged : reason ?? context.l10n.shellDeleteNoUndo),
      onTap: enabled ? onTap : null,
    );
  }
}

Future<void> deleteSelectionFlow(BuildContext context, WidgetRef ref) async {
  final chosen = ref.read(drawerSelectionProvider);
  if (chosen == null || chosen.isEmpty) return;
  final owner = captureSessionDeletionOwner(ref);
  if (owner == null) return;
  try {
    await deleteSessionsFlow(context, ref, chosen.toList(), owner: owner, selection: chosen);
  } finally {
    owner.close();
  }
}

/// [owner] must predate every sheet in the intent (including a row's action
/// sheet). Its irrevocable lease prevents A -> B -> A from reviving consent.
Future<void> deleteSessionsFlow(
  BuildContext context,
  WidgetRef ref,
  List<String> ids, {
  required SessionDeletionOwner owner,
  Set<String>? selection,
  bool archived = false,
}) async {
  if (ids.isEmpty || !owner.isCurrent(ref)) return;
  final scope = ref.read(drawerScopeProvider);
  if (scope == null || scope.readOnly) return;
  final rows = archived ? ref.read(sessionsProvider.notifier).archivedSessions : scope.sessions;
  final reason = sessionDeletionDisabledReason(
    context,
    available: ref.read(sessionDeletionAvailableProvider),
    busy: ref.read(sessionDeletionBusyProvider),
    sessions: rows,
    ids: ids,
  );
  if (reason != null) return;
  final titles = {for (final row in rows) row.sessionId: sessionTitle(row)};
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => Consumer(
      builder: (context, ref, _) {
        // Rebuild on capability/connection changes; confirmation itself still
        // checks the lease synchronously immediately before it returns consent.
        final available = ref.watch(sessionDeletionAvailableProvider);
        final busy = ref.watch(sessionDeletionBusyProvider);
        final scope = ref.watch(drawerScopeProvider);
        final reason = sessionDeletionDisabledReason(
          context,
          available: available,
          busy: busy,
          sessions: archived
              ? ref.read(sessionsProvider.notifier).archivedSessions
              : scope?.sessions ?? const <SessionSummary>[],
          ids: ids,
        );
        final current = owner.isCurrent(ref);
        return AlertDialog(
          key: const ValueKey('session-delete-confirmation'),
          title: Text(
            ids.length == 1
                ? context.l10n.shellDeleteChatConfirmation(titles[ids.single] ?? ids.single)
                : context.l10n.shellDeleteChatsConfirmation(ids.length),
          ),
          content: SingleChildScrollView(
            child: Text(
              current
                  ? [context.l10n.shellDeleteWarning, ?reason].join('\n\n')
                  : context.l10n.shellDeleteOwnerChanged,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
            FilledButton(
              key: const ValueKey('session-delete-confirm'),
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: current && reason == null && scope?.readOnly == false
                  ? () => Navigator.pop(dialog, owner.isCurrent(ref))
                  : null,
              child: Text(context.l10n.shellDeletePermanently),
            ),
          ],
        );
      },
    ),
  );
  if (!context.mounted || confirmed != true || !owner.isCurrent(ref)) return;
  // Do not reinterpret an old selection as a newly created selection with the
  // same IDs while the confirmation was open.
  if (selection != null && !identical(ref.read(drawerSelectionProvider), selection)) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        key: const ValueKey('session-delete-progress'),
        content: Row(
          children: [
            const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(child: Text(context.l10n.shellDeletingChats)),
          ],
        ),
      ),
    ),
  );
  unawaited(navigator.push(progress));
  List<String> deleted;
  Map<String, String> failures;
  try {
    final result = await ref.read(sessionDeletionProvider.notifier).delete(ids, owner: owner);
    if (!context.mounted || result.retired || !owner.isCurrent(ref)) return;
    deleted = result.deleted;
    failures = result.failures;
  } catch (_) {
    if (!context.mounted || !owner.isCurrent(ref)) return;
    deleted = const [];
    failures = {for (final id in ids) id: 'failed'};
  } finally {
    // Remove only our own route, never a host switcher's or another dialog.
    if (navigator.mounted && progress.isActive) navigator.removeRoute(progress);
  }
  if (!context.mounted || !owner.isCurrent(ref)) return;
  if (selection != null) {
    if (!identical(ref.read(drawerSelectionProvider), selection)) return;
    final notifier = ref.read(drawerSelectionProvider.notifier);
    if (failures.isEmpty) {
      notifier.end();
    } else {
      // Successful rows disappear only after server acknowledgement. Failed
      // rows stay selected so they can be inspected or explicitly retried.
      notifier.setAll(failures.keys);
    }
    if (!context.mounted || !owner.isCurrent(ref)) return;
    final current = ref.read(drawerSelectionProvider);
    final selectionChanged = failures.isEmpty
        ? current != null
        : current == null || current.length != failures.length || !current.containsAll(failures.keys);
    if (selectionChanged) return;
  }
  if (failures.isEmpty) {
    _showDeletionReceipt(context, deleted.length);
    return;
  }
  await showAppDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const ValueKey('session-delete-failures'),
      title: Text(context.l10n.shellDeletePartial(deleted.length, failures.length)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in failures.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${titles[entry.key] ?? entry.key}\n${entry.key}\n${sessionDeletionFailureText(context, entry.value)} (${entry.value})',
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.l10n.commonDone))],
    ),
  );
}

// This receipt belongs at the top: a bottom snackbar covers the composer
// as soon as the person closes the drawer to continue chatting.
void _showDeletionReceipt(BuildContext context, int count) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearMaterialBanners()
    ..removeCurrentMaterialBanner();
  var current = true;
  late final ScaffoldFeatureController<MaterialBanner, MaterialBannerClosedReason> receipt;
  void close() {
    if (current && messenger.mounted) receipt.close();
  }

  receipt = messenger.showMaterialBanner(
    MaterialBanner(
      content: _DeletionReceiptText(text: context.l10n.shellChatsDeleted(count), onTimeout: close),
      actions: [TextButton(onPressed: close, child: Text(context.l10n.commonClose))],
    ),
  );
  unawaited(receipt.closed.then((_) => current = false));
}

class _DeletionReceiptText extends StatefulWidget {
  const _DeletionReceiptText({required this.text, required this.onTimeout});

  final String text;
  final VoidCallback onTimeout;

  @override
  State<_DeletionReceiptText> createState() => _DeletionReceiptTextState();
}

class _DeletionReceiptTextState extends State<_DeletionReceiptText> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), widget.onTimeout);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.text);
}

String sessionDeletionFailureText(BuildContext context, String code) => switch (code) {
  'session-active' => context.l10n.shellDeleteRunning,
  'session-related' => context.l10n.shellDeleteRelated,
  'writer-held' => context.l10n.shellDeleteWriterHeld,
  'not-found' => context.l10n.shellDeleteNotFound,
  'unavailable' => context.l10n.shellDeleteUnavailable,
  'connection-lost' => context.l10n.shellDeleteConnectionLost,
  'busy' => context.l10n.shellDeletingChats,
  'archive-pending' => context.l10n.shellDeleteArchivePending,
  'inventory-changed' => context.l10n.shellDeleteInventoryChanged,
  'protocol-error' => context.l10n.shellDeleteProtocolError,
  'not-attempted' => context.l10n.shellDeleteNotAttempted,
  _ => context.l10n.shellDeleteFailed,
};
