// 「分享配置」: what the active engine can put in a profile share, as a checklist
// (with sizes), and the [ProfileShare] built from the ticked items.
//
// Settings: each namespace's user layer, cleaned by settings_sanitizer.dart.
// Plugins: third-party bundles installed from npm / GitHub at their exact
// version, plus official bundles switched on; local installs can't travel.
// Presets ride with the plugin that declares them. Skills and AGENTS.md are
// read from the on-device engine's files (no remote method reads them).

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../l10n/l10n.dart';
import 'guest_fs.dart';
import 'namespace_labels.dart';
import 'plugin_share.dart';
import 'settings_sanitizer.dart';
import 'share_models.dart';
import 'share_net.dart';

enum ExportSection { settings, plugins, skills, agentsMd }

/// One row of the checklist.
class ExportItem {
  const ExportItem({
    required this.id,
    required this.section,
    required this.title,
    this.subtitle,
    this.bytes = 0,
    this.unavailable,
    this.defaultOn = true,
    this.monoTitle = false,
  });

  /// `settings:<ns>`, `plugin:<name>`, `skill:<name>`, `agents-md`.
  final String id;
  final ExportSection section;
  final String title;
  final String? subtitle;

  /// JSON size of what the row adds.
  final int bytes;

  /// Why it can't be shared (the row is shown, not tickable).
  final String? unavailable;
  final bool defaultOn;

  /// The title is an id (an unknown settings namespace).
  final bool monoTitle;

  bool get available => unavailable == null;
}

/// What the active engine offers, and how to build the share.
class ProfileExportSource {
  ProfileExportSource({
    required this.hostLabel,
    required this.isLocal,
    required this.items,
    required this.settings,
    required this.plugins,
    required this.presets,
    required this.skills,
    this.agentsMd,
  });

  final String hostLabel;
  final bool isLocal;
  final List<ExportItem> items;

  /// Cleaned user layers by namespace.
  final Map<String, Map<String, Object?>> settings;

  /// Shareable plugins by bundle name.
  final Map<String, SharedPlugin> plugins;

  /// Presets each plugin declares.
  final Map<String, List<SharedPreset>> presets;
  final Map<String, SharedSkill> skills;
  final String? agentsMd;

  Iterable<ExportItem> section(ExportSection s) => items.where((i) => i.section == s);

  Set<String> get defaultSelection => {
    for (final i in items)
      if (i.available && i.defaultOn) i.id,
  };

  /// The share for the ticked [selected] item ids.
  ProfileShare build(Set<String> selected, {String? name, DateTime? now}) {
    final chosen = [
      for (final MapEntry(:key, :value) in plugins.entries)
        if (selected.contains('plugin:$key')) value,
    ];
    return ProfileShare(
      name: name,
      created: now ?? DateTime.now(),
      settings: {
        for (final MapEntry(:key, :value) in settings.entries)
          if (selected.contains('settings:$key')) key: value,
      },
      plugins: chosen,
      presets: [for (final p in chosen) ...?presets[p.name]],
      skills: [
        for (final MapEntry(:key, :value) in skills.entries)
          if (selected.contains('skill:$key')) value,
      ],
      agentsMd: selected.contains('agents-md') ? agentsMd : null,
    );
  }
}

int _jsonBytes(Object? value) => utf8.encode(jsonEncode(value)).length;

String _pluginSubtitle(SharedPlugin p) => switch (p.source) {
  PluginSourceKind.npm => 'npm · ${p.version}',
  PluginSourceKind.github => 'GitHub · ${p.repository ?? p.name}',
  PluginSourceKind.git => '${p.repository ?? 'Git'} · ${p.gitRef ?? ''}',
  PluginSourceKind.official => appL10n.pluginsOfficialPlugin,
};

/// Reads everything [client] (and, for the on-device engine, [fs]) can share.
Future<ProfileExportSource> loadProfileExport(
  DshClient client, {
  required String hostLabel,
  required bool isLocal,
  GuestFs? fs,
}) async {
  final items = <ExportItem>[];
  final settings = <String, Map<String, Object?>>{};
  final plugins = <String, SharedPlugin>{};
  final presets = <String, List<SharedPreset>>{};
  final skills = <String, SharedSkill>{};

  // Settings.
  try {
    final description = await client.describeSettings();
    for (final view in description.namespaces.values) {
      final clean = sanitizeNamespace(view);
      if (clean == null || clean.isEmpty) continue;
      settings[view.ns] = clean.values;
      items.add(
        ExportItem(
          id: 'settings:${view.ns}',
          section: ExportSection.settings,
          title: namespaceLabel(view.ns),
          monoTitle: !hasNamespaceLabel(view.ns),
          subtitle: appL10n.commonItemCount(clean.values.length),
          bytes: _jsonBytes({view.ns: clean.values}),
        ),
      );
    }
  } on DshException {
    // A carrier without settings access: nothing from this section.
  }

  // Plugins (and the presets they declare).
  List<AgentPresetInfo> presetInfo = const [];
  try {
    presetInfo = await client.listAgentPresets();
  } on DshException {
    // Names fall back to ids.
  }
  try {
    for (final bundle in await client.listBundles()) {
      SharedPlugin? shared;
      String? unavailable;
      if (bundle.official) {
        final on = bundle.installed || (bundle.optional && bundle.enabled);
        if (!on) continue;
        shared = SharedPlugin(
          name: bundle.name,
          source: PluginSourceKind.official,
          title: bundle.title(),
          summary: bundle.summary(),
        );
      } else if (bundle.installed) {
        shared = sharedPluginFromBundle(bundle);
        if (shared == null) unavailable = appL10n.pluginsLocalUnshareable;
      } else {
        continue; // Installation-provided infrastructure.
      }
      final declared = [
        for (final row in bundle.rows)
          if (row.moduleName == agentPresetModule && row.rowId.startsWith('preset-'))
            row.rowId.substring('preset-'.length),
      ];
      final presetList = [
        for (final id in declared)
          SharedPreset(id: id, name: presetInfo.where((p) => p.id == id).firstOrNull?.name, bundle: bundle.name),
      ];
      final subtitle = [
        if (shared != null) _pluginSubtitle(shared),
        if (presetList.isNotEmpty)
          appL10n.pluginsIncludesPresets(presetList.map((p) => p.displayName).join(appL10n.pluginsListSeparator)),
      ].join(' · ');
      if (shared != null) {
        plugins[bundle.name] = shared;
        if (presetList.isNotEmpty) presets[bundle.name] = presetList;
      }
      items.add(
        ExportItem(
          id: 'plugin:${bundle.name}',
          section: ExportSection.plugins,
          title: bundle.title(),
          subtitle: unavailable ?? (subtitle.isEmpty ? null : subtitle),
          bytes: shared == null
              ? 0
              : _jsonBytes(shared.toJson()) + _jsonBytes([for (final p in presetList) p.toJson()]),
          unavailable: unavailable,
        ),
      );
    }
  } on DshException {
    // No plugin list over this carrier.
  }

  // The on-device engine's files.
  String? agentsMd;
  if (isLocal && fs != null) {
    for (final local in await fs.readUserSkills()) {
      final unavailable = local.skill.files.values.any(containsSecret) ? appL10n.pluginsSecretsUnshareable : null;
      if (unavailable == null) skills[local.name] = local.skill;
      items.add(
        ExportItem(
          id: 'skill:${local.name}',
          section: ExportSection.skills,
          title: local.name,
          subtitle: unavailable ?? local.description,
          bytes: _jsonBytes(local.skill.toJson()),
          unavailable: unavailable,
        ),
      );
    }
    agentsMd = await fs.readUserAgentsMd();
    if (agentsMd != null) {
      final unavailable = containsSecret(agentsMd) ? appL10n.pluginsSecretsUnshareable : null;
      items.add(
        ExportItem(
          id: 'agents-md',
          section: ExportSection.agentsMd,
          title: 'AGENTS.md',
          subtitle: unavailable ?? appL10n.pluginsLineCount(agentsMd.split('\n').length),
          bytes: _jsonBytes(agentsMd),
          unavailable: unavailable,
          defaultOn: false,
        ),
      );
      if (unavailable != null) agentsMd = null;
    }
  }

  return ProfileExportSource(
    hostLabel: hostLabel,
    isLocal: isLocal,
    items: items,
    settings: settings,
    plugins: plugins,
    presets: presets,
    skills: skills,
    agentsMd: agentsMd,
  );
}

/// Adds npm integrity to [share]'s registry plugins (in parallel, within a
/// few seconds; plugins the registry doesn't answer for stay as they are).
Future<ProfileShare> withProfileNpmFacts(ShareNet net, ProfileShare share) async {
  if (!share.plugins.any((p) => p.source == PluginSourceKind.npm)) return share;
  final plugins = await Future.wait([for (final p in share.plugins) withNpmFacts(net, p)]);
  return ProfileShare(
    name: share.name,
    created: share.created,
    settings: share.settings,
    plugins: plugins,
    presets: share.presets,
    skills: share.skills,
    agentsMd: share.agentsMd,
  );
}

/// `1.2 KB`, `860 B`.
String formatShareBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  final kb = bytes / 1024;
  return kb < 100 ? '${kb.toStringAsFixed(1)} KB' : '${kb.round()} KB';
}
