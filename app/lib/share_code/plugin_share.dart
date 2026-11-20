// 「分享插件」: a [SharedPlugin] from what the plugin pages already hold (a market
// entry or an installed bundle), plus the npm facts that make it checkable on
// the other side.

import 'package:dsh_client/dsh_client.dart';

import 'share_codec.dart';
import 'share_link.dart';
import 'share_models.dart';
import 'share_net.dart';

/// [version] (default: the newest) of a market entry; null when its source
/// can't travel in a link (a git URL that isn't https).
SharedPlugin? sharedPluginFromMarket(MarketPlugin plugin, {MarketVersion? version}) {
  final v = version ?? plugin.latest;
  final title = plugin.displayTitle();
  final summary = plugin.displayDescription();
  switch (v.source) {
    case MarketNpmSource():
      if (!isPackageName(plugin.name) || !isExactSemver(v.version)) return null;
      return SharedPlugin(
        name: plugin.name,
        source: PluginSourceKind.npm,
        spec: '${plugin.name}@${v.version}',
        version: v.version,
        title: title,
        author: plugin.author,
        summary: summary,
      );
    case MarketGitSource(:final url, :final commit, :final path):
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
      final spec = 'git+${url.endsWith('.git') ? url : '$url.git'}#$commit${path == null ? '' : '&path:/$path'}';
      try {
        return SharedPlugin.fromJson({
          'name': plugin.name,
          'source': uri.host == 'github.com' ? 'github' : 'git',
          'spec': spec,
          'version': v.version,
          'title': title,
          'author': ?plugin.author,
          'summary': ?summary,
        });
      } on ShareFormatException {
        return null;
      }
  }
}

/// An installed bundle; null for local installs and official entries that
/// only switch (those travel inside a profile, not on their own).
SharedPlugin? sharedPluginFromBundle(PluginBundle bundle) => SharedPlugin.fromInstalledSource(
  name: bundle.name,
  source: bundle.source,
  version: bundle.version,
  title: bundle.title(),
  summary: bundle.summary(),
);

/// Adds the registry's integrity (and the publisher as author when none is
/// known). Unchanged when the registry doesn't answer in time.
Future<SharedPlugin> withNpmFacts(ShareNet net, SharedPlugin plugin) async {
  if (plugin.source != PluginSourceKind.npm || plugin.version == null) return plugin;
  final facts = await net
      .npmFacts(plugin.name, plugin.version!)
      .timeout(const Duration(seconds: 8), onTimeout: () => null);
  if (facts == null) return plugin;
  return plugin.copyWith(integrity: facts.integrity, author: plugin.author ?? facts.publisher);
}

/// The landing-page link of [plugin] (no integrity: no network needed), for
/// QR codes on share images. Null when the plugin can't travel in a link.
String? pluginShareWebLink(SharedPlugin? plugin) =>
    plugin == null ? null : ShareLink.inline(ShareKind.plugin, encodeShareCode(PluginShare(plugin))).webLink;

/// [pluginShareWebLink] of a market entry's newest version.
String? marketPluginShareWebLink(MarketPlugin plugin) => pluginShareWebLink(sharedPluginFromMarket(plugin));
