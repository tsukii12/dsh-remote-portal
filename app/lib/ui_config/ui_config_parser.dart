// ui.json v1 → [UiConfigLoad]. Every item stands alone: a wrong one is left out
// with a JSON Pointer and a short reason, the rest applies. A file that cannot
// be read as a whole (syntax, size, version) keeps the last good configuration.
//
// `assets/skills/dsh-go-ui/check.mjs` is this file's twin for the agent on the
// Host: same traversal order, same pointers, same words. Change both together;
// test/ui_config/check_mjs_parity_test.dart runs the shared fixtures through
// each.

import 'dart:convert';

import '../l10n/l10n.dart';
import '../plugins/seams/slot_catalog.dart' show slotInfo;
import 'ui_config_model.dart';
import 'ui_config_schema.dart';
import 'ui_json_reader.dart';

/// Messages shared with check.mjs.
abstract final class UiMessages {
  static String get fileTooLarge => appL10n.shellConfigFileTooLarge;
  static String get rootNotObject => appL10n.shellConfigRootNotObject;
  static String get versionMissing => appL10n.shellConfigVersionMissing;
  static String get versionNotInt => appL10n.shellConfigVersionNotInt;
  static String get versionTooLow => appL10n.shellConfigVersionTooLow;
  static String versionTooHigh(int v) => appL10n.shellConfigVersionTooHigh(v);
  static String get notObject => appL10n.shellConfigNotObject;
  static String get notArray => appL10n.shellConfigNotArray;
  static String get notString => appL10n.shellConfigNotString;
  static String get notBool => appL10n.shellConfigNotBool;
  static String get empty => appL10n.shellConfigEmpty;
  static String get unknownKey => appL10n.shellConfigUnknownKey;
  static String get duplicateKey => appL10n.shellConfigDuplicateKey;
  static String get duplicateItem => appL10n.shellConfigDuplicateItem;
  static String missing(String key) => appL10n.shellConfigMissing(key);
  static String truncated(int n) => appL10n.shellConfigTruncated(n);
  static String tooLong(int n) => appL10n.shellConfigTooLong(n);
  static String tooMany(int n) => appL10n.shellConfigTooMany(n);
  static String badValue(String value, List<String> options, {String? noun}) {
    noun ??= appL10n.shellConfigValueNoun;
    final runes = value.runes.toList();
    final shown = runes.length <= 32 ? value : '${String.fromCharCodes(runes.take(32))}…';
    final base = appL10n.shellConfigUnsupportedValue(noun, shown);
    return options.length <= 8
        ? appL10n.shellConfigValueOptions(noun, shown, options.join(appL10n.shellListSeparator))
        : base;
  }

  static String get headerItem => appL10n.shellConfigHeaderItem;
  static String get headerId => appL10n.shellConfigHeaderId;
  static String get idTaken => appL10n.shellConfigIdTaken;
  static String get commandSlash => appL10n.shellConfigCommandSlash;
  static String get commandName => appL10n.shellConfigCommandName;
  static String get noNewline => appL10n.shellConfigNoNewline;
  static String get httpsOnly => appL10n.shellConfigHttpsOnly;
  static String get badUrl => appL10n.shellConfigBadUrl;
  static String get accentFormat => appL10n.shellConfigAccentFormat;
  static String get accentBoth => appL10n.shellConfigAccentBoth;
  static String get petId => appL10n.shellConfigPetId;
  static String get keysFormat => appL10n.shellConfigKeysFormat;
  static String get systemKey => appL10n.shellConfigSystemKey;
  static String get needModifier => appL10n.shellConfigNeedModifier;
  static String get reserved => appL10n.shellConfigReservedKey;
  static String duplicateShortcut(String pointer) => appL10n.shellConfigDuplicateShortcut(pointer);
  static String get slotName => appL10n.shellConfigSlotName;
  static String get unknownSlot => appL10n.shellConfigUnknownSlot;
  static String get unseatableSlot => appL10n.shellConfigUnseatableSlot;
  static String get packageName => appL10n.shellConfigPackageName;
}

/// Parses ui.json [text]. On a fatal issue the result carries [lastGood]
/// (or the empty configuration) with [UiConfigLoad.fromLastGood] set.
UiConfigLoad parseUiConfig(String text, {UiConfig? lastGood, DateTime? readAt, String? sourceVersion}) {
  final at = readAt ?? DateTime.now();
  UiConfigLoad fatal(String pointer, String message) => UiConfigLoad(
    config: lastGood ?? UiConfig.empty,
    issues: [UiConfigIssue(pointer, message, UiIssueKind.fatal)],
    readAt: at,
    sourceVersion: sourceVersion,
    fromLastGood: lastGood != null,
  );

  if (utf8.encode(text).length > UiSchema.maxBytes) return fatal('', UiMessages.fileTooLarge);
  final UiJsonDocument doc;
  try {
    doc = readUiJson(text);
  } on UiJsonSyntaxError catch (e) {
    return fatal('', e.message);
  }
  final root = doc.value;
  if (root is! Map<String, Object?>) return fatal('', UiMessages.rootNotObject);
  if (!root.containsKey('version')) return fatal('/version', UiMessages.versionMissing);
  final version = root['version'];
  if (version is! int) return fatal('/version', UiMessages.versionNotInt);
  if (version < 1) return fatal('/version', UiMessages.versionTooLow);
  if (version > UiSchema.version) return fatal('/version', UiMessages.versionTooHigh(version));

  final v = _Validator();
  for (final pointer in doc.duplicateKeys) {
    v.issue(pointer, UiMessages.duplicateKey, UiIssueKind.ignored);
  }
  final config = v.root(root);
  return UiConfigLoad(config: config, issues: List.unmodifiable(v.issues), readAt: at, sourceVersion: sourceVersion);
}

final _controlChars = RegExp('[\u0000-\u001F\u007F-\u009F\u2028\u2029]');
final _lineBreaks = RegExp('\r\n|\r|\n|\t');
final _headerId = RegExp(r'^[a-z][a-zA-Z0-9-]{0,31}$');
final _commandName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$');
final _httpsUrl = RegExp(r'^https://([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(:[0-9]{1,5})?([/?#][^\s]*)?$');
final _badPercent = RegExp(r'%(?![0-9A-Fa-f]{2})');
final _hexColor = RegExp(r'^#[0-9A-Fa-f]{6}$');
final _petId = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
final _slot = RegExp(r'^[a-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*$');
final _package = RegExp(r'^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$');

class _Validator {
  final issues = <UiConfigIssue>[];
  final entries = <UiSettingKey, UiConfigEntry>{};

  void issue(String pointer, String message, [UiIssueKind kind = UiIssueKind.invalid]) =>
      issues.add(UiConfigIssue(pointer, message, kind));

  void entry(UiSettingKey key, String pointer, Object? value) =>
      entries[key] = UiConfigEntry(key: key, pointer: pointer, value: value);

  static String child(String pointer, String key) => '$pointer/${escapePointerToken(key)}';

  /// Flags keys outside [known]; returns nothing (callers read known keys).
  void unknownKeys(Map<String, Object?> map, String pointer, List<String> known) {
    for (final key in map.keys) {
      if (!known.contains(key)) issue(child(pointer, key), UiMessages.unknownKey, UiIssueKind.ignored);
    }
  }

  Map<String, Object?>? object(Object? value, String pointer) {
    if (value is Map<String, Object?>) return value;
    issue(pointer, UiMessages.notObject);
    return null;
  }

  List<Object?>? array(Object? value, String pointer) {
    if (value is List<Object?>) return value;
    issue(pointer, UiMessages.notArray);
    return null;
  }

  /// One value of [options]; null (with an issue) otherwise.
  String? choice(Object? value, String pointer, List<String> options, {String? noun}) {
    if (value is! String) {
      issue(pointer, UiMessages.notString);
      return null;
    }
    if (options.contains(value)) return value;
    issue(pointer, UiMessages.badValue(value, options, noun: noun));
    return null;
  }

  /// A one-line label: line breaks become spaces, control characters go,
  /// ends are trimmed, more than [max] characters are cut.
  String? label(Object? value, String pointer, int max) {
    if (value is! String) {
      issue(pointer, UiMessages.notString);
      return null;
    }
    final clean = value.replaceAll(_lineBreaks, ' ').replaceAll(_controlChars, '').trim();
    if (clean.isEmpty) {
      issue(pointer, UiMessages.empty);
      return null;
    }
    final runes = clean.runes.toList();
    if (runes.length <= max) return clean;
    issue(pointer, UiMessages.truncated(max), UiIssueKind.adjusted);
    return String.fromCharCodes(runes.take(max)).trim();
  }

  UiConfig root(Map<String, Object?> root) {
    List<UiHeaderItem>? headerActions;
    List<UiQuickAction>? quickActions;
    List<UiSuggestion>? suggestions;
    List<UiDrawerGroup>? drawerGroups;
    UiDrawerSort? drawerSort;
    UiDrawerFilter? drawerFilter;
    UiDensity? density;
    var hide = <UiHideItem>[];
    UiThemeMode? themeMode;
    UiAccent? accent;
    UiPetSpec? pet;
    List<UiShortcut>? shortcuts;
    var seats = <String, Map<String, UiSeatMode>>{};

    for (final MapEntry(:key, :value) in root.entries) {
      final p = child('', key);
      switch (key) {
        case 'version' || r'$schema':
          break;
        case 'header':
          headerActions = header(value, p);
        case 'composer':
          if (object(value, p) case final map?) {
            unknownKeys(map, p, const ['quickActions']);
            if (map.containsKey('quickActions')) {
              quickActions = quickActionList(map['quickActions'], child(p, 'quickActions'));
            }
          }
        case 'emptyState':
          if (object(value, p) case final map?) {
            unknownKeys(map, p, const ['suggestions']);
            if (map.containsKey('suggestions')) {
              suggestions = suggestionList(map['suggestions'], child(p, 'suggestions'));
            }
          }
        case 'drawer':
          if (object(value, p) case final map?) {
            for (final MapEntry(key: k, value: field) in map.entries) {
              final fp = child(p, k);
              switch (k) {
                case 'groups':
                  drawerGroups = groupList(field, fp);
                case 'sort':
                  if (choice(field, fp, UiSchema.drawerSorts) case final s?) {
                    drawerSort = UiDrawerSort.values.byName(s);
                    entry(UiSettingKey.drawerSort, fp, s);
                  }
                case 'filter':
                  if (choice(field, fp, UiSchema.drawerFilters) case final f?) {
                    drawerFilter = UiDrawerFilter.values.byName(f);
                    entry(UiSettingKey.drawerFilter, fp, f);
                  }
                default:
                  issue(fp, UiMessages.unknownKey, UiIssueKind.ignored);
              }
            }
          }
        case 'density':
          if (choice(value, p, UiSchema.densities) case final d?) {
            density = UiDensity.values.byName(d);
            entry(UiSettingKey.density, p, d);
          }
        case 'hide':
          hide = hideList(value, p);
        case 'theme':
          if (object(value, p) case final map?) {
            for (final MapEntry(key: k, value: field) in map.entries) {
              final fp = child(p, k);
              switch (k) {
                case 'mode':
                  if (choice(field, fp, UiSchema.themeModes) case final m?) {
                    themeMode = UiThemeMode.values.byName(m);
                    entry(UiSettingKey.themeMode, fp, m);
                  }
                case 'accentPreset':
                  if (choice(field, fp, UiSchema.accentPresets) case final id?) {
                    if (accent != null && accent.rgb != null) {
                      issue(entries[UiSettingKey.accent]!.pointer, UiMessages.accentBoth, UiIssueKind.ignored);
                    }
                    accent = UiAccent.preset(id);
                    entry(UiSettingKey.accent, fp, id);
                  }
                case 'accent':
                  if (field is! String) {
                    issue(fp, UiMessages.notString);
                  } else if (!_hexColor.hasMatch(field)) {
                    issue(fp, UiMessages.accentFormat);
                  } else if (accent != null && accent.presetId != null) {
                    issue(fp, UiMessages.accentBoth, UiIssueKind.ignored);
                  } else {
                    accent = UiAccent.color(int.parse(field.substring(1), radix: 16));
                    entry(UiSettingKey.accent, fp, accent.toJson());
                  }
                default:
                  issue(fp, UiMessages.unknownKey, UiIssueKind.ignored);
              }
            }
          }
        case 'pet':
          pet = petSpec(value, p);
        case 'shortcuts':
          shortcuts = shortcutList(value, p);
        case 'plugins':
          if (object(value, p) case final map?) {
            unknownKeys(map, p, const ['seats']);
            if (map.containsKey('seats')) seats = seatMap(map['seats'], child(p, 'seats'));
          }
        default:
          issue(p, UiMessages.unknownKey, UiIssueKind.ignored);
      }
    }

    return UiConfig(
      headerActions: headerActions,
      quickActions: quickActions,
      suggestions: suggestions,
      drawerGroups: drawerGroups,
      drawerSort: drawerSort,
      drawerFilter: drawerFilter,
      density: density,
      hide: List.unmodifiable(hide),
      themeMode: themeMode,
      accent: accent,
      pet: pet,
      shortcuts: shortcuts,
      seats: seats,
      entries: Map.unmodifiable(entries),
    );
  }

  // ── actions ──────────────────────────────────────────────────────────────

  UiAction? action(Object? value, String pointer) {
    final map = object(value, pointer);
    if (map == null) return null;
    final tp = child(pointer, 'type');
    if (!map.containsKey('type')) {
      issue(tp, UiMessages.missing('type'));
      return null;
    }
    final type = choice(map['type'], tp, UiSchema.actionTypes, noun: appL10n.shellConfigActionNoun);
    if (type == null) return null;
    switch (type) {
      case 'send':
        unknownKeys(map, pointer, const ['type', 'text']);
        final p = child(pointer, 'text');
        if (!map.containsKey('text')) {
          issue(p, UiMessages.missing('text'));
          return null;
        }
        final raw = map['text'];
        if (raw is! String) {
          issue(p, UiMessages.notString);
          return null;
        }
        final text = raw
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .replaceAll(RegExp('[\u0000-\u0008\u000B-\u001F\u007F-\u009F]'), '')
            .trim();
        if (text.isEmpty) {
          issue(p, UiMessages.empty);
          return null;
        }
        if (text.runes.length > UiSchema.sendTextMax) {
          issue(p, UiMessages.tooLong(UiSchema.sendTextMax));
          return null;
        }
        return UiSendAction(text);
      case 'open':
        unknownKeys(map, pointer, const ['type', 'page']);
        final p = child(pointer, 'page');
        if (!map.containsKey('page')) {
          issue(p, UiMessages.missing('page'));
          return null;
        }
        final page = choice(map['page'], p, UiSchema.pages, noun: appL10n.shellConfigPageNoun);
        return page == null ? null : UiOpenAction(page);
      case 'command':
        unknownKeys(map, pointer, const ['type', 'name', 'args']);
        final p = child(pointer, 'name');
        if (!map.containsKey('name')) {
          issue(p, UiMessages.missing('name'));
          return null;
        }
        final raw = map['name'];
        if (raw is! String) {
          issue(p, UiMessages.notString);
          return null;
        }
        var name = raw.trim();
        if (name.startsWith('/')) {
          name = name.substring(1);
          issue(p, UiMessages.commandSlash, UiIssueKind.adjusted);
        }
        if (!_commandName.hasMatch(name)) {
          issue(p, UiMessages.commandName);
          return null;
        }
        String? args;
        if (map.containsKey('args')) {
          final ap = child(pointer, 'args');
          final rawArgs = map['args'];
          if (rawArgs is! String) {
            issue(ap, UiMessages.notString);
            return null;
          }
          if (rawArgs.contains('\n') || rawArgs.contains('\r')) {
            issue(ap, UiMessages.noNewline);
            return null;
          }
          final trimmed = rawArgs.replaceAll(_controlChars, '').trim();
          if (trimmed.runes.length > UiSchema.commandArgsMax) {
            issue(ap, UiMessages.tooLong(UiSchema.commandArgsMax));
            return null;
          }
          if (trimmed.isNotEmpty) args = trimmed;
        }
        return UiCommandAction(name, args: args);
      case 'link':
        unknownKeys(map, pointer, const ['type', 'url']);
        final p = child(pointer, 'url');
        if (!map.containsKey('url')) {
          issue(p, UiMessages.missing('url'));
          return null;
        }
        final raw = map['url'];
        if (raw is! String) {
          issue(p, UiMessages.notString);
          return null;
        }
        final url = raw.trim();
        if (!url.toLowerCase().startsWith('https://')) {
          issue(p, UiMessages.httpsOnly);
          return null;
        }
        final normalized = 'https://${url.substring(8)}';
        final parsed =
            url.length > UiSchema.urlMax || !_httpsUrl.hasMatch(normalized) || _badPercent.hasMatch(normalized)
            ? null
            : Uri.tryParse(normalized);
        if (parsed == null) {
          issue(p, UiMessages.badUrl);
          return null;
        }
        return UiLinkAction(parsed);
    }
    return null;
  }

  // ── header ───────────────────────────────────────────────────────────────

  List<UiHeaderItem>? header(Object? value, String pointer) {
    final map = object(value, pointer);
    if (map == null) return null;
    unknownKeys(map, pointer, const ['actions']);
    if (!map.containsKey('actions')) return null;
    final p = child(pointer, 'actions');
    final list = array(map['actions'], p);
    if (list == null) return null;
    final out = <UiHeaderItem>[];
    final seen = <String>{};
    var custom = 0;
    for (final (index, item) in list.indexed) {
      final ip = '$p/$index';
      if (item is String) {
        final id = choice(item, ip, UiSchema.headerBuiltins, noun: appL10n.shellConfigButtonNoun);
        if (id == null) continue;
        if (!seen.add(id)) {
          issue(ip, UiMessages.duplicateItem, UiIssueKind.ignored);
          continue;
        }
        out.add(UiHeaderBuiltinItem(UiHeaderBuiltin.values.byName(id)));
      } else if (item is Map<String, Object?>) {
        final button = customButton(item, ip, seen);
        if (button == null) continue;
        if (custom >= UiSchema.headerCustomMax) {
          issue(ip, UiMessages.tooMany(UiSchema.headerCustomMax), UiIssueKind.ignored);
          continue;
        }
        custom++;
        seen.add(button.id);
        out.add(button);
      } else {
        issue(ip, UiMessages.headerItem);
      }
    }
    if (out.isEmpty && list.isNotEmpty) return null;
    entry(UiSettingKey.headerActions, p, [for (final item in out) item.toJson()]);
    return List.unmodifiable(out);
  }

  UiHeaderCustomItem? customButton(Map<String, Object?> map, String pointer, Set<String> taken) {
    unknownKeys(map, pointer, const ['id', 'icon', 'label', 'action']);
    var ok = true;
    String? id;
    final idp = child(pointer, 'id');
    if (!map.containsKey('id')) {
      issue(idp, UiMessages.missing('id'));
      ok = false;
    } else if (map['id'] is! String) {
      issue(idp, UiMessages.notString);
      ok = false;
    } else if (!_headerId.hasMatch(map['id']! as String)) {
      issue(idp, UiMessages.headerId);
      ok = false;
    } else if (taken.contains(map['id']) || UiSchema.headerBuiltins.contains(map['id'])) {
      issue(idp, UiMessages.idTaken);
      ok = false;
    } else {
      id = map['id']! as String;
    }
    String? icon;
    final iconp = child(pointer, 'icon');
    if (!map.containsKey('icon')) {
      issue(iconp, UiMessages.missing('icon'));
      ok = false;
    } else {
      icon = choice(map['icon'], iconp, UiSchema.icons, noun: appL10n.shellConfigIconNoun);
      if (icon == null) ok = false;
    }
    String? label;
    final labelp = child(pointer, 'label');
    if (!map.containsKey('label')) {
      issue(labelp, UiMessages.missing('label'));
      ok = false;
    } else {
      label = this.label(map['label'], labelp, UiSchema.headerLabelMax);
      if (label == null) ok = false;
    }
    UiAction? action;
    final actionp = child(pointer, 'action');
    if (!map.containsKey('action')) {
      issue(actionp, UiMessages.missing('action'));
      ok = false;
    } else {
      action = this.action(map['action'], actionp);
      if (action == null) ok = false;
    }
    if (!ok) return null;
    return UiHeaderCustomItem(id: id!, icon: icon!, label: label!, action: action!);
  }

  // ── composer / empty state ───────────────────────────────────────────────

  List<UiQuickAction>? quickActionList(Object? value, String pointer) {
    final list = array(value, pointer);
    if (list == null) return null;
    final out = <UiQuickAction>[];
    for (final (index, item) in list.indexed) {
      final ip = '$pointer/$index';
      final map = object(item, ip);
      if (map == null) continue;
      unknownKeys(map, ip, const ['label', 'action']);
      final label = requiredLabel(map, ip, 'label', UiSchema.quickLabelMax);
      final action = requiredAction(map, ip);
      if (label == null || action == null) continue;
      if (out.length >= UiSchema.quickActionsMax) {
        issue(ip, UiMessages.tooMany(UiSchema.quickActionsMax), UiIssueKind.ignored);
        continue;
      }
      out.add(UiQuickAction(label: label, action: action));
    }
    if (out.isEmpty) return null;
    entry(UiSettingKey.quickActions, pointer, [for (final q in out) q.toJson()]);
    return List.unmodifiable(out);
  }

  List<UiSuggestion>? suggestionList(Object? value, String pointer) {
    final list = array(value, pointer);
    if (list == null) return null;
    final out = <UiSuggestion>[];
    for (final (index, item) in list.indexed) {
      final ip = '$pointer/$index';
      final map = object(item, ip);
      if (map == null) continue;
      unknownKeys(map, ip, const ['title', 'subtitle', 'action']);
      final title = requiredLabel(map, ip, 'title', UiSchema.suggestionTitleMax);
      String? subtitle;
      var ok = true;
      if (map.containsKey('subtitle')) {
        subtitle = label(map['subtitle'], child(ip, 'subtitle'), UiSchema.suggestionSubtitleMax);
        if (subtitle == null) ok = false;
      }
      final action = requiredAction(map, ip);
      if (title == null || action == null || !ok) continue;
      if (out.length >= UiSchema.suggestionsMax) {
        issue(ip, UiMessages.tooMany(UiSchema.suggestionsMax), UiIssueKind.ignored);
        continue;
      }
      out.add(UiSuggestion(title: title, subtitle: subtitle, action: action));
    }
    if (out.isEmpty) return null;
    entry(UiSettingKey.suggestions, pointer, [for (final s in out) s.toJson()]);
    return List.unmodifiable(out);
  }

  String? requiredLabel(Map<String, Object?> map, String pointer, String key, int max) {
    final p = child(pointer, key);
    if (!map.containsKey(key)) {
      issue(p, UiMessages.missing(key));
      return null;
    }
    return label(map[key], p, max);
  }

  UiAction? requiredAction(Map<String, Object?> map, String pointer) {
    final p = child(pointer, 'action');
    if (!map.containsKey('action')) {
      issue(p, UiMessages.missing('action'));
      return null;
    }
    return action(map['action'], p);
  }

  // ── drawer / hide ────────────────────────────────────────────────────────

  List<UiDrawerGroup>? groupList(Object? value, String pointer) {
    final list = array(value, pointer);
    if (list == null) return null;
    final out = <UiDrawerGroup>[];
    for (final (index, item) in list.indexed) {
      final ip = '$pointer/$index';
      final name = choice(item, ip, UiSchema.drawerGroups);
      if (name == null) continue;
      final group = UiDrawerGroup.values.byName(name);
      if (out.contains(group)) {
        issue(ip, UiMessages.duplicateItem, UiIssueKind.ignored);
        continue;
      }
      out.add(group);
    }
    if (out.isEmpty && list.isNotEmpty) return null;
    entry(UiSettingKey.drawerGroups, pointer, [for (final g in out) g.name]);
    return List.unmodifiable(out);
  }

  List<UiHideItem> hideList(Object? value, String pointer) {
    final list = array(value, pointer);
    if (list == null) return const [];
    final out = <UiHideItem>[];
    for (final (index, item) in list.indexed) {
      final ip = '$pointer/$index';
      final name = choice(item, ip, UiSchema.hideItems);
      if (name == null) continue;
      final hidden = UiHideItem.values.byName(name);
      if (out.contains(hidden)) {
        issue(ip, UiMessages.duplicateItem, UiIssueKind.ignored);
        continue;
      }
      out.add(hidden);
      entry(UiSettingKey.hide(hidden), ip, true);
    }
    return out;
  }

  // ── pet ──────────────────────────────────────────────────────────────────

  UiPetSpec? petSpec(Object? value, String pointer) {
    final map = object(value, pointer);
    if (map == null) return null;
    String? id;
    UiPetPosition? position;
    bool? quiet;
    for (final MapEntry(key: k, value: field) in map.entries) {
      final fp = child(pointer, k);
      switch (k) {
        case 'id':
          if (field is! String) {
            issue(fp, UiMessages.notString);
          } else if (!_petId.hasMatch(field)) {
            issue(fp, UiMessages.petId);
          } else {
            id = field;
          }
        case 'position':
          if (choice(field, fp, UiSchema.petPositions) case final wire?) {
            position = UiPetPosition.values.firstWhere((p) => p.wire == wire);
          }
        case 'quiet':
          if (field is bool) {
            quiet = field;
          } else {
            issue(fp, UiMessages.notBool);
          }
        default:
          issue(fp, UiMessages.unknownKey, UiIssueKind.ignored);
      }
    }
    if (id == null && position == null && quiet == null) return null;
    final spec = UiPetSpec(id: id, position: position, quiet: quiet);
    entry(UiSettingKey.pet, pointer, spec.toJson());
    return spec;
  }

  // ── shortcuts ────────────────────────────────────────────────────────────

  List<UiShortcut>? shortcutList(Object? value, String pointer) {
    final list = array(value, pointer);
    if (list == null) return null;
    final out = <UiShortcut>[];
    final where = <String, String>{};
    for (final (index, item) in list.indexed) {
      final ip = '$pointer/$index';
      final map = object(item, ip);
      if (map == null) continue;
      unknownKeys(map, ip, const ['keys', 'action']);
      final kp = child(ip, 'keys');
      String? keys;
      if (!map.containsKey('keys')) {
        issue(kp, UiMessages.missing('keys'));
      } else {
        keys = shortcutKeys(map['keys'], kp);
        if (keys != null && where.containsKey(keys)) {
          issue(kp, UiMessages.duplicateShortcut(where[keys]!));
          keys = null;
        }
      }
      final action = requiredAction(map, ip);
      if (keys == null || action == null) continue;
      if (out.length >= UiSchema.shortcutsMax) {
        issue(ip, UiMessages.tooMany(UiSchema.shortcutsMax), UiIssueKind.ignored);
        continue;
      }
      where[keys] = ip;
      out.add(UiShortcut(keys: keys, action: action));
    }
    if (out.isEmpty) return null;
    entry(UiSettingKey.shortcuts, pointer, [for (final s in out) s.toJson()]);
    return List.unmodifiable(out);
  }

  /// `Ctrl + Shift + N` → `ctrl+shift+n`; null (with an issue) when it is
  /// not a usable combination.
  String? shortcutKeys(Object? value, String pointer) {
    if (value is! String) {
      issue(pointer, UiMessages.notString);
      return null;
    }
    final parts = value.toLowerCase().split('+').map((p) => p.trim()).toList();
    if (parts.any((p) => p.isEmpty)) {
      issue(pointer, UiMessages.keysFormat);
      return null;
    }
    if (parts.any(UiSchema.systemModifiers.contains)) {
      issue(pointer, UiMessages.systemKey);
      return null;
    }
    final key = parts.last;
    final mods = parts.sublist(0, parts.length - 1);
    final modSet = mods.toSet();
    if (!UiSchema.shortcutKeys.contains(key) ||
        modSet.length != mods.length ||
        !mods.every(const ['ctrl', 'alt', 'shift'].contains)) {
      issue(pointer, UiMessages.keysFormat);
      return null;
    }
    final functionKey = RegExp(r'^f([1-9]|1[0-2])$').hasMatch(key);
    if (!functionKey && !modSet.contains('ctrl') && !modSet.contains('alt')) {
      issue(pointer, UiMessages.needModifier);
      return null;
    }
    final canonical = [
      for (final m in const ['ctrl', 'alt', 'shift'])
        if (modSet.contains(m)) m,
      key,
    ].join('+');
    if (UiSchema.reservedShortcuts.contains(canonical)) {
      issue(pointer, UiMessages.reserved);
      return null;
    }
    return canonical;
  }

  // ── plugins ──────────────────────────────────────────────────────────────

  Map<String, Map<String, UiSeatMode>> seatMap(Object? value, String pointer) {
    final map = object(value, pointer);
    if (map == null) return const {};
    final out = <String, Map<String, UiSeatMode>>{};
    for (final MapEntry(key: slot, value: packages) in map.entries) {
      final sp = child(pointer, slot);
      if (!_slot.hasMatch(slot)) {
        issue(sp, UiMessages.slotName);
        continue;
      }
      final info = slotInfo(slot);
      if (info == null) {
        issue(sp, UiMessages.unknownSlot, UiIssueKind.adjusted);
      } else if (!info.seatable) {
        issue(sp, UiMessages.unseatableSlot, UiIssueKind.ignored);
        continue;
      }
      final inner = object(packages, sp);
      if (inner == null) continue;
      for (final MapEntry(key: package, value: mode) in inner.entries) {
        final pp = child(sp, package);
        if (package.length > 214 || !_package.hasMatch(package)) {
          issue(pp, UiMessages.packageName);
          continue;
        }
        final name = choice(mode, pp, UiSchema.seatModes);
        if (name == null) continue;
        (out[slot] ??= {})[package] = UiSeatMode.values.byName(name);
        entry(UiSettingKey.seat(slot, package), pp, name);
      }
    }
    return {for (final MapEntry(:key, :value) in out.entries) key: Map.unmodifiable(value)};
  }
}
