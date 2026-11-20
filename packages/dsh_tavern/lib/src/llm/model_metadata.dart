part of 'model_client.dart';

const _usageFields = ['prompt_tokens', 'completion_tokens', 'cache_hit_tokens'];
const _assistantProfile = 'deepseek_chat_completions_non_thinking_v1';

/// Lossless usage evidence beside the legacy normalized counters. Missing,
/// invalid, unknown and explicitly reported zero are intentionally distinct.
class ModelUsageReport {
  factory ModelUsageReport.fromJson(Map<String, Object?> json) {
    final value = _metadataObject(json);
    if (value['version'] is! int ||
        value['version'] != 1 ||
        !const ['provider', 'legacy_normalized', 'not_reported'].contains(value['origin']) ||
        !const ['nonstream', 'streaming', 'custom'].contains(value['transport']) ||
        value['observationIndex'] is! int ||
        (value['observationIndex']! as int) < 0 ||
        value['observationComplete'] is! bool ||
        (value['rawPresent'] != null && value['rawPresent'] is! bool) ||
        !value.containsKey('raw')) {
      throw const FormatException('Invalid usage report envelope.');
    }
    final fields = value['fields'];
    if (fields is! Map<String, Object?> || fields.length != _usageFields.length) {
      throw const FormatException('Invalid usage report fields.');
    }
    for (final key in _usageFields) {
      final field = fields[key];
      if (field is! Map<String, Object?> ||
          !const ['reported', 'missing', 'invalid', 'unknown'].contains(field['state']) ||
          (field['sourcePath'] != null && field['sourcePath'] is! String) ||
          (field['originalPresence'] != null && field['originalPresence'] is! bool)) {
        throw FormatException('Invalid usage field: $key.');
      }
      final number = field['value'];
      if (field['state'] == 'reported' ? number is! int || number < 0 : number != null) {
        throw FormatException('Invalid reported usage value: $key.');
      }
      final state = field['state'];
      final presence = field['originalPresence'];
      if ((state == 'reported' || state == 'invalid') && presence != true ||
          state == 'missing' && presence != false ||
          state == 'unknown' && presence != null) {
        throw FormatException('Usage presence contradicts its field state: $key.');
      }
      if (value['origin'] == 'legacy_normalized' && state != 'unknown' ||
          value['origin'] == 'not_reported' && state != 'missing') {
        throw FormatException('Usage origin contradicts its field state: $key.');
      }
    }
    if (value['origin'] == 'provider' && value['rawPresent'] != true ||
        value['origin'] == 'not_reported' && (value['rawPresent'] != false || value['raw'] != null) ||
        value['origin'] == 'legacy_normalized' && (value['rawPresent'] != null || value['raw'] != null)) {
      throw const FormatException('Usage origin contradicts raw presence.');
    }
    return ModelUsageReport._(value);
  }

  factory ModelUsageReport.legacyNormalized({required int observationIndex}) => ModelUsageReport.fromJson({
    'version': 1,
    'origin': 'legacy_normalized',
    'transport': 'custom',
    'observationIndex': observationIndex,
    'observationComplete': false,
    'rawPresent': null,
    'raw': null,
    'fields': {for (final key in _usageFields) key: _usageField('unknown')},
  });

  ModelUsageReport._(this._data);
  final Map<String, Object?> _data;
  int get version => _data['version']! as int;
  String get origin => _data['origin']! as String;
  String get transport => _data['transport']! as String;
  int get observationIndex => _data['observationIndex']! as int;
  bool get observationComplete => _data['observationComplete']! as bool;
  bool? get rawPresent => _data['rawPresent'] as bool?;
  Object? get raw => _metadataCopy(_data['raw']);
  Map<String, Object?> get fields => _metadataObject(_data['fields']! as Map<String, Object?>);
  Map<String, Object?> toJson() => _metadataObject(_data);
}

Map<String, Object?> _usageField(String state, {int? value, String? path, bool? presence}) => {
  'state': state,
  'value': value,
  'sourcePath': path,
  'originalPresence': presence,
};

ModelUsageReport _providerUsageReport(
  Object? raw, {
  required bool present,
  required String transport,
  required int observationIndex,
}) {
  final fields = <String, Object?>{};
  final diagnostics = <Map<String, Object?>>[];
  Map<String, Object?> selected(Object? value, String path) => value is int && value >= 0
      ? _usageField('reported', value: value, path: path, presence: true)
      : _usageField('invalid', path: path, presence: true);
  if (!present) {
    for (final key in _usageFields) {
      fields[key] = _usageField('missing', presence: false);
    }
  } else if (raw is! Map<String, Object?>) {
    for (final key in _usageFields) {
      fields[key] = _usageField('invalid', path: 'usage', presence: true);
    }
  } else {
    for (final key in const ['prompt_tokens', 'completion_tokens']) {
      fields[key] = raw.containsKey(key)
          ? selected(raw[key], 'usage.$key')
          : _usageField('missing', path: 'usage.$key', presence: false);
    }
    const primary = 'prompt_cache_hit_tokens';
    const detailsKey = 'prompt_tokens_details';
    final details = raw[detailsKey];
    final primaryPresent = raw.containsKey(primary);
    final invalidDetails = raw.containsKey(detailsKey) && details is! Map<String, Object?>;
    if (invalidDetails) {
      diagnostics.add({'code': 'invalid_usage_details', 'sourcePath': 'usage.$detailsKey'});
    }
    if (raw[primary] != null) {
      fields['cache_hit_tokens'] = selected(raw[primary], 'usage.$primary');
    } else if (details is Map<String, Object?> && details.containsKey('cached_tokens')) {
      fields['cache_hit_tokens'] = selected(details['cached_tokens'], 'usage.$detailsKey.cached_tokens');
    } else if (primaryPresent) {
      fields['cache_hit_tokens'] = selected(raw[primary], 'usage.$primary');
    } else if (invalidDetails) {
      fields['cache_hit_tokens'] = _usageField('invalid', path: 'usage.$detailsKey', presence: true);
    } else {
      fields['cache_hit_tokens'] = _usageField('missing', path: 'usage.$primary', presence: false);
    }
  }
  return ModelUsageReport.fromJson({
    'version': 1,
    'origin': present ? 'provider' : 'not_reported',
    'transport': transport,
    'observationIndex': observationIndex,
    'observationComplete': true,
    'rawPresent': present,
    'raw': raw,
    'fields': fields,
    if (diagnostics.isNotEmpty) 'diagnostics': diagnostics,
  });
}

/// Typed parser facts. Legacy custom fragments omit this object and therefore
/// cannot establish that their original response envelope was fully supported.
class ModelToolFragmentStructure {
  const ModelToolFragmentStructure({
    this.structuralKnowledge = 'known',
    this.unsupportedEnvelope = false,
    this.invalidMetadataType = false,
    this.invalidArgumentsType = false,
  });
  factory ModelToolFragmentStructure.fromJson(Map<String, Object?> json) {
    if (!const ['known', 'unknown'].contains(json['structuralKnowledge']) ||
        json['unsupportedEnvelope'] is! bool ||
        json['invalidMetadataType'] is! bool ||
        json['invalidArgumentsType'] is! bool) {
      throw const FormatException('Invalid fragment structure.');
    }
    return ModelToolFragmentStructure(
      structuralKnowledge: json['structuralKnowledge']! as String,
      unsupportedEnvelope: json['unsupportedEnvelope']! as bool,
      invalidMetadataType: json['invalidMetadataType']! as bool,
      invalidArgumentsType: json['invalidArgumentsType']! as bool,
    );
  }
  final String structuralKnowledge;
  final bool unsupportedEnvelope;
  final bool invalidMetadataType;
  final bool invalidArgumentsType;
  Map<String, Object?> toJson() => {
    'structuralKnowledge': structuralKnowledge,
    'unsupportedEnvelope': unsupportedEnvelope,
    'invalidMetadataType': invalidMetadataType,
    'invalidArgumentsType': invalidArgumentsType,
  };
}

/// The call fields actually observed in one response. Index is correlation
/// metadata and is never added to the assistant message sent back on the wire.
class ModelAssistantToolCall {
  factory ModelAssistantToolCall.fromJson(Map<String, Object?> json) {
    final value = _metadataObject(json);
    if (value['index'] is! int || (value['index']! as int) < 0) {
      throw const FormatException('Invalid assistant call index.');
    }
    for (final key in const ['id', 'type', 'name', 'arguments']) {
      if (value[key] != null && value[key] is! String) throw FormatException('Invalid assistant call $key.');
    }
    return ModelAssistantToolCall._(value);
  }
  ModelAssistantToolCall._(this._data);
  final Map<String, Object?> _data;
  int get index => _data['index']! as int;
  String? get id => _data['id'] as String?;
  String? get type => _data['type'] as String?;
  String? get name => _data['name'] as String?;
  String? get arguments => _data['arguments'] as String?;
  Map<String, Object?> toJson() => _metadataObject(_data);
}

/// Response-only assistant data for the supported non-thinking profile. The
/// factory derives call fields from the same message and refuses inconsistent
/// serialized claims; it never fills missing role, identity or arguments.
class ModelAssistantSnapshot {
  factory ModelAssistantSnapshot.fromCustomMessage(Map<String, Object?> message, {List<int>? callIndexes}) {
    _metadataFinite(message, Set<Object>.identity());
    final collector = _AssistantCollector('custom_snapshot');
    collector.add(message, streaming: false, callIndexes: callIndexes);
    return collector.finish();
  }
  factory ModelAssistantSnapshot.fromJson(Map<String, Object?> json) {
    final value = _metadataObject(json);
    final wire = value['wireMessage'];
    final rawCalls = value['calls'];
    final state = value['structuralState'];
    final diagnostics = value['diagnostics'];
    if (value['version'] is! int ||
        value['version'] != 1 ||
        value['profile'] != _assistantProfile ||
        !const ['nonstream_message', 'streaming_aggregate', 'custom_snapshot'].contains(value['source']) ||
        value['completeForReplay'] is! bool ||
        wire is! Map<String, Object?> ||
        rawCalls is! List<Object?> ||
        state is! Map<String, Object?> ||
        diagnostics is! List<Object?>) {
      throw const FormatException('Invalid assistant snapshot envelope.');
    }
    final calls = <ModelAssistantToolCall>[];
    for (final call in rawCalls) {
      if (call is! Map<String, Object?>) throw const FormatException('Invalid assistant snapshot calls.');
      calls.add(ModelAssistantToolCall.fromJson(call));
    }
    _validateAssistantState(state);
    for (final diagnostic in diagnostics) {
      if (diagnostic is! Map<String, Object?>) throw const FormatException('Invalid assistant diagnostic.');
    }
    final collector = _AssistantCollector(value['source']! as String);
    collector.add(wire, streaming: false, callIndexes: [for (final call in calls) call.index]);
    final rebuilt = collector.finish();
    if (!_metadataEqual([for (final call in calls) call.toJson()], [for (final call in rebuilt.calls) call.toJson()])) {
      throw const FormatException('Assistant calls do not match the same wire message.');
    }
    if (value['completeForReplay'] == true &&
        (!rebuilt.completeForReplay ||
            state['replayability'] != 'confirmed' ||
            state['resourceOverflow'] == true ||
            state['hasUnassignedFragment'] == true ||
            state['metadataConflict'] == true ||
            state['unsupportedEnvelope'] == true ||
            state['finalIdentityComplete'] != true ||
            state['originalArgumentsStringComplete'] != true ||
            state['structuralKnowledge'] != 'known')) {
      throw const FormatException('Assistant replay completeness is not supported by its data.');
    }
    return ModelAssistantSnapshot._(value);
  }
  ModelAssistantSnapshot._(Map<String, Object?> data) : _data = _metadataObject(data);
  final Map<String, Object?> _data;
  int get version => _data['version']! as int;
  String get profile => _data['profile']! as String;
  String get source => _data['source']! as String;
  bool get completeForReplay => _data['completeForReplay']! as bool;
  Map<String, Object?> get wireMessage => _metadataObject(_data['wireMessage']! as Map<String, Object?>);
  List<ModelAssistantToolCall> get calls => List.unmodifiable([
    for (final call in _data['calls']! as List<Object?>) ModelAssistantToolCall.fromJson(call! as Map<String, Object?>),
  ]);
  Map<String, Object?> get structuralState => _metadataObject(_data['structuralState']! as Map<String, Object?>);
  List<Map<String, Object?>> get diagnostics => List.unmodifiable([
    for (final item in _data['diagnostics']! as List<Object?>) _metadataObject(item! as Map<String, Object?>),
  ]);
  Map<String, Object?> toJson() => _metadataObject(_data);
}

void _validateAssistantState(Map<String, Object?> state) {
  for (final key in const [
    'resourceOverflow',
    'hasUnassignedFragment',
    'metadataConflict',
    'unsupportedEnvelope',
    'finalIdentityComplete',
    'originalArgumentsStringComplete',
  ]) {
    if (state[key] is! bool) throw FormatException('Invalid assistant structure: $key.');
  }
  if (!const ['known', 'unknown'].contains(state['structuralKnowledge']) ||
      !const ['confirmed', 'invalid', 'unknown'].contains(state['replayability'])) {
    throw const FormatException('Invalid assistant replayability.');
  }
}

class _AssistantCollector {
  _AssistantCollector(this.source);
  static const _maxCalls = 64;
  static const _maxArgumentBytes = 1024 * 1024;
  final String source;
  final _calls = <int, _AssistantCallBuffer>{};
  final _content = StringBuffer();
  final _reasoning = <String, StringBuffer?>{};
  String? _role;
  var _contentPresent = false;
  var _contentString = false;
  var _toolsPresent = false;
  var _toolsArrayObserved = false;
  var _bytes = 0;
  var _overflow = false;
  var _unassigned = false;
  var _conflict = false;
  var _unsupported = false;
  var _invalidMessage = false;
  var _unknown = false;

  void add(Map<String, Object?> message, {required bool streaming, List<int>? callIndexes}) {
    for (final key in message.keys) {
      if (!const ['role', 'content', 'reasoning_content', 'reasoning', 'tool_calls'].contains(key)) _unsupported = true;
    }
    if (message.containsKey('role')) {
      final role = message['role'];
      if (role is! String) {
        _invalidMessage = true;
      } else if (_role == null) {
        _role = role;
      } else if (_role != role) {
        _conflict = true;
      }
    }
    if (message.containsKey('content')) {
      _contentPresent = true;
      final content = message['content'];
      if (content is String) {
        _contentString = true;
        _content.write(content);
      } else if (content != null) {
        _invalidMessage = true;
      }
    }
    for (final field in const ['reasoning_content', 'reasoning']) {
      if (!message.containsKey(field)) continue;
      final reasoning = message[field];
      if (reasoning is String) {
        (_reasoning[field] ??= StringBuffer()).write(reasoning);
      } else {
        _reasoning.putIfAbsent(field, () => null);
        if (reasoning != null) _invalidMessage = true;
      }
    }
    final tools = message['tool_calls'];
    _toolsPresent = _toolsPresent || message.containsKey('tool_calls');
    _toolsArrayObserved = _toolsArrayObserved || tools is List<Object?>;
    if (callIndexes != null) {
      if (callIndexes.length > _maxCalls) {
        throw const FormatException('callIndexes exceeds the 64-call snapshot limit.');
      }
      final length = tools is List<Object?> ? tools.length : 0;
      if (callIndexes.length != length ||
          callIndexes.any((index) => index < 0) ||
          callIndexes.toSet().length != callIndexes.length) {
        throw const FormatException('callIndexes must match the actual tools and be nonnegative and unique.');
      }
      callIndexes = List<int>.of(callIndexes);
    }
    var ordinal = 0;
    for (final fragment in _toolFragments(tools, streaming: streaming)) {
      final originalIndex = fragment.index;
      final index = callIndexes == null || originalIndex == null ? originalIndex : callIndexes[ordinal];
      ordinal++;
      final structure = fragment.structure;
      _unknown = _unknown || structure == null || structure.structuralKnowledge != 'known';
      _unsupported = _unsupported || (structure?.unsupportedEnvelope ?? false);
      if (index == null || index < 0) {
        _unassigned = true;
      }
      var call = index == null || index < 0 ? null : _calls[index];
      final arguments = fragment.arguments;
      var retain = !_overflow;
      if (arguments != null && retain) {
        final remaining = _maxArgumentBytes - _bytes;
        if (arguments.length > remaining) {
          _overflow = true;
          retain = false;
        } else {
          final joins =
              (call?.endsWithLeadSurrogate ?? false) &&
              arguments.isNotEmpty &&
              (arguments.codeUnitAt(0) & 0xfc00) == 0xdc00;
          final count = utf8.encode(arguments).length - (joins ? 2 : 0);
          if (count > remaining) {
            _overflow = true;
            retain = false;
          } else {
            _bytes += count;
          }
        }
      }
      if (index == null || index < 0) continue;
      if (call == null) {
        if (_calls.length == _maxCalls) {
          _overflow = true;
          continue;
        }
        call = _AssistantCallBuffer();
        _calls[index] = call;
      }
      call.invalidMetadata = call.invalidMetadata || (structure?.invalidMetadataType ?? false);
      call.invalidArguments = call.invalidArguments || (structure?.invalidArgumentsType ?? false);
      call.metadata('id', fragment.id);
      call.metadata('type', fragment.type);
      call.metadata('name', fragment.name);
      if (arguments != null && retain && !_overflow) {
        call.sawArguments = true;
        call.arguments.write(arguments);
        if (arguments.isNotEmpty) {
          call.endsWithLeadSurrogate = (arguments.codeUnitAt(arguments.length - 1) & 0xfc00) == 0xd800;
        }
      }
    }
  }

  ModelAssistantSnapshot finish() {
    final ordered = _calls.keys.toList();
    if (source == 'streaming_aggregate') ordered.sort();
    final ids = <String>{};
    var identity = !_unassigned;
    var arguments = !_overflow && !_unassigned;
    final wireCalls = <Map<String, Object?>>[];
    final calls = <Map<String, Object?>>[];
    for (final index in ordered) {
      final call = _calls[index]!;
      final id = call.fields['id'];
      final type = call.fields['type'];
      final name = call.fields['name'];
      final unique = id != null && id.isNotEmpty && ids.add(id);
      _conflict = _conflict || call.conflict;
      identity =
          identity &&
          unique &&
          type == 'function' &&
          name != null &&
          name.isNotEmpty &&
          !call.conflict &&
          !call.invalidMetadata;
      arguments = arguments && call.sawArguments && !call.invalidArguments;
      final rawArguments = call.sawArguments ? call.arguments.toString() : null;
      calls.add({'index': index, 'id': id, 'type': type, 'name': name, 'arguments': rawArguments});
      wireCalls.add({
        'id': ?id,
        'type': ?type,
        if (name != null || rawArguments != null) 'function': {'name': ?name, 'arguments': ?rawArguments},
      });
    }
    final invalid =
        _overflow ||
        _unassigned ||
        _conflict ||
        _unsupported ||
        _invalidMessage ||
        _role != 'assistant' ||
        !identity ||
        !arguments;
    final replayability = invalid ? 'invalid' : (_unknown ? 'unknown' : 'confirmed');
    final state = <String, Object?>{
      'resourceOverflow': _overflow,
      'hasUnassignedFragment': _unassigned,
      'metadataConflict': _conflict,
      'unsupportedEnvelope': _unsupported,
      'finalIdentityComplete': identity,
      'originalArgumentsStringComplete': arguments,
      'structuralKnowledge': _unknown ? 'unknown' : 'known',
      'replayability': replayability,
    };
    return ModelAssistantSnapshot._({
      'version': 1,
      'profile': _assistantProfile,
      'source': source,
      'completeForReplay': replayability == 'confirmed',
      'wireMessage': {
        if (_role != null) 'role': _role,
        if (_contentPresent) 'content': _contentString ? _content.toString() : null,
        for (final entry in _reasoning.entries) entry.key: entry.value?.toString(),
        if (_toolsPresent) 'tool_calls': _toolsArrayObserved ? wireCalls : null,
      },
      'calls': calls,
      'structuralState': state,
      'diagnostics': <Map<String, Object?>>[
        if (_overflow) {'code': 'assistant_resource_limit'},
        if (_unassigned) {'code': 'assistant_unassigned_fragment'},
        if (_conflict) {'code': 'assistant_metadata_conflict'},
        if (_unsupported) {'code': 'assistant_unsupported_envelope'},
        if (_invalidMessage) {'code': 'assistant_invalid_message_type'},
        if (_role != 'assistant') {'code': 'assistant_role_not_observed'},
        if (!identity) {'code': 'assistant_incomplete_identity'},
        if (!arguments) {'code': 'assistant_incomplete_arguments'},
      ],
    });
  }
}

class _AssistantCallBuffer {
  final fields = <String, String>{};
  final arguments = StringBuffer();
  var sawArguments = false;
  var endsWithLeadSurrogate = false;
  var conflict = false;
  var invalidMetadata = false;
  var invalidArguments = false;
  void metadata(String field, String? value) {
    if (value == null) return;
    if (!fields.containsKey(field)) {
      fields[field] = value;
    } else if (fields[field] != value) {
      conflict = true;
    }
  }
}

Object? _metadataCopy(Object? value) {
  _metadataFinite(value, Set<Object>.identity());
  return jsonDecode(jsonEncode(value));
}

void _metadataFinite(Object? item, Set<Object> parents) {
  if (item == null || item is String || item is bool || item is int) return;
  if (item is double && item.isFinite) return;
  if (item is Map<String, Object?> || item is List<Object?>) {
    if (!parents.add(item)) throw const FormatException('Cyclic model metadata.');
    final children = item is Map<String, Object?> ? item.values : (item as List<Object?>);
    for (final child in children) {
      _metadataFinite(child, parents);
    }
    parents.remove(item);
    return;
  }
  throw const FormatException('Model metadata requires finite JSON.');
}

Map<String, Object?> _metadataObject(Map<String, Object?> value) => _metadataCopy(value)! as Map<String, Object?>;

bool _metadataEqual(Object? left, Object? right) {
  if (left is num && right is num && (left is int) != (right is int)) return false;
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    return left.length == right.length &&
        left.keys.every((key) => right.containsKey(key) && _metadataEqual(left[key], right[key]));
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_metadataEqual(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
