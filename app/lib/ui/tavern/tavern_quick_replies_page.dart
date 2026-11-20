// 快速回复: add, change and remove the lines that sit above the composer in
// every tavern chat (tap sends one, long-press puts it in the box to edit).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../common/app_dialog.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class TavernQuickRepliesPage extends ConsumerWidget {
  const TavernQuickRepliesPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernQuickRepliesPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final replies = ref.watch(tavernQuickRepliesProvider);
    final store = ref.read(tavernQuickRepliesProvider.notifier);
    Future<void> add() async {
      final text = await _editReply(context, '');
      if (text != null) await store.add(text);
    }

    return AppPage.list(
      title: l10n.tavernQuickReplies,
      children: [
        if (replies.isEmpty)
          EmptyView(
            icon: AppIcons.reply,
            title: l10n.tavernQuickRepliesEmpty,
            message: l10n.tavernQuickRepliesNote,
            actionLabel: l10n.tavernQuickReplyAdd,
            onAction: () => unawaited(add()),
          )
        else
          SettingsSection(
            footer: Text(l10n.tavernQuickRepliesNote),
            children: [
              for (final (i, reply) in replies.indexed)
                SettingsTile(
                  key: ValueKey('tavern-qr-row-$i'),
                  title: reply,
                  trailing: IconButton(
                    key: ValueKey('tavern-qr-delete-$i'),
                    tooltip: l10n.commonDelete,
                    icon: Icon(AppIcons.delete, size: 18, color: DshColors.of(context).textTertiary),
                    onPressed: () => unawaited(store.removeAt(i)),
                  ),
                  onTap: () async {
                    final text = await _editReply(context, reply);
                    if (text != null) await store.replaceAt(i, text);
                  },
                ),
              SettingsTile(
                key: const ValueKey('tavern-qr-add'),
                icon: AppIcons.add,
                tinted: false,
                title: l10n.tavernQuickReplyAdd,
                chevron: false,
                onTap: () => unawaited(add()),
              ),
            ],
          ),
      ],
    );
  }
}

/// The line as written, or null when cancelled or left blank.
Future<String?> _editReply(BuildContext context, String initial) async {
  final text = await showAppDialog<String>(
    context: context,
    builder: (_) => _ReplyDialog(initial: initial),
  );
  return text == null || text.trim().isEmpty ? null : text;
}

/// Owns its field, so it is let go with the route.
class _ReplyDialog extends StatefulWidget {
  const _ReplyDialog({required this.initial});

  final String initial;

  @override
  State<_ReplyDialog> createState() => _ReplyDialogState();
}

class _ReplyDialogState extends State<_ReplyDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.initial.isEmpty ? l10n.tavernQuickReplyAdd : l10n.commonEdit),
      content: TextField(
        key: const ValueKey('tavern-qr-field'),
        controller: _field,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        decoration: InputDecoration(hintText: l10n.tavernQuickReplyHint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        TextButton(
          key: const ValueKey('tavern-qr-save'),
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
