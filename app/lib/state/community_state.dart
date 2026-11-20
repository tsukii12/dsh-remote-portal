import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/update_config.dart' show updateRepo;
import '../update/update_http.dart';

/// The 社区 hub's content: picked plugins, prompt ideas, group links and
/// news, curated by the maintainers in `community.json` at the root of the
/// project repository (docs/design/community.md). Nothing here is
/// written by users and nothing is uploaded.
///
/// Offline-safe: the copy bundled in `assets/community/community.json` is
/// there from the first launch, the last good download is cached, and a
/// newer `revision` from the network replaces both. Sources are tried in
/// order with the one that worked last time first, like the update feed.
///
/// Build-time override: `--dart-define=DSH_COMMUNITY_FEED=https://…/community.json`
/// tries a self-hosted copy first.

const communityAsset = 'assets/community/community.json';
const communitySchema = 1;

/// How often the hub asks the network (opening the page more often is free).
const communityRefreshInterval = Duration(hours: 6);

/// The largest feed accepted.
const communityMaxBytes = 256 * 1024;

const _feedDefine = String.fromEnvironment('DSH_COMMUNITY_FEED');

/// Where `community.json` is fetched from, in order: a self-hosted copy (when
/// built with one), GitHub raw, then jsDelivr's two CDNs (they serve the
/// same file from the repository, cached up to a few hours, and are usually
/// reachable where GitHub is not).
List<CommunitySource> defaultCommunitySources() => [
  if (_feedDefine.isNotEmpty) ?_selfHosted(_feedDefine),
  CommunitySource('github', Uri.parse('https://raw.githubusercontent.com/$updateRepo/main/community.json')),
  CommunitySource('jsdelivr', Uri.parse('https://cdn.jsdelivr.net/gh/$updateRepo@main/community.json')),
  CommunitySource('fastly', Uri.parse('https://fastly.jsdelivr.net/gh/$updateRepo@main/community.json')),
];

CommunitySource? _selfHosted(String url) => switch (Uri.tryParse(url)) {
  final uri? when uri.scheme == 'https' => CommunitySource('feed', uri),
  _ => null,
};

class CommunitySource {
  const CommunitySource(this.id, this.url);
  final String id;
  final Uri url;

  @override
  String toString() => '$id <$url>';
}

// ── Model ────────────────────────────────────────────────────────────────────

/// A recommended plugin; installed through the plugin market
/// (looked up by [name] in the market index).
class CommunityPlugin {
  const CommunityPlugin({required this.name, this.note});

  /// npm package name, as in the market index.
  final String name;

  /// One line on why (replaces the plugin's own description in the row).
  final String? note;
}

/// A prompt idea: opens a new conversation with [prompt] in the composer,
/// not sent.
class CommunityPrompt {
  const CommunityPrompt({required this.title, required this.prompt, this.summary, this.icon});

  final String title;
  final String? summary;
  final String prompt;

  /// A name from the hub's small icon set (`code`, `chart`, …).
  final String? icon;
}

/// Where people talk: a QQ / WeChat / Telegram group, a forum.
class CommunityGroup {
  const CommunityGroup({required this.kind, required this.title, this.subtitle, this.url, this.qr, this.copy});

  /// `qq`, `wechat`, `telegram`, `discord`, `forum`, `github`, or anything
  /// else (a link).
  final String kind;
  final String title;
  final String? subtitle;

  /// Opened in the browser / the app that handles it (https only).
  final String? url;

  /// What the QR code encodes (defaults to [url]).
  final String? qr;

  /// Copied by 「复制」: a group number, an account id.
  final String? copy;

  String? get qrData => qr ?? url;
}

/// One line of news.
class CommunityUpdate {
  const CommunityUpdate({required this.date, required this.title, this.summary, this.url});

  final DateTime date;
  final String title;
  final String? summary;
  final String? url;
}

/// A parsed `community.json`.
class CommunityFeed {
  const CommunityFeed({
    required this.revision,
    this.updatedAt,
    this.tagline,
    this.plugins = const [],
    this.prompts = const [],
    this.groups = const [],
    this.updates = const [],
  });

  /// Grows with every edit; an older copy (a stale CDN) never replaces a newer one.
  final int revision;
  final DateTime? updatedAt;

  /// The overview card's second line.
  final String? tagline;
  final List<CommunityPlugin> plugins;
  final List<CommunityPrompt> prompts;
  final List<CommunityGroup> groups;
  final List<CommunityUpdate> updates;

  static const empty = CommunityFeed(revision: 0);

  bool get isEmpty => plugins.isEmpty && prompts.isEmpty && groups.isEmpty && updates.isEmpty;

  /// Reads [text]. A wrong schema or shape throws [FormatException]; single
  /// entries that are malformed (or link anywhere but https) are dropped.
  static CommunityFeed parse(String text) {
    final Object? json = jsonDecode(text);
    if (json is! Map<String, Object?>) throw const FormatException('not an object');
    if (json['schema'] != communitySchema) throw FormatException('schema ${json['schema']}');
    final revision = json['revision'];
    if (revision is! int || revision < 0) throw const FormatException('revision');

    List<T> list<T>(String key, T? Function(Map<String, Object?>) read) => [
      if (json[key] case final List<Object?> items)
        for (final item in items.take(50))
          if (item is Map<String, Object?>) ?read(item),
    ];

    return CommunityFeed(
      revision: revision,
      updatedAt: _date(json['updatedAt']),
      tagline: _text(json['tagline'], 40),
      plugins: list('plugins', (m) {
        final name = _text(m['name'], 214);
        if (name == null || !_packageName.hasMatch(name)) return null;
        return CommunityPlugin(name: name, note: _text(m['note'], 60));
      }),
      prompts: list('prompts', (m) {
        final title = _text(m['title'], 24);
        final prompt = _text(m['prompt'], 4000, multiline: true);
        if (title == null || prompt == null) return null;
        return CommunityPrompt(
          title: title,
          prompt: prompt,
          summary: _text(m['summary'], 40),
          icon: _text(m['icon'], 24),
        );
      }),
      groups: list('groups', (m) {
        final title = _text(m['title'], 24);
        final url = _https(m['url']);
        final qr = _text(m['qr'], 500);
        final copy = _text(m['copy'], 64);
        // A QR code that looks like a link must be an https one too.
        final qrOk = qr == null || !qr.contains('://') || _https(qr) != null;
        if (title == null || !qrOk || (url == null && qr == null && copy == null)) return null;
        return CommunityGroup(
          kind: _text(m['kind'], 16)?.toLowerCase() ?? 'link',
          title: title,
          subtitle: _text(m['subtitle'], 40),
          url: url,
          qr: qr,
          copy: copy,
        );
      }),
      updates: list('updates', (m) {
        final date = _date(m['date']);
        final title = _text(m['title'], 40);
        if (date == null || title == null) return null;
        return CommunityUpdate(date: date, title: title, summary: _text(m['summary'], 120), url: _https(m['url']));
      }),
    );
  }

  static final _packageName = RegExp(r'^(?:@[a-z0-9][\w.-]*/)?[a-z0-9][\w.-]*$');

  static String? _text(Object? value, int max, {bool multiline = false}) {
    if (value is! String || value.trim().isEmpty) return null;
    // A prompt keeps its trailing blank lines: 「报错如下：\n\n」 leaves the
    // cursor where the paste goes.
    final text = multiline
        ? value.trimLeft().replaceAll(RegExp(r'[ \t]+$', multiLine: true), '')
        : value.trim().replaceAll(RegExp(r'\s+'), ' ');
    return text.length <= max ? text : '${text.substring(0, max - 1)}…';
  }

  static String? _https(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri.toString();
  }

  static DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value) : null;
}

// ── State ────────────────────────────────────────────────────────────────────

enum CommunityOrigin { bundled, cached, network }

class CommunityState {
  const CommunityState({required this.feed, required this.origin, this.fetchedAt, this.refreshing = false});

  final CommunityFeed feed;
  final CommunityOrigin origin;

  /// Last time a source answered (with this revision or an older one).
  final DateTime? fetchedAt;
  final bool refreshing;

  CommunityState copyWith({CommunityFeed? feed, CommunityOrigin? origin, DateTime? fetchedAt, bool? refreshing}) =>
      CommunityState(
        feed: feed ?? this.feed,
        origin: origin ?? this.origin,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        refreshing: refreshing ?? this.refreshing,
      );
}

// Seams (tests override these).
final communityHttpProvider = Provider<UpdateHttp>((ref) => IoUpdateHttp());
final communitySourcesProvider = Provider<List<CommunitySource>>((ref) => defaultCommunitySources());
final communityBundleProvider = Provider<Future<String> Function()>(
  (ref) =>
      () => rootBundle.loadString(communityAsset),
);
final communityClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class CommunityController extends AsyncNotifier<CommunityState> {
  static const _feedKey = 'community.feed';
  static const _fetchedKey = 'community.fetchedAt';
  static const _sourceKey = 'community.source';

  @override
  Future<CommunityState> build() async {
    final prefs = await SharedPreferences.getInstance();
    var best = const CommunityState(feed: CommunityFeed.empty, origin: CommunityOrigin.bundled);
    try {
      best = CommunityState(
        feed: CommunityFeed.parse(await ref.read(communityBundleProvider)()),
        origin: CommunityOrigin.bundled,
      );
    } catch (_) {}
    final fetched = prefs.getInt(_fetchedKey);
    final fetchedAt = fetched == null ? null : DateTime.fromMillisecondsSinceEpoch(fetched);
    if (prefs.getString(_feedKey) case final cached?) {
      try {
        final feed = CommunityFeed.parse(cached);
        if (feed.revision > best.feed.revision) best = CommunityState(feed: feed, origin: CommunityOrigin.cached);
      } catch (_) {
        unawaited(prefs.remove(_feedKey));
      }
    }
    best = best.copyWith(fetchedAt: fetchedAt);
    final now = ref.read(communityClockProvider)();
    final due = fetchedAt == null || now.isBefore(fetchedAt) || now.difference(fetchedAt) >= communityRefreshInterval;
    if (due) Future.microtask(refresh);
    return best;
  }

  /// Asks the sources (preferred one first) for a newer feed. Quiet on
  /// failure: the hub keeps what it shows.
  Future<void> refresh() async {
    final current = state.value ?? await future;
    if (current.refreshing) return;
    state = AsyncData(current.copyWith(refreshing: true));
    final prefs = await SharedPreferences.getInstance();
    final http = ref.read(communityHttpProvider);
    final sources = [...ref.read(communitySourcesProvider)];
    final preferred = prefs.getString(_sourceKey);
    final i = sources.indexWhere((s) => s.id == preferred);
    if (i > 0) sources.insert(0, sources.removeAt(i));

    var next = current.copyWith(refreshing: false);
    for (final source in sources) {
      try {
        final response = await http.get(
          source.url,
          headers: const {'accept': 'application/json'},
          timeout: const Duration(seconds: 10),
        );
        if (response.status != 200) {
          await response.discard();
          continue;
        }
        final text = await response.text(maxBytes: communityMaxBytes, timeout: const Duration(seconds: 15));
        final feed = CommunityFeed.parse(text);
        final now = ref.read(communityClockProvider)();
        unawaited(prefs.setInt(_fetchedKey, now.millisecondsSinceEpoch));
        unawaited(prefs.setString(_sourceKey, source.id));
        next = next.copyWith(fetchedAt: now);
        if (feed.revision > current.feed.revision ||
            (feed.revision == current.feed.revision && current.origin == CommunityOrigin.bundled)) {
          unawaited(prefs.setString(_feedKey, text));
          next = next.copyWith(feed: feed, origin: CommunityOrigin.network);
        }
        break;
      } catch (_) {
        continue;
      }
    }
    if (ref.mounted) state = AsyncData(next);
  }
}

final communityProvider = AsyncNotifierProvider<CommunityController, CommunityState>(CommunityController.new);
