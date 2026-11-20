// 举报: tell the reviewers what is wrong with one release.
//
// A report is sent as the GitHub account, so the sheet first asks for the
// sign-in and the credential agreement (workshop_mine_access.dart). It has no
// request id and can't be looked up afterwards: when the answer is lost on
// the way, nobody can tell whether it arrived. The sheet then says exactly
// that, and writing another one starts only from a button that names the
// risk; the controller is handed the very attempt that was on screen
// (workshopReportProvider, contract §10).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_auth_state.dart';
import '../../state/workshop_report_state.dart';
import '../../workshop/workshop_models.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_mine_access.dart';
import 'workshop_mine_reason_field.dart';
import 'workshop_mine_text.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// Opens the report form for [entry] (the release the detail sheet shows).
Future<void> showWorkshopReportSheet(BuildContext context, WorkshopEntry entry) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    // Typed text is not lost to a stray drag.
    dismissal: SheetDismissal.button,
    builder: (_) => WorkshopReportSheet(entry: entry),
  );
}

class WorkshopReportSheet extends ConsumerStatefulWidget {
  const WorkshopReportSheet({super.key, required this.entry});

  final WorkshopEntry entry;

  @override
  ConsumerState<WorkshopReportSheet> createState() => _WorkshopReportSheetState();
}

class _WorkshopReportSheetState extends ConsumerState<WorkshopReportSheet> {
  final _reason = TextEditingController();

  /// What is wrong with the typed reason, found before sending.
  String? _reasonError;

  /// The text changed since the last refusal: that refusal is about other
  /// words now.
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    // An earlier report that ended (received, or refused) is over: this
    // sheet starts a new one. An unknown one is not cleared this way.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final phase = ref.read(workshopReportProvider).phase;
      if (phase == WorkshopReportPhase.succeeded || phase == WorkshopReportPhase.failed) {
        ref.read(workshopReportProvider.notifier).beginNewOperation();
      }
    });
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// Whether [attempt] is about the release this sheet reports.
  bool _mine(WorkshopReportAttempt? attempt) {
    final meta = widget.entry.metadata;
    return attempt != null && attempt.kind == meta.kind && attempt.id == meta.id && attempt.version == meta.version;
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    final problem = workshopReasonProblem(l10n, _reason.text);
    if (problem != null) {
      setState(() => _reasonError = problem);
      return;
    }
    setState(() => _edited = false);
    final notifier = ref.read(workshopReportProvider.notifier);
    // A report about something else that ended while this sheet was up is
    // over: this one starts anew. An unknown one is never cleared this way.
    final last = ref.read(workshopReportProvider);
    if (!_mine(last.attempt) &&
        (last.phase == WorkshopReportPhase.succeeded || last.phase == WorkshopReportPhase.failed)) {
      notifier.beginNewOperation();
    }
    // The outcome is read from the state (see [_onChanged]); the bool only
    // says whether this try was taken.
    final accepted = await notifier.submit(widget.entry, _reason.text);
    if (mounted && !accepted) showBriefNotice(context, l10n.workshopErrorBusy);
  }

  /// The person read that the last report may have arrived and chose to write
  /// another: [shown] is the attempt the warning was about.
  void _writeAgain(WorkshopReportAttempt shown) {
    final accepted = ref.read(workshopReportProvider.notifier).beginNewOperation(confirmedUnknown: shown);
    if (!accepted) {
      showBriefNotice(context, context.l10n.workshopErrorBusy);
      return;
    }
    // Nothing is sent yet: the form comes back, with what was written.
    if (_mine(shown) && _reason.text.isEmpty) _reason.text = shown.reason;
  }

  void _onChanged(WorkshopReportState? before, WorkshopReportState now) {
    if (before?.phase != WorkshopReportPhase.sending || !identical(before?.session, now.session)) return;
    if (now.phase != WorkshopReportPhase.succeeded || !_mine(now.attempt)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final done = context.l10n.workshopReportDone;
    Navigator.of(context).pop();
    messenger?.showBriefNotice(done);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    ref.listen(workshopReportProvider, _onChanged);
    final gate = workshopAuthorGate(ref.watch(workshopAccessProvider));
    final report = ref.watch(workshopReportProvider);
    final meta = widget.entry.metadata;
    final title = workshopTitleOf(meta, Localizations.localeOf(context).languageCode);
    final mine = _mine(report.attempt);
    final failure = report.phase == WorkshopReportPhase.failed && mine && !_edited ? report.error : null;
    final refused = failure?.code == 'workshop_bad_reason';

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(l10n.workshopReport),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                child: Text(
                  l10n.workshopReportTarget(title, meta.version),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                ),
              ),
              if (gate != WorkshopAuthorGate.open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 28, 0, 28),
                  child: WorkshopAuthorGateView(
                    compact: true,
                    signInTitle: l10n.workshopReportSignInTitle,
                    signInMessage: l10n.workshopReportSignInMessage,
                    consentMessage: l10n.workshopReportConsentMessage,
                  ),
                )
              else if (report.attempt case final shown? when report.phase == WorkshopReportPhase.unknown)
                Padding(
                  padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(AppIcons.warning, size: 18, color: colors.warning),
                          const SizedBox(width: 8),
                          Expanded(child: Text(l10n.workshopReportUnknownTitle, style: theme.textTheme.titleSmall)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        [
                          l10n.workshopReportUnknownMessage,
                          if (!mine) l10n.workshopReportUnknownOther(shown.id, shown.version),
                        ].join(' '),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 20),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: () => _writeAgain(shown),
                        child: Text(l10n.workshopReportUnknownAgain, textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      WorkshopReasonField(
                        controller: _reason,
                        label: l10n.workshopReportReason,
                        hint: l10n.workshopReportReasonHint,
                        error: _reasonError ?? (refused ? l10n.workshopMineReasonRejected : null),
                        enabled: !report.busy,
                        onChanged: (_) {
                          if (_reasonError != null || !_edited) {
                            setState(() {
                              _reasonError = null;
                              _edited = true;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.workshopReportNote,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
                      ),
                      const SizedBox(height: 16),
                      if (failure != null && !refused)
                        WorkshopNote(
                          workshopExceptionText(l10n, failure),
                          tone: WorkshopNoteTone.danger,
                          padding: const EdgeInsets.only(bottom: 10),
                        ),
                      FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: report.busy ? null : () => unawaited(_submit()),
                        child: AnimatedSwitcher(
                          duration: AppMotion.of(context, AppMotion.quick),
                          child: Text(
                            report.busy ? l10n.workshopReportSending : l10n.workshopReportSubmit,
                            key: ValueKey(report.busy),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
