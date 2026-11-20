/// Pure protocol for one director result. Transport, catalogue authorization,
/// persistence and eventual event consumers belong to the owning engine.
library;

import 'dart:convert';

/// Internal shared cadence parsing. The native caller retains its admission,
/// counter, tick write and issue-publication timing.
({int every, bool invalid}) directorEvery({
  Map<String, Object?> settings = const {},
  Map<String, Object?> card = const {},
}) {
  final raw = settings.containsKey('every') ? settings['every'] : card['every'];
  final present = settings.containsKey('every') || card.containsKey('every');
  final valid = raw is int && raw >= 1 && raw <= 1000;
  return (every: valid ? raw : 1, invalid: present && !valid);
}

/// The director plans the next turn; it does not impersonate the player or
/// obtain permission to execute a proposed event by naming it in this tool.
const directorSystemPrompt = '''你是后台剧情导演，只提供下一回合的结构化规划。
只调用一次 direct 工具，不输出普通正文，不写任何角色台词，不续写主回复。
不要替当前用户/persona 描述已经做出的动作、说过的话、选择或决定；beat 只说明局势、环境和其他角色可发展的方向，给用户保留行动空间。
notes 是私有规划和剧透笔记，不是已经写入隐藏状态的事实；不得声称笔记自动修改了状态。
beat 是下一回合提示要点，不要复制 notes 中不应公开的秘密。
prefetch 只能选择提供的目录中的精确引用，不猜测、改写或补造 bookId、uid、memory id；没有需要时返回空数组。
suggestions 必须恰好三项，每项提供非空 text 和对应 risk，供用户选择，不表示用户已采取该行动。
events 只提出待处理建议，每项 name 标识提案，data 用文本说明；它们不是已执行事件，不是任意 JSON、路径或代码执行接口。
五个字段 notes、beat、prefetch、suggestions、events 都必须返回；notes、beat、risk、data 可为空字符串，prefetch 和 events 可为空数组，suggestions 始终为三项。
保持简洁：prefetch 最多64项，events最多32项。notes、beat、建议和事件文本都按原文保存，不要依赖宏或命令被执行。''';

/// Returns a fresh complete function envelope. Generic providers can request
/// [strict] false to omit the provider-specific strict flag; local validation
/// remains identical. Count and byte constraints deliberately stay local.
Map<String, Object?> directToolDefinition({bool strict = true}) => {
  'type': 'function',
  'function': <String, Object?>{
    'name': 'direct',
    'description': '提交一次后台导演规划；五字段齐全，恰好三条带风险的建议，事件仅为待处理提案。',
    if (strict) 'strict': true,
    'parameters': _objectSchema({
      'notes': _stringSchema('私有规划笔记，不自动修改任何状态。'),
      'beat': _stringSchema('下一回合要点，不写台词，不替用户行动或决定。'),
      'prefetch': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'anyOf': <Object?>[
            _objectSchema({
              'kind': <String, Object?>{
                'type': 'string',
                'enum': <String>['worldInfo'],
              },
              'bookId': _stringSchema('目录给出的精确本地世界书 id。'),
              'uid': _stringSchema('目录给出的精确条目 uid。'),
            }),
            _objectSchema({
              'kind': <String, Object?>{
                'type': 'string',
                'enum': <String>['memory'],
              },
              'id': _stringSchema('目录给出的精确记忆 id。'),
            }),
          ],
        },
      },
      'suggestions': <String, Object?>{
        'type': 'array',
        'description': '恰好三项，提出可选行动及风险，不宣称用户已经执行。',
        'items': _objectSchema({'text': _stringSchema('非空建议文字。'), 'risk': _stringSchema('该建议的风险；没有补充时可为空。')}),
      },
      'events': <String, Object?>{
        'type': 'array',
        'items': _objectSchema({'name': _stringSchema('非空提案名称。'), 'data': _stringSchema('提案说明文本，不是已执行动作或任意 JSON/代码。')}),
      },
    }),
  },
};

Map<String, Object?> _stringSchema(String description) => {'type': 'string', 'description': description};
Map<String, Object?> _objectSchema(Map<String, Object?> properties) => {
  'type': 'object',
  'properties': properties,
  'required': properties.keys.toList(),
  'additionalProperties': false,
};

const _invalidDirectOutput = 'Invalid director output.';
const _rootFields = {'notes', 'beat', 'prefetch', 'suggestions', 'events'};
const _worldInfoFields = {'kind', 'bookId', 'uid'};
const _memoryFields = {'kind', 'id'};
const _suggestionFields = {'text', 'risk'};
const _eventFields = {'name', 'data'};

/// A validated, detached result. The private JSON encoding is the sole stored
/// collection representation; callers receive a fresh deep copy on every read.
class DirectOutput {
  DirectOutput._(this._encoded, this._issuesEncoded, this._notes, this._beat);

  factory DirectOutput.parse(Map<String, Object?> raw, {String personaName = ''}) {
    final root = _requireObject(raw, _rootFields);
    final notes = _requireString(root['notes'], 64 * 1024);
    final beat = _requireString(root['beat'], 16 * 1024);
    final prefetch = _requireList(root['prefetch'], 64);
    for (final value in prefetch) {
      if (value is! Map<Object?, Object?>) _invalid();
      switch (value['kind']) {
        case 'worldInfo':
          final reference = _requireObject(value, _worldInfoFields);
          _requireString(reference['bookId'], 1024, nonempty: true);
          _requireString(reference['uid'], 1024, nonempty: true);
        case 'memory':
          final memoryReference = _requireObject(value, _memoryFields);
          _requireString(memoryReference['id'], 1024, nonempty: true);
        default:
          _invalid();
      }
    }
    final suggestions = _requireList(root['suggestions'], 3);
    if (suggestions.length != 3) _invalid();
    for (final value in suggestions) {
      final suggestion = _requireObject(value, _suggestionFields);
      _requireString(suggestion['text'], 4 * 1024, nonempty: true);
      _requireString(suggestion['risk'], 1024);
    }
    final events = _requireList(root['events'], 32);
    for (final value in events) {
      final event = _requireObject(value, _eventFields);
      _requireString(event['name'], 1024, nonempty: true);
      _requireString(event['data'], 16 * 1024);
    }
    // All shapes and individual bounds are checked before encoding. In
    // particular, cycles, nonfinite numbers and arbitrary toJson objects never
    // reach the encoder through these string-only closed records.
    final encoded = jsonEncode(raw);
    if (encoded.length > 256 * 1024 || utf8.encode(encoded).length > 256 * 1024) _invalid();
    final sanitized = sanitizeDirectorBeat(beat, personaName);
    final captured = jsonDecode(encoded) as Map<String, Object?>;
    captured['beat'] = sanitized.text;
    return DirectOutput._(jsonEncode(captured), jsonEncode(sanitized.issues), notes, sanitized.text);
  }

  final String _encoded;
  final String _issuesEncoded;
  final String _notes;
  final String _beat;
  String get notes => _notes;
  String get beat => _beat;
  Map<String, Object?> toJson() => jsonDecode(_encoded) as Map<String, Object?>;
  List<Map<String, Object?>> get prefetch => _records('prefetch');
  List<Map<String, Object?>> get suggestions => _records('suggestions');
  List<Map<String, Object?>> get events => _records('events');
  List<Map<String, Object?>> get issues => (jsonDecode(_issuesEncoded) as List<Object?>).cast<Map<String, Object?>>();
  List<Map<String, Object?>> _records(String field) => (toJson()[field]! as List<Object?>).cast<Map<String, Object?>>();
}

Never _invalid() => throw const FormatException(_invalidDirectOutput);

Map<String, Object?> _requireObject(Object? value, Set<String> fields) {
  if (value is! Map<Object?, Object?> ||
      value.length != fields.length ||
      value.keys.any((key) => key is! String) ||
      !fields.every(value.containsKey)) {
    _invalid();
  }
  return {for (final field in fields) field: value[field]};
}

List<Object?> _requireList(Object? value, int maximum) {
  if (value is! List<Object?> || value.length > maximum) _invalid();
  return value;
}

String _requireString(Object? value, int maximumBytes, {bool nonempty = false}) {
  if (value is! String || (nonempty && value.isEmpty) || value.length > maximumBytes) _invalid();
  if (utf8.encode(value).length > maximumBytes) _invalid();
  return value;
}

const _personaActionPrefixes = <String>[
  '转身',
  '点头',
  '摇头',
  '决定',
  '回答',
  '选择',
  '同意',
  '拒绝',
  '走',
  '说',
  '拿',
  '问',
  '推',
  '冲',
  '握',
];

/// Removes only a deterministic sentence-start pattern, not arbitrary natural
/// language impersonation. Names are literal (never interpolated into a regex).
/// A leading exact name must be followed by whitespace, ':'/'：', or one of
/// the fixed action prefixes above. Other text, whitespace and line separators
/// retain their original UTF-16 code units. Issues locate removed spans in the
/// original string; they are not part of the five-field tool output.
({String text, List<Map<String, Object?>> issues}) sanitizeDirectorBeat(String beat, String personaName) {
  if (beat.isEmpty || personaName.trim().isEmpty) return (text: beat, issues: <Map<String, Object?>>[]);
  final output = StringBuffer();
  final issues = <Map<String, Object?>>[];
  var start = 0;
  var segment = 0;
  while (start < beat.length) {
    var content = start;
    while (content < beat.length &&
        _beatWhitespace(beat.codeUnitAt(content)) &&
        !_beatLineBreak(beat.codeUnitAt(content))) {
      content++;
    }
    // Match a literal leading-space name at the original start if supplied;
    // ordinary indentation otherwise remains outside the removed span.
    final nameStart = beat.startsWith(personaName, start) ? start : content;
    final named = beat.startsWith(personaName, nameStart);
    final nameEnd = nameStart + personaName.length;
    final suffix = named && nameEnd < beat.length ? beat.codeUnitAt(nameEnd) : null;
    final remove =
        named &&
        suffix != null &&
        (_beatWhitespace(suffix) ||
            suffix == 0x3a ||
            suffix == 0xff1a ||
            _personaActionPrefixes.any((action) => beat.startsWith(action, nameEnd)));

    var end = start;
    while (end < beat.length) {
      // A punctuation character belonging to the exact name is not a sentence
      // boundary, e.g. the '.' and '?' in the literal persona name A.[x]+?.
      if (named && end == nameStart) {
        end = nameEnd;
        continue;
      }
      final unit = beat.codeUnitAt(end);
      if (_beatLineBreak(unit)) break;
      end++;
      if (_beatSentenceEnd(unit)) {
        while (end < beat.length && _beatSentenceEnd(beat.codeUnitAt(end))) {
          end++;
        }
        break;
      }
    }
    if (remove) {
      output.write(beat.substring(start, nameStart));
      issues.add({'code': 'persona-action-filtered', 'index': segment, 'offset': nameStart, 'end': end});
    } else {
      output.write(beat.substring(start, end));
    }
    // CRLF is preserved as one separator; other supported line separators are
    // preserved literally too, including after a removed sentence.
    if (end < beat.length && _beatLineBreak(beat.codeUnitAt(end))) {
      final next = beat.codeUnitAt(end) == 0x0d && end + 1 < beat.length && beat.codeUnitAt(end + 1) == 0x0a
          ? end + 2
          : end + 1;
      output.write(beat.substring(end, next));
      end = next;
    }
    start = end;
    segment++;
  }
  return (text: output.toString(), issues: issues);
}

bool _beatSentenceEnd(int unit) =>
    unit == 0x2e || unit == 0x21 || unit == 0x3f || unit == 0x3002 || unit == 0xff01 || unit == 0xff1f;
bool _beatLineBreak(int unit) => unit == 0x0a || unit == 0x0d || unit == 0x2028 || unit == 0x2029;
bool _beatWhitespace(int unit) =>
    (unit >= 0x09 && unit <= 0x0d) ||
    unit == 0x20 ||
    unit == 0x85 ||
    unit == 0xa0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200a) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202f ||
    unit == 0x205f ||
    unit == 0x3000 ||
    unit == 0xfeff;
