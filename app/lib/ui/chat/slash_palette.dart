// The slash palette: the same catalog as DSH Web's "/" menu, Chinese faces
// for the first-party commands, prefix-first filtering.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/commands_state.dart';
import '../common/smooth_size.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The part kept when completing at [caret]. A known token is replaced as a
/// whole, while an unknown token leaves the draft to the right untouched.
({int leading, String suffix}) slashCompletionContext(List<SlashCommand> commands, String text, int caret) {
  final leading = text.length - text.trimLeft().length;
  final full = parseSlashInput(text);
  final end = full != null && resolveSlashCommand(commands, full.token) != null
      ? leading + 1 + full.token.length
      : caret;
  return (leading: leading, suffix: text.substring(end));
}

/// The row's click hint and ChatScreen use the same decision.
bool slashPickInsertsText(SlashCommand command, {required bool hasSuffix}) =>
    hasSuffix ||
    command.kind == SlashCommandKind.skill ||
    (command.kind == SlashCommandKind.host && command.takesInput);

/// 指令面板显示什么。
sealed class PaletteContent {
  const PaletteContent();

  /// 输入框里的内容需要面板吗(以 `/` 开头,且还在打指令名,或者首行的
  /// 已知指令有提示文案、参数还未填写)。
  static PaletteContent? of(List<SlashCommand> commands, String text, {int? caret}) {
    final draft = text;
    if (caret != null) {
      if (caret < 0 || caret > text.length) return null;
      // Text after the cursor may be an existing draft. It must not become
      // part of the command-name filter while inserting a leading slash.
      text = text.substring(0, caret);
    }
    final input = parseSlashInput(text);
    if (input == null) return null;
    if (!input.hasArgs) {
      final completion = slashCompletionContext(commands, draft, caret ?? draft.length);
      return PaletteMatches(
        filterSlashCommands(commands, input.token),
        typed: input.token.isNotEmpty,
        hasSuffix: completion.suffix.isNotEmpty,
      );
    }
    // A hint describes an empty argument on this line. Moving back before an
    // existing argument must not reopen it; name completion above still uses
    // only the prefix so inserting a slash keeps the draft to its right.
    if (input.rest!.trim().isNotEmpty ||
        (caret != null && draft.substring(caret).trim().isNotEmpty) ||
        text.contains('\n') ||
        text.contains('\r')) {
      return null;
    }
    final command = resolveSlashCommand(commands, input.token);
    if (command != null && (command.hint?.trim().isNotEmpty ?? false)) return PaletteHint(command);
    return null;
  }
}

/// 还在打指令名:候选列表(可能为空)。第一行是"发送"会选中的那一条。
final class PaletteMatches extends PaletteContent {
  const PaletteMatches(this.commands, {this.typed = false, this.hasSuffix = false});
  final List<SlashCommand> commands;

  /// Picking must preserve the text after the completed command name.
  final bool hasSuffix;

  /// Part of a name is typed: sending picks the first row, so it is marked.
  /// A bare `/` marks nothing (sending it does nothing).
  final bool typed;
}

/// 指令名已完整、正在输参数:只提示参数格式。
final class PaletteHint extends PaletteContent {
  const PaletteHint(this.command);
  final SlashCommand command;
}

/// 输入框上方的玻璃指令面板:和输入条同宽、同样 28 的圆角,浮在它上方 6。
///
/// ```
/// ╭──────────────────────────────────────╮
/// │ ⊞  压缩  /compact                  ↵ │   ← 打了半个名字时,发送会选中第一行
/// │    压缩以上对话内容,腾出上下文         │
/// │ ⛉  权限  /permission <预设名>          │
/// │    切换权限预设(沙箱模式与审批策略)     │
/// ╰──────────────────────────────────────╯
/// ```
///
/// 行首图标的中心与输入条里 ＋ 键的中心对齐;图标是 20 号线性图标、次要色,
/// 不带底色。
class SlashPalette extends StatelessWidget {
  const SlashPalette({super.key, required this.content, required this.onPick});

  final PaletteContent content;
  final ValueChanged<SlashCommand> onPick;

  static const _rowHeight = 56.0;
  static const _maxRows = 5.5;

  /// The composer's radius; rows inside sit [rowInset] in, so their own
  /// highlight is concentric with it.
  static const radius = AppShape.xl;
  static const rowInset = 6.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);

    final Widget body = switch (content) {
      PaletteMatches(:final commands) when commands.isEmpty => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 18, 14),
        child: Row(
          children: [
            SizedBox(width: 32, child: Icon(AppIcons.noResults, size: 20, color: dsh.textTertiary)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.activitySlashNoMatch,
                style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
              ),
            ),
          ],
        ),
      ),
      PaletteMatches(:final commands, :final typed, :final hasSuffix) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _rowHeight * _maxRows),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: rowInset),
          itemCount: commands.length,
          itemBuilder: (context, i) => _CommandTile(
            command: commands[i],
            highlighted: typed && i == 0,
            hasSuffix: hasSuffix,
            onTap: () => onPick(commands[i]),
          ),
        ),
      ),
      PaletteHint(:final command) => Padding(
        padding: const EdgeInsets.symmetric(vertical: rowInset),
        child: _CommandTile(command: command, showHintOnly: true),
      ),
    };

    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(radius)));
    return Semantics(
      container: true,
      label: l10n.activitySlashCommands,
      child: GlassSurface(
        tier: GlassTier.sheet,
        borderRadius: const BorderRadius.all(Radius.circular(radius)),
        // Popover over live content: near-opaque so rows never read through,
        // even where the device has blur turned off.
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

class _CommandTile extends StatelessWidget {
  const _CommandTile({
    required this.command,
    this.highlighted = false,
    this.showHintOnly = false,
    this.hasSuffix = false,
    this.onTap,
  });

  final SlashCommand command;
  final bool highlighted;
  final bool hasSuffix;

  /// 参数提示态:不可点,描述换成"输入参数后发送"。
  final bool showHintOnly;
  final VoidCallback? onTap;

  static const _shape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(Radius.circular(SlashPalette.radius - SlashPalette.rowInset)),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final hint = command.hint;
    final intent = command.kind == SlashCommandKind.skill
        ? l10n.activitySlashSkillIntent
        : slashPickInsertsText(command, hasSuffix: hasSuffix)
        ? l10n.activitySlashInsertIntent
        : l10n.activitySlashRunIntent;
    final description = showHintOnly
        ? (command.description.isEmpty
              ? l10n.activitySlashEnterArgs
              : l10n.activitySlashDescriptionArgs(command.description))
        : [intent, if (command.description.isNotEmpty) command.description].join(' · ');
    final named = command.label != command.name;

    return Semantics(
      button: onTap != null,
      label: l10n.activitySlashCommandSemantics(command.label, command.name),
      hint: description,
      onTap: onTap,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SlashPalette.rowInset),
        child: Material(
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
              // 6 + 6 + half of 32 = 28: the icon's centre over the ＋ key's.
              padding: const EdgeInsets.fromLTRB(2, 8, 12, 8),
              child: Row(
                children: [
                  SizedBox(width: 32, child: Icon(slashIcon(command), size: 20, color: colors.onSurfaceVariant)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              if (named)
                                TextSpan(
                                  text: '${command.label}  ',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: colors.onSurface,
                                    height: 1.35,
                                  ),
                                ),
                              TextSpan(
                                text: '/${command.name}',
                                style: AppType.monoLabel(color: named ? colors.onSurfaceVariant : colors.onSurface),
                              ),
                              if (hint != null && hint.isNotEmpty)
                                TextSpan(
                                  text: ' $hint',
                                  style: AppType.monoLabel(color: dsh.textTertiary),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (description.isNotEmpty)
                          Text(
                            description,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 指令图标:内置指令各一个,其他(插件)统一用拼图。
IconData slashIcon(SlashCommand command) =>
    command.kind == SlashCommandKind.skill ? AppIcons.skill : slashIconFor(command.name);

IconData slashIconFor(String name) => switch (name) {
  'new' => AppIcons.newChat,
  'model' => AppIcons.model,
  'compact' => AppIcons.compact,
  'permission' => AppIcons.permissions,
  'plan' => AppIcons.plan,
  'goal' => AppIcons.goal,
  'feedback' => AppIcons.feedback,
  'features' => AppIcons.allFeatures,
  _ => AppIcons.plugin,
};
