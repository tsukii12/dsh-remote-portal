part of 'engine.dart';

extension _GameplayDraftExports on TavernEngine {
  Future<_GameplayExportPlan> _captureGameplayDraftExport(TavernGameplayExportRequest request) async {
    final stored = _requireAuthoringDraft(request.draftId!, request.draftRevision!);
    final savedText = jsonEncode(stored.data);
    final draft = _authoringView(stored);
    final candidates = _materializeAuthoring(draft, request.changeIds.toSet(), includeDiffs: false).candidates;
    final sources = {for (final source in draft.sources) source.physicalResourceId: source};
    final savedSources = <String, Map<String, Object?>>{
      for (final raw in (stored.data['sources']! as List<Object?>).cast<Map<String, Object?>>())
        _authoringTarget(raw['target']! as Map<String, Object?>).physicalResourceId: raw,
    };
    final primaryId = request.physicalResourceId!;
    final primary = sources[primaryId];
    if (primary == null || primary.target.kind != TavernAuthoringTargetKind.character) {
      _invalidGameplayExport('The primary draft resource must be an actual character candidate.');
    }
    const reserved = {'formatVersion', 'packId', 'packVersion', 'dshgo', 'schemaPatches', 'resources', 'references'};
    if (request.manifestFields.keys.any(reserved.contains)) {
      _invalidGameplayExport('Additional manifest fields cannot replace protocol fields.');
    }
    final issues = <Map<String, Object?>>[];
    final primarySource = <String, Object?>{
      'kind': 'draft',
      'draftId': draft.id,
      'draftRevision': draft.draftRevision,
      'physicalResourceId': primaryId,
      'origin': primary.origin.name,
    };
    final primaryCandidate = candidates[primaryId]!;
    final data = primaryCandidate['data'];
    final extensions = data is Map<String, Object?> ? data['extensions'] : null;
    if (data is! Map<String, Object?> || extensions != null && extensions is! Map<String, Object?>) {
      issues.add(
        _gameplayExportIssue(
          'export_primary_card',
          'The selected character must expose its real data/extensions object.',
          source: primarySource,
        ),
      );
    }
    final present = extensions is Map<String, Object?> && extensions.containsKey('dshgo');
    final raw = extensions is Map<String, Object?> ? extensions['dshgo'] : null;
    final schemaPatches = _gameplayDraftSchemaPatches(raw, request.schemaRoots, primarySource, issues);
    final declarations = <Map<String, Object?>>[];
    final mappings = <Map<String, Object?>>[];
    final files = <String, Uint8List>{};
    final media = <String, _AuthoringCapturedResource>{};
    final used = <String>{primaryId};

    void checkDraft() {
      final fresh = _requireAuthoringDraft(draft.id, draft.draftRevision);
      if (jsonEncode(fresh.data) != savedText) {
        throw const TavernAuthoringException('capture_conflict', 'The saved draft changed during export capture.');
      }
    }

    for (final selection in request.draftResources) {
      final source = sources[selection.physicalResourceId];
      if (source == null) {
        _invalidGameplayExport('Each selected resource must belong to this draft.');
      }
      used.add(source.physicalResourceId);
      final sourceRef = <String, Object?>{
        'kind': 'draft',
        'draftId': draft.id,
        'draftRevision': draft.draftRevision,
        'physicalResourceId': source.physicalResourceId,
        'pointer': ?selection.pointer,
        'assetUri': ?selection.assetUri,
        'media': ?selection.media?.name,
      };
      final declaration = <String, Object?>{
        'localId': selection.localId,
        'kind': selection.kind,
        'path': selection.path,
        if (selection.entries.isNotEmpty) 'entries': [for (final entry in selection.entries) entry.toJson()],
      };
      declarations.add(declaration);
      mappings.add({...declaration, 'source': sourceRef});
      if (!isSafeCardAssetPath(selection.path) ||
          selection.path == 'pack.json' ||
          selection.path.startsWith('\uFEFF')) {
        issues.add(
          _gameplayExportIssue(
            'export_resource_path',
            'This new ZIP path cannot be preserved exactly by the existing pack codec.',
            source: sourceRef,
            path: selection.path,
          ),
        );
        continue;
      }

      final Uint8List bytes;
      final pointer = selection.pointer;
      if (pointer != null) {
        final tokens = _gameplayCompositionPointer(pointer);
        final value = tokens == null ? null : _authoringLookup(candidates[source.physicalResourceId], tokens);
        if (value == null || !value.exists) {
          issues.add(
            _gameplayExportIssue(
              'export_resource_pointer',
              'The selected JSON Pointer does not identify an actual candidate value.',
              source: sourceRef,
              path: pointer,
            ),
          );
          continue;
        }
        // Preserve a complete unchanged original when one exists; subvalues and
        // edited candidates keep their full JSON values without invented defaults.
        final saved = savedSources[source.physicalResourceId]!;
        final original = saved['rawText'];
        final text =
            tokens!.isEmpty && original is String && _stateJsonEqual(candidates[source.physicalResourceId], source.base)
            ? original
            : jsonEncode(value.value);
        bytes = Uint8List.fromList(utf8.encode(text));
      } else {
        final mode = selection.media!;
        final uri = selection.assetUri!;
        final path = embeddedCardAssetPath(uri);
        if (uri != 'ccdefault:' && path == null) {
          issues.add(
            _gameplayExportIssue(
              'export_media_uri',
              'Choose an actual captured local asset URI or ccdefault:; remote resources are not fetched.',
              source: sourceRef,
              path: uri,
            ),
          );
          continue;
        }
        if (source.target.kind != TavernAuthoringTargetKind.character ||
            mode == TavernAuthoringMediaSelection.none ||
            mode == TavernAuthoringMediaSelection.seedCaptured && source.origin != TavernAuthoringSourceOrigin.seed ||
            mode == TavernAuthoringMediaSelection.currentSource &&
                (source.origin != TavernAuthoringSourceOrigin.existing || source.authorityRevision == null)) {
          issues.add(
            _gameplayExportIssue(
              'export_media_source',
              'This source does not provide bytes under the selected explicit media mode.',
              source: sourceRef,
            ),
          );
          continue;
        }
        var captured = media[source.physicalResourceId];
        if (captured == null) {
          captured = await _captureAuthoringResource(
            source.target,
            seedDraft: mode == TavernAuthoringMediaSelection.seedCaptured ? stored : null,
          );
          if (mode == TavernAuthoringMediaSelection.currentSource) {
            final expected = source.authorityRevision!;
            final before = AuthoringResourceSnapshot.fromJson(savedSources[source.physicalResourceId]!);
            final ledger = captured.ledger;
            if (ledger == null ||
                ledger.domainId != expected.domainId ||
                ledger.revision != expected.revision ||
                ledger.snapshot == null ||
                !ledger.snapshot!.sameAs(before) ||
                !captured.snapshot.sameAs(before)) {
              _authoringAuthorityConflict(source.physicalResourceId);
            }
          }
          media[source.physicalResourceId] = captured;
        }
        final selected = uri == 'ccdefault:'
            ? mode == TavernAuthoringMediaSelection.seedCaptured
                  ? source.sourceFormat == 'png'
                        ? captured.media['original.png']
                        : null
                  : captured.media['source.png']
            : captured.media['resources/$path'];
        if (selected == null) {
          issues.add(
            _gameplayExportIssue(
              'export_media_missing',
              'The requested media is absent from the captured source.',
              source: sourceRef,
              path: uri,
            ),
          );
          continue;
        }
        bytes = Uint8List.fromList(selected);
      }
      final prior = files[selection.path];
      if (prior != null && !_stateJsonEqual(prior, bytes)) {
        issues.add(
          _gameplayExportIssue(
            'export_resource_conflict',
            'Two selected resources assign different bytes to the same output path.',
            source: sourceRef,
            path: selection.path,
          ),
        );
      } else {
        files[selection.path] = bytes;
      }
    }

    final manifest = <String, Object?>{
      ...request.manifestFields,
      'formatVersion': 1,
      'packId': request.packId,
      'packVersion': request.packVersion,
      if (present) 'dshgo': _authoringCopy(raw),
      'schemaPatches': schemaPatches,
      'resources': declarations,
      'references': request.references,
    };
    Map<String, Object?>? inspection;
    try {
      validateGameplayPackParts(manifest, files);
      inspection = await _inspectGameplayPackParts(manifest, files, request.at);
    } on FormatException catch (error) {
      issues.add(_gameplayExportIssue('export_pack_structure', error.message.toString()));
    } on TavernImportError catch (error) {
      issues.add(_gameplayExportIssue('export_pack_structure', error.toString()));
    }
    final sourceRows = <Map<String, Object?>>[
      for (final source in draft.sources)
        if (used.contains(source.physicalResourceId))
          {
            'kind': 'draft',
            'draftId': draft.id,
            'draftRevision': draft.draftRevision,
            'physicalResourceId': source.physicalResourceId,
            'origin': source.origin.name,
            'sourceFormat': source.sourceFormat,
            'baseHash': _directorHash(source.base),
            'candidateHash': _directorHash(candidates[source.physicalResourceId]),
            if (source.authorityRevision != null)
              'authorityRevision': _authoringRevisionJson(source.authorityRevision!),
            if (source.physicalResourceId == primaryId && inspection != null) 'inspection': inspection['dshgo'],
          },
    ];
    if (inspection != null) {
      final declaration = inspection['dshgo']! as Map<String, Object?>;
      for (final issue in (declaration['issues']! as List<Object?>).cast<Map<String, Object?>>()) {
        issues.add({
          ..._gameplayExportIssue(
            'export_dshgo_diagnostic',
            'The original DSH declaration has a native diagnostic.',
            blocking: false,
            source: primarySource,
          ),
          'diagnostic': issue,
        });
      }
      for (final value in (inspection['resources']! as List<Object?>).cast<Map<String, Object?>>()) {
        final mapping = mappings.singleWhere((row) => row['localId'] == value['localId']);
        mapping['inspection'] = value;
        for (final checked in (value['reports']! as List<Object?>).cast<Map<String, Object?>>()) {
          final report = checked['report']! as Map<String, Object?>;
          for (final finding in (report['findings']! as List<Object?>).cast<Map<String, Object?>>()) {
            issues.add({
              ..._gameplayExportIssue(
                'export_resource_diagnostic',
                'The selected resource has a native intake diagnostic.',
                blocking: false,
                source: mapping['source']! as Map<String, Object?>,
                path: value['path']! as String,
              ),
              'diagnostic': finding,
              'pointer': checked['pointer'],
            });
          }
        }
      }
    }
    Future<void> recheck() => _recheckCapturedAuthoringResources(media.values, check: checkDraft);
    await recheck();
    final preview = _gameplayExportPreview(
      request: request,
      sources: sourceRows,
      mergedRaw: manifest,
      idMappings: const [],
      resourceMappings: mappings,
      issues: issues,
      files: files,
      facts: {
        'draftDataHash': _directorHash(stored.data),
        'media': [
          for (final captured in media.values)
            {
              'physicalResourceId': captured.target.physicalResourceId,
              'snapshot': captured.snapshot.toJson(),
              if (captured.ledger != null)
                'knownAuthority': {
                  'domainId': captured.ledger!.domainId,
                  'revision': captured.ledger!.revision,
                  'snapshot': captured.ledger!.snapshot?.toJson(),
                },
              'seedDraftId': ?captured.seedDraftId,
              'seedRevision': ?captured.seedRevision,
            },
        ],
      },
    );
    return _GameplayExportPlan(request: request, preview: preview, files: files, recheck: recheck);
  }
}

List<Map<String, Object?>> _gameplayDraftSchemaPatches(
  Object? raw,
  List<String> roots,
  Map<String, Object?> source,
  List<Map<String, Object?>> issues,
) {
  final state = raw is Map<String, Object?> ? raw['state'] : null;
  final hasSchema = state is Map<String, Object?> && state.containsKey('schema');
  final schema = state is Map<String, Object?> ? state['schema'] : null;
  final result = <Map<String, Object?>>[];
  final prior = <List<String>>[];
  for (final root in roots) {
    final tokens = _gameplayCompositionPointer(root);
    if (tokens == null || !hasSchema) {
      issues.add(
        _gameplayExportIssue(
          'export_schema_root',
          'Each schema root must identify an actual node in the candidate schema.',
          source: source,
          path: root,
        ),
      );
      continue;
    }
    if (prior.any((path) => _gameplayPathPrefix(path, tokens) || _gameplayPathPrefix(tokens, path))) {
      issues.add(
        _gameplayExportIssue(
          'export_schema_overlap',
          'Schema roots within one new pack must not overlap.',
          source: source,
          path: root,
        ),
      );
    }
    prior.add(tokens);
    var node = schema;
    var exists = true;
    for (final token in tokens) {
      if (!_gameplayObjectSchema(node)) {
        exists = false;
        break;
      }
      final properties = (node! as Map<String, Object?>)['properties'];
      if (properties is! Map<String, Object?> || !properties.containsKey(token)) {
        exists = false;
        break;
      }
      node = properties[token];
    }
    if (!exists) {
      issues.add(
        _gameplayExportIssue(
          'export_schema_root',
          'A schema root must follow existing object properties, without inferred parents or array indexes.',
          source: source,
          path: root,
        ),
      );
      continue;
    }
    result.add({'path': root, 'node': _authoringCopy(node)});
  }
  if (hasSchema && roots.isEmpty) {
    issues.add(
      _gameplayExportIssue(
        'schema_roots_required',
        'The original schema is preserved without composable schema roots.',
        blocking: false,
        source: source,
        path: '/state/schema',
      ),
    );
  }
  return result;
}
