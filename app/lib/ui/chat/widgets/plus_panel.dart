// The composer's ＋ panel (docs/design/settings-ia.md §4.4, media-generation
// §4.2): the attachment tiles (相册 · 拍照 · 文件, and 生成 where the host can
// generate), then what applies to this conversation (本对话: permissions and
// plan mode) and, while phone control is on, how it confirms.
//
// ```
//                  ───
//  ╭──────╮  ╭──────╮  ╭──────╮  ╭──────╮
//  │ 相册 │  │ 拍照 │  │ 文件 │  │ 生成 │     equal, 8 apart, 16 from the sides
//  ╰──────╯  ╰──────╯  ╰──────╯  ╰──────╯
//   本对话
//  ╭────────────────────────────────────╮   card edges = the tiles' edges
//  │ 权限               工作区内修改  › │
//  │ 计划模式                     [○  ] │
//  ╰────────────────────────────────────╯
// ```

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/connection_state.dart';
import '../../../state/features_state.dart';
import '../../../state/hosts_state.dart';
import '../../../state/session_modes.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../common/sheet_navigator.dart';
import '../../common/sheet_title_bar.dart';
import '../../features/feature_format.dart';
import '../../features/permission_page.dart' show confirmPermission, writePermissionDefault;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Where a picked attachment comes from.
enum AttachSource { gallery, camera, files }

/// What the ＋ panel was closed with.
sealed class PlusChoice {
  const PlusChoice();
}

/// A tile that picks an attachment.
final class AttachChoice extends PlusChoice {
  const AttachChoice(this.source);
  final AttachSource source;
}

/// The panel's measured geometry; `test/chat/plus_panel_test.dart` checks it.
abstract final class PlusPanelMetrics {
  /// Panel edge → first / last tile, and → the cards below.
  static const side = 16.0;

  /// Between tiles.
  static const gap = 8.0;

  /// The tile's coloured square.
  static const square = 60.0;
}

/// The ＋ panel. [files] false (DSH Remote stages no files) leaves 文件 out;
/// [generate] adds 生成; [call] adds 语音通话; [sessionId] adds 本对话 (a new
/// chat has no conversation to set yet).
Future<PlusChoice?> showPlusPanel(BuildContext context, {bool files = true, String? sessionId}) {
  return showAppSheet<PlusChoice>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: SheetNavigator(
          root: (_) => _PlusRoot(files: files, sessionId: sessionId),
        ),
      ),
    ),
  );
}

/// 本对话的权限 on its own (the permission pill above the composer).
Future<void> showPermissionSheet(BuildContext context, String sessionId) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: SheetNavigator(root: (_) => SessionPermissionPage(sessionId: sessionId)),
      ),
    ),
  );
}

class _PlusRoot extends ConsumerWidget {
  const _PlusRoot({required this.files, required this.sessionId});

  final bool files;
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessionId = this.sessionId;
    final tiles = [
      (AttachChoice(AttachSource.gallery), AppIcons.gallery, l10n.chatGallery, 0),
      (AttachChoice(AttachSource.camera), AppIcons.camera, l10n.chatTakePhoto, 2),
      if (files) (AttachChoice(AttachSource.files), AppIcons.files, l10n.chatFile, 4),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PlusPanelMetrics.side, 4, PlusPanelMetrics.side, 0),
          child: Row(
            spacing: PlusPanelMetrics.gap,
            children: [
              for (final (choice, icon, label, tint) in tiles)
                Expanded(
                  child: PlusTile(icon: icon, label: label, tint: tint, onTap: () => Navigator.pop(context, choice)),
                ),
            ],
          ),
        ),
        if (sessionId != null) ...[const SizedBox(height: 16), _ThisChatCard(sessionId: sessionId)],
        const SizedBox(height: 20),
      ],
    );
  }
}

/// One attachment tile: a 60 coloured square and its name, the whole tile
/// the tap target.
class PlusTile extends StatelessWidget {
  const PlusTile({super.key, required this.icon, required this.label, required this.tint, required this.onTap});

  final IconData icon;
  final String label;
  final int tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final bg = colors.identity[tint % colors.identity.length];
    final fg = colors.onIdentity[tint % colors.onIdentity.length];
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: AppShape.card,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: PlusPanelMetrics.square,
                height: PlusPanelMetrics.square,
                decoration: ShapeDecoration(color: bg, shape: Squircle.border(AppShape.lg)),
                child: Icon(icon, size: 26, color: fg),
              ),
              const SizedBox(height: 8),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

/// 本对话: the preset (opens its page) and plan mode.
class _ThisChatCard extends ConsumerStatefulWidget {
  const _ThisChatCard({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_ThisChatCard> createState() => _ThisChatCardState();
}

class _ThisChatCardState extends ConsumerState<_ThisChatCard> {
  /// Asked for and not yet in the log (a switch mid-turn lands at the next
  /// step); null follows the log.
  bool? _plan;
  bool _busy = false;

  Future<void> _togglePlan(bool next) async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _busy = true;
      _plan = next;
    });
    final ok = await ref.read(chatProvider(widget.sessionId).notifier).runCommand(next ? '/plan' : '/plan off');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _plan = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final modes = ref.watch(sessionModesProvider(widget.sessionId));
    if (_plan == modes.plan) _plan = null;
    final plan = _plan ?? modes.plan;
    return ListPageCard(
      title: l10n.nearbyThisChat,
      margin: const EdgeInsets.symmetric(horizontal: PlusPanelMetrics.side),
      children: [
        ListPageRow(
          title: l10n.featuresPermissions,
          value: switch (modes.preset) {
            final preset? => permissionName(preset),
            null => null,
          },
          onTap: () => SheetNavigator.of(context).push((_) => SessionPermissionPage(sessionId: widget.sessionId)),
        ),
        MergeSemantics(
          child: ListPageRow(
            title: l10n.hubSessionPlanMode,
            onTap: _busy ? null : () => unawaited(_togglePlan(!plan)),
            trailing: Switch.adaptive(value: plan, onChanged: _busy ? null : (v) => unawaited(_togglePlan(v))),
          ),
        ),
      ],
    );
  }
}

/// 本对话的权限: the four presets, then what new conversations start with.
class SessionPermissionPage extends ConsumerStatefulWidget {
  const SessionPermissionPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionPermissionPage> createState() => _SessionPermissionPageState();
}

class _SessionPermissionPageState extends ConsumerState<SessionPermissionPage> {
  /// Picked here and not yet in the log.
  String? _picked;
  bool _busy = false;

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _pick(String value, String? current) async {
    if (_busy || value == current) return;
    if (!await confirmPermission(context, value) || !mounted) return;
    setState(() {
      _busy = true;
      _picked = value;
    });
    final ok = await ref.read(chatProvider(widget.sessionId).notifier).runCommand('/permission $value');
    if (!mounted) return;
    ref.invalidate(permissionStateProvider(widget.sessionId));
    setState(() {
      _busy = false;
      if (!ok) _picked = null;
    });
    if (!ok) _toast(context.l10n.featuresSwitchFailed);
  }

  Future<void> _makeDefault(String value, int revision) async {
    final owner = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null || _busy) return;
    if (!await confirmPermission(context, value) || !mounted || ref.read(activeHostProvider) != owner) return;
    setState(() => _busy = true);
    final problem = await writePermissionDefault(client, value, revision);
    if (!mounted) return;
    ref.invalidate(permissionStateProvider(widget.sessionId));
    setState(() => _busy = false);
    if (problem != null) _toast(problem);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final async = ref.watch(permissionStateProvider(widget.sessionId));
    final logged = ref.watch(sessionModesProvider(widget.sessionId)).preset;
    final state = async.value;
    if (_picked != null && _picked == (logged ?? state?.current)) _picked = null;
    final current = _picked ?? logged ?? state?.current;

    final Widget body;
    if (state == null) {
      body = SizedBox(
        height: 160,
        child: Center(
          child: async.hasError
              ? Text(
                  l10n.featuresPermissionsReadFailed,
                  style: theme.textTheme.bodyMedium?.copyWith(color: dsh.textTertiary),
                )
              : const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    } else {
      final defaults = state.defaultOptions ?? state.options.where((o) => o.value != 'auto').toList();
      final revision = state.defaultRevision;
      final canDefault =
          current != null &&
          current != state.hostDefault &&
          revision != null &&
          defaults.any((o) => o.value == current);
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetGroup(
            children: [
              for (final o in state.options)
                Semantics(
                  selected: o.value == current,
                  inMutuallyExclusiveGroup: true,
                  child: ListPageRow(
                    title: permissionName(o.value, o.name),
                    subtitle: permissionHint(o.value, o.description),
                    onTap: _busy ? null : () => unawaited(_pick(o.value, current)),
                    trailing: o.value == current
                        ? Icon(AppIcons.selected, size: 22, color: theme.colorScheme.primary)
                        : o.value == 'danger-full-access'
                        ? Icon(AppIcons.permissionRisky, size: 18, color: dsh.warning)
                        : const SizedBox.square(dimension: 22),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.nearbyNewChatDefault(permissionName(state.hostDefault)),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
          ),
          if (canDefault)
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => unawaited(_makeDefault(current, revision)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.nearbySetAsDefault),
                    const SizedBox(width: 2),
                    const Icon(AppIcons.disclosure, size: 14),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [SheetTitleBar(l10n.nearbyPermissionTitle), body, const SizedBox(height: 16)],
    );
  }
}
