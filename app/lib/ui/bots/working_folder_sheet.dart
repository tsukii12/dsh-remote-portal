// Host directory selection uses the existing folders/update endpoints only.
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';
import 'bot_action_scope.dart';

Future<void> showWorkingFolderSheet(
  BuildContext context, {
  String? botId,
  String? roomId,
  String? workDir,
  BotActionScope? scope,
  WidgetRef? ref,
}) {
  if (scope != null && (ref == null || !scope.connected(context, ref))) return Future.value();
  return showAppSheet<void>(
    context,
    dismissal: SheetDismissal.button,
    isScrollControlled: true,
    builder: (_) => WorkingFolderSheet(botId: botId, roomId: roomId, workDir: workDir, scope: scope),
  );
}

class WorkingFolderSheet extends ConsumerStatefulWidget {
  const WorkingFolderSheet({super.key, this.botId, this.roomId, this.workDir, this.scope})
    : assert((botId == null) != (roomId == null));
  final String? botId;
  final String? roomId;
  final String? workDir;
  final BotActionScope? scope;

  @override
  ConsumerState<WorkingFolderSheet> createState() => _WorkingFolderSheetState();
}

class _WorkingFolderSheetState extends ConsumerState<WorkingFolderSheet> {
  late final BotActionScope _scope;
  late String _selected;
  DsBotFolders? _catalog;
  String? _error;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _scope = widget.scope ?? BotActionScope(ref, botId: widget.botId, roomId: widget.roomId);
    _selected = widget.workDir ?? '';
    _load();
  }

  bool get _current {
    if (!mounted || !_scope.connected(context, ref)) return false;
    final status = ref.read(dsBotProvider);
    if (!status.ready) return false;
    final bot = status.team?.bot(widget.botId);
    final room = widget.roomId == null ? null : status.team?.room(widget.roomId!);
    return widget.botId != null
        ? bot != null && bot.workDir == widget.workDir
        : room != null && room.workDir == widget.workDir;
  }

  bool get _writable => _current && _scope.current(context, ref);

  Future<void> _load() async {
    if (_loading || !_current) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await _scope.api!.folders();
      if (_current) setState(() => _catalog = catalog);
    } catch (error) {
      if (_current) setState(() => _error = describeDsBotError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _validChoice =>
      _catalog != null && (_selected.isEmpty || _catalog!.folders.any((folder) => folder.path == _selected));

  String get _defaultLabel =>
      widget.botId != null ? context.l10n.botsFolderTeamDefault : context.l10n.botsFolderRoomDefault;

  Future<void> _save() async {
    if (_saving || !_writable || !_validChoice || _selected == (widget.workDir ?? '')) return;
    final selected = _selected;
    setState(() => _saving = true);
    try {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(context.l10n.botsFolderConfirm),
          content: SingleChildScrollView(
            child: Text(
              selected.isEmpty
                  ? '$_defaultLabel${widget.botId != null && _catalog?.team != null ? '\n${_catalog!.team}' : ''}'
                  : selected,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
            FilledButton(
              key: const ValueKey('folder-confirm'),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(context.l10n.commonSave),
            ),
          ],
        ),
      );
      if (confirmed != true || !_writable) return;
      setState(() => _error = null);
      if (widget.botId != null) {
        await _scope.api!.setBotWorkDir(widget.botId!, selected);
      } else {
        await _scope.api!.setRoomWorkDir(widget.roomId!, selected);
      }
      // The successful write changes workDir; use identity, not the original value.
      if (!mounted || !_scope.connected(context, ref)) return;
      await ref.read(dsBotProvider.notifier).refresh();
      if (mounted && _scope.connected(context, ref)) Navigator.pop(context);
    } catch (error) {
      if (_current) {
        setState(
          () => _error = error is DshRemoteException && error.code == 'bot/refused'
              ? context.l10n.botsFolderRefused
              : describeDsBotError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(dsBotProvider);
    final l10n = context.l10n;
    final current = _current;
    final enabled = _writable && !_saving;
    final paths = <String>{};
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.botsWorkingFolder),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.botsFolderHint),
                  const SizedBox(height: 16),
                  Text(l10n.botsFolderCurrent, style: Theme.of(context).textTheme.titleSmall),
                  SelectableText(widget.workDir ?? _defaultLabel),
                  const SizedBox(height: 12),
                  if (!current)
                    Text(l10n.botsFolderUnavailable, style: TextStyle(color: DshColors.of(context).danger))
                  else ...[
                    if (_loading) const Center(child: CircularProgressIndicator()),
                    if (_catalog != null) ...[
                      RadioGroup<String>(
                        groupValue: _selected,
                        onChanged: (value) {
                          if (enabled && value != null) setState(() => _selected = value);
                        },
                        child: Column(
                          children: [
                            RadioListTile<String>(
                              key: const ValueKey('folder-default'),
                              value: '',
                              enabled: enabled,
                              title: Text(_defaultLabel),
                              subtitle: widget.botId != null && _catalog!.team != null ? Text(_catalog!.team!) : null,
                            ),
                            for (final folder in _catalog!.folders)
                              if (paths.add(folder.path))
                                RadioListTile<String>(
                                  key: ValueKey('folder:${folder.path}'),
                                  value: folder.path,
                                  enabled: enabled,
                                  title: Text(folder.title),
                                  subtitle: Text(folder.path),
                                ),
                          ],
                        ),
                      ),
                      if (_catalog!.folders.isEmpty) Text(l10n.botsFolderNoChoices),
                    ],
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: DshColors.of(context).danger)),
                      if (_catalog == null)
                        TextButton(onPressed: _loading ? null : _load, child: Text(l10n.commonRetry)),
                    ],
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('folder-save'),
                    onPressed: enabled && _validChoice && _selected != (widget.workDir ?? '') ? _save : null,
                    child: Text(l10n.commonSave),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
