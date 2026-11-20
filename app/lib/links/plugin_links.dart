// A plugin's page in the official market: `https://go.dshtui.com/p/<name>`
// (docs/design/plugin-market.md §6). The page itself is the share host's;
// its 「用 DSH Go 打开」 hands over `dshgo://go.dshtui.com/p/<name>`, the
// same scheme as hosted conversation links, and both open the plugin's
// detail sheet here.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show MarketIndexException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../share_hosted/hosted_config.dart' show shareHostOrigin;
import '../state/plugins_state.dart';
import '../ui/plugins/plugin_detail_sheet.dart' show showMarketPluginSheet;
import 'app_links.dart';

final _packageName = RegExp(r'^(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$');

/// The page of [name] in the official market, the package name encoded as
/// one path segment (`/p/%40dsh-go%2Fmedia`).
String marketPluginLink(String name) => '$shareHostOrigin/p/${Uri.encodeComponent(name)}';

/// The package a plugin link names — https or `dshgo://`, on the share host,
/// the name encoded or not (`/p/@dsh-go/media`); null for anything else.
String? marketPluginLinkName(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != appLinkScheme) return null;
  if (uri.host.toLowerCase() != Uri.parse(shareHostOrigin).host || uri.userInfo.isNotEmpty || uri.hasPort) {
    return null;
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2 || segments.length > 3 || segments.first != 'p') return null;
  final name = segments.skip(1).join('/');
  return _packageName.hasMatch(name) && name.length <= 214 ? name : null;
}

/// [name]'s market entry: the official market's, else dshfind's. Null when
/// neither lists it.
Future<MarketEntry?> findMarketEntry(ProviderContainer container, String name) async {
  try {
    if ((await container.read(officialMarketProvider.future)).byName[name] case final entry?) return entry;
  } on MarketFetchException {
    // dshfind may still list it.
  } on MarketIndexException {
    // Same.
  }
  return (await container.read(marketCatalogProvider.future)).byName[name];
}

/// Opens [uri]'s plugin in its detail sheet over the home route; a plugin
/// neither market lists, or a market that can't be read, gets a toast.
/// False when [uri] isn't a plugin link.
Future<bool> openMarketPluginLink(BuildContext context, Uri uri) async {
  final name = marketPluginLinkName(uri);
  if (name == null) return false;
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final entry = await findMarketEntry(container, name);
    if (!context.mounted) return true;
    if (entry == null) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.marketLinkNotFound(name))));
      return true;
    }
    unawaited(showMarketPluginSheet(context, entry));
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text(error is MarketFetchException ? error.message : l10n.pluginsMarketInvalid)),
    );
  }
  return true;
}

/// Registers `<share host>/p` with [router] (https and `dshgo://` alike).
/// [LinkHost] calls it. Returns the unregister function.
VoidCallback registerPluginLinks(LinkRouter router) =>
    router.registerLinkHandler('${Uri.parse(shareHostOrigin).host}/p', (uri) async {
      final context = router.context;
      if (context == null) return false;
      return openMarketPluginLink(context, uri);
    });
