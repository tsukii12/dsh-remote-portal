// ui.json as app state. Each host has its own file: [uiConfigProvider] follows
// one host's, keeps its last good text per host for the next cold start, and
// [uiOverridesProvider] gives the active host's configuration minus the
// settings set aside with 「恢复默认」. The ui*Provider values at the bottom merge
// ui.json over the app's own settings for the screens to read, each with the
// entry that set it (for 「来自 ui.json」).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show AppLifecycleListener, Color, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/seams/seat_models.dart' show SeatOverride, SeatOverrides;
import '../runtime/runtime_bridge.dart' show RuntimePhase;
import '../runtime/runtime_state.dart';
import '../share_code/guest_fs.dart';
import '../state/appearance_state.dart';
import '../state/connection_state.dart';
import '../state/drawer_view_state.dart';
import '../state/hosts_state.dart';
import '../state/settings_state.dart';
import '../ui/theme/accent.dart';
import 'ui_config_ignores.dart';
import 'ui_config_model.dart';
import 'ui_config_parser.dart';
import 'ui_config_source.dart';

// ── Wiring (tests override these) ───────────────────────────────────────────

/// Moments to look again: the app came to the front, the network changed.
final uiConfigKicksProvider = Provider<Stream<void>>((ref) => ref.watch(networkKicksProvider));

/// Moments to look at the on-device file again: the app came to the front
/// (a network change says nothing about a local file).
final uiLocalKicksProvider = Provider<Stream<void>>((ref) {
  final kicks = StreamController<void>.broadcast();
  final lifecycle = AppLifecycleListener(onResume: () => kicks.add(null));
  ref.onDispose(() {
    lifecycle.dispose();
    unawaited(kicks.close());
  });
  return kicks.stream;
});

/// The on-device rootfs (guest `/`), or null before the runtime is installed.
typedef UiRootfsResolver = Future<Directory?> Function();

final uiRootfsResolverProvider = Provider<UiRootfsResolver>(
  (ref) =>
      () async => (await GuestFs.local())?.root,
);

/// Makes the source for [host], using the caller's [ref] (so the config
/// follows the connection); null when the host can't be read now.
typedef UiConfigSourceBuilder = UiConfigSource? Function(Ref ref, HostRef host);

/// What [uiConfigSourceBuilderProvider] uses; tests swap in a no-op builder so
/// pages that read `ui.json` do not open `dsh/runtime/events` unasked.
UiConfigSourceBuilder defaultUiConfigSourceBuilder = defaultUiConfigSource;

final uiConfigSourceBuilderProvider = Provider<UiConfigSourceBuilder>((ref) => defaultUiConfigSourceBuilder);

/// Local: the rootfs file, looked at again on resumes and runtime changes.
/// Remote: only the active host's, over its open connection.
UiConfigSource? defaultUiConfigSource(Ref ref, HostRef host) {
  if (host.isLocal) {
    final kicks = StreamController<void>.broadcast();
    ref.onDispose(kicks.close);
    ref.listen(localRuntimeProvider.select((s) => s.status.phase), (_, _) => kicks.add(null));
    final resumes = ref.watch(uiLocalKicksProvider).listen(kicks.add);
    ref.onDispose(resumes.cancel);
    return LocalUiConfigSource(
      rootfs: ref.read(uiRootfsResolverProvider),
      kicks: kicks.stream,
      mayWrite: () => ref.read(localRuntimeProvider).status.phase != RuntimePhase.installing,
    );
  }
  if (ref.watch(activeHostProvider) != host) return null;
  final conn = ref.watch(activeConnectionProvider.select((c) => c.value));
  if (conn == null || conn.isLocal || conn.kind != host.kind || conn.hostId != host.id) return null;
  return RemoteUiConfigSource(host: DshUiRemoteHost(conn.client), kicks: ref.watch(uiConfigKicksProvider));
}

// ── One host's file ─────────────────────────────────────────────────────────

/// Whether and how a host's ui.json is being followed.
enum UiConfigAvailability {
  /// Not started yet.
  idle,

  /// Following the file; [UiConfigState.load] is current.
  live,

  /// Not reachable now (another host is active, offline); [UiConfigState.load]
  /// is the last good one remembered for this host, if any.
  cached,

  /// There is no ui.json.
  absent,

  /// The on-device runtime is not installed.
  noRuntime,

  /// A remote host with no conversation yet.
  noSession,

  /// A remote host where the dsh-go-ui skill is not installed and DSH home
  /// is unknown.
  noSkill,

  /// The host can't read files for the app (some relays).
  unsupported,

  /// The host refused to read the file.
  denied,
}

/// A host's ui.json as far as the app knows it.
class UiConfigState {
  const UiConfigState({
    this.load,
    this.availability = UiConfigAvailability.idle,
    this.restored = false,
    this.skillMissing = false,
  });

  /// The last read, or null when there is no file (or none read yet).
  final UiConfigLoad? load;
  final UiConfigAvailability availability;

  /// The remembered configuration has been looked up (cold start: wait for
  /// this before drawing what ui.json decides, to avoid a flash).
  final bool restored;

  /// A remote host without the dsh-go-ui skill.
  final bool skillMissing;

  /// Offer to install the skill (remote hosts only).
  bool get needsSkill => skillMissing || availability == UiConfigAvailability.noSkill;

  UiConfigState copyWith({
    UiConfigLoad? Function()? load,
    UiConfigAvailability? availability,
    bool? restored,
    bool? skillMissing,
  }) => UiConfigState(
    load: load != null ? load() : this.load,
    availability: availability ?? this.availability,
    restored: restored ?? this.restored,
    skillMissing: skillMissing ?? this.skillMissing,
  );
}

/// Follows one host's ui.json.
class UiConfigController extends Notifier<UiConfigState> {
  UiConfigController(this.host);

  final HostRef host;

  static String cacheKey(HostRef host) => 'ui_config.cache.${uiHostKey(host)}';

  UiConfigState _now = const UiConfigState();
  String? _lastText;
  bool _sawLive = false;
  UiConfigSource? _source;

  /// The newest good configuration (for a fatal read to keep).
  UiConfig? get _lastGood {
    final load = _now.load;
    if (load == null) return null;
    return load.config;
  }

  @override
  UiConfigState build() {
    final source = ref.read(uiConfigSourceBuilderProvider)(ref, host);
    _source = source;
    if (!_now.restored) unawaited(_restore());
    if (source != null) {
      final sub = source.watch().listen(_onRead, onError: (Object _) {});
      ref.onDispose(sub.cancel);
    } else {
      _sawLive = false;
    }
    return _now = _now.copyWith(
      availability: source == null
          ? UiConfigAvailability.cached
          : (_sawLive ? _now.availability : UiConfigAvailability.idle),
    );
  }

  void _set(UiConfigState next) {
    _now = next;
    state = next;
  }

  Future<void> _restore() async {
    String? text;
    try {
      final prefs = await SharedPreferences.getInstance();
      text = prefs.getString(cacheKey(host));
    } catch (_) {}
    if (!ref.mounted) return;
    if (text != null && _lastText == null && !_sawLive) {
      final load = parseUiConfig(text);
      _set(_now.copyWith(load: load.fatal ? null : () => load, restored: true));
    } else {
      _set(_now.copyWith(restored: true));
    }
  }

  Future<void> _remember(String? text) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      text == null ? await prefs.remove(cacheKey(host)) : await prefs.setString(cacheKey(host), text);
    } catch (_) {}
  }

  void _onRead(UiConfigRead read) {
    if (!ref.mounted) return;
    _sawLive = true;
    switch (read) {
      case UiConfigText(:final text, :final version):
        if (text == _lastText && _now.load != null) {
          if (_now.availability != UiConfigAvailability.live) {
            _set(_now.copyWith(availability: UiConfigAvailability.live));
          }
          return;
        }
        _lastText = text;
        final load = parseUiConfig(text, lastGood: _lastGood, sourceVersion: version);
        _set(
          _now.copyWith(load: () => load, availability: UiConfigAvailability.live, restored: true, skillMissing: false),
        );
        if (!load.fatal) {
          unawaited(_remember(text));
          unawaited(ref.read(uiIgnoresProvider.notifier).prune(host, load.config));
        }
        _report(load);
      case UiConfigBroken(:final message, :final version):
        _lastText = null;
        final lastGood = _lastGood;
        final load = UiConfigLoad(
          config: lastGood ?? UiConfig.empty,
          issues: [UiConfigIssue('', message, UiIssueKind.fatal)],
          readAt: DateTime.now(),
          sourceVersion: version,
          fromLastGood: lastGood != null,
        );
        _set(_now.copyWith(load: () => load, availability: UiConfigAvailability.live, restored: true));
        _report(load);
      case UiConfigAbsent(:final skillMissing):
        _lastText = null;
        _set(UiConfigState(availability: UiConfigAvailability.absent, restored: true, skillMissing: skillMissing));
        unawaited(_remember(null));
        _report(null);
      case UiConfigUnavailable(:final reason):
        final availability = switch (reason) {
          UiConfigUnavailableReason.noRuntime => UiConfigAvailability.noRuntime,
          UiConfigUnavailableReason.noSession => UiConfigAvailability.noSession,
          UiConfigUnavailableReason.noSkill => UiConfigAvailability.noSkill,
          UiConfigUnavailableReason.unsupported => UiConfigAvailability.unsupported,
          UiConfigUnavailableReason.denied => UiConfigAvailability.denied,
        };
        // Nothing to read on the phone: no file. Elsewhere keep what the
        // host said last.
        if (reason == UiConfigUnavailableReason.noRuntime) {
          _lastText = null;
          _set(UiConfigState(availability: availability, restored: true));
        } else {
          _set(_now.copyWith(availability: availability, restored: true));
        }
    }
  }

  void _report(UiConfigLoad? load) {
    if (_source case final UiConfigStatusSink sink) unawaited(sink.writeStatus(load));
  }
}

final uiConfigProvider = NotifierProvider.family<UiConfigController, UiConfigState, HostRef>(UiConfigController.new);

// ── The active host's configuration ─────────────────────────────────────────

/// The active host's ui.json after 「恢复默认」: what the screens apply.
class UiOverrides {
  const UiOverrides({required this.host, this.config = UiConfig.empty, this.load});

  final HostRef host;

  /// Applied settings (set-aside ones removed).
  final UiConfig config;

  /// The read it came from (issues, time), null without a file.
  final UiConfigLoad? load;

  /// The entry behind [key] when ui.json sets it now; null when the app's
  /// own setting applies.
  UiConfigEntry? entryFor(UiSettingKey key) => config.entries[key];

  bool fromUiJson(UiSettingKey key) => config.entries.containsKey(key);

  bool hides(UiHideItem item) => config.hides(item);
}

final uiOverridesProvider = Provider<UiOverrides>((ref) {
  final host = ref.watch(activeHostProvider);
  final load = ref.watch(uiConfigProvider(host).select((s) => s.load));
  if (load == null) return UiOverrides(host: host);
  final ignores = ref.watch(uiIgnoresProvider);
  final aside = {
    for (final entry in load.config.entries.values)
      if (ignores.any((i) => i.matches(host, entry))) entry.key,
  };
  return UiOverrides(host: host, config: load.config.without(aside), load: load);
});

/// The ui.json entry behind one setting on the active host (null: the app's
/// own value applies). What [FromUiJsonBadge] and greyed-out controls read.
final uiSettingEntryProvider = Provider.family<UiConfigEntry?, UiSettingKey>(
  (ref, key) => ref.watch(uiOverridesProvider.select((o) => o.entryFor(key))),
);

/// 「恢复默认」 for [key] on the active host: the app's own setting applies
/// again while the file keeps this value.
Future<void> restoreUiDefault(UiOverrides overrides, UiIgnoresController ignores, UiSettingKey key) async {
  final entry = overrides.entryFor(key);
  if (entry != null) await ignores.ignore(overrides.host, entry);
}

// ── Merged values ───────────────────────────────────────────────────────────

/// A value and, when ui.json set it, the entry that did.
class UiValue<T> {
  const UiValue(this.value, [this.entry]);

  final T value;
  final UiConfigEntry? entry;

  bool get fromUiJson => entry != null;

  @override
  bool operator ==(Object other) => other is UiValue<T> && other.value == value && other.entry == entry;

  @override
  int get hashCode => Object.hash(value, entry);
}

/// Light / dark: ui.json's `theme.mode` over 设置 › 外观.
final uiThemeModeProvider = Provider<UiValue<ThemeMode>>((ref) {
  final mode = ref.watch(uiOverridesProvider.select((o) => o.config.themeMode));
  if (mode == null) return UiValue(ref.watch(settingsProvider.select((s) => s.themeMode)));
  return UiValue(switch (mode) {
    UiThemeMode.system => ThemeMode.system,
    UiThemeMode.light => ThemeMode.light,
    UiThemeMode.dark => ThemeMode.dark,
  }, ref.watch(uiSettingEntryProvider(UiSettingKey.themeMode)));
});

/// The palette: ui.json's `theme.accentPreset` / `theme.accent` over 外观's.
/// A custom colour goes through the same derivation and contrast guard as
/// the appearance page's.
final uiAccentProvider = Provider<UiValue<AppAccent>>((ref) {
  final accent = ref.watch(uiOverridesProvider.select((o) => o.config.accent));
  if (accent == null) return UiValue(ref.watch(accentProvider));
  final entry = ref.watch(uiSettingEntryProvider(UiSettingKey.accent));
  if (accent.presetId case final id?) return UiValue(AppAccent.preset(id), entry);
  return UiValue(AppAccent.derive(Color(0xFF000000 | accent.rgb!)), entry);
});

/// The drawer's order: ui.json's `drawer.sort` over the drawer's own.
final uiDrawerSortProvider = Provider<UiValue<DrawerSort>>((ref) {
  final sort = ref.watch(uiOverridesProvider.select((o) => o.config.drawerSort));
  if (sort == null) return UiValue(ref.watch(drawerViewProvider.select((v) => v.sort)));
  return UiValue(DrawerSort.values.byName(sort.name), ref.watch(uiSettingEntryProvider(UiSettingKey.drawerSort)));
});

/// The filter the drawer opens with (the drawer's own filter is per run).
final uiDrawerFilterProvider = Provider<UiValue<DrawerFilter>>((ref) {
  final filter = ref.watch(uiOverridesProvider.select((o) => o.config.drawerFilter));
  if (filter == null) return const UiValue(DrawerFilter.all);
  return UiValue(DrawerFilter.values.byName(filter.name), ref.watch(uiSettingEntryProvider(UiSettingKey.drawerFilter)));
});

/// Row density (no app setting yet: comfortable).
final uiDensityProvider = Provider<UiValue<UiDensity>>((ref) {
  final density = ref.watch(uiOverridesProvider.select((o) => o.config.density));
  if (density == null) return const UiValue(UiDensity.comfortable);
  return UiValue(density, ref.watch(uiSettingEntryProvider(UiSettingKey.density)));
});

/// Applied ui.json `plugins.seats`, before the planner merges local preferences.
final uiSeatOverridesProvider = Provider<SeatOverrides>((ref) {
  final seats = ref.watch(uiOverridesProvider.select((o) => o.config.seats));
  if (seats.isEmpty) return SeatOverrides.none;
  return SeatOverrides({
    for (final MapEntry(key: slot, value: packages) in seats.entries)
      slot: {
        for (final MapEntry(key: package, value: mode) in packages.entries) package: ?SeatOverride.tryParse(mode.name),
      },
  });
});

/// Whether ui.json hides [UiHideItem] on the active host.
final uiHiddenProvider = Provider.family<bool, UiHideItem>(
  (ref, item) => ref.watch(uiOverridesProvider.select((o) => o.hides(item))),
);

// ── Skill auto-install hook ─────────────────────────────────────────────────

/// True while the on-device engine is running (the skill installer's cue).
final uiLocalEngineRunningProvider = Provider<bool>(
  (ref) => ref.watch(localRuntimeProvider.select((s) => s.status.phase == RuntimePhase.running)),
);
