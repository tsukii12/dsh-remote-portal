part of 'engine.dart';

const _gameplayEventRuntimeKey = 'dshgoPackRuntime';

typedef _GameplayEventPromptRef = ({state_core.StateExecutionSource source, String id});
typedef _GameplayPendingEventPrompt = ({_GameplayEventPromptRef ref, Map<String, Object?> prompt});

/// The map belongs to the admitted registry. Content version is represented by
/// the capability/configuration fingerprint; a wire name never grants authority.
Map<String, state_core.StateEventTarget> _gameplayEventWireTargets(_GameplayRuntime gameplay) {
  final targets = gameplay.events.eventTargets;
  final reserved = <String>{'group.speaker'};
  final raw = gameplay.events.raw;
  if (raw is Map<String, Object?> && raw['registries'] is List<Object?>) {
    for (final item in raw['registries']! as List<Object?>) {
      if (item is! Map<String, Object?> || item['source'] is! Map<String, Object?>) {
        continue;
      }
      final source = item['source']! as Map<String, Object?>;
      final registry = item['raw'];
      if (source['kind'] == 'legacy' && registry is Map<String, Object?> && registry['rules'] is List<Object?>) {
        for (final rule in registry['rules']! as List<Object?>) {
          if (rule is Map<String, Object?> && rule['name'] is String) {
            reserved.add(rule['name']! as String);
          }
        }
      }
    }
  }
  for (final target in targets) {
    if (!target.source.isPack) {
      reserved.add(target.name);
    }
  }
  final result = <String, state_core.StateEventTarget>{};
  for (final target in targets) {
    if (!target.source.isPack) {
      result[target.name] = target;
      continue;
    }
    final stem = 'dshgo.pack.event:${_directorHash({'source': target.source.toJson(), 'name': target.name})}';
    var name = stem;
    var suffix = 0;
    while (!reserved.add(name)) {
      name = '$stem:${++suffix}';
    }
    result[name] = target;
  }
  return result;
}

List<Map<String, Object?>> _gameplayEventWireJson(Map<String, state_core.StateEventTarget> targets) => [
  for (final entry in targets.entries)
    {'wireName': entry.key, 'source': entry.value.source.toJson(), 'name': entry.value.name},
];

Map<String, Object?> _gameplayEventCapability(_GameplayRuntime gameplay, Map<String, Object?> settings) => {
  'version': 2,
  'mode': 'literal',
  'effectiveConfigId': gameplay.effectiveConfigId,
  'registryFingerprint': gameplay.events.fingerprint,
  'stateDefinitionFingerprint': gameplay.state.hasSchema ? gameplay.state.fingerprint : null,
  'handlerRefs': [for (final ref in gameplay.events.handlerRefs) ref.toJson()],
  'eventMap': _gameplayEventWireJson(_gameplayEventWireTargets(gameplay)),
  'automaticEnabledAtCapture': _map(settings['director'])['enabled'] == true,
};

bool _gameplayEventCapabilityMatches(
  Map<String, Object?> capability,
  _GameplayRuntime gameplay,
  Map<String, state_core.StateEventTarget> targets,
) =>
    capability['version'] == 2 &&
    capability['mode'] == 'literal' &&
    gameplay.events.executable &&
    capability['effectiveConfigId'] == gameplay.effectiveConfigId &&
    capability['registryFingerprint'] == gameplay.events.fingerprint &&
    capability.containsKey('stateDefinitionFingerprint') &&
    capability['stateDefinitionFingerprint'] == (gameplay.state.hasSchema ? gameplay.state.fingerprint : null) &&
    _stateJsonEqual(capability['handlerRefs'], [for (final ref in gameplay.events.handlerRefs) ref.toJson()]) &&
    _stateJsonEqual(capability['eventMap'], _gameplayEventWireJson(targets));

/// Used only with the original generated capability, or after its complete
/// identity has matched the admitted registry. Unknown legacy proposals retain
/// their literal name and remain subject to the ordinary handler vocabulary.
Map<String, Object?>? _gameplayPersistedEventTarget(Map<String, Object?>? capability, String wireName) {
  if (capability == null || capability['version'] != 2) {
    return null;
  }
  for (final item in capability['eventMap']! as List<Object?>) {
    final row = item! as Map<String, Object?>;
    if (row['wireName'] == wireName) {
      return {
        'effectiveConfigId': capability['effectiveConfigId'],
        'source': _copy(row['source']! as Map<String, Object?>),
        'name': row['name'],
      };
    }
  }
  return {
    'effectiveConfigId': capability['effectiveConfigId'],
    'source': const state_core.StateExecutionSource.legacy().toJson(),
    'name': wireName,
  };
}

Map<String, Object?> _gameplayDirectToolDefinition(Map<String, Object?>? capability, {required bool strict}) {
  final tool = director_core.directToolDefinition(strict: strict);
  if (capability?['version'] != 2) {
    return tool;
  }
  final function = tool['function']! as Map<String, Object?>;
  final parameters = function['parameters']! as Map<String, Object?>;
  final properties = parameters['properties']! as Map<String, Object?>;
  final events = properties['events']! as Map<String, Object?>;
  final items = events['items']! as Map<String, Object?>;
  final fields = items['properties']! as Map<String, Object?>;
  final name = fields['name']! as Map<String, Object?>;
  name['description'] =
      '非空提案名称。对提供的 eventCapability.eventMap 使用精确 wireName；不要用包内 name 代替。'
      '未列入该表的原有提案仍按原名称提交，事件仍只是待处理建议。';
  return tool;
}

bool _hasGameplayEventRuntime(Map<String, Object?> saved, _GameplayRuntime? gameplay) {
  if (gameplay == null || gameplay.activeSources.isEmpty || !saved.containsKey(_gameplayEventRuntimeKey)) {
    return false;
  }
  final raw = saved[_gameplayEventRuntimeKey];
  if (raw is! Map<String, Object?> || raw['bindings'] is! Map<String, Object?>) {
    return true;
  }
  final bindings = raw['bindings']! as Map<String, Object?>;
  for (final source in gameplay.activeSources) {
    if (!bindings.containsKey(source.bindingId)) {
      continue;
    }
    final row = bindings[source.bindingId];
    if (row is! Map<String, Object?> || row.containsKey('events')) {
      return true;
    }
  }
  return false;
}

state_core.CardEventSnapshot _inspectGameplayEvents(
  state_core.CardEventDefinition definition,
  Map<String, Object?> saved,
  _GameplayRuntime? gameplay,
) => definition.inspect(
  runtimeExists: saved.containsKey(_cardEventRuntimeKey),
  runtime: saved[_cardEventRuntimeKey],
  packRuntimeExists: gameplay != null && saved.containsKey(_gameplayEventRuntimeKey),
  packRuntime: gameplay == null ? null : saved[_gameplayEventRuntimeKey],
  activeSources: gameplay?.activeSources ?? const [],
);

/// The caller has already used the core's full event-domain inspection. This
/// projection does not validate a second time or create/reset a saved domain.
List<_GameplayPendingEventPrompt> _gameplayPendingEventPrompts(Object? raw, _GameplayRuntime? gameplay) {
  if (gameplay == null || raw is! Map<String, Object?> || raw['bindings'] is! Map<String, Object?>) {
    return [];
  }
  final bindings = raw['bindings']! as Map<String, Object?>;
  final result = <_GameplayPendingEventPrompt>[];
  for (final source in gameplay.activeSources) {
    final row = bindings[source.bindingId];
    if (row is! Map<String, Object?> ||
        row['installedPackId'] != source.installedPackId ||
        row['onceEpoch'] != source.onceEpoch ||
        row['events'] is! Map<String, Object?>) {
      continue;
    }
    final events = row['events']! as Map<String, Object?>;
    for (final prompt in _stateRows(events['pendingPrompts'])) {
      result.add((ref: (source: source, id: prompt['id']! as String), prompt: prompt));
    }
  }
  return result;
}

Map<String, Object?> _gameplayEventPromptRefJson(_GameplayEventPromptRef ref) => {
  'source': ref.source.toJson(),
  'id': ref.id,
};

state_core.StateExecutionSource? _gameplayEventEffectSource(Map<String, Object?> effect) {
  final raw = effect['executionSource'];
  if (raw is! Map<String, Object?> || raw['kind'] != 'pack') {
    return null;
  }
  return state_core.StateExecutionSource.pack(
    installedPackId: raw['installedPackId']! as String,
    bindingId: raw['bindingId']! as String,
    onceEpoch: raw['onceEpoch']! as int,
  );
}

/// next is already owned by this settlement. The accepted core candidate owns
/// all domains; this host step changes only the corresponding prompt queues.
bool _settleGameplayEventPrompts(
  Map<String, Object?> next,
  Set<_GameplayEventPromptRef> consumed,
  List<Map<String, Object?>> effects,
) {
  final prompts = <state_core.StateExecutionSource, List<Map<String, Object?>>>{};
  for (final effect in effects) {
    final source = _gameplayEventEffectSource(effect);
    if (source != null && effect['type'] == 'prompt') {
      (prompts[source] ??= []).add(effect);
    }
  }
  final sources = {for (final ref in consumed) ref.source, ...prompts.keys};
  if (sources.isEmpty) {
    return false;
  }
  final pack = next[_gameplayEventRuntimeKey]! as Map<String, Object?>;
  final bindings = pack['bindings']! as Map<String, Object?>;
  var changed = false;
  for (final source in sources) {
    final row = bindings[source.bindingId]! as Map<String, Object?>;
    final events = row['events']! as Map<String, Object?>;
    final old = _stateRows(events['pendingPrompts']);
    final pending = <Map<String, Object?>>[
      for (final prompt in old)
        if (!consumed.contains((source: source, id: prompt['id']! as String))) prompt,
      for (final prompt in prompts[source] ?? const <Map<String, Object?>>[])
        {
          'id': prompt['effectId'],
          'text': prompt['text'],
          'invocationId': prompt['invocationId'],
          'source': 'directorEvent',
          'executionSource': source.toJson(),
          'eventId': prompt['eventId'],
          'runId': prompt['runId'],
          'handlerId': prompt['handlerId'],
          'actionIndex': prompt['actionIndex'],
        },
    ];
    if (!_stateJsonEqual(old, pending)) {
      events['pendingPrompts'] = pending;
      changed = true;
    }
  }
  return changed;
}

Map<String, Object?> _unresolvedGameplayEventSnapshot(
  String? nodeId,
  Map<String, Object?> saved,
  Map<String, Object?> own,
  List<Map<String, Object?>> issues,
) => {
  'unresolved': true,
  'executable': false,
  'valid': false,
  'automaticEnabled': false,
  'nodeId': nodeId,
  'runtimeExists': saved.containsKey(_cardEventRuntimeKey),
  if (saved.containsKey(_cardEventRuntimeKey)) 'runtime': saved[_cardEventRuntimeKey],
  'packRuntimeExists': saved.containsKey(_gameplayEventRuntimeKey),
  if (saved.containsKey(_gameplayEventRuntimeKey)) 'packRuntime': saved[_gameplayEventRuntimeKey],
  'receipts': _stateRows(own['directorEventReceipts']),
  'effects': _stateRows(own['directorEventEffects']),
  'pendingConsumed': _strings(own['directorEventPendingConsumed']),
  'packPendingConsumed': _stateRows(own['directorEventPackPendingConsumed']),
  'issues': [...issues, ..._stateRows(own['directorEventIssues'])],
};
