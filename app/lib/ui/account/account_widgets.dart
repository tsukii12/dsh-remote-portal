import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/account_state.dart';
import '../common/display_image.dart';
import '../common/overview_card.dart' show OverviewChevron;
import '../common/progress_halo.dart';
import '../common/status_dot.dart';
import '../settings/settings_widgets.dart' show SettingsIcon, SettingsMetrics, settingsTitleStyle;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'account_page.dart';
import '../common/smooth_size.dart';
import '../onboarding/onboarding_scaffold.dart';
import '../common/brief_notice.dart';

/// Opens a Platform page (top-up, usage) the same way sign-in does.
Future<void> openAccountLink(BuildContext context, WidgetRef ref, String url) async {
  final l10n = context.l10n;
  final uri = Uri.tryParse(url);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened = uri != null && await ref.read(accountBrowserProvider).open(uri);
  if (!opened) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.engineAccountBrowserFailed)));
  }
}

/// Round profile picture; falls back to the name's first character, or a
/// person glyph when only a masked phone/email is known.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, this.profile, this.size = 56});

  final AccountProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final key = profile?.id ?? profile?.contact ?? profile?.name ?? '';
    final slot = key.isEmpty ? 0 : DshColors.identityIndex(key);
    final bg = colors.identity[slot];
    final fg = colors.onIdentity[slot];
    final name = profile?.name?.trim() ?? '';
    final fallback = DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: const CircleBorder()),
      child: Center(
        child: name.isNotEmpty
            ? Text(
                String.fromCharCodes(name.runes.take(1)),
                style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600, color: fg, height: 1),
              )
            : Icon(AppIcons.avatar, size: size * 0.52, color: fg),
      ),
    );
    final url = profile?.avatarUrl;
    return SizedBox.square(
      dimension: size,
      child: url == null
          ? fallback
          : ClipOval(
              child: Image(
                image: imageForDisplay(
                  NetworkImage(url),
                  width: size,
                  height: size,
                  pixelRatio: MediaQuery.devicePixelRatioOf(context),
                ),
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
                loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
              ),
            ),
    );
  }
}

/// Halo, title and one calm sentence for a running (or just finished) sign-in.
class SignInStatus extends StatelessWidget {
  const SignInStatus({super.key, required this.state, this.succeeded = false, this.haloSize = 132});

  final AccountState state;

  /// Show the brief "登录成功" beat before the caller moves on.
  final bool succeeded;
  final double haloSize;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final stage = succeeded ? null : (state.stage ?? SignInStage.preparing);
    final (IconData icon, String title, String body) = switch (stage) {
      null => (
        AppIcons.done,
        l10n.engineAccountSignInSuccess,
        state.profile == null ? l10n.engineAccountAlmostReady : l10n.engineAccountWelcome(state.profile!.displayName),
      ),
      SignInStage.preparing when !state.connected => (
        AppIcons.engineStarting,
        l10n.engineAccountStartingEngine,
        l10n.engineAccountOpenSignInNext,
      ),
      SignInStage.preparing => (AppIcons.link, l10n.engineAccountPreparingSignIn, l10n.engineAccountOpenDeepSeekNext),
      SignInStage.waitingBrowser => (
        AppIcons.browser,
        l10n.engineAccountFinishInBrowser,
        l10n.engineAccountReturnToDsh,
      ),
      SignInStage.finishing => (AppIcons.verified, l10n.engineAccountFinishingSignIn, l10n.engineAccountSavingSignIn),
    };
    final hint = switch (state.browserHint) {
      _ when stage != SignInStage.waitingBrowser => null,
      BrowserHint.returned => l10n.engineAccountAwaitingResult,
      BrowserHint.notOpened => l10n.engineAccountBrowserFailed,
      BrowserHint.none => null,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProgressHalo(
          value: succeeded ? 1 : null,
          size: haloSize,
          strokeWidth: 3.5,
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.emphasized),
            switchInCurve: AppMotion.enter,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(animation), child: child),
            ),
            child: Icon(icon, key: ValueKey(icon), size: haloSize * 0.27, color: scheme.primary),
          ),
        ),
        const SizedBox(height: 28),
        AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.standard),
          child: Text(title, key: ValueKey(title), textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        _MaybeSmoothSize(
          child: hint == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: GlassSurface(
                    tier: GlassTier.card,
                    borderRadius: AppShape.radiusLg,
                    padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(AppIcons.info, size: 18, color: colors.info),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The standard size animation, as [SmoothSize] (a zero-duration
/// AnimatedSize re-dirties itself during layout and throws under the
/// onboarding's IntrinsicHeight when "remove animations" is on).
class _MaybeSmoothSize extends StatelessWidget {
  const _MaybeSmoothSize({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}

/// Actions under [SignInStatus]: reopen / copy the link while the browser step
/// is pending, and always a way out.
class SignInActions extends ConsumerWidget {
  const SignInActions({super.key, required this.state});

  final AccountState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final account = ref.read(accountProvider.notifier);
    final colors = DshColors.of(context);
    final waiting = state.stage == SignInStage.waitingBrowser && state.authorizeUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (waiting && state.browserHint == BrowserHint.notOpened)
          FilledButton.icon(
            onPressed: () => _copyLink(context, state.authorizeUrl!),
            icon: const Icon(AppIcons.copy, size: 18),
            label: Text(l10n.engineAccountCopySignInLink),
          )
        else if (waiting && state.browserHint == BrowserHint.returned)
          FilledButton.icon(
            onPressed: () => unawaited(account.reopenBrowser()),
            icon: const Icon(AppIcons.openExternal, size: 18),
            label: Text(l10n.engineAccountReopenSignIn),
          )
        else if (waiting)
          OutlinedButton.icon(
            onPressed: () => unawaited(account.reopenBrowser()),
            icon: const Icon(AppIcons.openExternal, size: 18),
            label: Text(l10n.engineAccountReopenSignIn),
          ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => unawaited(account.cancel()),
          style: TextButton.styleFrom(foregroundColor: colors.textTertiary),
          child: Text(l10n.engineAccountCancelSignIn),
        ),
      ],
    );
  }

  static Future<void> _copyLink(BuildContext context, String url) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: url));
    messenger?.showBriefNotice(l10n.engineAccountSignInLinkCopied);
  }
}

/// Inline, dismissible explanation of the last failed sign-in.
class SignInFailureCard extends ConsumerWidget {
  const SignInFailureCard({super.key, required this.failure});

  final SignInFailure failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(AppIcons.error, size: 20, color: colors.danger),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(failure.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(failure.message, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.commonClose,
            visualDensity: VisualDensity.compact,
            icon: Icon(AppIcons.close, size: 18, color: colors.textTertiary),
            onPressed: ref.read(accountProvider.notifier).dismissFailure,
          ),
        ],
      ),
    );
  }
}

/// Settings row for the DeepSeek account: avatar, name and masked contact when
/// signed in, otherwise a sign-in prompt. Opens [AccountPage].
///
/// Place it inside a `SheetGroup`, for example as the first row of "模型与密钥".
class AccountTile extends ConsumerWidget {
  const AccountTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(accountProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);

    final String title;
    final String? subtitle;
    final Widget leading;
    Widget? value;
    switch (state.phase) {
      case AccountPhase.signedIn:
        title = state.profile?.displayName ?? l10n.engineAccountDeepSeek;
        final contact = state.profile?.contact;
        subtitle = contact != null && contact != title ? contact : l10n.engineAccountSignedIn;
        leading = AccountAvatar(profile: state.profile, size: 32);
      case AccountPhase.signingIn:
        title = l10n.engineAccountDeepSeek;
        subtitle = null;
        leading = const _TileIcon();
        value = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StatusDot(tone: StatusTone.busy, size: 7),
            const SizedBox(width: 7),
            Text(l10n.engineAccountSigningIn),
          ],
        );
      case AccountPhase.unsupported:
        title = l10n.engineAccountDeepSeek;
        subtitle = l10n.engineAccountUnsupported;
        leading = const _TileIcon();
      case AccountPhase.signedOut:
        title = l10n.engineAccountDeepSeek;
        subtitle = l10n.engineAccountNoKeyNeeded;
        leading = const _TileIcon();
        value = Text(l10n.engineAccountSignedOut, style: TextStyle(color: colors.textTertiary));
      case AccountPhase.unknown:
        // Engine not connected yet: don't claim either way.
        title = l10n.engineAccountDeepSeek;
        subtitle = l10n.engineAccountNoKeyNeeded;
        leading = const _TileIcon();
    }

    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountPage())),
      splashFactory: rowSplash(context),
      highlightColor: scheme.onSurface.withValues(alpha: 0.05),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: subtitle == null ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightTwoLine,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 6, SettingsMetrics.trailingPad, 6),
          child: Row(
            children: [
              leading,
              const SizedBox(width: SettingsMetrics.iconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: settingsTitleStyle(context)?.copyWith(color: scheme.onSurface),
                    ),
                    if (subtitle case final sub?) ...[
                      const SizedBox(height: 1),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  child: value,
                ),
              ],
              const SizedBox(width: 4),
              const OverviewChevron(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same 32dp round tinted glyph as the other settings rows.
class _TileIcon extends StatelessWidget {
  const _TileIcon();

  @override
  Widget build(BuildContext context) => const SettingsIcon(AppIcons.account);
}

/// Three plain facts about account sign-in, on the account page and in onboarding.
class AccountFacts extends StatelessWidget {
  const AccountFacts({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        OnboardingFact(icon: AppIcons.balance, text: l10n.engineAccountUsageFact),
        OnboardingFact(icon: AppIcons.browser, text: l10n.engineAccountBrowserFact),
        OnboardingFact(icon: AppIcons.localOnly, text: l10n.engineAccountCredentialsFact),
      ],
    );
  }
}
