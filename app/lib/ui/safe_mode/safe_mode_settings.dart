import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import 'safe_mode_actions.dart';

/// Settings entries for safe mode: a manual "以安全模式启动" / "恢复正常模式" and the
/// "自动进入安全模式" switch, which lives natively so the decision can be made with no
/// UI attached. Settings rows, placed inside the settings screen's own group.
class SafeModeSettingsTiles extends ConsumerWidget {
  const SafeModeSettingsTiles({
    super.key,
    this.showAutoSwitch = true,
    this.tint = 3,
    this.tinted = true,
    this.icon = true,
  });

  /// The "自动进入安全模式" switch under the manual row. The settings hub
  /// leaves it to the engine page ([SafeModeAutoSwitch]).
  final bool showAutoSwitch;
  final int tint;
  final bool tinted;

  /// False: plain rows (本机引擎, where the rows beside it have none).
  final bool icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    if (status.phase == RuntimePhase.notInstalled || status.phase == RuntimePhase.installing) {
      return const SizedBox.shrink();
    }
    final busy = status.phase.isBusy;
    final manual = status.inSafeMode
        ? SettingsTile(
            icon: icon ? AppIcons.safeMode : null,
            tint: tint,
            tinted: tinted,
            spot: Spots.safeMode,
            title: l10n.phoneSafeLeave,
            subtitle: l10n.phoneSafeNormalSettingsHint,
            onTap: busy ? null : () => unawaited(SafeModeActions.leave(context)),
          )
        : SettingsTile(
            icon: icon ? AppIcons.safeMode : null,
            tint: tint,
            tinted: tinted,
            spot: Spots.safeMode,
            subtitle: l10n.phoneSafeStartSettingsHint,
            onTap: busy ? null : () => unawaited(SafeModeActions.enter(context)),
          );
    if (!showAutoSwitch) return manual;
    return Column(
      mainAxisSize: MainAxisSize.min,
      // The 2dp gap SheetGroup puts between rows.
      spacing: 2,
      children: [
        manual,
        SafeModeAutoSwitch(tint: tint, tinted: tinted),
      ],
    );
  }
}

/// "自动进入安全模式": decided natively, so it works with no UI attached.
class SafeModeAutoSwitch extends ConsumerWidget {
  const SafeModeAutoSwitch({super.key, this.icon = AppIcons.autoSwitch, this.tint = 3, this.tinted = true});

  /// Null for a plain row (secondary pages).
  final IconData? icon;
  final int tint;
  final bool tinted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final autoSafe = ref.watch(localRuntimeProvider.select((s) => s.status.autoSafe));
    return SettingsSwitchTile(
      icon: icon,
      tint: tint,
      tinted: tinted,
      spot: Spots.autoSafe,
      subtitle: l10n.phoneSafeAutoSettingsHint,
      value: autoSafe,
      onChanged: (v) => unawaited(ref.read(runtimeBridgeProvider).setAutoSafe(v)),
    );
  }
}
