import 'dart:convert';

import 'model_client.dart';

/// A complete transport snapshot, not permission to execute a tool. The
/// engine separately checks the actual request, mode and terminal outcome.
class ModelToolCall {
  ModelToolCall._({
    required this.index,
    required this.id,
    required this.type,
    required this.name,
    required this.arguments,
    required Map<String, Object?>? parameters,
    required List<Map<String, Object?>> issues,
    required this.valid,
    required this.identityComplete,
    required this.originalArgumentsStringComplete,
    required this.metadataConflict,
    required this.unsupportedEnvelope,
    required this.structuralKnowledge,
  }) : _parameters = parameters == null ? null : jsonEncode(parameters),
       _issues = jsonEncode(issues);

  final int index;
  final String? id;
  final String? type;
  final String? name;
  final String arguments;
  final String? _parameters;
  final String _issues;
  final bool valid;
  final bool identityComplete;
  final bool originalArgumentsStringComplete;
  final bool metadataConflict;
  final bool unsupportedEnvelope;
  final String structuralKnowledge;
  String get replayability => !identityComplete || !originalArgumentsStringComplete || unsupportedEnvelope
      ? 'invalid'
      : (structuralKnowledge == 'known' ? 'confirmed' : 'unknown');

  Map<String, Object?>? get parameters => _parameters == null ? null : jsonDecode(_parameters) as Map<String, Object?>;
  List<Map<String, Object?>> get issues => _decodeIssues(_issues);

  Map<String, Object?> toJson() => {
    'index': index,
    'id': id,
    'type': type,
    'name': name,
    'arguments': arguments,
    'parameters': parameters,
    'issues': issues,
    'valid': valid,
    'identityComplete': identityComplete,
    'originalArgumentsStringComplete': originalArgumentsStringComplete,
    'metadataConflict': metadataConflict,
    'unsupportedEnvelope': unsupportedEnvelope,
    'structuralKnowledge': structuralKnowledge,
    'replayability': replayability,
  };
}

class ModelToolBatch {
  ModelToolBatch._(
    List<ModelToolCall> calls,
    List<Map<String, Object?>> issues,
    this.eligibleStructure, {
    required this.rollNameObserved,
    required this.resourceOverflow,
    required this.hasUnassignedFragment,
    required this.metadataConflict,
    required this.unsupportedEnvelope,
    required this.structuralKnowledge,
  }) : calls = List.unmodifiable(calls),
       _issues = jsonEncode(issues);

  final List<ModelToolCall> calls;
  final String _issues;

  /// False on either resource limit. Otherwise individual call.valid decides
  /// structural usability; an unassigned bad fragment cannot poison a valid
  /// independent call with its own explicit index.
  final bool eligibleStructure;
  final bool rollNameObserved;
  final bool resourceOverflow;
  final bool hasUnassignedFragment;
  final bool metadataConflict;
  final bool unsupportedEnvelope;
  final String structuralKnowledge;
  bool get finalIdentityComplete =>
      !hasUnassignedFragment && !resourceOverflow && calls.every((call) => call.identityComplete);
  bool get originalArgumentsStringComplete =>
      !hasUnassignedFragment && !resourceOverflow && calls.every((call) => call.originalArgumentsStringComplete);
  String get replayability =>
      resourceOverflow ||
          hasUnassignedFragment ||
          metadataConflict ||
          unsupportedEnvelope ||
          !finalIdentityComplete ||
          !originalArgumentsStringComplete
      ? 'invalid'
      : (structuralKnowledge == 'known' ? 'confirmed' : 'unknown');
  Map<String, Object?> get structuralState => {
    'resourceOverflow': resourceOverflow,
    'hasUnassignedFragment': hasUnassignedFragment,
    'metadataConflict': metadataConflict,
    'unsupportedEnvelope': unsupportedEnvelope,
    'finalIdentityComplete': finalIdentityComplete,
    'originalArgumentsStringComplete': originalArgumentsStringComplete,
    'structuralKnowledge': structuralKnowledge,
    'replayability': replayability,
  };
  List<Map<String, Object?>> get issues => _decodeIssues(_issues);

  Map<String, Object?> toJson() => {
    'calls': [for (final call in calls) call.toJson()],
    'issues': issues,
    'eligibleStructure': eligibleStructure,
    'rollNameObserved': rollNameObserved,
    'structuralState': structuralState,
  };
}

/// One accumulator per response. Only arguments concatenate; id/type/name
/// must agree whenever repeated. Malformed calls remain inspectable.
class ModelToolAccumulator {
  static const maxCalls = 64;
  static const maxArgumentBytes = 1024 * 1024;

  final _calls = <int, _CallBuffer>{};
  final _issues = _IssueBag(global: true);
  var _argumentBytes = 0;
  var _resourceOverflow = false;
  var _rollNameObserved = false;
  var _hasUnassignedFragment = false;
  var _unsupportedEnvelope = false;
  var _structuralUnknown = false;
  Map<String, Object?>? _resourceIssue;
  ModelToolBatch? _finished;

  void add(ModelToolFragment fragment) {
    if (_finished != null) {
      throw StateError('A finished tool batch cannot accept more fragments.');
    }
    // This O(1) fact survives invalid indexes, resource drops and capped
    // diagnostics. It is a candidate observation, never authorization.
    _rollNameObserved = _rollNameObserved || fragment.name == 'roll';
    final structure = fragment.structure;
    _unsupportedEnvelope = _unsupportedEnvelope || (structure?.unsupportedEnvelope ?? false);
    _structuralUnknown = _structuralUnknown || structure == null || structure.structuralKnowledge != 'known';
    final index = fragment.index;
    var call = index == null || index < 0 ? null : _calls[index];
    final appendArguments = _countArguments(
      fragment.arguments,
      afterLeadSurrogate: call?.endsWithLeadSurrogate ?? false,
    );
    final issues = fragment.issues;
    if (index == null || index < 0) {
      _hasUnassignedFragment = true;
      for (final issue in issues) {
        _issues.add(issue);
      }
      if (index != null || issues.isEmpty) {
        _issues.add(_issue('invalid_index', 'index', 'A tool fragment requires a non-negative integer index.'));
      }
      return;
    }
    if (call == null) {
      if (_calls.length == maxCalls) {
        _flagOverflow(_issue('tool_call_limit', 'tool_calls', 'The response exceeds the 64-call limit.'));
        return;
      }
      call = _CallBuffer(index);
      _calls[index] = call;
    }
    for (final issue in issues) {
      call.issues.add(issue);
    }
    call.structuralUnknown = call.structuralUnknown || structure == null || structure.structuralKnowledge != 'known';
    call.unsupportedEnvelope = call.unsupportedEnvelope || (structure?.unsupportedEnvelope ?? false);
    call.invalidMetadataType = call.invalidMetadataType || (structure?.invalidMetadataType ?? false);
    call.invalidArgumentsType = call.invalidArgumentsType || (structure?.invalidArgumentsType ?? false);
    call.metadata('id', fragment.id);
    call.metadata('type', fragment.type);
    call.metadata('function.name', fragment.name);
    if (fragment.arguments != null && appendArguments && !_resourceOverflow) {
      final arguments = fragment.arguments!;
      call.sawArguments = true;
      call.arguments.write(arguments);
      if (arguments.isNotEmpty) {
        call.endsWithLeadSurrogate = (arguments.codeUnitAt(arguments.length - 1) & 0xfc00) == 0xd800;
      }
    }
  }

  bool _countArguments(String? arguments, {required bool afterLeadSurrogate}) {
    if (_resourceOverflow) {
      return false;
    }
    if (arguments == null) {
      return true;
    }
    final remaining = maxArgumentBytes - _argumentBytes;
    // UTF-8 never needs fewer bytes than these UTF-16 code units. The cheap
    // check also avoids allocating an arbitrarily large temporary byte list.
    if (arguments.length > remaining) {
      _overflowArguments();
      return false;
    }
    // Each isolated surrogate costs three bytes. Joining the previous lead
    // with this tail makes one four-byte code point in this call's arguments.
    final joinsPair = afterLeadSurrogate && arguments.isNotEmpty && (arguments.codeUnitAt(0) & 0xfc00) == 0xdc00;
    final bytes = utf8.encode(arguments).length - (joinsPair ? 2 : 0);
    if (bytes > remaining) {
      _overflowArguments();
      return false;
    }
    _argumentBytes += bytes;
    return true;
  }

  void _overflowArguments() {
    _flagOverflow(
      _issue(
        'tool_arguments_limit',
        'function.arguments',
        'The response exceeds the 1 MiB UTF-8 arguments limit. No call in this batch may execute.',
      ),
    );
  }

  void _flagOverflow(Map<String, Object?> issue) {
    _resourceOverflow = true;
    _resourceIssue ??= issue;
    _issues.add(issue);
  }

  /// Idempotent. Returned containers and JSON snapshots cannot mutate the
  /// accumulator. No argument prefix is decoded after a resource overflow.
  ModelToolBatch finish() => _finished ??= _finish();

  ModelToolBatch _finish() {
    final indexes = _calls.keys.toList()..sort();
    final ids = <String, List<_CallBuffer>>{};
    for (final index in indexes) {
      final call = _calls[index]!;
      final id = call.id;
      if (id != null && id.isNotEmpty) {
        ids.putIfAbsent(id, () => []).add(call);
      }
    }
    for (final duplicates in ids.values) {
      if (duplicates.length > 1) {
        for (final call in duplicates) {
          call.duplicateId = true;
          call.issues.add(_issue('duplicate_id', 'id', 'Different call indexes use the same id.', call.index));
        }
      }
    }
    final calls = <ModelToolCall>[];
    for (final index in indexes) {
      final call = _calls[index]!;
      call.requireMetadata();
      final arguments = call.arguments.toString();
      Map<String, Object?>? parameters;
      if (_resourceOverflow) {
        call.issues.add(
          _issue(
            'batch_resource_limit',
            'tool_calls',
            'A response limit was exceeded; this call is not executable.',
            index,
          ),
        );
      } else if (!call.sawArguments) {
        call.issues.add(_issue('missing_arguments', 'function.arguments', 'No argument string was received.', index));
      } else {
        try {
          final decoded = jsonDecode(arguments);
          if (decoded is Map<String, Object?>) {
            // Also rejects numbers outside Dart's finite JSON representation.
            // Never let a later toJson() throw while recording a rejected call.
            parameters = jsonDecode(jsonEncode(decoded)) as Map<String, Object?>;
          } else {
            call.issues.add(
              _issue('arguments_not_object', 'function.arguments', 'Tool parameters must be a JSON object.', index),
            );
          }
        } on FormatException {
          call.issues.add(
            _issue(
              'invalid_arguments_json',
              'function.arguments',
              'Tool arguments are not a complete JSON document.',
              index,
            ),
          );
        } on JsonUnsupportedObjectError {
          call.issues.add(
            _issue(
              'invalid_arguments_value',
              'function.arguments',
              'Tool arguments contain a value outside the supported JSON representation.',
              index,
            ),
          );
        }
      }
      final issues = call.issues.snapshot();
      calls.add(
        ModelToolCall._(
          index: index,
          id: call.id,
          type: call.type,
          name: call.name,
          arguments: arguments,
          parameters: parameters,
          issues: issues,
          valid: !_resourceOverflow && issues.isEmpty && parameters != null,
          identityComplete:
              call.id != null &&
              call.id!.isNotEmpty &&
              call.type == 'function' &&
              call.name != null &&
              call.name!.isNotEmpty &&
              !call.duplicateId &&
              !call.metadataConflict &&
              !call.invalidMetadataType,
          originalArgumentsStringComplete: call.sawArguments && !call.invalidArgumentsType && !_resourceOverflow,
          metadataConflict: call.metadataConflict,
          unsupportedEnvelope: call.unsupportedEnvelope,
          structuralKnowledge: call.structuralUnknown ? 'unknown' : 'known',
        ),
      );
    }
    final issues = _issues.snapshot();
    final resourceIssue = _resourceIssue;
    if (resourceIssue != null && !issues.any((issue) => issue['code'] == resourceIssue['code'])) {
      // A custom transport cannot bury the batch-wide refusal under a full
      // diagnostic bag. Preserve its bounded omission marker as well.
      if (issues.length == _IssueBag._limit) {
        issues[0] = resourceIssue;
      } else {
        issues.add(resourceIssue);
      }
    }
    return ModelToolBatch._(
      calls,
      issues,
      !_resourceOverflow,
      rollNameObserved: _rollNameObserved,
      resourceOverflow: _resourceOverflow,
      hasUnassignedFragment: _hasUnassignedFragment,
      metadataConflict: calls.any((call) => call.metadataConflict),
      unsupportedEnvelope: _unsupportedEnvelope,
      structuralKnowledge: _structuralUnknown ? 'unknown' : 'known',
    );
  }
}

class _CallBuffer {
  _CallBuffer(this.index);
  final int index;
  final _metadata = <String, String>{};
  final arguments = StringBuffer();
  final issues = _IssueBag();
  var sawArguments = false;
  var endsWithLeadSurrogate = false;
  var duplicateId = false;
  var metadataConflict = false;
  var invalidMetadataType = false;
  var invalidArgumentsType = false;
  var unsupportedEnvelope = false;
  var structuralUnknown = false;

  String? get id => _metadata['id'];
  String? get type => _metadata['type'];
  String? get name => _metadata['function.name'];

  void metadata(String field, String? value) {
    if (value == null) {
      return;
    }
    final previous = _metadata[field];
    if (previous == null) {
      _metadata[field] = value;
    } else if (previous != value) {
      metadataConflict = true;
      issues.add(_issue('conflicting_metadata', field, 'Repeated tool metadata does not agree.', index));
    }
  }

  void requireMetadata() {
    if (id == null || id!.isEmpty) {
      issues.add(_issue('missing_id', 'id', 'A tool call requires a non-empty id.', index));
    }
    if (type == null) {
      issues.add(_issue('missing_type', 'type', 'A tool call requires type=function.', index));
    } else if (type != 'function') {
      issues.add(_issue('invalid_tool_type', 'type', 'Only function tool calls are supported.', index));
    }
    if (name == null || name!.isEmpty) {
      issues.add(_issue('missing_name', 'function.name', 'A tool call requires a non-empty name.', index));
    }
  }
}

/// Parser codes are fixed, but the public fragment constructor may also be
/// used by a custom transport. Keep both deduplication and storage bounded.
class _IssueBag {
  _IssueBag({this.global = false});
  static const _limit = 32;
  final bool global;
  final _values = <Map<String, Object?>>[];
  final _keys = <String>{};
  var _capped = false;

  void add(Map<String, Object?> issue) {
    if (_capped) {
      return;
    }
    final key = global ? '${issue['code']}' : '${issue['code']}\u0000${issue['field']}';
    if (_keys.contains(key)) {
      return;
    }
    if (_values.length == _limit) {
      _values[_limit - 1] = _issue('diagnostic_limit', 'tool_calls', 'Further distinct diagnostics were omitted.');
      _capped = true;
      return;
    }
    _keys.add(key);
    _values.add(jsonDecode(jsonEncode(issue)) as Map<String, Object?>);
  }

  List<Map<String, Object?>> snapshot() => _decodeIssues(jsonEncode(_values));
}

Map<String, Object?> _issue(String code, String field, String message, [int? index]) => {
  'code': code,
  'field': field,
  'message': message,
  'index': ?index,
};

List<Map<String, Object?>> _decodeIssues(String json) => [
  for (final issue in jsonDecode(json) as List<Object?>) issue as Map<String, Object?>,
];
