part of 'engine.dart';

extension _GameplayCastOperations on TavernEngine {
  Future<TavernCastImportResult> _importDshgoCastMember(
    TavernCastSource source,
    String localCastId, {
    required String operationId,
    String? domainId,
  }) => _authoringOperation(() async {
    final captured = _captureGameplayCastSource(source);
    final domain = domainId ?? _authoringAuthority.domainId;
    if (domain.isEmpty || operationId.isEmpty || localCastId.isEmpty) {
      _invalidGameplayCast('Use a nonempty domain, operation id and local cast id.');
    }
    final parameters = <String, Object?>{
      'method': 'importDshgoCastMember',
      'source': captured.toJson(),
      'localCastId': localCastId,
    };
    final replayed = replayAuthoringSaveAs(_authoringAuthority, domain, operationId, parameters);
    if (replayed != null) {
      return _gameplayCastResult(captured, localCastId, replayed);
    }
    if (domain != _authoringAuthority.domainId) {
      throw const TavernAuthoringException('authority_conflict', 'The operation domain changed.');
    }

    final String text;
    final String sourceFormat;
    final List<String> mediaRefs;
    final TavernAuthoringMediaSelection media;
    AuthoringCardMedia? capturedMedia;
    ({String id, AuthoringExpectation expected})? requiredSource;
    if (captured.kind == TavernCastSourceKind.card) {
      final card = captured.card!;
      final expected = card.authorityRevision;
      if (card.origin != TavernAuthoringSourceOrigin.existing ||
          card.target.kind != TavernAuthoringTargetKind.character ||
          !CharacterLibrary.isValidId(card.target.id) ||
          expected == null ||
          expected.domainId.isEmpty ||
          expected.revision < 1) {
        _invalidGameplayCast('A card source requires an existing character and its captured authority revision.');
      }
      _authoringAuthority.checkWritable(card.physicalResourceId);
      final saved = _authoringAuthority.peek(card.physicalResourceId);
      final before = saved.snapshot;
      if (saved.domainId != expected.domainId ||
          saved.revision != expected.revision ||
          before == null ||
          !before.present ||
          before.rawText == null ||
          before.identityText == null) {
        _gameplayCastSourceConflict(card.physicalResourceId);
      }
      final document = const CardCodec().decodeAuthority(Uint8List.fromList(utf8.encode(before.rawText!)));
      final identity = jsonDecode(decodeAuthoringText(utf8.encode(before.identityText!)).text) as Map<String, Object?>;
      if (!_stateJsonEqual(document, card.base) ||
          identity['sourceFormat'] != card.sourceFormat ||
          !_stateJsonEqual(identity['resources'], card.mediaRefs)) {
        _gameplayCastSourceConflict(card.physicalResourceId);
      }
      final data = document['data']! as Map<String, Object?>;
      final extensions = data['extensions'];
      final dshgo = extensions is Map<String, Object?> ? extensions['dshgo'] : null;
      text = jsonEncode(_gameplayCastMember(dshgo, localCastId));
      requiredSource = (id: card.target.id, expected: AuthoringExpectation(revision: expected, before: before));
      media = captured.copyMedia ? TavernAuthoringMediaSelection.currentSource : TavernAuthoringMediaSelection.none;
      mediaRefs = captured.copyMedia ? card.mediaRefs : const [];
      sourceFormat = captured.copyMedia ? card.sourceFormat : 'json';
    } else {
      final ref = captured.packRef!;
      if (ref.installedPackId.isEmpty || ref.packVersion.isEmpty) {
        _invalidGameplayCast('A pack source requires a complete installed version identity.');
      }
      final version = _store.readGameplayPackVersion(ref);
      if (version == null) {
        throw const TavernGameplayException(
          code: 'version_not_found',
          message: 'The source pack version does not exist.',
        );
      }
      // Tombstones retain immutable originals and remain explicit import sources.
      if (captured.kind == TavernCastSourceKind.packManifest) {
        text = jsonEncode(_gameplayCastMember(version.manifest['dshgo'], localCastId));
      } else {
        final resource = _store.readGameplayPackResource(ref, localCastId);
        if (resource == null || resource.kind != 'castCard') {
          throw const TavernGameplayException(
            code: 'cast_not_found',
            message: 'The selected castCard resource does not exist.',
          );
        }
        text = decodeAuthoringText(resource.bytes).rawText;
      }
      final assets = <String, Uint8List>{};
      for (final id in captured.assetResourceIds) {
        final resource = _store.readGameplayPackResource(ref, id);
        if (resource == null || resource.kind != 'asset') {
          throw const TavernGameplayException(
            code: 'resource_not_found',
            message: 'A selected cast asset resource does not exist.',
          );
        }
        assets[resource.path] = resource.bytes;
      }
      sourceFormat = 'json';
      mediaRefs = assets.keys.toList();
      media = assets.isEmpty ? TavernAuthoringMediaSelection.none : TavernAuthoringMediaSelection.seedCaptured;
      if (assets.isNotEmpty) {
        // This internal supplied-media branch is also used by saved seeds.
        // Its bytes here are the selected immutable pack files, not a new seed.
        capturedMedia = AuthoringCardMedia(
          sourceFormat: TavernCardFormat.json,
          originalBytes: Uint8List.fromList(utf8.encode(text)),
          assets: assets,
        );
      }
    }
    final receipt = await _library.importAuthoringEnvelope(
      text,
      domainId: domain,
      operationId: operationId,
      parameters: parameters,
      media: media,
      mediaRefs: mediaRefs,
      sourceFormat: sourceFormat,
      seedMedia: capturedMedia,
      currentSource: captured.copyMedia ? requiredSource : null,
      requiredSource: requiredSource,
      inspect: _inspectCardReport,
    );
    return _gameplayCastResult(captured, localCastId, receipt);
  });

  Future<TavernCastImportResult?> _readDshgoCastImport(String domainId, String operationId) => _authoringOperation(() {
    final operation = _store.readAuthoringOperationData(domainId, operationId);
    if (operation == null || operation.request['method'] != 'importDshgoCastMember') {
      return null;
    }
    final source = _gameplayCastSourceFromJson(operation.request['source']! as Map<String, Object?>);
    final receipt = authoringSaveAsReceipt(operation, operation.request['saveAsResult']! as Map<String, Object?>);
    return _gameplayCastResult(source, operation.request['localCastId']! as String, receipt);
  });
}

TavernCastImportResult _gameplayCastResult(
  TavernCastSource source,
  String localCastId,
  TavernAuthoringSaveAsReceipt receipt,
) {
  final target = receipt.newTarget;
  return TavernCastImportResult(
    receipt: receipt,
    mapping: receipt.committed == true && target?.kind == TavernAuthoringTargetKind.character
        ? TavernCastMapping(
            source: source,
            localCastId: localCastId,
            characterId: target!.id,
            domainId: receipt.outcome.domainId,
            operationId: receipt.operationId,
          )
        : null,
  );
}

TavernCastSource _captureGameplayCastSource(TavernCastSource source) {
  final json = source.toJson();
  if (!_authoringFiniteJson(json)) {
    _invalidGameplayCast('Cast sources must contain only finite JSON values.');
  }
  final captured = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  if (source.kind != TavernCastSourceKind.card) {
    final ids = (captured['assetResourceIds']! as List<Object?>).cast<String>().toList();
    if (ids.any((id) => id.isEmpty) || ids.toSet().length != ids.length) {
      _invalidGameplayCast('Choose distinct nonempty asset resource ids.');
    }
    ids.sort();
    captured['assetResourceIds'] = ids;
  }
  return _gameplayCastSourceFromJson(captured);
}

TavernCastSource _gameplayCastSourceFromJson(Map<String, Object?> source) {
  final kind = TavernCastSourceKind.values.byName(source['kind']! as String);
  if (kind == TavernCastSourceKind.card) {
    final card = source['card']! as Map<String, Object?>;
    final target = card['target']! as Map<String, Object?>;
    final rawRevision = card['authorityRevision'] as Map<String, Object?>?;
    return TavernCastSource.card(
      card: TavernAuthoringSource(
        target: TavernAuthoringTarget(
          kind: TavernAuthoringTargetKind.values.byName(target['kind']! as String),
          id: target['id']! as String,
        ),
        origin: TavernAuthoringSourceOrigin.values.byName(card['origin']! as String),
        sourceFormat: card['sourceFormat']! as String,
        base: card['base']! as Map<String, Object?>,
        mediaRefs: (card['mediaRefs']! as List<Object?>).cast<String>().toList(),
        authorityRevision: rawRevision == null
            ? null
            : TavernAuthorityRevision(
                domainId: rawRevision['domainId']! as String,
                revision: rawRevision['revision']! as int,
              ),
        applySupported: card['applySupported']! as bool,
      ),
      copyMedia: source['copyMedia']! as bool,
    );
  }
  final ref = source['packRef']! as Map<String, Object?>;
  final packRef = TavernPackVersionRef(
    installedPackId: ref['installedPackId']! as String,
    packVersion: ref['packVersion']! as String,
  );
  final assets = (source['assetResourceIds']! as List<Object?>).cast<String>().toList();
  return kind == TavernCastSourceKind.packManifest
      ? TavernCastSource.pack(packRef: packRef, assetResourceIds: assets)
      : TavernCastSource.packResource(packRef: packRef, assetResourceIds: assets);
}

Map<String, Object?> _gameplayCastMember(Object? dshgo, String localCastId) {
  final cast = dshgo is Map<String, Object?> ? dshgo['cast'] : null;
  if (cast is! List<Object?>) {
    throw const TavernGameplayException(code: 'cast_not_found', message: 'The source does not contain a cast array.');
  }
  final ids = <String>{};
  Map<String, Object?>? selected;
  for (final value in cast) {
    if (value is! Map<String, Object?>) {
      _invalidGameplayCast('Cast members must be objects with unique nonempty local ids.');
    }
    final id = value['id'];
    if (id is! String || id.isEmpty || !ids.add(id)) {
      _invalidGameplayCast('Cast members must be objects with unique nonempty local ids.');
    }
    if (id == localCastId) {
      selected = value;
    }
  }
  if (selected == null) {
    throw const TavernGameplayException(code: 'cast_not_found', message: 'The selected cast member does not exist.');
  }
  // The same actual CardCodec authority intake used by prepared imports validates
  // the complete data. It does not adopt the runtime-defaulted projection.
  return {'spec': 'chara_card_v3', 'spec_version': '3.0', 'data': selected['card']};
}

Never _invalidGameplayCast(String message) =>
    throw TavernGameplayException(code: 'invalid_cast_source', message: message);

Never _gameplayCastSourceConflict(String resourceId) => throw TavernAuthoringException(
  'authority_conflict',
  'The captured cast source changed.',
  physicalResourceId: resourceId,
);
