// What a parsed ui.json says, and what went wrong reading it. Nothing here runs
// anything: an action is data until the person taps the control that carries
// it.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable, listEquals;

// ── Actions ─────────────────────────────────────────────────────────────────

/// One of the four things a ui.json control may do, chosen by the person's
/// tap and never on load.
@immutable
sealed class UiAction {
  const UiAction();

  /// The canonical JSON form (also what [UiConfigEntry.hash] is taken of).
  Map<String, Object?> toJson();

  @override
  bool operator ==(Object other) => other is UiAction && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Puts [text] into the composer; the person still taps send.
final class UiSendAction extends UiAction {
  const UiSendAction(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'send', 'text': text};
}

/// Opens a native page: a feature-catalog id, `new-chat` or `settings`.
final class UiOpenAction extends UiAction {
  const UiOpenAction(this.page);

  final String page;

  @override
  Map<String, Object?> toJson() => {'type': 'open', 'page': page};
}

/// Runs `/name args` in the current conversation (`commands/execute`).
final class UiCommandAction extends UiAction {
  const UiCommandAction(this.name, {this.args});

  /// Without the slash.
  final String name;
  final String? args;

  /// The line `commands/execute` takes.
  String get line => args == null ? '/$name' : '/$name $args';

  @override
  Map<String, Object?> toJson() => {'type': 'command', 'name': name, 'args': ?args};
}

/// Opens an https link in the browser after a confirmation that shows its
/// full host.
final class UiLinkAction extends UiAction {
  const UiLinkAction(this.url);

  final Uri url;

  @override
  Map<String, Object?> toJson() => {'type': 'link', 'url': url.toString()};
}

// ── Items ───────────────────────────────────────────────────────────────────

enum UiHeaderBuiltin { newChat, detail, schedule, agents, model }

/// One entry of `header.actions`: a built-in button or a custom one.
@immutable
sealed class UiHeaderItem {
  const UiHeaderItem();

  Object toJson();

  @override
  bool operator ==(Object other) => other is UiHeaderItem && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

final class UiHeaderBuiltinItem extends UiHeaderItem {
  const UiHeaderBuiltinItem(this.builtin);

  final UiHeaderBuiltin builtin;

  @override
  Object toJson() => builtin.name;
}

final class UiHeaderCustomItem extends UiHeaderItem {
  const UiHeaderCustomItem({required this.id, required this.icon, required this.label, required this.action});

  final String id;

  /// A name from `UiSchema.icons` (see `uiConfigIcon`).
  final String icon;
  final String label;
  final UiAction action;

  @override
  Object toJson() => {'id': id, 'icon': icon, 'label': label, 'action': action.toJson()};
}

/// A capsule above the composer.
@immutable
class UiQuickAction {
  const UiQuickAction({required this.label, required this.action});

  final String label;
  final UiAction action;

  Map<String, Object?> toJson() => {'label': label, 'action': action.toJson()};

  @override
  bool operator ==(Object other) => other is UiQuickAction && other.label == label && other.action == action;

  @override
  int get hashCode => Object.hash(label, action);
}

/// A card on the empty new-chat screen.
@immutable
class UiSuggestion {
  const UiSuggestion({required this.title, this.subtitle, required this.action});

  final String title;
  final String? subtitle;
  final UiAction action;

  Map<String, Object?> toJson() => {'title': title, 'subtitle': ?subtitle, 'action': action.toJson()};

  @override
  bool operator ==(Object other) =>
      other is UiSuggestion && other.title == title && other.subtitle == subtitle && other.action == action;

  @override
  int get hashCode => Object.hash(title, subtitle, action);
}

/// A hardware-keyboard shortcut; [keys] is canonical (`ctrl+alt+shift+k`,
/// modifiers in that order, lower case).
@immutable
class UiShortcut {
  const UiShortcut({required this.keys, required this.action});

  final String keys;
  final UiAction action;

  bool get ctrl => keys.split('+').contains('ctrl');
  bool get alt => keys.split('+').contains('alt');
  bool get shift => keys.split('+').contains('shift');

  /// The key after the modifiers (`k`, `f5`, `/`, `enter`, `up`…).
  String get key => keys.split('+').last;

  Map<String, Object?> toJson() => {'keys': keys, 'action': action.toJson()};

  @override
  bool operator ==(Object other) => other is UiShortcut && other.keys == keys && other.action == action;

  @override
  int get hashCode => Object.hash(keys, action);
}

enum UiDrawerGroup { pinned, folders, today, yesterday, thisWeek, earlier }

enum UiDrawerSort { activity, created }

enum UiDrawerFilter { all, running, pending, unread }

enum UiDensity { compact, comfortable }

enum UiHideItem { turnFooter, tokenCount, reasoningDetails, activityStrip, whaleTail, todoPill, goalBar, pluginCapsule }

enum UiThemeMode { system, light, dark }

enum UiPetPosition {
  topLeft('top-left'),
  topRight('top-right'),
  bottomLeft('bottom-left'),
  bottomRight('bottom-right');

  const UiPetPosition(this.wire);

  final String wire;
}

/// `plugins.seats` values; [web] is the seat's 「在网页版打开」 row.
enum UiSeatMode { native, island, web, hidden }

/// `theme.accentPreset` ([presetId]) or `theme.accent` ([rgb], 0xRRGGBB).
@immutable
class UiAccent {
  const UiAccent.preset(String this.presetId) : rgb = null;

  const UiAccent.color(int this.rgb) : presetId = null;

  final String? presetId;
  final int? rgb;

  Object toJson() => presetId ?? '#${rgb!.toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  bool operator ==(Object other) => other is UiAccent && other.presetId == presetId && other.rgb == rgb;

  @override
  int get hashCode => Object.hash(presetId, rgb);
}

/// The pet's preferences; each field is optional. Parsed and validated;
/// nothing reads them yet.
@immutable
class UiPetSpec {
  const UiPetSpec({this.id, this.position, this.quiet});

  final String? id;
  final UiPetPosition? position;
  final bool? quiet;

  Map<String, Object?> toJson() => {'id': ?id, 'position': ?position?.wire, 'quiet': ?quiet};

  @override
  bool operator ==(Object other) =>
      other is UiPetSpec && other.id == id && other.position == position && other.quiet == quiet;

  @override
  int get hashCode => Object.hash(id, position, quiet);
}

// ── Settings and their provenance ───────────────────────────────────────────

/// One thing ui.json can set: the unit that is marked 「来自 ui.json」 and
/// that 「恢复默认」 sets aside. Equality is by [id].
@immutable
class UiSettingKey {
  const UiSettingKey._(this.id);

  final String id;

  static const headerActions = UiSettingKey._('header.actions');
  static const quickActions = UiSettingKey._('composer.quickActions');
  static const suggestions = UiSettingKey._('emptyState.suggestions');
  static const drawerGroups = UiSettingKey._('drawer.groups');
  static const drawerSort = UiSettingKey._('drawer.sort');
  static const drawerFilter = UiSettingKey._('drawer.filter');
  static const density = UiSettingKey._('density');
  static const themeMode = UiSettingKey._('theme.mode');

  /// `theme.accentPreset` or `theme.accent`, whichever the file uses.
  static const accent = UiSettingKey._('theme.accent');
  static const pet = UiSettingKey._('pet');
  static const shortcuts = UiSettingKey._('shortcuts');

  /// One hidden item (`hide` lists several).
  static UiSettingKey hide(UiHideItem item) => UiSettingKey._('hide.${item.name}');

  /// One seat override: [package] in [slot].
  static UiSettingKey seat(String slot, String package) => UiSettingKey._('plugins.seats|$slot|$package');

  /// Rebuilds a key from its [id] (the ignore table stores ids).
  static UiSettingKey fromId(String id) => UiSettingKey._(id);

  @override
  bool operator ==(Object other) => other is UiSettingKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'UiSettingKey($id)';
}

/// Where a setting sits in the file and what it says.
@immutable
class UiConfigEntry {
  const UiConfigEntry({required this.key, required this.pointer, required this.value});

  final UiSettingKey key;

  /// JSON Pointer into ui.json (`/theme/mode`, `/hide/2`).
  final String pointer;

  /// The canonical JSON of the value as applied (after trimming).
  final Object? value;

  /// Short fingerprint of [value]: a 「恢复默认」 lasts while it matches.
  String get hash => sha256.convert(utf8.encode(_canonical(value))).toString().substring(0, 16);

  /// The value for people: a string as is, anything else as compact JSON,
  /// cut to 200 characters.
  String get display {
    final v = value;
    final text = v is String ? v : jsonEncode(v);
    final runes = text.runes.toList();
    return runes.length <= 200 ? text : '${String.fromCharCodes(runes.take(199))}…';
  }

  @override
  bool operator ==(Object other) =>
      other is UiConfigEntry && other.key == key && other.pointer == pointer && other.hash == hash;

  @override
  int get hashCode => Object.hash(key, pointer, hash);
}

String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

// ── The configuration ───────────────────────────────────────────────────────

/// The applied content of one ui.json. A null field is "not set": the app's
/// own default or setting stays.
@immutable
class UiConfig {
  const UiConfig({
    this.headerActions,
    this.quickActions,
    this.suggestions,
    this.drawerGroups,
    this.drawerSort,
    this.drawerFilter,
    this.density,
    this.hide = const [],
    this.themeMode,
    this.accent,
    this.pet,
    this.shortcuts,
    this.seats = const {},
    this.entries = const {},
  });

  static const empty = UiConfig();

  /// In display order; built-ins not listed are hidden. `[]` hides them all.
  final List<UiHeaderItem>? headerActions;
  final List<UiQuickAction>? quickActions;
  final List<UiSuggestion>? suggestions;

  /// Groups in display order; groups not listed are hidden.
  final List<UiDrawerGroup>? drawerGroups;
  final UiDrawerSort? drawerSort;

  /// The drawer's filter when it opens.
  final UiDrawerFilter? drawerFilter;
  final UiDensity? density;
  final List<UiHideItem> hide;
  final UiThemeMode? themeMode;
  final UiAccent? accent;
  final UiPetSpec? pet;
  final List<UiShortcut>? shortcuts;

  /// slot → package → mode.
  final Map<String, Map<String, UiSeatMode>> seats;

  /// Every applied setting with its place in the file.
  final Map<UiSettingKey, UiConfigEntry> entries;

  bool get isEmpty => entries.isEmpty;

  /// 「已应用 N 项」: one per setting (a list setting counts once, each
  /// hidden item and each seat override once).
  int get appliedCount => entries.length;

  bool hides(UiHideItem item) => hide.contains(item);

  /// The same configuration without [keys] (settings set aside with
  /// 「恢复默认」).
  UiConfig without(Set<UiSettingKey> keys) {
    if (keys.isEmpty || !keys.any(entries.containsKey)) return this;
    bool keep(UiSettingKey key) => !keys.contains(key);
    return UiConfig(
      headerActions: keep(UiSettingKey.headerActions) ? headerActions : null,
      quickActions: keep(UiSettingKey.quickActions) ? quickActions : null,
      suggestions: keep(UiSettingKey.suggestions) ? suggestions : null,
      drawerGroups: keep(UiSettingKey.drawerGroups) ? drawerGroups : null,
      drawerSort: keep(UiSettingKey.drawerSort) ? drawerSort : null,
      drawerFilter: keep(UiSettingKey.drawerFilter) ? drawerFilter : null,
      density: keep(UiSettingKey.density) ? density : null,
      hide: [
        for (final item in hide)
          if (keep(UiSettingKey.hide(item))) item,
      ],
      themeMode: keep(UiSettingKey.themeMode) ? themeMode : null,
      accent: keep(UiSettingKey.accent) ? accent : null,
      pet: keep(UiSettingKey.pet) ? pet : null,
      shortcuts: keep(UiSettingKey.shortcuts) ? shortcuts : null,
      seats: {
        for (final MapEntry(key: slot, value: packages) in seats.entries)
          if ({
                for (final MapEntry(key: package, value: mode) in packages.entries)
                  if (keep(UiSettingKey.seat(slot, package))) package: mode,
              }
              case final kept when kept.isNotEmpty)
            slot: kept,
      },
      entries: {
        for (final MapEntry(:key, :value) in entries.entries)
          if (keep(key)) key: value,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UiConfig &&
      other.entries.length == entries.length &&
      entries.entries.every((e) => other.entries[e.key] == e.value) &&
      listEquals(other.hide, hide);

  @override
  int get hashCode => Object.hashAllUnordered(entries.values);
}

// ── Reading results ─────────────────────────────────────────────────────────

/// How serious an issue is.
enum UiIssueKind {
  /// The whole file is not applied (syntax, version, size); the last good
  /// configuration stays.
  fatal,

  /// This item or field is wrong and left out.
  invalid,

  /// Valid JSON the app does not use: unknown keys, repeats, items over a
  /// limit.
  ignored,

  /// Applied after a small fix (cut to length, a stray `/` removed).
  adjusted;

  /// Whether the issue means something in the file has no effect.
  bool get dropsSomething => this != adjusted;
}

/// One problem, at a JSON Pointer (`''` is the whole file).
@immutable
class UiConfigIssue {
  const UiConfigIssue(this.pointer, this.message, this.kind);

  final String pointer;
  final String message;
  final UiIssueKind kind;

  bool get fatal => kind == UiIssueKind.fatal;

  /// `/composer/quickActions/2/action/url：只支持 https 链接`.
  String get line => pointer.isEmpty ? message : '$pointer：$message';

  Map<String, Object?> toJson() => {'pointer': pointer, 'kind': kind.name, 'message': message};

  @override
  bool operator ==(Object other) =>
      other is UiConfigIssue && other.pointer == pointer && other.message == message && other.kind == kind;

  @override
  int get hashCode => Object.hash(pointer, message, kind);

  @override
  String toString() => 'UiConfigIssue(${kind.name} $line)';
}

/// One read of ui.json: what applies and what went wrong.
@immutable
class UiConfigLoad {
  const UiConfigLoad({
    required this.config,
    this.issues = const [],
    required this.readAt,
    this.sourceVersion,
    this.fromLastGood = false,
  });

  /// What applies: the file's content, or after a fatal issue the last good
  /// configuration (or nothing).
  final UiConfig config;
  final List<UiConfigIssue> issues;
  final DateTime readAt;

  /// The source's freshness token (local mtime and size, the Host's version).
  final String? sourceVersion;

  /// [config] is the previous good one: this read had a fatal issue.
  final bool fromLastGood;

  bool get fatal => issues.any((i) => i.fatal);

  /// 「N 处没生效」.
  int get notAppliedCount => issues.where((i) => i.kind.dropsSomething).length;

  int get appliedCount => fatal ? 0 : config.appliedCount;
}
