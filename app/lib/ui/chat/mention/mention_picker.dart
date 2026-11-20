// The `@` picker above the composer, in the same glass popover as the slash
// palette (`../slash_palette.dart`).

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../l10n/l10n.dart';
import '../../common/smooth_size.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../slash_palette.dart';
import 'mention_chip.dart';
import 'mention_controller.dart';

/// 输入框上方的引用面板:和指令面板同一个玻璃浮层、同样的行解剖。
///
/// ```
/// ╭──────────────────────────────────────╮
/// │      文件                             │
/// │ ▤    main.dart                     ↵ │   ← 打了字时,发送会选中第一行
/// │      lib                             │
/// │ ▢    ui/                           › │   ← 文件夹:点行选中,点 › 进入
/// │      子代理 / 对话                    │
/// │ ▭    修复登录问题                      │
/// │      3小时                            │
/// ╰──────────────────────────────────────╯
/// ```
///
/// 分组标题与行文字左对齐;行首图标的中心和 ＋ 键的中心对齐。
class MentionPicker extends StatelessWidget {
  const MentionPicker({super.key, required this.controller});

  final MentionPickerController controller;

  static const _maxHeight = 300.0;

  /// Row text starts here (inset 6 + padding 6 + icon slot 32 + gap 10).
  static const textInset = SlashPalette.rowInset + 6 + 32 + 10;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final sections = controller.sections;
    final query = controller.query;

    final Widget body;
    if (sections.isEmpty) {
      final loading = controller.loading;
      body = Padding(
        padding: const EdgeInsets.fromLTRB(SlashPalette.rowInset + 6, 14, 18, 14),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Center(
                child: loading
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: dsh.textTertiary),
                      )
                    : Icon(AppIcons.noResults, size: 20, color: dsh.textTertiary),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                loading
                    ? l10n.chatMentionSearching
                    : query != null && query.pathOnly
                    ? l10n.chatMentionNoFiles
                    : l10n.chatMentionNoMatches,
                style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
              ),
            ),
          ],
        ),
      );
    } else {
      final rows = <Widget>[];
      var index = 0;
      for (final section in sections) {
        rows.add(_SectionTitle(section.title, first: rows.isEmpty));
        for (final item in section.items) {
          final i = index++;
          rows.add(
            _MentionTile(
              item: item,
              highlighted: i == controller.highlighted,
              onTap: () => controller.pick(item),
              onDrill: item.drillable ? () => controller.drill(item) : null,
            ),
          );
        }
      }
      body = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: SlashPalette.rowInset),
          children: rows,
        ),
      );
    }

    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(SlashPalette.radius)));
    return Semantics(
      container: true,
      label: l10n.chatQuote,
      child: GlassSurface(
        tier: GlassTier.sheet,
        borderRadius: const BorderRadius.all(Radius.circular(SlashPalette.radius)),
        child: Material(
          color: DshSurfaces.of(context).backdropTop.withValues(alpha: 0.94),
          clipBehavior: Clip.antiAlias,
          shape: shape,
          child: SmoothSize(
            duration: AppMotion.of(context, AppMotion.quick),
            curve: AppMotion.std,
            alignment: Alignment.bottomCenter,
            child: body,
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {required this.first});

  final String title;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(MentionPicker.textInset, first ? 12 : 8, 16, 4),
        child: Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary, letterSpacing: 0.2),
        ),
      ),
    );
  }
}

class _MentionTile extends StatelessWidget {
  const _MentionTile({required this.item, required this.highlighted, required this.onTap, this.onDrill});

  final MentionItem item;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback? onDrill;

  static const _shape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(Radius.circular(SlashPalette.radius - SlashPalette.rowInset)),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final detail = item.detail;
    final kind = MentionChip.semanticKind(item.kind);

    final tile = Material(
      type: MaterialType.transparency,
      shape: _shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: _shape,
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.quick),
          decoration: ShapeDecoration(
            color: colors.onSurface.withValues(alpha: highlighted ? 0.06 : 0),
            shape: _shape,
          ),
          constraints: const BoxConstraints(minHeight: 52),
          padding: EdgeInsets.fromLTRB(6, 8, onDrill == null ? 12 : 0, 8),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Icon(
                  item.subagent ? AppIcons.subagents : MentionChip.iconFor(item.kind),
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: colors.onSurface,
                        height: 1.35,
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.35),
                      ),
                  ],
                ),
              ),
              // Sending now picks this row.
              AnimatedOpacity(
                opacity: highlighted ? 1 : 0,
                duration: AppMotion.of(context, AppMotion.quick),
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(AppIcons.enterKey, size: 16, color: dsh.textTertiary),
                ),
              ),
              if (onDrill case final drill?)
                InkResponse(
                  onTap: drill,
                  radius: 20,
                  child: SizedBox(
                    width: 40,
                    height: 36,
                    child: Icon(AppIcons.disclosure, size: 20, color: dsh.textTertiary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: l10n.chatMentionSemantics(kind, item.label),
      hint: detail,
      onTap: onTap,
      customSemanticsActions: onDrill == null ? null : {CustomSemanticsAction(label: l10n.chatOpenFolder): onDrill!},
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SlashPalette.rowInset),
        child: tile,
      ),
    );
  }
}
