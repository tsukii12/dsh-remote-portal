part of 'state_engine.dart';

/// Stable across definition edits: an existing slot/entity binding stays bound.
String secretBindingKey(
  String slotId,
  String entityId, {
  StateExecutionSource source = const StateExecutionSource.legacy(),
}) => source.isPack
    ? _fingerprint({
        'kind': 'pack',
        'installedPackId': source.installedPackId,
        'bindingId': source.bindingId,
        'slotId': slotId,
        'entityId': entityId,
      })
    : _fingerprint([slotId, entityId]);

/// Fixed declarations only. Model output cannot choose paths or release policy.
class SecretDefinition {
  SecretDefinition.parse(
    Object? rawRegistry, {
    required StateDefinition state,
    Object? version = 1,
    this.source = const StateExecutionSource.legacy(),
    String? effectiveConfigId,
  }) : _raw = _eventCopy(rawRegistry),
       _version = _eventCopy(version),
       _state = state {
    try {
      _stateFingerprint = state.fingerprint;
    } catch (_) {
      _stateFingerprint = _fingerprint(
        _eventIdentity({'version': state._version, 'state': state._raw, 'composition': ?state._compositionIdentity}),
      );
      _issues.add(_issue('secret_state_identity', '', 'The state definition has no finite JSON identity.'));
    }
    _identity = _fingerprint(
      _eventIdentity({
        'version': _version,
        'secretSlots': _raw,
        'stateDefinitionFingerprint': _stateFingerprint,
        if (source.isPack) 'source': source.toJson(),
        'effectiveConfigId': ?effectiveConfigId,
      }),
    );
    if (!defined) return;
    _collectProtectedPaths();
    if (_version != 1) {
      _issues.add(_issue('secret_version', '', 'Only enclosing dshgo version 1 is executable.'));
      return;
    }
    if (_raw is! _Json || !_finiteJson(_raw)) {
      _issues.add(_issue('secret_shape', '', 'The secret registry must be a finite JSON object.'));
      return;
    }
    final raw = _raw;
    if (utf8.encode(jsonEncode(raw)).length > 1024 * 1024) {
      _issues.add(_issue('secret_size', '', 'The secret registry exceeds 1 MiB of UTF-8 JSON.'));
      return;
    }
    if (raw['v'] != 1) {
      _issues.add(_issue('secret_version', '/v', 'Only secret registry version 1 is executable.'));
      return;
    }
    final slots = raw['slots'];
    if (slots is! List<Object?>) {
      _issues.add(_issue('secret_slots', '/slots', 'The registry requires a slots array.'));
      return;
    }
    if (slots.length > 256) {
      _issues.add(_issue('secret_slots_limit', '/slots', 'A registry has at most 256 slots.'));
      return;
    }
    if (!_state.executable || _issues.any((issue) => issue['code'] == 'secret_state_identity')) {
      _issues.add(_issue('secret_state_definition', '', 'An executable state schema is required.'));
      return;
    }
    var valid = true;
    final ids = <String>{}, paths = <String>{};
    for (var i = 0; i < slots.length; i++) {
      final location = '/slots/$i';
      try {
        final item = slots[i];
        if (item is! _Json || !item.containsKey('bindWhen')) {
          throw _StateError(
            'secret_slot',
            location,
            'A slot requires fixed id, path, entityPath, unbound, bindWhen and release.',
          );
        }
        final id = _secretSlotString(item, 'id', location);
        final path = _secretSlotString(item, 'path', location);
        final entityPath = _secretSlotString(item, 'entityPath', location);
        final tokens = _tokens(path), entityTokens = _tokens(entityPath);
        if (!ids.add(id)) throw _StateError('secret_duplicate_id', '$location/id', 'Slot ids must be unique.');
        if (!paths.add(path)) {
          throw _StateError('secret_duplicate_path', '$location/path', 'Slot paths must be unique.');
        }
        if (_prefix(tokens, entityTokens) || _prefix(entityTokens, tokens)) {
          throw _StateError('secret_entity_overlap', '$location/entityPath', 'Fact and entity paths must not overlap.');
        }
        final sink = _secretSlotSink(_state, tokens);
        final unbound = item['unbound'];
        final absent = unbound is _Json && unbound.length == 1 && unbound['exists'] == false;
        final nullable =
            unbound is _Json &&
            unbound.length == 2 &&
            unbound['exists'] == true &&
            unbound.containsKey('value') &&
            unbound['value'] == null;
        if (!absent && !nullable) {
          throw _StateError(
            'secret_unbound',
            '$location/unbound',
            'unbound is exactly {exists:false} or {exists:true,value:null}.',
          );
        }
        if (nullable && !sink.types.contains('null')) {
          throw _StateError(
            'secret_unbound_null',
            '$location/unbound',
            'The sink schema must permit an explicit null.',
          );
        }
        final release = item['release'];
        if (release is! _Json ||
            release['audience'] != 'currentCharacter' ||
            !release.containsKey('when') ||
            release['template'] is! String) {
          throw _StateError(
            'secret_release',
            '$location/release',
            'Release requires fixed id, currentCharacter audience, when and string template.',
          );
        }
        final releaseId = _secretSlotString(release, 'id', '$location/release');
        final bindWhen = _Logic.compile(item['bindWhen'], '$location/bindWhen');
        final releaseWhen = _Logic.compile(release['when'], '$location/release/when');
        _slots.add(
          _SecretSlot(
            id,
            path,
            entityPath,
            tokens,
            entityTokens,
            nullable,
            bindWhen,
            releaseWhen,
            releaseId,
            release['template']! as String,
            item,
          ),
        );
        _secretSlotUnknown(
          item,
          const {'id', 'path', 'entityPath', 'unbound', 'bindWhen', 'release'},
          location,
          _issues,
        );
        _secretSlotUnknown(release, const {'id', 'audience', 'when', 'template'}, '$location/release', _issues);
      } on _StateError catch (error) {
        valid = false;
        _issues.add(error.issue);
      }
    }
    _secretSlotUnknown(raw, const {'v', 'slots'}, '', _issues);
    // A malformed member disables the whole declaration, never a silent subset.
    _executable = valid;
    if (!valid) _slots.clear();
  }

  final Object? _raw, _version;
  final StateExecutionSource source;
  final StateDefinition _state;
  late final String _stateFingerprint, _identity;
  final List<_Json> _issues = [];
  final List<_SecretSlot> _slots = [];
  final Set<String> _protectedPaths = {};
  bool _executable = false;
  bool get defined => _raw != null;
  bool get executable => _executable;
  String get fingerprint => _identity;
  Object? get raw => _eventCopy(_raw);
  List<Map<String, Object?>> get issues => _maps(_issues);
  List<String> get protectedPaths => List.of(_protectedPaths);

  void _collectProtectedPaths() {
    final raw = _raw;
    if (raw is! _Json || raw['slots'] is! List<Object?>) {
      _issues.add(
        _issue('secret_protection_unknown', '', 'Protected paths cannot be reliably recovered from this registry.'),
      );
      return;
    }
    final slots = raw['slots']! as List<Object?>;
    for (var i = 0; i < slots.length; i++) {
      final item = slots[i];
      try {
        if (item is! _Json) throw const _StateError('pointer', '', 'A slot must be an object.');
        _protectedPaths.add(_pointer(_tokens(item['path'])));
      } on _StateError {
        _issues.add(
          _issue('secret_protection_unknown', '/slots/$i/path', 'This slot has no reliable JSON Pointer to protect.'),
        );
      }
    }
  }

  SecretCapability capture({
    required Object? value,
    required bool valueExists,
    required Iterable<String> boundKeys,
    required String characterId,
  }) {
    final frozen = _eventCopy(value), problems = issues;
    final captured = <_CapturedSecretSlot>[];
    final finite = _finiteJson(frozen);
    final baselineFingerprint = finite
        ? _fingerprint({'exists': valueExists, 'value': frozen})
        : _fingerprint(_eventIdentity({'exists': valueExists, 'value': frozen}));
    if (characterId.isEmpty) problems.add(_issue('secret_character', '', 'A current character identity is required.'));
    var validState = false;
    if (!valueExists || !finite || !_state.executable) {
      problems.add(_issue('secret_state_value', '', 'An existing, finite, valid saved state is required.'));
    } else {
      final invalid = _state.validate(frozen);
      problems.addAll(invalid);
      validState = invalid.isEmpty;
    }
    if (executable && characterId.isNotEmpty && validState) {
      final bound = boundKeys.toSet();
      for (final slot in _slots) {
        final current = _secretSlotLookup(frozen, slot.tokens);
        final entity = _secretSlotLookup(frozen, slot.entityTokens);
        if (!current.parents || !entity.parents) {
          problems.add(_issue('secret_parent', slot.path, 'Every fact/entity parent must already be an object.'));
          continue;
        }
        if (!entity.exists || entity.value is! String || (entity.value! as String).isEmpty) {
          problems.add(_issue('secret_entity', slot.entityPath, 'The current entity must be a nonempty string.'));
          continue;
        }
        final entityId = entity.value! as String;
        if (bound.contains(secretBindingKey(slot.id, entityId, source: source)) ||
            current.exists != slot.expectedExists ||
            (current.exists && current.value != null)) {
          continue;
        }
        try {
          if (_truthy(slot.bindWhen.evaluate(frozen))) captured.add(_CapturedSecretSlot(slot, entityId));
        } on _StateError catch (error) {
          problems.add(error.issue);
        }
      }
    }
    return SecretCapability._(
      definitionFingerprint: fingerprint,
      stateDefinitionFingerprint: _stateFingerprint,
      baselineFingerprint: baselineFingerprint,
      characterId: characterId,
      baseline: frozen,
      valueExists: valueExists,
      slots: captured,
      issues: problems,
    );
  }

  /// Current-state policy only. The host must authenticate the binding ledger,
  /// same-chat bind run, definition, recipient and value hash before using this.
  SecretRelease? releaseFor({
    required String slotId,
    required String entityId,
    required String characterId,
    required Object? value,
    required bool valueExists,
  }) {
    if (!executable || !valueExists || characterId.isEmpty || entityId.isEmpty || !_finiteJson(value)) return null;
    final frozen = _copy(value);
    if (!_state.executable || _state.validate(frozen).isNotEmpty) return null;
    final matches = _slots.where((slot) => slot.id == slotId);
    if (matches.isEmpty) return null;
    final slot = matches.single;
    final current = _secretSlotLookup(frozen, slot.tokens), entity = _secretSlotLookup(frozen, slot.entityTokens);
    if (!current.parents ||
        !current.exists ||
        current.value is! String ||
        !entity.parents ||
        !entity.exists ||
        entity.value != entityId) {
      return null;
    }
    final fact = current.value! as String;
    if (utf8.encode(fact).length > 16 * 1024) return null;
    try {
      _secretSlotSink(_state, slot.tokens);
      if (!_truthy(slot.releaseWhen.evaluate(frozen))) return null;
    } on _StateError {
      return null;
    }
    return SecretRelease._(
      slotId: slot.id,
      entityId: entityId,
      path: slot.path,
      releaseId: slot.releaseId,
      characterId: characterId,
      definitionFingerprint: fingerprint,
      valueHash: _fingerprint(fact),
      text: slot.template.replaceAll('{{fact}}', fact),
    );
  }
}

class SecretCapability {
  SecretCapability._({
    required this.definitionFingerprint,
    required this.stateDefinitionFingerprint,
    required this.baselineFingerprint,
    required this.characterId,
    required Object? baseline,
    required bool valueExists,
    required List<_CapturedSecretSlot> slots,
    required List<_Json> issues,
  }) : _slots = List.unmodifiable(slots),
       _issues = _maps(issues) {
    _identity = _fingerprint(
      _eventIdentity({
        'definitionFingerprint': definitionFingerprint,
        'stateDefinitionFingerprint': stateDefinitionFingerprint,
        'valueExists': valueExists,
        'value': baseline,
        'characterId': characterId,
        'catalog': catalog,
      }),
    );
  }
  final String definitionFingerprint, stateDefinitionFingerprint, baselineFingerprint, characterId;
  final List<_CapturedSecretSlot> _slots;
  final List<_Json> _issues;
  late final String _identity;
  String get fingerprint => _identity;
  List<String> get slotIds => [for (final slot in _slots) slot.definition.id];
  List<Map<String, Object?>> get catalog => [for (final slot in _slots) slot.toJson()];
  List<Map<String, Object?>> get issues => _maps(_issues);

  Map<String, Object?>? strictTool() {
    if (_slots.isEmpty) return null;
    return {
      'type': 'function',
      'function': <String, Object?>{
        'name': 'propose_secrets',
        'description': 'Propose literal values for the captured secret slots.',
        'strict': true,
        'parameters': <String, Object?>{
          'type': 'object',
          'additionalProperties': false,
          'required': ['notes', 'facts'],
          'properties': <String, Object?>{
            'notes': <String, Object?>{'type': 'string'},
            'facts': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'additionalProperties': false,
                'required': ['slotId', 'value'],
                'properties': <String, Object?>{
                  'slotId': <String, Object?>{'type': 'string', 'enum': slotIds},
                  'value': <String, Object?>{'type': 'string'},
                },
              },
            },
          },
        },
      },
    };
  }

  SecretProposal parseProposal(Object? raw) {
    if (!_finiteJson(raw)) throw const FormatException('Secret proposal must be finite JSON.');
    final copy = _eventCopy(raw);
    if (utf8.encode(jsonEncode(copy)).length > 256 * 1024) {
      throw const FormatException('Secret proposal exceeds 256 KiB of UTF-8 JSON.');
    }
    if (copy is! _Json || copy.length != 2 || copy['notes'] is! String || copy['facts'] is! List<Object?>) {
      throw const FormatException('Secret proposal requires exactly string notes and array facts.');
    }
    final facts = copy['facts']! as List<Object?>;
    if (facts.length > 8) throw const FormatException('A secret proposal has at most 8 facts.');
    final allowed = slotIds.toSet(), seen = <String>{};
    for (final fact in facts) {
      if (fact is! _Json ||
          fact.length != 2 ||
          fact['slotId'] is! String ||
          fact['value'] is! String ||
          !allowed.contains(fact['slotId']) ||
          !seen.add(fact['slotId']! as String)) {
        throw const FormatException('Facts require exactly one distinct authorized slotId and a string value.');
      }
      if (utf8.encode(fact['value']! as String).length > 16 * 1024) {
        throw const FormatException('A secret fact exceeds 16 KiB of UTF-8 text.');
      }
    }
    return SecretProposal._(fingerprint, copy['notes']! as String, facts.cast<_Json>());
  }

  StateSecretPlan plan(SecretProposal proposal, {required String id}) {
    if (proposal._capabilityFingerprint != fingerprint) {
      throw const FormatException('The proposal belongs to a different captured capability.');
    }
    final checked = parseProposal(proposal.toJson());
    if (checked._facts.isEmpty) throw const FormatException('An empty proposal does not bind facts.');
    return StateSecretPlan(
      id: id,
      stateDefinitionFingerprint: stateDefinitionFingerprint,
      baselineFingerprint: baselineFingerprint,
      facts: [
        for (final fact in checked._facts)
          _slots.singleWhere((slot) => slot.definition.id == fact['slotId']).fact(fact['value']! as String),
      ],
    );
  }
}

class SecretProposal {
  SecretProposal._(this._capabilityFingerprint, this.notes, List<_Json> facts) : _facts = _maps(facts);
  final String _capabilityFingerprint;
  final String notes;
  final List<_Json> _facts;
  List<Map<String, Object?>> get facts => _maps(_facts);
  Map<String, Object?> toJson() => {'notes': notes, 'facts': facts};
}

class SecretRelease {
  const SecretRelease._({
    required this.slotId,
    required this.entityId,
    required this.path,
    required this.releaseId,
    required this.characterId,
    required this.definitionFingerprint,
    required this.valueHash,
    required this.text,
  });
  final String slotId, entityId, path, releaseId, characterId, definitionFingerprint, valueHash, text;
  Map<String, Object?> toJson() => {
    'slotId': slotId,
    'entityId': entityId,
    'path': path,
    'releaseId': releaseId,
    'characterId': characterId,
    'definitionFingerprint': definitionFingerprint,
    'valueHash': valueHash,
    'text': text,
  };
}

class _SecretSlot {
  _SecretSlot(
    this.id,
    this.path,
    this.entityPath,
    List<String> tokens,
    List<String> entityTokens,
    this.expectedExists,
    this.bindWhen,
    this.releaseWhen,
    this.releaseId,
    this.template,
    _Json raw,
  ) : tokens = List.unmodifiable(tokens),
      entityTokens = List.unmodifiable(entityTokens),
      raw = _mapCopy(raw);
  final String id, path, entityPath, releaseId, template;
  final List<String> tokens, entityTokens;
  final bool expectedExists;
  final _Logic bindWhen, releaseWhen;
  final _Json raw;
}

class _CapturedSecretSlot {
  const _CapturedSecretSlot(this.definition, this.entityId);
  final _SecretSlot definition;
  final String entityId;
  _Json toJson() => {'slotId': definition.id, 'entityId': entityId, 'declaration': _mapCopy(definition.raw)};
  StateSecretFact fact(String value) => StateSecretFact(
    slotId: definition.id,
    entityId: entityId,
    path: definition.path,
    expectedExists: definition.expectedExists,
    expectedValue: null,
    value: value,
  );
}

String _secretSlotString(_Json raw, String key, String location) {
  final value = raw[key];
  if (value is! String || value.isEmpty) {
    throw _StateError('secret_slot_string', '$location/$key', 'A nonempty fixed string is required.');
  }
  return value;
}

void _secretSlotUnknown(_Json raw, Set<String> allowed, String location, List<_Json> issues) {
  for (final key in raw.keys) {
    if (!allowed.contains(key)) {
      issues.add(
        _issue(
          'secret_unknown',
          '$location/${_escape(key)}',
          'Unknown declaration metadata is preserved without execution.',
          kind: 'unknown',
        ),
      );
    }
  }
}

_Schema _secretSlotSink(StateDefinition state, List<String> tokens) {
  if (!state.executable || tokens.isEmpty) {
    throw _StateError('secret_sink', _pointer(tokens), 'A non-root executable string sink is required.');
  }
  var node = state._root!;
  void permitted() {
    if (node.blocked || node.derived || !node.allowed.contains(StateActor.rules)) {
      throw _StateError(
        'secret_sink_permission',
        _pointer(tokens),
        'The entire sink chain must be executable, non-derived and rules-writable.',
      );
    }
  }

  for (final token in tokens) {
    permitted();
    if (!node.types.contains('object') || node.types.contains('array') || !node.properties.containsKey(token)) {
      throw _StateError('secret_sink_path', _pointer(tokens), 'A fixed object-property schema chain is required.');
    }
    node = node.properties[token]!;
  }
  permitted();
  if (!node.hidden || !node.types.contains('string') || node.types.any((type) => type != 'string' && type != 'null')) {
    throw _StateError(
      'secret_sink_type',
      _pointer(tokens),
      'The sink must be hidden and have only string or string/null types.',
    );
  }
  return node;
}

({bool parents, bool exists, Object? value}) _secretSlotLookup(Object? value, List<String> tokens) {
  if (tokens.isEmpty) return (parents: true, exists: true, value: value);
  var current = value;
  for (var i = 0; i < tokens.length; i++) {
    if (current is! _Json) return (parents: false, exists: false, value: null);
    final present = current.containsKey(tokens[i]);
    if (i == tokens.length - 1) return (parents: true, exists: present, value: current[tokens[i]]);
    if (!present) return (parents: false, exists: false, value: null);
    current = current[tokens[i]];
  }
  return (parents: false, exists: false, value: null);
}
