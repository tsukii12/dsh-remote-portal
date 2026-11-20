// A forum post's body. The cooked HTML is read into blocks
// (lib/forum/render/cooked.dart): prose goes through the app's MarkdownBody,
// exactly like a chat reply; quotes, link previews, pictures, share codes,
// spoiler-style details and polls get their own native pieces.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../forum/forum_share.dart';
import '../../forum/forum_state.dart';
import '../../forum/render/cooked.dart';
import '../../share_code/share_link.dart';
import '../../share_code/share_models.dart';
import '../chat/render/markdown_body.dart';
import '../chat/widgets/image_gallery.dart';
import '../common/display_image.dart';
import '../common/expand_reveal.dart';
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'forum_widgets.dart';

/// Opens a web address outside the app (http/https only).
Future<void> openForumLink(Uri url) async {
  if (url.scheme != 'http' && url.scheme != 'https') return;
  try {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No browser: nothing to do.
  }
}

class ForumPostBody extends ConsumerStatefulWidget {
  const ForumPostBody({super.key, required this.cooked, this.onOpenTopic, this.secondary = false, this.postUrl});

  final String cooked;

  /// The post on the web (polls and other things only the web can show).
  final Uri? postUrl;

  /// A quote from another topic was tapped.
  final void Function(int topicId, int? postNumber)? onOpenTopic;

  /// Quieter type (inside quotes).
  final bool secondary;

  @override
  ConsumerState<ForumPostBody> createState() => _ForumPostBodyState();
}

class _ForumPostBodyState extends ConsumerState<ForumPostBody> {
  List<CookedBlock>? _blocks;
  String? _source;
  Uri? _base;

  List<CookedBlock> _read(Uri base) {
    if (_blocks == null || _source != widget.cooked || _base != base) {
      _source = widget.cooked;
      _base = base;
      _blocks = parseCooked(widget.cooked, base: base);
    }
    return _blocks!;
  }

  @override
  Widget build(BuildContext context) {
    final base = ref.watch(forumApiProvider.select((api) => api.baseUrl));
    return ForumBlocks(
      blocks: _read(base),
      onOpenTopic: widget.onOpenTopic,
      secondary: widget.secondary,
      postUrl: widget.postUrl,
    );
  }
}

/// Draws already-read blocks (quotes nest through it).
class ForumBlocks extends StatelessWidget {
  const ForumBlocks({super.key, required this.blocks, this.onOpenTopic, this.secondary = false, this.postUrl});

  final List<CookedBlock> blocks;
  final void Function(int topicId, int? postNumber)? onOpenTopic;
  final bool secondary;
  final Uri? postUrl;

  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final images = blocks.whereType<CookedImage>().toList(growable: false);
    var imageIndex = 0;
    final children = <Widget>[
      for (final block in blocks)
        switch (block) {
          CookedMarkdown(:final markdown) => MarkdownBody(text: markdown, secondary: secondary),
          CookedQuote() => ForumQuoteBlock(quote: block, onOpenTopic: onOpenTopic),
          CookedOnebox() => ForumOneboxCard(onebox: block),
          CookedImage() => ForumPostImage(image: block, gallery: images, initial: imageIndex++),
          CookedShare(:final link, :final label) => ForumShareCard(link: link, label: label),
          CookedDetails() => _DetailsBlock(details: block, onOpenTopic: onOpenTopic),
          CookedEmbed() => _EmbedRow(embed: block, fallback: postUrl),
        },
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: gap), child],
      ],
    );
  }
}

// ── Quote ────────────────────────────────────────────────────────────────────

/// `[quote]`: a thin bar, who said it, then their words in quieter type.
class ForumQuoteBlock extends StatelessWidget {
  const ForumQuoteBlock({super.key, required this.quote, this.onOpenTopic});

  final CookedQuote quote;
  final void Function(int topicId, int? postNumber)? onOpenTopic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final name = quote.username;
    final other = quote.topicTitle;
    final header = Row(
      children: [
        if (name != null) ...[ForumAvatar(username: name, url: quote.avatarUrl, size: 20), const SizedBox(width: 8)],
        Flexible(
          child: Text(
            [?name, ?other].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (other != null && quote.topicId != null && onOpenTopic != null) ...[
          const SizedBox(width: 4),
          Icon(AppIcons.disclosure, size: 18, color: colors.textTertiary),
        ],
      ],
    );
    final open = other != null && quote.topicId != null && onOpenTopic != null
        ? () => onOpenTopic!(quote.topicId!, quote.postNumber)
        : null;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.05 : 0.035),
        shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name != null || other != null) ...[
              open == null ? header : GestureDetector(onTap: open, behavior: HitTestBehavior.opaque, child: header),
              const SizedBox(height: 8),
            ],
            ForumBlocks(blocks: quote.body, onOpenTopic: onOpenTopic, secondary: true),
          ],
        ),
      ),
    );
  }
}

// ── Link preview ─────────────────────────────────────────────────────────────

class ForumOneboxCard extends StatelessWidget {
  const ForumOneboxCard({super.key, required this.onebox});

  final CookedOnebox onebox;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final image = onebox.imageUrl;
    return Pressable(
      onTap: () => unawaited(openForumLink(onebox.url)),
      semanticLabel: onebox.title ?? onebox.url.toString(),
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusMd,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(AppIcons.link, size: 14, color: colors.textTertiary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            onebox.source ?? onebox.url.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                    if (onebox.title case final title?) ...[
                      const SizedBox(height: 4),
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    ],
                    if (onebox.description case final description?) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              if (image != null) ...[
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: AppShape.radiusSm,
                  child: SizedBox.square(
                    dimension: 56,
                    child: ColoredBox(
                      color: colors.codeWellBg,
                      child: Image(
                        image: imageForDisplay(
                          NetworkImage(image.toString()),
                          width: 56,
                          height: 56,
                          pixelRatio: MediaQuery.devicePixelRatioOf(context),
                        ),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(AppIcons.image, size: 20, color: colors.textTertiary),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pictures ─────────────────────────────────────────────────────────────────

class ForumPostImage extends StatelessWidget {
  const ForumPostImage({super.key, required this.image, this.gallery, this.initial = 0});

  final CookedImage image;
  final List<CookedImage>? gallery;
  final int initial;

  /// Tallest a picture is drawn in a post; a tap shows it whole.
  static const maxHeight = 420.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final ratio = image.aspectRatio ?? 16 / 9;
    return LayoutBuilder(
      builder: (context, constraints) {
        final natural = image.width?.toDouble() ?? constraints.maxWidth;
        var width = natural.clamp(0.0, constraints.maxWidth);
        var height = width / ratio;
        if (height > maxHeight) {
          height = maxHeight;
          width = height * ratio;
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            image: true,
            label: image.alt.isEmpty ? l10n.remoteForumImage : image.alt,
            child: Pressable(
              onTap: () =>
                  Navigator.of(context).push(ForumImageViewer.route(image, gallery: gallery, initial: initial)),
              child: ClipRRect(
                borderRadius: AppShape.radiusMd,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: ColoredBox(
                    color: colors.codeWellBg,
                    child: Image(
                      image: imageForDisplay(
                        NetworkImage(image.src.toString()),
                        width: width,
                        height: height,
                        pixelRatio: MediaQuery.devicePixelRatioOf(context),
                      ),
                      fit: BoxFit.cover,
                      frameBuilder: (context, child, frame, sync) => sync
                          ? child
                          : AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: AppMotion.of(context, AppMotion.quick),
                              child: child,
                            ),
                      errorBuilder: (_, _, _) =>
                          Center(child: Icon(AppIcons.image, size: 28, color: colors.textTertiary)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The direct pictures in one post body (quotes and details stay separate).
class ForumImageViewer extends StatefulWidget {
  const ForumImageViewer({super.key, required this.image, this.gallery, this.initial = 0});

  final CookedImage image;
  final List<CookedImage>? gallery;
  final int initial;

  static Route<void> route(CookedImage image, {List<CookedImage>? gallery, int initial = 0}) => MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ForumImageViewer(image: image, gallery: gallery, initial: initial),
  );

  @override
  State<ForumImageViewer> createState() => _ForumImageViewerState();
}

class _ForumImageViewerState extends State<ForumImageViewer> {
  late final _images = List<CookedImage>.unmodifiable(
    widget.gallery?.isNotEmpty == true ? widget.gallery! : [widget.image],
  );
  late int _index = widget.initial.clamp(0, _images.length - 1);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: ImagePager(
              initialPage: _index,
              itemCount: _images.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) {
                final image = _images[index];
                return Center(
                  child: Image.network(
                    (image.fullSrc ?? image.src).toString(),
                    fit: BoxFit.contain,
                    semanticLabel: image.alt.isEmpty ? l10n.remoteForumImage : image.alt,
                    errorBuilder: (_, _, _) => const Icon(AppIcons.imageBroken, color: Colors.white54, size: 40),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: padding.top + 6,
            left: 12 + padding.left,
            right: 12 + padding.right,
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.commonClose,
                  onPressed: () => Navigator.of(context).maybePop(),
                  style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.14)),
                  icon: const Icon(AppIcons.close, color: Colors.white),
                ),
                if (_images.length > 1) ...[
                  const SizedBox(width: 12),
                  Text(l10n.mediaPageOf(_index + 1, _images.length), style: const TextStyle(color: Colors.white)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Share codes ──────────────────────────────────────────────────────────────

/// A dsh-go share link inside a post: what it is and a one-tap 「安装」.
class ForumShareCard extends ConsumerWidget {
  const ForumShareCard({super.key, required this.link, this.label});

  final ShareLink link;
  final String? label;

  static const glyphSize = 40.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final summary = summarizeShareLink(link, label: label);
    final tint = summary.kind == ShareKind.plugin ? 3 : 6;
    final subtitle = [summary.kindLabel, ?summary.detail].join(' · ');
    Future<void> install() async {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final ok = await ref.read(forumShareInstallerProvider)(link);
      if (!ok) messenger?.showSnackBar(SnackBar(content: Text(l10n.remoteForumErrShareCode)));
    }

    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                color: colors.identity[tint],
                shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusSm),
              ),
              child: SizedBox.square(
                dimension: glyphSize,
                child: Icon(
                  summary.kind == ShareKind.plugin ? AppIcons.plugin : AppIcons.configure,
                  size: 22,
                  color: colors.onIdentity[tint],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(summary.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: install,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                visualDensity: VisualDensity.compact,
                shape: const StadiumBorder(),
              ),
              child: Text(l10n.commonInstall),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Details, polls, videos ───────────────────────────────────────────────────

class _DetailsBlock extends StatefulWidget {
  const _DetailsBlock({required this.details, this.onOpenTopic});

  final CookedDetails details;
  final void Function(int topicId, int? postNumber)? onOpenTopic;

  @override
  State<_DetailsBlock> createState() => _DetailsBlockState();
}

class _DetailsBlockState extends State<_DetailsBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: AppShape.radiusSm,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: AppMotion.of(context, AppMotion.quick),
                  child: Icon(AppIcons.disclosure, size: 20, color: colors.textTertiary),
                ),
                const SizedBox(width: 4),
                Expanded(child: Text(widget.details.summary, style: theme.textTheme.titleSmall)),
              ],
            ),
          ),
        ),
        ExpandReveal(
          open: _open,
          child: Padding(
            padding: const EdgeInsets.only(left: 24, top: 6),
            child: ForumBlocks(blocks: widget.details.body, onOpenTopic: widget.onOpenTopic),
          ),
        ),
      ],
    );
  }
}

class _EmbedRow extends StatelessWidget {
  const _EmbedRow({required this.embed, this.fallback});

  final CookedEmbed embed;
  final Uri? fallback;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final (icon, label) = switch (embed.kind) {
      CookedEmbedKind.poll => (AppIcons.poll, embed.label ?? l10n.remoteForumPoll),
      CookedEmbedKind.video => (AppIcons.playVideo, embed.label ?? l10n.remoteForumVideo),
      CookedEmbedKind.other => (AppIcons.openExternal, embed.label ?? l10n.remoteForumEmbed),
    };
    final url = embed.url ?? fallback;
    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusMd,
      onTap: url == null ? null : () => unawaited(openForumLink(url)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            ),
            Text(
              embed.kind == CookedEmbedKind.poll ? l10n.remoteForumVoteOnWeb : l10n.commonOpen,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
