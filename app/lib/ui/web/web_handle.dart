// The app's mark in a round glass key — [WebMarkButton] — and the handle of
// 网页模式: the same key, seated where a web page has its back button
// (WebViewPage.leading): inside DSH Web's header row beside the drawer button,
// above the sidebar on a tablet. So it never sits on the page's own title,
// actions, composer or scroll-to-bottom key; the geometry tests
// (test/web/web_mode_test.dart) hold it to that in every layout.
//
// The handle opens the three things only the native app has: the native
// interface itself, App 设置 (hosts, theme, phone control, background
// running…) and the host switcher. A 网页版 page, which has no handle, seats
// the same key as its way back (web_view_page.dart), so the app's one mark
// stays in its one seat.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../remote/host_status.dart';
import '../remote/host_switcher.dart';
import '../remote/remote_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/settings_widgets.dart';
import '../shell/brand_mark.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The app's mark in a round glass key: the handle's face, and — on a page
/// with no handle (网页版) — the marker in DSH Web's leading seat doing the
/// page's way back. [size] matches the button whose seat it takes.
class WebMarkButton extends StatelessWidget {
  const WebMarkButton({super.key, required this.size, required this.tooltip, required this.label, required this.onTap});

  final double size;

  /// The long-press hint (and the semantics label's source), e.g. 原生功能
  /// or 返回.
  final String tooltip;

  /// What a screen reader calls the button (the mark says nothing by itself).
  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The mark at the weight of the page's other glyphs (22 wide in a 44
    // key), centred on its ink rather than its box.
    final mark = size * 0.5 / BrandMark.aspect;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: size,
          child: GlassSurface(
            tier: GlassTier.chrome,
            circle: true,
            grouped: true,
            onTap: onTap,
            child: Center(
              child: Transform.translate(
                offset: BrandMark.opticalShift(mark),
                child: BrandMark(size: mark, color: scheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The handle: 网页模式's one key, opening its ways back to the native app.
class WebHandleButton extends StatelessWidget {
  const WebHandleButton({super.key, required this.size, required this.onNative});

  final double size;

  /// 切回原生界面 (the caller hands the conversation over first).
  final Future<void> Function() onNative;

  static String get tooltip => appL10n.webNativeFeatures;

  @override
  Widget build(BuildContext context) {
    final tooltip = context.l10n.webNativeFeatures;
    return WebMarkButton(
      size: size,
      tooltip: tooltip,
      label: tooltip,
      onTap: () => unawaited(showWebHandleSheet(context, onNative: onNative)),
    );
  }
}

/// 切回原生界面 · App 设置 · 切换主机.
Future<void> showWebHandleSheet(BuildContext context, {required Future<void> Function() onNative}) =>
    showAppSheet<void>(context, builder: (_) => _HandleSheet(onNative: onNative));

class _HandleSheet extends ConsumerWidget {
  const _HandleSheet({required this.onNative});

  final Future<void> Function() onNative;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(activeHostProvider);
    final name = ref.watch(hostNameProvider(host)) ?? context.l10n.commonRemoteHost;
    final navigator = Navigator.of(context);
    void push(Widget page) => unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => page)));
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitleBar('DSH'),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              SettingsTile(
                key: const ValueKey('web-handle-native'),
                // 界面's mark, as in 设置 and the drawer.
                icon: AppIcons.swap,
                tinted: false,
                title: context.l10n.webSwitchToNative,
                chevron: false,
                onTap: () {
                  navigator.pop();
                  unawaited(onNative());
                },
              ),
              SettingsTile(
                key: const ValueKey('web-handle-settings'),
                icon: AppIcons.settings,
                tinted: false,
                title: context.l10n.webAppSettings,
                onTap: () {
                  navigator.pop();
                  push(const SettingsScreen());
                },
              ),
              SettingsTile(
                key: const ValueKey('web-handle-host'),
                icon: hostKindIcon(host.kind),
                tinted: false,
                title: context.l10n.webSwitchHost,
                value: Text(name),
                onTap: () {
                  navigator.pop();
                  unawaited(showHostSheet(navigator.context, onManage: () => push(const RemoteScreen())));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
