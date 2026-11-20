// Which plugins get a 「设置」 entry, what it is called and whether it can be
// changed: every plugin entry whose Config has something to draw, wherever
// it is listed — its detail sheet, the inventory, 设置 › 引擎参数 › 插件, the
// settings search. A plugin is a row of a bundle the person chose —
// installed from the market or a local path, or an official optional bundle
// switched on ([PluginConfigScope]); DSH's core and the App's own rows never
// are, and an entry nobody recognises isn't either. A plugin without fields
// gets no entry, never an empty page. Where the Host reads forms one entry
// at a time (the dsh-go bridge), its own list says which entries can be
// configured until a form is read, and (bridge R7) which ones an overlay
// fixes.
//
// Names. A bundle with one entry to set is called by its title; a bundle
// with several (the voice-input kit's three) calls each
// 「bundle title · entry name」. The entry name is the row's own title, else
// one its schema gives itself, else the entry id made readable — the app's
// names for official entries, words for the rest. A row title that only
// repeats the package, or that the bundle or a sibling shares, says nothing
// and gives way to the id. A bundle without a title of its own adds nothing
// to its entries' names. (Bridge R7 labels every entry of a bundle with the
// bundle's title, which is why the label alone is never the name.) These
// names are for a Host whose list says who carries each entry (bridge R7);
// without it — no bridge routes as on runtime r12, an older bridge —
// everything is named and shown exactly as before.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show LocalizedText, PluginBundle, PluginBundleRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/plugin_config/plugin_config_state.dart';
import '../../../state/plugins_state.dart' show installedPluginsProvider;
import '../../engine_settings/engine_settings_page.dart' show curatedNamespaces, namespaceTitle;
import '../../engine_settings/namespace_copy.dart';
import '../../engine_settings/schema_fields.dart' show humanizeKey;
import 'plugin_config_layout.dart';

/// Entry [ns] gets a page here: a plugin's ([PluginConfigState.isPlugin]),
/// not one the app curates, and with at least one field (or, not read yet,
/// listed as configurable).
bool hasPluginConfig(PluginConfigState? state, String ns) {
  if (state == null || !state.isPlugin(ns) || curatedNamespaces.contains(ns)) return false;
  if (state[ns] case final form?) {
    return cachedPluginConfigLayout(form, copy: namespaceCopy[ns] ?? const {}).fieldCount > 0;
  }
  return state.lazy && (state.entries[ns]?.configurable ?? false);
}

/// Reads the plugin list again (its last read failed: nothing is a plugin
/// until one succeeds).
void retryPluginList(WidgetRef ref) =>
    unawaited(ref.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));

/// The entries with a page, in the Host's order.
List<String> pluginConfigEntries(PluginConfigState? state) => [
  for (final ns in state?.entries.keys ?? const <String>[])
    if (hasPluginConfig(state, ns)) ns,
];

/// Rows of [bundle] with a page (curated ones the engine serves included),
/// in bundle order. Empty while the bundle is off or nothing is known.
List<PluginBundleRow> bundleConfigRows(PluginBundle bundle, PluginConfigState? state) => [
  if (state != null && bundle.enabled)
    for (final row in bundle.rows)
      if ((curatedNamespaces.contains(row.rowId) && state.entries.containsKey(row.rowId)) ||
          hasPluginConfig(state, row.rowId))
        row,
];

/// What entry [ns]'s row says under its name when it can be read here but
/// not changed (the Host's list says so up front: bridge R7 `writable:
/// false`): 「由配置文件固定」 when an overlay sets it, else 「只读」. Null for
/// one that can be changed, and wherever the Host does not say (an older
/// bridge: as before, the form tells once read).
String? pluginConfigReadOnlyNote(PluginConfigState? state, String ns, {L10n? l10n}) {
  final entry = state?.entries[ns];
  if (entry == null || !entry.readOnly || !(state?.isPlugin(ns) ?? false)) return null;
  final l = l10n ?? appL10n;
  return entry.fixedByFile ? l.pluginConfigFixed : l.pluginConfigReadOnly;
}

/// The bundle entry [ns] belongs to: the one the Host names (bridge R7),
/// else a chosen bundle whose rows carry it ([PluginConfigScope.owns]),
/// else any listed bundle that does. Null when no bundle lists it.
PluginBundle? pluginConfigBundle(String ns, List<PluginBundle>? bundles, {PluginConfigState? state}) {
  final all = bundles ?? const <PluginBundle>[];
  bool carries(PluginBundle b) => b.rows.any((r) => r.rowId == ns);
  if (state?.entries[ns]?.bundle case final name?) {
    if (all.where((b) => b.name == name && carries(b)).firstOrNull case final bundle?) return bundle;
  }
  return all.where((b) => PluginConfigScope.owns(b) && carries(b)).firstOrNull ?? all.where(carries).firstOrNull;
}

/// The Host's list says who carries [ns] (bridge R7, runtime r14): the
/// names below apply. Without it — no bridge routes (DSH's own
/// `settings/describe`, as on runtime r12), an older bridge — every name is
/// what it was before R7 ([_namedBefore]): those Hosts label an entry with
/// its id, never all of a bundle's entries with one title.
bool pluginConfigNamedByBundle(PluginConfigState? state, String ns) => state?.entries[ns]?.owner != null;

/// What entry [ns] is called wherever it is listed and on its page: its
/// bundle's title when it is the bundle's only entry with a page,
/// 「bundle title · entry name」 when the bundle has several
/// ([pluginConfigEntryName]). A bundle without a title of its own adds
/// nothing: the entry's name (one entry: the app's or the row's, else the
/// package name). Outside any bundle: the Host's label, else the app's name
/// for it. [l10n] picks the language (the settings search matches both).
/// Not from bridge R7 ([pluginConfigNamedByBundle]): as before.
String pluginConfigTitle(String ns, List<PluginBundle>? bundles, {PluginConfigState? state, L10n? l10n}) {
  if (!pluginConfigNamedByBundle(state, ns)) return _namedBefore(ns, bundles, state);
  final l = l10n ?? appL10n;
  final group = _groupOf(ns, bundles, state, l);
  if (group == null) return namespaceTitle(ns);
  final title = group.title;
  if (group.names.length <= 1) return title ?? group.known ?? group.fallback;
  final name = group.names[ns]!;
  return title == null ? name : l.pluginConfigEntryTitle(title, name);
}

/// What entry [ns] was called before bridge R7, unchanged: its row's title,
/// else its bundle's when the bundle has one row, else the Host's label,
/// else the app's name for it; in the app's language.
String _namedBefore(String ns, List<PluginBundle>? bundles, PluginConfigState? state) {
  final locale = AppLocale.current.languageCode;
  for (final bundle in bundles ?? const <PluginBundle>[]) {
    for (final row in bundle.rows) {
      if (row.rowId != ns) continue;
      if (row.meta?.title case final title?) return title.resolve(locale);
      if (bundle.rows.length == 1) return bundle.title(locale);
    }
  }
  if (state?.entries[ns]?.label case final label?) return label.resolve(locale);
  return namespaceTitle(ns);
}

/// Entry [ns]'s own name among its bundle's entries: the row's title, else
/// the schema's, else the readable entry id ([pluginConfigIdName]); a name
/// that only repeats the package, the bundle's title or a sibling's gives
/// way to the id. What the bundle's detail sheet lists it as.
String pluginConfigEntryName(String ns, List<PluginBundle>? bundles, {PluginConfigState? state, L10n? l10n}) {
  final l = l10n ?? appL10n;
  return _groupOf(ns, bundles, state, l)?.names[ns] ?? pluginConfigIdName(ns, l10n: l);
}

/// Entry id [ns] made readable: the app's name for an official entry, else
/// its words (an `optional-` prefix dropped).
String pluginConfigIdName(String ns, {L10n? l10n}) =>
    _appName(ns, l10n ?? appL10n) ?? humanizeKey(ns.startsWith('optional-') ? ns.substring('optional-'.length) : ns);

/// The app's own name for an official entry: a small table for the
/// optional bundles' rows that have no title of their own, only their
/// package's name (`@deepseek-ai/dsh-experimental-translator`,
/// `workflow-ptc`) or one their bundle shares; then the engine namespaces
/// the app already names (`plugin-market`, `cot-translation`, …).
String? _appName(String ns, L10n l) =>
    switch (ns) {
      'speech-to-text' => l.pluginConfigNameSpeechToText,
      'speech-to-text-sensevoice' => l.pluginConfigNameSenseVoice,
      'api-speech-to-text' => l.pluginConfigNameSpeechApi,
      'translator' => l.pluginConfigNameTranslator,
      'optional-session-query-sqlite' => l.pluginConfigNameSessionIndex,
      'optional-tool-session-query' => l.pluginConfigNameSessionSearchTool,
      'optional-terminal-registry' => l.pluginConfigNameTerminalService,
      'optional-terminal-bash' => l.pluginConfigNameTerminalBash,
      'optional-terminal-pwsh' => l.pluginConfigNameTerminalPwsh,
      'optional-tool-terminal' => l.pluginConfigNameTerminalTools,
      'worktree' => l.pluginConfigNameWorktree,
      'tool-worktree' => l.pluginConfigNameWorktreeTools,
      'optional-ralph-workflow' => l.pluginConfigNameRalphWorkflow,
      'tool-ralph' => l.pluginConfigNameRalphTools,
      _ => null,
    } ??
    namespaceTitles[ns];

/// [ns]'s bundle as its entries are named: the bundle's own title (null
/// when it has none), each entry with a page by its name ([ns] included),
/// what [ns] is known as without falling back to its id, and the last
/// resort for a lone entry (the bundle's package name).
({String? title, Map<String, String> names, String? known, String fallback})? _groupOf(
  String ns,
  List<PluginBundle>? bundles,
  PluginConfigState? state,
  L10n l,
) {
  final locale = l.localeName;
  final bundle = pluginConfigBundle(ns, bundles, state: state);
  final String? title;
  final String fallback;
  final List<String> members;
  if (bundle != null) {
    title = bundle.meta?.title?.resolve(locale);
    fallback = bundle.name;
    members = [
      for (final row in bundle.rows)
        // Not known yet which have a page: every row, as before.
        if (row.rowId == ns || state == null || hasPluginConfig(state, row.rowId)) row.rowId,
    ];
  } else if (state?.entries[ns] case PluginConfigEntry(:final label?) && final entry) {
    // No bundle list: the Host's own word. R7 names the bundle and labels
    // each of its entries with the bundle's title.
    title = label.resolve(locale);
    fallback = title;
    final name = entry.bundle;
    members = [
      for (final MapEntry(:key, :value) in state!.entries.entries)
        if (key == ns || (name != null && value.bundle == name && hasPluginConfig(state, key))) key,
    ];
  } else {
    return null;
  }
  String? own(String id) {
    final row = bundle?.rows.where((r) => r.rowId == id).firstOrNull;
    if (row?.meta?.title case final LocalizedText text?) {
      final name = text.resolve(locale);
      if (!_onlyPackage(name, row!)) return name;
    }
    // Known once its form was read.
    final schema = state?[id]?.view.schema;
    return (schema?.meta.title ?? schema?.effective.meta.title)?.resolve(locale);
  }

  final names = {for (final id in members) id: own(id) ?? pluginConfigIdName(id, l10n: l)};
  String key(String name) => name.trim().toLowerCase();
  final counts = <String, int>{};
  for (final name in names.values) {
    counts.update(key(name), (n) => n + 1, ifAbsent: () => 1);
  }
  for (final id in names.keys.toList()) {
    final name = key(names[id]!);
    if (counts[name]! > 1 || (title != null && name == key(title))) names[id] = pluginConfigIdName(id, l10n: l);
  }
  return (title: title, names: names, known: own(ns) ?? _appName(ns, l), fallback: fallback);
}

/// [title] is only the row's package or id (what a plugin without a title
/// of its own shows): `@deepseek-ai/dsh-tool-session-query`, `dsh-media`,
/// `workflow-ptc`.
bool _onlyPackage(String title, PluginBundleRow row) {
  final t = title.trim().toLowerCase();
  final module = row.moduleName.toLowerCase();
  final bare = module.split('/').where((s) => s.isNotEmpty && !s.startsWith('@')).firstOrNull ?? module;
  return {
    module,
    ?modulePackage(module),
    bare,
    if (bare.startsWith('dsh-')) bare.substring('dsh-'.length),
    row.rowId.toLowerCase(),
  }.contains(t);
}
