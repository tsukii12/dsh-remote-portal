import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/plugins_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../theme/theme.dart';
import 'market_widgets.dart';
import 'plugin_widgets.dart';
import '../common/brief_notice.dart';
import '../common/undo_notice_window.dart';

/// Install/remove flows shared by the list, the cards and the sheets. They
/// capture the [ProviderContainer], messenger and root navigator up front so
/// the outcome is still reported after the sheet that started them closed.

/// Queues [request] on the active host and reports the outcome: a toast for
/// 「已安装」, a restart offer for `restart-required` or an update, the reason
/// otherwise.
Future<PluginInstallJob> runPluginInstall(BuildContext context, PluginInstallRequest request) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final host = container.read(pluginHostProvider);
  final job = await container.read(pluginInstallsProvider.notifier).install(request);
  final name = request.title ?? request.name;
  switch (job.phase) {
    case PluginInstallPhase.succeeded when job.needsRestart:
      if (host?.isLocal ?? false) {
        if (navigator.mounted) {
          unawaited(offerEngineRestart(navigator.context, container, name));
        }
      } else {
        messenger?.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(l10n.pluginsInstalledRemoteRestart(name, host?.label ?? l10n.commonRemoteHost)),
          ),
        );
      }
    case PluginInstallPhase.succeeded:
      messenger?.showBriefNotice(l10n.pluginsInstalledNamed(name));
    case PluginInstallPhase.cancelled:
      messenger?.showBriefNotice(l10n.pluginsInstallCancelled);
    case PluginInstallPhase.failed:
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.pluginsInstallFailureNamed(name, job.failure?.title ?? l10n.pluginsInstallFailed))),
      );
    default:
      break;
  }
  return job;
}

/// Installs [entry]'s pinned version on the active host. A medium or high
/// risk asks first, listing what the checks found. Null when declined.
Future<PluginInstallJob?> installMarketEntry(BuildContext context, MarketEntry entry) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final host = container.read(pluginHostProvider);
  if (marketNeedsApp(entry, container.read(appVersionProvider)) != null) return null;
  if (!await confirmMarketRisk(context, entry) || !context.mounted) return null;
  if (!identical(container.read(pluginHostProvider), host)) return null;
  return runPluginInstall(context, marketInstallRequest(entry));
}

/// Replaces the installed copy with [entry]'s pinned version: the risk first
/// (when there is one to confirm), then what an update costs.
Future<void> updateMarketEntry(BuildContext context, MarketEntry entry, {String? from}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final host = container.read(pluginHostProvider);
  if (marketNeedsApp(entry, container.read(appVersionProvider)) != null) return;
  if (!await confirmMarketRisk(context, entry) || !context.mounted) return;
  if (!identical(container.read(pluginHostProvider), host)) return;
  final ok = await confirmPluginUpdate(
    context,
    name: entry.title(Localizations.localeOf(context).languageCode),
    bundleName: entry.name,
    from: from,
    to: entry.plugin.latest.version,
  );
  if (ok && context.mounted && identical(container.read(pluginHostProvider), host)) {
    await runPluginInstall(context, marketInstallRequest(entry, replace: true));
  }
}

/// 「安装前确认」 for a medium or high risk entry: each flag in plain words
/// and the note that they are features, not a verdict. True straight away
/// for everything else.
Future<bool> confirmMarketRisk(BuildContext context, MarketEntry entry) async {
  final listing = entry.listing;
  if (listing == null || !listing.needsConfirm) return true;
  final l10n = context.l10n;
  final colors = DshColors.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final host = container.read(pluginHostProvider);
  final selected = container.read(activeHostProvider);
  final generation = host?.client.mux.generation;
  final ready = host?.client.mux.lastReadyGenerationNumber;
  var current = host != null;
  final selection = container.listen(activeHostProvider, (_, next) {
    if (next != selected) current = false;
  });
  final connection = container.listen(pluginHostProvider, (_, next) {
    if (!identical(next, host)) current = false;
  });
  final ok =
      await showAppDialog<bool>(
        context: context,
        builder: (dialog) {
          final theme = Theme.of(dialog);
          return AlertDialog(
            title: Text(l10n.marketRiskConfirmTitle(entry.title(Localizations.localeOf(context).languageCode))),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final flag in listing.flags) ...[
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '● ',
                            style: TextStyle(color: marketFlagColor(dialog, flag)),
                          ),
                          TextSpan(
                            text: marketFlagText(l10n, flag).$1,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 16, top: 2, bottom: 10),
                      child: Text(
                        marketFlagText(l10n, flag).$2,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.55),
                      ),
                    ),
                  ],
                  Text(
                    l10n.marketChecksNote,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.55),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
              FilledButton(
                style: listing.risk == MarketRisk.high
                    ? FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger)
                    : null,
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(l10n.marketRiskConfirmAction),
              ),
            ],
          );
        },
      ).whenComplete(() {
        selection.close();
        connection.close();
      });
  if (ok != true || !context.mounted) return false;
  if (!current ||
      !identical(container.read(pluginHostProvider), host) ||
      !identical(host?.client.mux.generation, generation) ||
      host?.client.mux.lastReadyGenerationNumber != ready) {
    _hostChangedNotice(context, messenger, l10n.pluginsOperationHostChanged);
    return false;
  }
  return true;
}

/// Restart dialog for the on-device engine after `restart-required`.
Future<void> offerEngineRestart(BuildContext context, ProviderContainer container, String name) async {
  final l10n = context.l10n;
  final restart = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.pluginsRestartRequired),
      content: Text(l10n.pluginsRestartExplanation(name)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonLater)),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.pluginsRestartEngine)),
      ],
    ),
  );
  if (restart != true) return;
  try {
    if (await EngineControl.restart(container)) return;
  } on Object {
    // Native start/stop errors need the same visible failure as a stop timeout.
  }
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      content: Text(l10n.pluginsReloadFailed),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonClose))],
    ),
  );
}

/// A confirmation that a host change retired: nothing was sent. These open
/// from a plugin sheet, which still describes the previous host; it closes
/// first so the notice isn't left under it.
void _hostChangedNotice(BuildContext context, ScaffoldMessengerState? messenger, String text) {
  final route = ModalRoute.of(context);
  if (route is ModalBottomSheetRoute && route.isCurrent) Navigator.of(context).pop();
  messenger?.showBriefNotice(text);
}

/// Explicit consent for the build scripts pnpm blocked, then a retry that
/// passes them as `approvedBuilds`.
Future<void> approveBuildsAndRetry(BuildContext context, PluginInstallJob job) async {
  final l10n = context.l10n;
  final builds = job.failure?.pendingBuilds ?? const <String>[];
  if (builds.isEmpty) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final host = container.read(pluginHostProvider);
  final selected = container.read(activeHostProvider);
  final generation = host?.client.mux.generation;
  final readyGeneration = host?.client.mux.lastReadyGenerationNumber;
  var current = host != null;
  // Consent belongs to the named host even if selection leaves and returns
  // before a frame. Stop observing as soon as the dialog settles.
  final selection = container.listen(activeHostProvider, (_, next) {
    if (next != selected) current = false;
  });
  final connection = container.listen(pluginHostProvider, (_, next) {
    if (!identical(next, host)) current = false;
  });
  final ok =
      await showAppDialog<bool>(
        context: context,
        builder: (dialog) {
          final theme = Theme.of(dialog);
          return AlertDialog(
            title: Text(l10n.pluginsAllowBuildScripts),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.pluginsBuildScriptPackages),
                const SizedBox(height: 8),
                for (final name in builds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $name', style: AppType.monoLabel(color: theme.colorScheme.onSurface)),
                  ),
                const SizedBox(height: 8),
                Text(
                  l10n.pluginsBuildScriptWarning(host?.label ?? l10n.pluginsThisDevice),
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
              FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.pluginsAllowRetry)),
            ],
          );
        },
      ).whenComplete(() {
        selection.close();
        connection.close();
      });
  if (ok != true || !context.mounted) return;
  if (!current ||
      !identical(container.read(pluginHostProvider), host) ||
      !identical(host?.client.mux.generation, generation) ||
      host?.client.mux.lastReadyGenerationNumber != readyGeneration) {
    _hostChangedNotice(context, messenger, l10n.pluginsOperationHostChanged);
    return;
  }
  unawaited(runPluginInstall(context, job.request.withApprovedBuilds(builds)));
}

/// Confirms an update (remove, then install): a failed install leaves the
/// plugin uninstalled.
Future<bool> confirmPluginUpdate(
  BuildContext context, {
  required String name,
  required String bundleName,
  String? from,
  required String to,
}) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final host = container.read(pluginHostProvider);
  final selected = container.read(activeHostProvider);
  final generation = host?.client.mux.generation;
  final readyGeneration = host?.client.mux.lastReadyGenerationNumber;
  PluginBundle? currentBundle() {
    final inventory = container.read(installedPluginsProvider);
    if (inventory.isLoading || inventory.hasError) return null;
    return inventory.value?.where((bundle) => bundle.name == bundleName).firstOrNull;
  }

  final original = currentBundle();
  var current = host != null;
  final selection = container.listen(activeHostProvider, (_, next) {
    if (next != selected) current = false;
  });
  final connection = container.listen(pluginHostProvider, (_, next) {
    if (!identical(next, host)) current = false;
  });
  bool sameBundle() {
    final latest = currentBundle();
    return latest != null &&
        latest.version == original?.version &&
        latest.source == original?.source &&
        (latest.installed || latest.availability == 'profile');
  }

  final ok =
      await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.pluginsUpdateNamed(name)),
          content: Text(
            from == null ? l10n.pluginsUpdateCurrentWarning(to) : l10n.pluginsUpdateVersionWarning(from, to),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.commonUpdate)),
          ],
        ),
      ).whenComplete(() {
        selection.close();
        connection.close();
      });
  // Keep the original package/version intent; never turn an old confirmation
  // into removal of a newer installation or a retry on another host.
  if (ok != true || !context.mounted) return false;
  if (!current ||
      !identical(container.read(pluginHostProvider), host) ||
      !identical(host?.client.mux.generation, generation) ||
      host?.client.mux.lastReadyGenerationNumber != readyGeneration) {
    _hostChangedNotice(context, messenger, l10n.pluginsOperationHostChanged);
    return false;
  }
  return original != null && original.version == from && sameBundle();
}

/// Confirms, hides [bundle] and shows 「已卸载…」 with 撤销; the Host removes it
/// when the undo window ends (undo sends nothing). Afterwards only what makes
/// that notice untrue, or incomplete, is reported: a restart still needed, a
/// failure, or a plan dropped without 撤销. True once the Host removed it.
Future<bool> removePluginBundle(BuildContext context, PluginBundle bundle, {Route<dynamic>? ownerRoute}) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final selectedHost = container.read(activeHostProvider);
  final host = container.read(pluginHostProvider);
  final generation = host?.client.mux.generation;
  final readyGeneration = host?.client.mux.lastReadyGenerationNumber;
  final title = bundle.title();
  final colors = DshColors.of(context);
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.pluginsUninstallNamed(title)),
      content: Text(l10n.pluginsUninstallExplanation(host?.label ?? l10n.pluginsThisHost)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.pluginsUninstall),
        ),
      ],
    ),
  );
  // The confirmation names the connection that opened it. A retained sheet
  // must not acquire the newer controller destination after switching hosts
  // or reconnecting, including a return to the same client object.
  if (ok != true || !context.mounted || host == null) return false;
  if (!identical(container.read(pluginHostProvider), host) ||
      !identical(host.client.mux.generation, generation) ||
      host.client.mux.lastReadyGenerationNumber != readyGeneration) {
    _hostChangedNotice(context, messenger, l10n.pluginsOperationHostChanged);
    return false;
  }
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return false;
  if (messenger == null || !messenger.mounted) return false;
  final removals = container.read(installedPluginsProvider.notifier);
  final intent = reserveUndoNotice(messenger);
  PendingPluginRemoval pending;
  try {
    pending = removals.scheduleRemoval(bundle);
  } on Object catch (error) {
    bool owned() =>
        context.mounted &&
        messenger.mounted &&
        intent.isCurrent &&
        (route == null || route.isCurrent) &&
        identical(container.read(pluginHostProvider), host) &&
        identical(host.client.mux.generation, generation) &&
        host.client.mux.lastReadyGenerationNumber == readyGeneration;
    await publishAfterUndoNotice(messenger, owned, () {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(_failed(l10n.pluginsUninstallFailed, describePluginError(error))), persist: false),
      );
    });
    return false;
  }

  // Scheduling publishes inventory. A synchronous listener may have navigated
  // or changed owner; never pop that newer route or replace its undo plan.
  if (!context.mounted ||
      !messenger.mounted ||
      (route != null && !route.isCurrent) ||
      !identical(container.read(pluginHostProvider), host) ||
      !identical(host.client.mux.generation, generation) ||
      host.client.mux.lastReadyGenerationNumber != readyGeneration) {
    pending.cancel();
    return false;
  }
  final lease = intent.claim(
    identity: pending,
    canUndo: () => pending.canUndo,
    cancel: pending.cancel,
    commit: pending.commitNow,
    windowClosed: pending.windowClosed,
  );
  if (lease == null) return false;
  if (!identical(lease.intent, intent)) return false;
  // Ending the previous window may synchronously navigate or change Host.
  if (!context.mounted ||
      !messenger.mounted ||
      !lease.isCurrent ||
      !intent.isCurrent ||
      (route != null && !route.isCurrent) ||
      !identical(container.read(pluginHostProvider), host) ||
      !identical(host.client.mux.generation, generation) ||
      host.client.mux.lastReadyGenerationNumber != readyGeneration) {
    pending.cancel();
    return false;
  }
  // The undo action must live above the outer sheet, including market nesting.
  if (route is ModalBottomSheetRoute) Navigator.of(context).pop();
  final outcomeRoute = ownerRoute ?? (route is ModalBottomSheetRoute ? null : route);
  var current = true;
  final owner = container.listen(pluginHostProvider, (_, next) {
    if (!identical(next, host)) {
      current = false;
      pending.cancel();
    }
  });
  bool owned() =>
      current &&
      (outcomeRoute == null || outcomeRoute.isCurrent) &&
      messenger.mounted &&
      identical(container.read(pluginHostProvider), host) &&
      identical(host.client.mux.generation, generation) &&
      host.client.mux.lastReadyGenerationNumber == readyGeneration;
  final notice = messenger.showUndoNotice(
    l10n.pluginsUninstalledNamed(title),
    undoLabel: l10n.shellUndo,
    onUndo: pending.undo,
    window: InstalledPluginsController.removalUndoWindow,
  );
  lease.attach(messenger, notice);
  Future<void> publishResult(SnackBar resultNotice) => publishAfterUndoNotice(messenger, owned, () {
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(resultNotice);
  });
  // A failure, or a plan dropped without 撤销 before sending, brings the row
  // back after the notice said 已卸载: say so on this Host's page, even across
  // a reconnect.
  bool samePage() =>
      messenger.mounted &&
      (outcomeRoute == null || outcomeRoute.isCurrent) &&
      container.read(activeHostProvider) == selectedHost;
  Future<void> publishFailure(String text) => publishAfterUndoNotice(messenger, samePage, () {
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text), persist: false));
  });

  try {
    final result = await pending.done;
    if (result == null) {
      // Dropped before sending: by 撤销, or by a reconnect or the plugin
      // changing on the Host.
      if (!pending.undone && !pending.sent) await publishFailure(l10n.pluginsUninstallFailed);
      return false;
    }
    if (result.succeeded && !result.needsRestart) return true;
    if (result.succeeded) {
      final local = host.isLocal;
      await publishResult(
        SnackBar(
          content: Text(
            local
                ? l10n.pluginsUninstalledRestartLocal(title)
                : l10n.pluginsUninstalledRestartRemote(title, host.label),
          ),
          persist: false,
          action: local
              ? SnackBarAction(
                  label: l10n.pluginsRestartNow,
                  onPressed: () {
                    if (owned()) unawaited(EngineControl.restart(container));
                  },
                )
              : null,
        ),
      );
      return true;
    }
    await publishFailure(_failed(l10n.pluginsUninstallFailed, describeOperationFailure(result, isLocal: host.isLocal)));
  } on Object catch (error) {
    await publishFailure(_failed(l10n.pluginsUninstallFailed, describePluginError(error)));
  } finally {
    owner.close();
  }
  return false;
}

/// Switches a bundle; reports failures and restart needs.
Future<void> togglePluginBundle(BuildContext context, PluginBundle bundle, bool enabled) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final host = container.read(pluginHostProvider);
  try {
    final result = await container.read(installedPluginsProvider.notifier).setEnabled(bundle, enabled);
    if (!result.succeeded) {
      final failure = describeOperationFailure(result, isLocal: host?.isLocal ?? true);
      messenger?.showSnackBar(
        SnackBar(content: Text(_failed(enabled ? l10n.pluginsEnableFailed : l10n.pluginsDisableFailed, failure))),
      );
    } else if (result.needsRestart) {
      final local = host?.isLocal ?? true;
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              local
                  ? (enabled ? l10n.pluginsEnabledRestartLocal : l10n.pluginsDisabledRestartLocal)
                  : (enabled
                        ? l10n.pluginsEnabledRestartRemote(host!.label)
                        : l10n.pluginsDisabledRestartRemote(host!.label)),
            ),
            persist: false,
            action: local
                ? SnackBarAction(
                    label: l10n.pluginsRestartNow,
                    onPressed: () => unawaited(EngineControl.restart(container)),
                  )
                : null,
          ),
        );
    }
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          _failed(enabled ? l10n.pluginsEnableFailed : l10n.pluginsDisableFailed, describePluginError(error)),
        ),
      ),
    );
  }
}

/// 「没能卸载：原因」; an unknown failure has no reason worth showing.
String _failed(String action, PluginFailure failure) =>
    failure.kind == PluginFailureKind.unknown ? action : appL10n.pluginsActionFailure(action, failure.message);

/// For hosts that cannot install from here (relay): the command to run there.
Future<void> showPluginCommandSheet(
  BuildContext context, {
  required String title,
  required String command,
  String? hostLabel,
}) {
  final l10n = context.l10n;
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final colors = DshColors.of(sheet);
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(title),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.pluginsRelayCommandInstruction(hostLabel ?? l10n.pluginsThatComputer),
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    PluginCommandBox(command: command),
                    const SizedBox(height: 12),
                    Text(
                      l10n.pluginsCommandAfterInstall,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
