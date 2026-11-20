part of 'engine.dart';

extension _AuthoringSeeds on TavernEngine {
  Future<TavernAuthoringDraft> _createAuthoringSeed(TavernAuthoringSeedInput input) => _authoringOperation(() async {
    final bytes = Uint8List.fromList(input.bytes);
    final kind = input.kind;
    final fileName = input.fileName;
    if (kind != TavernAuthoringTargetKind.character && kind != TavernAuthoringTargetKind.lorebook) {
      throw const TavernAuthoringException('unsupported_seed', 'Only character and lorebook seeds are supported.');
    }
    final suffix = _store.newAuthoringOperationId().replaceAll('-', '');
    final target = TavernAuthoringTarget(
      kind: kind,
      id: kind == TavernAuthoringTargetKind.character ? 'card-$suffix' : 'seed-$suffix',
    );
    final source = <String, Object?>{
      'target': {'kind': kind.name, 'id': target.id},
      'origin': 'seed',
      'present': false,
      'mediaRefs': <String>[],
      'fileName': fileName,
    };
    final blobs = <String, Uint8List>{};
    final changes = <TavernAuthoringChange>[];
    if (kind == TavernAuthoringTargetKind.character) {
      final decoded = await _decodeAuthoringCardSeed(bytes);
      final seed = decoded.seed;
      source.addAll({
        'base': seed.json,
        'rawText': seed.rawText,
        'sourceFormat': seed.sourceFormat.name,
        'mediaRefs': seed.assets.keys.toList(),
      });
      blobs['original.${seed.sourceFormat.name}'] = seed.originalBytes;
      for (final asset in seed.assets.entries) {
        blobs['resources/${asset.key}'] = asset.value;
      }
      final conversion = decoded.conversion;
      if (conversion != null) {
        changes.add(
          TavernAuthoringChange(
            id: 'seed-upgrade-v3',
            physicalResourceId: target.physicalResourceId,
            path: '',
            operation: TavernAuthoringChangeKind.set,
            value: conversion,
          ),
        );
      }
    } else {
      final text = decodeAuthoringText(bytes);
      final document = _decodeObject(text.text, 'Lorebook');
      if (!_authoringFiniteJson(document)) {
        _authoringInvalid('Seeds must contain finite JSON.');
      }
      source.addAll({
        'base': document,
        'rawText': text.rawText,
        'sourceFormat': !document.containsKey('entries') && document['format'] == 'dshgo-lorebook'
            ? 'dshgo-lorebook'
            : 'st-json',
      });
      blobs['original.json'] = bytes;
    }
    return _authoringView(
      _store.createAuthoringSeedDraftData(
        {
          'version': 1,
          'sources': [source],
          'changes': [for (final change in changes) _authoringChangeJson(change)],
        },
        target.physicalResourceId,
        blobs,
      ),
    );
  });

  Future<TavernAuthoringSaveAsReceipt> _saveAuthoringAsNew(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required String operationId,
    required TavernAuthoringMediaSelection media,
    String? domainId,
  }) => _authoringOperation(() async {
    final selected = List<String>.of(changeIds)..sort();
    final domain = domainId ?? _authoringAuthority.domainId;
    if (draftId.isEmpty ||
        draftRevision < 1 ||
        operationId.isEmpty ||
        domain.isEmpty ||
        selected.toSet().length != selected.length ||
        selected.any((id) => id.isEmpty)) {
      _authoringInvalid('Use a valid draft revision and distinct change identifiers.', resourceId: physicalResourceId);
    }
    final parameters = <String, Object?>{
      'method': 'saveAsNew',
      'draftId': draftId,
      'draftRevision': draftRevision,
      'physicalResourceId': physicalResourceId,
      'changeIds': selected,
      'media': media.name,
    };
    final replayed = replayAuthoringSaveAs(_authoringAuthority, domain, operationId, parameters);
    if (replayed != null) {
      return replayed;
    }
    if (domain != _authoringAuthority.domainId) {
      _authoringAuthorityConflict(physicalResourceId);
    }
    final stored = _requireAuthoringDraft(draftId, draftRevision);
    final draft = _authoringView(stored);
    final source = draft.sources.where((source) => source.physicalResourceId == physicalResourceId).firstOrNull;
    if (source == null) {
      _authoringInvalid('The resource is not in this draft.', resourceId: physicalResourceId);
    }
    if (source.target.kind != TavernAuthoringTargetKind.character &&
        source.target.kind != TavernAuthoringTargetKind.lorebook) {
      _unsupportedAuthoringSaveAs(physicalResourceId);
    }
    final selectedSet = selected.toSet();
    if (draft.changes.any(
      (change) => selectedSet.contains(change.id) && change.physicalResourceId != physicalResourceId,
    )) {
      _authoringInvalid('One adoption can select only one physical resource.', resourceId: physicalResourceId);
    }
    final candidate = _materializeAuthoring(draft, selectedSet, includeDiffs: false).candidates[physicalResourceId]!;
    final saved = (stored.data['sources']! as List<Object?>).cast<Map<String, Object?>>().firstWhere(
      (value) => _authoringTarget(value['target']! as Map<String, Object?>).physicalResourceId == physicalResourceId,
    );
    final text = _stateJsonEqual(source.base, candidate) ? saved['rawText']! as String : jsonEncode(candidate);
    if (media == TavernAuthoringMediaSelection.seedCaptured && source.origin != TavernAuthoringSourceOrigin.seed) {
      _unsupportedAuthoringSaveAs(physicalResourceId);
    }
    if (media == TavernAuthoringMediaSelection.currentSource &&
        (source.target.kind != TavernAuthoringTargetKind.character ||
            source.origin != TavernAuthoringSourceOrigin.existing ||
            source.authorityRevision == null)) {
      _unsupportedAuthoringSaveAs(physicalResourceId);
    }
    if (source.target.kind == TavernAuthoringTargetKind.character) {
      AuthoringCardMedia? capturedMedia;
      if (media == TavernAuthoringMediaSelection.seedCaptured) {
        final blobs = _store.readAuthoringSeedBlobs(draftId, physicalResourceId);
        final format = TavernCardFormat.values.byName(source.sourceFormat);
        final original = blobs['original.${format.name}'];
        if (original == null || source.mediaRefs.any((path) => !blobs.containsKey('resources/$path'))) {
          _unsupportedAuthoringSaveAs(physicalResourceId);
        }
        capturedMedia = AuthoringCardMedia(
          sourceFormat: format,
          originalBytes: original,
          assets: {for (final path in source.mediaRefs) path: blobs['resources/$path']!},
          png: format == TavernCardFormat.png ? original : null,
          fileName: saved['fileName'] as String?,
        );
      }
      return _library.importAuthoringEnvelope(
        text,
        domainId: domain,
        operationId: operationId,
        parameters: parameters,
        media: media,
        mediaRefs: source.mediaRefs,
        sourceFormat: source.sourceFormat,
        seedMedia: capturedMedia,
        currentSource: media == TavernAuthoringMediaSelection.currentSource
            ? (
                id: source.target.id,
                expected: AuthoringExpectation(
                  revision: source.authorityRevision!,
                  before: AuthoringResourceSnapshot.fromJson(saved),
                ),
              )
            : null,
        check: () {
          _requireAuthoringDraft(draftId, draftRevision);
        },
        inspect: _inspectCardReport,
      );
    }
    return _bookOperation(() async {
      final replayed = replayAuthoringSaveAs(_authoringAuthority, domain, operationId, parameters);
      if (replayed != null) {
        return replayed;
      }
      if (domain != _authoringAuthority.domainId) {
        _authoringAuthorityConflict(physicalResourceId);
      }
      String id;
      do {
        id = _store.newAuthoringOperationId();
      } while (await FileSystemEntity.type('${directory.path}/lorebooks/$id.json', followLinks: false) !=
          FileSystemEntityType.notFound);
      final result = <String, Object?>{'copiedMedia': <String>[], 'issues': <Object?>[]};
      final request = AuthoringWriteRequest(
        domainId: domain,
        operationId: operationId,
        physicalResourceId: 'lorebook:$id',
        parameters: {...parameters, 'saveAsResult': result},
      );
      try {
        final receipt = await _writeBookNow(
          id,
          null,
          exactText: text,
          request: request,
          requireMissing: true,
          check: () {
            _requireAuthoringDraft(draftId, draftRevision);
          },
        );
        return authoringSaveAsReceipt(receipt, result);
      } on TavernAuthoringException catch (error) {
        final receipt = error.receipt;
        if (error.code != 'resource_write_failed' ||
            receipt == null ||
            receipt.domainId != domain ||
            receipt.operationId != operationId ||
            receipt.physicalResourceId != request.physicalResourceId) {
          rethrow;
        }
        return authoringSaveAsReceipt(receipt, result);
      }
    });
  });
}

Future<({DecodedCardSeed seed, Map<String, Object?>? conversion})> _decodeAuthoringCardSeed(Uint8List bytes) =>
    Isolate.run(() {
      const codec = CardCodec();
      final seed = codec.decodeSeed(bytes);
      if (!_authoringFiniteJson(seed.json)) {
        _authoringInvalid('Seeds must contain finite JSON.');
      }
      Map<String, Object?>? conversion;
      if (seed.json['spec'] == null || seed.json['spec'] == 'chara_card_v2') {
        try {
          conversion = codec.decode(Uint8List.fromList(utf8.encode(seed.rawText))).json;
        } on TavernImportError {
          // A valid container can hold an unfinished raw card. Keep that seed;
          // an explicit author change must repair it before a real adoption.
        }
      }
      return (seed: seed, conversion: conversion);
    });

Never _unsupportedAuthoringSaveAs(String resourceId) => throw TavernAuthoringException(
  'unsupported_save_as',
  'This source does not support the selected Save As media mode.',
  physicalResourceId: resourceId,
);
