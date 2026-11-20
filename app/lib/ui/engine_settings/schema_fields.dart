// How an engine settings field reads: which control a schemastery node gets,
// its Chinese label, units, value text and client-side validation. Pure (no
// widgets) so the form engine's decisions are unit-tested on their own.

import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart' show LocalizedText;

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';

/// The control a field gets.
enum FieldKind {
  /// boolean → switch.
  toggle,

  /// Fixed tuple positions or boolean arrays.
  sequence,

  /// Unconstrained JSON value.
  jsonValue,

  /// union of constants → segmented capsule (≤ 3) or a picker sheet.
  choice,

  /// number → stepper / slider sheet with units.
  number,

  /// Named numeric bit mask → multiple selection.
  bitset,

  /// string → text sheet.
  text,

  /// `role('secret')` string → masked field, saved through credentials.
  secret,

  /// array of strings / numbers / constants → item list sheet.
  list,

  /// array of objects → item list whose items open a small form.
  objectList,

  /// dict of strings / numbers / booleans → key-value sheet.
  dict,

  /// object → its own group of fields.
  group,

  /// Anything else (union of objects, tuples, `any`, collections holding
  /// secrets, objects with no declared fields): shown, not edited.
  readOnly,

  /// Hidden, `role('credential-ref')` plumbing, or constant markers.
  hidden,
}

bool _primitive(SchemaNode node) {
  final n = node.effective;
  return n.type == 'string' || n.type == 'number' || n.enumValues != null;
}

bool _containsSecret(SchemaNode source, [Set<SchemaNode>? ancestors]) {
  final node = source.effective;
  final seen = ancestors ?? <SchemaNode>{};
  if (seen.contains(node) || seen.length >= 32) return true;
  if (source.isSecret || node.isSecret) return true;
  final next = {...seen, node};
  return [
    ...node.dict.values,
    ...node.list,
    if (node.inner != null) node.inner!,
  ].any((child) => _containsSecret(child, next));
}

/// The node a field's control edits: what wrappers resolve to, the string
/// input of a built-in date() / regExp(), and the value of an optional field
/// ([schemaValueOf]). The field's default and description stay on [source].
SchemaNode valueNodeOf(SchemaNode source) => textInputNodeOf(schemaValueOf(source));

/// The control for [node].
FieldKind kindOf(SchemaNode node) {
  final effective = node.effective;
  if (effective.meta.hidden || node.meta.hidden || effective.isCredentialRef) return FieldKind.hidden;
  if (effective.isSecret || node.isSecret) return FieldKind.secret;
  final n = valueNodeOf(node);
  switch (n.type) {
    case 'boolean':
      return FieldKind.toggle;
    case 'number':
      return FieldKind.number;
    case 'bitset':
      return n.bits.isEmpty ? FieldKind.readOnly : FieldKind.bitset;
    case 'string':
      return FieldKind.text;
    case 'const':
      return FieldKind.hidden;
    case 'any':
      return FieldKind.jsonValue;
    case 'tuple':
      return _containsSecret(n) ? FieldKind.readOnly : FieldKind.sequence;
    case 'union':
      final values = n.enumValues;
      if (values != null) return values.length > 1 ? FieldKind.choice : FieldKind.hidden;
      final members = n.members;
      if (members.isNotEmpty && members.every((m) => m.type == 'string' || m.type == 'const')) return FieldKind.text;
      if (members.isNotEmpty && members.every((m) => m.type == 'number' || m.type == 'const')) {
        return members.any((m) => m.type == 'const') ? FieldKind.readOnly : FieldKind.number;
      }
      return FieldKind.readOnly;
    case 'object':
    case 'intersect':
      return n.fields == null ? FieldKind.readOnly : FieldKind.group;
    case 'array':
      final inner = n.inner;
      // Item editors show and write values in the clear; the Host never
      // returns a secret and refuses writes over one.
      if (inner == null || _containsSecret(inner)) return FieldKind.readOnly;
      if (inner.effective.type == 'boolean') return FieldKind.sequence;
      if (_primitive(inner)) return FieldKind.list;
      // `array(object({}))` declares nothing to fill in: its items are opaque.
      if (inner.fields?.isNotEmpty ?? false) return FieldKind.objectList;
      return FieldKind.readOnly;
    case 'dict':
      final inner = n.inner?.effective;
      if (inner == null || _containsSecret(n.inner!)) return FieldKind.readOnly;
      if (inner.type == 'boolean' || _primitive(inner)) return FieldKind.dict;
      return FieldKind.readOnly;
  }
  return FieldKind.readOnly;
}

// ── Units ────────────────────────────────────────────────────────────────────

/// How a number is shown and typed.
enum FieldUnit {
  plain,

  /// Stored in milliseconds, typed in seconds.
  milliseconds,
  seconds,
  bytes,
  tokens,

  /// 0–1, shown as a percentage.
  ratio,
}

/// A unit guessed from the key (`timeoutMs`, `maxOutputBytes`) or the role.
FieldUnit unitFor(String key, SchemaNode node) {
  final meta = node.effective.meta;
  if (meta.role == 'slider' && meta.max == 1 && (meta.min ?? 0) == 0) return FieldUnit.ratio;
  if (key.endsWith('Ms')) return FieldUnit.milliseconds;
  if (key.endsWith('Seconds') || key.endsWith('Sec')) return FieldUnit.seconds;
  if (key.endsWith('Bytes')) return FieldUnit.bytes;
  if (key.endsWith('Tokens')) return FieldUnit.tokens;
  return FieldUnit.plain;
}

/// The unit typed into the number sheet.
String? editUnitLabel(FieldUnit unit) => switch (unit) {
  FieldUnit.milliseconds || FieldUnit.seconds => appL10n.engineFieldSecondsUnit,
  FieldUnit.bytes => appL10n.engineFieldBytesUnit,
  FieldUnit.ratio => '%',
  _ => null,
};

/// Stored value → the number typed in the sheet.
num toEditValue(num stored, FieldUnit unit) => switch (unit) {
  FieldUnit.milliseconds => stored / 1000,
  FieldUnit.ratio => stored * 100,
  _ => stored,
};

/// Typed number → stored value.
num fromEditValue(num typed, FieldUnit unit) => switch (unit) {
  FieldUnit.milliseconds => _roundedMilliseconds(typed),
  FieldUnit.ratio => typed / 100,
  _ => typed,
};

num _roundedMilliseconds(num typed) {
  final scaled = typed * 1000;
  return scaled.isFinite ? scaled.roundToDouble() : scaled;
}

/// Step of the stepper in typed units.
num editStep(SchemaMeta meta, FieldUnit unit) {
  return switch (unit) {
    FieldUnit.milliseconds => 1,
    FieldUnit.ratio => 1,
    FieldUnit.bytes => 1024,
    _ => meta.step != null && meta.step! > 0 ? meta.step! : 1,
  };
}

String _trim(num n, {int digits = 3}) {
  if (n == n.roundToDouble()) return n.round().toString();
  var text = n.toStringAsFixed(digits);
  text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return text;
}

/// `65536` → `64 KB`, `67108864` → `64 MB`, `64000` → `64 KB`.
String formatBytes(num bytes) {
  final b = bytes.round();
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  if (b >= gib && b % gib == 0) return '${b ~/ gib} GB';
  if (b >= mib && b % mib == 0) return '${b ~/ mib} MB';
  if (b >= 1000000 && b % 1000000 == 0) return '${b ~/ 1000000} MB';
  if (b >= 1024 && b % 1024 == 0) return '${b ~/ 1024} KB';
  if (b >= 1000 && b % 1000 == 0) return '${b ~/ 1000} KB';
  if (b >= mib) return '${_trim(b / mib, digits: 1)} MB';
  if (b >= 1024) return '${_trim(b / 1024, digits: 1)} KB';
  return appL10n.engineFieldByteCount(b);
}

/// `60000` ms → `60 秒`, `90` s → `1.5 分钟`, `3600` s → `1 小时`.
String formatSeconds(num seconds) {
  if (seconds >= 3600 && seconds % 3600 == 0) return appL10n.engineFieldHours(_trim(seconds / 3600));
  if (seconds >= 60 && seconds % 60 == 0) return appL10n.engineFieldMinutes(_trim(seconds / 60));
  return appL10n.engineFieldSeconds(_trim(seconds));
}

/// `256000` → `256K`, `262144` → `256K`, `1000000` → `1M`.
String formatTokenCount(num value) {
  final v = value.round();
  if (v >= 1000000 && v % 1000000 == 0) return '${v ~/ 1000000}M';
  if (v >= 1048576 && v % 1048576 == 0) return '${v ~/ 1048576}M';
  if (v >= 1000 && v % 1000 == 0) return '${v ~/ 1000}K';
  if (v >= 1024 && v % 1024 == 0) return '${v ~/ 1024}K';
  return '$v';
}

/// A stored number in words.
String formatNumber(num value, FieldUnit unit) => switch (unit) {
  FieldUnit.milliseconds => value < 1000 ? appL10n.engineFieldMilliseconds(_trim(value)) : formatSeconds(value / 1000),
  FieldUnit.seconds => formatSeconds(value),
  FieldUnit.bytes => formatBytes(value),
  FieldUnit.tokens => formatTokenCount(value),
  FieldUnit.ratio => '${_trim(value * 100, digits: 1)}%',
  FieldUnit.plain => _trim(value),
};

// ── Bounds and validation ────────────────────────────────────────────────────

/// A bound worth showing: schemastery spells "no limit" as
/// `Number.MAX_SAFE_INTEGER` and "above zero" as `Number.MIN_VALUE`.
num? meaningfulMax(SchemaMeta meta) => meta.max == null || meta.max! >= 9e15 ? null : meta.max;

num? meaningfulMin(SchemaMeta meta) => meta.min == null || meta.min! <= -9e15 ? null : meta.min;

bool isInteger(SchemaMeta meta) =>
    meta.step != null &&
    meta.step != 0 &&
    meta.step == meta.step!.roundToDouble() &&
    (meta.min ?? 0) == (meta.min ?? 0).roundToDouble();

/// `1–50`, `≥ 1`, `≤ 10`; null without bounds. In typed units.
String? rangeText(SchemaMeta meta, FieldUnit unit) {
  final min = meaningfulMin(meta);
  final max = meaningfulMax(meta);
  String show(num n) => _trim(toEditValue(n, unit));
  if (min != null && min > 0 && min < 1e-300) {
    return max == null ? appL10n.engineFieldGreaterThanZero : appL10n.engineFieldPositiveMax(show(max));
  }
  if (min != null && max != null) return '${show(min)}–${show(max)}';
  if (min != null) return appL10n.engineFieldMin(show(min));
  if (max != null) return appL10n.engineFieldMaxBound(show(max));
  return null;
}

String _numberRangeError(num min, num max, FieldUnit unit) {
  final upper = _trim(toEditValue(max, unit));
  if (min > 0 && min < 1e-300) return appL10n.engineFieldEnterPositiveRange(upper);
  return appL10n.engineFieldEnterBoundedRange(_trim(toEditValue(min, unit)), upper);
}

// Match schemastery 3.18.5's decimalShift/isMultipleOf, including its strict
// floating-point remainder for exponential steps. Dividing by a tiny step
// can overflow; a tolerance on the quotient also admits values it rejects.
num _decimalShift(num value, int digits) {
  final text = value.toString();
  if (text.contains('e') || !text.contains('.')) return value * math.pow(10, digits);
  final dot = text.indexOf('.');
  final integer = text.substring(0, dot);
  final fraction = text.substring(dot + 1);
  if (fraction.length <= digits) return num.parse(integer + fraction.padRight(digits, '0'));
  return num.parse('$integer${fraction.substring(0, digits)}.${fraction.substring(digits)}');
}

bool _schemaMultiple(num value, num min, num step) {
  step = step.abs();
  final text = step.toString().replaceFirst(RegExp(r'\.0$'), '');
  if (!RegExp(r'^\d+\.\d+$').hasMatch(text)) return (value - min) % step == 0;
  final digits = text.length - text.indexOf('.') - 1;
  final distance = (_decimalShift(value, digits) - _decimalShift(min, digits)).abs();
  return distance % _decimalShift(step, digits) == 0;
}

/// Why a typed number (in typed units) is refused; null when it is fine.
String? validateNumber(String text, SchemaMeta meta, FieldUnit unit) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final typed = num.tryParse(trimmed);
  if (typed == null || typed.isNaN || typed.isInfinite) return appL10n.engineFieldEnterNumeric;
  final stored = fromEditValue(typed, unit);
  if (!stored.isFinite) return appL10n.engineFieldEnterNumeric;
  final min = meaningfulMin(meta);
  final max = meaningfulMax(meta);
  final integer = isInteger(meta);
  if (integer && unit != FieldUnit.milliseconds && stored != stored.roundToDouble()) {
    return appL10n.engineFieldEnterInteger;
  }
  final range = rangeText(meta, unit);
  if (min != null && (stored < min || (min > 0 && min < 1e-300 && stored <= 0))) {
    return range != null && max != null
        ? _numberRangeError(min, max, unit)
        : appL10n.engineFieldBelowMin(_trim(toEditValue(min, unit)));
  }
  if (max != null && stored > max) {
    return range != null && min != null
        ? _numberRangeError(min, max, unit)
        : appL10n.engineFieldAboveMax(_trim(toEditValue(max, unit)));
  }
  final step = meta.step;
  // Schemastery checks the stored value, regardless of display units, and
  // accepts negative steps by taking their absolute value.
  if (step != null && step != 0) {
    final base = min ?? 0;
    if (!_schemaMultiple(stored, base, step)) return appL10n.engineFieldMultiple(_trim(step));
  }
  return null;
}

/// A JavaScript regular expression in Dart terms; null when it does not
/// compile here (the engine still checks it).
RegExp? jsRegExp(String source, String? flags) {
  final f = flags ?? '';
  try {
    return RegExp(
      source,
      caseSensitive: !f.contains('i'),
      multiLine: f.contains('m'),
      dotAll: f.contains('s'),
      unicode: f.contains('u') || f.contains('v'),
    );
  } on FormatException {
    return null;
  }
}

/// Why a typed string is refused; null when it is fine. Empty means "back
/// to the default" and is always fine.
String? validateText(String text, SchemaMeta meta, {String? patternMessage}) {
  if (text.isEmpty) return null;
  final min = meaningfulMin(meta);
  final max = meaningfulMax(meta);
  // JavaScript String.length (used by schemastery) counts UTF-16 units.
  final length = text.length;
  if (min != null && length < min) {
    return min == min.roundToDouble()
        ? appL10n.engineFieldMinCharacters(min.toInt())
        : appL10n.engineFieldMinCharactersDecimal(_trim(min));
  }
  if (max != null && length > max) {
    return max == max.roundToDouble()
        ? appL10n.engineFieldMaxCharacters(max.toInt())
        : appL10n.engineFieldMaxCharactersDecimal(_trim(max));
  }
  if (meta.pattern case final source?) {
    final re = jsRegExp(source, meta.patternFlags);
    if (re != null && !re.hasMatch(text)) return patternMessage ?? appL10n.engineFieldInvalidFormat;
  }
  return null;
}

// ── Copy ─────────────────────────────────────────────────────────────────────

/// Counted units whose English labels depend on the value.
enum FieldCountUnit { layers, items, uses, results }

/// What a page says about one field; the schema fills in the rest.
class FieldCopy {
  const FieldCopy({
    this.label,
    this.hint,
    this.choices = const {},
    this.aliases = const {},
    this.unit,
    this.placeholder,
    this.fallback,
    this.patternMessage,
    this.itemLabel,
    this.suffix,
    this.countUnit,
    this.shown = const {},
  });

  final String? label;

  /// The row's second line: what it is, ≤ 16 characters.
  final String? hint;

  /// Choice labels in the order offered; when set, only these are offered.
  final Map<Object?, String> choices;

  /// Saved values read as another choice (legacy spellings).
  final Map<Object?, Object?> aliases;
  final FieldUnit? unit;
  final String? placeholder;

  /// What the field means when nothing is stored and the schema has no
  /// default (the client's own default).
  final Object? fallback;

  /// The field-specific "format" error.
  final String? patternMessage;

  /// One item of a list (「索引源」 → 「地址」).
  final String? itemLabel;

  /// Counted unit of a plain number (「层」「个」「次」).
  final String? suffix;
  final FieldCountUnit? countUnit;

  /// How a stored text reads on its row (`auto` → 「跟随界面语言」).
  final Map<String, String> shown;
}

/// Built-in date()/regExp() serialize as a union of a JS instance and a
/// preserving string transform. Edit the declared string input, never run
/// the serialized JavaScript callback in the app.
SchemaNode textInputNodeOf(SchemaNode source) {
  final node = source.effective;
  if (node.type != 'union' || node.list.length != 2) return node;
  final inputs = node.members;
  if (inputs.where((member) => member.type == 'is').length != 1) return node;
  return inputs
          .where(
            (member) => member.type == 'string' && (member.meta.role == 'datetime' || member.meta.role == 'regexp'),
          )
          .firstOrNull ??
      node;
}

/// A stored number in words, with the field's counted unit.
String formatFieldNumber(num value, FieldUnit unit, FieldCopy copy) {
  final text = formatNumber(value, unit);
  if (copy.suffix == null || unit != FieldUnit.plain) return text;
  if (value == value.roundToDouble()) {
    final count = value.toInt();
    return switch (copy.countUnit) {
      FieldCountUnit.layers => appL10n.engineLayerCount(count),
      FieldCountUnit.items => appL10n.engineFieldItemCount(count),
      FieldCountUnit.uses => appL10n.engineFieldUseCount(count),
      FieldCountUnit.results => appL10n.engineFieldResultCount(count),
      null => '$text ${copy.suffix}',
    };
  }
  return '$text ${copy.suffix}';
}

/// Labels of well-known keys, for plugins whose schemas carry none.
Map<String, String> get commonKeyLabels => <String, String>{
  'enabled': appL10n.commonEnable,
  'baseURL': appL10n.engineFieldBaseUrl,
  'baseUrl': appL10n.engineFieldBaseUrl,
  'endpoint': appL10n.engineFieldBaseUrl,
  'url': appL10n.engineFieldAddress,
  'apiKey': 'API Key',
  'token': appL10n.engineFieldToken,
  'model': appL10n.engineModelTitle,
  'provider': appL10n.engineFieldService,
  'maxTokens': appL10n.engineFieldMaxTokens,
  'timeoutMs': appL10n.engineFieldTimeout,
  'timeout': appL10n.engineFieldTimeout,
  'apiVersion': appL10n.engineFieldApiVersion,
  'count': appL10n.engineFieldQuantity,
  'maxUses': appL10n.engineFieldMaxUses,
  'maxRetries': appL10n.engineFieldMaxRetries,
  'concurrency': appL10n.engineFieldConcurrency,
  'targetLanguage': appL10n.engineTranslationTargetLanguage,
  'language': appL10n.engineLanguageTitle,
  'indexes': appL10n.enginePluginIndexSources,
  'interval': appL10n.engineFieldInterval,
  'prompt': appL10n.engineFieldPrompt,
  'systemPrompt': appL10n.engineFieldSystemPrompt,
  'temperature': appL10n.engineFieldTemperature,
  'debug': appL10n.engineFieldDebugMode,
  'verbose': appL10n.engineFieldVerboseLogs,
  'path': appL10n.engineFieldPath,
  'cwd': appL10n.engineFieldCwd,
  'command': appL10n.engineFieldCommand,
  'args': appL10n.engineFieldArguments,
  'env': appL10n.engineFieldEnvironment,
  'headers': appL10n.engineFieldHeaders,
  'proxy': appL10n.engineFieldProxy,
};

/// Labels of well-known constants.
Map<Object?, String> get commonValueLabels => <Object?, String>{
  'auto': appL10n.engineFieldAuto,
  'enabled': appL10n.engineFieldEnabled,
  'disabled': appL10n.commonClose,
  'on': appL10n.engineFieldOn,
  'off': appL10n.engineFieldOff,
  'low': appL10n.engineFieldLow,
  'medium': appL10n.engineFieldMedium,
  'high': appL10n.engineFieldHigh,
  'max': appL10n.engineFieldMax,
  'none': appL10n.engineFieldNone,
  'light': appL10n.commonLight,
  'dark': appL10n.commonDark,
  'system': appL10n.commonFollowSystem,
  'compact': appL10n.engineFieldCompact,
  'standard': appL10n.engineFieldStandard,
  'detailed': appL10n.engineFieldDetailed,
};

/// `maxOutputBytes` → `Max output bytes`; `api_key` → `Api key`.
String humanizeKey(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .trim();
  if (spaced.isEmpty) return key;
  final words = spaced.split(RegExp(r'\s+'));
  return [
    for (final (i, w) in words.indexed)
      if (w.length > 1 && w == w.toUpperCase())
        w
      else if (i == 0)
        '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}'
      else
        w.toLowerCase(),
  ].join(' ');
}

/// A description's Markdown as plain text, for a one-line title or hint:
/// links keep their text, `**strong**`, `__strong__` and `` `code` `` lose
/// their marks, and so does a leading heading or list marker. 字段说明 shows
/// the Markdown itself.
String plainSchemaText(String text) => text
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)\s]*\)'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'(\*\*|__)(.+?)\1'), (m) => m[2]!)
    .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1]!)
    .replaceFirst(RegExp(r'^\s*(#{1,6}|[-*+]|\d+\.)\s+'), '')
    .trim();

/// [text] in the UI language, as plain text (see [LocalizedText.resolve]:
/// Chinese, then English, then whatever there is).
String? _plainText(LocalizedText? text) {
  final resolved = text?.resolve(AppLocale.current.languageCode);
  return resolved == null ? null : plainSchemaText(resolved.trim());
}

/// The description on the field, else on what it wraps or holds.
String? _plainDescription(SchemaNode node) =>
    _plainText(node.meta.description ?? node.effective.meta.description ?? valueNodeOf(node).meta.description);

/// The longest description that reads as a title.
const _titleRunes = 18;

final _han = RegExp(r'[\u3400-\u9fff]');

bool _fitsTitle(String text) => text.runes.length <= _titleRunes && !text.contains('\n');

String _firstSentence(String text) {
  // l10n:keep schema sentence boundary pattern
  final first = text.split(RegExp(r'(?<=[。.!?！？])\s*|\n')).first.trim();
  return first.runes.length > 40 ? '${String.fromCharCodes(first.runes.take(39))}…' : first;
}

/// A long description that opens with a name: Chinese text before an
/// opening bracket, a colon, a semicolon, a line break or the end of its
/// first sentence, and the rest that explains it (「兼容接口返回格式（按模型目录；
/// GPT Image 留空）」 → 「兼容接口返回格式」 / 「按模型目录；GPT Image 留空」).
/// Null when that text is not 2–18 characters of Chinese: an English clause
/// seldom reads as a name, and a comma usually ends a condition, not a name.
({String title, String rest})? leadingPhrase(String text) {
  // l10n:keep schema punctuation pattern
  final stop = RegExp(r'[（(：；;。！？\n]|:(?!//)').firstMatch(text);
  if (stop == null) return null;
  final title = text.substring(0, stop.start).trim();
  final length = title.runes.length;
  if (length < 2 || length > _titleRunes || !_han.hasMatch(title)) return null;
  // l10n:keep schema punctuation pattern
  String trimmed(String s) => s.replaceFirst(RegExp(r'^[\s，,。.；;：:、]+'), '').trim();
  var rest = text.substring(stop.end);
  final close = switch (stop[0]) {
    // l10n:keep schema punctuation pattern
    '（' => '）',
    '(' => ')',
    _ => null,
  };
  final end = close == null ? -1 : rest.indexOf(close);
  if (end >= 0) {
    // What the brackets hold, then whatever follows them.
    final inside = rest.substring(0, end).trim();
    final after = trimmed(rest.substring(end + 1));
    // l10n:keep schema punctuation joining a Chinese phrase
    rest = after.isEmpty ? inside : (inside.isEmpty ? after : '$inside，$after');
  }
  return (title: title, rest: trimmed(rest));
}

/// What a field's own description gives its row: a title when it is short
/// or opens with a name ([leadingPhrase]), and the line under the title.
({String? title, String? hint}) _describedText(SchemaNode node) {
  final text = _plainDescription(node);
  if (text == null || text.isEmpty) return (title: null, hint: null);
  // l10n:keep schema punctuation pattern
  if (_fitsTitle(text)) return (title: text.replaceFirst(RegExp(r'[。.]$'), ''), hint: null);
  if (leadingPhrase(text) case (:final title, :final rest)) {
    // The rest can open a Markdown list of its own.
    final more = plainSchemaText(rest);
    return (title: title, hint: more.isEmpty ? null : _firstSentence(more));
  }
  return (title: null, hint: _firstSentence(text));
}

/// The field's title: page copy, the schema's description when it is short
/// or opens with a name (in the UI language when it has one, else English),
/// a known key, then the key in words.
String labelFor(String key, SchemaNode node, FieldCopy copy) {
  if (copy.label case final label?) return label;
  return _describedText(node).title ?? commonKeyLabels[key] ?? humanizeKey(key);
}

/// The field's second line: page copy, else what a longer schema description
/// adds to the title.
String? hintFor(SchemaNode node, FieldCopy copy) {
  if (copy.hint case final hint?) return hint;
  if (copy.label == null) return _describedText(node).hint;
  // The page names the field; a description longer than a title explains it.
  final text = _plainDescription(node);
  return text == null || text.isEmpty || _fitsTitle(text) ? null : _firstSentence(text);
}

/// The choices a choice field offers, in order, with labels.
List<(Object?, String)> choicesFor(SchemaNode node, FieldCopy copy) {
  if (copy.choices.isNotEmpty) return [for (final MapEntry(:key, :value) in copy.choices.entries) (key, value)];
  return [for (final v in node.effective.enumValues ?? const []) (v, valueLabel(v, copy, node: node))];
}

/// The name an option of [node] gives itself: `const(v).description(…)`
/// (schemastery's way to label a choice), when it reads as a title.
String? _optionLabel(SchemaNode? node, Object? value) {
  if (node == null) return null;
  final n = node.effective;
  final options = n.type == 'const' ? [n] : [if (n.type == 'union') ...n.list];
  for (final option in options) {
    final constant = option.effective;
    if (constant.type != 'const' || !jsonEquals(constant.value, value)) continue;
    final text = _plainText(option.meta.description ?? constant.meta.description);
    if (text == null || text.isEmpty) return null;
    if (_fitsTitle(text)) return text;
    return leadingPhrase(text)?.title;
  }
  return null;
}

/// A constant in words: page copy, the option's own description in [node],
/// a well-known value, then the value itself (nothing and the empty string
/// read 「未设置」).
String valueLabel(Object? value, FieldCopy copy, {SchemaNode? node}) {
  final v = copy.aliases[value] ?? value;
  return copy.choices[v] ??
      _optionLabel(node, v) ??
      commonValueLabels[v] ??
      (v == null || v == '' ? appL10n.commonNotSet : '$v');
}

/// The choice a stored value reads as (aliases applied).
Object? choiceValue(Object? value, FieldCopy copy) => copy.aliases[value] ?? value;
