// 编辑消息 (docs/design/roleplay-ui.md §7): a whole page for one message, so
// a long reply can be read and changed comfortably. Pops the new text, or
// nothing when left unchanged; leaving with changes asks first.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/discard_guard.dart';
import '../providers/provider_widgets.dart';
import '../shell/page_frame.dart';

class TavernMessageEditPage extends StatefulWidget {
  const TavernMessageEditPage({super.key, required this.speaker, required this.text, this.title});

  /// Who said it, shown under the title; or whose text it is.
  final String speaker;
  final String text;

  /// 编辑消息 unless given: the page also edits a preset's texts.
  final String? title;

  static Route<String> route({required String speaker, required String text, String? title}) =>
      MaterialPageRoute<String>(
        builder: (_) => TavernMessageEditPage(speaker: speaker, text: text, title: title),
      );

  @override
  State<TavernMessageEditPage> createState() => _TavernMessageEditPageState();
}

class _TavernMessageEditPageState extends State<TavernMessageEditPage> {
  late final _field = TextEditingController(text: widget.text);
  bool _leaving = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _save() {
    _leaving = true;
    Navigator.of(context).pop(_field.text == widget.text ? null : _field.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return DiscardGuard(
      listenable: _field,
      isDirty: () => !_leaving && _field.text != widget.text,
      child: Stack(
        children: [
          AppPage(
            title: widget.title ?? l10n.tavernEditMessage,
            subtitle: Text(widget.speaker),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, FormBottomBar.height + 8),
                  child: TextField(
                    key: const ValueKey('tavern-message-field'),
                    controller: _field,
                    autofocus: true,
                    maxLines: null,
                    minLines: 12,
                    keyboardType: TextInputType.multiline,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                    decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('tavern-message-save'),
                onPressed: _save,
                child: Text(l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
