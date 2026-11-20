// Search the forum (titles and posts; Chinese is segmented on the server when
// the forum's default locale is zh_CN).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../forum/discourse_client.dart';
import '../../forum/forum_models.dart';
import '../../forum/forum_state.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'forum_topic_page.dart';
import 'forum_widgets.dart';

class ForumSearchPage extends ConsumerStatefulWidget {
  const ForumSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  static Route<void> route() => MaterialPageRoute(builder: (_) => const ForumSearchPage());

  @override
  ConsumerState<ForumSearchPage> createState() => _ForumSearchPageState();
}

class _ForumSearchPageState extends ConsumerState<ForumSearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final term = _query.trim();
    final async = term.isEmpty ? null : ref.watch(forumSearchProvider(term));
    final site = ref.watch(forumSiteProvider).value;

    final field = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: TextField(
        controller: _controller,
        autofocus: widget.initialQuery.isEmpty,
        textInputAction: TextInputAction.search,
        onChanged: (text) => setState(() => _query = text),
        onSubmitted: (text) => setState(() => _query = text),
        style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15),
        decoration: InputDecoration(
          hintText: l10n.remoteForumSearchHint,
          filled: true,
          fillColor: theme.colorScheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.08 : 0.05),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          prefixIcon: Icon(AppIcons.search, size: 20, color: colors.textTertiary),
          prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.commonClear,
                  iconSize: 18,
                  icon: Icon(AppIcons.clear, color: colors.textTertiary),
                  onPressed: () => setState(() {
                    _controller.clear();
                    _query = '';
                  }),
                ),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(999)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(999)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(999)),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );

    final Widget body;
    if (async == null) {
      body = EmptyView(icon: AppIcons.search, title: l10n.remoteForumSearchHint);
    } else if (async.hasError && !async.hasValue) {
      final error = async.error;
      body = EmptyView(
        icon: AppIcons.offline,
        title: error is ForumException ? error.message : l10n.remoteForumErrSearch,
        actionLabel: l10n.commonRetry,
        onAction: () => ref.invalidate(forumSearchProvider(term)),
      );
    } else if (async.value == null || async.isLoading && async.value!.hits.isEmpty) {
      body = const ForumListSkeleton(rows: 4);
    } else if (async.value!.hits.isEmpty) {
      body = EmptyView(icon: AppIcons.noResults, title: l10n.remoteForumNoSearchResults(term));
    } else {
      final hits = async.value!.hits;
      body = Column(
        children: [
          for (final (i, hit) in hits.indexed)
            FadeSlideIn(
              index: i,
              child: ForumSearchRow(
                hit: hit,
                category: site?.category(hit.topic.categoryId),
                onTap: () => unawaited(
                  Navigator.of(context).push(
                    ForumTopicPage.route(topicId: hit.topic.id, title: hit.topic.title, postNumber: hit.postNumber),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return AppPage(
      title: l10n.remoteForumSearch,
      showLargeTitle: false,
      slivers: [
        SliverToBoxAdapter(child: field),
        SliverToBoxAdapter(child: body),
      ],
    );
  }
}

/// A hit: the topic's title, the matching words, where and when.
class ForumSearchRow extends StatelessWidget {
  const ForumSearchRow({super.key, required this.hit, this.category, this.onTap});

  final ForumSearchHit hit;
  final ForumCategory? category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final meta = theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hit.topic.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.4),
            ),
            if (hit.blurb.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                hit.blurb,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                if (category != null) ...[
                  Flexible(
                    child: ForumCategoryLabel(category: category!, style: meta),
                  ),
                  Text(' · ', style: meta),
                ],
                if (hit.user?.username case final name? when name.isNotEmpty) ...[
                  Flexible(
                    child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: meta),
                  ),
                  Text(' · ', style: meta),
                ],
                Text(forumAgo(hit.createdAt), style: AppType.tabular(meta)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
