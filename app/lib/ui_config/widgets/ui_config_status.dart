// ui.json's one quiet line in settings and the sheet behind it: 「界面配置 · 2
// 处没生效」, and on tap what did not apply, with the JSON Pointer of each. No
// banners, no notifications. Without a ui.json the line is not there — except
// on a remote host without the dsh-go-ui skill, where it offers to install it
// (when the app's wiring provides an installer).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../ui/common/app_sheet.dart';
import '../../ui/settings/settings_widgets.dart' show InfoRow, SettingsTile;
import '../../ui/theme/app_icons.dart';
import '../../ui/theme/theme.dart';
import '../ui_config_labels.dart';
import '../ui_config_model.dart';
import '../ui_config_state.dart';
import '../ui_skill.dart';
import '../../ui/common/brief_notice.dart';

/// The row's value: 「2 处没生效」「已应用 12 项」「没有生效」.
String uiConfigSummary(UiConfigLoad load) {
  if (load.fatal) return appL10n.shellConfigNotApplied;
  final dropped = load.notAppliedCount;
  return dropped > 0 ? appL10n.shellConfigDroppedCount(dropped) : appL10n.shellConfigAppliedCount(load.appliedCount);
}

/// 「界面配置」 for the active host; nothing when it has no ui.json.
class UiConfigStatusTile extends ConsumerWidget {
  const UiConfigStatusTile({super.key, this.icon, this.tinted = false, this.tint = 0});

  final IconData? icon;

  /// As [SettingsTile.tinted]: a tinted disc on hub pages, a line icon
  /// elsewhere.
  final bool tinted;
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final host = ref.watch(activeHostProvider);
    final state = ref.watch(uiConfigProvider(host));
    final load = state.load;
    if (load == null) {
      final installer = ref.watch(uiSkillRemoteInstallerProvider);
      if (host.isLocal || !state.needsSkill || installer == null) return const SizedBox.shrink();
      return SettingsTile(
        key: const ValueKey('ui-config-status'),
        icon: icon,
        tinted: tinted,
        tint: tint,
        title: l10n.shellInterfaceConfig,
        value: Text(l10n.shellSkillNotInstalled),
        onTap: () => unawaited(_install(context, ref, host, installer)),
      );
    }
    return SettingsTile(
      key: const ValueKey('ui-config-status'),
      icon: icon,
      tinted: tinted,
      tint: tint,
      title: l10n.shellInterfaceConfig,
      value: Text(uiConfigSummary(load)),
      onTap: () => unawaited(showUiConfigIssues(context)),
    );
  }

  Future<void> _install(BuildContext context, WidgetRef ref, HostRef host, UiSkillRemoteInstaller installer) async {
    final agreed = await confirmUiSkillInstall(context);
    if (agreed != true || !context.mounted) return;
    final bundle = await ref.read(uiSkillBundleLoaderProvider)();
    if (!context.mounted) return;
    await installer.install(context, host, bundle);
  }
}

/// Asks before the skill goes onto a remote host.
Future<bool?> confirmUiSkillInstall(BuildContext context) => showAppSheet<bool>(
  context,
  builder: (context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(context.l10n.shellInstallInterfaceSkill),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 20),
            child: Text(
              context.l10n.shellInstallInterfaceSkillMessage,
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(context.l10n.commonCancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('ui-skill-install'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(context.l10n.commonInstall),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  },
);

/// What the active host's ui.json did and did not apply.
Future<void> showUiConfigIssues(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const UiConfigIssuesSheet());

class UiConfigIssuesSheet extends ConsumerWidget {
  const UiConfigIssuesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final host = ref.watch(activeHostProvider);
    final load = ref.watch(uiConfigProvider(host).select((s) => s.load));
    final applied = ref.watch(uiOverridesProvider.select((o) => o.config.entries.values.toList()));
    final dropped = load?.issues.where((i) => i.kind.dropsSomething).toList() ?? const <UiConfigIssue>[];
    final adjusted = load?.issues.where((i) => !i.kind.dropsSomething).toList() ?? const <UiConfigIssue>[];
    final summary = switch (load) {
      null => l10n.shellNoUiJson,
      UiConfigLoad(fatal: true, fromLastGood: true) => l10n.shellConfigUsingPrevious,
      UiConfigLoad(fatal: true) => l10n.shellConfigNotApplied,
      _ => [
        l10n.shellConfigAppliedCount(load.appliedCount),
        if (dropped.isNotEmpty) l10n.shellConfigDroppedCount(dropped.length),
      ].join(' · '),
    };
    final copyText = [
      for (final i in [...dropped, ...adjusted]) i.line,
    ].join('\n');

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            l10n.shellInterfaceConfig,
            actions: [
              if (copyText.isNotEmpty)
                SheetIconButton(
                  icon: AppIcons.copy,
                  tooltip: l10n.commonCopy,
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    await Clipboard.setData(ClipboardData(text: copyText));
                    messenger?.showBriefNotice(l10n.commonCopied);
                  },
                ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
                    child: Text(
                      'ui.json · $summary',
                      key: const ValueKey('ui-config-summary'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                    ),
                  ),
                  if (dropped.isNotEmpty)
                    SheetGroup(
                      title: l10n.shellConfigDroppedHeading,
                      children: [for (final i in dropped) _IssueRow(pointer: i.pointer, text: i.message)],
                    ),
                  if (adjusted.isNotEmpty)
                    SheetGroup(
                      title: l10n.shellConfigNotesHeading,
                      children: [for (final i in adjusted) _IssueRow(pointer: i.pointer, text: i.message)],
                    ),
                  if (applied.isNotEmpty && !(load?.fatal ?? false))
                    SheetGroup(
                      title: l10n.shellConfigAppliedHeading,
                      children: [
                        for (final e in applied)
                          if (uiSettingLabel(e) case (final name, final value)) InfoRow(label: name, value: value),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A pointer (small, mono, quiet) over what it says.
class _IssueRow extends StatelessWidget {
  const _IssueRow({required this.pointer, required this.text});

  final String pointer;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pointer.isNotEmpty) ...[
              Text(pointer, style: AppType.monoLabel(color: colors.textTertiary)),
              const SizedBox(height: 2),
            ],
            Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }
}
