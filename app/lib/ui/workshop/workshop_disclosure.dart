// 凭据说明: what leaves the phone when the person acts as their GitHub account
// (投稿, 我的投稿, 举报), shown before anything is sent
// (docs/design/workshop-app.md「投稿与凭据」).
//
// The workshop checks who is asking by receiving the GitHub token (no scopes:
// public profile only) and asking GitHub whose it is. The two
// addresses on screen are the ones in the offer the state layer made; the
// very same offer object goes back with 「同意并继续」, so a consent can never
// land on an address the person did not see.
//
// One view, two places: the publish page shows it as a step of its own, the
// other pages raise it as a sheet ([showWorkshopDisclosureSheet]).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_auth_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// The disclosure as a sheet. Completes with the offer the person agreed to
/// (the object that was on screen), or null when they did not.
Future<WorkshopDisclosure?> showWorkshopDisclosureSheet(BuildContext context, WorkshopDisclosure offer) {
  return showAppSheet<WorkshopDisclosure>(
    context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: WorkshopDisclosureView(
          offer: offer,
          onAccept: (offer) => Navigator.of(context).pop(offer),
          onDecline: () => Navigator.of(context).pop(),
        ),
      ),
    ),
  );
}

class WorkshopDisclosureView extends StatelessWidget {
  const WorkshopDisclosureView({
    super.key,
    required this.offer,
    required this.onAccept,
    required this.onDecline,
    this.stale = false,
  });

  /// The offer on screen. [onAccept] gets this object back, not a copy.
  final WorkshopDisclosure offer;
  final ValueChanged<WorkshopDisclosure> onAccept;
  final VoidCallback onDecline;

  /// The last 「同意」 was for an offer that had been replaced: say so, and
  /// show the current one.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final body = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 48,
                child: GlassSurface(
                  tier: GlassTier.card,
                  circle: true,
                  child: Center(child: Icon(AppIcons.apiKey, size: 22, color: theme.colorScheme.onSurfaceVariant)),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(l10n.workshopDisclosureTitle, style: theme.textTheme.titleLarge),
              ),
              const SizedBox(height: 8),
              Text(l10n.workshopDisclosureLead, style: body),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (stale)
          WorkshopNote(l10n.workshopDisclosureStale, tone: WorkshopNoteTone.warning),
        ListPageCard(
          children: [
            _Party(label: l10n.workshopDisclosureWorker, host: workshopHostText(offer.worker)),
            _Party(label: l10n.workshopDisclosureAccount, host: workshopHostText(offer.account)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.workshopDisclosureUse, style: body),
              const SizedBox(height: 8),
              Text(
                l10n.workshopDisclosureKept,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => onAccept(offer),
                child: Text(l10n.workshopDisclosureAccept),
              ),
              const SizedBox(height: 4),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                onPressed: onDecline,
                child: Text(l10n.workshopDisclosureDecline),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One side of the hand-over: what it does, and its address in full under
/// it (an address is never cut to fit a row's end).
class _Party extends StatelessWidget {
  const _Party({required this.label, required this.host});

  final String label;
  final String host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 10, ListPageRow.horizontal, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary)),
          const SizedBox(height: 2),
          Text(host, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4)),
        ],
      ),
    );
  }
}
