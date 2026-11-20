// A plugin's configuration as a native page (docs/design/plugin-config.md):
// every field its Config declares, drawn by the schema form engine. Live
// fields take effect as they change; the others wait for 保存, which reloads
// the plugin with progress, and a failed reload can be retried, put back or
// dropped. Long forms fold their groups and their plumbing (「高级」) and get
// a search; a plugin that ships its own web page keeps a way there.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart' show Slots, seatInventoryProvider;
import '../../../state/engine_settings_state.dart';
import '../../../state/plugin_config/plugin_config_state.dart';
import '../../../state/plugins_state.dart';
import '../../common/app_dialog.dart';
import '../../common/discard_guard.dart';
import '../../common/search_capsule.dart';
import '../../engine_settings/field_row.dart';
import '../../engine_settings/namespace_copy.dart';
import '../../engine_settings/schema_collapsed_groups.dart';
import '../../engine_settings/schema_documentation.dart';
import '../../engine_settings/schema_fields.dart' show FieldKind, humanizeKey, kindOf;
import '../../engine_settings/schema_form.dart';
import '../../features/feature_widgets.dart';
import '../../settings/index/spot_anchor.dart' show anchorSpot;
import '../../settings/index/spots.dart' show SettingsIndex;
import '../../settings/settings_widgets.dart' show SettingsSection;
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../web/dsh_web_launcher.dart' show DshWebOpenScope;
import '../../web/web_target.dart';
import '../seats/seat_links.dart' show seatWebOpenerProvider;
import 'plugin_config_entries.dart' show pluginConfigNamedByBundle, pluginConfigTitle, retryPluginList;
import 'plugin_config_layout.dart';
import 'plugin_config_save_bar.dart';

/// A plugin form's fields read and write [PluginConfigController].
class PluginConfigSource extends SchemaFormSource {
  const PluginConfigSource(this.ns);

  final String ns;

  @override
  EngineSettings? watch(WidgetRef ref) => ref.watch(pluginConfigProvider).value?.settingsFor(ns);

  @override
  T select<T>(WidgetRef ref, T Function(EngineSettings? settings) selector) =>
      ref.watch(pluginConfigProvider.select((async) => selector(async.value?.settingsFor(ns))));

  @override
  SettingsEditor editor(WidgetRef ref, EngineSettings snapshot) =>
      PluginConfigEditor(ref.read(pluginConfigProvider.notifier));

  @override
  String secretSetLabel(L10n l10n) => l10n.pluginConfigSecretSet;

  @override
  String secretUnsetLabel(L10n l10n) => l10n.commonNotSet;

  @override
  bool operator ==(Object other) => other is PluginConfigSource && other.ns == ns;

  @override
  int get hashCode => ns.hashCode;
}

/// A search shows once a form has this many fields.
const pluginConfigSearchFrom = 8;

/// Titled groups fold once a form has this many fields.
const pluginConfigFoldFrom = 12;

/// The bundle that brings entry [ns], if listed.
PluginBundle? pluginConfigBundleOf(List<PluginBundle>? bundles, String ns) =>
    bundles?.where((b) => b.rows.any((r) => r.rowId == ns)).firstOrNull;

/// Where [ns]'s own page is in DSH Web: its bundle's card on the Plugins
/// page (titles in every language, then the package name).
DshWebTarget pluginConfigWebTarget(String ns, {required String title, List<PluginBundle>? bundles}) {
  final bundle = pluginConfigBundleOf(bundles, ns);
  if (bundle == null) return DshWebTarget(pluginItem: [title, ns]);
  return DshWebTarget(pluginItem: [...?bundle.meta?.title?.all, bundle.name]);
}

/// Which choice rows of [layout] draw as capsules now (an unset optional
/// choice is a picker row instead), as the cards' shared capsule layout
/// reads them.
String _capsules(PluginConfigLayout layout, EngineSettings settings) {
  final choices = _choicesOf[layout] ??= [
    for (final section in layout.sections)
      for (final f in section.fields)
        if (f.fallbackNode == null)
          if (settings.nodeOf(f.ref) case final node? when kindOf(node) == FieldKind.choice) f,
  ];
  return [
    for (final f in choices)
      if (settings.nodeOf(f.ref) case final node?) segmentOf(f, node, settings) == null ? '0' : '1',
  ].join();
}

/// The choice fields of a layout (it is one schema's).
final _choicesOf = Expando<List<SchemaFieldSpec>>('pluginConfigChoices');

/// Held edits that leaving drops: the back gesture asks first.
bool _dirtyOf(PluginConfigState? state, String ns) =>
    (state?.hasDraft(ns) ?? false) && !(state?.isApplying(ns) ?? false);

/// What the page draws besides its rows and the save bar, compared to decide
/// whether it draws again: the form and its entry, the plugin list's answer,
/// whether the form can be written, which choices are capsules. A value, a
/// held edit or a live write in flight is redrawn by its own row
/// ([SchemaFieldTile]) and the save bar.
@immutable
class _PageFrame {
  _PageFrame(this.async, String ns, {required String query}) : _key = _keyOf(async, ns, query);

  final AsyncValue<PluginConfigState?> async;
  final List<Object?> _key;

  static List<Object?> _keyOf(AsyncValue<PluginConfigState?> async, String ns, String query) {
    final state = async.value;
    if (state == null) return [async.isLoading, async.hasError, async.error];
    final form = state[ns];
    final settings = form == null ? null : state.settingsFor(ns);
    return [
      state.forms,
      state.entries,
      state.scope,
      state.loadErrors,
      state.lazy,
      state.writable,
      state.local,
      state.hostLabel,
      // 「在网页版设置」 is shut while a save or a live write is on its way.
      state.isApplying(ns),
      state.pending[ns]?.isNotEmpty ?? false,
      if (form != null && settings != null) ...[
        settings.canWrite(ns),
        settings.isLocked(ns),
        _capsules(cachedPluginConfigLayout(form, copy: namespaceCopy[ns] ?? const {}, query: query), settings),
      ],
    ];
  }

  @override
  bool operator ==(Object other) => other is _PageFrame && listEquals(_key, other._key);

  @override
  int get hashCode => Object.hashAll(_key);
}

class PluginConfigPage extends ConsumerStatefulWidget {
  const PluginConfigPage({super.key, required this.ns, this.title});

  /// The plugin entry's profile id (its settings namespace).
  final String ns;
  final String? title;

  @override
  ConsumerState<PluginConfigPage> createState() => _PluginConfigPageState();
}

class _PluginConfigPageState extends ConsumerState<PluginConfigPage> {
  final _search = TextEditingController();
  final _dirty = ValueNotifier(false);
  late final _guarded = Listenable.merge([_search, _dirty]);
  late final PluginConfigController _controller;
  String _query = '';

  /// The form's cards and what they were built from: kept while that stays
  /// the same, so the page drawing again leaves the rows alone.
  List<Object?>? _groupsKey;
  List<Widget> _groups = const [];

  /// The page opened before its form was there; the form has been drawn.
  bool _formLate = false;
  bool _formShown = false;

  String get ns => widget.ns;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(pluginConfigProvider.notifier);
    // A Host that serves forms one entry at a time: read this one now, and
    // again once the entry list arrives.
    ref.listenManual(pluginConfigProvider, (_, next) {
      final state = next.value;
      if (state != null && state.lazy && state[ns] == null && !state.loadErrors.containsKey(ns)) {
        unawaited(_controller.load(ns));
      }
    }, fireImmediately: true);
    ref.listenManual(
      pluginConfigProvider.select((async) => _dirtyOf(async.value, ns)),
      (_, dirty) => _dirty.value = dirty,
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    // Left with 放弃: the held edits go too (a save in flight carries on).
    final controller = _controller;
    final ns = this.ns;
    scheduleMicrotask(() => controller.discardIfIdle(ns));
    _search.dispose();
    _dirty.dispose();
    super.dispose();
  }

  String _title(List<PluginBundle>? bundles, PluginConfigState? state) {
    if (widget.title case final title?) return title;
    // A bridge R7 Host: the name it is listed by (plugin_config_entries.dart).
    if (pluginConfigNamedByBundle(state, ns)) return pluginConfigTitle(ns, bundles, state: state, l10n: context.l10n);
    final locale = AppLocale.current.languageCode;
    if (pluginConfigBundleOf(bundles, ns) case final bundle?) {
      final row = bundle.rows.firstWhere((r) => r.rowId == ns);
      return row.meta?.title?.resolve(locale) ?? bundle.title(locale);
    }
    if (state?.entries[ns]?.label case final label?) return label.resolve(locale);
    return namespaceTitles[ns] ?? humanizeKey(ns);
  }

  /// Why there is no form: the Host's reason for an entry it lists, else the
  /// plugin is not running.
  Widget _unavailable(BuildContext context, PluginConfigEntry? entry) {
    final l10n = context.l10n;
    return switch ((entry?.state, entry?.reason)) {
      (null, _) || ('inactive', _) || (_, 'not-active') => FeatureMessage(
        icon: AppIcons.unsupported,
        title: l10n.engineSettingsPluginStopped,
        body: l10n.engineSettingsEnablePlugin,
      ),
      ('failed', _) => FeatureMessage(icon: AppIcons.error, title: l10n.pluginConfigNotStarted),
      _ => FeatureMessage(icon: AppIcons.unsupported, title: l10n.pluginConfigUnsupported),
    };
  }

  /// The plugin ships a settings page of its own in DSH Web (it said so, or
  /// the web client reported it in a config slot).
  bool _hasWebPage(PluginConfigForm form, List<PluginBundle>? bundles) {
    if (form.prefersOwnPage) return true;
    final owner = pluginConfigBundleOf(bundles, ns);
    if (owner == null) return false;
    final occupancy = ref.watch(seatInventoryProvider)?.occupancy;
    if (occupancy == null) return false;
    return [
      ...?occupancy[Slots.bundleConfig],
      ...?occupancy[Slots.rowConfig],
      ...?occupancy[Slots.settingsSection],
    ].any((o) => o.package == owner.name && (o.slot != Slots.rowConfig || o.cell.endsWith('#$ns')));
  }

  /// A save is reloading the plugin, or a live write is on its way.
  bool _busy(PluginConfigState? state) =>
      state != null && (state.isApplying(ns) || (state.pending[ns]?.isNotEmpty ?? false));

  /// Off to DSH Web, which edits the same configuration through its own
  /// page. Not while [_busy]: it would land on a plugin in the middle of its
  /// reload. Held edits go first, when the person says so: kept, a later 保存
  /// would write them over what was set there. A row of the form that names
  /// only this entry ([target], 「在网页版编辑此项」) lands on the plugin's own
  /// card too.
  Future<void> _openWeb(String title, List<PluginBundle>? bundles, [DshWebTarget? target]) async {
    final state = ref.read(pluginConfigProvider).value;
    if (_busy(state)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.pluginConfigSaving)));
      return;
    }
    if (state != null && state.hasDraft(ns)) {
      if (!await _confirmDiscard() || !mounted) return;
      _controller.discard(ns);
    }
    final own = target == null || (target.pluginItem.length == 1 && target.pluginItem.single == ns);
    ref.read(seatWebOpenerProvider)(
      context,
      ref,
      own ? pluginConfigWebTarget(ns, title: title, bundles: bundles) : target,
    );
  }

  /// 「放弃修改？」, as when leaving the page with held edits.
  Future<bool> _confirmDiscard() async {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.botsDiscardTitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.botsKeepEditing)),
          FilledButton(
            key: const ValueKey('plugin-config-web-discard'),
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.botsDiscard),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _resetAll() async {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pluginConfigResetAllTitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.pluginConfigReset),
          ),
        ],
      ),
    );
    if (ok == true) await _controller.resetAll(ns);
  }

  /// The form's cards: built again only when [layout], the folding, the
  /// schema, the lock or the capsule rows change.
  List<Widget> _groupsOf(PluginConfigLayout layout, EngineSettings settings, {required bool fold}) {
    final key = [ns, layout, fold, settings[ns]?.schema, settings.isLocked(ns), _capsules(layout, settings)];
    if (_groupsKey case final previous? when listEquals(previous, key)) return _groups;
    _groupsKey = key;

    List<Widget> rows(SchemaFormSection section) => [
      for (final f in section.fields)
        anchorSpot(SettingsIndex.forField(f.ns, f.path), SchemaFieldTile(f, key: ValueKey(f.ref.key))),
    ];

    return _groups = [
      if (fold)
        for (final section in layout.sections)
          if (section.title == null)
            ...schemaFormGroups([section], settings: settings)
          else
            SchemaCollapsedGroup(
              key: PageStorageKey('plugin-config:$ns:${section.title}'),
              title: section.title!,
              count: section.fields.length,
              children: rows(section),
            )
      else
        ...schemaFormGroups(layout.sections, settings: settings),
      if (layout.advanced.isNotEmpty)
        SchemaCollapsedGroup(
          key: PageStorageKey('plugin-config:$ns:advanced'),
          title: advancedGroupTitle,
          count: layout.advancedCount,
          children: [
            for (final section in layout.advanced) ...[
              if (section.title case final heading?) SchemaGroupLabel(heading),
              ...rows(section),
            ],
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final query = _query;
    final async = ref.watch(pluginConfigProvider.select((async) => _PageFrame(async, ns, query: query))).async;
    final state = async.value;
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final title = _title(bundles, state);
    final form = state?[ns];

    if (state == null || form == null) {
      _formLate = true;
      return AppPage.list(
        title: title,
        children: [
          if (state == null && async.hasError)
            FeatureMessage(
              icon: AppIcons.error,
              title: l10n.engineSettingsReadFailed,
              body: describeSettingsError(async.error!),
              action: (
                l10n.commonRetry,
                () {
                  ref.invalidate(engineSettingsProvider);
                  ref.invalidate(pluginConfigProvider);
                },
              ),
            )
          else if (state == null && async.isLoading)
            const FeatureLoading()
          else if (state == null)
            const FeatureOffline()
          // DSH's core, the App's own rows, anything not a chosen bundle's:
          // never drawn or written here; nor anything while the plugin list
          // is not the Host's confirmed answer (PluginConfigScope).
          else if (!state.isPlugin(ns))
            switch (state.scope.status) {
              PluginScopeStatus.pending => const FeatureLoading(),
              PluginScopeStatus.failed => FeatureMessage(
                icon: AppIcons.error,
                title: l10n.pluginConfigListFailed,
                action: (l10n.commonRetry, () => retryPluginList(ref)),
              ),
              PluginScopeStatus.offline => const FeatureOffline(),
              PluginScopeStatus.confirmed => FeatureMessage(
                icon: AppIcons.unsupported,
                title: l10n.pluginConfigUnsupported,
              ),
            }
          else if (state.loadErrors[ns] case final error?)
            FeatureMessage(
              icon: AppIcons.error,
              title: l10n.engineSettingsReadFailed,
              body: error,
              action: (l10n.commonRetry, () => unawaited(_controller.load(ns))),
            )
          else if (state.lazy && (state.entries[ns]?.configurable ?? false))
            const FeatureLoading()
          else
            _unavailable(context, state.entries[ns]),
        ],
      );
    }

    // A form read after the page opened (a Host that serves forms one at a
    // time) is drawn once the page has slid in, not in the middle of it.
    if (!_formShown) {
      if (_formLate) {
        return AppPage.list(
          title: title,
          children: [_AfterEntrance(onEntered: () => setState(() => _formShown = true))],
        );
      }
      _formShown = true;
    }

    final settings = state.settingsFor(ns);
    final copy = namespaceCopy[ns] ?? const <String, FieldCopy>{};
    final layout = cachedPluginConfigLayout(form, copy: copy, query: _query);
    final searching = _query.trim().isNotEmpty;
    final web = _hasWebPage(form, bundles);
    // What the Host keeps as the person's own (held edits are 放弃's).
    final userSet = form.view.user?.isNotEmpty ?? false;

    Widget webCard() => SettingsSection(
      children: [
        EngineFieldRow(
          key: const ValueKey('plugin-config-web'),
          title: l10n.pluginConfigOpenWeb,
          subtitle: l10n.pluginConfigOpenWebHint,
          opensExternally: true,
          enabled: !_busy(state),
          onTap: () => unawaited(_openWeb(title, bundles)),
        ),
      ],
    );

    // A long form folds its titled groups (the untitled top stays open),
    // unless its schema folds groups of its own.
    final titled = layout.sections.where((s) => s.title != null).length;
    final foldGroups = !searching && !layout.authored && layout.fieldCount >= pluginConfigFoldFrom && titled >= 2;
    final groups = _groupsOf(layout, settings, fold: foldGroups);

    final page = AppPage.list(
      title: title,
      subtitle: state.local || state.hostLabel == null ? null : Text(state.hostLabel!),
      actions: [SchemaDocumentationButton(schema: form.view.schema, title: title)],
      children: [
        if (!state.writable)
          Padding(padding: const EdgeInsets.only(bottom: 16), child: FeatureNote(l10n.engineSettingsReadOnly))
        // What its row in the list said (bridge R7): an overlay fixes it.
        else if (state.entries[ns] case final entry? when entry.readOnly)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: FeatureNote(entry.fixedByFile ? l10n.pluginConfigFixedNote : l10n.engineSettingsReadOnly),
          ),
        if (form.failed)
          SettingsSection(
            children: [
              EngineFieldRow(
                title: l10n.pluginConfigNotStarted,
                subtitle: form.error,
                subtitleColor: DshColors.of(context).danger,
              ),
            ],
          ),
        if (layout.fieldCount >= pluginConfigSearchFrom)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SearchCapsule(
              key: const ValueKey('plugin-config-search'),
              controller: _search,
              hint: l10n.pluginConfigSearchHint,
              onChanged: (text) => setState(() => _query = text),
              onClear: () => setState(() {
                _search.clear();
                _query = '';
              }),
            ),
          ),
        if (web && form.prefersOwnPage && !searching) webCard(),
        if (searching && layout.sections.isEmpty)
          FeatureMessage(icon: AppIcons.search, title: l10n.pluginConfigNoMatch)
        else
          ...groups,
        if (layout.isEmpty && !searching && !web)
          FeatureMessage(icon: AppIcons.configure, title: l10n.pluginConfigNone),
        if (web && !form.prefersOwnPage && !searching) webCard(),
        if (userSet && !searching && settings.canWrite(ns))
          SettingsSection(
            children: [
              EngineFieldRow(
                key: const ValueKey('plugin-config-reset-all'),
                title: l10n.pluginConfigResetAll,
                chevron: false,
                onTap: () => unawaited(_resetAll()),
              ),
            ],
          ),
        _SaveBarRoom(ns: ns),
      ],
    );

    return SchemaFormScope(
      source: PluginConfigSource(ns),
      child: DiscardGuard(
        listenable: _guarded,
        isDirty: () => _dirty.value,
        child: Stack(
          children: [
            // The form's own ways to DSH Web (「在网页版编辑此项」) go the page's way.
            DshWebOpenScope(onOpen: (target) => unawaited(_openWeb(title, bundles, target)), child: page),
            _SaveBarSlot(ns: ns, controller: _controller),
          ],
        ),
      ),
    );
  }
}

/// The held edits and the save of [ns] the bar shows.
({int changes, PluginConfigJob? job}) _barOf(AsyncValue<PluginConfigState?> async, String ns) =>
    (changes: async.value?.draftOf(ns).length ?? 0, job: async.value?.jobOf(ns));

/// Room at the end of the page while the save bar shows, so nothing hides
/// under it.
class _SaveBarRoom extends ConsumerWidget {
  const _SaveBarRoom({required this.ns});

  final String ns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shows = ref.watch(
      pluginConfigProvider.select((async) {
        final (:changes, :job) = _barOf(async, ns);
        return PluginConfigSaveBar.shows(changes, job);
      }),
    );
    return SizedBox(height: shows ? PluginConfigSaveBar.reserve : 0);
  }
}

/// The save bar at the page's foot, above the keyboard. It watches the held
/// edits and the save itself: an edit redraws the bar, not the page, and
/// neither does the keyboard sliding in.
class _SaveBarSlot extends ConsumerWidget {
  const _SaveBarSlot({required this.ns, required this.controller});

  final String ns;
  final PluginConfigController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:changes, :job) = ref.watch(pluginConfigProvider.select((async) => _barOf(async, ns)));
    final bar = PluginConfigSaveBar.shows(changes, job);
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.viewInsetsOf(context).bottom,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.standard),
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
        child: bar
            ? PluginConfigSaveBar(
                key: const ValueKey('plugin-config-bar'),
                changes: changes,
                job: job,
                onSave: () => unawaited(controller.save(ns)),
                onDiscard: () => controller.discard(ns),
                onRetry: () => unawaited(controller.retry(ns)),
                onRestore: () => unawaited(controller.rollback(ns)),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// What a page shows while it is still sliding in (its route's entrance):
/// the loading line, then [onEntered] once the page is in place — after this
/// frame when it already is.
class _AfterEntrance extends StatefulWidget {
  const _AfterEntrance({required this.onEntered});

  final VoidCallback onEntered;

  @override
  State<_AfterEntrance> createState() => _AfterEntranceState();
}

class _AfterEntranceState extends State<_AfterEntrance> {
  Animation<double>? _entrance;
  var _entered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final entrance = ModalRoute.of(context)?.animation;
    if (identical(entrance, _entrance)) return;
    _entrance?.removeStatusListener(_onStatus);
    _entrance = entrance;
    if (entrance != null && entrance.status == AnimationStatus.forward) {
      entrance.addStatusListener(_onStatus);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _enter());
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.forward) _enter();
  }

  void _enter() {
    _entrance?.removeStatusListener(_onStatus);
    if (!mounted || _entered) return;
    _entered = true;
    widget.onEntered();
  }

  @override
  void dispose() {
    _entrance?.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const FeatureLoading();
}
