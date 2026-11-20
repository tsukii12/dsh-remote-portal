import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/smooth_size.dart';
import '../settings/settings_widgets.dart' show SettingsMetrics, SettingsSection;
import '../theme/theme.dart';
import 'field_row.dart';
import 'schema_fields.dart';
import 'schema_form.dart' show SchemaFieldSpec, SchemaFormSection;

/// A collapsed container: its structural identity, its label, and how many
/// keys deep its object sits (its own fields are one deeper).
typedef _CollapseGroup = ({String key, String title, int depth});

/// Keep structural ancestors: flattening an intersect loses the metadata of
/// the member object that owns a field. Later members take precedence, as in
/// schemaAt. Structural identities also distinguish equal display labels.
List<_CollapseGroup> _groupsForField(SchemaFieldSpec field, EngineSettings settings, String? heading) {
  final view = settings[field.ns];
  if (view == null) return const [];
  List<_CollapseGroup>? walk(
    SchemaNode source,
    List<String> remaining,
    List<String> path,
    List<Object> address,
    Set<SchemaNode> ancestors,
  ) {
    final node = source.effective;
    if (ancestors.contains(node) || ancestors.length >= 32) return null;
    final next = {...ancestors, node};
    final own = <_CollapseGroup>[
      if ((source.meta.collapse || node.meta.collapse) && (node.type == 'object' || node.type == 'intersect'))
        (
          key: jsonEncode([field.ns, ...address]),
          title: labelFor(
            path.isEmpty ? field.ns : path.last,
            source,
            FieldCopy(label: address.isEmpty && source.meta.description == null ? heading : null),
          ),
          depth: path.length,
        ),
    ];
    if (remaining.isEmpty) return own;
    if (node.type == 'intersect') {
      for (var index = node.list.length - 1; index >= 0; index--) {
        final nested = walk(node.list[index], remaining, path, [
          ...address,
          ['member', index],
        ], next);
        if (nested != null) return [...own, ...nested];
      }
      return null;
    }
    final key = remaining.first;
    final child = node.type == 'object'
        ? node.dict[key]
        : (node.type == 'array' || node.type == 'dict')
        ? node.inner
        : null;
    if (child == null) return null;
    final nested = walk(
      child,
      remaining.sublist(1),
      [...path, key],
      [
        ...address,
        ['field', key],
      ],
      next,
    );
    return nested == null ? null : [...own, ...nested];
  }

  return walk(view.schema, field.path, const [], const [], <SchemaNode>{}) ?? const [];
}

/// A legacy/curated section can contain fields from different intersection
/// members. Split only at a different collapsed ancestry; never fold an
/// unrelated free sibling just because it shared the original section.
List<SchemaFormSection> splitCollapsedSections(List<SchemaFormSection> sections, EngineSettings? settings) {
  if (settings == null) return sections;
  if (!sections.any(
    (section) => section.fields.any((field) => _groupsForField(field, settings, section.title).isNotEmpty),
  )) {
    return sections;
  }
  final result = <SchemaFormSection>[];
  final seen = <String>{};
  for (final source in sections) {
    final unique = source.children != null
        ? source.fields
        : [
            for (final field in source.fields)
              if (seen.add(field.ref.key)) field,
          ];
    if (source.children == null && unique.isEmpty) continue;
    final section = SchemaFormSection(
      title: source.title,
      fields: unique,
      children: source.children,
      footer: source.footer,
    );
    if (section.children != null || section.fields.length < 2) {
      result.add(section);
      continue;
    }
    final runs = <List<SchemaFieldSpec>>[];
    String? previous;
    for (final field in section.fields) {
      final signature = jsonEncode([for (final group in _groupsForField(field, settings, section.title)) group.key]);
      if (previous != signature) runs.add([]);
      runs.last.add(field);
      previous = signature;
    }
    if (runs.length == 1) {
      result.add(section);
    } else {
      for (var index = 0; index < runs.length; index++) {
        result.add(
          SchemaFormSection(
            title: section.title,
            fields: runs[index],
            footer: index == runs.length - 1 ? section.footer : null,
          ),
        );
      }
    }
  }
  return result;
}

/// One section of a form with its rows built.
typedef SchemaFormEntry = ({SchemaFormSection section, List<Widget> rows});

/// [entries] as the cards of a page. A run of entries under a collapsed
/// container becomes one card whose first row is the container's header;
/// open, the fields follow in the same card, and a collapsed container inside
/// it is one more header row there. [uniform] wraps a card with the sections
/// it shows, whose capsule rows share one layout.
///
/// Honor only metadata actually received from settings/describe. Some engine
/// projections strip container meta; the app must not invent it from plugins.
List<Widget> collapseSchemaGroups(
  List<SchemaFormEntry> entries,
  EngineSettings? settings, {
  required Widget Function(List<SchemaFormSection> sections, Widget card) uniform,
}) {
  Widget plain(SchemaFormEntry entry) => uniform(
    [entry.section],
    SettingsSection(
      title: entry.section.title,
      footer: entry.section.footer == null ? null : Text(entry.section.footer!),
      children: entry.rows,
    ),
  );
  if (settings == null) return [for (final entry in entries) plain(entry)];
  final paths = [
    for (final entry in entries)
      entry.section.children != null || entry.section.fields.isEmpty
          ? const <_CollapseGroup>[]
          : _groupsForField(entry.section.fields.first, settings, entry.section.title),
  ];
  PageStorageKey<String> storageKey(_CollapseGroup group, int index) =>
      PageStorageKey('schema-collapse:${group.key}:${entries[index].section.fields.first.ref.key}');

  /// The run [start, end) under [group] (entry [depth] of their paths), as
  /// the rows of its card.
  ({List<Widget> rows, List<SchemaFormSection> sections, int count}) inside(
    int start,
    int end,
    int depth,
    _CollapseGroup group,
  ) {
    bool own(int index) => entries[index].section.fields.first.path.length == group.depth + 1;
    // The heading the container's own fields carry: a plain object inside
    // it is labelled relative to that.
    final heading = [
      for (var index = start; index < end; index++)
        if (paths[index].length == depth && own(index)) entries[index].section.title,
    ].firstOrNull;
    final rows = <Widget>[];
    final sections = <SchemaFormSection>[];
    var count = 0;
    var index = start;
    while (index < end) {
      if (paths[index].length == depth) {
        final entry = entries[index];
        if (entry.section.title case final title? when !own(index)) {
          final prefix = heading == null ? null : '$heading · ';
          rows.add(SchemaGroupLabel(prefix != null && title.startsWith(prefix) ? title.substring(prefix.length) : title));
        }
        rows.addAll(entry.rows);
        sections.add(entry.section);
        count += entry.rows.length;
        index++;
        continue;
      }
      final nested = paths[index][depth];
      var next = index + 1;
      while (next < end && paths[next].length > depth && paths[next][depth].key == nested.key) {
        next++;
      }
      final content = inside(index, next, depth + 1, nested);
      rows.add(
        SchemaCollapsedGroup(
          key: storageKey(nested, index),
          title: nested.title,
          count: content.count,
          nested: true,
          children: content.rows,
        ),
      );
      sections.addAll(content.sections);
      count += content.count;
      index = next;
    }
    return (rows: rows, sections: sections, count: count);
  }

  final cards = <Widget>[];
  var index = 0;
  while (index < entries.length) {
    if (paths[index].isEmpty) {
      cards.add(plain(entries[index]));
      index++;
      continue;
    }
    final group = paths[index].first;
    var next = index + 1;
    while (next < entries.length && paths[next].isNotEmpty && paths[next].first.key == group.key) {
      next++;
    }
    final content = inside(index, next, 1, group);
    final footers = [for (final section in content.sections) ?section.footer];
    cards.add(
      uniform(
        content.sections,
        SchemaCollapsedGroup(
          key: storageKey(group, index),
          title: group.title,
          count: content.count,
          footer: footers.isEmpty ? null : footers.join('\n'),
          children: content.rows,
        ),
      ),
    );
    index = next;
  }
  return cards;
}

/// A collapsed container: a card (or, [nested] in an open one, a run of that
/// card's rows) whose first row is the header — the title, how many settings
/// it holds, a chevron that turns down while open — with the fields under it
/// once open, at the card's own row insets and gaps. The open state survives
/// scrolling away (kept under its [PageStorageKey]).
class SchemaCollapsedGroup extends StatefulWidget {
  const SchemaCollapsedGroup({
    super.key,
    required this.title,
    required this.count,
    required this.children,
    this.nested = false,
    this.footer,
  });

  final String title;

  /// The settings inside, nested containers' included.
  final int count;
  final List<Widget> children;

  /// Rows in an open container's card rather than a card of its own.
  final bool nested;

  /// A note under the card while it is open.
  final String? footer;

  /// The gap between the rows of a card, as in [SettingsSection]'s.
  static const gap = 2.0;

  @override
  State<SchemaCollapsedGroup> createState() => _SchemaCollapsedGroupState();
}

class _SchemaCollapsedGroupState extends State<SchemaCollapsedGroup> {
  late bool _open = PageStorage.maybeOf(context)?.readState(context) as bool? ?? false;

  void _toggle() {
    setState(() => _open = !_open);
    PageStorage.maybeOf(context)?.writeState(context, _open);
  }

  @override
  Widget build(BuildContext context) {
    final rows = SmoothSize(
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          EngineFieldRow(
            title: widget.title,
            subtitle: context.l10n.engineSettingsGroupCount(widget.count),
            expanded: _open,
            onTap: _toggle,
          ),
          if (_open)
            for (final child in widget.children) ...[const SizedBox(height: SchemaCollapsedGroup.gap), child],
        ],
      ),
    );
    if (widget.nested) return rows;
    return SettingsSection(footer: _open && widget.footer != null ? Text(widget.footer!) : null, children: [rows]);
  }
}

/// The name of a plain object's fields inside a container's card, where a
/// card's title would be.
class SchemaGroupLabel extends StatelessWidget {
  const SchemaGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, SettingsMetrics.inset, 4),
    child: Semantics(header: true, child: Text(text, style: groupTitleStyle(context))),
  );
}
