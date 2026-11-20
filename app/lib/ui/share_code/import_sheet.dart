// The confirm sheet a share code opens — what it is, where it comes from,
// whether it checks out, what would change on the chosen engine (per-item
// switches for a profile), then the install with progress. A profile import
// pins a restore point on the device first, so 安全模式's 「恢复上次正常的配置」 undoes it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/guest_fs.dart';
import '../../share_code/profile_export.dart' show formatShareBytes;
import '../../share_code/share_code_state.dart';
import '../../share_code/share_codec.dart';
import '../../share_code/share_import.dart';
import '../../share_code/share_models.dart';
import '../../share_code/share_net.dart';
import '../../state/engine_control.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/scroll_edge_fade.dart';
import '../common/segmented_pill.dart';
import '../common/status_chip.dart';
import '../plugins/plugin_widgets.dart' show PluginAvatar;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'plugin_share_sheet.dart' show pluginSourceText;
import 'profile_share_sheet.dart' show profileSummary;
import 'share_code_widgets.dart';
import 'share_content_sheet.dart';

/// How the code arrived (the profile's 来源 row).
enum ShareOrigin {
  link,
  file,
  gist;

  String get label => switch (this) {
    ShareOrigin.link => appL10n.pluginsShareLink,
    ShareOrigin.file => appL10n.pluginsFile,
    ShareOrigin.gist => 'GitHub Gist',
  };
}

Future<void> showShareImportSheet(
  BuildContext context,
  SharePayload payload, {
  ShareOrigin origin = ShareOrigin.link,
}) => showAppSheet<void>(
  context,
  heightFactor: payload is ProfileShare ? 0.9 : null,
  isScrollControlled: true,
  builder: (_) => ShareImportSheet(payload: payload, origin: origin),
);

class ShareImportSheet extends ConsumerStatefulWidget {
  const ShareImportSheet({super.key, required this.payload, this.origin = ShareOrigin.link});

  final SharePayload payload;
  final ShareOrigin origin;

  @override
  ConsumerState<ShareImportSheet> createState() => _ShareImportSheetState();
}

enum _Phase { planning, ready, running, done }

class _ShareImportSheetState extends ConsumerState<ShareImportSheet> {
  ImportTarget? _target;
  ImportPlan? _plan;
  Object? _planError;
  int _planSeq = 0;
  Set<String> _selected = {};
  _Phase _phase = _Phase.planning;
  final _steps = <String, StepStatus>{};
  ImportResult? _result;
  bool _restarting = false;

  bool get _isProfile => widget.payload is ProfileShare;

  Future<void> _planFor(ImportTarget target) async {
    final seq = ++_planSeq;
    setState(() {
      _target = target;
      _plan = null;
      _planError = null;
      _phase = _Phase.planning;
    });
    try {
      final fs = target.isLocal ? await ref.read(guestFsProvider.future) : null;
      final plan = await planImport(widget.payload, target, net: ref.read(shareNetProvider), fs: fs);
      if (!mounted || seq != _planSeq) return;
      setState(() {
        _plan = plan;
        _selected = plan.defaultSelection;
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted || seq != _planSeq) return;
      setState(() {
        _planError = e;
        _phase = _Phase.ready;
      });
    }
  }

  Future<void> _run() async {
    final plan = _plan;
    final target = _target;
    if (plan == null || target == null || _phase != _Phase.ready) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final runner = container.read(pluginRunnerFactoryProvider)(container, target);
    final fs = target.isLocal ? await container.read(guestFsProvider.future) : null;
    setState(() {
      _phase = _Phase.running;
      _steps.clear();
    });
    final result = await applyImport(
      plan,
      _selected,
      runner: runner,
      fs: fs,
      onStep: (id, status) {
        if (mounted) setState(() => _steps[id] = status);
      },
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _phase = _Phase.done;
    });
  }

  Future<void> _restart() async {
    if (_restarting) return;
    setState(() => _restarting = true);
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context);
    unawaited(EngineControl.restart(container));
    navigator.pop();
  }

  List<ImportTarget> get _targets => ref.read(importTargetsProvider);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final targets = ref.watch(importTargetsProvider);
    final current = _target;
    if (_phase != _Phase.running && _phase != _Phase.done) {
      final stillThere = current != null && targets.any((t) => identical(t.connection, current.connection));
      if (!stillThere && targets.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && (_target == null || !targets.any((t) => identical(t.connection, _target!.connection)))) {
            unawaited(_planFor(targets.first));
          }
        });
      }
    }
    final title = switch (widget.payload) {
      PluginShare() => l10n.pluginsInstallPlugin,
      ProfileShare() => l10n.pluginsImportProfile,
    };
    final content = <Widget>[
      Padding(padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 12), child: _hero()),
      SheetGroup(children: _facts()),
      if (targets.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 14, kSheetGutter, 6),
          child: SegmentedPill<int>(
            key: const ValueKey('share-import-target'),
            segments: [for (final (i, t) in targets.indexed) PillSegment(i, t.label)],
            selected: current == null
                ? 0
                : targets.indexWhere((t) => identical(t.connection, current.connection)).clamp(0, targets.length - 1),
            onChanged: (i) {
              if (_phase == _Phase.running || _phase == _Phase.done) return;
              unawaited(_planFor(targets[i]));
            },
          ),
        ),
      if (_isProfile) ..._diff(),
    ];
    final footer = SafeArea(
      top: false,
      child: Padding(padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 16), child: _footer(targets)),
    );
    if (_isProfile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title),
          Expanded(
            child: ScrollEdgeFade(
              child: ListView(padding: EdgeInsets.zero, children: content),
            ),
          ),
          footer,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title),
        Flexible(
          child: ScrollEdgeFade(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: content,
              ),
            ),
          ),
        ),
        footer,
      ],
    );
  }

  Widget _hero() => switch (widget.payload) {
    PluginShare(:final plugin) => ShareHero(
      leading: PluginAvatar(name: plugin.name, title: plugin.displayTitle, size: 56),
      title: plugin.displayTitle,
      subtitle: plugin.summary ?? plugin.author,
    ),
    final ProfileShare p => ShareHero(
      leading: const ProfileTile(),
      title: p.name ?? appL10n.pluginsProfileTitle,
      subtitle: profileSummary(p),
    ),
  };

  ImportChange? get _pluginChange => _plan?.changes.where((c) => c.section == ImportSection.plugins).firstOrNull;

  List<Widget> _facts() {
    final payload = widget.payload;
    final target = _target;
    final targetRow = ListPageRow(
      key: const ValueKey('share-import-target-row'),
      title: _isProfile ? appL10n.pluginsImportTo : appL10n.pluginsInstallTo,
      value: target?.label ?? appL10n.commonNotConnected,
    );
    switch (payload) {
      case PluginShare(:final plugin):
        final change = _pluginChange;
        final size = change?.facts?.unpackedSize;
        return [
          ListPageRow(
            title: appL10n.pluginsSource,
            value: pluginSourceText(plugin, publisher: change?.facts?.publisher),
          ),
          ListPageRow(title: appL10n.commonVersion, value: plugin.version ?? plugin.gitRef ?? '—'),
          if (plugin.source != PluginSourceKind.official)
            ListPageRow(
              key: const ValueKey('share-import-integrity'),
              title: appL10n.pluginsVerification,
              trailing: _integrityChip(change?.integrity),
            ),
          if (size != null) ListPageRow(title: appL10n.pluginsSize, value: formatShareBytes(size)),
          if (_target != null && _targets.length < 2) targetRow,
        ];
      case ProfileShare():
        return [
          ListPageRow(title: appL10n.pluginsSource, value: widget.origin.label),
          ListPageRow(title: appL10n.pluginsSize, value: formatShareBytes(shareBodyBytes(payload).length)),
          if (_target != null && _targets.length < 2) targetRow,
        ];
    }
  }

  Widget _integrityChip(IntegrityStatus? status) => switch (status) {
    IntegrityStatus.verified => StatusChip(tone: StatusTone.ok, label: appL10n.pluginsVerified),
    IntegrityStatus.mismatch => StatusChip(tone: StatusTone.error, label: appL10n.pluginsVerificationMismatch),
    IntegrityStatus.unverifiable => StatusChip(tone: StatusTone.idle, label: appL10n.pluginsCannotVerify),
    null => StatusChip(tone: StatusTone.idle, label: appL10n.pluginsVerifying),
  };

  static Map<ImportSection, String> get _sectionTitles => {
    ImportSection.plugins: appL10n.pluginsTitle,
    ImportSection.presets: appL10n.pluginsPresets,
    ImportSection.settings: appL10n.commonSettings,
    ImportSection.skills: appL10n.pluginsSkills,
    ImportSection.agentsMd: appL10n.pluginsPersonalPreferences,
  };

  static String _kindLabel(ChangeKind kind) => switch (kind) {
    ChangeKind.add => appL10n.pluginsAdded,
    ChangeKind.change => appL10n.pluginsModified,
    ChangeKind.install => appL10n.commonInstall,
    ChangeKind.upgrade => appL10n.commonUpdate,
    ChangeKind.enable => appL10n.commonEnable,
    ChangeKind.unchanged => appL10n.pluginsNoChanges,
    ChangeKind.unavailable => appL10n.pluginsUnavailable,
  };

  List<Widget> _diff() {
    final plan = _plan;
    if (plan == null) {
      return [if (_planError == null) const _Waiting() else _Note(text: appL10n.pluginsHostProfileReadFailed)];
    }
    return [
      const SizedBox(height: 8),
      for (final section in ImportSection.values)
        if (plan.section(section).isNotEmpty)
          SheetGroup(title: _sectionTitles[section], children: [for (final c in plan.section(section)) _row(c)]),
      if (plan.changes.every((c) => !c.actionable)) _Note(text: appL10n.pluginsAlreadyMatches),
    ];
  }

  Widget _row(ImportChange c) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final status = _steps[c.id];
    final on = c.follows == null ? _selected.contains(c.id) : _selected.contains(c.follows);
    String? subtitle;
    Color? subtitleColor;
    if (status?.state == ImportStepState.failed) {
      subtitle = status!.message ?? appL10n.pluginsUnsuccessful;
      subtitleColor = colors.danger;
    } else if (status?.state == ImportStepState.skipped) {
      subtitle = status!.message ?? appL10n.pluginsSkipped;
    } else if (c.blocked != null) {
      subtitle = c.blocked;
    } else {
      subtitle = [_kindLabel(c.kind), ?c.detail, ?status?.message].join(' · ');
    }
    final Widget? trailing = switch (status?.state) {
      ImportStepState.running => SizedBox.square(
        dimension: ShareCheck.size,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: colors.textTertiary),
        ),
      ),
      ImportStepState.done => Icon(AppIcons.success, size: ShareCheck.size, color: colors.success),
      ImportStepState.failed => Icon(AppIcons.stepFailed, size: ShareCheck.size, color: colors.danger),
      ImportStepState.skipped => Icon(AppIcons.stepSkipped, size: ShareCheck.size, color: colors.textTertiary),
      ImportStepState.pending => ShareCheck(value: true, enabled: false),
      null => c.actionable ? ShareCheck(value: on, enabled: c.toggleable && _phase == _Phase.ready) : null,
    };
    return ListPageRow(
      key: ValueKey('share-change-${c.id}'),
      title: c.title,
      titleStyle: c.monoTitle ? AppType.mono(size: 14, color: theme.colorScheme.onSurface) : null,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      subtitleMaxLines: c.sensitive ? 4 : 2,
      // Instructions and skills can be read before they are ticked.
      trailing: c.skill != null || c.text != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                SizedBox.square(
                  dimension: 44,
                  child: TextButton(
                    key: ValueKey('share-view-${c.id}'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () =>
                        showShareContentSheet(context, title: c.title, files: c.skill?.files ?? {'AGENTS.md': c.text!}),
                    child: Text(appL10n.pluginsView),
                  ),
                ),
                trailing ?? const SizedBox.square(dimension: ShareCheck.size),
              ],
            )
          : trailing,
      onTap: c.toggleable && _phase == _Phase.ready
          ? () => setState(() {
              final next = {..._selected};
              if (!next.remove(c.id)) next.add(c.id);
              _selected = next;
            })
          : null,
    );
  }

  Widget _footer(List<ImportTarget> targets) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    Widget primary(String label, VoidCallback? onPressed, {bool busy = false}) => FilledButton(
      key: const ValueKey('share-import-primary'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      onPressed: onPressed,
      child: busy
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    strokeCap: StrokeCap.round,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Text(label),
              ],
            )
          : Text(label),
    );
    Widget note(String text, {bool danger = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: danger ? colors.danger : colors.textTertiary),
      ),
    );

    if (targets.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          note(appL10n.commonEngineUnreachable),
          primary(_isProfile ? appL10n.pluginsImport : appL10n.commonInstall, null),
        ],
      );
    }
    switch (_phase) {
      case _Phase.planning:
        return primary(_isProfile ? appL10n.pluginsImport : appL10n.commonInstall, null);
      case _Phase.ready:
        final plan = _plan;
        if (plan == null) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              note(appL10n.pluginsHostPluginsReadFailed, danger: true),
              primary(appL10n.commonRetry, () => _planFor(_target!)),
            ],
          );
        }
        if (!_isProfile) {
          final c = _pluginChange!;
          final label = switch (c.kind) {
            ChangeKind.upgrade => appL10n.pluginsUpdateTo(
              c.plugin?.version ?? c.plugin?.gitRef ?? appL10n.pluginsNewVersion,
            ),
            ChangeKind.enable => appL10n.commonEnable,
            ChangeKind.unchanged => c.detail ?? appL10n.commonInstalled,
            ChangeKind.unavailable => appL10n.commonInstall,
            _ => appL10n.commonInstall,
          };
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [if (c.blocked case final b?) note(b), primary(label, c.actionable ? _run : null)],
          );
        }
        final count = plan.selected(_selected).length;
        return primary(
          count == 0 ? appL10n.pluginsImport : appL10n.pluginsImportCount(count),
          count == 0 ? null : _run,
        );
      case _Phase.running:
        return primary(_isProfile ? appL10n.pluginsImporting : appL10n.pluginsInstallingActive, null, busy: true);
      case _Phase.done:
        final result = _result!;
        final failed = result.failed;
        final local = _target?.isLocal ?? true;
        final message = failed > 0
            ? (_isProfile
                  ? appL10n.pluginsImportFailedCount(failed)
                  : (result.statuses.values.firstOrNull?.message ?? appL10n.pluginsCouldNotInstall))
            : result.needsRestart
            ? (local
                  ? appL10n.pluginsEngineRestartToApply
                  : appL10n.pluginsRemoteRestartToApply(_target?.label ?? appL10n.pluginsThatComputer))
            : (_isProfile ? appL10n.pluginsImportedCount(result.done) : appL10n.commonCompleted);
        final done = OutlinedButton(
          key: const ValueKey('share-import-done'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appL10n.commonDone),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            note(message, danger: failed > 0),
            if (result.needsRestart && local)
              Row(
                children: [
                  Expanded(child: done),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('share-import-restart'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _restarting ? null : _restart,
                      child: Text(appL10n.pluginsRestartEngine),
                    ),
                  ),
                ],
              )
            else
              FilledButton(
                key: const ValueKey('share-import-primary'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(failed > 0 ? appL10n.commonClose : appL10n.commonDone),
              ),
          ],
        );
    }
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Center(
      child: SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          strokeCap: StrokeCap.round,
          color: DshColors.of(context).textTertiary,
        ),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 8),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
    ),
  );
}
