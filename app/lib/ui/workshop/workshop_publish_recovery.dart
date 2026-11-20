// 「放下这条记录」: the way out when the phone's record of an unfinished
// submission cannot be used (it is damaged, its package is gone, or clearing
// it keeps failing), so the page is not left offering 重试 forever.
//
// Letting go removes the record on this phone and nothing else. The workshop
// is not asked to cancel anything, and the dialog says so before the person
// agrees: a submission that did arrive stays there, and one sent again may
// then exist twice. The state layer reads the record first and hands out an
// offer; the page asks about that offer and returns the very same object.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_preferences.dart';
import '../../state/workshop_publish_state.dart';
import '../common/app_dialog.dart';
import '../theme/theme.dart';
import 'workshop_publish_text.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// The quiet text action, with what went wrong the last time it was tried
/// said above it. Drawn only while the state layer allows asking; [beside]
/// (the step's other text actions) is drawn either way, before it.
class WorkshopPublishLetGo extends StatefulWidget {
  const WorkshopPublishLetGo({
    super.key,
    required this.publish,
    required this.onLetGo,
    this.beside = const [],
    this.centered = false,
  });

  final WorkshopPublishState publish;
  final VoidCallback onLetGo;
  final List<Widget> beside;

  /// Under a centred statement instead of in a left-aligned column.
  final bool centered;

  @override
  State<WorkshopPublishLetGo> createState() => _WorkshopPublishLetGoState();
}

class _WorkshopPublishLetGoState extends State<WorkshopPublishLetGo> {
  /// Whether the action was on offer the last time nothing was running.
  /// While the record is being read or removed the state layer says "not
  /// now"; the action then stays where it was, switched off, so the page
  /// does not jump.
  bool _offered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final publish = widget.publish;
    if (!publish.working) _offered = publish.canRequestPendingAbandonment;
    final error = publish.recoveryError;
    final actions = [
      ...widget.beside,
      if (_offered)
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
          onPressed: publish.canRequestPendingAbandonment ? widget.onLetGo : null,
          child: Text(l10n.workshopPublishLetGo),
        ),
    ];
    if (actions.isEmpty && error == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null)
          WorkshopNote(
            workshopRecoveryErrorText(l10n, error),
            tone: WorkshopNoteTone.warning,
            padding: const EdgeInsets.fromLTRB(24, 8, 16, 0),
          ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Wrap(
              alignment: widget.centered ? WrapAlignment.center : WrapAlignment.start,
              spacing: 4,
              children: actions,
            ),
          ),
      ],
    );
  }
}

/// Asks before the phone's record is let go, saying what [offer] covers and
/// what the workshop will and will not know. True only for 「放下记录」.
/// [resultKnown]: the workshop's answer is already on screen, so nothing has
/// to be sent again.
Future<bool> showWorkshopLetGoDialog(
  BuildContext context,
  WorkshopPendingAbandonOffer offer, {
  required bool resultKnown,
}) async {
  final l10n = context.l10n;
  final colors = DshColors.of(context);
  final worker = workshopHostText(offer.worker);
  final scope = switch (offer.range) {
    WorkshopPendingAbandonRange.currentAccount => l10n.workshopPublishLetGoAccount(worker),
    // The whole container is unreadable: every account's record goes.
    WorkshopPendingAbandonRange.allLocalAccounts => l10n.workshopPublishLetGoAll(worker),
  };
  final facts = resultKnown ? l10n.workshopPublishLetGoFactsKnown : l10n.workshopPublishLetGoFacts;
  final go = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.workshopPublishLetGoTitle),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [Text(scope), const SizedBox(height: 12), Text(facts)],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.workshopPublishLetGoConfirm),
        ),
      ],
    ),
  );
  return go ?? false;
}
