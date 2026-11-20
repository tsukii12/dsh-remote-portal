// An Agent preset's plugin list as the editor sees it: the top-level rows of
// the `agentPresets/read` YAML (entry-list dialect, `!!js` included) with
// the official Chinese names of their packages, the persona (system prompt),
// and the bundle that declares a new or changed preset — the only way a
// preset is written (`@deepseek-ai/dsh-agent-preset` README: a bundle patch
// installed with plugin_manager; creator mode writes it in a conversation).

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../../../l10n/l10n.dart';

/// Official names (`locale/zh.json` meta of each package) of the modules a
/// preset row can name; groups are named by their row id below.
Map<String, String> get _moduleNames => {
  '@deepseek-ai/dsh-agent-instructions': appL10n.featuresModuleInstructions,
  '@deepseek-ai/dsh-time-context': appL10n.featuresModuleTime,
  '@deepseek-ai/dsh-tool-bash': appL10n.featuresModuleBash,
  '@deepseek-ai/dsh-tool-bash-persistent': appL10n.featuresModulePersistentBash,
  '@deepseek-ai/dsh-tool-pwsh': appL10n.featuresModulePowerShell,
  '@deepseek-ai/dsh-tool-fs': appL10n.featuresModuleFiles,
  '@deepseek-ai/dsh-tool-fs-search': appL10n.featuresModuleFileSearch,
  '@deepseek-ai/dsh-tool-jobs': appL10n.featuresModuleJobs,
  '@deepseek-ai/dsh-tool-schedule': appL10n.featuresModuleSchedule,
  '@deepseek-ai/dsh-skill-filesystem': appL10n.featuresModuleLocalSkills,
  '@deepseek-ai/dsh-tool-skill': appL10n.featuresModuleSkillTool,
  '@deepseek-ai/dsh-command-goal': appL10n.featuresModuleGoalCommand,
  '@deepseek-ai/dsh-tool-goal': appL10n.featuresModuleGoalTool,
  '@deepseek-ai/dsh-plan-mode': appL10n.featuresModulePlan,
  '@deepseek-ai/dsh-compaction-basic': appL10n.featuresModuleCompaction,
  '@deepseek-ai/dsh-command-compact': appL10n.featuresModuleCompactCommand,
  '@deepseek-ai/dsh-tool-ask-user': appL10n.featuresModuleAskUser,
  '@deepseek-ai/dsh-tool-todo': appL10n.featuresModuleTodo,
  '@deepseek-ai/dsh-tool-web': appL10n.featuresModuleWeb,
  '@deepseek-ai/dsh-tool-present': appL10n.featuresModulePresent,
  '@deepseek-ai/dsh-tool-cordis': appL10n.featuresModuleCordis,
  '@deepseek-ai/dsh-tool-subagent': appL10n.featuresModuleSubagent,
  '@deepseek-ai/dsh-tool-subagent-control': appL10n.featuresModuleSubagentControl,
  '@deepseek-ai/dsh-tool-workflow': appL10n.featuresModuleWorkflow,
  '@deepseek-ai/dsh-plugin-manager/tools': appL10n.featuresModulePluginManager,
  '@deepseek-ai/dsh-plugin-market/tools': appL10n.featuresModulePluginMarket,
  '@deepseek-ai/dsh-agent-tool-presentation': appL10n.featuresModuleToolCalls,
  '@deepseek-ai/dsh-terminal': appL10n.featuresModuleTerminal,
  '@deepseek-ai/dsh-persona': appL10n.featuresModulePersona,
};

/// Names of the shipped presets' `cordis:group` rows.
Map<String, String> get _groupNames => {
  'planning': appL10n.featuresModulePlan,
  'compaction': appL10n.featuresModuleCompaction,
  'delegation': appL10n.featuresGroupDelegation,
  'persistent-shell': appL10n.featuresGroupTerminal,
};

/// The persona module: its `prefix` is the system prompt the editor edits.
const personaModule = '@deepseek-ai/dsh-persona';

/// Where a row is listed in the editor.
enum PresetRowKind { tool, skill, context }

/// One top-level row of the plugin list.
class PresetRow {
  const PresetRow({
    required this.id,
    required this.module,
    required this.text,
    this.disabled = false,
    this.condition,
    this.children = const [],
  });

  /// Row id (`tool-bash`, `planning`).
  final String id;

  /// Module the row names (`@deepseek-ai/dsh-tool-bash`, `cordis:group`).
  final String module;

  /// The row's YAML exactly as the Host rendered it (`!!js` kept).
  final String text;

  /// `disabled: true`.
  final bool disabled;

  /// A `disabled: !!js …` expression (the row switches with the platform).
  final String? condition;

  /// Child modules of a group row.
  final List<String> children;

  bool get isGroup => module == 'cordis:group';

  /// Only loads on Windows (`disabled: !!js process.platform !== 'win32'`):
  /// kept as is, not offered as a switch.
  bool get windowsOnly => condition?.replaceAll(' ', '').contains("!=='win32'") ?? false;

  /// The official Chinese name, else the row id.
  String get label =>
      (isGroup ? _groupNames[id] ?? (children.isEmpty ? null : _moduleNames[children.first]) : _moduleNames[module]) ??
      id;

  PresetRowKind get kind {
    final names = [module, ...children].join(' ');
    if (names.contains('skill')) return PresetRowKind.skill;
    if (id.startsWith('tool-') ||
        names.contains('dsh-tool-') ||
        names.contains('/tools') ||
        names.contains('terminal') ||
        id == 'present') {
      return PresetRowKind.tool;
    }
    return PresetRowKind.context;
  }
}

/// A parsed `agentPresets/read` document.
class PresetComposition {
  const PresetComposition(this.rows, {this.persona = const {}});

  static final _jsTag = RegExp(r'!!js\s+(.*)$');

  /// Splits [yaml] into top-level rows and reads each one (`!!js` values are
  /// read as text, the original lines are kept for writing back).
  factory PresetComposition.parse(String yaml) {
    final blocks = <List<String>>[];
    for (final line in const LineSplitter().convert(yaml)) {
      if (line.startsWith('- ')) {
        blocks.add([line]);
      } else if (blocks.isNotEmpty) {
        blocks.last.add(line);
      }
    }
    final rows = <PresetRow>[];
    var persona = const <String, Object?>{};
    for (final block in blocks) {
      while (block.isNotEmpty && block.last.trim().isEmpty) {
        block.removeLast();
      }
      final text = block.join('\n');
      final readable = [
        for (final line in block) line.replaceFirstMapped(_jsTag, (m) => jsonEncode('!!js ${m.group(1)}')),
      ].join('\n');
      Object? node;
      try {
        node = loadYaml(readable);
      } on Object {
        node = null;
      }
      final map = node is YamlList && node.isNotEmpty && node.first is YamlMap ? node.first as YamlMap : null;
      final module = map?['name'];
      final id = map?['id'] ?? module;
      if (map == null || id is! String || module is! String) {
        rows.add(PresetRow(id: 'row-${rows.length + 1}', module: '', text: text));
        continue;
      }
      final disabled = map['disabled'];
      final config = map['config'];
      rows.add(
        PresetRow(
          id: id,
          module: module,
          text: text,
          disabled: disabled == true,
          condition: disabled is String && disabled.startsWith('!!js ') ? disabled.substring(5) : null,
          children: [
            if (config is YamlList)
              for (final child in config)
                if (child is YamlMap && child['name'] is String) child['name'] as String,
          ],
        ),
      );
      if (module == personaModule && config is YamlMap) {
        persona = {for (final e in config.entries) '${e.key}': _plain(e.value)};
      }
    }
    return PresetComposition(rows, persona: persona);
  }

  final List<PresetRow> rows;

  /// The persona row's config (`prefix`, `complete`, …); empty without one.
  final Map<String, Object?> persona;

  bool get hasPersona => rows.any((r) => r.module == personaModule);

  /// The system prompt text (`persona.prefix`).
  String get prompt => persona['prefix'] is String ? persona['prefix']! as String : '';

  /// `persona.complete`: the prompt is the whole system prompt.
  bool get completePrompt => persona['complete'] == true;

  /// Rows the editor offers as switches (not the persona, not Windows-only).
  List<PresetRow> get switchable => [
    for (final r in rows)
      if (r.module.isNotEmpty && r.module != personaModule && !r.windowsOnly) r,
  ];

  /// Ids of the rows that load now (a `!!js` row counts as on).
  Set<String> get enabled => {
    for (final r in rows)
      if (!r.disabled) r.id,
  };

  /// The plugin list with [enabled] applied and the persona's prompt set to
  /// [prompt] / [complete]; untouched rows keep their exact text.
  String render({required Set<String> enabled, String? prompt, bool? complete}) {
    final out = <String>[];
    for (final row in rows) {
      if (row.module == personaModule) {
        final changed = (prompt != null && prompt != this.prompt) || (complete != null && complete != completePrompt);
        out.add(changed ? _persona(row, prompt ?? this.prompt, complete ?? completePrompt) : row.text);
        continue;
      }
      final on = enabled.contains(row.id);
      if (on == !row.disabled) {
        out.add(row.text);
      } else if (on) {
        out.add(_withoutDisabled(row.text));
      } else {
        out.add(_withDisabled(row.text));
      }
    }
    return out.join('\n');
  }

  String _persona(PresetRow row, String prompt, bool complete) {
    final config = {...persona, 'prefix': prompt};
    if (complete) {
      config['complete'] = true;
    } else {
      config.remove('complete');
    }
    return [
      '- id: ${row.id}',
      "  name: '$personaModule'",
      if (row.disabled) '  disabled: true',
      '  config:',
      for (final MapEntry(:key, :value) in config.entries) '    $key: ${jsonEncode(value)}',
    ].join('\n');
  }

  static final _disabledLine = RegExp(r'^  disabled:.*$', multiLine: true);

  static String _withDisabled(String text) {
    if (_disabledLine.hasMatch(text)) return text.replaceFirst(_disabledLine, '  disabled: true');
    final lines = text.split('\n');
    final name = lines.indexWhere((l) => l.startsWith('  name:'));
    lines.insert(name < 0 ? 1 : name + 1, '  disabled: true');
    return lines.join('\n');
  }

  static String _withoutDisabled(String text) =>
      text.split('\n').where((l) => l.trimRight() != '  disabled: true').join('\n');
}

Object? _plain(Object? value) => switch (value) {
  YamlMap() => {for (final e in value.entries) '${e.key}': _plain(e.value)},
  YamlList() => [for (final v in value) _plain(v)],
  _ => value,
};

// ── The bundle ───────────────────────────────────────────────────────────────

final _idPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// Why [id] can't name a new preset, or null.
String? presetIdError(String id, Set<String> taken) {
  if (id.isEmpty) return appL10n.featuresPresetIdRequired;
  if (id.length > 40) return appL10n.featuresPresetIdLength;
  if (!_idPattern.hasMatch(id)) return appL10n.featuresPresetIdFormat;
  if (taken.contains(id)) return appL10n.featuresPresetIdTaken;
  return null;
}

/// `Code Review` → `code-review`; null when nothing usable is left (a
/// Chinese name).
String? presetIdFromName(String name) {
  final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) return null;
  return slug.length > 40 ? slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '') : slug;
}

/// The two files of a bundle that declares one preset (the format of
/// `editing-cordis-compositions`, the creator mode's own skill).
class PresetBundle {
  const PresetBundle({
    required this.id,
    required this.name,
    required this.description,
    required this.plugins,
    this.order,
    this.packageName,
  });

  final String id;
  final String name;
  final String description;

  /// The plugin list YAML ([PresetComposition.render]).
  final String plugins;
  final int? order;

  /// Keeps an existing bundle's package name; default `@local/dsh-preset-<id>`.
  final String? packageName;

  String get package => packageName ?? '@local/dsh-preset-$id';

  /// Directory the creator writes the files to, in its workspace.
  String get directory => 'dsh-preset-$id';

  String get packageJson => const JsonEncoder.withIndent('  ').convert({
    'name': package,
    'version': '1.0.0',
    'private': true,
    'type': 'module',
    'dsh': {
      'bundle': {'patch': './cordis.patch.yml'},
    },
  });

  String get patch => [
    '- insert:',
    '    - id: preset-$id',
    "      name: '@deepseek-ai/dsh-agent-preset'",
    '      config:',
    '        id: $id',
    '        name: ${jsonEncode(name)}',
    if (description.isNotEmpty) '        description: ${jsonEncode(description)}',
    if (order case final o?) '        order: $o',
    '        plugins:',
    for (final line in const LineSplitter().convert(plugins)) line.isEmpty ? '' : '          $line',
  ].join('\n');

  /// The request creator mode receives: write the files verbatim, install
  /// (after removing [replacing], the bundle that declares it now).
  String request({String? replacing}) {
    final request = replacing == null
        ? appL10n.featuresPresetCreateRequest(name, id, directory)
        : appL10n.featuresPresetUpdateRequest(name, id, replacing, directory);
    return '$request'
        '`$directory/package.json`\n```json\n$packageJson\n```\n\n'
        '`$directory/cordis.patch.yml`\n```yaml\n$patch\n```';
  }
}
