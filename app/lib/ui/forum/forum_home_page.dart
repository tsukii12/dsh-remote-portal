// 「论坛」, the forum's home (a list page): 最新 / 热门 / the categories as capsules,
// topics below, pull to refresh, more as you scroll. Signed out it reads public
// categories; signing in (account button) adds posting, replies, likes and
// notifications.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../forum/discourse_client.dart';
import '../../forum/forum_auth.dart';
import '../../forum/forum_models.dart';
import '../../forum/forum_state.dart';
import '../common/capsule_chip.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../common/pressable.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'forum_account_sheet.dart';
import 'forum_composer_sheet.dart';
import 'forum_notifications_page.dart';
import 'forum_search_page.dart';
import 'forum_topic_page.dart';
import 'forum_widgets.dart';

class ForumHomePage extends ConsumerStatefulWidget {
  const ForumHomePage({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const ForumHomePage());

  @override
  ConsumerState<ForumHomePage> createState() => _ForumHomePageState();
}

class _ForumHomePageState extends ConsumerState<ForumHomePage> {
  ForumFeed _feed = const ForumFeed.latest();

  @override
  void initState() {
    super.initState();
    // Fresh unread count for the bell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(forumAuthProvider.notifier).refreshUser());
    });
  }

  ForumTopicsController get _list => ref.read(forumTopicsProvider(_feed).notifier);

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _compose() async {
    if (!ref.read(forumAuthProvider).signedIn) {
      await showForumAccountSheet(context);
      return;
    }
    final result = await showForumComposer(context, ForumNewTopicTarget(categoryId: _feed.categoryId));
    if (result == null || !mounted) return;
    if (result.queued) {
      _toast(context.l10n.remoteForumPendingApproval);
      return;
    }
    unawaited(_list.refresh());
    final id = result.topicId;
    if (id != null) unawaited(Navigator.of(context).push(ForumTopicPage.route(topicId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final auth = ref.watch(forumAuthProvider);
    final site = ref.watch(forumSiteProvider).value;
    final async = ref.watch(forumTopicsProvider(_feed));
    final list = async.value;
    final padding = MediaQuery.paddingOf(context);

    final capsules = SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        children: [
          for (final (label, feed) in [
            (l10n.remoteForumLatest, const ForumFeed.latest()),
            (l10n.remoteForumTop, const ForumFeed.top()),
            for (final c in site?.topLevel ?? const <ForumCategory>[]) (c.name, ForumFeed.category(c)),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CapsuleChoiceChip(
                label: label,
                selected: _feed == feed,
                onSelected: () => setState(() => _feed = feed),
              ),
            ),
        ],
      ),
    );

    final List<Widget> body;
    if (list == null && async.hasError) {
      final error = async.error;
      body = [
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.offline,
            title: error is ForumException ? error.message : l10n.remoteForumErrOpen,
            actionLabel: l10n.commonRetry,
            onAction: () {
              ref.invalidate(forumSiteProvider);
              ref.invalidate(forumTopicsProvider(_feed));
            },
          ),
        ),
      ];
    } else if (list == null) {
      body = const [SliverToBoxAdapter(child: ForumListSkeleton())];
    } else if (list.topics.isEmpty) {
      body = [
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.forum,
            title: l10n.remoteForumNoTopics,
            actionLabel: auth.signedIn ? l10n.remoteForumPost : null,
            onAction: auth.signedIn ? () => unawaited(_compose()) : null,
          ),
        ),
      ];
    } else {
      body = [
        SliverList.builder(
          itemCount: list.topics.length,
          itemBuilder: (context, i) {
            final topic = list.topics[i];
            return FadeSlideIn(
              index: i,
              child: ForumTopicRow(
                key: ValueKey(topic.id),
                topic: topic,
                category: site?.category(topic.categoryId),
                showCategory: _feed.kind != ForumFeedKind.category,
                onTap: () =>
                    unawaited(Navigator.of(context).push(ForumTopicPage.route(topicId: topic.id, title: topic.title))),
              ),
            );
          },
        ),
        SliverToBoxAdapter(
          child: ForumListFooter(
            loading: list.loadingMore,
            error: list.moreError,
            onRetry: () => unawaited(_list.loadMore()),
            end: !list.hasMore && list.topics.length > 10,
          ),
        ),
      ];
    }

    final page = NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        final current = ref.read(forumTopicsProvider(_feed)).value;
        if (current != null && current.hasMore && current.moreError == null && n.metrics.extentAfter < 900) {
          unawaited(_list.loadMore());
        }
        return false;
      },
      child: RefreshIndicator(
        edgeOffset: padding.top + 56,
        onRefresh: () async {
          ref.invalidate(forumSiteProvider);
          unawaited(ref.read(forumAuthProvider.notifier).refreshUser());
          await _list.refresh();
        },
        child: AppPage(
          title: l10n.remoteForum,
          actions: [
            if (auth.signedIn)
              GlassIconButton(
                icon: AppIcons.notifications,
                tooltip: auth.unread > 0
                    ? l10n.remoteForumNotificationsUnread(auth.unread)
                    : l10n.remoteForumNotifications,
                badge: auth.unread > 0 ? _UnreadBadge(count: auth.unread) : null,
                onPressed: () => unawaited(Navigator.of(context).push(ForumNotificationsPage.route())),
              ),
            _AccountButton(auth: auth),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: _SearchEntry(onTap: () => unawaited(Navigator.of(context).push(ForumSearchPage.route()))),
            ),
            SliverToBoxAdapter(child: capsules),
            ...body,
            const SliverToBoxAdapter(child: SizedBox(height: ForumComposeButton.height + 12)),
          ],
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: page),
        Positioned(
          right: 12,
          bottom: padding.bottom + 12,
          child: ForumComposeButton(onPressed: () => unawaited(_compose())),
        ),
      ],
    );
  }
}

/// The account key in the bar: the user's avatar in a 44 glass circle
/// (signed in), a person glyph otherwise.
class _AccountButton extends StatelessWidget {
  const _AccountButton({required this.auth});

  final ForumAuthState auth;

  static const size = 44.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final user = auth.user;
    final label = auth.signedIn ? l10n.remoteForumAccount : l10n.remoteForumSignIn;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: size,
          child: GlassSurface(
            tier: GlassTier.chrome,
            circle: true,
            grouped: true,
            onTap: () => unawaited(showForumAccountSheet(context)),
            child: Center(
              child: auth.signedIn && user != null
                  ? ForumAvatar(username: user.username, template: user.avatarTemplate, size: size - 10)
                  : Icon(AppIcons.profile, size: 22, color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「搜索话题和帖子」: a capsule that opens search (the plugin market's look).
class _SearchEntry extends StatelessWidget {
  const _SearchEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final fill = theme.colorScheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.08 : 0.05);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Semantics(
        button: true,
        label: l10n.remoteForumSearch,
        excludeSemantics: true,
        child: Material(
          color: fill,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 42,
              child: Row(
                children: [
                  SizedBox(width: 44, child: Icon(AppIcons.search, size: 20, color: colors.textTertiary)),
                  Text(
                    l10n.remoteForumSearchHint,
                    style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, color: colors.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The count on the bell: a small red capsule.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: ShapeDecoration(color: colors.danger, shape: const StadiumBorder()),
      alignment: Alignment.center,
      child: Text(
        text,
        style: AppType.tabular(TextStyle(fontSize: 10, height: 1, fontWeight: FontWeight.w600, color: colors.onDanger)),
      ),
    );
  }
}

/// 「发帖」: the page's one primary control, floating bottom-right.
class ForumComposeButton extends StatelessWidget {
  const ForumComposeButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Pressable(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: const StadiumBorder(),
          shadows: [
            BoxShadow(color: scheme.primary.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 6)),
          ],
        ),
        child: FilledButton.icon(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, height),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            shape: const StadiumBorder(),
            elevation: 0,
          ),
          icon: const Icon(AppIcons.newPost, size: 18),
          label: Text(l10n.remoteForumPost),
        ),
      ),
    );
  }
}
