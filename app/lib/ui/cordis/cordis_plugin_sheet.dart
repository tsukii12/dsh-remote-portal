// One dynamic plugin (a row of the official Cordis panel): what it is, its
// state, and what can be done from the phone — open its panel in DSH Web,
// stop it, remove it. Running a version with an interface, and answering a
// run request, happen in DSH Web: the official runner executes that code in
// the page.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/cordis_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/expand_reveal.dart';
import '../common/list_page_row.dart';
import '../features/feature_format.dart' show featureErrorText;
import '../plugins/seats/cordis_island_seat.dart';
import '../safe_mode/recovery_actions.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';
import '../common/brief_notice.dart';

Future<void> showCordisPluginSheet(BuildContext context, CordisPlugin plugin) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => CordisPluginSheet(initial: plugin));

/// Opens DSH Web on a target; tests swap it for a recorder. (The same shape
/// as 全部功能's opener, kept here so this sheet doesn't pull in the catalog.)
final cordisWebOpenerProvider = Provider<void Function(BuildContext context, WidgetRef ref, DshWebTarget target)>(
  (ref) =>
      (context, ref, target) => openDshWeb(context, ref, target: target),
);

/// Where 「在网页版打开」 lands: the owning conversation, with the Cordis
/// panel open.
DshWebTarget cordisWebTarget(CordisPlugin plugin) => DshWebTarget(sessionId: plugin.agentId, panel: DshWebPanel.cordis);

/// 「后台和界面」: which halves the shown version has.
String cordisMakeup(CordisPackage package) => switch ((package.hasHostHalf, package.hasClientHalf)) {
  (true, true) => appL10n.catalogCordisHostClient,
  (true, false) => appL10n.catalogCordisHostOnly,
  (false, true) => appL10n.catalogCordisClientOnly,
  _ => '—',
};

enum _Busy { stop, remove }

class CordisPluginSheet extends ConsumerStatefulWidget {
  const CordisPluginSheet({super.key, required this.initial});

  /// The row as the list showed it; the sheet follows the live inventory.
  final CordisPlugin initial;

  @override
  ConsumerState<CordisPluginSheet> createState() => _CordisPluginSheetState();
}

class _CordisPluginSheetState extends ConsumerState<CordisPluginSheet> {
  _Busy? _busy;
  String? _error;
  bool _details = false;

  CordisPlugin get _plugin =>
      ref.read(cordisInventoryProvider).value?.where((p) => p.pluginId == widget.initial.pluginId).firstOrNull ??
      widget.initial;

  DshClient? get _client => ref.read(activeConnectionProvider).value?.client;

  Future<void> _stop() async {
    final client = _client;
    if (client == null || _busy != null) return;
    setState(() {
      _busy = _Busy.stop;
      _error = null;
    });
    try {
      final outcome = await client.stopCordisPlugin(_plugin);
      if (outcome == CordisStopOutcome.missing && mounted) {
        setState(() => _error = appL10n.catalogCordisPluginGone);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = featureErrorText(appL10n.catalogCordisStopFailed, error));
      }
    } finally {
      if (mounted) {
        ref.invalidate(cordisInventoryProvider);
        setState(() => _busy = null);
      }
    }
  }

  Future<void> _remove() async {
    final client = _client;
    if (client == null || _busy != null) return;
    final plugin = _plugin;
    final versions = plugin.packages.length;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) {
        final l10n = dialog.l10n;
        return AlertDialog(
          title: Text(l10n.catalogCordisRemoveTitle(plugin.name)),
          content: Text(versions > 1 ? l10n.catalogCordisRemoveVersions(versions) : l10n.catalogCordisRemoveOne),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: DshColors.of(dialog).danger,
                foregroundColor: DshColors.of(dialog).onDanger,
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l10n.catalogCordisRemove),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = _Busy.remove;
      _error = null;
    });
    try {
      await client.removeCordisPlugin(plugin);
      ref.invalidate(cordisInventoryProvider);
      navigator.pop();
      messenger?.showBriefNotice(appL10n.catalogCordisRemoved);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = null;
          _error = featureErrorText(appL10n.catalogCordisRemoveFailed, error);
        });
      }
    }
  }

  void _open() => ref.read(cordisWebOpenerProvider)(context, ref, cordisWebTarget(_plugin));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    ref.watch(cordisInventoryProvider);
    final plugin = _plugin;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final status = plugin.status;
    final failure = plugin.failure;
    final session = ref.watch(sessionsProvider).value?.where((s) => s.sessionId == plugin.agentId).firstOrNull;
    final sessionTitle = session?.title?.trim();
    final shown = plugin.shown;
    final idle = _busy == null;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(plugin.name),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (plugin.purpose.isNotEmpty) ...[
                    Text(plugin.purpose, style: theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
                    const SizedBox(height: 16),
                  ],
                  if (failure != null) ...[
                    _FailureLine(
                      text: cordisFailureText(failure),
                      detail: failure.message,
                      open: _details,
                      onToggle: () => setState(() => _details = !_details),
                    ),
                    const SizedBox(height: 16),
                  ],
                  ListPageCard(
                    margin: EdgeInsets.zero,
                    children: [
                      ListPageRow(title: l10n.commonStatus, value: cordisStatusLabel(status)),
                      ListPageRow(
                        title: l10n.catalogCordisChat,
                        value: sessionTitle == null || sessionTitle.isEmpty ? l10n.commonUntitledChat : sessionTitle,
                      ),
                      if (plugin.packages.length > 1)
                        ListPageRow(
                          title: l10n.commonVersion,
                          value: l10n.catalogCordisVersionCount(plugin.packages.length),
                        ),
                      if (shown != null) ListPageRow(title: l10n.catalogCordisMakeup, value: cordisMakeup(shown)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // The plugin's interactive region, when it can show here.
                  CordisIslandSeat(plugin: plugin),
                  RecoveryActions(
                    primaryLabel: l10n.commonOpenInWeb,
                    onPrimary: idle ? _open : null,
                    secondary: [
                      (
                        label: _busy == _Busy.stop ? l10n.catalogCordisStopping : l10n.commonStop,
                        onPressed: idle && plugin.running ? () => unawaited(_stop()) : null,
                      ),
                      (
                        label: _busy == _Busy.remove ? l10n.catalogCordisRemoving : l10n.catalogCordisRemove,
                        onPressed: idle ? () => unawaited(_remove()) : null,
                      ),
                    ],
                  ),
                  if (_error case final error?) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What failed, in words, with the Host's own message behind 「详情」.
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.text, required this.detail, required this.open, required this.onToggle});

  final String text;
  final String detail;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The whole line toggles; icon and label sit on the two edges.
        Semantics(
          button: detail.isNotEmpty,
          expanded: detail.isEmpty ? null : open,
          child: InkWell(
            onTap: detail.isEmpty ? null : onToggle,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Icon(AppIcons.error, size: 18, color: colors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger)),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Text(
                      open ? l10n.commonCollapse : l10n.commonDetails,
                      style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        ExpandReveal(
          open: open && detail.isNotEmpty,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(detail, style: AppType.monoSmall(color: colors.textTertiary)),
          ),
        ),
      ],
    );
  }
}
