// The settings index: every settings page and every row on them that a
// person may look for, in one table. A row takes its title from here (the
// `spot:` of SettingsTile and friends), so the page and the index can't drift
// apart; search, page links (`dshgo://open/<id>`) and the guide's paths all
// read the same entries. docs/design/settings-ia.md §4.5.
//
// Pure data: no page widgets here (they are in settings_pages.dart), so any
// row can import it.

import '../../../l10n/l10n.dart';

/// A piece of UI text, resolved in a given language.
typedef Label = String Function(L10n l10n);

/// How often people come for it; a search tie goes to the more frequent.
enum Freq {
  high(5),
  medium(2),
  low(0);

  const Freq(this.bonus);

  /// What it adds to a search score.
  final int bonus;
}

enum SpotCondition {
  openChat,
  animationsOn,
  engineField;

  String label(L10n l10n) => switch (this) {
    openChat => l10n.searchNeedsChat,
    animationsOn => l10n.searchNeedsAnimations,
    engineField => l10n.searchNeedsEngineField,
  };
}

enum SettingsPageId { hub, models, permission, agentPresets, appearance, remote, about }

/// One engine setting a spot anchors: the field [key] in any of [namespaces]
/// (shell settings live in `bash-sandbox` or `pwsh-sandbox`).
class SpotField {
  const SpotField(this.namespaces, this.key);

  final List<String> namespaces;
  final String key;

  bool matches(String ns, List<String> path) => path.length == 1 && path.single == key && namespaces.contains(ns);
}

/// A settings page: where it lives, what it is called, how links name it.
class SettingsPageMeta {
  SettingsPageMeta(
    this.id, {
    required this.title,
    this.parent = SettingsPageId.hub,
    this.group,
    this.keywords,
    this.ohosKeywords,
    this.freq = Freq.low,
    this.links = const [],
    this.condition,
    this.row = true,
    this.androidOnly = false,
    this.ohosOnly = false,
    this.iosToo = false,
  });

  final SettingsPageId id;
  final Label title;

  /// Its one home; null only for the hub.
  final SettingsPageId? parent;

  /// The hub group its row sits in, when [parent] is the hub.
  final Label? group;

  /// Comma-separated synonyms and old names (search_{zh,en}.arb).
  final Label? keywords;

  /// In place of [keywords] where they name what HarmonyOS doesn't have.
  final Label? ohosKeywords;
  final Freq freq;

  /// `dshgo://open/<id>` names, old ones included.
  final List<String> links;
  final SpotCondition? condition;

  /// Whether [parent] draws a row for it. 全部功能 has none: the drawer opens
  /// it, and search still finds it.
  final bool row;

  /// Android's own (androidSystemFeaturesProvider), and so is all that is on
  /// or under it ([SettingsIndex.androidOnly]).
  final bool androidOnly;

  /// HarmonyOS's own, where Android has a page of its own for the same idea.
  final bool ohosOnly;
  final bool iosToo;

  /// The row on [parent] that opens this page.
  late final SettingSpot entry = SettingSpot(
    'page:${id.name}',
    page: parent ?? SettingsPageId.hub,
    title: title,
    group: group,
    keywords: keywords,
    ohosKeywords: ohosKeywords,
    freq: freq,
    opens: id,
    condition: condition,
    androidOnly: androidOnly,
    ohosOnly: ohosOnly,
    iosToo: iosToo,
  );
}

/// One row (or one section of a page) a person may look for.
class SettingSpot {
  const SettingSpot(
    this.id, {
    required this.page,
    required this.title,
    this.group,
    this.keywords,
    this.ohosKeywords,
    this.freq = Freq.low,
    this.link,
    this.condition,
    this.opens,
    this.field,
    this.altTitle,
    this.ohosTitle,
    this.androidOnly = false,
    this.ohosOnly = false,
    this.iosToo = false,
    this.iosLacks = false,
  });

  /// Stable, unique: `phone-confirm`, `page:phone`.
  final String id;

  /// The page it is on.
  final SettingsPageId page;
  final Label title;

  /// The hub group, when [page] is the hub.
  final Label? group;

  /// Comma-separated synonyms and old names (search_{zh,en}.arb).
  final Label? keywords;

  /// In place of [keywords] where they name what HarmonyOS doesn't have.
  final Label? ohosKeywords;
  final Freq freq;

  /// `dshgo://open/<link>` opens [page] at this row.
  final String? link;
  final SpotCondition? condition;

  /// The page this row opens: an entry row.
  final SettingsPageId? opens;

  /// The engine setting it shows, on pages drawn from the engine's schema.
  final SpotField? field;

  /// The title the row shows in its other state (安全模式: 以安全模式启动 /
  /// 恢复正常模式).
  final Label? altTitle;

  /// In place of [title] where the row has another name on HarmonyOS.
  final Label? ohosTitle;

  /// The title on this OS, for what lists the spot away from its row.
  Label titleOn({required bool harmony}) => harmony ? ohosTitle ?? title : title;

  /// Android's own, on a page that isn't ([SettingsIndex.androidOnly]).
  final bool androidOnly;

  /// HarmonyOS's own ([SettingsPageMeta.ohosOnly]).
  final bool ohosOnly;

  /// One of [androidOnly]'s that iOS has as well: only HarmonyOS goes without.
  final bool iosToo;

  /// What Android and HarmonyOS have and iOS doesn't (a picture shortcut, the
  /// refresh rate, the rescue profile).
  final bool iosLacks;

  bool get isEntry => opens != null;
}

/// The index itself.
abstract final class SettingsIndex {
  static final Map<SettingsPageId, SettingsPageMeta> pages = {for (final p in _pages) p.id: p};

  /// Rows that aren't page entries.
  static final List<SettingSpot> rows = List.unmodifiable(_rows);

  /// Every spot: the rows and each page's entry.
  static final List<SettingSpot> spots = [
    for (final p in _pages)
      if (p.parent != null) p.entry,
    ..._rows,
  ];

  static final Map<String, SettingSpot> _byId = {for (final s in spots) s.id: s};

  static SettingsPageMeta page(SettingsPageId id) => pages[id]!;

  static SettingSpot? spot(String id) => _byId[id];

  static SettingSpot entry(SettingsPageId id) => pages[id]!.entry;

  /// The spots on [page], entries to its child pages included.
  static Iterable<SettingSpot> on(SettingsPageId page) => spots.where((s) => s.page == page);

  /// The page a `dshgo://open/<id>` link names, by its page links.
  static SettingsPageMeta? pageForLink(String id) => _pages.where((p) => p.links.contains(id)).firstOrNull;

  /// The row a `dshgo://open/<id>` link names.
  static SettingSpot? spotForLink(String id) => _rows.where((s) => s.link == id).firstOrNull;

  /// The row showing the engine setting [path] of namespace [ns].
  static SettingSpot? forField(String ns, List<String> path) =>
      _rows.where((s) => s.field?.matches(ns, path) ?? false).firstOrNull;

  /// Every link id the index answers.
  static Set<String> get linkIds => {for (final p in _pages) ...p.links, for (final s in _rows) ?s.link};

  /// Whether [spot] is Android's own: it says so, or a page on its way does.
  /// Search leaves these out on HarmonyOS (androidSystemFeaturesProvider).
  static bool androidOnly(SettingSpot spot) => spot.androidOnly || chain(spot.page).any((p) => page(p).androidOnly);

  /// Whether the `dshgo://open/<id>` link [id] leads to something [androidOnly]
  /// (on [ios], also to what it lacks: [SettingSpot.iosLacks]).
  static bool androidOnlyLink(String id, {bool ios = false}) {
    final spot = pageForLink(id)?.entry ?? spotForLink(id);
    return spot != null && (androidOnly(spot) && !(ios && spot.iosToo) || ios && spot.iosLacks);
  }

  /// Whether the `dshgo://open/<id>` link [id] leads to what only HarmonyOS has.
  static bool ohosOnlyLink(String id) => pageForLink(id)?.ohosOnly ?? false;

  /// The link to follow on HarmonyOS for [id]: 系统操作 stands in for 手机操控
  /// and its 解除限制, whose hard rules it hasn't got, and the permission page
  /// for 确认方式, which follows it there. Anything else is itself.
  static String ohosLink(String id) => id;

  /// Pages from the hub down to [id], both included.
  static List<SettingsPageId> chain(SettingsPageId id) {
    final out = <SettingsPageId>[];
    SettingsPageId? at = id;
    while (at != null) {
      out.insert(0, at);
      at = pages[at]!.parent;
    }
    return out;
  }

  /// The way there by name, as the guide writes it: 设置 › 手机操控 ›
  /// 确认方式. A page's own trail ends with its title.
  static List<String> trail(SettingSpot spot, L10n l10n) => [
    for (final p in chain(spot.isEntry ? spot.opens! : spot.page)) page(p).title(l10n),
    if (!spot.isEntry) spot.title(l10n),
  ];

  /// What a search result shows under its title: the pages it sits in, with
  /// the hub group after 设置 (设置 › AI › 权限). A page shows its own title
  /// last; a row shows the page it is on.
  static List<String> path(SettingSpot spot, L10n l10n) {
    final pages = chain(spot.isEntry ? spot.opens! : spot.page);
    final out = <String>[];
    for (final (i, p) in pages.indexed) {
      out.add(page(p).title(l10n));
      if (i == 0) {
        // The hub group of the next step down, or of the row itself.
        final group = pages.length > 1 ? page(pages[1]).group : spot.group;
        if (group != null) out.add(group(l10n));
      }
    }
    return out;
  }
}

// ── Pages ────────────────────────────────────────────────────────────────────

// The hub's groups, by intent (docs/design/settings-ia.md §4.2).
String _ai(L10n l) => l.hubGroupAi;
String _look(L10n l) => l.hubSettingsAppearance;
String _general(L10n l) => l.hubGroupGeneral;
String _hosts(L10n l) => l.hubGroupHosts;
String _help(L10n l) => l.hubGroupHelp;

final _pages = <SettingsPageMeta>[
  SettingsPageMeta(SettingsPageId.hub, title: (l) => l.commonSettings, parent: null, links: const ['settings']),
  SettingsPageMeta(
    SettingsPageId.models,
    title: (l) => l.hubSettingsProviders,
    group: _ai,
    keywords: (l) => l.searchKwModels,
    freq: Freq.medium,
    links: const ['models'],
  ),
  SettingsPageMeta(
    SettingsPageId.permission,
    title: (l) => l.featuresPermissions,
    group: _ai,
    keywords: (l) => l.searchKwPermission,
    freq: Freq.medium,
    links: const ['permission'],
  ),
  SettingsPageMeta(
    SettingsPageId.agentPresets,
    title: (l) => l.featuresAgentPresets,
    parent: SettingsPageId.hub,
    keywords: (l) => l.searchKwAgentPresets,
    links: const ['agent-presets'],
  ),
  SettingsPageMeta(
    SettingsPageId.appearance,
    title: (l) => l.pluginsTheme,
    group: _look,
    keywords: (l) => l.searchKwTheme,
    freq: Freq.medium,
    links: const ['appearance'],
  ),
  SettingsPageMeta(
    SettingsPageId.remote,
    title: (l) => l.commonRemoteHost,
    group: _hosts,
    keywords: (l) => l.searchKwRemote,
    freq: Freq.medium,
    links: const ['remote'],
  ),
  SettingsPageMeta(
    SettingsPageId.about,
    title: (l) => l.hubAbout,
    group: _help,
    keywords: (l) => l.searchKwAbout,
    links: const ['about'],
  ),
];

// ── Rows ─────────────────────────────────────────────────────────────────────

abstract final class Spots {
  static final chatTextSize = SettingSpot(
    'chat-text-size',
    page: SettingsPageId.hub,
    group: _look,
    title: (l) => l.hubSettingsChatTextSize,
    keywords: (l) => l.searchKwTextSize,
    freq: Freq.medium,
    link: 'chat-text-size',
  );
  static final foldTurns = SettingSpot(
    'fold-turns',
    page: SettingsPageId.hub,
    group: _look,
    title: (l) => l.hubSettingsCollapseSteps,
    keywords: (l) => l.searchKwFoldTurns,
  );
  static final language = SettingSpot(
    'language',
    page: SettingsPageId.hub,
    group: _general,
    title: (l) => l.localeTitle,
    keywords: (l) => l.searchKwLanguage,
  );
  static final permissionCurrent = SettingSpot(
    'permission-current',
    page: SettingsPageId.permission,
    title: (l) => l.featuresCurrentChat,
    keywords: (l) => l.searchKwPermissionCurrent,
    condition: SpotCondition.openChat,
  );
  static final permissionDefault = SettingSpot(
    'permission-default',
    page: SettingsPageId.permission,
    title: (l) => l.featuresNewChatDefault,
    keywords: (l) => l.searchKwPermissionDefault,
    freq: Freq.medium,
    link: 'permission-default',
  );
  static final darkMode = SettingSpot(
    'dark-mode',
    page: SettingsPageId.appearance,
    title: (l) => l.hubThemeLightDark,
    keywords: (l) => l.searchKwDarkMode,
    freq: Freq.medium,
    link: 'dark-mode',
  );
  static final accent = SettingSpot(
    'accent',
    page: SettingsPageId.appearance,
    title: (l) => l.pluginsColors,
    keywords: (l) => l.searchKwAccent,
    ohosKeywords: (l) => l.harmonyKwAccent,
  );
  static final wallpaper = SettingSpot(
    'wallpaper',
    page: SettingsPageId.appearance,
    title: (l) => l.wallpaperTitle,
    keywords: (l) => l.searchKwWallpaper,
  );
  static final version = SettingSpot(
    'version',
    page: SettingsPageId.about,
    title: (l) => l.commonVersion,
    keywords: (l) => l.searchKwVersion,
  );
  static final licenses = SettingSpot(
    'licenses',
    page: SettingsPageId.about,
    title: (l) => l.hubSettingsLicenses,
    keywords: (l) => l.searchKwLicenses,
  );
}

final _rows = <SettingSpot>[
  Spots.language,
  Spots.chatTextSize,
  Spots.foldTurns,
  Spots.darkMode,
  Spots.accent,
  Spots.wallpaper,
  Spots.version,
  Spots.licenses,
  Spots.permissionCurrent,
  Spots.permissionDefault,
];
