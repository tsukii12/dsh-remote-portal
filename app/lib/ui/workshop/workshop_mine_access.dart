// What stands between a person and the pages that act as their GitHub account
// (我的投稿, 举报): signing in with GitHub, the workshop's own checks, and
// agreeing that the workshop is handed the GitHub token.
//
// Signing in is the sign-in sheet's (workshop_sign_in.dart). The agreement is asked
// here because both pages need it and neither can send the person to the
// other; what is confirmed is the very object the sheet showed
// (workshopAccessProvider, contract §6).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_auth_state.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../theme/app_icons.dart';
import 'workshop_disclosure.dart';
import 'workshop_sign_in.dart';
import 'workshop_text.dart';

/// Where the person is on the way to acting as their GitHub account.
enum WorkshopAuthorGate {
  /// The stored token or the workshop's checks are still being read.
  checking,

  /// Not signed in.
  signIn,

  /// The workshop's checks failed (unreachable, another account system, …).
  failed,

  /// Signed in, but hasn't agreed to hand the credential to the workshop.
  consent,
  open,
}

WorkshopAuthorGate workshopAuthorGate(WorkshopAccessState access) {
  if (access.accountRestoring) return WorkshopAuthorGate.checking;
  if (!access.signedIn) return WorkshopAuthorGate.signIn;
  if (access.loading) return WorkshopAuthorGate.checking;
  if (access.error != null || access.capabilities == null) return WorkshopAuthorGate.failed;
  return access.disclosureAccepted ? WorkshopAuthorGate.open : WorkshopAuthorGate.consent;
}

/// The gate as a designed state: one glyph, one line, at most one button
/// (登录 / 重试 / 查看说明). While checking, and once open, a quiet ring.
class WorkshopAuthorGateView extends ConsumerWidget {
  const WorkshopAuthorGateView({
    super.key,
    required this.signInTitle,
    required this.signInMessage,
    required this.consentMessage,
    this.compact = false,
  });

  /// Why this page wants a signed-in account.
  final String signInTitle;
  final String signInMessage;

  /// What agreeing lets the person do here.
  final String consentMessage;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final access = ref.watch(workshopAccessProvider);
    switch (workshopAuthorGate(access)) {
      case WorkshopAuthorGate.checking || WorkshopAuthorGate.open:
        return const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)));
      case WorkshopAuthorGate.signIn:
        return EmptyView(
          icon: AppIcons.profile,
          title: signInTitle,
          message: signInMessage,
          compact: compact,
          actionLabel: l10n.workshopSignInTitle,
          onAction: () => unawaited(showWorkshopSignInSheet(context)),
        );
      case WorkshopAuthorGate.failed:
        final code = access.error?.code;
        final unconfigured = code == 'workshop_unconfigured';
        return EmptyView(
          icon: unconfigured ? AppIcons.workshop : AppIcons.offline,
          title: unconfigured ? l10n.workshopNotOpenTitle : l10n.workshopUnavailableTitle,
          message: unconfigured ? l10n.workshopNotOpenMessage : workshopErrorLine(l10n, code ?? ''),
          compact: compact,
          actionLabel: unconfigured ? null : l10n.commonRetry,
          onAction: unconfigured ? null : () => unawaited(ref.read(workshopAccessProvider.notifier).refresh()),
        );
      case WorkshopAuthorGate.consent:
        return EmptyView(
          icon: AppIcons.verified,
          title: l10n.workshopMineConsentTitle,
          message: consentMessage,
          compact: compact,
          actionLabel: l10n.workshopMineConsentAction,
          onAction: () => unawaited(confirmWorkshopDisclosure(context, ref)),
        );
    }
  }
}

/// Shows which workshop receives the GitHub token and which account system it
/// is checked with, and records the answer. The object confirmed is the one the
/// sheet showed; if the account or the workshop changed meanwhile, the state
/// layer refuses it and the gate says so.
Future<void> confirmWorkshopDisclosure(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final offered = ref.read(workshopAccessProvider).disclosure;
  if (offered == null) {
    showBriefNotice(context, l10n.workshopErrorBusy);
    return;
  }
  final agreed = await showWorkshopDisclosureSheet(context, offered);
  if (agreed == null || !context.mounted) return;
  await ref.read(workshopAccessProvider.notifier).confirmDisclosure(agreed);
  if (!context.mounted) return;
  // Agreed for now, but not written down: say so instead of promising that
  // the question won't come back.
  final access = ref.read(workshopAccessProvider);
  if (access.disclosureAccepted && access.preferenceError != null) {
    showBriefNotice(context, l10n.workshopDisclosureUnsaved);
  }
}
