// Generated pictures full screen (docs/design/media-generation.md §5.4), and a
// plugin gallery's pictures (MediaViewerPage.pictures, plugin-ui-v3 §4.2): black
// in both themes, the batch side by side (swipe; not while zoomed), pinch to
// 8×, double-tap to 2.5×. Top: back and 「2 / 4」 (one picture: its name),
// save and share mirrored on the right, 44 glass keys 12 from the edges. At
// the bottom a glass capsule (52 high, 12 in, at most 400, centred) with the
// actions that apply, all equally wide, and 「AI 生成」 8 above it. A tap on
// the picture hides and shows all of it. Saving and sharing use the file's
// own bytes. A plugin's pictures have no capsule: the plugin's name sits where
// 「AI 生成」 does, and save / share appear only when the bytes are at hand.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/artifacts.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../shell/page_frame.dart' show GlassIconButton;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../artifact_preview.dart' show ArtifactPreviewPage;
import '../dsh_ui/dsh_ui_blocks.dart' show ViewerPicture;
import '../render/markdown_image.dart';
import '../widgets/image_actions.dart';
import '../widgets/image_gallery.dart';
import '../widgets/message_actions.dart' show copyMessage;
import 'media_card.dart';
import 'media_format.dart';
import 'media_image_feedback.dart';

/// The viewer's measured geometry; `test/media/media_card_test.dart` (viewer).
abstract final class MediaViewerMetrics {
  /// Screen edges → keys and capsule.
  static const side = 12.0;

  /// Status bar → the keys.
  static const top = 6.0;
  static const capsuleHeight = 52.0;
  static const capsuleMaxWidth = 400.0;

  /// Capsule → 「AI 生成」.
  static const labelGap = 8.0;
  static const maxScale = ZoomableImage.maxScale;
  static const doubleTapScale = ZoomableImage.doubleTapScale;
}

/// Opens a plugin gallery's [pictures] at [index], under [source] (the
/// plugin's name).
Future<void> openPictureViewer(
  BuildContext context, {
  required List<ViewerPicture> pictures,
  int index = 0,
  String? source,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: AppMotion.of(context, AppMotion.standard),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
      pageBuilder: (context, animation, _) => FadeTransition(
        opacity: animation,
        child: MediaViewerPage.pictures(pictures: pictures, initial: index, source: source),
      ),
    ),
  );
}

/// A plugin gallery's tap (`DshUiPictureViewer` in plugin views and genui
/// cards): its pictures in this viewer.
void openGalleryPictures(BuildContext context, List<ViewerPicture> pictures, int index, String? source) {
  unawaited(openPictureViewer(context, pictures: pictures, index: index, source: source));
}

/// Opens [meta]'s pictures at [index]; the chat's [MediaCardActions] add 编辑.
Future<void> openMediaViewer(
  BuildContext context, {
  required String sessionId,
  required MediaMeta meta,
  int index = 0,
  CachedImageReader? reader,
}) {
  reader ??= ProviderScope.containerOf(context, listen: false).read(workspaceImageReaderProvider);
  final actions = MediaCardActions.maybeOf(context);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: AppMotion.of(context, AppMotion.standard),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
      pageBuilder: (context, animation, _) => FadeTransition(
        opacity: animation,
        child: MediaViewerPage(sessionId: sessionId, meta: meta, initial: index, onEdit: actions?.edit, reader: reader),
      ),
    ),
  );
}

class MediaViewerPage extends ConsumerStatefulWidget {
  const MediaViewerPage({
    super.key,
    required this.sessionId,
    required MediaMeta this.meta,
    this.initial = 0,
    this.onEdit,
    this.reader,
  }) : pictures = null,
       source = null;

  /// A plugin gallery's pictures (no conversation files, no capsule).
  const MediaViewerPage.pictures({super.key, required List<ViewerPicture> this.pictures, this.initial = 0, this.source})
    : sessionId = '',
      meta = null,
      reader = null,
      onEdit = null;

  final String sessionId;
  final CachedImageReader? reader;
  final MediaMeta? meta;
  final List<ViewerPicture>? pictures;

  /// Where [pictures] come from (a plugin's name), in place of 「AI 生成」.
  final String? source;
  final int initial;
  final void Function(MediaMeta meta, MediaItem item)? onEdit;

  @override
  ConsumerState<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends ConsumerState<MediaViewerPage> {
  late int _index = widget.initial.clamp(0, (widget.pictures?.length ?? _items.length) - 1);
  bool _chrome = true;
  // Keep all pages and reloads on the Host that opened this viewer.
  late final CachedImageReader _sourceReader =
      widget.reader ?? ref.read<CachedImageReader>(workspaceImageReaderProvider);

  List<MediaItem> get _items => widget.meta?.items ?? const [];

  Future<Uint8List> _bytes() => mediaItemBytes(ref, widget.sessionId, _items[_index], reader: _sourceReader);

  @override
  Widget build(BuildContext context) {
    if (widget.pictures case final pictures?) return _picturesPage(context, pictures);
    final meta = widget.meta!;
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    final item = _items[_index];
    final title = _items.length > 1 ? l10n.mediaPageOf(_index + 1, _items.length) : item.name;
    final duration = AppMotion.of(context, AppMotion.quick);
    final surfaces = DshSurfaces.of(context);
    final prompt = meta.promptToCopy;
    final onEdit = widget.onEdit;
    final actions = <(IconData, String, VoidCallback)>[
      if (onEdit != null && !item.isVideo)
        (
          AppIcons.mediaEdit,
          l10n.mediaEdit,
          () {
            Navigator.of(context).maybePop();
            onEdit(meta, item);
          },
        ),
      if (prompt != null && prompt.isNotEmpty)
        (AppIcons.copy, l10n.mediaCopyPrompt, () => unawaited(copyMessage(context, prompt))),
      (
        AppIcons.mediaDetails,
        l10n.commonDetails,
        () => unawaited(showMediaDetails(context, sessionId: widget.sessionId, meta: meta, item: item)),
      ),
    ];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: ImagePager(
                initialPage: _index,
                itemCount: _items.length,
                tapWhenZoomed: true,
                onTap: () => setState(() => _chrome = !_chrome),
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _PicturePage(
                  key: ValueKey(_items[i].path),
                  reader: _sourceReader,
                  sessionId: widget.sessionId,
                  item: _items[i],
                  label: meta.prompt,
                ),
              ),
            ),
            Theme(
              data: buildDarkTheme(accent: surfaces.accent, glassBlur: surfaces.blurEnabled),
              child: Builder(
                builder: (context) => IgnorePointer(
                  ignoring: !_chrome,
                  child: AnimatedOpacity(
                    opacity: _chrome ? 1 : 0,
                    duration: duration,
                    curve: AppMotion.std,
                    child: Stack(
                      children: [
                        Positioned(
                          top: padding.top + MediaViewerMetrics.top,
                          left: MediaViewerMetrics.side + padding.left,
                          right: MediaViewerMetrics.side + padding.right,
                          child: Row(
                            children: [
                              GlassIconButton(
                                icon: AppIcons.back,
                                tooltip: l10n.commonBack,
                                grouped: false,
                                onPressed: () => Navigator.of(context).maybePop(),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppType.tabular(
                                    Theme.of(context).textTheme.titleMedium!.copyWith(color: Colors.white),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (!item.isVideo) ...[
                                GallerySaveButton(load: _bytes, name: item.name, grouped: false),
                                const SizedBox(width: 8),
                                GlassIconButton(
                                  icon: AppIcons.share,
                                  tooltip: l10n.commonShare,
                                  grouped: false,
                                  onPressed: () => unawaited(shareImageFile(context, _bytes, name: item.name)),
                                ),
                              ] else
                                GlassIconButton(
                                  icon: AppIcons.openWith,
                                  tooltip: l10n.mediaOpenElsewhere,
                                  grouped: false,
                                  onPressed: () => unawaited(openMediaElsewhere(context, ref, widget.sessionId, item)),
                                ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: MediaViewerMetrics.side + padding.left,
                          right: MediaViewerMetrics.side + padding.right,
                          bottom: math.max(padding.bottom, MediaViewerMetrics.side),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: MediaViewerMetrics.capsuleMaxWidth),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      MediaOverlayLabel(text: l10n.mediaAiGenerated),
                                      const SizedBox(height: MediaViewerMetrics.labelGap),
                                      _ActionCapsule(actions: actions),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _picturesPage(BuildContext context, List<ViewerPicture> pictures) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    final picture = pictures[_index.clamp(0, pictures.length - 1)];
    final title = pictures.length > 1 ? l10n.mediaPageOf(_index + 1, pictures.length) : picture.name;
    final duration = AppMotion.of(context, AppMotion.quick);
    final surfaces = DshSurfaces.of(context);
    final bytes = picture.bytes;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: ImagePager(
                initialPage: _index,
                itemCount: pictures.length,
                tapWhenZoomed: true,
                onTap: () => setState(() => _chrome = !_chrome),
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _PicturePage(
                  key: ValueKey(i),
                  sessionId: '',
                  reader: null,
                  picture: pictures[i],
                  label: pictures[i].label,
                ),
              ),
            ),
            Theme(
              data: buildDarkTheme(accent: surfaces.accent, glassBlur: surfaces.blurEnabled),
              child: Builder(
                builder: (context) => IgnorePointer(
                  ignoring: !_chrome,
                  child: AnimatedOpacity(
                    opacity: _chrome ? 1 : 0,
                    duration: duration,
                    curve: AppMotion.std,
                    child: Stack(
                      children: [
                        Positioned(
                          top: padding.top + MediaViewerMetrics.top,
                          left: MediaViewerMetrics.side + padding.left,
                          right: MediaViewerMetrics.side + padding.right,
                          child: Row(
                            children: [
                              GlassIconButton(
                                icon: AppIcons.back,
                                tooltip: l10n.commonBack,
                                grouped: false,
                                onPressed: () => Navigator.of(context).maybePop(),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppType.tabular(
                                    Theme.of(context).textTheme.titleMedium!.copyWith(color: Colors.white),
                                  ),
                                ),
                              ),
                              if (bytes != null) ...[
                                const SizedBox(width: 12),
                                GallerySaveButton(load: bytes, name: picture.name, grouped: false),
                                const SizedBox(width: 8),
                                GlassIconButton(
                                  icon: AppIcons.share,
                                  tooltip: l10n.commonShare,
                                  grouped: false,
                                  onPressed: () => unawaited(shareImageFile(context, bytes, name: picture.name)),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (widget.source case final source?)
                          Positioned(
                            left: MediaViewerMetrics.side + padding.left,
                            right: MediaViewerMetrics.side + padding.right,
                            bottom: math.max(padding.bottom, MediaViewerMetrics.side),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: MediaViewerMetrics.capsuleMaxWidth),
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: MediaOverlayLabel(text: source),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture's source; the shared pager owns its zoom and drag gestures.
class _PicturePage extends ConsumerStatefulWidget {
  const _PicturePage({super.key, required this.sessionId, required this.reader, this.item, this.picture, this.label});

  final String sessionId;
  final CachedImageReader? reader;

  /// A conversation's file, or [picture].
  final MediaItem? item;
  final ViewerPicture? picture;
  final String? label;

  @override
  ConsumerState<_PicturePage> createState() => _PicturePageState();
}

class _PicturePageState extends ConsumerState<_PicturePage> {
  Future<LoadedImage>? _future;
  CachedImageReader? _reader;
  (String, String?)? _source;
  ImageProvider? _displayProvider;
  int _attempt = 0;

  void _resolve(CachedImageReader? reader) {
    final item = widget.item;
    final path = item == null
        ? null
        : item.isVideo
        ? item.poster
        : item.path;
    final source = (widget.sessionId, path);
    if (identical(_reader, reader) && _source == source) return;
    _reader = reader;
    _source = source;
    _displayProvider = null;
    _future = path == null || reader == null ? null : reader.read(widget.sessionId, path);
  }

  Future<void> _retry() async {
    final reader = _reader;
    final source = _source;
    await _displayProvider?.evict();
    if (!mounted || reader != _reader || source != _source) return;
    if (source case (final sessionId, final path?)) reader?.forget(sessionId, path);
    setState(() {
      _attempt += 1;
      _source = null;
      _future = null;
    });
  }

  Widget _bitmap(ImageProvider provider) {
    _displayProvider = provider;
    return Image(
      key: ValueKey((_reader, _source, _attempt)),
      image: provider,
      fit: BoxFit.contain,
      semanticLabel: widget.label,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) => sync || frame != null
          ? child
          : Stack(fit: StackFit.expand, children: [const MediaImageFeedback(dark: true), child]),
      errorBuilder: (context, error, stack) =>
          MediaImageFeedback(error: imageErrorText(error), onRetry: _retry, dark: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    _resolve(widget.reader);
    final picture = widget.picture;
    return Center(
      child: picture != null
          ? _bitmap(picture.image)
          : FutureBuilder<LoadedImage>(
              key: ValueKey((_reader, _source, _attempt)),
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.data case RasterImage(:final provider)) return _bitmap(provider);
                if (snapshot.hasError || _future == null) {
                  return MediaImageFeedback(
                    error: snapshot.hasError ? imageErrorText(snapshot.error!) : context.l10n.chatImageReadFailed,
                    onRetry: _future == null ? null : _retry,
                    dark: true,
                  );
                }
                return const MediaImageFeedback(dark: true);
              },
            ),
    );
  }
}

/// The bottom capsule: equal items, icon over a word.
class _ActionCapsule extends StatelessWidget {
  const _ActionCapsule({required this.actions});

  final List<(IconData, String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    return SizedBox(
      height: MediaViewerMetrics.capsuleHeight,
      width: double.infinity,
      child: GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: BorderRadius.circular(MediaViewerMetrics.capsuleHeight / 2),
        grouped: false,
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            children: [
              for (final (icon, label, onTap) in actions)
                Expanded(
                  child: Semantics(
                    button: true,
                    label: label,
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: onTap,
                      customBorder: const StadiumBorder(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 20, color: fg),
                          const SizedBox(height: 2),
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(color: fg),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 详情: the description (copyable), then model, size, cost, provenance and
/// the file.
Future<void> showMediaDetails(
  BuildContext context, {
  required String sessionId,
  required MediaMeta meta,
  MediaItem? item,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: MediaDetails(sessionId: sessionId, meta: meta, item: item),
      ),
    ),
  );
}

class MediaDetails extends StatefulWidget {
  const MediaDetails({super.key, required this.sessionId, required this.meta, this.item});

  final String sessionId;
  final MediaMeta meta;
  final MediaItem? item;

  @override
  State<MediaDetails> createState() => _MediaDetailsState();
}

class _MediaDetailsState extends State<MediaDetails> {
  bool _whole = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final meta = widget.meta;
    final item = widget.item;
    final shown = meta.revisedPrompt ?? meta.prompt;
    final provenance = meta.provenance;
    final marks = [
      if (provenance?.c2pa == true) l10n.mediaProvenanceC2pa,
      if (provenance?.implicitLabel == true) l10n.mediaProvenanceImplicit,
      if (provenance?.visibleMark == true) l10n.mediaProvenanceVisible,
    ];
    final cost = mediaCostText(meta.cost);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(l10n.commonDetails),
        if (shown != null && shown.trim().isNotEmpty)
          SheetGroup(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => setState(() => _whole = !_whole),
                      child: Text(
                        shown.trim(),
                        maxLines: _whole ? null : 6,
                        overflow: _whole ? null : TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (meta.revisedPrompt != null && meta.prompt != null && meta.prompt != meta.revisedPrompt) ...[
                      const SizedBox(height: 4),
                      Text(
                        l10n.mediaOriginalPrompt(meta.prompt!.trim()),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => unawaited(copyMessage(context, meta.promptToCopy ?? shown)),
                        child: Text(l10n.mediaCopyPrompt),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        SheetGroup(
          children: [
            if (meta.request.modelName case final model?) ListPageRow(title: l10n.mediaDetailModel, value: model),
            if (item?.width case final w?)
              if (item?.height case final h?) ListPageRow(title: l10n.mediaDetailSize, value: '$w × $h'),
            if (item?.duration case final d?) ListPageRow(title: l10n.mediaParamDuration, value: formatClip(d)),
            ?(cost == null ? null : ListPageRow(title: l10n.mediaDetailCost, value: cost)),
            if (marks.isNotEmpty) ListPageRow(title: l10n.mediaDetailProvenance, value: marks.join(' · ')),
            if (item != null)
              ListPageRow(
                title: l10n.mediaDetailFile,
                value: item.name,
                onTap: () => Navigator.of(context).push(
                  ArtifactPreviewPage.route(
                    sessionId: widget.sessionId,
                    artifact: Artifact(path: item.path, origin: ArtifactOrigin.linked, turn: 0),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
