// Message actions after DSH Web's `MessageIconActions` (copy, branch).
// The menu every message opens (long-press, or ⋯ in a reply's row) is in
// `message_menu.dart`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../../speech/read_aloud.dart';
import '../../common/bleed.dart';
import '../../common/fluid_bits.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'message_menu.dart';
import '../../common/brief_notice.dart';

export 'message_menu.dart';

/// Copies [text]; [toast] confirms it when nothing else on screen does.
Future<void> copyMessage(BuildContext context, String text, {bool toast = true}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  HapticFeedback.lightImpact();
  await Clipboard.setData(ClipboardData(text: text));
  if (toast) {
    messenger?.showBriefNotice(l10n.commonCopied);
  }
}

/// Quiet icons under the last reply of a turn: copy, share ([onShare], the
/// share panel), 「朗读」 ([onReadAloud]), branch ([onBranch]), 「重新回答」 ([onRegenerate], the
/// conversation's last reply only) and ⋯ ([onMore]), which opens the same
/// menu as a long-press (select, quote…). [trailing] (the turn footnote)
/// sits at the row's right end.
class ReplyActionRow extends StatefulWidget {
  const ReplyActionRow({
    super.key,
    required this.text,
    this.onShare,
    this.onReadAloud,
    this.reading = ReadAloudPhase.idle,
    this.onBranch,
    this.branching = false,
    this.onRegenerate,
    this.regenerating = false,
    this.onMore,
    this.trailing,
  });

  /// What 「复制」 copies, worked out when it is tapped.
  final String Function() text;

  /// 「分享」: the share panel for this reply.
  final VoidCallback? onShare;

  /// 「朗读」: reads this reply aloud, or stops it while [reading].
  final VoidCallback? onReadAloud;

  /// Where reading this reply aloud is: asking for the voice (转圈), or playing (停止键).
  final ReadAloudPhase reading;
  final VoidCallback? onBranch;

  /// 正在分叉:分叉键转圈,不能再点。
  final bool branching;

  /// 「重新回答」; null leaves the key out.
  final VoidCallback? onRegenerate;

  /// 正在准备重新回答(读原图、分叉):重答键转圈,不能再点。
  final bool regenerating;

  /// ⋯: the message menu.
  final VoidCallback? onMore;
  final Widget? trailing;

  @override
  State<ReplyActionRow> createState() => _ReplyActionRowState();
}

class _ReplyActionRowState extends State<ReplyActionRow> {
  bool _copied = false;

  void _copy() {
    copyMessage(context, widget.text(), toast: false);
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final muted = DshColors.of(context).textTertiary;
    // 36 的圆钮、20 的图标:图标四周各 8,和 Bleed 的 8 一起让第一个图标
    // 贴正文左缘、脚注的箭头贴正文右缘。
    final style = IconButton.styleFrom(
      minimumSize: const Size.square(_button),
      maximumSize: const Size.square(_button),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: muted,
      iconSize: 20,
    );
    // 图标原地换(对勾、转圈):淡入并从 0.7 放大。
    Widget swap(Widget child) => AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.quick),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(animation), child: child),
      ),
      child: child,
    );
    // 进行中:原地转圈,键不能再点。
    Widget busyKey(MessageAction action, VoidCallback onTap, bool busy) => IconButton(
      tooltip: action.label,
      onPressed: busy
          ? null
          : () {
              HapticFeedback.lightImpact();
              onTap();
            },
      style: style,
      icon: swap(
        busy
            ? SizedBox.square(
                key: ValueKey('${action.name}-busy'),
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: muted),
              )
            : Icon(action.icon, key: ValueKey(action.name)),
      ),
    );
    final onShare = widget.onShare;
    final onBranch = widget.onBranch;
    final onReadAloud = widget.onReadAloud;
    final reading = widget.reading;
    final onRegenerate = widget.onRegenerate;
    final onMore = widget.onMore;
    final icons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _copied ? l10n.commonCopied : l10n.commonCopy,
          onPressed: _copy,
          style: style.copyWith(foregroundColor: WidgetStatePropertyAll(_copied ? colors.primary : muted)),
          icon: swap(
            _copied && AppMotion.fluid(context)
                ? const DrawnCheck(key: ValueKey(true))
                : Icon(_copied ? AppIcons.done : AppIcons.copy, key: ValueKey(_copied)),
          ),
        ),
        if (onShare != null)
          IconButton(
            key: const ValueKey('reply-share'),
            tooltip: l10n.commonShare,
            onPressed: () {
              HapticFeedback.lightImpact();
              onShare();
            },
            style: style,
            icon: const Icon(AppIcons.share),
          ),
        if (onReadAloud != null)
          IconButton(
            key: const ValueKey('reply-read-aloud'),
            tooltip: reading == ReadAloudPhase.idle ? l10n.speechReadAloud : l10n.speechReadAloudStop,
            onPressed: () {
              HapticFeedback.lightImpact();
              onReadAloud();
            },
            style: style.copyWith(
              foregroundColor: WidgetStatePropertyAll(reading == ReadAloudPhase.idle ? muted : colors.primary),
            ),
            icon: swap(switch (reading) {
              ReadAloudPhase.idle => const Icon(AppIcons.readAloud, key: ValueKey('read-idle')),
              ReadAloudPhase.loading => SizedBox.square(
                key: const ValueKey('read-loading'),
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
              ),
              ReadAloudPhase.playing => const Icon(AppIcons.stop, key: ValueKey('read-playing')),
            }),
          ),
        if (onBranch != null) busyKey(MessageAction.branch, onBranch, widget.branching),
        if (onRegenerate != null) busyKey(MessageAction.regenerate, onRegenerate, widget.regenerating),
        if (onMore != null)
          IconButton(tooltip: l10n.commonMore, onPressed: onMore, style: style, icon: const Icon(AppIcons.more)),
      ],
    );
    final trailing = widget.trailing;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Bleed(
        horizontal: 8,
        child: Row(
          children: [
            icons,
            if (trailing != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: trailing),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static const _button = 36.0;
}
