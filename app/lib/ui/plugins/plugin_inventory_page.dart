// 插件清单 (page-design.md §1 C, list page, read-only): every Loader entry
// of the active host with its state, grouped by the bundle that brings it,
// and — when an agent-preset roster is composed — each preset's own
// composition. Mirrors `dsh-client-ui-settings-plugin-inventory` over
// `pluginInventory/list`; switches stay on the 插件 page.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/engine_settings_state.dart';
import '../../state/plugin_config/plugin_config_state.dart';
import '../../state/plugins_state.dart' show installedPluginsProvider;
import '../../state/voice_scribe_settings.dart';
import '../common/app_sheet.dart';
import '../common/capsule_chip.dart';
import '../common/expand_reveal.dart';
import '../common/list_page_row.dart';
import '../common/row_marks.dart';
import '../common/segmented_pill.dart';
import '../common/search_capsule.dart';
import '../common/status_chip.dart';
import '../engine_settings/engine_settings_page.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'config/plugin_config_entries.dart';
import 'plugin_detail_sheet.dart' show PluginHero;
import 'plugin_widgets.dart';
import 'voice_scribe_settings_page.dart';

/// Dot colour of a row's state.
StatusTone inventoryTone(InventoryStatus status) => switch (status) {
  InventoryStatus.running => StatusTone.ok,
  InventoryStatus.failed => StatusTone.error,
  InventoryStatus.loading => StatusTone.busy,
  InventoryStatus.waiting => StatusTone.warn,
  InventoryStatus.off || InventoryStatus.idle || InventoryStatus.conditional => StatusTone.idle,
};

enum _Scope { global, presets }

/// Rows grouped for the page: problems first, then by bundle (Loader
/// order), the version beside the bundle's name; components without a
/// Chinese name go to [system] (shown folded). Pure for testing.
({List<(String title, List<InventoryItem> items)> groups, List<InventoryItem> system}) groupInventory(
  List<InventoryItem> items,
) {
  final failed = [
    for (final i in items)
      if (i.status == InventoryStatus.failed) i,
  ];
  final system = <InventoryItem>[];
  final groups = <(String?, String?), List<InventoryItem>>{};
  for (final item in items) {
    if (item.status == InventoryStatus.failed) continue;
    if (item.system) {
      system.add(item);
      continue;
    }
    (groups[(item.source, item.version)] ??= []).add(item);
  }
  final other = groups.remove((null, null));
  String title((String?, String?) key) {
    final (source, version) = key;
    final name = source ?? appL10n.commonOther;
    return version == null ? name : '$name · $version';
  }

  return (
    groups: [
      if (failed.isNotEmpty) (appL10n.pluginsError, failed),
      for (final MapEntry(:key, :value) in groups.entries) (title(key), value),
      if (other != null) (appL10n.commonOther, other),
    ],
    system: system,
  );
}

class PluginInventoryPage extends ConsumerStatefulWidget {
  const PluginInventoryPage({super.key});

  @override
  ConsumerState<PluginInventoryPage> createState() => _PluginInventoryPageState();
}

class _PluginInventoryPageState extends ConsumerState<PluginInventoryPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  _Scope _scope = _Scope.global;
  String? _preset;
  bool _systemOpen = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = text);
    });
  }

  void _clear() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = '');
  }

  List<String> get _terms =>
      _query.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connected = ref.watch(activeConnectionProvider).value != null;
    final async = ref.watch(pluginInventoryProvider);
    final snapshot = async.value;
    final presets = snapshot?.inventory.presets ?? const <PresetPlugins>[];
    final scope = presets.isEmpty ? _Scope.global : _scope;
    final preset = presets.isEmpty
        ? null
        : presets.firstWhere(
            (p) => p.id == _preset,
            orElse: () => presets.firstWhere((p) => p.isDefault, orElse: () => presets.first),
          );
    return AppPage(
      title: l10n.pluginsInventoryTitle,
      subtitle: snapshot == null ? null : Text(_summary(snapshot)),
      slivers: [
        if (snapshot != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SearchCapsule(controller: _search, hint: l10n.pluginsSearch, onChanged: _onQuery, onClear: _clear),
            ),
          ),
          if (presets.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SegmentedPill<_Scope>(
                  segments: [
                    PillSegment(_Scope.global, l10n.pluginsGlobalPlugins),
                    PillSegment(_Scope.presets, l10n.pluginsAgentPresets),
                  ],
                  selected: scope,
                  onChanged: (s) => setState(() => _scope = s),
                ),
              ),
            ),
          if (scope == _Scope.presets && presets.length > 1)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  children: [
                    for (final p in presets)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: CapsuleChoiceChip(
                          label: presetLabel(p),
                          selected: p.id == preset?.id,
                          onSelected: () => setState(() => _preset = p.id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
        SliverList.list(
          children: [
            if (!connected)
              const FeatureOffline()
            else if (snapshot == null && async.hasError)
              FeatureMessage(
                icon: AppIcons.error,
                title: l10n.pluginsInventoryReadFailed,
                body: describeSettingsError(async.error!),
                action: (l10n.commonRetry, () => ref.invalidate(pluginInventoryProvider)),
              )
            else if (snapshot == null)
              const FeatureLoading()
            else if (scope == _Scope.global)
              ..._groups(snapshot.global)
            else if (preset != null)
              ..._presetGroup(snapshot, preset),
          ],
        ),
      ],
    );
  }

  static String _summary(InventorySnapshot snapshot) {
    final items = snapshot.global;
    final running = items.where((i) => i.status == InventoryStatus.running).length;
    final failed = items.where((i) => i.status == InventoryStatus.failed).length;
    return [
      appL10n.pluginsComponentCount(items.length),
      appL10n.pluginsEnabledCount(running),
      if (failed > 0) appL10n.pluginsErrorCount(failed),
    ].join(' · ');
  }

  List<Widget> _groups(List<InventoryItem> all) {
    final items = [
      for (final i in all)
        if (i.matches(_terms)) i,
    ];
    if (items.isEmpty) {
      return [
        FeatureMessage(
          icon: AppIcons.noResults,
          title: all.isEmpty ? appL10n.pluginsNoPlugins : appL10n.pluginsNoMatchingPlugins,
        ),
      ];
    }
    var index = 0;
    final grouped = groupInventory(items);
    return [
      for (final (i, (title, group)) in grouped.groups.indexed) ...[
        if (i > 0) const SizedBox(height: 24),
        ListPageCard(
          title: title,
          children: [
            for (final item in group)
              FadeSlideIn(
                index: index++,
                child: InventoryRow(item: item),
              ),
          ],
        ),
      ],
      if (grouped.system.isNotEmpty) ...[
        if (grouped.groups.isNotEmpty) const SizedBox(height: 24),
        SystemComponentsCard(
          items: grouped.system,
          // A search looks inside the folded group too.
          open: _systemOpen || _terms.isNotEmpty,
          onToggle: () => setState(() => _systemOpen = !_systemOpen),
        ),
      ],
    ];
  }

  List<Widget> _presetGroup(InventorySnapshot snapshot, PresetPlugins preset) {
    if (preset.broken case final reason?) {
      return [FeatureMessage(icon: AppIcons.error, title: appL10n.pluginsPresetLoadFailed, body: reason)];
    }
    final rows = snapshot.presets[preset.id] ?? const <InventoryItem>[];
    final items = [
      for (final i in rows)
        if (i.matches(_terms)) i,
    ];
    if (items.isEmpty) {
      return [
        FeatureMessage(
          icon: AppIcons.noResults,
          title: rows.isEmpty ? appL10n.pluginsPresetNoPlugins : appL10n.pluginsNoMatchingPlugins,
        ),
      ];
    }
    return [
      ListPageCard(
        title: '${presetLabel(preset)} · ${items.length}',
        children: [
          for (final (i, item) in items.indexed)
            FadeSlideIn(
              index: i,
              child: InventoryRow(item: item),
            ),
        ],
      ),
    ];
  }
}

/// A preset's name, 「（默认）」 on the default one.
String presetLabel(PresetPlugins preset) {
  final name = switch (preset.name) {
    final n? when n.trim().isNotEmpty => n.trim(),
    _ => switch (preset.id) {
      'standard' => appL10n.pluginsStandard,
      'minimal' => appL10n.pluginsMinimal,
      _ => preset.id,
    },
  };
  return preset.isDefault ? appL10n.pluginsDefaultPresetName(name) : name;
}

/// One entry: its Chinese name over its Chinese one-liner (when it has one),
/// and a dot for its state.
class InventoryRow extends StatelessWidget {
  const InventoryRow({super.key, required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    void open() => unawaited(showInventorySheet(context, item));
    return Semantics(
      label: l10n.pluginsInventorySemantics(item.title, item.status.label),
      button: true,
      onTap: open,
      excludeSemantics: true,
      child: ListPageRow(
        title: item.title,
        subtitle: item.description,
        trailing: AnimatedStatusDot(tone: inventoryTone(item.status), size: 8),
        onTap: open,
      ),
    );
  }
}

/// 「系统组件」: internal components without a Chinese name, folded into one
/// row until opened.
class SystemComponentsCard extends StatelessWidget {
  const SystemComponentsCard({super.key, required this.items, required this.open, required this.onToggle});

  final List<InventoryItem> items;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListPageCard(
      children: [
        Semantics(
          expanded: open,
          child: ListPageRow(
            title: l10n.pluginsSystemComponents,
            value: l10n.pluginsCount(items.length),
            onTap: onToggle,
            // Ink ends on the status dots' right edge below.
            trailing: RowExpandArrow(open: open),
          ),
        ),
        ExpandReveal(
          open: open,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final item in items) InventoryRow(item: item)],
          ),
        ),
      ],
    );
  }
}

/// An entry's detail: what it is, where it comes from, its state, and its
/// settings when it has any.
Future<void> showInventorySheet(BuildContext context, InventoryItem item) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => InventorySheet(item: item));

class InventorySheet extends ConsumerWidget {
  const InventorySheet({super.key, required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final config = ref.watch(pluginConfigProvider).value;
    final pluginForm = hasPluginConfig(config, item.rowId);
    final configurable =
        (curatedNamespaces.contains(item.rowId) && (config?.entries.containsKey(item.rowId) ?? false)) || pluginForm;
    // A plugin's form on a bridge R7 Host opens under the name it is listed
    // by elsewhere; otherwise as before.
    final formTitle = pluginForm && pluginConfigNamedByBundle(config, item.rowId)
        ? pluginConfigTitle(
            item.rowId,
            ref.watch(installedPluginsProvider.select((s) => s.value)),
            state: config,
            l10n: l10n,
          )
        : item.title;
    final connection = ref.watch(activeConnectionProvider);
    final voiceSource = connection.isLoading || connection.hasError ? null : connection.value;
    final voice = item.moduleName == voiceScribeModule;
    final facts = <(String, String)>[
      if (item.source case final source?) (l10n.pluginsSource, source),
      if (item.version case final version?) (l10n.commonVersion, version),
      if (item.condition case final condition?) (l10n.pluginsDisableCondition, condition),
      if (item.enabledIn.isNotEmpty) (l10n.pluginsProvidedByPreset, item.enabledIn.join(l10n.pluginsListSeparator)),
    ];
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.pluginsDetailsTitle),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 20),
              children: [
                PluginHero(
                  avatar: PluginAvatar(name: item.moduleName, title: item.title, icon: item.icon, size: 56),
                  title: item.title,
                  subtitle: item.moduleName,
                  subtitleMaxLines: 2,
                  monoSubtitle: true,
                  badges: [StatusChip(tone: inventoryTone(item.status), label: item.status.label)],
                ),
                if (item.description case final description?) ...[
                  const SizedBox(height: 16),
                  SelectableText(description, style: theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
                ],
                if (item.metaError case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.pluginsPackageInfoError(error),
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
                  ),
                ],
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  ListPageCard(
                    margin: EdgeInsets.zero,
                    children: [for (final (label, value) in facts) ListPageRow(title: label, value: value)],
                  ),
                ],
                // The schema form and the voice plugin's own settings share
                // one card when a plugin has both.
                if (configurable || voice) ...[
                  const SizedBox(height: 16),
                  ListPageCard(
                    margin: EdgeInsets.zero,
                    children: [
                      if (configurable)
                        ListPageRow(
                          icon: AppIcons.configure,
                          title: l10n.commonSettings,
                          subtitle: pluginForm ? pluginConfigReadOnlyNote(config, item.rowId, l10n: l10n) : null,
                          chevron: true,
                          onTap: () => unawaited(openSettingsPage(context, item.rowId, title: formTitle)),
                        ),
                      if (voice)
                        ListPageRow(
                          icon: AppIcons.voice,
                          title: voiceScribePageTitle,
                          chevron: true,
                          onTap: voiceSource == null
                              ? null
                              : () => unawaited(
                                  Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          VoiceScribeSettingsPage(source: voiceSource, entryId: item.entryId),
                                    ),
                                  ),
                                ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
