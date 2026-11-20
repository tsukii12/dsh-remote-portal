import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../settings/settings_widgets.dart';

/// Local, native-only recovery: available even when DSH's workspace RPC is down.
class WorkspaceRecoverySettings extends ConsumerStatefulWidget {
  const WorkspaceRecoverySettings({super.key});

  @override
  ConsumerState<WorkspaceRecoverySettings> createState() => _WorkspaceRecoverySettingsState();
}

class _WorkspaceRecoverySettingsState extends ConsumerState<WorkspaceRecoverySettings> {
  bool _busy = false;
  Object? _failure;

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(localRuntimeProvider);
    final status = runtime.status;
    final l10n = context.l10n;
    final enabled = runtime.loaded && !status.phase.isBusy && status.phase != RuntimePhase.notInstalled && !_busy;
    final active = status.workspaceRecovery;
    return SettingsSection(
      title: l10n.workspaceRecoveryTitle,
      children: [
        SettingsTile(
          key: const ValueKey('workspace-recovery'),
          spot: Spots.workspaceRecovery,
          title: active ? l10n.workspaceRecoveryDisable : l10n.workspaceRecoveryEnable,
          subtitle: active ? l10n.workspaceRecoveryActive : l10n.workspaceRecoveryHint,
          value: _busy ? Text(l10n.workspaceRecoveryWorking) : null,
          onTap: enabled ? () => unawaited(_change()) : null,
        ),
        if (_failure case final failure?)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
              switch (failure) {
                MissingPluginException() => l10n.workspaceRecoveryUnavailable,
                PlatformException(code: 'runtime_not_stopped') => l10n.phoneSafeStopIncomplete,
                PlatformException(code: 'runtime_not_stopped_after_recovery') =>
                  l10n.workspaceRecoveryRestartIncomplete,
                PlatformException(code: 'workspace_recovery_save_failed') => l10n.workspaceRecoverySaveFailed,
                _ => l10n.workspaceRecoveryFailed,
              },
              key: const ValueKey('workspace-recovery-error'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Future<bool> _confirm(ProviderContainer container, RuntimeStatus initial) async {
    final l10n = context.l10n;
    final route = ModalRoute.of(context);
    final host = container.read(activeHostProvider);
    var owned = true;
    final hosts = container.listen(activeHostProvider, (_, next) {
      if (next != host) owned = false;
    });
    final runtimes = container.listen(
      localRuntimeProvider.select((s) => (s.status.installedVersion, s.status.workspaceRecovery, s.status.phase)),
      (_, next) {
        if (next.$1 != initial.installedVersion ||
            next.$2 != initial.workspaceRecovery ||
            next.$3 == RuntimePhase.installing ||
            next.$3 == RuntimePhase.notInstalled) {
          owned = false;
        }
      },
    );
    try {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(initial.workspaceRecovery ? l10n.workspaceRecoveryDisable : l10n.workspaceRecoveryEnable),
          content: SingleChildScrollView(
            child: Text(
              initial.workspaceRecovery ? l10n.workspaceRecoveryDisableBody : l10n.workspaceRecoveryEnableBody,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(
              key: const ValueKey('workspace-recovery-confirm'),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(
                initial.workspaceRecovery ? l10n.workspaceRecoveryDisableStart : l10n.workspaceRecoveryEnableStart,
              ),
            ),
          ],
        ),
      );
      return confirmed == true && mounted && owned && route?.isCurrent != false;
    } finally {
      hosts.close();
      runtimes.close();
    }
  }

  Future<void> _change() async {
    if (_busy) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final initial = container.read(localRuntimeProvider).status;
    final route = ModalRoute.of(context);
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      if (!await _confirm(container, initial)) return;
      // The confirmed local operation keeps its container lifetime if the page
      // is popped. No remote connection or workspace preference is touched.
      await EngineControl.setWorkspaceRecovery(container, enabled: !initial.workspaceRecovery);
    } catch (error) {
      if (mounted && route?.isCurrent != false) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
