// A Bot's or a group's memory on its details page: the summary, every entry
// (tap to edit or remove), and 「添加记忆」.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_sheets.dart';
import 'bot_action_scope.dart';

/// Entries longer than DS Bot keeps are refused there; the field stops here.
const memoryEntryMax = 300;

class BotMemoryCard extends ConsumerStatefulWidget {
  const BotMemoryCard({super.key, this.botId, this.roomId});

  final String? botId;
  final String? roomId;

  @override
  ConsumerState<BotMemoryCard> createState() => _BotMemoryCardState();
}

typedef _MemoryOwner = ({HostRef host, DsBotApi? api, String? boot, String? botId, String? roomId});

class _BotMemoryCardState extends ConsumerState<BotMemoryCard> {
  String? get botId => widget.botId;
  String? get roomId => widget.roomId;
  _MemoryOwner? _owner;
  DsBotMemoryView? _cached;
  ProviderSubscription<DsBotStatus>? _status;

  _MemoryOwner _ownerOf(DsBotStatus status) => (
    host: status.host,
    api: ref.read(dsBotProvider.notifier).api,
    boot: status.hello?.boot,
    botId: botId,
    roomId: roomId,
  );

  void _discardDifferentOwner(DsBotStatus status) {
    final owner = _ownerOf(status);
    if (!status.ready || _owner != owner) {
      _cached = null;
      _owner = status.ready ? owner : null;
    }
  }

  bool _canAct(_MemoryOwner owner) {
    if (!mounted) return false;
    final status = ref.read(dsBotProvider);
    final memory = ref.read(dsBotMemoryProvider(_key));
    return status.ready &&
        status.readOnly == null &&
        _ownerOf(status) == owner &&
        !memory.isLoading &&
        !memory.hasError;
  }

  @override
  void initState() {
    super.initState();
    // Clear immediately, including transitions that happen between two frames.
    _status = ref.listenManual(dsBotProvider, (_, next) => _discardDifferentOwner(next));
  }

  @override
  void dispose() {
    _status?.close();
    super.dispose();
  }

  ({String? botId, String? roomId}) get _key => (botId: botId, roomId: roomId);

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    BotActionScope scope,
    Future<void> Function(DsBotApi api) call,
  ) async {
    if (!context.mounted || !scope.current(context, ref)) return;
    final api = scope.api!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await call(api);
    } catch (error) {
      if (context.mounted && scope.current(context, ref)) {
        messenger?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    }
    if (context.mounted && scope.current(context, ref)) ref.invalidate(dsBotMemoryProvider(_key));
  }

  Future<void> _open(BuildContext context, WidgetRef ref, DsBotMemoryEntry entry, {required bool canEdit}) async {
    final scope = BotActionScope(ref, botId: botId, roomId: roomId);
    final action = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(context.l10n.botsMemory),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
              child: Text(entry.text, style: Theme.of(sheet).textTheme.bodyLarge),
            ),
            SheetGroup(
              children: [
                if (canEdit)
                  ListPageRow(
                    icon: AppIcons.edit,
                    title: context.l10n.commonEdit,
                    onTap: () => Navigator.pop(sheet, 'edit'),
                  ),
                ListPageRow(
                  icon: AppIcons.delete,
                  title: context.l10n.commonDelete,
                  danger: true,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'delete'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!context.mounted || !scope.current(context, ref) || action == null) return;
    if (action == 'delete') {
      await _run(context, ref, scope, (api) => api.forgetMemory(entry, botId: botId, roomId: roomId));
      return;
    }
    final next = await showTextEditSheet(
      context,
      title: context.l10n.botsEditMemory,
      initial: entry.text,
      maxLength: memoryEntryMax,
      multiline: true,
    );
    if (next == null || next == entry.text || !context.mounted) return;
    await _run(context, ref, scope, (api) => api.editMemory(entry, next, botId: botId, roomId: roomId));
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final scope = BotActionScope(ref, botId: botId, roomId: roomId);
    final text = await showTextEditSheet(
      context,
      title: context.l10n.botsAddMemory,
      hint: roomId == null ? context.l10n.botsMemoryReplyExample : context.l10n.botsMemoryDraftExample,
      maxLength: memoryEntryMax,
      multiline: true,
      action: context.l10n.commonAdd,
    );
    if (text == null || !context.mounted) return;
    await _run(context, ref, scope, (api) => api.addMemory(text, botId: botId, roomId: roomId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final memory = ref.watch(dsBotMemoryProvider(_key));
    final dsh = DshColors.of(context);
    final writable = status.ready && status.readOnly == null;
    final canEdit = writable && status.supports('memory-edit');
    _discardDifferentOwner(status);
    final owner = _ownerOf(status);
    if (status.ready && !memory.isLoading && !memory.hasError) _cached = memory.value;
    final view = status.ready ? _cached : null;
    final canAct = writable && !memory.isLoading && !memory.hasError;
    // Rows waiting on a refresh look disabled; on a read-only host they keep
    // full opacity, like the details page's other read-only rows.
    final rowOpacity = writable && !canAct ? 0.5 : 1.0;
    final updateLabel = memory.hasError
        ? l10n.readListFailed
        : memory.isLoading
        ? l10n.readListUpdating
        : null;
    final entries = view?.entries ?? const <DsBotMemoryEntry>[];
    return ListPageCard(
      title: view == null
          ? l10n.botsMemory
          : '${l10n.botsMemoryCount(entries.length)}${updateLabel == null ? '' : ' · $updateLabel'}',
      children: [
        if (view == null && memory.isLoading)
          const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 20))
        else if (view == null)
          ListPageRow(
            icon: AppIcons.error,
            title: l10n.botsMemoryReadFailed,
            onTap: () => ref.invalidate(dsBotMemoryProvider(_key)),
          )
        else ...[
          if (view.summary case final summary? when summary.trim().isNotEmpty)
            ListPageRow(icon: AppIcons.summary, title: l10n.botsSummary, subtitle: summary.trim(), subtitleMaxLines: 4),
          for (final entry in entries)
            Opacity(
              opacity: rowOpacity,
              child: ListPageRow(
                icon: _scopeIcon(entry.scope),
                title: entry.text,
                titleMaxLines: 3,
                subtitle: _entryMeta(entry),
                chevron: false,
                onTap: canAct
                    ? () {
                        if (_canAct(owner)) _open(context, ref, entry, canEdit: canEdit);
                      }
                    : null,
              ),
            ),
          if (entries.isEmpty) ListPageRow(icon: AppIcons.empty, iconColor: dsh.textTertiary, title: l10n.botsNoMemory),
          if (canEdit)
            Opacity(
              opacity: rowOpacity,
              child: ListPageRow(
                icon: AppIcons.add,
                title: l10n.botsAddMemory,
                chevron: false,
                onTap: canAct
                    ? () {
                        if (_canAct(owner)) _add(context, ref);
                      }
                    : null,
              ),
            ),
          if (memory.hasError)
            ListPageRow(
              icon: AppIcons.error,
              title: l10n.botsMemoryReadFailed,
              onTap: () => ref.invalidate(dsBotMemoryProvider(_key)),
            ),
        ],
      ],
    );
  }
}

IconData _scopeIcon(String scope) => switch (scope) {
  'team' => AppIcons.team,
  'group' => AppIcons.groupChat,
  _ => AppIcons.bookmark,
};

/// 「团队 · 你写的 · 2026-10-24」.
String _entryMeta(DsBotMemoryEntry entry) => [
  switch (entry.scope) {
    'team' => appL10n.botsTeam,
    'group' => appL10n.botsGroupChat,
    _ => appL10n.botsSelf,
  },
  if (entry.by == 'user') appL10n.botsWrittenByYou else if (entry.by case final by? when by.isNotEmpty) by,
  ?entry.added,
].join(' · ');
