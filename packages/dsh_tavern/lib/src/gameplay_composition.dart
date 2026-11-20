part of 'engine.dart';

typedef _GameplayPackInput = ({
  TavernGameplayScope scope,
  String? targetId,
  TavernPackBindingPreview binding,
  TavernPackVersion? version,
  Map<String, Uint8List> files,
});

typedef _GameplayCurrentValue = ({
  Map<String, Object?> source,
  bool valueExists,
  Object? value,
  List<Map<String, Object?>> issues,
});

typedef _GameplayLegacyResource = ({
  String kind,
  String bucket,
  Map<String, Object?> source,
  Map<String, Object?> resource,
  bool present,
  Object? raw,
  List<Map<String, Object?>> entries,
  List<Map<String, Object?>> issues,
});

typedef _GameplayCompositionContext = ({
  TavernGameplayContext request,
  String hostCharacterId,
  List<String> rosterCharacterIds,
  bool isGroup,
  bool regexEnabled,
  bool characterRegexEnabled,
  List<_GameplayLegacyResource> legacyResources,
  _GameplayCurrentValue? currentState,
  bool validateCurrentState,
});

final class _GameplayDeclaration {
  const _GameplayDeclaration({
    required this.source,
    required this.rawPresent,
    required this.raw,
    required this.roles,
    this.pack,
  });

  final Map<String, Object?> source;
  final bool rawPresent;
  final Object? raw;
  final List<String> roles;
  final _GameplayPackInput? pack;

  Map<String, Object?>? get fields => raw is Map<String, Object?> ? raw! as Map<String, Object?> : null;
  Object? get version => fields?.containsKey('v') == true ? fields!['v'] : 1;
  bool get active => pack == null || pack!.binding.enabled && pack!.version != null && !pack!.version!.removed;
  bool get eligible => (!rawPresent || fields != null) && version == 1;

  Map<String, Object?> toSourceJson() => {
    ...source,
    'roles': roles,
    'rawPresent': rawPresent,
    'raw': raw,
    if (pack case final input?) ...{
      'enabled': input.binding.enabled,
      'available': input.version != null,
      'removed': input.version?.removed,
      'digest': input.version?.digest,
      'aliases': input.binding.aliases,
      if (input.version?.manifest.containsKey('schemaPatches') == true)
        'schemaPatches': input.version!.manifest['schemaPatches'],
      if (input.version != null) 'inspection': input.version!.inspection,
    },
  };
}

/// Provenance follows replaced subtrees, without changing any source's raw IDs.
final class _GameplayFieldSources {
  final _values = <String, Map<String, Object?>>{};

  void put(String path, _GameplayDeclaration source, String sourcePath, {bool subtree = false, bool replaced = false}) {
    final shadowed = <Map<String, Object?>>[];
    if (replaced && !_values.containsKey(path)) {
      MapEntry<String, Map<String, Object?>>? inherited;
      for (final entry in _values.entries) {
        if (path.startsWith('${entry.key}/') && (inherited == null || entry.key.length > inherited.key.length)) {
          inherited = entry;
        }
      }
      if (inherited != null) {
        shadowed.add(inherited.value['winner']! as Map<String, Object?>);
      }
    }
    for (final key in _values.keys.toList()) {
      if (key == path || subtree && key.startsWith('$path/')) {
        final previous = _values.remove(key)!;
        shadowed.add(previous['winner']! as Map<String, Object?>);
        shadowed.addAll((previous['shadowed']! as List<Object?>).cast<Map<String, Object?>>());
      }
    }
    // One declaration may be shadowed through both a parent and a child.
    // Its source map is shared; retain each source once, in encounter order.
    _values[path] = {
      'path': path,
      'winner': source.source,
      'sourcePath': sourcePath,
      'shadowed': shadowed.toSet().toList(),
    };
  }

  Map<String, Object?> diagnostic(Map<String, Object?> issue, String path, _GameplayDeclaration fallback) {
    Map<String, Object?>? match;
    for (final entry in _values.entries) {
      if ((path == entry.key || path.startsWith('${entry.key}/')) &&
          (match == null || entry.key.length > (match['path']! as String).length)) {
        match = entry.value;
      }
    }
    final base = match?['path'] as String? ?? '';
    return {
      'diagnostic': issue,
      'source': match?['winner'] ?? fallback.source,
      'sourcePath': match == null ? path : '${match['sourcePath']}${path.substring(base.length)}',
    };
  }

  List<Map<String, Object?>> get values => _values.values.toList();
}

Map<String, Object?> _gameplayConflict(
  String code,
  String message, {
  _GameplayDeclaration? source,
  String? sourcePath,
}) => {'code': code, 'message': message, 'source': ?source?.source, 'sourcePath': ?sourcePath};

List<String>? _gameplayCompositionPointer(String path) {
  try {
    return _authoringPointer(path);
  } on TavernAuthoringException {
    return null;
  }
}

bool _gameplayPathPrefix(List<String> parent, List<String> child) {
  if (parent.length > child.length) {
    return false;
  }
  for (var i = 0; i < parent.length; i++) {
    if (parent[i] != child[i]) {
      return false;
    }
  }
  return true;
}

bool _gameplayObjectSchema(Object? raw) {
  if (raw is! Map<String, Object?> || raw.containsKey('properties') && raw['properties'] is! Map<String, Object?>) {
    return false;
  }
  if (!raw.containsKey('type')) {
    return raw['properties'] is Map<String, Object?> && !raw.containsKey('items');
  }
  final type = raw['type'];
  if (type == 'object') {
    return true;
  }
  return type is List<Object?> &&
      type.isNotEmpty &&
      type.contains('object') &&
      type.every((item) => item == 'object' || item == 'null') &&
      type.toSet().length == type.length;
}

({bool applied, bool replaced}) _gameplayPutSchemaChild(Object? schema, List<String> path, Object? value) {
  var parent = schema;
  for (var i = 0; i < path.length; i++) {
    if (!_gameplayObjectSchema(parent)) {
      return (applied: false, replaced: false);
    }
    final object = parent! as Map<String, Object?>;
    final rawProperties = object['properties'];
    if (i == path.length - 1) {
      final properties = rawProperties is Map<String, Object?> ? rawProperties : <String, Object?>{};
      final replaced = properties.containsKey(path[i]);
      properties[path[i]] = _authoringCopy(value);
      object['properties'] = properties;
      return (applied: true, replaced: replaced);
    }
    if (rawProperties is! Map<String, Object?> || !rawProperties.containsKey(path[i])) {
      return (applied: false, replaced: false);
    }
    parent = rawProperties[path[i]];
  }
  return (applied: false, replaced: false);
}

String _gameplaySchemaPath(List<String> path) =>
    '/state/schema${[for (final token in path) '/properties/${_gameplayPointerToken(token)}'].join()}';

List<({List<String> path, Object? node, int index})>? _gameplaySchemaPatches(
  _GameplayDeclaration source,
  List<Map<String, Object?>> conflicts,
) {
  final raw = source.pack!.version!.manifest['schemaPatches'] as List<Object?>? ?? const <Object?>[];
  final result = <({List<String> path, Object? node, int index})>[];
  var valid = true;
  for (final (index, item) in raw.indexed) {
    final path = item is Map<String, Object?> && item['path'] is String
        ? _gameplayCompositionPointer(item['path']! as String)
        : null;
    if (path == null || item is! Map<String, Object?> || !item.containsKey('node')) {
      conflicts.add(
        _gameplayConflict(
          'schema_patch_shape',
          'A schema patch requires an escaped state-value pointer and a complete node.',
          source: source,
          sourcePath: '/schemaPatches/$index',
        ),
      );
      valid = false;
      continue;
    }
    if (result.any(
      (previous) => _gameplayPathPrefix(previous.path, path) || _gameplayPathPrefix(path, previous.path),
    )) {
      conflicts.add(
        _gameplayConflict(
          'schema_patch_overlap',
          'Schema roots within one source must not overlap.',
          source: source,
          sourcePath: '/schemaPatches/$index/path',
        ),
      );
      valid = false;
    }
    result.add((path: path, node: item['node'], index: index));
  }
  return valid ? result : null;
}

List<Map<String, Object?>> _gameplayNativeIssues(
  List<Map<String, Object?>> issues,
  _GameplayDeclaration source,
  String base,
) => [
  for (final issue in issues)
    {'diagnostic': issue, 'source': source.source, 'sourcePath': '$base${issue['path'] ?? ''}'},
];

Map<String, Object?> _gameplayDefinition(
  String path, {
  required bool present,
  required bool? executable,
  List<Map<String, Object?>> issues = const [],
  _GameplayDeclaration? source,
}) => {'path': path, 'present': present, 'executable': executable, 'issues': issues, 'source': ?source?.source};

bool _gameplayDefinitionScope(_GameplayPackInput input, _GameplayCompositionContext context) =>
    input.scope != TavernGameplayScope.character || input.targetId == context.hostCharacterId;

List<_GameplayDeclaration> _gameplayDeclarations(
  List<_GameplayPackInput> snapshot,
  Map<String, Map<String, Object?>?> cards,
  _GameplayCompositionContext context,
) {
  final result = <_GameplayDeclaration>[];
  for (final entry in cards.entries) {
    final data = entry.value;
    final extensions = data is Map<String, Object?> ? data['extensions'] : null;
    final present = extensions is Map<String, Object?> && extensions.containsKey('dshgo');
    result.add(
      _GameplayDeclaration(
        source: {'kind': 'card', 'characterId': entry.key},
        rawPresent: present,
        raw: extensions is Map<String, Object?> ? extensions['dshgo'] : null,
        roles: [
          if (entry.key == context.hostCharacterId) 'host',
          if (entry.key == context.request.characterId) 'actor',
          if (context.isGroup && context.rosterCharacterIds.contains(entry.key)) 'roster',
        ],
      ),
    );
  }
  for (final input in snapshot) {
    final manifest = input.version?.manifest;
    final present = manifest?.containsKey('dshgo') ?? false;
    result.add(
      _GameplayDeclaration(
        source: {
          'kind': 'pack',
          'scope': input.scope.name,
          'targetId': ?input.targetId,
          'bindingId': input.binding.bindingId,
          'packRef': input.binding.packRef.toJson(),
        },
        rawPresent: present,
        raw: present ? manifest!['dshgo'] : null,
        roles: [
          if (_gameplayDefinitionScope(input, context)) 'definition',
          if (input.scope != TavernGameplayScope.character || input.targetId == context.request.characterId) 'regex',
          if (input.scope != TavernGameplayScope.character ||
              (context.isGroup ? context.rosterCharacterIds : [context.request.characterId]).contains(input.targetId))
            'worldInfo',
        ],
        pack: input,
      ),
    );
  }
  return result;
}

TavernGameplayResolution _composeGameplay(
  List<_GameplayPackInput> snapshot,
  Map<String, _AuthoringCapturedResource> capturedCards,
  _GameplayCompositionContext context, {
  Map<String, Object?>? bindingIdentity,
}) => _composeGameplayData(
  snapshot,
  {for (final entry in capturedCards.entries) entry.key: entry.value.document?['data'] as Map<String, Object?>?},
  context,
  bindingIdentity: bindingIdentity,
);

/// Both preview and an admitted execution use the same owned card declarations.
TavernGameplayResolution _composeGameplayData(
  List<_GameplayPackInput> snapshot,
  Map<String, Map<String, Object?>?> cards,
  _GameplayCompositionContext context, {
  Map<String, Object?>? bindingIdentity,
  bool includeResources = true,
}) {
  final sources = _gameplayDeclarations(snapshot, cards, context);
  final host = sources.firstWhere((source) => source.pack == null && source.roles.contains('host'));
  final declarationSources = [
    host,
    for (final source in sources)
      if (source.pack != null && source.roles.contains('definition') && source.active) source,
  ];
  final conflicts = <Map<String, Object?>>[];
  final provenance = _GameplayFieldSources();
  final definitions = <Map<String, Object?>>[];
  var stateEligible = true;
  var eventsEligible = true;
  for (final source in sources) {
    final input = source.pack;
    if (input != null && input.binding.enabled && (input.version == null || input.version!.removed)) {
      conflicts.add(
        _gameplayConflict(
          input.version == null ? 'version_not_found' : 'version_removed',
          'The proposed version is unavailable and contributes no configuration.',
          source: source,
        ),
      );
      if (source.roles.contains('definition')) {
        stateEligible = false;
        eventsEligible = false;
      }
    }
  }
  for (final source in declarationSources) {
    if (!source.eligible) {
      conflicts.add(
        _gameplayConflict(
          source.rawPresent && source.fields == null ? 'dshgo_source_shape' : 'dshgo_source_version',
          'This source is preserved but cannot contribute executable declarations.',
          source: source,
          sourcePath: '',
        ),
      );
      stateEligible = false;
      eventsEligible = false;
    }
  }

  final effective = host.fields == null ? <String, Object?>{} : _authoringCopy(host.fields)! as Map<String, Object?>;
  final owners = <String, _GameplayDeclaration>{};
  void own(String path, _GameplayDeclaration source, {bool subtree = false}) {
    if (subtree) {
      owners.removeWhere((key, _) => key.startsWith('$path/'));
    }
    owners[path] = source;
    provenance.put(path, source, path, subtree: subtree);
  }

  for (final entry in host.fields?.entries ?? const <MapEntry<String, Object?>>[]) {
    own('/${_gameplayPointerToken(entry.key)}', host);
  }
  final originalState = host.fields?['state'];
  var statePresent = host.fields?.containsKey('state') ?? false;
  Object? state = _authoringCopy(originalState);
  var schemaPresent = originalState is Map<String, Object?> && originalState.containsKey('schema');
  Object? schema = state is Map<String, Object?> ? state['schema'] : null;
  if (originalState is Map<String, Object?>) {
    for (final key in originalState.keys) {
      own('/state/${_gameplayPointerToken(key)}', host);
    }
  } else if (statePresent) {
    conflicts.add(
      _gameplayConflict(
        'state_source_shape',
        'An explicit state declaration must be an object; absence and null are different.',
        source: host,
        sourcePath: '/state',
      ),
    );
    stateEligible = false;
  }
  final ruleSources = <state_core.StateCompositionRuleSource>[
    if (host.eligible && originalState is Map<String, Object?>)
      (source: host.source, sourcePath: '/state', state: originalState),
  ];

  final eventSources = <_GameplayDeclaration>[];
  final originalDirector = host.fields?['director'];
  if (originalDirector is Map<String, Object?>) {
    for (final key in originalDirector.keys) {
      own('/director/${_gameplayPointerToken(key)}', host);
    }
    if (originalDirector.containsKey('eventRules')) {
      eventSources.add(host);
    }
  } else if (host.fields?.containsKey('director') ?? false) {
    conflicts.add(
      _gameplayConflict(
        'director_source_shape',
        'An explicit director carrier must be an object.',
        source: host,
        sourcePath: '/director',
      ),
    );
    eventsEligible = false;
  }

  for (final source in declarationSources.skip(1)) {
    if (!source.eligible) {
      continue;
    }
    final fields = source.fields;
    for (final entry in fields?.entries ?? const <MapEntry<String, Object?>>[]) {
      final key = entry.key;
      if (const {'v', 'state', 'director', 'tools', 'components', 'dice'}.contains(key)) {
        continue;
      }
      effective[key] = _authoringCopy(entry.value);
      own('/${_gameplayPointerToken(key)}', source, subtree: true);
    }
    if (fields?.containsKey('tools') ?? false) {
      conflicts.add(
        _gameplayConflict(
          'not_composed',
          'Pack tools do not replace the original card policy or grant a permission.',
          source: source,
          sourcePath: '/tools',
        ),
      );
    }
    if (fields?.containsKey('director') ?? false) {
      final raw = fields!['director'];
      if (raw is Map<String, Object?>) {
        final previous = effective['director'];
        final director = previous is Map<String, Object?> ? previous : <String, Object?>{};
        for (final entry in raw.entries) {
          if (entry.key != 'eventRules') {
            director[entry.key] = _authoringCopy(entry.value);
            own('/director/${_gameplayPointerToken(entry.key)}', source, subtree: true);
          }
        }
        effective['director'] = director;
        if (raw.containsKey('eventRules')) {
          eventSources.add(source);
        }
      } else {
        effective['director'] = _authoringCopy(raw);
        own('/director', source, subtree: true);
        conflicts.add(
          _gameplayConflict(
            'director_source_shape',
            'An explicit director carrier must be an object.',
            source: source,
            sourcePath: '/director',
          ),
        );
        eventsEligible = false;
      }
    }

    final declaredState = fields?['state'];
    final hasState = fields?.containsKey('state') ?? false;
    final patches = source.pack!.version!.manifest['schemaPatches'] as List<Object?>? ?? const <Object?>[];
    statePresent = statePresent || hasState || patches.isNotEmpty;
    if (hasState && declaredState is! Map<String, Object?>) {
      conflicts.add(
        _gameplayConflict(
          'state_source_shape',
          'An explicit state declaration must be an object; absence and null are different.',
          source: source,
          sourcePath: '/state',
        ),
      );
      stateEligible = false;
      continue;
    }
    final nextState = state is Map<String, Object?> ? state : <String, Object?>{};
    if (declaredState is Map<String, Object?>) {
      if (declaredState.containsKey('schema') && patches.isEmpty) {
        conflicts.add(
          _gameplayConflict(
            'schema_roots_required',
            'A pack schema needs explicit schemaPatches paths; its root is not inferred.',
            source: source,
            sourcePath: '/state/schema',
          ),
        );
        stateEligible = false;
      }
      for (final entry in declaredState.entries) {
        if (entry.key != 'schema' && entry.key != 'rules') {
          nextState[entry.key] = _authoringCopy(entry.value);
          own('/state/${_gameplayPointerToken(entry.key)}', source, subtree: true);
        }
      }
      ruleSources.add((source: source.source, sourcePath: '/state', state: declaredState));
    }
    final parsed = _gameplaySchemaPatches(source, conflicts);
    if (parsed == null) {
      stateEligible = false;
    } else {
      for (final patch in parsed) {
        final bool replaced;
        if (patch.path.isEmpty) {
          replaced = schemaPresent;
          schema = _authoringCopy(patch.node);
          schemaPresent = true;
        } else {
          final edit = schemaPresent
              ? _gameplayPutSchemaChild(schema, patch.path, patch.node)
              : (applied: false, replaced: false);
          if (!edit.applied) {
            conflicts.add(
              _gameplayConflict(
                'schema_parent',
                'A child patch requires an existing object-schema parent and cannot create intermediate parents.',
                source: source,
                sourcePath: '/schemaPatches/${patch.index}/path',
              ),
            );
            stateEligible = false;
            continue;
          }
          replaced = edit.replaced;
        }
        provenance.put(
          _gameplaySchemaPath(patch.path),
          source,
          '/schemaPatches/${patch.index}/node',
          subtree: true,
          replaced: replaced,
        );
      }
    }
    state = nextState;
  }

  if (state is Map<String, Object?>) {
    if (schemaPresent) {
      state['schema'] = schema;
    }
    if (ruleSources.any((source) => source.state.containsKey('rules'))) {
      // Display union only. Compilation below retains each original list and
      // never parses this flattened view as one legacy declaration.
      state['rules'] = ruleSources.length == 1
          ? _authoringCopy(ruleSources.single.state['rules'])
          : [
              for (final source in ruleSources)
                if (source.state['rules'] case final List<Object?> rules) ...rules,
            ];
      var displayIndex = 0;
      for (final source in ruleSources) {
        final original = source.state['rules'];
        if (original is! List<Object?>) {
          continue;
        }
        final owner = declarationSources.firstWhere((item) => identical(item.source, source.source));
        for (var index = 0; index < original.length; index++) {
          provenance.put('/state/rules/${displayIndex++}', owner, '/state/rules/$index');
        }
      }
    }
  }
  if (statePresent) {
    effective['state'] = state;
  }
  for (final source in declarationSources) {
    if (source.pack == null || !source.eligible || source.fields?['state'] is! Map<String, Object?>) {
      continue;
    }
    final rules = (source.fields!['state']! as Map<String, Object?>)['rules'];
    if (rules is List<Object?>) {
      for (final (index, rule) in rules.indexed) {
        if (rule is Map<String, Object?> && rule['id'] is! String) {
          conflicts.add(
            _gameplayConflict(
              'rule_identity_required',
              'Pack rules require an explicit string id; original positions and slots are retained.',
              source: source,
              sourcePath: '/state/rules/$index/id',
            ),
          );
        }
      }
    }
  }

  final director = effective['director'];
  final directorFields = director is Map<String, Object?> ? director : null;
  final secretOwner = owners['/director/secretSlots'] ?? owners['/director'] ?? host;
  final checked = state_core.inspectStateComposition(
    state,
    version: host.version,
    sources: ruleSources,
    compositionEligible: stateEligible,
    validateValue: context.validateCurrentState && context.currentState != null,
    valueExists: context.currentState?.valueExists ?? false,
    value: context.currentState?.value,
    secretSlots: directorFields?['secretSlots'],
    secretVersion: secretOwner.version,
  );
  final stateIssues = <Map<String, Object?>>[
    for (final issue in checked.definitionIssues) provenance.diagnostic(issue, '/state${issue['path'] ?? ''}', host),
    ...checked.ruleIssues,
  ];
  final rules = <Map<String, Object?>>[];
  for (final rule in checked.rules) {
    final sourceRef = rule['source']! as Map<String, Object?>;
    final source = declarationSources.firstWhere((item) => identical(item.source, sourceRef));
    final original = (source.fields!['state']! as Map<String, Object?>)['rules']! as List<Object?>;
    final declaration = original[rule['index']! as int]! as Map<String, Object?>;
    rules.add({
      ...rule,
      'compositionEligible': source.pack == null || declaration['id'] is String,
      if (declaration['id'] is String) 'localId': declaration['id'],
    });
  }
  definitions.add({
    ..._gameplayDefinition('/state', present: statePresent, executable: checked.executable, issues: stateIssues),
    'compositionEligible': stateEligible,
    'rules': rules,
  });

  final storyOwner = owners['/story'] ?? host;
  final story = story_core.StoryDefinition.parse(effective['story'], version: storyOwner.version);
  definitions.add(
    _gameplayDefinition(
      '/story',
      present: effective.containsKey('story'),
      executable: story.executable,
      issues: _gameplayNativeIssues(story.issues, storyOwner, '/story'),
      source: storyOwner,
    ),
  );
  final eventFacts = _gameplayEventDefinitions(eventSources, eventsEligible, conflicts);
  definitions.add(eventFacts.definition);
  if (eventFacts.display != null && directorFields != null) {
    directorFields['eventRules'] = eventFacts.display;
  }
  definitions.add(
    _gameplayDefinition(
      '/director/secretSlots',
      present: directorFields?.containsKey('secretSlots') ?? false,
      executable: checked.secretExecutable,
      issues: _gameplayNativeIssues(checked.secretIssues, secretOwner, '/director/secretSlots'),
      source: secretOwner,
    ),
  );
  final cadence = director_core.directorEvery(card: directorFields ?? const {});
  definitions.add(
    _gameplayDefinition(
      '/director/every',
      present: directorFields?.containsKey('every') ?? false,
      executable: null,
      issues: [
        if (cadence.invalid)
          provenance.diagnostic({'kind': 'director', 'code': 'invalid_director_every'}, '/director/every', host),
      ],
    ),
  );
  final cardData = cards[context.hostCharacterId]!;
  final tools = parseToolCardDeclaration(cardData);
  definitions.add(
    _gameplayDefinition(
      '/tools',
      present: host.fields?.containsKey('tools') ?? false,
      executable: null,
      source: host,
      issues: [
        for (final issue in tools['diagnostics']! as List<Map<String, Object?>>)
          {
            'diagnostic': issue,
            'source': host.source,
            'sourcePath': _gameplayToolSourcePath(issue['fieldPath']! as String),
            if (issue['fieldPath'] == 'extensions') 'sourceRoot': 'cardData',
          },
      ],
    ),
  );
  if (effective.containsKey('cast')) {
    final inspection = inspectDshgoExtension({'cast': effective['cast']});
    final block = inspection.blocks.firstWhere((item) => item.path == '/cast');
    definitions.add(
      _gameplayDefinition(
        '/cast',
        present: true,
        executable: block.executable,
        issues: [
          for (final issue in block.issues)
            provenance.diagnostic(issue, issue['sourcePath']! as String, owners['/cast'] ?? host),
        ],
      ),
    );
  }
  _gameplayAppItems(declarationSources, effective, definitions, provenance);
  final resources = includeResources
      ? _gameplayResourcePlan(
          sources,
          regexEnabled: context.regexEnabled,
          characterRegexEnabled: context.characterRegexEnabled,
          legacyResources: context.legacyResources,
        )
      : <Map<String, Object?>>[];
  _gameplayReferences(declarationSources, sources, host, eventFacts.names, definitions, conflicts);

  final current = context.currentState;
  final currentState = current == null
      ? null
      : (
          source: current.source,
          valueExists: current.valueExists,
          value: current.value,
          validated: checked.validated,
          issues: <Map<String, Object?>>[
            for (final issue in current.issues)
              {'diagnostic': issue, 'source': current.source, 'sourcePath': issue['path'] ?? ''},
            for (final issue in checked.valueIssues)
              {
                'diagnostic': issue,
                'source': current.source,
                'sourcePath': '/messageVariables/dshgo${issue['path'] ?? ''}',
              },
          ],
        );
  final sourceJson = [for (final source in sources) source.toSourceJson()];
  final identity = _directorHash(
    _gameplayConfigurationIdentity(
      cards,
      context,
      sourceJson,
      effective,
      definitions,
      provenance.values,
      conflicts,
      bindingIdentity: bindingIdentity,
    ),
  );
  if (context.validateCurrentState && current == null) {
    conflicts.add(
      _gameplayConflict(
        'not_available',
        'Value validation needs an actual chat state carrier; no sample value is initialized.',
      ),
    );
  }
  return TavernGameplayResolution(
    context: context.request,
    hostCharacterId: context.hostCharacterId,
    rawPresent: host.rawPresent,
    raw: host.raw,
    effective: effective,
    sources: sourceJson,
    fieldSources: provenance.values,
    resources: resources,
    definitions: definitions,
    conflicts: conflicts,
    currentState: currentState,
    effectiveConfigId: identity,
  );
}

/// A definition configuration is host-scoped even when another group member
/// speaks. Public resource views retain their actual actor/regex/WI roles;
/// persisted explanation sources retain only roles used to authorize definitions.
List<Map<String, Object?>> _gameplayDefinitionSources(List<Map<String, Object?>> sources) {
  final cards = sources.where((row) => row['kind'] == 'card').toList()
    ..sort((left, right) => (left['characterId']! as String).compareTo(right['characterId']! as String));
  return [
    for (final row in [...cards, ...sources.where((row) => row['kind'] != 'card')])
      {
        ...row,
        'roles': [
          for (final role in row['roles']! as List<Object?>)
            if (role == 'host' || role == 'definition') role,
        ],
      },
  ];
}

/// The definition identity omits preview-only file witnesses, current-value
/// diagnostics and the speaking actor's resource roles. Source membership,
/// availability and stable mappings still distinguish equal flattened values.
Map<String, Object?> _gameplayConfigurationIdentity(
  Map<String, Map<String, Object?>?> cards,
  _GameplayCompositionContext context,
  List<Map<String, Object?>> sources,
  Map<String, Object?> effective,
  List<Map<String, Object?>> definitions,
  List<Map<String, Object?>> fieldSources,
  List<Map<String, Object?>> conflicts, {
  Map<String, Object?>? bindingIdentity,
}) => {
  'v': 1,
  'hostCharacterId': context.hostCharacterId,
  'chatId': context.request.chatId,
  'isGroup': context.isGroup,
  'rosterCharacterIds': context.rosterCharacterIds,
  'cards': {
    for (final entry in cards.entries)
      entry.key: {
        'present': entry.value != null,
        'extensionsPresent': entry.value?.containsKey('extensions') ?? false,
        'extensions': entry.value?['extensions'],
      },
  },
  'bindings': bindingIdentity,
  'sources': _gameplayDefinitionSources(sources),
  'effective': effective,
  'definitions': definitions,
  'fieldSources': fieldSources,
  'conflicts': conflicts,
};

({Map<String, Object?> definition, Map<String, Object?>? display, Map<_GameplayDeclaration, Set<String>> names})
_gameplayEventDefinitions(
  List<_GameplayDeclaration> sources,
  bool compositionEligible,
  List<Map<String, Object?>> conflicts,
) {
  final registries = <Map<String, Object?>>[];
  final displayRules = <Object?>[];
  final names = <_GameplayDeclaration, Set<String>>{};
  var count = 0;
  for (final source in sources) {
    final director = source.fields!['director']! as Map<String, Object?>;
    final raw = director['eventRules'];
    final parsed = state_core.CardEventDefinition.parse(raw, version: source.version);
    final rules = raw is Map<String, Object?> ? raw['rules'] : null;
    final handlers = <Map<String, Object?>>[];
    final surviving = parsed.handlerIds.toSet();
    final eventNames = <String>{};
    if (rules is List<Object?>) {
      count += rules.length;
      for (final (index, rule) in rules.indexed) {
        if (rule is Map<String, Object?> && surviving.contains(rule['id'])) {
          handlers.add({
            'index': index,
            'localId': rule['id'],
            'name': rule['name'],
            'sourcePath': '/director/eventRules/rules/$index',
          });
          eventNames.add(rule['name']! as String);
        }
      }
      if (source.eligible && parsed.executable) {
        displayRules.addAll(rules);
      }
    }
    names[source] = source.eligible && parsed.executable ? eventNames : <String>{};
    registries.add({
      'source': source.source,
      'raw': raw,
      'executable': parsed.executable,
      'issues': _gameplayNativeIssues(parsed.issues, source, '/director/eventRules'),
      'handlers': handlers,
    });
    if (!source.eligible || raw is! Map<String, Object?> || !parsed.executable) {
      compositionEligible = false;
    }
  }
  if (count > 256) {
    compositionEligible = false;
    conflicts.add(
      _gameplayConflict(
        'event_rules_composition_limit',
        'The composed event registries exceed the existing 256 declaration limit.',
      ),
    );
  }
  return (
    definition: {
      ..._gameplayDefinition('/director/eventRules', present: sources.isNotEmpty, executable: null),
      'compositionEligible': compositionEligible,
      'registries': registries,
    },
    display: sources.isEmpty ? null : <String, Object?>{'v': 1, 'rules': displayRules},
    names: names,
  );
}

List<Map<String, Object?>> _gameplayResourcePlan(
  List<_GameplayDeclaration> sources, {
  required bool regexEnabled,
  required bool characterRegexEnabled,
  List<_GameplayLegacyResource> legacyResources = const [],
  Set<String>? kinds,
  Map<(String, String, String), ({Object error, StackTrace stack})> resourceErrors = const {},
}) {
  final books = <Map<String, Object?>>[];
  final regex = <Map<String, Object?>>[];
  final app = <Map<String, Object?>>[];
  for (final source in sources) {
    final input = source.pack;
    if (input == null || !source.active) {
      continue;
    }
    final version = input.version!;
    final inspections = <String, Map<String, Object?>>{};
    for (final rawInspection in version.inspection['resources']! as List<Object?>) {
      final item = rawInspection! as Map<String, Object?>;
      inspections[item['localId']! as String] = item;
    }
    for (final resource in gameplayPackResources(version.manifest)) {
      final kind = resource['kind']! as String;
      if (kinds != null && !kinds.contains(kind)) {
        continue;
      }
      if (kind == 'lorebook' && !source.roles.contains('worldInfo') ||
          kind == 'regex' && !source.roles.contains('regex')) {
        continue;
      }
      final failure =
          resourceErrors[(
            input.binding.packRef.installedPackId,
            input.binding.packRef.packVersion,
            resource['path']! as String,
          )];
      if (failure != null) {
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
      final localId = resource['localId']! as String;
      final saved = inspections[localId]!;
      final bucket = input.scope.name;
      final entries = <Map<String, Object?>>[];
      Object? raw;
      var enabled = true;
      if (kind == 'lorebook' || kind == 'regex' || kind == 'castCard') {
        final text = decodeAuthoringText(input.files[resource['path']]!).text;
        raw = kind == 'regex'
            ? jsonDecode(text)
            : _decodeObject(text, kind == 'lorebook' ? 'Gameplay lorebook' : 'Gameplay cast card');
      }
      final mappings = <String, String>{};
      for (final rawMapping in resource['entries'] as List<Object?>? ?? const <Object?>[]) {
        final item = rawMapping! as Map<String, Object?>;
        mappings[item['pointer']! as String] = item['localId']! as String;
      }
      if (kind == 'lorebook') {
        final book = WorldInfoBook.fromJson(
          id: localId,
          source: WorldInfoSource.values.byName(bucket),
          json: raw! as Map<String, Object?>,
        );
        raw = book.raw;
        for (final entry in _gameplayLegacyBookEntries(book)) {
          entries.add({...entry, 'localId': mappings[entry['pointer']]!});
        }
      } else if (kind == 'regex') {
        enabled = input.scope == TavernGameplayScope.character ? characterRegexEnabled : regexEnabled;
        final diagnostics = (saved['regexDiagnostics']! as List<Object?>).cast<Map<String, Object?>>();
        void addRule(Map<String, Object?> item, String pointer, int index, List<Map<String, Object?>> issues) {
          final incompatible = issues.any((issue) => issue['status'] == 'incompatible');
          final execution = RegexScript.fromJson({...item, if (incompatible) 'disabled': true});
          entries.add({
            'index': index,
            'pointer': pointer,
            'localId': mappings[pointer] ?? localId,
            'stId': execution.id,
            'raw': item,
            'disabled': execution.disabled,
            'effective': enabled && !execution.disabled,
            'diagnostics': issues,
          });
        }

        if (raw is Map<String, Object?>) {
          addRule(raw, '', 0, diagnostics);
        } else {
          for (final (index, item) in (raw! as List<Object?>).indexed) {
            if (item is Map<String, Object?>) {
              // The saved intake keeps one diagnostic for every original
              // list position, including non-object positions.
              addRule(item, '/$index', index, [diagnostics[index]]);
            }
          }
        }
      }
      final row = <String, Object?>{
        'kind': kind,
        'bucket': kind == 'lorebook' || kind == 'regex' ? bucket : 'app',
        'source': source.source,
        'resource': {...resource, 'phase': 'pack', 'enabled': enabled},
        'present': true,
        'raw': raw,
        'entries': entries,
        'issues': <Map<String, Object?>>[],
        'inspection': saved,
      };
      if (kind == 'lorebook') {
        books.add(row);
      } else if (kind == 'regex') {
        regex.add(row);
      } else {
        app.add(row);
      }
    }
  }
  Map<String, Object?> legacy(_GameplayLegacyResource row) => {
    'kind': row.kind,
    'bucket': row.bucket,
    'source': row.source,
    'resource': row.resource,
    'present': row.present,
    'raw': row.raw,
    'entries': row.entries,
    'issues': row.issues,
  };
  final result = <Map<String, Object?>>[];
  result.addAll(
    _gameplayWorldInfoOrder(
      [
        for (final row in legacyResources)
          if (row.kind == 'lorebook' && row.resource['phase'] == 'linked') legacy(row),
      ],
      [
        for (final row in legacyResources)
          if (row.kind == 'lorebook' && row.resource['phase'] == 'embedded') legacy(row),
      ],
      books,
      (row) => row['bucket']! as String,
    ),
  );
  for (final bucket in const ['global', 'managed', 'preset', 'character']) {
    result.addAll([
      for (final row in legacyResources)
        if (row.kind == 'regex' && row.bucket == bucket) legacy(row),
    ]);
    if (bucket == 'managed') {
      result.addAll(regex.where((row) => row['bucket'] == 'global'));
    } else if (bucket == 'character') {
      result.addAll(regex.where((row) => row['bucket'] == 'character'));
    }
  }
  result.addAll(regex.where((row) => row['bucket'] == 'chat'));
  result.addAll(app);
  return result;
}

/// App declarations are displayed under their real source/local ID pair.
/// These data rows do not execute components, skills, or quick replies.
void _gameplayAppItems(
  List<_GameplayDeclaration> sources,
  Map<String, Object?> effective,
  List<Map<String, Object?>> definitions,
  _GameplayFieldSources provenance,
) {
  for (final path in const ['/components/custom', '/dice/skills']) {
    final items = <Map<String, Object?>>[];
    for (final source in sources) {
      if (!source.eligible) {
        continue;
      }
      final fields = source.fields;
      if (path == '/components/custom') {
        final components = fields?['components'];
        final custom = components is Map<String, Object?> ? components['custom'] : null;
        if (custom is List<Object?>) {
          for (final (index, raw) in custom.indexed) {
            items.add({
              'source': source.source,
              'sourcePath': '/components/custom/$index',
              'raw': raw,
              if (raw is Map<String, Object?> && raw['id'] is String) 'localId': raw['id'],
            });
          }
        }
      } else {
        final dice = fields?['dice'];
        final skills = dice is Map<String, Object?> ? dice['skills'] : null;
        if (skills is Map<String, Object?>) {
          for (final entry in skills.entries) {
            items.add({
              'source': source.source,
              'sourcePath': '/dice/skills/${_gameplayPointerToken(entry.key)}',
              'localId': entry.key,
              'raw': entry.value,
            });
          }
        }
      }
    }
    final tokens = _gameplayCompositionPointer(path)!;
    final present = sources.any((source) => source.eligible && _authoringLookup(source.raw, tokens).exists);
    definitions.add({..._gameplayDefinition(path, present: present, executable: null), 'items': items});
  }
  // Ordinary App fields use explicit whole-field priority. The two named
  // collections above retain all sources and are not keyed by raw ID alone.
  for (final domain in const ['components', 'dice']) {
    final result = <String, Object?>{};
    var found = false;
    for (final source in sources) {
      if (!source.eligible || !(source.fields?.containsKey(domain) ?? false)) {
        continue;
      }
      found = true;
      final value = source.fields![domain];
      if (value is! Map<String, Object?>) {
        effective[domain] = _authoringCopy(value);
        provenance.put('/$domain', source, '/$domain', subtree: true);
        result.clear();
        continue;
      }
      for (final entry in value.entries) {
        final path = '/$domain/${_gameplayPointerToken(entry.key)}';
        provenance.put(path, source, path, subtree: true, replaced: result.containsKey(entry.key));
        result[entry.key] = _authoringCopy(entry.value);
      }
      effective[domain] = result;
    }
    if (!found) {
      effective.remove(domain);
    }
  }
}

void _gameplayReferences(
  List<_GameplayDeclaration> sources,
  List<_GameplayDeclaration> availableSources,
  _GameplayDeclaration host,
  Map<_GameplayDeclaration, Set<String>> eventNames,
  List<Map<String, Object?>> definitions,
  List<Map<String, Object?>> conflicts,
) {
  final byBinding = {
    for (final source in availableSources)
      if (source.pack != null) source.pack!.binding.bindingId: source,
  };
  final references = <Map<String, Object?>>[];
  for (final source in sources) {
    final input = source.pack;
    if (input == null || !source.eligible) {
      continue;
    }
    final declared = input.version!.manifest['references'] as List<Object?>? ?? const <Object?>[];
    final seen = <String>{};
    for (final (index, raw) in declared.indexed) {
      final path = '/references/$index';
      final rawPointer = raw is Map<String, Object?> ? raw['pointer'] : null;
      final pointer = rawPointer is String ? rawPointer : null;
      final tokens = pointer == null ? null : _gameplayCompositionPointer(pointer);
      final supportedEvent = tokens != null && _gameplayReferencePosition(source.raw, 'event', tokens);
      void retainUnresolvedEvent() {
        if (supportedEvent) {
          // An explicit but malformed/ambiguous reference at a real event
          // position cannot fall back to that source's unqualified raw name.
          references.add({
            'source': source.source,
            'sourcePath': path,
            'pointer': pointer,
            'kind': 'event',
            'resolved': false,
          });
        }
      }

      if (raw is! Map<String, Object?> ||
          pointer == null ||
          raw['kind'] is! String ||
          raw['source'] is! String ||
          raw['localId'] is! String) {
        conflicts.add(
          _gameplayConflict(
            'unsupported_reference',
            'A reference requires pointer, kind, source, and localId strings.',
            source: source,
            sourcePath: path,
          ),
        );
        retainUnresolvedEvent();
        continue;
      }
      final kind = raw['kind']! as String;
      if (tokens == null || !seen.add(pointer) || !_gameplayReferencePosition(source.raw, kind, tokens)) {
        conflicts.add(
          _gameplayConflict(
            'unsupported_reference',
            'This reference is not at a supported original declaration position.',
            source: source,
            sourcePath: path,
          ),
        );
        retainUnresolvedEvent();
        continue;
      }
      final targetName = raw['source']! as String;
      final _GameplayDeclaration? target = switch (targetName) {
        'self' => source,
        'card' => host,
        _ => byBinding[input.binding.aliases[targetName]],
      };
      final localId = raw['localId']! as String;
      var resolved = target != null && target.active && target.eligible;
      if (resolved) {
        if (kind == 'event') {
          resolved = eventNames[target]?.contains(localId) ?? false;
        } else if (kind == 'component') {
          final components = target.fields?['components'];
          final custom = components is Map<String, Object?> ? components['custom'] : null;
          resolved =
              custom is List<Object?> &&
              custom.where((item) => item is Map<String, Object?> && item['id'] == localId).length == 1;
        } else if (kind == 'asset') {
          // CCv3 card assets have no catalog localId mapping. Neither a name,
          // URI nor an unknown extra field invents that identity here.
          final manifest = target.pack?.version?.manifest;
          resolved =
              manifest != null &&
              gameplayPackResources(manifest).any((item) => item['kind'] == 'asset' && item['localId'] == localId);
        }
      }
      if (!resolved) {
        conflicts.add(
          _gameplayConflict(
            'unresolved_reference',
            'The declared source/localId is not an available target in this composition.',
            source: source,
            sourcePath: path,
          ),
        );
      }
      references.add({
        'source': source.source,
        'sourcePath': path,
        'pointer': pointer,
        'kind': kind,
        'localId': localId,
        'resolved': resolved,
        'target': ?target?.source,
      });
    }
  }
  definitions.add({
    ..._gameplayDefinition('/references', present: references.isNotEmpty, executable: null),
    'items': references,
  });
}

bool _gameplayReferencePosition(Object? raw, String kind, List<String> tokens) {
  final found = _authoringLookup(raw, tokens);
  if (!found.exists) {
    return false;
  }
  bool arrayItem(int position) {
    final parent = _authoringLookup(raw, tokens.sublist(0, position)).value;
    return parent is List<Object?> && _authoringIndex(tokens[position], parent.length) != null;
  }

  if (kind == 'event') {
    if (tokens.length == 5 &&
        tokens[0] == 'director' &&
        tokens[1] == 'eventRules' &&
        tokens[2] == 'rules' &&
        arrayItem(3) &&
        tokens[4] == 'name') {
      return true;
    }
    final actionPath =
        tokens.length == 6 &&
            tokens[0] == 'state' &&
            tokens[1] == 'rules' &&
            arrayItem(2) &&
            tokens[3] == 'do' &&
            arrayItem(4) &&
            tokens[5] == 'name' ||
        tokens.length == 7 &&
            tokens[0] == 'director' &&
            tokens[1] == 'eventRules' &&
            tokens[2] == 'rules' &&
            arrayItem(3) &&
            tokens[4] == 'do' &&
            arrayItem(5) &&
            tokens[6] == 'name';
    if (actionPath) {
      final parent = _authoringLookup(raw, tokens.sublist(0, tokens.length - 1)).value;
      return parent is Map<String, Object?> && parent['type'] == 'event';
    }
    return false;
  }
  if (kind == 'component') {
    return tokens.length == 3 && tokens[0] == 'components' && tokens[1] == 'enabled' && arrayItem(2);
  }
  if (kind == 'asset') {
    return tokens.length == 2 && tokens[0] == 'theme' && tokens[1] == 'background' ||
        tokens.length == 3 &&
            tokens[0] == 'theme' &&
            tokens[1] == 'fonts' &&
            _authoringLookup(raw, tokens.sublist(0, 2)).value is Map<String, Object?> ||
        tokens.length == 3 && tokens[0] == 'cast' && arrayItem(1) && tokens[2] == 'sprites' ||
        tokens.length == 6 &&
            tokens[0] == 'cast' &&
            arrayItem(1) &&
            tokens[2] == 'card' &&
            tokens[3] == 'assets' &&
            arrayItem(4) &&
            tokens[5] == 'uri';
  }
  return false;
}

String _gameplayToolSourcePath(String fieldPath) {
  if (fieldPath == 'extensions') {
    return '/extensions';
  }
  final suffix = fieldPath.substring('extensions.dshgo'.length);
  return suffix.isEmpty ? '' : '/${suffix.substring(1).split('.').map(_gameplayPointerToken).join('/')}';
}
