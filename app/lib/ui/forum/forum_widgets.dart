// The small pieces the forum pages share — avatars, the category dot, relative
// times and the topic row.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../forum/discourse_client.dart';
import '../../forum/forum_models.dart';
import '../../forum/forum_state.dart';
import '../common/display_image.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

// ── Time ─────────────────────────────────────────────────────────────────────

/// `刚刚`, `5 分钟前`, `3 小时前`, `昨天`, `6 天前`, `10月3日`, `2025年3月1日`.
String forumAgo(DateTime? at, {DateTime? now}) {
  if (at == null) return '';
  final current = now ?? DateTime.now();
  final d = current.difference(at);
  if (d.inSeconds < 60) return appL10n.remoteForumJustNow;
  if (d.inMinutes < 60) return appL10n.remoteForumMinutesAgo(d.inMinutes);
  if (d.inHours < 24) return appL10n.remoteForumHoursAgo(d.inHours);
  if (d.inHours < 48) return appL10n.commonYesterday;
  if (d.inDays < 30) return appL10n.remoteForumDaysAgo(d.inDays);
  if (at.year == current.year) return appL10n.monthDay(at);
  return appL10n.remoteForumYearDate(at.year, at.month.toString(), at.day);
}

/// `1.2万` for big counts, plain digits below ten thousand.
String forumCount(int n) {
  if (n < 10000) return '$n';
  if (appL10n.localeName == 'en') return NumberFormat.compact(locale: 'en').format(n);
  final wan = n / 10000;
  final value = (wan >= 100 ? wan.round() : (wan * 10).round() / 10).toString().replaceFirst(RegExp(r'\.0$'), '');
  return appL10n.remoteForumTenThousands(value);
}

// ── Avatars ──────────────────────────────────────────────────────────────────

/// A round avatar: the user's picture over their initial on an identity
/// colour (what shows while it loads, offline, or in tests).
class ForumAvatar extends ConsumerWidget {
  const ForumAvatar({super.key, required this.username, this.template, this.url, this.size = 32, this.ring});

  final String username;

  /// Discourse avatar template (`…/{size}/…`).
  final String? template;

  /// A ready URL (quotes carry one), used when there is no [template].
  final Uri? url;
  final double size;

  /// A ring in this colour around the avatar (overlapping stacks).
  final Color? ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = DshColors.of(context);
    final slot = DshColors.identityIndex(username.toLowerCase());
    final base = ref.watch(forumApiProvider.select((api) => api.baseUrl));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final source = template != null ? forumAvatarUrl(base, template, size: (size * dpr).ceil()) : url;
    final initial = username.isEmpty ? '?' : username.characters.first.toUpperCase();
    Widget avatar = DecoratedBox(
      decoration: ShapeDecoration(color: colors.identity[slot], shape: const CircleBorder()),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Text(
                initial,
                style: TextStyle(
                  fontSize: size * 0.44,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: colors.onIdentity[slot],
                ),
              ),
            ),
            if (source != null)
              ClipOval(
                child: Image(
                  image: imageForDisplay(NetworkImage(source.toString()), width: size, height: size, pixelRatio: dpr),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  frameBuilder: (context, child, frame, sync) => sync
                      ? child
                      : AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: AppMotion.of(context, AppMotion.quick),
                          child: child,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
    if (ring case final ring?) {
      avatar = DecoratedBox(
        decoration: ShapeDecoration(color: ring, shape: const CircleBorder()),
        child: Padding(padding: const EdgeInsets.all(1.5), child: avatar),
      );
    }
    return Semantics(
      label: username,
      image: true,
      child: ExcludeSemantics(child: avatar),
    );
  }
}

/// Up to three overlapping avatars (the topic row's right edge).
class ForumAvatarStack extends StatelessWidget {
  const ForumAvatarStack({super.key, required this.users, this.size = 22});

  final List<ForumUser> users;
  final double size;

  /// How much each avatar tucks under the next.
  static const overlap = 7.0;

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) return const SizedBox.shrink();
    final ring = Theme.of(context).colorScheme.surface;
    final step = size + 3 - overlap;
    return SizedBox(
      width: step * (users.length - 1) + size + 3,
      height: size + 3,
      child: Stack(
        children: [
          for (final (i, user) in users.indexed.toList().reversed)
            Positioned(
              left: step * i,
              child: ForumAvatar(username: user.username, template: user.avatarTemplate, size: size, ring: ring),
            ),
        ],
      ),
    );
  }
}

// ── Categories ───────────────────────────────────────────────────────────────

/// The category's colour as a small dot, then its name.
class ForumCategoryLabel extends StatelessWidget {
  const ForumCategoryLabel({super.key, required this.category, this.style});

  final ForumCategory category;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = style ?? Theme.of(context).textTheme.bodySmall!.copyWith(color: DshColors.of(context).textTertiary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ForumCategoryDot(color: Color(category.colorValue)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(category.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text),
        ),
      ],
    );
  }
}

class ForumCategoryDot extends StatelessWidget {
  const ForumCategoryDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(color: color, shape: const CircleBorder()),
    child: SizedBox.square(dimension: size),
  );
}

// ── Topic row ────────────────────────────────────────────────────────────────

/// One topic in a list:
///
/// ```
/// │ 标题，最多两行                                   ◍◍◍ │
/// │ ● 插件 · 12 回复 · 3 小时前                           │
/// ```
class ForumTopicRow extends StatelessWidget {
  const ForumTopicRow({super.key, required this.topic, this.category, this.onTap, this.showCategory = true});

  final ForumTopic topic;
  final ForumCategory? category;
  final VoidCallback? onTap;
  final bool showCategory;

  static const horizontal = 16.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final meta = theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary);
    final fresh = topic.unseen || topic.unreadPosts > 0;
    final title = Text.rich(
      TextSpan(
        children: [
          if (topic.pinned)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(AppIcons.pinActive, size: 15, color: colors.textTertiary),
              ),
            ),
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(AppIcons.lockActive, size: 15, color: colors.textTertiary),
              ),
            ),
          TextSpan(text: topic.title),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.4, color: theme.colorScheme.onSurface),
    );
    final dot = Text(' · ', style: meta);
    final semantics = [
      topic.title,
      if (showCategory && category != null) category!.name,
      l10n.remoteForumReplyCount(topic.replies),
      forumAgo(topic.activityAt),
    ].join(l10n.remoteForumSemanticsSeparator);
    return Semantics(
      button: onTap != null,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: horizontal, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      title,
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (showCategory && category != null) ...[
                            Flexible(
                              child: ForumCategoryLabel(category: category!, style: meta),
                            ),
                            dot,
                          ],
                          Text(
                            l10n.remoteForumCompactReplies(topic.replies, forumCount(topic.replies)),
                            style: AppType.tabular(meta),
                          ),
                          dot,
                          Text(forumAgo(topic.activityAt), style: AppType.tabular(meta)),
                          if (fresh) ...[
                            dot,
                            Text(
                              topic.unreadPosts > 0
                                  ? l10n.remoteForumNewReplyCount(topic.unreadPosts)
                                  : l10n.remoteForumNew,
                              style: meta.copyWith(color: colors.info),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ForumAvatarStack(users: topic.avatars()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The quiet stand-in while a list loads: grey bars where rows will be (no
/// shimmer: nothing loops).
class ForumListSkeleton extends StatelessWidget {
  const ForumListSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.onSurface.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.08 : 0.06);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
    );
    return Semantics(
      label: l10n.remoteLoading,
      child: Column(
        children: [
          for (var i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(widthFactor: i.isEven ? 0.86 : 0.64, child: bar(double.infinity, 14)),
                        const SizedBox(height: 10),
                        bar(132, 10),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  bar(48, 22),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The end of a paged list: a small ring while loading, a retry line after a
/// failure, nothing otherwise.
class ForumListFooter extends StatelessWidget {
  const ForumListFooter({super.key, required this.loading, this.error, this.onRetry, this.end = false});

  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  /// Everything is loaded: a faint end mark.
  final bool end;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    Widget child;
    if (loading) {
      child = const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (error != null) {
      child = TextButton(onPressed: onRetry, child: Text(l10n.remoteForumErrorRetry(error.toString())));
    } else if (end) {
      child = Text(l10n.remoteForumNoMore, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary));
    } else {
      child = const SizedBox(height: 20);
    }
    return SizedBox(height: 64, child: Center(child: child));
  }
}
