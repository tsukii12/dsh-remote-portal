// The share panel's pages: the first one (what to share, then where it goes),
// 「链接」 and 「文件」. 「图片」 is share_image_page.dart; 「选中消息」 the message
// picker. docs/design/share-redesign.md §4.
//
//   分享
//   (( 这条回复 )  选中消息   整段对话 )
//   (✓ 思考过程) (✓ 工具调用) (✓ 图片)
//   [ card ]
//   ⛨ 2 条消息 · 3 次工具调用 · 密钥已隐藏          调整
//     (链接)    (图片)    (文件)    (文字)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_share.dart' show DecodedConversation, maxConversationFileBytes;
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_navigator.dart';
import '../replay/conversation_out.dart';
import '../replay/replay_page.dart' show openConversationReplay;
import '../session/workspace_files.dart' show formatBytes;
import '../share_code/share_code_panel.dart' show ShareQrPage;
import '../share_code/share_code_widgets.dart';
import '../share_hosted/hosted_links_page.dart' show linkExpiryText;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'share_image_page.dart';
import 'share_panel.dart';
import 'share_picker.dart';

/// The first page: scope, what it includes, the card, then the ways out.
class SharePanelHome extends StatelessWidget {
  const SharePanelHome({super.key});

  void _pick(BuildContext context, SharePanelModel model) {
    final navigator = SheetNavigator.of(context);
    navigator.push(
      (_) => MessagePicker(
        items: model.shareable,
        selected: model.pickStart,
        onDone: (keys) {
          model.pick(keys);
          navigator.pop();
        },
      ),
    );
  }

  void _open(BuildContext context, WidgetBuilder page) {
    final model = SharePanelScope.of(context);
    model.clearError();
    SheetNavigator.of(context).push(page);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final model = SharePanelScope.of(context);
    final conversation = model.conversation != null;
    final card = model.card;
    final ready = card != null;
    final privacy = model.privacy;
    final top = <Widget>[
      if (conversation && model.scopes.length > 1)
        SegmentedPill<ShareScope>(
          key: const ValueKey('share-scope'),
          segments: [for (final s in model.scopes) PillSegment(s, s.label)],
          selected: model.scope,
          onChanged: (scope) => scope == ShareScope.picked ? _pick(context, model) : model.setScope(scope),
        ),
      if (conversation) ...[
        const SizedBox(height: 12),
        Wrap(
          key: const ValueKey('share-privacy'),
          spacing: 8,
          runSpacing: 8,
          children: [
            ShareToggle(
              label: l10n.viewShareThinking,
              selected: privacy.thinking,
              onSelected: () => model.setPrivacy(privacy.copyWith(thinking: !privacy.thinking)),
            ),
            ShareToggle(
              label: l10n.viewShareIncludeTools,
              selected: privacy.tools,
              onSelected: () => model.setPrivacy(privacy.copyWith(tools: !privacy.tools)),
            ),
            ShareToggle(
              label: l10n.viewShareImages,
              selected: privacy.images,
              onSelected: () => model.setPrivacy(privacy.copyWith(images: !privacy.images)),
            ),
          ],
        ),
      ],
    ];
    final Widget preview;
    if (card != null) {
      preview = ListenableBuilder(
        listenable: model.style,
        builder: (context, _) => ShareCardPreview(card: model.style.card(context, card)),
      );
    } else {
      preview = _Placeholder(empty: model.isEmpty);
    }
    final destinations = ShareActionRow(
      key: const ValueKey('share-destinations'),
      actions: [
        if (model.linkMaker != null)
          ShareAction(
            key: const ValueKey('share-to-link'),
            icon: AppIcons.link,
            label: l10n.viewShareLink,
            onTap: ready ? () => _open(context, (_) => const ShareLinkPage()) : null,
          ),
        ShareAction(
          key: const ValueKey('share-to-image'),
          icon: AppIcons.shareImage,
          label: l10n.viewShareAsImage,
          onTap: ready
              ? () => _open(
                  context,
                  (_) => ShareImagePage(content: model.card!, style: model.style, refine: model.artifact?.refine),
                )
              : null,
        ),
        ShareAction(
          key: const ValueKey('share-to-file'),
          icon: AppIcons.shareFile,
          label: l10n.viewShareAsFile,
          onTap: ready ? () => _open(context, (_) => const ShareFilePage()) : null,
        ),
        if (conversation)
          ShareAction(
            key: const ValueKey('share-to-text'),
            icon: AppIcons.shareText,
            label: l10n.viewShareAsText,
            busy: model.work == ShareWork.text,
            onTap: ready ? model.shareText : null,
          ),
      ],
    );
    return SharePageLayout(
      title: l10n.commonShare,
      top: top,
      preview: preview,
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready) _Summary(onAdjust: model.scope == ShareScope.picked ? () => _pick(context, model) : null),
          if (model.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                key: const ValueKey('share-status'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
              ),
            ),
          const SizedBox(height: 12),
          destinations,
        ],
      ),
    );
  }
}

/// While the conversation arrives, or when it has nothing to share.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.empty});

  final bool empty;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return SizedBox(
      height: 240,
      child: Center(
        child: empty
            ? Text(
                context.l10n.viewShareEmpty,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
              )
            : SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: colors.textTertiary),
              ),
      ),
    );
  }
}

/// 「⛨ 2 条消息 · 3 次工具调用 · 密钥已隐藏  调整」: what goes out, in one
/// line; a file's kind and size for a delivered file.
class _Summary extends StatelessWidget {
  const _Summary({this.onAdjust});

  final VoidCallback? onAdjust;

  /// The row's height: the 「调整」 button's, so the row keeps its place when
  /// the button comes and goes.
  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final model = SharePanelScope.of(context);
    final style = AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary));
    final String text;
    final IconData icon;
    if (model.artifact case final a?) {
      icon = AppIcons.shareFile;
      text = [a.artifact.typeLabel, if (a.artifact.bytes case final b?) formatBytes(b)].join(' · ');
    } else {
      final counts = model.counts;
      icon = AppIcons.redacted;
      text = [
        l10n.viewShareMessageCount(counts.messages),
        if (counts.tools > 0) l10n.viewShareToolCount(counts.tools),
        if (counts.images > 0) l10n.viewImageCount(counts.images),
        l10n.viewShareRedacted,
      ].join(' · ');
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: height),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: model.historyLoading
                ? Padding(
                    padding: const EdgeInsets.all(2),
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      strokeCap: StrokeCap.round,
                      color: colors.textTertiary,
                    ),
                  )
                : Icon(icon, size: 16, color: colors.textTertiary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, key: const ValueKey('share-summary'), style: style),
          ),
          if (onAdjust case final onAdjust?)
            TextButton(
              key: const ValueKey('share-adjust'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, height),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onAdjust,
              child: Text(l10n.viewShareAdjust),
            ),
        ],
      ),
    );
  }
}

/// 「预览」: the replay the receiver gets (no 「接着聊」).
void _previewReplay(BuildContext context, ShareBuild built) =>
    unawaited(openConversationReplay(context, DecodedConversation(built.share, built.assets, code: ''), preview: true));

/// What goes out as a file: its name, its size, and 「预览」 when it replays.
class _FileTile extends StatelessWidget {
  const _FileTile({required this.name, this.size, this.onPreview});

  final String name;
  final String? size;
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) => SheetGroup(
    margin: EdgeInsets.zero,
    children: [
      ListPageRow(
        key: const ValueKey('share-file-row'),
        icon: AppIcons.shareFile,
        title: name,
        titleMaxLines: 2,
        subtitle: size,
        trailing: onPreview == null
            ? null
            : TextButton(
                key: const ValueKey('share-preview-replay'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: onPreview,
                child: Text(context.l10n.viewSharePreview),
              ),
      ),
    ],
  );
}

// ── 链接 ───────────────────────────────────────────────────────────────────

/// 「链接」: how long it lives, then the link and what to do with it.
///
/// ```
/// ‹ 链接
/// (  7 天  (( 30 天 ))  永久  )
/// 🔒 端到端加密，服务器看不到内容
/// ┌ 🔗 go.dshtui.com/c/a1B2c3D4e5 · 11 月 24 日到期 ┐
/// (复制链接) (二维码) (分享) (停止分享)       or  [ 生成链接 ]
///               我的分享链接
/// ```
class ShareLinkPage extends StatefulWidget {
  const ShareLinkPage({super.key});

  @override
  State<ShareLinkPage> createState() => _ShareLinkPageState();
}

class _ShareLinkPageState extends State<ShareLinkPage> {
  bool _copied = false;
  Timer? _copiedReset;
  late final SharePanelModel _model = SharePanelScope.of(context);

  @override
  void initState() {
    super.initState();
    // The size (and whether it fits) shows before the link is made.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_model.prepare());
    });
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    HapticFeedback.lightImpact();
    await _model.copyLink();
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _qr(SharePanelModel model) {
    final link = model.link;
    final built = model.built;
    if (link == null || built == null) return;
    SheetNavigator.of(context).push((_) => ShareQrPage(link: '${link.url}', title: built.share.title));
  }

  Future<void> _stop(SharePanelModel model) async {
    final l10n = context.l10n;
    final title = model.built?.share.title ?? '';
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.viewShareStopTitle),
        content: Text(l10n.remoteHostedDeleteBody(title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            key: const ValueKey('share-link-stop-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.viewShareStop),
          ),
        ],
      ),
    );
    if (ok == true) await model.stopLink();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final model = SharePanelScope.of(context);
    final link = model.link;
    final stopped = model.stopped;
    final built = model.built;
    final busy = model.work == ShareWork.link;
    final tooLarge = built?.tooLarge ?? false;
    final top = <Widget>[
      SegmentedPill<LinkExpiry>(
        key: const ValueKey('share-link-expiry'),
        segments: [for (final e in LinkExpiry.values) PillSegment(e, e.label)],
        selected: model.expiry,
        onChanged: busy ? null : (e) => model.expiry = e,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        child: Row(
          children: [
            Icon(AppIcons.lock, size: 14, color: colors.textTertiary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.viewShareLinkHint,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (link != null)
        SheetGroup(
          margin: EdgeInsets.zero,
          children: [
            ListPageRow(
              key: const ValueKey('share-link-row'),
              icon: AppIcons.link,
              title: link.display,
              // Large text on a narrow phone: the address wraps, never cut.
              titleMaxLines: 4,
              titleStyle: AppType.mono(size: 14, color: theme.colorScheme.onSurface),
              subtitle: linkExpiryText(link.expiresAt, model.now()),
            ),
          ],
        )
      else if (stopped != null)
        SheetGroup(
          margin: EdgeInsets.zero,
          children: [
            ListPageRow(
              key: const ValueKey('share-link-stopped'),
              icon: AppIcons.stopSharing,
              iconColor: colors.textTertiary,
              title: l10n.viewShareStopped,
              trailing: TextButton(
                key: const ValueKey('share-link-restore'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: model.restoreLink,
                child: Text(l10n.remoteUndo),
              ),
            ),
          ],
        )
      else
        _FileTile(
          name: built?.share.title ?? model.chat.title ?? '',
          size: built == null ? null : formatBytes(built.file.bytes),
          onPreview: built == null ? null : () => _previewReplay(context, built),
        ),
    ];
    final Widget action;
    if (link == null) {
      action = FilledButton(
        key: const ValueKey('share-link-make'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(ShareActionBar.height)),
        onPressed: busy || tooLarge || built == null ? null : model.makeLink,
        child: busy
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  strokeCap: StrokeCap.round,
                  color: theme.colorScheme.onPrimary,
                ),
              )
            : Text(l10n.viewShareCreateLink),
      );
    } else {
      action = ShareActionRow(
        actions: [
          ShareAction(
            key: const ValueKey('share-link-copy'),
            icon: AppIcons.link,
            label: _copied ? l10n.commonCopied : l10n.commonCopyLink,
            done: _copied,
            onTap: _copy,
          ),
          ShareAction(
            key: const ValueKey('share-link-qr'),
            icon: AppIcons.qrCode,
            label: l10n.viewQrCode,
            onTap: () => _qr(model),
          ),
          ShareAction(
            key: const ValueKey('share-link-share'),
            icon: AppIcons.share,
            label: l10n.commonShare,
            onTap: model.shareLink,
          ),
          ShareAction(
            key: const ValueKey('share-link-stop'),
            icon: AppIcons.stopSharing,
            label: l10n.viewShareStop,
            onTap: () => _stop(model),
          ),
        ],
      );
    }
    final String? error =
        model.error ?? (tooLarge ? l10n.viewShareTooLarge(maxConversationFileBytes ~/ (1024 * 1024)) : null);
    return SharePageLayout(
      title: l10n.viewShareLink,
      top: top,
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShareStatusBar(error: error, child: action),
          const SizedBox(height: 4),
          const Center(child: ManageLinksButton()),
        ],
      ),
    );
  }
}

// ── 文件 ───────────────────────────────────────────────────────────────────

/// 「文件」: a conversation as a dsh-go file, a web page or Markdown; a
/// delivered file as itself. Then 「保存」 / 「分享」.
class ShareFilePage extends StatefulWidget {
  const ShareFilePage({super.key});

  @override
  State<ShareFilePage> createState() => _ShareFilePageState();
}

class _ShareFilePageState extends State<ShareFilePage> {
  late final SharePanelModel _model = SharePanelScope.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _model.conversation != null) unawaited(_model.prepare());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final model = SharePanelScope.of(context);
    final artifact = model.artifact;
    final built = model.built;
    final format = model.format;
    final String name;
    final String? size;
    final String? hint;
    if (artifact != null) {
      name = artifact.artifact.name;
      size = [artifact.artifact.typeLabel, if (artifact.artifact.bytes case final b?) formatBytes(b)].join(' · ');
      hint = null;
    } else {
      name = ConversationOut.fileName(built?.share.title ?? model.chat.title ?? '', format);
      size = built == null ? null : formatBytes(built.of(format).bytes);
      hint = switch (format) {
        ConversationFormat.file => l10n.viewShareFileHint,
        ConversationFormat.page => l10n.viewShareWebHint,
        ConversationFormat.markdown => l10n.viewShareMarkdownHint,
      };
    }
    final top = <Widget>[
      if (artifact == null) ...[
        SegmentedPill<ConversationFormat>(
          key: const ValueKey('share-file-format'),
          segments: [
            PillSegment(ConversationFormat.file, l10n.viewShareChatFile),
            PillSegment(ConversationFormat.page, l10n.viewShareWebPage),
            PillSegment(ConversationFormat.markdown, 'Markdown'),
          ],
          selected: format,
          onChanged: model.work == null ? (f) => model.format = f : null,
        ),
        const SizedBox(height: 16),
      ],
      _FileTile(
        name: name,
        size: size,
        onPreview: built == null || !format.carriesFile || artifact != null
            ? null
            : () => _previewReplay(context, built),
      ),
      if (hint != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
          child: Text(
            hint,
            key: const ValueKey('share-file-hint'),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ),
    ];
    final ready = artifact != null || built != null;
    final idle = ready && !model.fileTooLarge;
    final progress = model.progress;
    final String? error =
        model.error ??
        (model.fileTooLarge ? l10n.viewShareTooLarge(maxConversationFileBytes ~/ (1024 * 1024)) : null);
    return SharePageLayout(
      title: l10n.viewShareAsFile,
      top: top,
      bottom: ShareStatusBar(
        error: error,
        status: progress == null || model.work == null ? null : l10n.chatDownloadingPercent((progress * 100).round()),
        child: ShareActionBar(
          saveKey: const ValueKey('share-file-save'),
          shareKey: const ValueKey('share-file-send'),
          saveLabel: l10n.commonSave,
          saved: model.fileSaved,
          busy: switch (model.work) {
            ShareWork.saving => ShareActionBusy.saving,
            ShareWork.sharing => ShareActionBusy.sharing,
            _ => null,
          },
          onSave: idle ? model.saveFile : null,
          onShare: idle ? model.shareFile : null,
        ),
      ),
    );
  }
}
