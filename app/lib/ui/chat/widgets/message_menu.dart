// One menu for every message, after DSH Web's `MessageIconActions` (copy,
// branch) with a long-press sheet. Long-press a bubble or a reply,
// or tap ⋯ at the end of a reply's action row: the same sheet. A preview, then
// what you do with this message, then what opens a new conversation (DSH
// forks; the source stays as it is). Pictures in messages get the same sheet
// with the picture as the preview.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../common/app_sheet.dart';
import '../../settings/settings_widgets.dart' show SettingsTile;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../render/markdown_body.dart';
import 'message_actions.dart' show copyMessage;

/// What the message menu offers, in its order. The ones with a [hint] open a
/// new conversation and sit in the second group.
enum MessageAction {
  copy(AppIcons.copy),
  selectText(AppIcons.selectText),
  quote(AppIcons.quote),
  share(AppIcons.share),
  readAloud(AppIcons.readAloud),
  regenerate(AppIcons.regenerate),
  branch(AppIcons.fork),
  edit(AppIcons.edit);

  const MessageAction(this.icon);
  final IconData icon;

  String get label => switch (this) {
    MessageAction.copy => appL10n.commonCopy,
    MessageAction.selectText => appL10n.chatSelectText,
    MessageAction.quote => appL10n.chatQuote,
    MessageAction.share => appL10n.commonShare,
    MessageAction.readAloud => appL10n.speechReadAloud,
    MessageAction.regenerate => appL10n.chatRegenerate,
    MessageAction.branch => appL10n.chatBranchFromHere,
    MessageAction.edit => appL10n.chatEditAndResend,
  };

  String? get hint => switch (this) {
    MessageAction.regenerate => appL10n.chatRegenerateHint,
    MessageAction.branch => appL10n.chatBranchHint,
    MessageAction.edit => appL10n.chatEditResendHint,
    _ => null,
  };

  /// Opens a new conversation (a fork); the second group.
  bool get forks => switch (this) {
    MessageAction.regenerate || MessageAction.branch || MessageAction.edit => true,
    _ => false,
  };
}

/// What the menu of a picture in a message offers.
enum ImageAction {
  save(AppIcons.save),
  share(AppIcons.share);

  const ImageAction(this.icon);
  final IconData icon;

  String get label => switch (this) {
    ImageAction.save => appL10n.chatSaveToPhotos,
    ImageAction.share => appL10n.commonShare,
  };
}

/// The message menu: a short preview of [text], then [actions] in two
/// groups — this message, then the ones that open a new conversation.
/// [actions] keep their [MessageAction] order whatever order they come in.
/// [extra] groups follow under their titles (a plugin's items, under its
/// name); their taps run once the sheet has closed.
Future<MessageAction?> showMessageMenu(
  BuildContext context, {
  required String text,
  required List<MessageAction> actions,
  List<MenuGroup> extra = const [],
}) {
  HapticFeedback.mediumImpact();
  final ordered = [
    for (final action in MessageAction.values)
      if (actions.contains(action)) action,
  ];
  return showAppSheet<MessageAction>(
    context,
    // As tall as the rows need (up to the screen), not the default 9/16:
    // a reply's full menu would otherwise hide its last rows below a scroll.
    isScrollControlled: true,
    builder: (sheet) => MenuSheet(
      preview: MenuTextPreview(text),
      groups: [
        for (final forks in [false, true])
          [
            for (final action in ordered)
              if (action.forks == forks)
                MenuItem(
                  icon: action.icon,
                  label: action.label,
                  hint: action.hint,
                  onTap: () => Navigator.pop(sheet, action),
                ),
          ],
        for (final group in extra)
          [
            for (final item in group.items)
              MenuItem(
                icon: item.icon,
                label: item.label,
                hint: item.hint,
                onTap: () {
                  Navigator.pop(sheet);
                  item.onTap();
                },
              ),
          ],
      ],
      titles: [null, null, for (final group in extra) group.title],
    ),
  );
}

/// The menu of a picture in a message: [image] as the preview, named [name].
Future<ImageAction?> showImageMenu(
  BuildContext context, {
  required ImageProvider image,
  String? name,
  List<ImageAction> actions = ImageAction.values,
}) {
  HapticFeedback.mediumImpact();
  return showAppSheet<ImageAction>(
    context,
    isScrollControlled: true,
    builder: (sheet) => MenuSheet(
      preview: MenuImagePreview(image: image, name: name),
      groups: [
        [
          for (final action in actions)
            MenuItem(icon: action.icon, label: action.label, onTap: () => Navigator.pop(sheet, action)),
        ],
      ],
    ),
  );
}

/// A titled group of rows after a menu's own.
class MenuGroup {
  const MenuGroup({required this.title, required this.items});

  final String title;
  final List<MenuItem> items;
}

/// One row of a [MenuSheet].
class MenuItem {
  const MenuItem({required this.icon, required this.label, required this.onTap, this.hint});

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;
}

/// The sheet every message and picture menu uses: [preview], then each of
/// [groups] as one card (empty groups are skipped). Taller than the screen,
/// it scrolls.
class MenuSheet extends StatelessWidget {
  const MenuSheet({super.key, required this.preview, required this.groups, this.titles = const []});

  final Widget preview;
  final List<List<MenuItem>> groups;

  /// Titles of [groups] by index (none past its end, or null).
  final List<String?> titles;

  /// Left and right of the preview: the card's edge plus 4, where the rows'
  /// own content starts to breathe.
  static const previewInset = kSheetGutter + 4;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(previewInset, 0, previewInset, 10), child: preview),
            for (final (index, group) in groups.indexed)
              if (group.isNotEmpty)
                SheetGroup(
                  title: index < titles.length ? titles[index] : null,
                  children: [
                    for (final item in group)
                      SettingsTile(
                        icon: item.icon,
                        tinted: false,
                        title: item.label,
                        subtitle: item.hint,
                        chevron: false,
                        onTap: item.onTap,
                      ),
                  ],
                ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// A message's first lines, quiet, at the top of its menu.
class MenuTextPreview extends StatelessWidget {
  const MenuTextPreview(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      menuPreview(text),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// A picture's thumbnail and name at the top of its menu.
class MenuImagePreview extends StatelessWidget {
  const MenuImagePreview({super.key, required this.image, this.name});

  final ImageProvider image;
  final String? name;

  static const size = 56.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final placeholder = theme.colorScheme.onSurface.withValues(alpha: 0.06);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Row(
      children: [
        Squircle.clip(
          radius: AppShape.sm,
          child: SizedBox.square(
            dimension: size,
            child: Image(
              image: ResizeImage(image, width: (size * dpr).round(), policy: ResizeImagePolicy.fit),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => ColoredBox(color: placeholder),
              frameBuilder: (context, child, frame, sync) =>
                  frame == null && !sync ? ColoredBox(color: placeholder) : child,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            (name?.trim().isNotEmpty ?? false) ? name!.trim() : l10n.chatImage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// The menu's preview line: Markdown emphasis, code ticks and heading marks
/// dropped, blank lines folded.
String menuPreview(String text) => text
    .replaceAll(RegExp(r'\*\*|__|`+'), '')
    .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\n\s*\n+'), '\n')
    .trim();

/// 「选择文字」: the whole message, freely selectable. Replies render as
/// Markdown ([markdown]), prompts as plain text. With [onQuote], the
/// selection toolbar also offers 「引用」: the sheet closes and the selected
/// passage goes to [onQuote].
Future<void> showSelectTextSheet(
  BuildContext context,
  String text, {
  bool markdown = false,
  ValueChanged<String>? onQuote,
}) {
  return showAppSheet<void>(
    context,
    heightFactor: 0.85,
    builder: (sheet) => _SelectTextSheet(
      text: text,
      markdown: markdown,
      onCopyAll: () {
        Navigator.pop(sheet);
        copyMessage(context, text);
      },
      onQuote: onQuote == null
          ? null
          : (selected) {
              Navigator.pop(sheet);
              onQuote(selected);
            },
    ),
  );
}

class _SelectTextSheet extends StatefulWidget {
  const _SelectTextSheet({required this.text, required this.markdown, required this.onCopyAll, this.onQuote});

  final String text;
  final bool markdown;
  final VoidCallback onCopyAll;
  final ValueChanged<String>? onQuote;

  @override
  State<_SelectTextSheet> createState() => _SelectTextSheetState();
}

class _SelectTextSheetState extends State<_SelectTextSheet> {
  /// What is selected right now (plain text).
  String _selected = '';

  Widget _toolbar(BuildContext context, SelectableRegionState region) {
    final items = [...region.contextMenuButtonItems];
    final onQuote = widget.onQuote;
    final selected = _selected;
    if (onQuote != null && selected.trim().isNotEmpty) {
      final copy = items.indexWhere((item) => item.type == ContextMenuButtonType.copy);
      items.insert(
        copy + 1,
        ContextMenuButtonItem(
          label: MessageAction.quote.label,
          onPressed: () {
            region.hideToolbar();
            onQuote(selected);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: region.contextMenuAnchors, buttonItems: items);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          l10n.chatSelectText,
          actions: [TextButton(onPressed: widget.onCopyAll, child: Text(l10n.chatCopyAll))],
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
            child: SelectionArea(
              onSelectionChanged: (content) => _selected = content?.plainText ?? '',
              contextMenuBuilder: _toolbar,
              child: widget.markdown
                  ? MarkdownBody(text: widget.text, selectable: false)
                  : Text(widget.text, style: AppType.chatBody(context, color: theme.colorScheme.onSurface)),
            ),
          ),
        ),
      ],
    );
  }
}
