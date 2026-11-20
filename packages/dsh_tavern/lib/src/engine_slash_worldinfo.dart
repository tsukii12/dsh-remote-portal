// The approved WI commands adapt SillyTavern world-info.js:1159–1449,
// 2687–2724, 2756–2766, 4082–4148 and 4395–4409, commit
// 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// They edit authoritative ST objects, not a reverse runtime-WI projection.
part of 'engine.dart';

const _slashWiDefinitions = <String, Object?>{
  'key': <Object?>[],
  'keysecondary': <Object?>[],
  'comment': '',
  'content': '',
  'constant': false,
  'vectorized': false,
  'selective': true,
  'selectiveLogic': 0,
  'addMemo': false,
  'order': 100,
  'position': 0,
  'disable': false,
  'ignoreBudget': false,
  'excludeRecursion': false,
  'preventRecursion': false,
  'matchPersonaDescription': false,
  'matchCharacterDescription': false,
  'matchCharacterPersonality': false,
  'matchCharacterDepthPrompt': false,
  'matchScenario': false,
  'matchCreatorNotes': false,
  'delayUntilRecursion': 0,
  'probability': 100,
  'useProbability': true,
  'depth': 4,
  'outletName': '',
  'group': '',
  'groupOverride': false,
  'groupWeight': 100,
  'scanDepth': null,
  'caseSensitive': null,
  'matchWholeWords': null,
  'useGroupScoring': null,
  'automationId': '',
  'role': 0,
  'sticky': null,
  'cooldown': null,
  'delay': null,
  'characterFilterNames': <Object?>[],
  'characterFilterTags': <Object?>[],
  'characterFilterExclude': false,
  'triggers': <Object?>[],
};
const _slashWiVirtualFields = {'characterFilterNames', 'characterFilterTags', 'characterFilterExclude'};
const _slashWiOriginalFields = <String, String>{
  'displayIndex': 'extensions.display_index',
  'excludeRecursion': 'extensions.exclude_recursion',
  'preventRecursion': 'extensions.prevent_recursion',
  'delayUntilRecursion': 'extensions.delay_until_recursion',
  'selectiveLogic': 'selectiveLogic',
  'comment': 'comment',
  'constant': 'constant',
  'order': 'insertion_order',
  'depth': 'extensions.depth',
  'probability': 'extensions.probability',
  'position': 'extensions.position',
  'role': 'extensions.role',
  'content': 'content',
  'enabled': 'enabled',
  'key': 'keys',
  'keysecondary': 'secondary_keys',
  'selective': 'selective',
  'matchWholeWords': 'extensions.match_whole_words',
  'useGroupScoring': 'extensions.use_group_scoring',
  'caseSensitive': 'extensions.case_sensitive',
  'matchPersonaDescription': 'extensions.match_persona_description',
  'matchCharacterDescription': 'extensions.match_character_description',
  'matchCharacterPersonality': 'extensions.match_character_personality',
  'matchCharacterDepthPrompt': 'extensions.match_character_depth_prompt',
  'matchScenario': 'extensions.match_scenario',
  'matchCreatorNotes': 'extensions.match_creator_notes',
  'scanDepth': 'extensions.scan_depth',
  'automationId': 'extensions.automation_id',
  'vectorized': 'extensions.vectorized',
  'groupOverride': 'extensions.group_override',
  'groupWeight': 'extensions.group_weight',
  'sticky': 'extensions.sticky',
  'cooldown': 'extensions.cooldown',
  'delay': 'extensions.delay',
  'triggers': 'extensions.triggers',
  'ignoreBudget': 'extensions.ignore_budget',
};

List<String> _slashParseStringArray(String value) {
  if (value.isEmpty) return <String>[];
  try {
    final parsed = ScriptCoercion.parseJson(value);
    if (parsed is List<Object?>) return [for (final item in parsed) ScriptCoercion.string(item)];
  } on FormatException {
    /* Only the fixed pure JSON compatibility fallback. */
  }
  return value.split(',').map(trimJsWhitespace).where((item) => item.isNotEmpty).toList();
}

Map<String, Object?> _slashWiEntries(_SlashInvocation invocation, Map<String, Object?> book) {
  final entries = book['entries'];
  if (entries is List) {
    throw _slashArgument(
      invocation,
      'file.entries',
      'These field commands support standalone ST entries objects; raw book APIs retain array support.',
      code: TavernScriptErrorCode.unsupportedCapability,
    );
  }
  if (entries is! Map<String, Object?>) {
    throw _slashArgument(
      invocation,
      'file.entries',
      'The ST entries container must be an object.',
      code: TavernScriptErrorCode.shapeMismatch,
    );
  }
  return entries;
}

void _slashSyncOriginalEntry(
  _SlashInvocation invocation,
  Map<String, Object?> book,
  String uid,
  String? path,
  Object? value,
) {
  if (path == null) return;
  final original = book['originalData'];
  if (original is! Map<String, Object?> || original['entries'] is! List<Object?>) return;
  Map<String, Object?>? found;
  for (final entry in original['entries']! as List<Object?>) {
    if (entry == null) {
      throw _slashArgument(
        invocation,
        'file.originalData.entries',
        'A null original entry has no UID.',
        code: TavernScriptErrorCode.shapeMismatch,
      );
    }
    // The actual string locator is never widened to a numeric UID match.
    if (entry is Map<String, Object?> && entry['uid'] is String && entry['uid'] == uid) {
      found = entry;
      break;
    }
  }
  if (found == null) return;
  Object? current = found;
  final parts = path.split('.');
  for (final part in parts.take(parts.length - 1)) {
    if (current is Map<String, Object?>) {
      current = current.putIfAbsent(part, () => <String, Object?>{});
    } else if (current is List<Object?>) {
      final child = ScriptCoercion.property(current, part);
      if (ScriptCoercion.isUndefined(child)) {
        final created = <String, Object?>{};
        ScriptCoercion.setProperty(current, part, created);
        current = created;
      } else {
        current = child;
      }
    } else {
      throw _slashArgument(
        invocation,
        'file.originalData.$path',
        'The original-data path cannot receive a property.',
        code: TavernScriptErrorCode.shapeMismatch,
      );
    }
  }
  // Fixed U2145–2159 can assign an array's non-index property. Such a
  // property does not enter JSON; preserve that pure no-op, not a bad-shape
  // rejection. Null and primitive receivers still fail before saving.
  if (!ScriptCoercion.setProperty(current, parts.last, _captureScriptJson(value))) {
    throw _slashArgument(
      invocation,
      'file.originalData.$path',
      'The original-data path cannot receive a property.',
      code: TavernScriptErrorCode.shapeMismatch,
    );
  }
}

class _SlashBookFileEffect {
  _SlashBookFileEffect(this.coordinator, this.scope, this.operation, this.bookId, this.raw, {this.sourceName});
  final _ScriptCoordinator coordinator;
  final _ScriptEffectScope scope;
  final String operation, bookId;
  final String? sourceName;
  final Map<String, Object?> raw;
  bool started = false, adopted = false;
  String? version;
  TavernJsonObject get target => {'kind': 'book', 'ref': TavernScriptBookRef.standalone(bookId: bookId).toJson()};
  void onStarted() {
    started = true;
    scope.execution!.recordEffect(
      kind: TavernSlashEffectKind.storage,
      state: TavernSlashEffectState.started,
      stage: TavernSlashEffectStage.handler,
      operation: operation,
      target: target,
      details: const {'carrier': 'file'},
    );
  }

  void onRenamed() {
    // This is called by the original writer immediately after actual rename.
    // Never check cancellation here or erase a file already adopted.
    adopted = true;
    scope.adopted();
    version = coordinator._resourceVersion('standalone:$bookId', raw);
    scope.execution!.recordEffect(
      kind: TavernSlashEffectKind.storage,
      state: TavernSlashEffectState.adopted,
      stage: TavernSlashEffectStage.handler,
      operation: operation,
      target: target,
      version: version,
      committed: true,
      details: {'carrier': 'file', 'name': ?sourceName},
    );
  }

  void failed(TavernScriptException error) {
    if (!started || adopted) return;
    final unknown = error.issues
        .where(
          (issue) =>
              issue.code == 'authoring_adoption_unconfirmed' &&
              issue.details['physicalResourceId'] == 'lorebook:$bookId',
        )
        .firstOrNull;
    scope.execution!.recordEffect(
      kind: TavernSlashEffectKind.storage,
      state: unknown == null ? TavernSlashEffectState.failed : TavernSlashEffectState.unconfirmed,
      stage: TavernSlashEffectStage.handler,
      operation: operation,
      target: target,
      details: {'carrier': 'file', 'code': error.code.name, ...?unknown?.details},
    );
  }
}

extension _SlashWorldInfoOperations on _ScriptCoordinator {
  Future<List<_ScriptStandaloneBook>> _slashBookCatalogNow() async {
    final result = <_ScriptStandaloneBook>[];
    final folder = Directory('${engine.directory.path}/lorebooks');
    try {
      await for (final file in folder.list(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.json')) continue;
        final filename = file.uri.pathSegments.last;
        final id = filename.substring(0, filename.length - 5);
        final book = await _scriptReadStandaloneNow(id);
        if (book != null) result.add(book);
      }
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
      // Only an absent directory is absence. File JSON and other I/O failures
      // from an actually enumerated book are never converted to an empty book.
      if (result.isNotEmpty) rethrow;
    }
    return result;
  }

  _ScriptStandaloneBook? _slashBookByName(
    _SlashInvocation invocation,
    List<_ScriptStandaloneBook> catalog,
    String name,
  ) {
    var matches = catalog.where((book) => book.sourceName == name).toList();
    if (matches.isEmpty) matches = catalog.where((book) => book.displayName == name).toList();
    if (matches.length > 1) {
      throw _slashArgument(
        invocation,
        'file',
        'The exact world-book name is ambiguous.',
        code: TavernScriptErrorCode.ambiguousName,
      );
    }
    return matches.firstOrNull;
  }

  String _slashBookReturnName(
    _SlashInvocation invocation,
    List<_ScriptStandaloneBook> catalog,
    _ScriptStandaloneBook book, {
    String? preferred,
  }) {
    var ambiguous = false;
    final names = <String>{
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (book.sourceName?.isNotEmpty == true) book.sourceName!,
      if (book.displayName.isNotEmpty) book.displayName,
    };
    for (final name in names) {
      try {
        final resolved = _slashBookByName(invocation, catalog, name);
        if (resolved?.id == book.id) return name;
        if (resolved != null) ambiguous = true;
      } on TavernScriptException catch (error) {
        if (error.code != TavernScriptErrorCode.ambiguousName) rethrow;
        ambiguous = true;
      }
    }
    throw _slashArgument(
      invocation,
      'file',
      'The bound book has no name that resolves uniquely to its identity.',
      code: ambiguous ? TavernScriptErrorCode.ambiguousName : TavernScriptErrorCode.notFound,
    );
  }

  Future<List<String>> _slashCharacterFilterNames(_SlashInvocation invocation, List<String> names) =>
      _bridgeOperation(() async {
        final owner = invocation.owner;
        owner.checkAlive();
        if (names.isEmpty) return <String>[];
        final chatId = owner.context.value.chatId;
        final chat = chatId == null ? null : engine._store.chat(chatId);
        final metadata = chat == null ? <String, Object?>{} : engine._chatCodec.metadataForNode(engine._store, chat.id);
        final settings = _runtimeCopy(engine._effectiveSettings(chat, metadata));
        final currentActor =
            owner.context.value.characterId ??
            (chat != null && engine._store.groupChat(chat.id) == null ? chat.characterId : null);
        return engine._libraryOperation(() async {
          final cards = await engine._characterSummaries();
          owner.checkAlive();
          // Fixed findChar(preferCurrentChar:false): actual avatar (including
          // its .png shorthand) wins, then the first accent/case-insensitive
          // name in the captured native list. This is not gen/sendas' unique-ID
          // policy. Native list order is the package's explicit list projection.
          final candidates = [
            for (final card in cards)
              (
                card: card,
                avatar: <String, Object?>{
                  ..._map(_map(settings['characterIdentities'])[card.id]),
                  if (card.id == currentActor) ..._map(settings['characterIdentity']),
                }['avatarFilename'],
              ),
          ];
          final fallback = candidates.where((candidate) => candidate.card.id == currentActor).firstOrNull;
          final result = <String>[];
          for (final name in names) {
            var selected = name.isEmpty
                ? null
                : candidates
                      .where(
                        (candidate) =>
                            candidate.avatar == name || !name.endsWith('.png') && candidate.avatar == '$name.png',
                      )
                      .firstOrNull;
            selected ??= candidates
                .where((candidate) => name.isEmpty || _slashNamesEqualIgnoreCaseAndAccents(candidate.card.name, name))
                .firstOrNull;
            // U1344 uses its real current character when findChar returned no
            // avatar. The package maps that source to the captured context actor;
            // an actorless group does not invent a current member.
            selected ??= fallback;
            if (selected == null) continue;
            final avatar = selected.avatar;
            if (avatar is! String || avatar.isEmpty) {
              throw _slashArgument(
                invocation,
                'characterFilterNames',
                'Each character filter needs an actual registered avatar filename.',
                code: TavernScriptErrorCode.unsupportedCapability,
              );
            }
            final filename = avatar.replaceFirst(RegExp(r'\.[^/.]+$'), '');
            if (filename.isNotEmpty && !result.contains(filename)) result.add(filename);
          }
          return result;
        });
      });

  void _slashSetEntryField(
    _SlashInvocation invocation,
    Map<String, Object?> book,
    Map<String, Object?> entry,
    String uid,
    String field,
    String value,
    List<String>? characterNames,
  ) {
    entry.putIfAbsent(field, () => _captureScriptJson(_slashWiDefinitions[field]));
    if (_slashWiVirtualFields.contains(field)) {
      if (!ScriptCoercion.truthy(entry['characterFilter'])) {
        entry['characterFilter'] = <String, Object?>{'isExclude': false, 'names': <Object?>[], 'tags': <Object?>[]};
      }
      final filter = entry['characterFilter'];
      if (filter is! Map<String, Object?> && filter is! List<Object?>) {
        throw _slashArgument(
          invocation,
          'file.entries.$uid.characterFilter',
          'The character filter cannot receive a property.',
          code: TavernScriptErrorCode.shapeMismatch,
        );
      }
      switch (field) {
        case 'characterFilterNames':
          ScriptCoercion.setProperty(filter, 'names', List<String>.of(characterNames!));
        case 'characterFilterTags':
          ScriptCoercion.setProperty(filter, 'tags', <Object?>[]);
        case 'characterFilterExclude':
          ScriptCoercion.setProperty(filter, 'isExclude', ScriptCoercion.trueBoolean(value));
      }
      _slashSyncOriginalEntry(invocation, book, uid, 'character_filter', filter);
      return;
    }
    final current = entry[field];
    final Object? converted;
    if (current is List) {
      var values = _slashParseStringArray(value);
      if (field == 'triggers') {
        values = values
            .where(const {'normal', 'continue', 'impersonate', 'swipe', 'regenerate', 'quiet'}.contains)
            .toList();
      }
      converted = values;
    } else if (current is bool) {
      converted = ScriptCoercion.trueBoolean(value);
    } else if (current is num) {
      final number = ScriptCoercion.number(value);
      if (!number.isFinite) {
        throw _slashArgument(invocation, 'unnamed', 'A numeric world-book field must remain finite JSON.');
      }
      converted = number;
    } else {
      converted = value;
    }
    entry[field] = converted;
    _slashSyncOriginalEntry(invocation, book, uid, _slashWiOriginalFields[field], converted);
  }

  Future<String> _executeSlashBook(_SlashInvocation invocation) async {
    if (invocation.command == 'getchatbook') return _executeSlashChatBook(invocation);
    final owner = invocation.owner;
    final operation = invocation.command;
    final file = _slashNamed(invocation, 'file');
    if (file.isEmpty) throw _slashArgument(invocation, 'file', 'A nonempty world-book name is required.');
    final suppliedField = _slashNamed(invocation, 'field');
    final field = suppliedField.isNotEmpty
        ? suppliedField
        : operation == 'findentry'
        ? 'key'
        : 'content';
    final key = operation == 'createentry' ? _slashNamed(invocation, 'key') : '';
    final body = _slashBody(invocation);
    final String? uid;
    var value = body;
    List<String>? characterNames;
    if (operation == 'setentryfield') {
      if (!invocation.has('uid')) throw _slashArgument(invocation, 'uid', 'An actual entry property key is required.');
      uid = _slashNamed(invocation, 'uid');
      if (!_slashWiDefinitions.containsKey(field)) {
        throw _slashArgument(
          invocation,
          'field',
          'This world-book field is not in the fixed definition.',
          code: TavernScriptErrorCode.unsupportedOption,
        );
      }
      value = value.replaceAllMapped(RegExp(r'\\([{}|])'), (match) => match[1]!);
      if (field == 'characterFilterNames') {
        characterNames = await owner.wait(
          _slashCharacterFilterNames(invocation, _slashParseStringArray(value)),
          TavernSlashWaitKind.storage,
        );
      } else if (field == 'characterFilterTags' && _slashParseStringArray(value).isNotEmpty) {
        throw _slashArgument(
          invocation,
          'characterFilterTags',
          'Nonempty tag names require a real tag-name to tag-ID catalog.',
          code: TavernScriptErrorCode.unsupportedCapability,
        );
      }
    } else {
      uid = null;
    }
    final scope = _ScriptEffectScope.slash(this, owner);
    _SlashBookFileEffect? effect;
    try {
      final result = await scope.drain(
        _bridgeOperation(
          () => engine._bookOperation(() async {
            scope.checkAlive();
            final catalog = await _slashBookCatalogNow();
            scope.checkAlive();
            final book = _slashBookByName(invocation, catalog, file);
            if (book == null) {
              throw _slashArgument(
                invocation,
                'file',
                'The exact world-book name was not found.',
                code: TavernScriptErrorCode.notFound,
              );
            }
            final raw = _captureScriptObject(book.raw);
            final entries = _slashWiEntries(invocation, raw);
            if (operation == 'findentry') {
              var query = body;
              if (!_slashWiVirtualFields.contains(field) && _slashWiDefinitions[field] is bool) {
                if (ScriptCoercion.trueBoolean(query)) query = 'true';
                if (ScriptCoercion.falseBoolean(query)) query = 'false';
              }
              final match = stFindEntries(
                entries,
                field,
                query,
                jsString: ScriptCoercion.string,
                lowercase: _slashDefaultLowercase,
              ).firstOrNull;
              final item = match?.item;
              final found = item is Map<String, Object?> ? item['uid'] : null;
              return found == null ? '' : ScriptCoercion.string(found);
            }
            final String result;
            if (operation == 'createentry') {
              int? free;
              for (var candidate = 0; candidate < 1000000; candidate++) {
                if (!entries.containsKey('$candidate')) {
                  free = candidate;
                  break;
                }
              }
              if (free == null) {
                throw _slashArgument(
                  invocation,
                  'file.entries',
                  'All supported entry property keys are occupied.',
                  code: TavernScriptErrorCode.range,
                );
              }
              final entry = <String, Object?>{
                'uid': free,
                for (final item in _slashWiDefinitions.entries)
                  if (!_slashWiVirtualFields.contains(item.key)) item.key: _captureScriptJson(item.value),
              };
              if (key.isNotEmpty) {
                entry['key'] = [key];
                entry['comment'] = key;
                entry['addMemo'] = true;
              }
              if (body.isNotEmpty) entry['content'] = body;
              entries['$free'] = entry;
              result = '$free';
            } else {
              if (!entries.containsKey(uid)) {
                throw _slashArgument(
                  invocation,
                  'uid',
                  'The entry property key does not exist.',
                  code: TavernScriptErrorCode.notFound,
                );
              }
              final entry = entries[uid];
              if (entry is! Map<String, Object?>) {
                throw _slashArgument(
                  invocation,
                  'uid',
                  'The selected entry must be an object.',
                  code: TavernScriptErrorCode.shapeMismatch,
                );
              }
              _slashSetEntryField(invocation, raw, entry, uid!, field, value, characterNames);
              result = '';
            }
            scope.checkAlive();
            final write = _SlashBookFileEffect(this, scope, operation, book.id, raw, sourceName: book.sourceName);
            effect = write;
            await engine._writeBookNow(
              book.id,
              raw,
              stWorldName: book.sourceName,
              preservedEnvelope: book.envelope,
              check: scope.checkAlive,
              onStarted: write.onStarted,
              onRenamed: write.onRenamed,
            );
            return result;
          }),
        ),
      );
      if (effect?.adopted == true) {
        resourcesChanged();
        await _confirmScriptEffectCaches(scope);
      }
      scope.checkAlive();
      return result;
    } catch (error, stack) {
      final failure = _scriptFailure(error);
      scope.observe(failure);
      effect?.failed(failure);
      if (effect?.adopted == true) resourcesChanged();
      Error.throwWithStackTrace(_scriptEffectException(scope, failure), stack);
    } finally {
      scope.finish();
    }
  }

  Future<String> _executeSlashChatBook(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    final admission = await _captureSlashChat(owner);
    owner.checkAlive();
    final chatId = admission.capture.chatId;
    // Capture the three actual values synchronously with their observation
    // tokens. No async gap pairs old header data with newly read versions.
    final bindingVersions = _captureSlashBindingVersions(owner, admission);
    final current = engine._store.chat(chatId);
    final metadata = _slashMetadataSource(current).metadata;
    final settings = _copy(current.settings);
    final scope = _ScriptEffectScope.slash(this, owner);
    _SlashBookFileEffect? effect;
    TavernJsonObject? bindingTarget;
    var bindingAttempted = false;
    int? bindingEffectsStart;
    try {
      final chosen = await scope.drain(
        _bridgeOperation(
          () => engine._bookOperation(() async {
            scope.checkAlive();
            _checkSlashChatAdmission(owner, admission);
            final catalog = await _slashBookCatalogNow();
            scope.checkAlive();
            final byId = {for (final book in catalog) book.id: book};
            final canonicalName = metadata['world_info'];
            String? canonicalId;
            if (canonicalName is String && canonicalName.isNotEmpty) {
              final mapping = settings['stLorebookIds'];
              if (mapping != null && mapping is! Map<String, Object?>) {
                throw _slashArgument(
                  invocation,
                  'settings.stLorebookIds',
                  'The source-name mapping must be an object.',
                  code: TavernScriptErrorCode.shapeMismatch,
                );
              }
              final candidate = mapping is Map<String, Object?> ? mapping[canonicalName] : null;
              if (candidate is String) canonicalId = candidate;
            }
            if (canonicalId is String) {
              final canonical = byId[canonicalId] ?? await _scriptReadStandaloneNow(canonicalId);
              scope.checkAlive();
              if (canonical != null) {
                if (!byId.containsKey(canonical.id)) catalog.add(canonical);
                return (
                  name: _slashBookReturnName(invocation, catalog, canonical, preferred: canonicalName as String),
                  id: canonical.id,
                  created: false,
                );
              }
            }
            // A valid canonical does not consume or validate the fallback binding.
            // Removing only this detached header field exposes the original native
            // chat source instead of feeding a stale canonical projection back in.
            final nativeMetadata = _copy(metadata)..remove('world_info');
            final nativeSettings = engine._effectiveSettings(current, nativeMetadata);
            final nativeValue = _map(nativeSettings['lorebooks'])['chat'];
            if (nativeValue != null && (nativeValue is! List<Object?> || nativeValue.any((item) => item is! String))) {
              throw _slashArgument(
                invocation,
                'settings.lorebooks.chat',
                'The native chat binding must contain book IDs.',
                code: TavernScriptErrorCode.shapeMismatch,
              );
            }
            final nativeIds = nativeValue is List<Object?> ? nativeValue.cast<String>().toSet() : <String>{};
            final native = <_ScriptStandaloneBook>[];
            for (final id in nativeIds) {
              final book = byId[id] ?? await _scriptReadStandaloneNow(id);
              scope.checkAlive();
              if (book != null) {
                native.add(book);
                if (!byId.containsKey(book.id)) catalog.add(book);
              }
            }
            if (native.length > 1) {
              throw _slashArgument(
                invocation,
                'settings.lorebooks.chat',
                'The native chat has multiple world books.',
                code: TavernScriptErrorCode.ambiguousName,
              );
            }
            if (native.isNotEmpty) {
              final book = native.single;
              return (name: _slashBookReturnName(invocation, catalog, book), id: book.id, created: false);
            }
            if (_slashFalse(invocation, 'create')) return (name: '', id: '', created: false);
            // The creation name is intentionally not consumed for existing books
            // or create=false, matching the descriptor's real early-return scope.
            final supplied = invocation.has('name') ? _slashNamed(invocation, 'name') : null;
            bool occupied(String name) => catalog.any((book) => book.sourceName == name || book.displayName == name);
            final String name;
            if (supplied != null) {
              if (supplied.isEmpty) throw _slashArgument(invocation, 'name', 'A creation name must not be empty.');
              if (occupied(supplied)) {
                throw _slashArgument(
                  invocation,
                  'name',
                  'This world-book name is already occupied.',
                  code: TavernScriptErrorCode.duplicateId,
                );
              }
              name = supplied;
            } else {
              var base = 'Chat Book $chatId'
                  .replaceAll(RegExp(r'[^a-zA-Z0-9 -]'), '_')
                  .replaceAll(RegExp(r'_{2,}'), '_');
              if (base.length > 64) base = base.substring(0, 64);
              String? available;
              for (var suffix = 0; suffix < 1000; suffix++) {
                final candidate = suffix == 0 ? base : '$base ($suffix)';
                if (!occupied(candidate)) {
                  available = candidate;
                  break;
                }
              }
              if (available == null) {
                throw _slashArgument(
                  invocation,
                  'name',
                  'No unique default name remains in the fixed search range.',
                  code: TavernScriptErrorCode.duplicateId,
                );
              }
              name = available;
            }
            for (final field in const ['stLorebookIds', 'lorebooks']) {
              if (settings.containsKey(field) && settings[field] is! Map<String, Object?>) {
                throw _slashArgument(
                  invocation,
                  'settings.$field',
                  'The binding container must be an object.',
                  code: TavernScriptErrorCode.shapeMismatch,
                );
              }
            }
            String id;
            do {
              scope.checkAlive();
              id = _newStateId();
            } while (await FileSystemEntity.type('${engine.directory.path}/lorebooks/$id.json', followLinks: false) !=
                FileSystemEntityType.notFound);
            final raw = <String, Object?>{'entries': <String, Object?>{}};
            final write = _SlashBookFileEffect(this, scope, 'getchatbook', id, raw, sourceName: name);
            effect = write;
            bindingTarget = {'kind': 'chatBookBinding', 'chatId': chatId, 'bookId': id, 'name': name};
            await engine._writeBookNow(
              id,
              raw,
              stWorldName: name,
              check: () {
                scope.checkAlive();
                _checkSlashChatAdmission(owner, admission);
              },
              onStarted: write.onStarted,
              onRenamed: write.onRenamed,
            );
            return (name: name, id: id, created: true);
          }),
        ),
      );
      scope.checkAlive();
      _checkSlashChatAdmission(owner, admission);
      if (!chosen.created) return chosen.name;
      bindingAttempted = true;
      bindingEffectsStart = owner.effects.length;
      await _mutateSlashMetadata<String>(
        owner,
        admission,
        operation: 'getchatbook',
        target: bindingTarget!,
        expectedVersions: bindingVersions,
        transform: (actualMetadata, actualSettings) {
          Map<String, Object?> object(String field) {
            if (!actualSettings.containsKey(field)) return <String, Object?>{};
            final value = actualSettings[field];
            if (value is! Map<String, Object?>) {
              throw _slashArgument(
                invocation,
                'settings.$field',
                'The binding container must be an object.',
                code: TavernScriptErrorCode.shapeMismatch,
              );
            }
            return _copy(value);
          }

          final ids = object('stLorebookIds')..[chosen.name] = chosen.id;
          final books = object('lorebooks')..['chat'] = [chosen.id];
          actualMetadata['world_info'] = chosen.name;
          actualSettings['stLorebookIds'] = ids;
          actualSettings['lorebooks'] = books;
          return (
            changed: true,
            value: chosen.name,
            metadata: actualMetadata,
            settings: actualSettings,
            injectionIds: <String>{},
          );
        },
      );
      scope.checkAlive();
      return chosen.name;
    } catch (error, stack) {
      final failure = _scriptFailure(error);
      scope.observe(failure);
      effect?.failed(failure);
      if (effect?.adopted == true) {
        // Calling the metadata helper is not evidence that SQL started. A
        // cancellation or target-version conflict can reject it before its
        // actual transaction boundary. Only that carrier's ledger is factual.
        final bindingEffects = owner.effects
            .skip(bindingEffectsStart ?? owner.effects.length)
            .where(
              (entry) =>
                  entry.kind == TavernSlashEffectKind.storage &&
                  entry.operation == 'getchatbook' &&
                  entry.target['kind'] == 'chatBookBinding' &&
                  entry.target['chatId'] == chatId &&
                  entry.target['bookId'] == effect!.bookId,
            )
            .toList();
        final bindingStarted = bindingEffects.any((entry) => entry.state == TavernSlashEffectState.started);
        final bindingAdopted = bindingEffects.any((entry) => entry.state == TavernSlashEffectState.adopted);
        if (!bindingStarted && bindingTarget != null) {
          owner.recordEffect(
            kind: TavernSlashEffectKind.storage,
            stage: TavernSlashEffectStage.handler,
            state: TavernSlashEffectState.skipped,
            operation: 'getchatbook',
            target: bindingTarget!,
            details: {'carrier': 'sql', 'reason': failure.code.name},
          );
        }
        final issue = TavernScriptIssue(
          code: 'chatBookPartial',
          message: 'The world-book file exists; the later binding or confirmation did not complete.',
          committed: true,
          contextId: owner.context.value.id,
          sourceSpan: invocation.sourceSpan,
          stage: 'handler',
          cancelled: failure.code == TavernScriptErrorCode.cancelled,
          details: {
            'bookId': effect!.bookId,
            'name': effect!.sourceName,
            'version': ?effect!.version,
            'bindingTarget': ?bindingTarget,
            'bindingAttempted': bindingAttempted,
            'bindingStarted': bindingStarted,
            'bindingAdopted': bindingAdopted,
          },
        );
        owner.observeIssues([issue]);
        scope.issues.add(issue);
      }
      Error.throwWithStackTrace(_scriptEffectException(scope, failure), stack);
    } finally {
      if (effect?.adopted == true) resourcesChanged();
      scope.finish();
    }
  }
}
