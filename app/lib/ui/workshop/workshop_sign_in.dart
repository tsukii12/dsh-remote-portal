// 用 GitHub 登录: the workshop's own sign-in (workshopAccountProvider).
//
// GitHub's device flow: the sheet asks for a code as it opens, shows it large
// enough to read off, and one button copies it and opens GitHub's page for it.
// The sheet then just waits and closes itself once the account is in; closing
// it earlier stops waiting (the code expires unused on GitHub).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/account_state.dart' show accountBrowserProvider;
import '../../state/workshop_account_state.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../theme/theme.dart';

Future<void> showWorkshopSignInSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (context) => const _SignInSheet());

class _SignInSheet extends ConsumerStatefulWidget {
  const _SignInSheet();
  @override
  ConsumerState<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends ConsumerState<_SignInSheet> {
  late final _account = ref.read(workshopAccountProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Providers may not change while widgets build or are torn down, so both
    // the start here and the cancel below run just after.
    scheduleMicrotask(() => unawaited(_account.startSignIn()));
  }

  @override
  void dispose() {
    scheduleMicrotask(_account.cancelSignIn);
    super.dispose();
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showBriefNotice(context, context.l10n.workshopSignInCopied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final account = ref.watch(workshopAccountProvider);
    ref.listen(workshopAccountProvider.select((value) => value.phase), (_, phase) {
      if (phase == WorkshopAccountPhase.signedIn) Navigator.of(context).maybePop();
    });
    final code = account.userCode, uri = account.verificationUri;
    final error = account.error;

    Widget quiet(String text) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Flexible(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary))),
      ],
    );

    final List<Widget> body;
    if (account.phase == WorkshopAccountPhase.awaitingCode && code != null && uri != null) {
      body = [
        Material(
          color: DshSurfaces.of(context).card.fill,
          shape: RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(_copy(code)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  code,
                  style: AppType.mono(size: 28, weight: FontWeight.w600, height: 1.2, color: theme.colorScheme.onSurface)
                      .copyWith(letterSpacing: 4),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.workshopSignInSteps,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () async {
            await _copy(code);
            if (!mounted) return;
            await ref.read(accountBrowserProvider).open(uri);
          },
          child: Text(l10n.workshopSignInOpen),
        ),
        const SizedBox(height: 16),
        quiet(l10n.workshopSignInWaiting),
      ];
    } else if (error != null) {
      body = [
        Text(
          switch (error) {
            WorkshopAccountError.expired => l10n.workshopSignInExpired,
            WorkshopAccountError.denied => l10n.workshopSignInDenied,
            WorkshopAccountError.network => l10n.workshopSignInNetwork,
            WorkshopAccountError.unconfigured => l10n.workshopSignInUnconfigured,
          },
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger),
        ),
        // A deployment without a GitHub app won't have one on a second try.
        if (error != WorkshopAccountError.unconfigured) ...[
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => unawaited(_account.startSignIn()),
            child: Text(l10n.workshopSignInAgain),
          ),
        ],
      ];
    } else {
      body = [Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: quiet(l10n.workshopSignInPreparing))];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHeader(l10n.workshopSignInTitle),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 20),
          child: Text(l10n.workshopSignInLead, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
