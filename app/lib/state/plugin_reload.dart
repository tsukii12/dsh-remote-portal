import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugins/native/native_state.dart';
import '../plugins/native/native_surface.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'engine_control.dart';
import 'hosts_state.dart';
import 'plugins_state.dart';

/// A local directory dependency, not a registry, Git URL or packaged archive.
/// The path is only classified; no plugin-supplied path is executed or opened.
bool isLocalPluginSource(String? source) {
  final spec = source?.trim() ?? '';
  if (spec.isEmpty || spec.contains('\u0000')) return false;
  final path = spec.startsWith('file:') || spec.startsWith('link:') ? spec.substring(5).trim() : spec;
  if (path.isEmpty || RegExp(r'\.(?:tgz|tar|tar\.gz)$', caseSensitive: false).hasMatch(path)) return false;
  final uri = Uri.tryParse(path);
  if (uri == null || uri.hasScheme || uri.host.isNotEmpty) return false;
  return spec.startsWith('file:') ||
      spec.startsWith('link:') ||
      spec.startsWith('/') ||
      spec.startsWith('./') ||
      spec.startsWith('../') ||
      spec.startsWith('~/');
}

bool canReloadLocalPlugin(PluginBundle bundle, PluginHost? host, HostRef active, RuntimeStatus runtime) =>
    active.isLocal &&
    host != null &&
    host.isLocal &&
    !host.safeMode &&
    !runtime.inSafeMode &&
    runtime.phase == RuntimePhase.running &&
    bundle.installed &&
    bundle.enabled &&
    !bundle.official &&
    bundle.readOnlyReason == null &&
    isLocalPluginSource(bundle.source);

enum PluginReloadResult { requested, cancelled, unavailable, busy }

/// One restart across every open plugin sheet, including its confirmation.
/// Uses the existing full-engine restart, not a claim of module-level HMR.
class LocalPluginReloadController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<PluginReloadResult> reload(PluginBundle requested, {required Future<bool> Function() confirm}) async {
    if (state) return PluginReloadResult.busy;
    final active = ref.read(activeHostProvider);
    final host = ref.read(pluginHostProvider);
    PluginBundle? current() {
      final bundles = ref.read(installedPluginsProvider);
      if (bundles.isLoading || bundles.hasError) return null;
      return bundles.value?.where((bundle) => bundle.name == requested.name).singleOrNull;
    }

    bool eligible(PluginBundle? bundle) =>
        bundle != null &&
        bundle.source == requested.source &&
        canReloadLocalPlugin(
          bundle,
          ref.read(pluginHostProvider),
          ref.read(activeHostProvider),
          ref.read(localRuntimeProvider).status,
        );
    if (!eligible(current())) return PluginReloadResult.unavailable;
    state = true;
    try {
      if (!await confirm() || !ref.mounted) return PluginReloadResult.cancelled;
      if (ref.read(activeHostProvider) != active ||
          ref.read(pluginHostProvider)?.client != host?.client ||
          !eligible(current())) {
        return PluginReloadResult.unavailable;
      }
      // An unfinished stop requested no start; the sheet reports it as a failed reload.
      if (!await EngineControl.restart(ref.container)) throw StateError('runtime_not_stopped');
      if (ref.mounted && ref.read(activeHostProvider) == active) {
        // A fast reconnect can keep the same declarations available. Their
        // live views still need a fresh read after source code changed.
        ref.invalidate(nativeRawContributionsProvider);
        ref.invalidate(nativeSurfaceProvider);
      }
      return PluginReloadResult.requested;
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

final localPluginReloadProvider = NotifierProvider<LocalPluginReloadController, bool>(LocalPluginReloadController.new);
