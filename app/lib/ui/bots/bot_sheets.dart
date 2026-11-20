// Small sheets the Bot pages share: edit one text, pick Bots, confirm a
// deletion.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';

/// Edits one text in a sheet; the new text, or null when closed.
Future<String?> showTextEditSheet(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  int? maxLength,
  bool multiline = false,
  String? action,
  bool allowEmpty = false,
}) {
  return showAppSheet<String>(
    context,
    dismissal: SheetDismissal.button,
    isScrollControlled: true,
    builder: (sheet) => _TextEditSheet(
      title: title,
      initial: initial,
      hint: hint,
      maxLength: maxLength,
      multiline: multiline,
      action: action ?? context.l10n.commonSave,
      allowEmpty: allowEmpty,
    ),
  );
}

class _TextEditSheet extends StatefulWidget {
  const _TextEditSheet({
    required this.title,
    required this.initial,
    required this.hint,
    required this.maxLength,
    required this.multiline,
    required this.action,
    required this.allowEmpty,
  });

  final String title;
  final String initial;
  final String? hint;
  final int? maxLength;
  final bool multiline;
  final String action;
  final bool allowEmpty;

  @override
  State<_TextEditSheet> createState() => _TextEditSheetState();
}

class _TextEditSheetState extends State<_TextEditSheet> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = widget.allowEmpty || _controller.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(widget.title),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLength: widget.maxLength,
                minLines: widget.multiline ? 3 : 1,
                maxLines: widget.multiline ? 8 : 1,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: widget.hint),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 12, SheetTitleBar.inset, 16),
              child: FilledButton(
                onPressed: ok ? () => Navigator.of(context).pop(_controller.text.trim()) : null,
                child: Text(widget.action),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks Bots from [bots]: several, or one when [single].
Future<List<String>?> showBotPickerSheet(
  BuildContext context, {
  required String title,
  required List<DsBot> bots,
  List<String> selected = const [],
  bool single = false,
  String? action,
  int min = 1,
}) {
  return showAppSheet<List<String>>(
    context,
    dismissal: single ? SheetDismissal.drag : SheetDismissal.button,
    isScrollControlled: true,
    builder: (sheet) => _BotPickerSheet(
      title: title,
      bots: bots,
      initial: selected,
      single: single,
      action: action ?? context.l10n.commonDone,
      min: min,
    ),
  );
}

class _BotPickerSheet extends StatefulWidget {
  const _BotPickerSheet({
    required this.title,
    required this.bots,
    required this.initial,
    required this.single,
    required this.action,
    required this.min,
  });

  final String title;
  final List<DsBot> bots;
  final List<String> initial;
  final bool single;
  final String action;
  final int min;

  @override
  State<_BotPickerSheet> createState() => _BotPickerSheetState();
}

class _BotPickerSheetState extends State<_BotPickerSheet> {
  late final Set<String> _picked = {...widget.initial};

  void _toggle(String id) {
    if (widget.single) {
      Navigator.of(context).pop([id]);
      return;
    }
    setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(widget.title),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  SheetGroup(
                    children: [
                      for (final bot in widget.bots)
                        InkWell(
                          key: ValueKey('pick-${bot.id}'),
                          onTap: () => _toggle(bot.id),
                          child: SizedBox(
                            height: 56,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                children: [
                                  BotAvatar(bot: bot, size: 32),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      bot.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15),
                                    ),
                                  ),
                                  if (!widget.single)
                                    Icon(
                                      _picked.contains(bot.id) ? AppIcons.radioOn : AppIcons.radioOff,
                                      size: 22,
                                      color: _picked.contains(bot.id)
                                          ? theme.colorScheme.primary
                                          : DshColors.of(context).textTertiary,
                                    )
                                  else if (_picked.contains(bot.id))
                                    Icon(AppIcons.selected, size: 20, color: theme.colorScheme.primary),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (!widget.single)
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 12, SheetTitleBar.inset, 16),
                child: FilledButton(
                  onPressed: _picked.length >= widget.min ? () => Navigator.of(context).pop(_picked.toList()) : null,
                  child: Text(widget.action),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「删除…？」 with a red confirm; true when confirmed.
Future<bool> confirmDelete(BuildContext context, {required String title, required String body}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(context.l10n.commonDelete),
        ),
      ],
    ),
  );
  return ok ?? false;
}
