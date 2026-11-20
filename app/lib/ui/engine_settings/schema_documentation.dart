// Schema-authored documentation only: no values, credentials, chat scope or
// executable dsh-ui blocks are passed to this reader.
import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'field_sheets.dart';
import 'schema_fields.dart' show commonKeyLabels, humanizeKey;

String get schemaDocumentationLabel => appL10n.schemaDocumentationTitle;

/// One step from the schema root to a documented node: a key, every item of
/// a list or map, a tuple position or one option of a union.
class SchemaDocumentationStep {
  const SchemaDocumentationStep.key(String this.key) : position = null, option = null;
  const SchemaDocumentationStep.each() : key = null, position = null, option = null;
  const SchemaDocumentationStep.position(int this.position) : key = null, option = null;
  const SchemaDocumentationStep.option(int this.option) : key = null, position = null;

  final String? key;

  /// 1-based.
  final int? position;

  /// 1-based.
  final int? option;

  /// The step as the form names it: a key in words, 每一项, 第 2 项, 选项 2.
  String get label {
    if (key case final key?) return commonKeyLabels[key] ?? humanizeKey(key);
    if (position case final position?) return appL10n.schemaDocumentationPosition(position);
    if (option case final option?) return appL10n.schemaDocumentationOption(option);
    return appL10n.schemaDocumentationEach;
  }
}

class SchemaDocumentationEntry {
  const SchemaDocumentationEntry(this.path, this.description, this.comment, this.link, {this.steps = const []});

  /// The raw schema path (`$.group.key`, `[]`, `{key}`): a stable identity,
  /// never shown.
  final String path;
  final String? description;
  final String? comment;
  final String? link;

  /// [path] as steps; empty for the root.
  final List<SchemaDocumentationStep> steps;

  /// The heading the sheet shows: the steps in words, or 概述 for the root.
  String get heading => steps.isEmpty ? appL10n.schemaDocumentationOverview : steps.map((s) => s.label).join(' › ');
}

/// Walk the actual serialized schema. Values and defaults are never read.
List<SchemaDocumentationEntry> schemaDocumentation(SchemaNode root, String locale) {
  final result = <SchemaDocumentationEntry>[];
  bool exhausted(SchemaNode node, Set<SchemaNode> seen) => seen.contains(node) || seen.length >= 32;
  bool wrapper(SchemaNode node) => node.type == 'transform' || node.type == 'lazy';

  // Keep raw wrappers: `effective` / `members` discard intermediate metadata.
  // Even hidden members participate in last-wins field selection, so a later
  // hidden declaration cannot reveal an earlier declaration of the same key.
  Map<String, (SchemaNode, bool)> fields(SchemaNode node, Set<SchemaNode> seen, [bool hidden = false]) {
    if (exhausted(node, seen)) return {};
    final next = {...seen, node};
    hidden = hidden || node.meta.hidden;
    if (wrapper(node) && node.inner != null) return fields(node.inner!, next, hidden);
    if (node.type == 'object') return {for (final entry in node.dict.entries) entry.key: (entry.value, hidden)};
    if (node.type != 'intersect') return {};
    return {for (final member in node.list) ...fields(member, next, hidden)};
  }

  void add(SchemaMeta meta, String path, List<SchemaDocumentationStep> steps) {
    final description = meta.description?.resolve(locale).trim();
    final comment = meta.comment?.trim();
    final link = meta.link?.trim();
    if ([description, comment, link].any((s) => s != null && s.isNotEmpty)) {
      final entry = SchemaDocumentationEntry(path, description, comment, link, steps: steps);
      if (!result.any(
        (e) => e.path == path && e.description == description && e.comment == comment && e.link == link,
      )) {
        result.add(entry);
      }
    }
  }

  // Structural member explanations are independent from field overrides.
  // Recurse through intersect and wrapper layers but leave object children
  // to the merged field walk, preventing obsolete duplicate field docs.
  void structure(SchemaNode node, String path, List<SchemaDocumentationStep> steps, Set<SchemaNode> seen) {
    if (node.meta.hidden || exhausted(node, seen)) return;
    final next = {...seen, node};
    add(node.meta, path, steps);
    if (wrapper(node) && node.inner != null) {
      structure(node.inner!, path, steps, next);
    } else if (node.type == 'intersect') {
      for (final member in node.list) {
        structure(member, path, steps, next);
      }
    }
  }

  void visit(SchemaNode node, String path, List<SchemaDocumentationStep> steps, Set<SchemaNode> ancestors) {
    if (node.meta.hidden || exhausted(node, ancestors)) return;
    final next = {...ancestors, node};
    add(node.meta, path, steps);
    if (wrapper(node) && node.inner != null) {
      visit(node.inner!, path, steps, next);
    } else if (node.type == 'object') {
      for (final entry in node.dict.entries) {
        visit(entry.value, '$path.${entry.key}', [...steps, SchemaDocumentationStep.key(entry.key)], next);
      }
    } else if (node.type == 'intersect') {
      for (final member in node.list) {
        structure(member, path, steps, next);
      }
      for (final entry in fields(node, {}).entries) {
        if (!entry.value.$2) {
          visit(entry.value.$1, '$path.${entry.key}', [...steps, SchemaDocumentationStep.key(entry.key)], next);
        }
      }
    } else if (node.inner case final inner?) {
      visit(inner, node.type == 'dict' ? '$path{key}' : '$path[]', [
        ...steps,
        const SchemaDocumentationStep.each(),
      ], next);
    } else {
      for (final (index, member) in node.list.indexed) {
        final tuple = node.type == 'tuple';
        visit(member, tuple ? '$path[$index]' : '$path (variant ${index + 1})', [
          ...steps,
          tuple ? SchemaDocumentationStep.position(index + 1) : SchemaDocumentationStep.option(index + 1),
        ], next);
      }
    }
  }

  visit(root, r'$', const [], {});
  return result;
}

/// [schemaDocumentation], worked out once per schema and language: the page's
/// ⓘ asks on every build of its bar.
List<SchemaDocumentationEntry> cachedSchemaDocumentation(SchemaNode root, String locale) =>
    (_documentation[root] ??= {})[locale] ??= schemaDocumentation(root, locale);

final _documentation = Expando<Map<String, List<SchemaDocumentationEntry>>>('schemaDocumentation');

/// Documentation links never resolve against the current host or chat session.
Uri? schemaDocumentationUri(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty && uri.userInfo.isEmpty
      ? uri
      : null;
}

typedef SchemaDocumentationLauncher = Future<bool> Function(Uri uri);
Future<bool> _launch(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

class SchemaDocumentationButton extends StatelessWidget {
  const SchemaDocumentationButton({super.key, required this.schema, required this.title});
  final SchemaNode schema;
  final String title;

  @override
  Widget build(BuildContext context) {
    final entries = cachedSchemaDocumentation(schema, AppLocale.current.toLanguageTag());
    if (entries.isEmpty) return const SizedBox.shrink();
    return IconButton(
      tooltip: schemaDocumentationLabel,
      icon: const Icon(AppIcons.info),
      onPressed: () =>
          unawaited(showFieldSheet<void>(context, (_) => SchemaDocumentationSheet(title: title, entries: entries))),
    );
  }
}

/// The page's field descriptions in full, like every field sheet: × and 完成.
class SchemaDocumentationSheet extends StatelessWidget {
  const SchemaDocumentationSheet({super.key, required this.title, required this.entries, this.launcher = _launch});
  final String title;
  final List<SchemaDocumentationEntry> entries;
  final SchemaDocumentationLauncher launcher;

  Future<void> _open(BuildContext context, String text) async {
    final uri = schemaDocumentationUri(text);
    if (uri == null) return;
    var opened = false;
    try {
      opened = await launcher(uri);
    } catch (_) {
      // The same non-destructive failure state as a rejected launch.
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.stateLinkOpenFailed)));
    }
  }

  Widget _markdown(BuildContext context, String text) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    // The chat's inline code and link colours, so a description reads like a reply.
    return GptMarkdownTheme(
      gptThemeData: GptMarkdownThemeData(
        brightness: theme.brightness,
        linkColor: theme.colorScheme.primary,
        linkHoverColor: theme.colorScheme.primary,
        inlineCode: InlineCodeStyle(
          fontFamily: AppType.monoFamily,
          fontFamilyFallback: AppType.monoFallback,
          fontSizeFactor: 0.875,
          color: dsh.codeWellFg,
          backgroundColor: dsh.codeWellBg,
          borderColor: dsh.codeWellBorder,
          borderWidth: 0.5,
          borderRadius: const Radius.circular(AppShape.xs),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        ),
      ),
      child: GptMarkdown(
        text,
        isStreaming: false,
        html: false,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        textScaler: MediaQuery.textScalerOf(context),
        onLinkTap: (url, _) => unawaited(_open(context, url)),
        // A schema description is documentation, not a fetch surface. Image URLs
        // stay selectable text; even a dsh-ui fence stays inert code.
        imageBuilder: (_, url, _, _) => Text(url),
        codeBuilder: (_, _, code, _) => Text(code, style: theme.textTheme.bodyMedium),
        styleSheet: const GptMarkdownStyleSheet(table: TableStyle(overflow: TableOverflow.scroll)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FieldSheetFrame(
      title: schemaDocumentationLabel,
      actions: EditorSheetActions(busy: false, onDone: () => Navigator.of(context).maybePop()),
      children: [
        SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(header: true, child: Text(entry.heading, style: theme.textTheme.titleSmall)),
                      for (final text in [entry.description, entry.comment])
                        if (text != null && text.isNotEmpty)
                          Padding(padding: const EdgeInsets.only(top: 6), child: _markdown(context, text)),
                      if (entry.link case final link? when link.isNotEmpty)
                        // Flush with the text above, drawn like a link inside it.
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 40),
                            alignment: AlignmentDirectional.centerStart,
                            textStyle: theme.textTheme.bodyMedium?.copyWith(decoration: TextDecoration.underline),
                          ),
                          onPressed: schemaDocumentationUri(link) == null
                              ? null
                              : () => unawaited(_open(context, link)),
                          child: Text(link),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}
