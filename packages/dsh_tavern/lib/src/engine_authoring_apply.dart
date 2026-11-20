part of 'engine.dart';

extension _AuthoringAdoptions on TavernEngine {
  Future<TavernAuthoringReceipt> _applyAuthoringChanges(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) => _authoringOperation(() async {
    final selected = List<String>.of(changeIds)..sort();
    if (draftId.isEmpty ||
        draftRevision < 1 ||
        selected.toSet().length != selected.length ||
        selected.any((id) => id.isEmpty)) {
      _authoringInvalid('Use a valid draft revision and distinct change identifiers.', resourceId: physicalResourceId);
    }
    _validateAuthoringOperation(operationId, physicalResourceId, expectedAuthorityRevision);
    final request = AuthoringWriteRequest(
      domainId: expectedAuthorityRevision.domainId,
      operationId: operationId,
      physicalResourceId: physicalResourceId,
      parameters: {
        'method': 'apply',
        'draftId': draftId,
        'draftRevision': draftRevision,
        'physicalResourceId': physicalResourceId,
        'changeIds': selected,
        'expectedAuthorityRevision': _authoringRevisionJson(expectedAuthorityRevision),
      },
    );
    final replay = _authoringAuthority.replay(request);
    if (replay != null) return replay;

    final stored = _requireAuthoringDraft(draftId, draftRevision);
    final draft = _authoringView(stored);
    final source = draft.sources.where((source) => source.physicalResourceId == physicalResourceId).firstOrNull;
    if (source == null) _authoringInvalid('The resource is not in this draft.', resourceId: physicalResourceId);
    if (!source.applySupported) _unsupportedAuthoringApply(physicalResourceId);
    final selectedSet = selected.toSet();
    if (draft.changes.any(
      (change) => selectedSet.contains(change.id) && change.physicalResourceId != physicalResourceId,
    )) {
      _authoringInvalid('One adoption can select only one physical resource.', resourceId: physicalResourceId);
    }
    final candidate = _materializeAuthoring(draft, selectedSet, includeDiffs: false).candidates[physicalResourceId]!;
    if (source.authorityRevision != expectedAuthorityRevision) _authoringAuthorityConflict(physicalResourceId);
    final saved = (stored.data['sources']! as List<Object?>).cast<Map<String, Object?>>().firstWhere(
      (value) => _authoringTarget(value['target']! as Map<String, Object?>).physicalResourceId == physicalResourceId,
    );
    final before = AuthoringResourceSnapshot.fromJson(saved);
    // Equal JSON is a deliberate no-effect request. Keep the saved actual
    // text, including its BOM and formatting, until the writer has passed CAS.
    final text = _stateJsonEqual(source.base, candidate) ? before.rawText! : jsonEncode(candidate);
    return _adoptAuthoringText(
      source.target,
      text,
      request: request,
      expected: AuthoringExpectation(revision: expectedAuthorityRevision, before: before),
      check: () {
        _requireAuthoringDraft(draftId, draftRevision);
      },
    );
  });

  Future<TavernAuthoringOperation?> _readAuthoringOperation(String operationId, {required String domainId}) =>
      _authoringOperation(() {
        if (operationId.isEmpty || domainId.isEmpty) {
          _authoringInvalid('Operation and domain identifiers must be nonempty.');
        }
        return _authoringAuthority.readOperation(operationId, domainId: domainId);
      });

  Future<List<TavernAuthoringRevisionSummary>> _listAuthoringRevisions(String physicalResourceId) =>
      _authoringOperation(() {
        _authoringPhysicalTarget(physicalResourceId);
        return _authoringAuthority.listRevisions(physicalResourceId);
      });

  Future<TavernAuthoringReceipt> _restoreAuthoringRevision(
    String physicalResourceId, {
    required TavernAuthorityRevision revision,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) => _authoringOperation(() async {
    _validateAuthoringOperation(operationId, physicalResourceId, expectedAuthorityRevision);
    _validateAuthoringRevision(revision);
    final request = AuthoringWriteRequest(
      domainId: expectedAuthorityRevision.domainId,
      operationId: operationId,
      physicalResourceId: physicalResourceId,
      parameters: {
        'method': 'restore',
        'physicalResourceId': physicalResourceId,
        'revision': _authoringRevisionJson(revision),
        'expectedAuthorityRevision': _authoringRevisionJson(expectedAuthorityRevision),
      },
    );
    final replay = _authoringAuthority.replay(request);
    if (replay != null) return replay;
    final target = _authoringPhysicalTarget(physicalResourceId);
    if (target.kind != TavernAuthoringTargetKind.character && target.kind != TavernAuthoringTargetKind.lorebook) {
      _unsupportedAuthoringApply(physicalResourceId);
    }
    final historical = _authoringAuthority.revisionSnapshot(physicalResourceId, revision);
    if (historical == null) {
      throw TavernAuthoringException(
        'not_found',
        'The adopted resource revision does not exist.',
        physicalResourceId: physicalResourceId,
      );
    }
    if (!historical.present || historical.rawText == null) _unsupportedAuthoringApply(physicalResourceId);
    final captured = await _captureAuthoringSource(target);
    final source = _authoringSourceView(captured);
    final current = AuthoringResourceSnapshot.fromJson(captured);
    if (source.authorityRevision != expectedAuthorityRevision ||
        (target.kind == TavernAuthoringTargetKind.character && current.identityText != historical.identityText)) {
      _authoringAuthorityConflict(physicalResourceId);
    }
    // Only JSON is restored. The expected before binds the current identity;
    // the actual writer retains it and verifies the current media is available.
    return _adoptAuthoringText(
      target,
      historical.rawText!,
      request: request,
      expected: AuthoringExpectation(revision: expectedAuthorityRevision, before: current),
    );
  });

  Future<TavernAuthoringReceipt> _adoptAuthoringText(
    TavernAuthoringTarget target,
    String text, {
    required AuthoringWriteRequest request,
    required AuthoringExpectation expected,
    void Function()? check,
  }) async {
    try {
      return switch (target.kind) {
        TavernAuthoringTargetKind.character => await _library.writeAuthoringEnvelope(
          target.id,
          text,
          request: request,
          expected: expected,
          check: check,
        ),
        TavernAuthoringTargetKind.lorebook => await _writeAuthoringBook(
          target.id,
          text,
          request: request,
          expected: expected,
          check: check,
        ),
        _ => _unsupportedAuthoringApply(target.physicalResourceId),
      };
    } on TavernAuthoringException catch (error) {
      final receipt = error.receipt;
      if (error.code != 'resource_write_failed' ||
          receipt == null ||
          receipt.domainId != request.domainId ||
          receipt.operationId != request.operationId ||
          receipt.physicalResourceId != request.physicalResourceId) {
        rethrow;
      }
      return receipt;
    }
  }
}

void _validateAuthoringOperation(String operationId, String resourceId, TavernAuthorityRevision revision) {
  if (operationId.isEmpty || resourceId.isEmpty) {
    _authoringInvalid('Operation and resource identifiers must be nonempty.');
  }
  _validateAuthoringRevision(revision);
}

void _validateAuthoringRevision(TavernAuthorityRevision revision) {
  if (revision.domainId.isEmpty || revision.revision < 1) _authoringInvalid('Use a valid durable authority revision.');
}

TavernAuthoringTarget _authoringPhysicalTarget(String resourceId) {
  final TavernAuthoringTarget target;
  if (resourceId.startsWith('character:')) {
    target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: resourceId.substring(10));
  } else if (resourceId.startsWith('lorebook:')) {
    target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: resourceId.substring(9));
  } else if (resourceId == 'regex-library') {
    target = const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global');
  } else if (resourceId.startsWith('preset:')) {
    target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: resourceId.substring(7));
  } else {
    _authoringInvalid('Unknown authoring resource kind.', resourceId: resourceId);
  }
  _validateAuthoringTargets([target]);
  return target;
}

Never _unsupportedAuthoringApply(String resourceId) => throw TavernAuthoringException(
  'unsupported_apply',
  'This saved source has no supported in-place adoption base.',
  physicalResourceId: resourceId,
);

Never _authoringAuthorityConflict(String resourceId) => throw TavernAuthoringException(
  'authority_conflict',
  'The saved authority revision, source or identity changed.',
  physicalResourceId: resourceId,
);
