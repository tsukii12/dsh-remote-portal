// The forum's notifications (a list page): replies, mentions, quotes, likes,
// badges; unread ones carry a dot.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../forum/discourse_client.dart';
import '../../forum/forum_auth.dart';
import '../../forum/forum_models.dart';
import '../../forum/forum_state.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'forum_account_sheet.dart';
import 'forum_topic_page.dart';
import 'forum_widgets.dart';

class ForumNotificationsPage extends ConsumerStatefulWidget {
  const ForumNotificationsPage({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const ForumNotificationsPage());

  @override
  ConsumerState<ForumNotificationsPage> createState() => _ForumNotificationsPageState();
}

class _ForumNotificationsPageState extends ConsumerState<ForumNotificationsPage> {
  void _open(ForumNotification n) {
    unawaited(ref.read(forumNotificationsProvider.notifier).markRead(n));
    final topic = n.topicId;
    if (topic == null) return;
    unawaited(
      Navigator.of(context).push(ForumTopicPage.route(topicId: topic, title: n.title, postNumber: n.postNumber)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final signedIn = ref.watch(forumAuthProvider.select((s) => s.signedIn));
    final async = ref.watch(forumNotificationsProvider);
    final data = async.value;
    final types = ref.watch(forumSiteProvider).value?.notificationTypes ?? const {};

    final List<Widget> slivers;
    if (!signedIn) {
      slivers = [
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.notifications,
            title: l10n.remoteForumSignInForNotifications,
            actionLabel: l10n.commonSignIn,
            onAction: () => unawaited(showForumAccountSheet(context)),
          ),
        ),
      ];
    } else if (data == null && async.hasError) {
      final error = async.error;
      slivers = [
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.offline,
            title: error is ForumException ? error.message : l10n.remoteForumErrNotifications,
            actionLabel: l10n.commonRetry,
            onAction: () => ref.invalidate(forumNotificationsProvider),
          ),
        ),
      ];
    } else if (data == null) {
      slivers = const [SliverToBoxAdapter(child: ForumListSkeleton(rows: 5))];
    } else if (data.items.isEmpty) {
      slivers = [
        SliverToBoxAdapter(
          child: EmptyView(icon: AppIcons.notifications, title: l10n.remoteForumNoNotifications),
        ),
      ];
    } else {
      slivers = [
        SliverList.builder(
          itemCount: data.items.length,
          itemBuilder: (context, i) => FadeSlideIn(
            index: i,
            child: ForumNotificationRow(
              notification: data.items[i],
              typeName: types[data.items[i].type],
              onTap: () => _open(data.items[i]),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: ForumListFooter(
            loading: data.loadingMore,
            error: data.moreError,
            onRetry: () => unawaited(ref.read(forumNotificationsProvider.notifier).loadMore()),
            end: !data.hasMore && data.items.length > 12,
          ),
        ),
      ];
    }

    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        final current = ref.read(forumNotificationsProvider).value;
        if (current != null && current.hasMore && current.moreError == null && n.metrics.extentAfter < 600) {
          unawaited(ref.read(forumNotificationsProvider.notifier).loadMore());
        }
        return false;
      },
      child: RefreshIndicator(
        edgeOffset: MediaQuery.paddingOf(context).top + 56,
        onRefresh: () async {
          try {
            await ref.read(forumNotificationsProvider.notifier).refresh();
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(error is ForumException ? error.message : l10n.remoteForumErrNotifications)),
              );
            }
          }
          if (mounted) unawaited(ref.read(forumAuthProvider.notifier).refreshUser());
        },
        child: AppPage(
          title: l10n.remoteForumNotifications,
          actions: [
            if (data != null && data.unread > 0)
              GlassIconButton(
                icon: AppIcons.markAllRead,
                tooltip: l10n.remoteForumMarkAllRead,
                onPressed: () => unawaited(ref.read(forumNotificationsProvider.notifier).markAllRead()),
              ),
          ],
          slivers: slivers,
        ),
      ),
    );
  }
}

/// What a notification says, by Discourse type (names from `/site.json`;
/// the numbers are core's own and stable).
(IconData, String) describeForumNotification(ForumNotification n, String? typeName) {
  final who = n.actor ?? appL10n.remoteForumSomeone;
  final type = typeName ?? _coreTypes[n.type];
  return switch (type) {
    'mentioned' => (AppIcons.mention, appL10n.remoteForumNotificationMention(who)),
    'group_mentioned' => (AppIcons.mention, appL10n.remoteForumNotificationGroupMention(who)),
    'replied' => (AppIcons.reply, appL10n.remoteForumNotificationReply(who)),
    'quoted' => (AppIcons.quote, appL10n.remoteForumNotificationQuote(who)),
    'edited' => (AppIcons.edit, appL10n.remoteForumNotificationEdit(who)),
    'liked' => (
      AppIcons.postLike,
      n.count > 1 ? appL10n.remoteForumNotificationLikes(who, n.count) : appL10n.remoteForumNotificationLike(who),
    ),
    'liked_consolidated' => (AppIcons.postLike, appL10n.remoteForumNotificationLikedPosts(who, n.count)),
    'reaction' => (AppIcons.reaction, appL10n.remoteForumNotificationReaction(who)),
    'private_message' => (AppIcons.mail, appL10n.remoteForumNotificationMessage(who)),
    'invited_to_private_message' => (AppIcons.mail, appL10n.remoteForumNotificationMessageInvite(who)),
    'invited_to_topic' => (AppIcons.invite, appL10n.remoteForumNotificationTopicInvite(who)),
    'posted' => (AppIcons.chat, appL10n.remoteForumNotificationNewReply(who)),
    'watching_first_post' => (AppIcons.newTopic, appL10n.remoteForumNotificationNewTopic(who)),
    'linked' => (AppIcons.link, appL10n.remoteForumNotificationLink(who)),
    'granted_badge' => (AppIcons.badgeEarned, appL10n.remoteForumNotificationBadge(n.badgeName ?? '')),
    'moved_post' => (AppIcons.moved, appL10n.remoteForumNotificationMoved(who)),
    'bookmark_reminder' => (AppIcons.bookmark, appL10n.remoteForumBookmarkReminder),
    'topic_reminder' => (AppIcons.reminder, appL10n.remoteForumTopicReminder),
    'post_approved' => (AppIcons.completed, appL10n.remoteForumPostApproved),
    'admin_problems' => (AppIcons.caution, appL10n.remoteForumAdminProblems),
    _ => (AppIcons.notifications, n.title ?? appL10n.remoteForumNewNotification),
  };
}

const _coreTypes = {
  1: 'mentioned',
  2: 'replied',
  3: 'quoted',
  4: 'edited',
  5: 'liked',
  6: 'private_message',
  7: 'invited_to_private_message',
  9: 'posted',
  10: 'moved_post',
  11: 'linked',
  12: 'granted_badge',
  13: 'invited_to_topic',
  15: 'group_mentioned',
  17: 'watching_first_post',
  18: 'topic_reminder',
  19: 'liked_consolidated',
  20: 'post_approved',
  24: 'bookmark_reminder',
  25: 'reaction',
};

class ForumNotificationRow extends StatelessWidget {
  const ForumNotificationRow({super.key, required this.notification, this.typeName, this.onTap});

  final ForumNotification notification;
  final String? typeName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final (icon, line) = describeForumNotification(notification, typeName);
    final unread = !notification.read;
    final subtitle = notification.title;
    return Semantics(
      button: onTap != null,
      label: [
        line,
        ?subtitle,
        if (unread) l10n.remoteForumUnread,
        forumAgo(notification.createdAt),
      ].join(l10n.remoteForumSemanticsSeparator),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: Center(
                    child: Icon(icon, size: 20, color: unread ? theme.colorScheme.onSurface : colors.textTertiary),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 15,
                          height: 1.4,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                          color: unread ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      forumAgo(notification.createdAt),
                      style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                    ),
                    const SizedBox(height: 6),
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        color: unread ? colors.info : Colors.transparent,
                        shape: const CircleBorder(),
                      ),
                      child: const SizedBox.square(dimension: 8),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
