// A plugin's native panel (docs/design/native-plugins.md §3.3 `panel`): its
// view and live data from the host's stream, drawn by the plugin view renderer,
// always under the plugin's name (§3.7 署名外框). Taps on its controls go back to
// the plugin and their data effects land here.

import 'package:dsh_client/dsh_client.dart' show DshGoScope;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_model.dart';
import '../../../plugins/native/native_capabilities.dart';
import '../../../plugins/native/native_state.dart';
import '../../../plugins/native/native_surface.dart';
import '../../../state/hosts_state.dart';
import '../../common/app_sheet.dart';
import '../../common/empty_view.dart';
import '../../chat/dsh_ui/dsh_ui_plugin_controls.dart' show DshUiControlButton;
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../view/plugin_view.dart';
import 'native_micro_caption.dart';
import 'native_taps.dart';

/// One panel, signed: the plugin's name over its view in a glass card
/// (loading, unreachable or broken in the same card).
class NativePanelView extends ConsumerWidget {
  const NativePanelView({super.key, required this.panel, this.sessionId});

  final NativePanel panel;
  final String? sessionId;

  NativeSurfaceKey get surfaceKey => nativePanelKey(panel, DshGoScope(sessionId: sessionId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(nativeCapabilityDiscoveryProvider);
    final l10n = context.l10n;
    final key = surfaceKey;
    final host = ref.watch(activeHostProvider);
    final state = ref.watch(nativeSurfaceProvider(key));
    final title = ref.watch(nativePluginTitleProvider(panel.package));
    final icon = ref.watch(nativeContributionsProvider.select((c) => c.plugin(panel.package)?.icon));

    final Widget body;
    final editableV2 = state.view is Map && (state.view as Map)['v'] == 2;
    if (state.hasView && (editableV2 || (!state.offline && state.failure == null))) {
      final bridge = ref.watch(nativeBridgeProvider);
      final view = PluginView(
        key: ValueKey((host, key)),
        view: state.view,
        data: state.data,
        clock: ref.watch(nativeClockProvider),
        showTitle: false,
        imageResolver: (src) =>
            src.startsWith('asset:') && bridge != null ? bridge.asset(panel.package, src.substring(6)) : null,
        onAction: state.offline || state.failure != null || bridge == null
            ? null
            : (action) => runNativeTap(
                context,
                ref,
                package: panel.package,
                surface: NativeSurface.panel,
                id: panel.id,
                scope: key.scope,
                action: action.id,
                value: action.args,
                userGesture: action.source != PluginActionSource.change,
                gestureAt: action.gestureAt,
                target: key,
                stillCurrent: () {
                  if (!context.mounted) return false;
                  final current = context.widget;
                  return current is NativePanelView && current.surfaceKey == key;
                },
              ),
      );
      body = !editableV2
          ? view
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.offline || state.failure != null) ...[
                  Text(
                    state.offline ? l10n.plugslotsPanelOffline : nativeIssueText(state.failure!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  DshUiControlButton(
                    label: l10n.commonRetry,
                    onPressed: () => ref.read(nativeSurfaceProvider(key).notifier).refresh(),
                  ),
                  const SizedBox(height: 12),
                ],
                view,
              ],
            );
    } else if (state.loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    } else {
      body = EmptyView(
        compact: true,
        icon: AppIcons.plugin,
        title: state.offline ? l10n.plugslotsPanelOffline : nativeIssueText(state.failure ?? 'plugin-error'),
        actionLabel: l10n.commonRetry,
        onAction: () => ref.read(nativeSurfaceProvider(key).notifier).refresh(),
      );
    }
    final micro = panel.micro;
    return PluginFrame(
      pluginName: title,
      icon: icon,
      // v1.2: the plugin's caption line, on its own small channel.
      child: micro == null
          ? body
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                body,
                NativeMicroCaption(package: panel.package, channel: micro, scope: key.scope),
              ],
            ),
    );
  }
}

/// A panel as a page of its own: its title in the bar, the signed panel
/// under it.
/// Opens [panel] the way it asked: a sheet over what the person was doing, or a page.
Future<void> openNativePanel(BuildContext context, NativePanel panel, {String? sessionId}) {
  if (!panel.sheet) return Navigator.of(context).push(NativePanelPage.route(panel: panel, sessionId: sessionId));
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => Padding(
      // A v2 panel can have fields: the sheet rises with the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: ValueKey('native-panel-sheet|${panel.package}|${panel.id}'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: NativePanelView(panel: panel, sessionId: sessionId),
        ),
      ),
    ),
  );
}

class NativePanelPage extends StatelessWidget {
  const NativePanelPage({super.key, required this.panel, this.sessionId});

  final NativePanel panel;
  final String? sessionId;

  static Route<void> route({required NativePanel panel, String? sessionId}) => MaterialPageRoute<void>(
    builder: (_) => NativePanelPage(panel: panel, sessionId: sessionId),
  );

  @override
  Widget build(BuildContext context) => AppPage.list(
    title: panel.title,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: NativePanelView(panel: panel, sessionId: sessionId),
      ),
    ],
  );
}
