// One submission: its status in words, what the reviewer or the author said,
// and the two things its author can do: read it again, and withdraw it.
//
// The sheet follows the submission by id in workshopSubmissionsProvider (the
// last single read, else its row, else what the list showed when it opened),
// and only while the account is the one it was opened under.
//
// Withdrawing asks for a reason, then confirms, then calls the controller.
// When the answer is lost on the way the result is unknown: the sheet says
// so and offers 查询结果, a read of the same submission. Withdrawing again is
// only offered after such a read found it not withdrawn (contract §9.1).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_catalog_state.dart';
import '../../state/workshop_submissions_state.dart';
import '../../workshop/workshop_models.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../common/status_chip.dart';
import '../plugins/plugin_detail_sheet.dart' show PluginHero;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_mine_reason_field.dart';
import 'workshop_mine_text.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// Opens [submission]'s detail. [session] is the submissions state's session
/// the row was read under.
Future<void> showWorkshopSubmissionSheet(
  BuildContext context,
  WorkshopSubmission submission, {
  required Object session,
}) {
  return showAppSheet<void>(
    context,
    heightFactor: 0.82,
    builder: (_) => WorkshopSubmissionSheet(opened: submission, session: session),
  );
}

class WorkshopSubmissionSheet extends ConsumerStatefulWidget {
  const WorkshopSubmissionSheet({super.key, required this.opened, required this.session});

  /// What the list showed when the sheet opened.
  final WorkshopSubmission opened;

  /// The account and workshop [opened] belongs to.
  final Object session;

  @override
  ConsumerState<WorkshopSubmissionSheet> createState() => _WorkshopSubmissionSheetState();
}

class _WorkshopSubmissionSheetState extends ConsumerState<WorkshopSubmissionSheet> {
  final _reason = TextEditingController();
  final _scroll = ScrollController();

  /// The reason field is up (at the end of the sheet's content).
  bool _asking = false;
  String? _reasonError;

  /// This sheet sent a withdrawal: a refusal shown here is about that try,
  /// not one left over from an earlier visit.
  bool _tried = false;

  /// After an unknown withdrawal, a read found the submission not withdrawn:
  /// withdrawing again is no longer a blind repeat.
  bool _stillThere = false;

  String get _id => widget.opened.id;

  @override
  void dispose() {
    _reason.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Brings up the reason field and scrolls down to it.
  void _ask() {
    setState(() => _asking = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      final duration = AppMotion.of(context, AppMotion.standard);
      if (duration == Duration.zero) {
        _scroll.jumpTo(end);
      } else {
        unawaited(_scroll.animateTo(end, duration: duration, curve: AppMotion.std));
      }
    });
  }

  WorkshopSubmission _current(WorkshopSubmissionsState subs) {
    if (subs.detailId == _id && subs.detail != null) return subs.detail!;
    for (final row in subs.items) {
      if (row.id == _id) return row;
    }
    return widget.opened;
  }

  /// 刷新这一条 and 查询结果: one read of this submission.
  Future<void> _reread() async {
    final accepted = await ref.read(workshopSubmissionsProvider.notifier).refreshSubmission(_id);
    if (!mounted) return;
    if (!accepted) {
      showBriefNotice(context, context.l10n.workshopErrorBusy);
      return;
    }
    final now = ref.read(workshopSubmissionsProvider);
    // Only this account's fresh answer about this submission counts.
    if (!identical(now.session, widget.session) || now.detailId != _id || now.detailError != null) return;
    final withdrawal = now.withdrawal;
    if (withdrawal.submissionId == _id &&
        withdrawal.phase == WorkshopWithdrawalPhase.unknown &&
        now.detail?.status != WorkshopSubmissionStatus.withdrawn) {
      setState(() => _stillThere = true);
    }
  }

  Future<void> _withdraw(WorkshopSubmission submission) async {
    final l10n = context.l10n;
    final reason = _reason.text;
    final problem = workshopReasonProblem(l10n, reason);
    if (problem != null) {
      setState(() => _reasonError = problem);
      return;
    }
    final title = workshopTitleOf(submission.metadata, Localizations.localeOf(context).languageCode);
    final colors = DshColors.of(context);
    final go = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.workshopMineWithdrawConfirmTitle),
        content: Text(l10n.workshopMineWithdrawConfirmMessage(title)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.workshopMineWithdrawConfirm),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final accepted = await ref.read(workshopSubmissionsProvider.notifier).withdraw(_id, reason);
    if (!mounted) return;
    if (!accepted) {
      showBriefNotice(context, l10n.workshopErrorBusy);
      return;
    }
    _tried = true;
    // Admitted is not withdrawn: read what this account's state says about
    // this submission now.
    final now = ref.read(workshopSubmissionsProvider);
    final withdrawal = now.withdrawal;
    if (!identical(now.session, widget.session) || withdrawal.submissionId != _id) return;
    switch (withdrawal.phase) {
      case WorkshopWithdrawalPhase.succeeded:
        setState(() {
          _asking = false;
          _stillThere = false;
          _reason.clear();
        });
        showBriefNotice(context, l10n.workshopMineWithdrawDone);
        // A public release just left the catalogue: let 发现 read it again.
        if (submission.status == WorkshopSubmissionStatus.approved && ref.exists(workshopCatalogProvider)) {
          unawaited(ref.read(workshopCatalogProvider.notifier).refresh());
        }
      case WorkshopWithdrawalPhase.unknown:
        // Back to 查询结果; the reason stays for a later, informed try.
        setState(() {
          _asking = false;
          _stillThere = false;
        });
      case WorkshopWithdrawalPhase.failed when withdrawal.error?.code == 'workshop_bad_reason':
        setState(() => _reasonError = l10n.workshopMineReasonRejected);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final subs = ref.watch(workshopSubmissionsProvider);

    // Another account now: this submission is not theirs to see.
    if (!identical(subs.session, widget.session)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.workshopMineDetailTitle),
          const SizedBox(height: 40),
          EmptyView(
            icon: AppIcons.account,
            title: l10n.workshopMineAccountChanged,
            message: l10n.workshopMineAccountChangedMessage,
          ),
        ],
      );
    }

    final submission = _current(subs);
    final meta = submission.metadata;
    final status = submission.status;
    final withdrawn = status == WorkshopSubmissionStatus.withdrawn;
    final rereading = subs.operation == WorkshopSubmissionsOperation.detail && subs.operationSubmissionId == _id;
    final withdrawal = subs.withdrawal.submissionId == _id ? subs.withdrawal : const WorkshopWithdrawalState();
    final sending = withdrawal.phase == WorkshopWithdrawalPhase.sending;
    final unknown = withdrawal.phase == WorkshopWithdrawalPhase.unknown && !withdrawn;
    final failure =
        _tried && withdrawal.phase == WorkshopWithdrawalPhase.failed && withdrawal.error?.code != 'workshop_bad_reason'
        ? withdrawal.error
        : null;
    final rereadFailure = subs.detailId == _id ? subs.detailError : null;
    // The reason is only asked for while withdrawing is on offer.
    final asking = _asking && !withdrawn && (!unknown || _stillThere);
    const notePadding = EdgeInsets.only(bottom: 12);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          l10n.workshopMineDetailTitle,
          actions: [
            if (rereading)
              const SizedBox.square(
                dimension: SheetHeader.buttonSize,
                child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else
              IconButton(
                tooltip: l10n.workshopMineRefreshOne,
                icon: Icon(AppIcons.refresh, size: 20, color: colors.textTertiary),
                onPressed: subs.busy ? null : () => unawaited(_reread()),
              ),
          ],
        ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            children: [
              PluginHero(
                avatar: WorkshopAvatar(meta, size: 64),
                title: workshopTitleOf(meta, Localizations.localeOf(context).languageCode),
                subtitle: '${workshopKindText(l10n, meta.kind)} · ${meta.version}',
                badges: [StatusChip(tone: workshopStatusTone(status), label: workshopStatusLabel(l10n, status))],
              ),
              const SizedBox(height: 16),
              Text(
                workshopStatusAbout(l10n, status),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
              ),
              if (submission.reviewReason case final reason?) _Said(label: l10n.workshopMineReviewReason, text: reason),
              if (submission.withdrawalReason case final reason?)
                _Said(label: l10n.workshopMineWithdrawReason, text: reason),
              const SizedBox(height: 16),
              ListPageCard(
                margin: EdgeInsets.zero,
                children: [
                  ListPageRow(title: l10n.workshopMineCreatedAt, value: workshopStamp(submission.createdAt)),
                  ListPageRow(title: l10n.workshopMineUpdatedAt, value: workshopStamp(submission.updatedAt)),
                ],
              ),
              const SizedBox(height: 16),
              if (rereadFailure != null)
                WorkshopNote(
                  '${l10n.workshopMineDetailStale} ${workshopErrorLine(l10n, rereadFailure.code)}',
                  padding: notePadding,
                ),
              if (unknown)
                WorkshopNote(
                  _stillThere ? l10n.workshopMineWithdrawStill : l10n.workshopMineWithdrawUnknown,
                  tone: WorkshopNoteTone.warning,
                  padding: notePadding,
                ),
              if (withdrawal.reconciled && withdrawn)
                WorkshopNote(l10n.workshopMineWithdrawReconciled, padding: notePadding),
              if (failure != null)
                WorkshopNote(workshopExceptionText(l10n, failure), tone: WorkshopNoteTone.danger, padding: notePadding),
              if (asking)
                WorkshopReasonField(
                  controller: _reason,
                  label: l10n.workshopMineWithdrawReason,
                  hint: l10n.workshopMineWithdrawReasonHint,
                  error: _reasonError,
                  enabled: !sending,
                  autofocus: true,
                  onChanged: (_) {
                    if (_reasonError != null) setState(() => _reasonError = null);
                  },
                ),
            ],
          ),
        ),
        if (!withdrawn)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + MediaQuery.viewInsetsOf(context).bottom),
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.quick),
                child: sending
                    ? _Sending(key: const ValueKey('sending'), label: l10n.workshopMineWithdrawing)
                    : unknown && !_stillThere
                    // The result is unknown: the one thing on offer is to look.
                    ? FilledButton(
                        key: const ValueKey('query'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: subs.busy ? null : () => unawaited(_reread()),
                        child: Text(l10n.workshopMineWithdrawQuery),
                      )
                    : asking
                    ? Row(
                        key: const ValueKey('reason'),
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                              onPressed: () => setState(() {
                                _asking = false;
                                _reasonError = null;
                              }),
                              child: Text(l10n.commonCancel),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                              onPressed: subs.busy ? null : () => unawaited(_withdraw(submission)),
                              child: Text(l10n.commonContinue),
                            ),
                          ),
                        ],
                      )
                    : OutlinedButton(
                        key: const ValueKey('withdraw'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          foregroundColor: colors.danger,
                        ),
                        onPressed: _ask,
                        child: Text(l10n.workshopMineWithdraw),
                      ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What someone wrote about the submission: a small label over their words.
class _Said extends StatelessWidget {
  const _Said({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
          ),
        ],
      ),
    );
  }
}

/// The bottom of the sheet while the withdrawal is on its way.
class _Sending extends StatelessWidget {
  const _Sending({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Flexible(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    ),
  );
}
