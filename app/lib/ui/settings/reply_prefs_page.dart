// 个人偏好: the person's own AGENTS.md in the guest's shared agents root,
// the same file a share-code import replaces.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/guest_fs.dart';
import '../../share_code/share_models.dart';
import '../providers/provider_widgets.dart' show FormBottomBar, FormFieldGroup;
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';

/// The saved text, for the settings row; null without the on-device runtime.
final replyPrefsProvider = FutureProvider.autoDispose<String?>((ref) async {
  final fs = await ref.watch(guestFsProvider.future);
  return fs == null ? null : await fs.readImportedAgentsMd();
});

class ReplyPrefsPage extends ConsumerStatefulWidget {
  const ReplyPrefsPage({super.key});

  @override
  ConsumerState<ReplyPrefsPage> createState() => _ReplyPrefsPageState();
}

class _ReplyPrefsPageState extends ConsumerState<ReplyPrefsPage> {
  final _text = TextEditingController();
  GuestFs? _fs;
  String _saved = '';
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final fs = await ref.read(guestFsProvider.future);
    if (fs == null || !mounted) return;
    final text = await fs.readImportedAgentsMd() ?? '';
    if (!mounted) return;
    setState(() {
      _fs = fs;
      _saved = text;
      _text.text = text;
    });
  }

  Future<void> _save() async {
    final fs = _fs!;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Nothing left: no file, rather than an empty one.
      if (_text.text.trim().isEmpty) {
        await fs.deleteImportedAgentsMd();
      } else {
        await fs.writeImportedAgentsMd(_text.text);
      }
      if (!mounted) return;
      ref.invalidate(replyPrefsProvider);
      showBriefNotice(context, appL10n.commonSaved);
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = appL10n.commonSaveFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final changed = _fs != null && _text.text != _saved;
    return Stack(
      children: [
        AppPage.list(
          title: l10n.pluginsPersonalPreferences,
          subtitle: Text(l10n.pluginsPreferencesDescription),
          children: [
            FormFieldGroup(
              children: [
                TextField(
                  key: const ValueKey('reply-prefs-input'),
                  controller: _text,
                  enabled: _fs != null && !_saving,
                  minLines: 8,
                  maxLines: null,
                  maxLength: ProfileShare.maxAgentsMdChars,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(hintText: l10n.pluginsPreferencesHint, counterText: ''),
                ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                    child: Text(
                      error,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: FormBottomBar.height),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: FormBottomBar(
            child: FilledButton(
              key: const ValueKey('reply-prefs-save'),
              onPressed: changed && !_saving ? _save : null,
              child: Text(_saving ? l10n.pluginsSaving : l10n.commonSave),
            ),
          ),
        ),
      ],
    );
  }
}
