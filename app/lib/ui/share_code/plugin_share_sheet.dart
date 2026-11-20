// 「分享插件」 — a plugin as a link, a QR code, a picture card (when the market
// knows it) or plain text. Entry points for the plugin pages:
// [shareMarketPlugin] (a market entry) and [shareInstalledPlugin] (an
// installed bundle). The card's page is the share panel's 「图片」.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/plugin_share.dart';
import '../../share_code/share_models.dart';
import '../../share_code/share_net.dart';
import '../../state/plugins_state.dart' show MarketEntry;
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../plugins/plugin_widgets.dart' show PluginAvatar;
import '../share/share_entry.dart' show pluginCardContent, pluginShareText;
import '../share/share_image_page.dart';
import 'share_code_panel.dart';
import 'share_code_widgets.dart';

/// 「分享插件」 from a market entry ([version] defaults to the newest); [card]
/// adds 「图片」. [webLink] (the official market's page for it) is the link
/// copied, shown as a QR code and shared in place of the share code's.
Future<void> shareMarketPlugin(
  BuildContext context,
  MarketPlugin plugin, {
  MarketVersion? version,
  MarketEntry? card,
  String? webLink,
}) {
  final shared = sharedPluginFromMarket(plugin, version: version);
  if (shared == null) return _cannotShare(context);
  return showSharePluginSheet(context, plugin: shared, icon: plugin.icon, card: card, webLink: webLink);
}

/// 「分享插件」 from an installed bundle (local installs can't be shared);
/// [card] (the market's entry for it) adds 「图片」.
Future<void> shareInstalledPlugin(BuildContext context, PluginBundle bundle, {MarketEntry? card}) {
  final shared = sharedPluginFromBundle(bundle);
  if (shared == null) return _cannotShare(context);
  return showSharePluginSheet(context, plugin: shared, icon: bundle.meta?.icon, card: card);
}

Future<void> _cannotShare(BuildContext context) async {
  final l10n = context.l10n;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l10n.pluginsLocalPluginUnshareable)));
}

Future<void> showSharePluginSheet(
  BuildContext context, {
  required SharedPlugin plugin,
  String? icon,
  MarketEntry? card,
  String? webLink,
}) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.drag,
  isScrollControlled: true,
  builder: (_) => SheetNavigator(
    root: (_) => PluginShareSheet(plugin: plugin, icon: icon, card: card, webLink: webLink),
  ),
);

/// Source line of a shared plugin: `npm`, `GitHub · acme/notes`, `gitee.com`.
String pluginSourceText(SharedPlugin p, {String? publisher}) => switch (p.source) {
  PluginSourceKind.npm => publisher == null ? 'npm' : 'npm · $publisher',
  PluginSourceKind.github => 'GitHub · ${p.repository ?? p.name}',
  PluginSourceKind.git => p.repository ?? 'Git',
  PluginSourceKind.official => appL10n.pluginsDshOfficial,
};

class PluginShareSheet extends ConsumerStatefulWidget {
  const PluginShareSheet({super.key, required this.plugin, this.icon, this.card, this.webLink});

  final SharedPlugin plugin;
  final String? icon;

  /// The market's entry: its picture card is 「图片」.
  final MarketEntry? card;

  /// The official market's page, in place of the share code's link.
  final String? webLink;

  @override
  ConsumerState<PluginShareSheet> createState() => _PluginShareSheetState();
}

class _PluginShareSheetState extends ConsumerState<PluginShareSheet> {
  late SharedPlugin _plugin = widget.plugin;
  late PluginShare _payload = PluginShare(widget.plugin);

  @override
  void initState() {
    super.initState();
    // The registry's integrity makes the link checkable; the link works
    // without it, so nothing waits for this.
    unawaited(
      withNpmFacts(ref.read(shareNetProvider), widget.plugin).then((p) {
        if (mounted && p.integrity != _plugin.integrity) {
          setState(() {
            _plugin = p;
            _payload = PluginShare(p);
          });
        }
      }, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = _plugin;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.pluginsSharePlugin),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 12),
            child: ShareHero(
              leading: PluginAvatar(name: p.name, title: p.displayTitle, icon: widget.icon, size: 56),
              title: p.displayTitle,
              subtitle: p.author ?? p.summary,
            ),
          ),
          SheetGroup(
            children: [
              ListPageRow(title: l10n.pluginsSource, value: pluginSourceText(p)),
              ListPageRow(title: l10n.commonVersion, value: p.version ?? p.gitRef ?? '—'),
            ],
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
            child: ShareCodePanel(
              payload: _payload,
              title: p.displayTitle,
              webLink: widget.webLink,
              onImage: switch (widget.card) {
                final card? => () => SheetNavigator.of(context).push(
                  (page) => ShareImagePage(
                    content: pluginCardContent(page, card, webLink: widget.webLink),
                    linkText: pluginShareText(card, webLink: widget.webLink),
                  ),
                ),
                null => null,
              },
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
