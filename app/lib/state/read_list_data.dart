import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import 'plugins_state.dart' show BundleGroup, bundleGroup;
import 'providers_state.dart' show ProvidersSnapshot, ProviderHealth;

/// Only these closed projections can be admitted to the display cache. A
/// rejected projection leaves the live/authoritative response untouched.
sealed class ReadListData {
  const ReadListData();
  Map<String, Object?> toJson();

  static const maxRows = 2048;
  static const maxText = 4096;
  static const maxIdentityUnits = 32 * 1024;

  static String text(String value, [int limit = maxText]) {
    if (value.length > limit) throw const FormatException('display field too large');
    return value;
  }

  static String? optional(String? value, [int limit = maxText]) => value == null ? null : text(value, limit);

  static void rows(int count, [int limit = maxRows]) {
    if (count > limit) throw const FormatException('display list too large');
  }
}

// A conservative preflight bounds temporary projection work as well as the
// final encoded entry. JSON may need six bytes per UTF-16 code unit; row
// charges also bound empty-string/object-heavy responses. Oversize results
// still render live but are not copied into the cache.
class _DisplayBudget {
  int remaining = 256 * 1024;

  String text(String value, [int limit = ReadListData.maxText]) {
    ReadListData.text(value, limit);
    remaining -= value.length * 6 + 32;
    if (remaining < 0) throw const FormatException('display projection budget');
    return value;
  }

  String? optional(String? value, [int limit = ReadListData.maxText]) => value == null ? null : text(value, limit);
}

final class CachedModels extends ReadListData {
  CachedModels(ModelCatalog catalog) : value = _copy(catalog);
  final ModelCatalog value;

  static ModelCatalog _copy(ModelCatalog source) {
    final budget = _DisplayBudget();
    ReadListData.rows(source.groups.length, 128);
    var total = 0;
    final groups = <ProviderGroup>[];
    for (final group in source.groups) {
      total += group.models.length;
      ReadListData.rows(total);
      final models = <ModelInfo>[];
      for (final model in group.models) {
        ReadListData.rows(model.efforts.length, 32);
        models.add(
          ModelInfo(
            provider: budget.text(model.provider, 256),
            id: budget.text(model.id, 512),
            name: budget.text(model.name, 512),
            description: budget.optional(model.description),
            defaultEffort: budget.optional(model.defaultEffort, 256),
            efforts: List.unmodifiable([
              for (final effort in model.efforts)
                ReasoningEffort(
                  budget.text(effort.id, 256),
                  budget.text(effort.name, 512),
                  budget.optional(effort.description),
                ),
            ]),
          ),
        );
      }
      groups.add(ProviderGroup(budget.text(group.id, 256), budget.text(group.name, 512), List.unmodifiable(models)));
    }
    final selection = source.defaultSelection;
    ReadListData.rows(source.routableProviders.length, 128);
    return ModelCatalog(
      defaultSelection: selection == null
          ? null
          : ModelSelection(
              provider: budget.text(selection.provider, 256),
              model: budget.text(selection.model, 512),
              reasoningEffort: budget.optional(selection.reasoningEffort, 256),
            ),
      routableProviders: List.unmodifiable([for (final p in source.routableProviders) budget.text(p, 256)]),
      groups: List.unmodifiable(groups),
      // Raw failure messages can include endpoints or credentials.
      failures: const [],
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'default': value.defaultSelection?.toJson(),
    'routes': value.routableProviders,
    'groups': [
      for (final g in value.groups)
        {
          'id': g.id,
          'name': g.name,
          'models': [
            for (final m in g.models)
              {
                'provider': m.provider,
                'id': m.id,
                'name': m.name,
                'description': m.description,
                'defaultEffort': m.defaultEffort,
                'efforts': [
                  for (final e in m.efforts) {'id': e.id, 'name': e.name, 'description': e.description},
                ],
              },
          ],
        },
    ],
  };
}

class CachedProvider {
  const CachedProvider({
    required this.id,
    required this.name,
    required this.api,
    required this.models,
    required this.health,
  });
  final String id;
  final String name;
  final ProviderApi? api;
  final int models;
  final ProviderHealth health;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'api': api?.name, 'models': models, 'health': health.name};
}

final class CachedProviders extends ReadListData {
  CachedProviders(ProvidersSnapshot source) : supported = source.supported, rows = _copy(source);
  final bool supported;
  final List<CachedProvider> rows;

  static List<CachedProvider> _copy(ProvidersSnapshot source) {
    final budget = _DisplayBudget();
    ReadListData.rows(source.providers.length, 512);
    return List.unmodifiable([
      for (final p in source.providers)
        CachedProvider(
          id: budget.text(p.id, 256),
          name: budget.text(p.displayName, 512),
          api: p.api,
          models: p.models.length,
          health: source.healthOf(p),
        ),
    ]);
  }

  @override
  Map<String, Object?> toJson() => {
    'supported': supported,
    'rows': [for (final row in rows) row.toJson()],
  };
}

class CachedPlugin {
  const CachedPlugin(this.bundle, this.group);
  // A display-only copy: no source, rows, overrides, install target or error.
  final PluginBundle bundle;
  final BundleGroup group;
  Map<String, Object?> toJson() => {
    'name': bundle.name,
    'group': group.name,
    'version': bundle.version,
    'official': bundle.official,
    'enabled': bundle.enabled,
    'installed': bundle.installed,
    'optional': bundle.optional,
    'title': bundle.meta?.title?.toJson(),
    'summary': bundle.meta?.description?.toJson(),
    'description': bundle.description,
  };
}

final class CachedPlugins extends ReadListData {
  CachedPlugins(List<PluginBundle> source) : rows = _copy(source);
  final List<CachedPlugin> rows;

  static LocalizedText? _text(_DisplayBudget budget, LocalizedText? source) {
    if (source == null) return null;
    ReadListData.rows(source.values.length, 16);
    return LocalizedText(
      Map.unmodifiable({for (final e in source.values.entries) budget.text(e.key, 32): budget.text(e.value)}),
    );
  }

  static List<CachedPlugin> _copy(List<PluginBundle> source) {
    final budget = _DisplayBudget();
    ReadListData.rows(source.length, 512);
    return List.unmodifiable([
      for (final b in source)
        CachedPlugin(
          PluginBundle(
            name: budget.text(b.name, 256),
            official: b.official,
            enabled: b.enabled,
            installed: b.installed,
            optional: b.optional,
            version: budget.optional(b.version, 128),
            description: budget.optional(b.description),
            meta: PluginDisplayMeta(
              title: _text(budget, b.meta?.title),
              description: _text(budget, b.meta?.description),
            ),
            readOnlyReason: 'display-snapshot',
            removable: false,
          ),
          bundleGroup(b),
        ),
    ]);
  }

  @override
  Map<String, Object?> toJson() => {
    'rows': [for (final row in rows) row.toJson()],
  };
}

/// Membership/path changes are a different workspace version. The digest
/// does not preserve a workspace path in a cached display row.
String? readWorkspaceVersion(Workspace workspace) {
  if (workspace.workspaceId.length > 256 ||
      workspace.path.length > 4096 ||
      workspace.sessionIds.length > ReadListData.maxRows ||
      workspace.sessionIds.any((id) => id.length > 256)) {
    return null;
  }
  var units = 0;
  for (final id in workspace.sessionIds) {
    units += id.length;
    if (units > ReadListData.maxIdentityUnits) return null;
  }
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            workspace.workspaceId,
            workspace.path,
            workspace.updatedAt?.millisecondsSinceEpoch,
            [...workspace.sessionIds]..sort(),
          ]),
        ),
      )
      .toString();
}

final class CachedSessions extends ReadListData {
  CachedSessions({
    required List<SessionSummary> sessions,
    required List<SessionSummary> bots,
    required this.workspaceVersion,
    required this.scoped,
    String? workspaceLabel,
  }) : sessions = _copy(sessions),
       bots = _copy(bots),
       workspaceLabel = ReadListData.optional(workspaceLabel, 512) {
    ReadListData.rows(sessions.length + bots.length);
  }

  final List<SessionSummary> sessions;
  final List<SessionSummary> bots;
  final String? workspaceVersion;
  final bool scoped;
  final String? workspaceLabel;

  static List<SessionSummary> _copy(List<SessionSummary> source) {
    final budget = _DisplayBudget();
    ReadListData.rows(source.length);
    return List.unmodifiable([
      for (final row in source)
        SessionSummary(
          sessionId: budget.text(row.sessionId, 256),
          updatedAt: row.updatedAt,
          running: false,
          blank: false,
          agentAvailable: false,
          projections: SessionProjections(-1, Map.unmodifiable({'title': budget.optional(row.title)})),
        ),
    ]);
  }

  @override
  Map<String, Object?> toJson() => {
    'workspaceVersion': workspaceVersion,
    'scoped': scoped,
    'workspaceLabel': workspaceLabel,
    'sessions': [
      for (final s in sessions) {'id': s.sessionId, 'title': s.title, 'updated': s.updatedAt.millisecondsSinceEpoch},
    ],
    'bots': [
      for (final s in bots) {'id': s.sessionId, 'title': s.title, 'updated': s.updatedAt.millisecondsSinceEpoch},
    ],
  };
}
