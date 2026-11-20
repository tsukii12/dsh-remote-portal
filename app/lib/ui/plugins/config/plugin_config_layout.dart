// How a plugin's configuration page orders its fields (pure, so the choices
// are unit-tested on their own): what a person comes for first — what must be
// filled in, keys, switches and choices, what the plugin tunes live — then
// the rest in the plugin's own order, and the plumbing (timeouts, limits,
// paths, endpoints with a working default) folded under 「高级」 once a form
// is long — unless the schema folds groups of its own, whose layout stands.
// A search over titles, descriptions, keys and choices shows every match,
// folded or not.

import 'dart:ui' show Locale;

import '../../../l10n/l10n.dart';
import '../../../state/engine_settings_state.dart';
import '../../../state/plugin_config/plugin_config_api.dart';
import '../../engine_settings/schema_fields.dart';
import '../../engine_settings/schema_form.dart' show SchemaFieldSpec, SchemaFormSection, schemaSections;

/// Where a field sits on the page.
enum ConfigTier {
  /// First in its group.
  primary,

  /// In the plugin's own order.
  regular,

  /// Under 「高级」 on a long form.
  advanced,
}

final _plumbingKey = RegExp(
  r'(Ms|Millis|Seconds|Sec|Bytes|Tokens|Timeout|Interval|Threshold|Padding|Grace|Retries|Retry|Backoff|'
  r'Concurrency|Pending|Probe|Buffer|Cache|Ttl|TTL|Debug|Verbose|Log|Logs|Path|Root|Dir|Directory|File|Origin|'
  r'Origins|Endpoint|Endpoints)$',
);
final _plumbingPrefix = RegExp(r'^(max|min|debug|verbose|log)([A-Z_]|$)');

bool _hasWorkingDefault(SchemaNode node) {
  final meta = node.effective.meta;
  if (meta.hasDefault && meta.defaultValue != null) return true;
  return node.meta.hasDefault && node.meta.defaultValue != null;
}

/// The tier of field [key].
ConfigTier configTierOf(String key, SchemaNode node, {bool live = false}) {
  final kind = kindOf(node);
  final meta = node.effective.meta;
  final required = (meta.required || node.meta.required) && !_hasWorkingDefault(node);
  if (kind == FieldKind.secret || required) return ConfigTier.primary;
  final badges = {...meta.badges, ...node.meta.badges};
  if (badges.contains('deprecated')) return ConfigTier.advanced;
  final plumbing = _plumbingKey.hasMatch(key) || _plumbingPrefix.hasMatch(key);
  if (plumbing && !live) return ConfigTier.advanced;
  final unit = kind == FieldKind.number ? unitFor(key, node) : FieldUnit.plain;
  if (unit != FieldUnit.plain && unit != FieldUnit.ratio && !live) return ConfigTier.advanced;
  if (live || kind == FieldKind.toggle || kind == FieldKind.choice) return ConfigTier.primary;
  return ConfigTier.regular;
}

/// A form folds its plumbing once it has this many fields, at least
/// [_minFolded] of them plumbing and something else left in view.
const _foldFrom = 7;
const _minFolded = 3;

/// The schema folds groups of its own (`.collapse()`): its author laid the
/// form out, so the page adds no folding of its own.
bool declaresCollapse(SchemaNode root) {
  final seen = <SchemaNode>{};
  bool walk(SchemaNode source, int depth) {
    final node = source.effective;
    if (depth > 32 || !seen.add(node)) return false;
    if (source.meta.collapse || node.meta.collapse) return true;
    return [...node.dict.values, ...node.list, ?node.inner].any((child) => walk(child, depth + 1));
  }

  return walk(root, 0);
}

/// The page's fields, in order.
class PluginConfigLayout {
  const PluginConfigLayout({
    required this.sections,
    this.advanced = const [],
    this.fieldCount = 0,
    this.authored = false,
  });

  /// What shows, groups in schema order, each group's fields by tier.
  final List<SchemaFormSection> sections;

  /// Under 「高级」, by the group they came from.
  final List<SchemaFormSection> advanced;

  /// Fields the form draws (a search counts them all).
  final int fieldCount;

  /// The schema folds its own groups ([declaresCollapse]).
  final bool authored;

  int get advancedCount => advanced.fold(0, (n, s) => n + s.fields.length);

  bool get isEmpty => sections.every((s) => s.fields.isEmpty) && advanced.isEmpty;
}

/// What a field is found by: title, description, key, path and choices.
String configSearchText(SchemaFieldSpec field, SchemaNode node) {
  final copy = field.copy;
  return [
    labelFor(field.key, node, copy),
    ?hintFor(node, copy),
    ?(node.meta.description ?? node.effective.meta.description)?.values.values.join('\n'),
    field.key,
    humanizeKey(field.key),
    field.path.join('.'),
    if (kindOf(node) == FieldKind.choice) for (final (_, label) in choicesFor(node, copy)) label,
  ].join('\n').toLowerCase();
}

/// [form] laid out for its page; with a [query], only the fields it matches
/// (nothing folded).
PluginConfigLayout pluginConfigLayout(
  PluginConfigForm form, {
  Map<String, FieldCopy> copy = const {},
  String query = '',
}) {
  final view = form.view;
  final sections = schemaSections(view, copy: copy);
  SchemaNode? nodeOf(SchemaFieldSpec f) => f.fallbackNode ?? schemaAt(view.schema, f.path);
  final drawn = [
    for (final section in sections)
      SchemaFormSection(
        title: section.title,
        footer: section.footer,
        fields: [
          for (final f in section.fields)
            if (nodeOf(f) case final node? when f.fallbackNode != null || kindOf(node) != FieldKind.hidden) f,
        ],
      ),
  ];
  final count = drawn.fold(0, (n, s) => n + s.fields.length);

  final terms = query.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (terms.isNotEmpty) {
    bool matches(SchemaFieldSpec f) {
      final node = nodeOf(f);
      if (node == null) return false;
      final text = configSearchText(f, node);
      return terms.every(text.contains);
    }

    return PluginConfigLayout(
      fieldCount: count,
      sections: [
        for (final s in drawn)
          if (s.fields.where(matches).toList() case final fields when fields.isNotEmpty)
            SchemaFormSection(title: s.title, fields: fields),
      ],
    );
  }

  ConfigTier tier(SchemaFieldSpec f) {
    final node = nodeOf(f);
    if (node == null || f.fallbackNode != null) return ConfigTier.regular;
    return configTierOf(f.key, node, live: !form.allLive && form.isLive(f.path));
  }

  final tiers = {for (final s in drawn) for (final f in s.fields) f.ref.key: tier(f)};
  final folded = tiers.values.where((t) => t == ConfigTier.advanced).length;
  final authored = declaresCollapse(view.schema);
  final fold = !authored && count >= _foldFrom && folded >= _minFolded && folded < count;
  List<SchemaFieldSpec> ordered(List<SchemaFieldSpec> fields) => [
    for (final t in ConfigTier.values)
      for (final f in fields)
        if (tiers[f.ref.key] == t && (!fold || t != ConfigTier.advanced)) f,
  ];
  return PluginConfigLayout(
    fieldCount: count,
    authored: authored,
    sections: [
      for (final s in drawn)
        if (ordered(s.fields) case final fields when fields.isNotEmpty)
          SchemaFormSection(title: s.title, footer: s.footer, fields: fields),
    ],
    advanced: [
      if (fold)
        for (final s in drawn)
          if (s.fields.where((f) => tiers[f.ref.key] == ConfigTier.advanced).toList() case final fields
              when fields.isNotEmpty)
            SchemaFormSection(title: s.title, fields: fields),
    ],
  );
}

/// [pluginConfigLayout], worked out once per schema: the page asks on every
/// build and every keystroke of its search, the lists that offer the page
/// ([hasPluginConfig]) on each of theirs. A layout reads only the form's
/// schema, namespace and liveness, [copy], [query] and the language, so a
/// form that is the same schema with other values (a live write, a refresh
/// that brought the same schema) keeps it. One search is kept beside the
/// unfiltered layout.
PluginConfigLayout cachedPluginConfigLayout(
  PluginConfigForm form, {
  Map<String, FieldCopy> copy = const {},
  String query = '',
}) {
  final layouts = _layouts[form.view.schema] ??= {};
  final key = (form.ns, form.allLive, copy, query.trim().toLowerCase(), AppLocale.current);
  if (layouts[key] case final layout?) return layout;
  if (key.$4.isNotEmpty) layouts.removeWhere((k, _) => k.$4.isNotEmpty);
  return layouts[key] = pluginConfigLayout(form, copy: copy, query: query);
}

final _layouts = Expando<Map<(String, bool, Map<String, FieldCopy>, String, Locale), PluginConfigLayout>>(
  'pluginConfigLayout',
);

/// The title of the folded group.
String get advancedGroupTitle => appL10n.pluginConfigAdvanced;
