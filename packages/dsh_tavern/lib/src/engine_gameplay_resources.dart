part of 'engine.dart';

/// Resource capture has no synthetic character or state-definition context.
final class _GameplayResourceCapture {
  const _GameplayResourceCapture(this.snapshot, {this.characterId, this.chatId, this.newGroupCharacterIds});
  factory _GameplayResourceCapture.fromAdmission(_GameplayAdmission admission) => _GameplayResourceCapture(
    admission.snapshot,
    characterId: admission.request.characterId,
    chatId: admission.request.chatId,
    newGroupCharacterIds: admission.newGroupCharacterIds,
  );

  final StoredGameplaySnapshot snapshot;
  final String? characterId, chatId;
  final List<String>? newGroupCharacterIds;
}

_GameplayResourceCapture _captureGameplayResources(
  TavernEngine engine, {
  String? characterId,
  String? chatId,
  Set<String> kinds = const {'regex'},
  bool deferResourceErrors = false,
}) => _GameplayResourceCapture(
  engine._store.readGameplaySnapshot(
    characterId: characterId,
    chatId: chatId,
    readBindings: true,
    readContext: false,
    resourceKinds: kinds,
    deferResourceErrors: deferResourceErrors,
  ),
  characterId: characterId,
  chatId: chatId,
);

bool _gameplayResourcesCurrent(TavernEngine engine, _GameplayResourceCapture capture) => _gameplaySnapshotCurrent(
  engine,
  capture.snapshot,
  characterId: capture.characterId,
  chatId: capture.chatId,
  newGroupCharacterIds: capture.newGroupCharacterIds,
);

final class _GameplayResources {
  const _GameplayResources({this.regex = const [], this.books = const [], this.packSources = const {}});
  final List<TavernScriptRegex> regex;
  final List<WorldInfoBook> books;
  final Map<WorldInfoEntryRef, WorldInfoPackSource> packSources;
}

/// Both the inspection rows and runtime adapters use this loader order.
/// Evaluation still applies its original scope, strategy and entry order.
List<T> _gameplayWorldInfoOrder<T>(List<T> linked, List<T> embedded, List<T> packs, String Function(T) bucket) => [
  for (final source in WorldInfoSource.values) ...[
    ...linked.where((row) => bucket(row) == source.name),
    if (source == WorldInfoSource.global || source == WorldInfoSource.chat)
      ...packs.where((row) => bucket(row) == source.name),
  ],
  ...embedded,
  ...packs.where((row) => bucket(row) == 'character'),
];

_GameplayResources _resolveGameplayResources(
  _GameplayResourceCapture capture,
  Map<String, Object?> settings, {
  required String? actorId,
  List<String>? worldInfoCharacterIds,
  Set<String> kinds = const {'regex', 'lorebook'},
  Set<String>? regexBuckets,
}) {
  final snapshot = capture.snapshot;
  final worldCharacters =
      worldInfoCharacterIds ??
      (snapshot.group == null && capture.newGroupCharacterIds == null
          ? [?actorId]
          : capture.newGroupCharacterIds ?? [for (final member in snapshot.group!.members) member.characterId]);
  final sources = <_GameplayDeclaration>[
    for (final input in _gameplayPackInputs(snapshot))
      _GameplayDeclaration(
        source: {
          'kind': 'pack',
          'scope': input.scope.name,
          'targetId': ?input.targetId,
          'bindingId': input.binding.bindingId,
          'packRef': input.binding.packRef.toJson(),
        },
        rawPresent: false,
        raw: null,
        pack: input,
        roles: [
          if ((input.scope != TavernGameplayScope.character || input.targetId == actorId) &&
              (regexBuckets == null || regexBuckets.contains(input.scope.name)))
            'regex',
          if (input.scope != TavernGameplayScope.character || worldCharacters.contains(input.targetId)) 'worldInfo',
        ],
      ),
  ];
  final rows = _gameplayResourcePlan(
    sources,
    regexEnabled: settings['regexEnabled'] != false,
    characterRegexEnabled:
        settings['regexEnabled'] != false &&
        settings['characterRegexEnabled'] != false &&
        !_strings(settings['disabledCharacterRegex']).contains(actorId),
    kinds: kinds,
    resourceErrors: snapshot.resourceErrors,
  );
  final bindings = {
    for (final scope in snapshot.scopeSnapshots)
      for (final binding in scope.bindings) binding.bindingId: binding,
  };
  final regex = <TavernScriptRegex>[];
  final books = <WorldInfoBook>[];
  final packSources = <WorldInfoEntryRef, WorldInfoPackSource>{};
  final bookIds = <String>{};
  for (final row in rows) {
    final source = row['source']! as Map<String, Object?>;
    final binding = bindings[source['bindingId']]!;
    final resource = row['resource']! as Map<String, Object?>;
    final kind = row['kind']! as String;
    final resourceId = resource['localId']! as String;
    final mappings = {
      for (final item in binding.sourceMap)
        if (item['kind'] == kind && item['resourceLocalId'] == resourceId)
          item['entryLocalId'] as String? ?? '': item['stableId']! as String,
    };
    String stableId(String entryId) {
      final id = mappings[entryId];
      if (id == null) {
        throw const TavernGameplayException(
          code: 'resource_identity_conflict',
          message: 'The admitted gameplay resource has no saved stable identity.',
        );
      }
      return id;
    }

    final entries = (row['entries']! as List<Object?>).cast<Map<String, Object?>>();
    if (kind == 'regex') {
      for (final entry in entries) {
        final raw = entry['raw']! as Map<String, Object?>;
        final localId = entry['localId']! as String;
        final pointer = entry['pointer']! as String;
        final id = stableId(pointer.isEmpty ? '' : localId);
        final execution = RegexScript.fromJson({...raw, 'id': id, if (entry['disabled'] == true) 'disabled': true});
        regex.add(
          TavernScriptRegex(
            source: TavernScriptRegexSource.values.byName(row['bucket']! as String),
            sourceRef: {
              ...source,
              'resourceLocalId': resourceId,
              'entryLocalId': localId,
              'pointer': pointer,
              'stableId': id,
              'onceEpoch': binding.onceEpoch,
            },
            raw: raw,
            engineId: id,
            stId: raw['id'] is String ? raw['id']! as String : '',
            execution: execution,
            enabled: !execution.disabled,
            effective: entry['effective']! as bool,
            diagnostics: [
              for (final issue in (entry['diagnostics']! as List<Object?>).cast<Map<String, Object?>>())
                TavernRegexDiagnostic.fromJson(issue),
            ],
          ),
        );
      }
    } else if (kind == 'lorebook') {
      final id = stableId('');
      if (!bookIds.add(id)) {
        throw const TavernGameplayException(
          code: 'resource_identity_conflict',
          message: 'Two admitted gameplay books have the same runtime identity.',
        );
      }
      final book = remapWorldInfoBook(
        WorldInfoBook.fromJson(
          id: resourceId,
          source: WorldInfoSource.values.byName(row['bucket']! as String),
          json: row['raw']! as Map<String, Object?>,
        ),
        id: id,
        stWorldName: id,
        entryUidsByPointer: {
          for (final entry in entries) entry['pointer']! as String: stableId(entry['localId']! as String),
        },
      );
      books.add(book);
      final entriesByPointer = {for (final entry in entries) entry['pointer']! as String: entry['localId']! as String};
      final executionSource = state_core.StateExecutionSource.pack(
        installedPackId: binding.packRef.installedPackId,
        bindingId: binding.bindingId,
        onceEpoch: binding.onceEpoch,
      );
      for (final entry in book.entries) {
        packSources[entry.identity] = WorldInfoPackSource(
          source: executionSource,
          resourceLocalId: resourceId,
          entryLocalId: entriesByPointer[entry.sourcePointer]!,
          packVersion: binding.packRef.packVersion,
        );
      }
    }
  }
  return _GameplayResources(regex: regex, books: books, packSources: packSources);
}

List<WorldInfoBook> _mergeGameplayBooks(
  List<WorldInfoBook> linked,
  List<WorldInfoBook> embedded,
  _GameplayResources resources,
) {
  final legacyIds = {
    for (final book in [...linked, ...embedded]) book.id,
  };
  if (resources.books.any((book) => legacyIds.contains(book.id))) {
    throw const TavernGameplayException(
      code: 'resource_identity_conflict',
      message: 'A gameplay runtime book identity conflicts with a real legacy book.',
    );
  }
  return _gameplayWorldInfoOrder(linked, embedded, resources.books, (book) => book.source.name);
}

/// An observation/storage projection, not a second runtime validator.
/// Unknown carriers remain evidence; known rule/event ledgers never enter an
/// empty-chat WI checkpoint or a WI-only compare-and-swap target.
({bool exists, Object? raw}) _gameplayWorldInfoCarrier(Map<String, Object?> state, {bool includeIdentityOnly = true}) {
  if (!state.containsKey('dshgoPackRuntime')) {
    return (exists: false, raw: null);
  }
  final raw = state['dshgoPackRuntime'];
  if (raw is! Map<String, Object?> || raw['v'] != 1 || raw['bindings'] is! Map<String, Object?>) {
    return (exists: true, raw: _runtimeValue(raw));
  }
  final bindings = <String, Object?>{};
  for (final entry in (raw['bindings']! as Map<String, Object?>).entries) {
    final row = entry.value;
    if (row is! Map<String, Object?>) {
      bindings[entry.key] = _runtimeValue(row);
    } else if (includeIdentityOnly || row.containsKey('worldInfo')) {
      bindings[entry.key] = {
        if (row.containsKey('installedPackId')) 'installedPackId': row['installedPackId'],
        if (row.containsKey('onceEpoch')) 'onceEpoch': row['onceEpoch'],
        if (row.containsKey('worldInfo')) 'worldInfo': _runtimeValue(row['worldInfo']),
      };
    }
  }
  return bindings.isEmpty
      ? (exists: false, raw: null)
      : (exists: true, raw: <String, Object?>{'v': 1, 'bindings': bindings});
}

state_core.StatePackWorldInfoSnapshot? _gameplayWorldInfoSnapshot(
  Map<String, Object?> state,
  _GameplayResources resources,
) => resources.packSources.isEmpty
    ? null
    : state_core.StatePackWorldInfoSnapshot(
        exists: state.containsKey('dshgoPackRuntime'),
        raw: state['dshgoPackRuntime'],
      );

void _adoptGameplayWorldInfo(_Turn turn, WorldInfoResult world) {
  if (world.packWorldInfo.isEmpty) {
    return;
  }
  final session = turn.stateSession;
  final adopted = session == null
      ? state_core.mergeStatePackWorldInfo(
          exists: turn.state.containsKey('dshgoPackRuntime'),
          raw: turn.state['dshgoPackRuntime'],
          delta: world.packWorldInfo,
        )
      : session.adoptPackWorldInfo(world.packWorldInfo);
  if (adopted.issues.isNotEmpty) {
    throw const TavernGameplayException(
      code: 'gameplay_world_info_runtime',
      message: 'The world-info result cannot replace the current pack runtime.',
    );
  }
  if (adopted.exists) {
    turn.state['dshgoPackRuntime'] = adopted.raw;
  }
}

void _checkScriptGameplayResources(TavernEngine engine, _GameplayResourceCapture? capture, String operation) {
  if (capture != null && !_gameplayResourcesCurrent(engine, capture)) {
    throw _scriptError(
      TavernScriptErrorCode.revisionConflict,
      operation,
      'The captured gameplay resource sources changed.',
    );
  }
}
