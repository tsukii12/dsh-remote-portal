// The DSH Go sidecar of the official plugin index, `dsh-go.json`
// (docs/design/plugin-market.md §3): what format 1 has no room for — the
// tier, the zh/en title and summary, screenshots, the DSH Go protocol
// declaration, the risk the market's checks found, the npm integrity and the
// withdrawn versions. Read leniently like the index: an entry that breaks a
// rule is skipped, the rest of the file still counts.

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../update/version.dart';

/// Which official section an entry belongs to.
enum MarketTier { official, community }

/// Ordered: a later value is riskier.
enum MarketRisk { low, medium, high }

/// The level of each flag the market's checks set (§5). A flag this app
/// doesn't know has no level of its own; the entry's declared level covers it.
const marketRiskFlagLevels = <String, MarketRisk>{
  'install-scripts': MarketRisk.high,
  'native-code': MarketRisk.high,
  'shell': MarketRisk.medium,
  'filesystem': MarketRisk.medium,
  'obfuscated': MarketRisk.medium,
  'network': MarketRisk.low,
  'not-adapted': MarketRisk.low,
};

/// At most this many screenshots are shown.
const maxMarketScreenshots = 4;

/// One plugin in the sidecar, for the version the official index pins.
class DshGoListing {
  const DshGoListing({
    required this.name,
    required this.version,
    required this.tier,
    this.title,
    this.summary,
    this.screenshots = const [],
    this.adapted = false,
    this.minApp,
    this.features = const [],
    this.risk = MarketRisk.low,
    this.flags = const [],
    this.integrity,
    this.checkedAt,
    this.blockedVersions = const {},
  });

  final String name;

  /// The pinned version; it must be the one the index lists.
  final String version;
  final MarketTier tier;
  final LocalizedText? title;
  final LocalizedText? summary;

  /// https only.
  final List<Uri> screenshots;

  /// Uses the DSH Go native protocol (cards, forms, settings pages).
  final bool adapted;

  /// Older apps show the plugin but can't install it.
  final AppVersion? minApp;
  final List<String> features;

  /// The higher of the declared level and its known flags' (the market says
  /// the level is the highest flag's; a disagreement never lowers it).
  final MarketRisk risk;
  final List<String> flags;

  /// npm `dist.integrity` of [version].
  final String? integrity;
  final DateTime? checkedAt;

  /// Withdrawn versions: people who have one installed are warned.
  final Set<String> blockedVersions;

  /// Goes under 「适配 DSH Go」 (a community entry): declares the protocol and
  /// the checks didn't flag it as not adapted.
  bool get isAdapted => adapted && !flags.contains('not-adapted');

  /// Install asks first, listing the flags.
  bool get needsConfirm => risk != MarketRisk.low;
}

/// The whole sidecar.
class MarketSidecar {
  const MarketSidecar({this.generatedAt, this.plugins = const {}, this.issues = const []});

  static const empty = MarketSidecar();

  final DateTime? generatedAt;
  final Map<String, DshGoListing> plugins;

  /// Entries dropped while reading (empty for a valid file).
  final List<MarketIndexIssue> issues;
}

final _integrity = RegExp(r'^sha(?:256|384|512)-[A-Za-z0-9+/]+={0,2}$');

/// Reads a decoded `dsh-go.json`. Throws [MarketIndexException] only when it
/// isn't a schema-1 sidecar at all; a bad entry is skipped and recorded.
MarketSidecar parseMarketSidecar(Object? json) {
  if (json is! Map) throw const MarketIndexException(r'$', 'must be an object');
  if (json['schema'] != 1) throw const MarketIndexException(r'$.schema', 'must be 1');
  final raw = json['plugins'];
  if (raw is! Map) throw const MarketIndexException(r'$.plugins', 'must be an object');
  final issues = <MarketIndexIssue>[];
  final plugins = <String, DshGoListing>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    final path = '\$.plugins.$key';
    final listing = key is String ? _listing(key, value) : null;
    if (listing == null) {
      issues.add(MarketIndexIssue(path, 'is not a valid entry'));
    } else {
      plugins[key as String] = listing;
    }
  }
  return MarketSidecar(generatedAt: _time(json['generatedAt']), plugins: plugins, issues: issues);
}

/// Decodes JSON text and reads it with [parseMarketSidecar].
MarketSidecar parseMarketSidecarText(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (error) {
    throw MarketIndexException(r'$', 'is not JSON (${error.message})');
  }
  return parseMarketSidecar(json);
}

DshGoListing? _listing(String name, Object? value) {
  if (value is! Map) return null;
  final version = value['version'];
  if (version is! String || !isExactSemver(version)) return null;
  final tier = switch (value['tier']) {
    'official' => MarketTier.official,
    'community' => MarketTier.community,
    _ => null,
  };
  if (tier == null) return null;
  final risk = value['risk'];
  if (risk is! Map) return null;
  final declared = MarketRisk.values.where((r) => r.name == risk['level']).firstOrNull;
  if (declared == null) return null;
  final rawFlags = risk['flags'];
  if (rawFlags is! List || rawFlags.any((flag) => flag is! String || flag.isEmpty)) return null;
  final flags = _strings(rawFlags);
  final dshGo = value['dshGo'] is Map ? value['dshGo'] as Map : const {};
  final minAppText = dshGo['minApp'];
  final minApp = minAppText is String ? AppVersion.tryParse(minAppText) : null;
  // An unreadable minimum would let any app install it.
  if (minAppText != null && minApp == null) return null;
  final integrity = value['integrity'];
  return DshGoListing(
    name: name,
    version: version,
    tier: tier,
    title: LocalizedText.fromJson(value['title']),
    summary: LocalizedText.fromJson(value['summary']),
    screenshots: [
      for (final text in _strings(value['screenshots']))
        if (Uri.tryParse(text) case final uri? when uri.scheme == 'https' && uri.host.isNotEmpty) uri,
    ].take(maxMarketScreenshots).toList(growable: false),
    adapted: dshGo['adapted'] == true,
    minApp: minApp,
    features: _strings(dshGo['features']),
    risk: [
      declared,
      for (final flag in flags) ?marketRiskFlagLevels[flag],
    ].reduce((a, b) => a.index >= b.index ? a : b),
    flags: flags,
    integrity: integrity is String && _integrity.hasMatch(integrity) ? integrity : null,
    checkedAt: _time(value['checkedAt']),
    blockedVersions: _strings(value['blockedVersions']).toSet(),
  );
}

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().where((s) => s.isNotEmpty).toList(growable: false) : const [];

DateTime? _time(Object? value) => value is String ? DateTime.tryParse(value) : null;
