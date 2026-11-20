part of 'engine.dart';

extension _AuthoringOperations on TavernEngine {
  Future<T> _authoringOperation<T>(FutureOr<T> Function() action) {
    _ensureAdmission();
    final owner = Completer<void>();
    _operations.add(owner.future);
    return () async {
      try {
        return await action();
      } finally {
        _operations.remove(owner.future);
        owner.complete();
      }
    }();
  }

  Future<TavernAuthoringDraft> _createAuthoringDraft(List<TavernAuthoringTarget> targets) =>
      _authoringOperation(() async {
        final captured = List<TavernAuthoringTarget>.of(targets);
        _validateAuthoringTargets(captured);
        final sources = [for (final target in captured) await _captureAuthoringSource(target)];
        return _authoringView(
          _store.createAuthoringDraftData({'version': 1, 'sources': sources, 'changes': <Object?>[]}),
        );
      });

  Future<TavernAuthoringDraft?> _readAuthoringDraft(String id) => _authoringOperation(() {
    final stored = _store.readAuthoringDraftData(id);
    return stored == null ? null : _authoringView(stored);
  });

  Future<List<TavernAuthoringDraftSummary>> _listAuthoringDrafts() => _authoringOperation(
    () => [
      for (final row in _store.listAuthoringDraftData())
        TavernAuthoringDraftSummary(
          id: row.id,
          draftRevision: row.revision,
          targets: [
            for (final source in row.data['sources']! as List<Object?>)
              _authoringTarget((source! as Map<String, Object?>)['target']! as Map<String, Object?>),
          ],
          updatedAt: row.updatedAt,
        ),
    ],
  );

  Future<TavernAuthoringDraft> _editAuthoringDraft(
    String id,
    int revision,
    List<TavernAuthoringChange> changes, {
    required bool rebase,
  }) => _authoringOperation(() async {
    final captured = _captureAuthoringChanges(changes);
    final stored = _requireAuthoringDraft(id, revision);
    final old = _authoringView(stored);
    if (rebase && old.sources.any((source) => source.origin == TavernAuthoringSourceOrigin.seed)) {
      throw const TavernAuthoringException('unsupported_seed', 'A seed has no live resource to rebase.');
    }
    final sources = rebase
        ? [for (final source in old.sources) await _captureAuthoringSource(source.target)]
        : stored.data['sources']! as List<Object?>;
    final data = <String, Object?>{
      ...stored.data,
      'sources': sources,
      'changes': [for (final change in captured) _authoringChangeJson(change)],
    };
    final candidate = _authoringView(
      StoredAuthoringDraft(
        id: id,
        revision: revision,
        data: data,
        createdAt: stored.createdAt,
        updatedAt: stored.updatedAt,
      ),
    );
    _materializeAuthoring(candidate, captured.map((change) => change.id).toSet(), includeDiffs: false);
    return _authoringView(_store.updateAuthoringDraftData(id, revision, data));
  });

  StoredAuthoringDraft _requireAuthoringDraft(String id, int revision) {
    final stored = _store.readAuthoringDraftData(id);
    if (stored == null) throw const TavernAuthoringException('not_found', 'The authoring draft does not exist.');
    if (stored.revision != revision) {
      throw const TavernAuthoringException('revision_conflict', 'The authoring draft changed.');
    }
    return stored;
  }

  Future<Map<String, Object?>> _captureAuthoringSource(TavernAuthoringTarget target) async {
    final source = <String, Object?>{
      'target': {'kind': target.kind.name, 'id': target.id},
      'mediaRefs': <String>[],
      'present': true,
    };
    switch (target.kind) {
      case TavernAuthoringTargetKind.character:
        final captured = await _library.readAuthoringSnapshot(target.id);
        if (captured == null) _authoringSourceMissing(target);
        source.addAll({
          'base': captured.document,
          'rawText': captured.rawText,
          'identityText': captured.identityText,
          'sourceFormat': captured.sourceFormat,
          'mediaRefs': captured.mediaRefs,
        });
        final revision = captured.authorityRevision;
        if (revision != null) source['authorityRevision'] = _authoringRevisionJson(revision);
      case TavernAuthoringTargetKind.lorebook:
        return _bookOperation(() async {
          _authoringAuthority.checkWritable(target.physicalResourceId);
          final file = File('${directory.path}/lorebooks/${target.id}.json');
          final ({String text, String rawText}) text;
          try {
            text = await readAuthoringText(file);
          } on PathNotFoundException catch (error) {
            final code = error.osError?.errorCode;
            if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
            _authoringAuthority.observe(target.physicalResourceId, const AuthoringResourceSnapshot(present: false));
            _authoringSourceMissing(target);
          }
          final revision = _authoringAuthority.observe(
            target.physicalResourceId,
            AuthoringResourceSnapshot(present: true, rawText: text.rawText),
          );
          final document = _decodeObject(text.text, 'Lorebook');
          _authoringBook(document);
          return {
            ...source,
            'base': document,
            'rawText': text.rawText,
            'authorityRevision': _authoringRevisionJson(revision),
            'sourceFormat': !document.containsKey('entries') && document['format'] == 'dshgo-lorebook'
                ? 'dshgo-lorebook'
                : 'st-json',
          };
        });
      case TavernAuthoringTargetKind.regexLibrary:
        final captured = await _regexLibrary.readAuthoringSnapshot();
        source.addAll({
          'base': captured.document,
          'rawText': captured.rawText,
          'present': captured.present,
          'sourceFormat': 'regex-library-v1',
        });
      case TavernAuthoringTargetKind.preset:
        return _presetOperation(() {
          final preset = _store.readAuthoringPresetData(target.id);
          if (preset == null) _authoringSourceMissing(target);
          return {
            ...source,
            'sourceFormat': preset['envelope'] == null ? 'st-json' : 'dsh-preset-enhance',
            'base': preset,
          };
        });
    }
    return source;
  }

  Future<TavernAuthoringPreview> _previewAuthoringDraft(String id, int revision, List<String> changeIds) =>
      _authoringOperation(() async {
        final selected = changeIds.toSet();
        final draft = _authoringView(_requireAuthoringDraft(id, revision));
        final result = _materializeAuthoring(draft, selected);
        final reports = <String, List<TavernImportReport>>{};
        final issues = <String, List<TavernImportFinding>>{};
        for (final source in draft.sources) {
          final inspected = await _inspectAuthoringSource(source, result.candidates[source.physicalResourceId]!);
          reports[source.physicalResourceId] = inspected.reports;
          if (inspected.issues.isNotEmpty) issues[source.physicalResourceId] = inspected.issues;
        }
        return TavernAuthoringPreview(
          draftId: id,
          draftRevision: revision,
          changeIds: [
            for (final change in draft.changes)
              if (selected.contains(change.id)) change.id,
          ],
          candidates: result.candidates,
          diffs: result.diffs,
          reports: reports,
          issues: issues,
        );
      });

  Future<TavernAuthoringRegexTest> _testAuthoringRegex(
    String id,
    int revision,
    List<String> changeIds,
    String resourceId,
    String scriptPath,
    String text,
  ) => _authoringOperation(() async {
    final selected = changeIds.toSet();
    final draft = _authoringView(_requireAuthoringDraft(id, revision));
    final candidate = _materializeAuthoring(draft, selected, includeDiffs: false).candidates[resourceId];
    if (candidate == null) _authoringInvalid('The selected source is not in this draft.', resourceId: resourceId);
    final value = _authoringLookup(candidate, _authoringPointer(scriptPath));
    if (!value.exists || value.value is! Map<String, Object?>) {
      _authoringInvalid('The script path must point to a regex object.', resourceId: resourceId);
    }
    final script = RegexScript.fromJson(value.value! as Map<String, Object?>);
    final compilation = await RegexEngine.checkScript(script, _regexWorker);
    final match = compilation.status == RegexCompileStatus.compatible
        ? await _regexWorker.hasMatch(script.findRegex, text)
        : null;
    return TavernAuthoringRegexTest(
      draftId: id,
      draftRevision: revision,
      physicalResourceId: resourceId,
      scriptPath: scriptPath,
      compilation: compilation,
      match: match,
    );
  });

  Future<({List<TavernImportReport> reports, List<TavernImportFinding> issues})> _inspectAuthoringSource(
    TavernAuthoringSource source,
    Map<String, Object?> candidate,
  ) async {
    final reports = <TavernImportReport>[];
    final issues = <TavernImportFinding>[];
    final at = _clock().toUtc();
    try {
      switch (source.target.kind) {
        case TavernAuthoringTargetKind.character:
          const CardCodec().validateAuthority(candidate);
          final diagnostics = await _checkCardRegex(candidate['data']! as Map<String, Object?>);
          reports.add(
            assessImport(
              kind: TavernImportKind.character,
              document: candidate,
              embeddedAssetPaths: source.mediaRefs,
              regexDiagnostics: diagnostics,
              checkedAt: at,
            ),
          );
        case TavernAuthoringTargetKind.lorebook:
          final raw = _authoringBook(candidate);
          final book = WorldInfoBook.fromJson(id: source.target.id, source: WorldInfoSource.global, json: raw);
          final diagnostics = await _checkWorldBookRegex(book);
          reports.add(
            assessImport(kind: TavernImportKind.lorebook, document: raw, regexDiagnostics: diagnostics, checkedAt: at),
          );
        case TavernAuthoringTargetKind.preset:
          final raw = _authoringObject(candidate['raw'], 'The preset raw value must be an object.');
          final envelope = candidate['envelope'] == null
              ? null
              : _authoringObject(candidate['envelope'], 'The preset envelope must be an object.');
          final parsed = const PresetCodec().validate(raw, envelope: envelope);
          final diagnostics = await inspectRegexScripts(_map(raw['extensions'])['regex_scripts'], _regexWorker);
          reports.add(
            assessImport(
              kind: TavernImportKind.preset,
              document: raw,
              envelope: envelope,
              regexDiagnostics: diagnostics,
              presetIssues: parsed.issues,
              checkedAt: at,
            ),
          );
        case TavernAuthoringTargetKind.regexLibrary:
          final scripts = candidate['scripts'];
          if (candidate['version'] != 1 || scripts is! List<Object?>) {
            throw const FormatException('The regex library must contain version 1 and a scripts array.');
          }
          for (var index = 0; index < scripts.length; index++) {
            final record = scripts[index];
            final path = '\$.scripts[$index].raw';
            if (record is! Map<String, Object?> || record['raw'] is! Map<String, Object?>) {
              issues.add(
                TavernImportFinding(
                  path: path,
                  code: 'invalid-rule',
                  message: 'The regex record must contain a raw object.',
                  kind: TavernImportFindingKind.invalid,
                ),
              );
              continue;
            }
            final raw = record['raw']! as Map<String, Object?>;
            final diagnostic = await inspectRegexScript(raw, _regexWorker, path: path);
            reports.add(
              assessImport(
                kind: TavernImportKind.regex,
                document: raw,
                path: path,
                regexDiagnostics: [diagnostic],
                checkedAt: at,
              ),
            );
          }
      }
    } on TavernPresetImportError catch (error) {
      issues.addAll([
        for (final issue in error.issues)
          TavernImportFinding(
            path: issue.path,
            code: issue.code,
            message: issue.message,
            kind: issue.severity == TavernPresetIssueSeverity.error
                ? TavernImportFindingKind.invalid
                : TavernImportFindingKind.conditional,
          ),
      ]);
    } on TavernImportError catch (error) {
      issues.add(_authoringStructureIssue(error.message));
    } on FormatException catch (error) {
      issues.add(_authoringStructureIssue(error.message));
    }
    return (reports: reports, issues: issues);
  }
}

TavernImportFinding _authoringStructureIssue(String message) =>
    TavernImportFinding(path: r'$', code: 'invalid-source', message: message, kind: TavernImportFindingKind.invalid);

Map<String, Object?> _authoringObject(Object? value, String message) {
  if (value is! Map<String, Object?>) throw FormatException(message);
  return value;
}

Map<String, Object?> _authoringBook(Map<String, Object?> document) {
  if (document.containsKey('entries') || document['format'] != 'dshgo-lorebook') return document;
  if (document['version'] != 1 || (document['stWorldName'] != null && document['stWorldName'] is! String)) {
    throw const FormatException('Unsupported or invalid stored lorebook.');
  }
  return _authoringObject(document['book'], 'The lorebook envelope must contain a book object.');
}

Never _authoringSourceMissing(TavernAuthoringTarget target) => throw TavernAuthoringException(
  'not_found',
  'The authoring source does not exist.',
  physicalResourceId: target.physicalResourceId,
);

TavernAuthoringTarget _authoringTarget(Map<String, Object?> data) => TavernAuthoringTarget(
  kind: TavernAuthoringTargetKind.values.byName(data['kind']! as String),
  id: data['id']! as String,
);

TavernAuthoringDraft _authoringView(StoredAuthoringDraft stored) {
  final draft = TavernAuthoringDraft(
    id: stored.id,
    draftRevision: stored.revision,
    createdAt: stored.createdAt,
    updatedAt: stored.updatedAt,
    sources: [
      for (final value in stored.data['sources']! as List<Object?>)
        _authoringSourceView(value! as Map<String, Object?>),
    ],
    changes: [
      for (final value in stored.data['changes']! as List<Object?>) _authoringChange(value! as Map<String, Object?>),
    ],
  );
  _validateAuthoringTargets(draft.sources.map((source) => source.target));
  if (draft.draftRevision < 1 ||
      draft.sources.any((source) => !_authoringFiniteJson(source.base)) ||
      draft.changes.any((change) => !_authoringFiniteJson(change.value))) {
    _authoringInvalid('A stored draft must have a positive revision and finite JSON.');
  }
  _validateAuthoringChanges(draft);
  return draft;
}

TavernAuthoringSource _authoringSourceView(Map<String, Object?> data) {
  final target = _authoringTarget(data['target']! as Map<String, Object?>);
  final token = data['authorityRevision'];
  final origin = TavernAuthoringSourceOrigin.values.byName(data['origin'] as String? ?? 'existing');
  if (origin == TavernAuthoringSourceOrigin.seed &&
      (token != null ||
          data['present'] != false ||
          (target.kind != TavernAuthoringTargetKind.character && target.kind != TavernAuthoringTargetKind.lorebook))) {
    _authoringInvalid('The saved seed source is invalid.', resourceId: target.physicalResourceId);
  }
  TavernAuthorityRevision? revision;
  if (token != null) {
    if (token is! Map<String, Object?> ||
        token['domainId'] is! String ||
        (token['domainId']! as String).isEmpty ||
        token['revision'] is! int ||
        (token['revision']! as int) < 1 ||
        data['present'] != true ||
        data['rawText'] is! String ||
        (data['identityText'] != null && data['identityText'] is! String) ||
        (target.kind == TavernAuthoringTargetKind.character && data['identityText'] is! String) ||
        (target.kind != TavernAuthoringTargetKind.character && target.kind != TavernAuthoringTargetKind.lorebook)) {
      _authoringInvalid('The saved authority base is invalid.', resourceId: target.physicalResourceId);
    }
    revision = TavernAuthorityRevision(domainId: token['domainId']! as String, revision: token['revision']! as int);
  }
  return TavernAuthoringSource(
    target: target,
    origin: origin,
    sourceFormat: data['sourceFormat']! as String,
    base: data['base']! as Map<String, Object?>,
    mediaRefs: (data['mediaRefs']! as List<Object?>).cast<String>().toList(),
    authorityRevision: revision,
    applySupported: revision != null,
  );
}

Map<String, Object?> _authoringRevisionJson(TavernAuthorityRevision revision) => {
  'domainId': revision.domainId,
  'revision': revision.revision,
};

TavernAuthoringChange _authoringChange(Map<String, Object?> data) => TavernAuthoringChange(
  id: data['id']! as String,
  physicalResourceId: data['physicalResourceId']! as String,
  path: data['path']! as String,
  operation: TavernAuthoringChangeKind.values.byName(data['operation']! as String),
  value: data['value'],
  dependsOn: (data['dependsOn']! as List<Object?>).cast<String>(),
);

Map<String, Object?> _authoringChangeJson(TavernAuthoringChange change) => {
  'id': change.id,
  'physicalResourceId': change.physicalResourceId,
  'path': change.path,
  'operation': change.operation.name,
  'value': change.value,
  'dependsOn': change.dependsOn,
};

List<TavernAuthoringChange> _captureAuthoringChanges(List<TavernAuthoringChange> changes) {
  try {
    final encoded = jsonEncode([for (final change in changes) _authoringChangeJson(change)]);
    final captured = jsonDecode(encoded) as List<Object?>;
    return [for (final value in captured) _authoringChange(value! as Map<String, Object?>)];
  } on JsonUnsupportedObjectError {
    _authoringInvalid('Changes must contain finite JSON values.');
  }
}

Never _authoringInvalid(String message, {String? resourceId, String? changeId}) =>
    throw TavernAuthoringException('invalid_change', message, physicalResourceId: resourceId, changeId: changeId);

void _validateAuthoringTargets(Iterable<TavernAuthoringTarget> targets) {
  final ids = <String>{};
  for (final target in targets) {
    if (target.id.isEmpty ||
        !ids.add(target.physicalResourceId) ||
        (target.kind == TavernAuthoringTargetKind.character && !CharacterLibrary.isValidId(target.id)) ||
        (target.kind == TavernAuthoringTargetKind.regexLibrary && target.id != 'global')) {
      _authoringInvalid('Authoring targets must have distinct valid identifiers.');
    }
    if (target.kind == TavernAuthoringTargetKind.lorebook) {
      try {
        _requireBookId(target.id);
      } on ArgumentError {
        _authoringInvalid('Use a filename-safe lorebook id.');
      }
    }
  }
  if (ids.isEmpty) _authoringInvalid('Select at least one source.');
}

bool _authoringFiniteJson(Object? value) {
  if (value is num) return value.isFinite;
  if (value is Map<String, Object?>) return value.values.every(_authoringFiniteJson);
  if (value is List<Object?>) return value.every(_authoringFiniteJson);
  return value == null || value is String || value is bool;
}

void _validateAuthoringChanges(TavernAuthoringDraft draft) {
  final resources = draft.sources.map((source) => source.physicalResourceId).toSet();
  final prior = <String, TavernAuthoringChange>{};
  final dependencies = <String, Set<String>>{};
  for (final change in draft.changes) {
    if (change.id.isEmpty ||
        prior.containsKey(change.id) ||
        !resources.contains(change.physicalResourceId) ||
        (change.operation == TavernAuthoringChangeKind.remove && change.value != null)) {
      _authoringInvalid('A change has an invalid id, source or remove value.', changeId: change.id);
    }
    _authoringPointer(change.path);
    final closure = <String>{};
    for (final dependency in change.dependsOn) {
      if (!prior.containsKey(dependency)) {
        _authoringInvalid('Dependencies must refer to earlier changes.', changeId: change.id);
      }
      closure
        ..add(dependency)
        ..addAll(dependencies[dependency]!);
    }
    for (final earlier in prior.values) {
      if (earlier.physicalResourceId == change.physicalResourceId &&
          (earlier.path == change.path ||
              earlier.path.startsWith('${change.path}/') ||
              change.path.startsWith('${earlier.path}/')) &&
          !closure.contains(earlier.id)) {
        _authoringInvalid('Overlapping changes require an explicit dependency.', changeId: change.id);
      }
    }
    prior[change.id] = change;
    dependencies[change.id] = closure;
  }
}

({Map<String, Map<String, Object?>> candidates, List<TavernAuthoringDiff> diffs}) _materializeAuthoring(
  TavernAuthoringDraft draft,
  Set<String> selected, {
  bool includeDiffs = true,
}) {
  final known = draft.changes.map((change) => change.id).toSet();
  if (!known.containsAll(selected)) _authoringInvalid('The selection contains an unknown change.');
  final candidates = <String, Map<String, Object?>>{
    for (final source in draft.sources) source.physicalResourceId: _authoringCopy(source.base)! as Map<String, Object?>,
  };
  final diffs = <TavernAuthoringDiff>[];
  for (final change in draft.changes) {
    if (!selected.contains(change.id)) continue;
    if (!selected.containsAll(change.dependsOn)) {
      throw TavernAuthoringException(
        'missing_dependency',
        'Select the required earlier changes.',
        physicalResourceId: change.physicalResourceId,
        changeId: change.id,
      );
    }
    final document = candidates[change.physicalResourceId]!;
    final tokens = _authoringPointer(change.path);
    final before = _authoringLookup(document, tokens);
    final beforeValue = includeDiffs ? _authoringCopy(before.value) : null;
    final after = _applyAuthoringChange(document, tokens, change);
    candidates[change.physicalResourceId] = after;
    if (includeDiffs) {
      final value = _authoringLookup(after, tokens);
      diffs.add(
        TavernAuthoringDiff(
          changeId: change.id,
          physicalResourceId: change.physicalResourceId,
          path: change.path,
          beforeExists: before.exists,
          before: beforeValue,
          afterExists: value.exists,
          after: _authoringCopy(value.value),
        ),
      );
    }
  }
  return (candidates: candidates, diffs: diffs);
}

Object? _authoringCopy(Object? value) =>
    value is Map<String, Object?> || value is List<Object?> ? jsonDecode(jsonEncode(value)) : value;

List<String> _authoringPointer(String path) {
  if (path.isEmpty) return const [];
  if (!path.startsWith('/') || RegExp(r'~(?![01])').hasMatch(path)) {
    _authoringInvalid('Use an escaped JSON Pointer.');
  }
  return [for (final token in path.substring(1).split('/')) token.replaceAll('~1', '/').replaceAll('~0', '~')];
}

int? _authoringIndex(String token, int length) {
  final index = int.tryParse(token);
  return index != null && index >= 0 && index < length && '$index' == token ? index : null;
}

({bool exists, Object? value}) _authoringLookup(Object? root, List<String> tokens) {
  var value = root;
  for (final token in tokens) {
    if (value is Map<String, Object?> && value.containsKey(token)) {
      value = value[token];
    } else if (value is List<Object?>) {
      final index = _authoringIndex(token, value.length);
      if (index == null) return (exists: false, value: null);
      value = value[index];
    } else {
      return (exists: false, value: null);
    }
  }
  return (exists: true, value: value);
}

Map<String, Object?> _applyAuthoringChange(
  Map<String, Object?> document,
  List<String> tokens,
  TavernAuthoringChange change,
) {
  Never invalid(String message) =>
      _authoringInvalid(message, resourceId: change.physicalResourceId, changeId: change.id);
  final remove = change.operation == TavernAuthoringChangeKind.remove;
  if (tokens.isEmpty) {
    if (remove || change.value is! Map<String, Object?>) invalid('The source root must remain an object.');
    return _authoringCopy(change.value)! as Map<String, Object?>;
  }
  final parent = _authoringLookup(document, tokens.sublist(0, tokens.length - 1));
  final container = parent.value;
  final key = tokens.last;
  if (parent.exists && container is Map<String, Object?>) {
    if (remove) {
      if (!container.containsKey(key)) invalid('The removed key does not exist.');
      container.remove(key);
    } else {
      container[key] = _authoringCopy(change.value);
    }
  } else if (parent.exists && container is List<Object?> && !remove) {
    final index = _authoringIndex(key, container.length);
    if (index == null) invalid('Replace the whole array to change its length or order.');
    container[index] = _authoringCopy(change.value);
  } else {
    invalid('The change parent must be an existing object or array.');
  }
  return document;
}
