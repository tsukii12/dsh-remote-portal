// The forum's account sheet — sign in with a Discourse User API Key (signed
// out), who you are and your numbers (signed in) — and 论坛设置, where the forum
// address can be changed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../forum/forum_auth.dart';
import '../../forum/forum_config.dart';
import '../../forum/forum_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/overview_card.dart';
import '../common/page_hero.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'forum_notifications_page.dart';
import 'forum_post_body.dart' show openForumLink;
import 'forum_widgets.dart';

/// The forum's glyph colour (the 社区 hub's forum row uses the same slot).
const forumTint = 2;

Future<void> showForumAccountSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const ForumAccountSheet());

/// Signed out: 「登录论坛」. Signed in: the account, notifications, sign out.
class ForumAccountSheet extends ConsumerWidget {
  const ForumAccountSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(forumAuthProvider);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(child: auth.signedIn ? const _SignedIn() : _SignIn(auth: auth)),
    );
  }
}

class _SignIn extends ConsumerStatefulWidget {
  const _SignIn({required this.auth});

  final ForumAuthState auth;

  @override
  ConsumerState<_SignIn> createState() => _SignInState();
}

class _SignInState extends ConsumerState<_SignIn> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final auth = widget.auth;
    final waiting = auth.phase == ForumAuthPhase.waiting;
    final host = Uri.tryParse(ref.watch(forumBaseUrlProvider))?.host ?? '';
    final controller = ref.read(forumAuthProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHeader(l10n.remoteForumSignIn),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 0),
          child: Row(
            children: [
              const OverviewGlyph(AppIcons.forum, tint: forumTint, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.remoteForumSignInBenefits, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (waiting)
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
            child: Row(
              children: [
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(child: Text(l10n.remoteForumFinishSignIn, style: theme.textTheme.bodyMedium)),
                TextButton(onPressed: controller.cancel, child: Text(l10n.commonCancel)),
              ],
            ),
          )
        else if (auth.error case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
            child: Text(error, style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: auth.phase == ForumAuthPhase.restoring ? null : () => unawaited(controller.signIn()),
            child: Text(waiting ? l10n.remoteReopenBrowser : l10n.commonSignIn),
          ),
        ),
        const SizedBox(height: 16),
        SheetGroup(
          children: [
            ListPageRow(
              icon: AppIcons.configure,
              title: l10n.remoteForumSettings,
              onTap: () => unawaited(showForumSettingsSheet(context)),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _SignedIn extends ConsumerWidget {
  const _SignedIn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final auth = ref.watch(forumAuthProvider);
    final user = auth.user;
    final summary = user == null ? null : ref.watch(forumUserSummaryProvider(user.username)).value;
    final base = ref.watch(forumBaseUrlProvider);
    String figure(int? n) => n == null ? '—' : forumCount(n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHeader(l10n.remoteForumAccount),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 0),
          child: Row(
            children: [
              ForumAvatar(username: user?.username ?? '', template: user?.avatarTemplate, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      user?.displayName ?? l10n.commonSignedIn,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (user != null)
                      Text(
                        '@${user.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, (value, label)) in [
                (figure(summary?.topicCount), l10n.remoteForumTopic),
                (figure(summary?.postCount), l10n.commonReply),
                (figure(summary?.likesReceived), l10n.remoteForumLikesReceived),
                (figure(summary?.daysVisited), l10n.remoteForumDaysVisited),
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(
                  child: HeroStat(value: value, label: label),
                ),
              ],
            ],
          ),
        ),
        SheetGroup(
          children: [
            ListPageRow(
              icon: AppIcons.notifications,
              title: l10n.remoteForumNotifications,
              meta: auth.unread > 0 ? l10n.remoteForumUnreadCount(auth.unread) : null,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(Navigator.of(context).push(ForumNotificationsPage.route()));
              },
            ),
            ListPageRow(
              icon: AppIcons.openExternal,
              title: l10n.commonOpenInWeb,
              onTap: () => unawaited(openForumLink(Uri.parse(base))),
            ),
            ListPageRow(
              icon: AppIcons.configure,
              title: l10n.remoteForumSettings,
              onTap: () => unawaited(showForumSettingsSheet(context)),
            ),
          ],
        ),
        SheetGroup(
          children: [
            ListPageRow(
              icon: AppIcons.logout,
              title: l10n.commonSignOut,
              danger: true,
              chevron: false,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(ref.read(forumAuthProvider.notifier).signOut());
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

// ── 论坛设置 ─────────────────────────────────────────────────────────────────

Future<void> showForumSettingsSheet(BuildContext context) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => const ForumSettingsSheet(),
);

/// The forum address (an advanced override of [forumDefaultBaseUrl]).
class ForumSettingsSheet extends ConsumerStatefulWidget {
  const ForumSettingsSheet({super.key});

  @override
  ConsumerState<ForumSettingsSheet> createState() => _ForumSettingsSheetState();
}

class _ForumSettingsSheetState extends ConsumerState<ForumSettingsSheet> {
  late final _controller = TextEditingController(text: ref.read(forumBaseUrlProvider));
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save([String? value]) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await ref.read(forumBaseUrlProvider.notifier).set(value ?? _controller.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = context.l10n.remoteForumErrAddress;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final custom = ref.watch(forumBaseUrlProvider) != forumDefaultBaseUrl;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(l10n.remoteForumSettings),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.remoteForumAddress,
                  hintText: forumDefaultBaseUrl,
                  errorText: _error,
                ),
                onSubmitted: (_) => unawaited(_save()),
              ),
            ),
            if (custom)
              Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 0),
                child: Text(
                  l10n.remoteForumDefaultAddress(Uri.parse(forumDefaultBaseUrl).host),
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _saving || !custom ? null : () => unawaited(_save('')),
                      child: Text(l10n.remoteRestoreDefault),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _saving ? null : () => unawaited(_save()),
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
