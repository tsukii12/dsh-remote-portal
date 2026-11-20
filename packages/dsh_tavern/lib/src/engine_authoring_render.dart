part of 'engine.dart';

final class _AuthoringRenderToken implements TavernScriptCancellation {
  const _AuthoringRenderToken(this.source);
  final ModelCancellation source;
  @override
  bool get isCancelled => source.isCancelled;
  @override
  Future<void> get whenCancelled => source.whenCancelled;
}

final class _AuthoringRenderTask implements TavernAuthoringTask<TavernAuthoringRenderResult> {
  _AuthoringRenderTask(this.request, {ModelCancellation? cancellation})
    : captureId = 'render-${_newStateId()}',
      cancellation = cancellation ?? ModelCancellation() {
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(
      this.cancellation.whenCancelled.then<void>((_) {
        reader?.stop();
        startClose();
      }),
    );
  }
  final TavernAuthoringRenderRequest request;
  final String captureId;
  final ModelCancellation cancellation;
  final drained = Completer<void>();
  final _result = Completer<TavernAuthoringRenderResult>();
  _AuthoringRenderReader? reader;
  TavernAuthoringPreviewSession? session;
  Future<void>? closing;
  @override
  String get requestId => request.requestId;
  @override
  Future<TavernAuthoringRenderResult> get result => _result.future;
  @override
  Future<void> cancel() {
    reader?.stop();
    cancellation.cancel();
    startClose();
    return drained.future;
  }

  void startClose() {
    final current = session;
    if (current == null || closing != null) {
      return;
    }
    final completed = Completer<void>();
    final future = closing = completed.future;
    // Cancellation may start close while render is still pending. Its error
    // is observed here and then reported after the original render has ended.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    // Install the close identity before invoking a re-entrant host method.
    unawaited(
      Future<void>.sync(current.close).then<void>(
        (_) {
          completed.complete();
        },
        onError: (Object error, StackTrace stack) {
          completed.completeError(error, stack);
        },
      ),
    );
  }

  TavernAuthoringRenderResult value(
    TavernAuthoringRenderStatus status, {
    List<TavernAuthoringIssue> issues = const [],
  }) => TavernAuthoringRenderResult(
    requestId: requestId,
    captureId: captureId,
    draftId: request.draftId,
    draftRevision: request.draftRevision,
    physicalResourceId: request.physicalResourceId,
    changeIds: request.changeIds,
    mode: request.mode,
    status: status,
    issues: issues,
  );

  bool owns(TavernAuthoringRenderResult value) =>
      value.requestId == requestId &&
      value.captureId == captureId &&
      value.draftId == request.draftId &&
      value.draftRevision == request.draftRevision &&
      value.physicalResourceId == request.physicalResourceId &&
      value.mode == request.mode &&
      _stateJsonEqual(value.changeIds, request.changeIds);
}

/// The only live reader given to openPreview. Closing dependency admission
/// drops its engine closure; sealed reads can only return the fixed cache.
final class _AuthoringRenderReader implements TavernAuthoringCaptureReader {
  _AuthoringRenderReader(this.cancellation, this.candidates, this._read);
  final ModelCancellation cancellation;
  final Map<String, Map<String, Object?>> candidates;
  Future<_AuthoringCapturedResource> Function(TavernAuthoringTarget)? _read;
  final _pending = <String, Future<_AuthoringCapturedResource>>{};
  final _deliveries = <Future<TavernAuthoringCapturedResource>>[];
  final resources = <String, _AuthoringCapturedResource>{};
  var _stopped = false;

  void closeAdmission() {
    _read = null;
  }

  void stop() {
    _stopped = true;
    closeAdmission();
  }

  Future<void> drain() async {
    await Future.wait(_deliveries);
  }

  Map<String, TavernAuthoringCapturedResource> renderViews() => {
    for (final entry in resources.entries) entry.key: _renderResourceView(entry.value, candidates[entry.key]),
  };

  @override
  Future<TavernAuthoringCapturedResource> read(TavernAuthoringTarget target) {
    cancellation.check();
    if (_stopped) {
      throw const TavernAuthoringException('unsupported_render_resource', 'This capture reader has closed.');
    }
    _validateAuthoringTargets([target]);
    final id = target.physicalResourceId;
    var pending = _pending[id];
    if (pending == null) {
      final read = _read;
      if (read == null) {
        throw TavernAuthoringException(
          'unsupported_render_resource',
          'This dependency was not captured before render sealed.',
          physicalResourceId: id,
        );
      }
      pending = read(target).then((resource) {
        resources[id] = resource;
        return resource;
      });
      _pending[id] = pending;
    }
    final delivered = pending.then((resource) {
      cancellation.check();
      return _renderResourceView(resource, candidates[id]);
    });
    _deliveries.add(delivered);
    unawaited(delivered.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return delivered;
  }
}

/// The sole resource delivery boundary. Internal captured values are never
/// handed out; each read and the final render frame receive their own view.
TavernAuthoringCapturedResource _renderResourceView(
  _AuthoringCapturedResource resource,
  Map<String, Object?>? candidate,
) {
  final ledger = resource.ledger;
  final revision = ledger?.revision;
  return TavernAuthoringCapturedResource(
    target: resource.target,
    present: resource.snapshot.present,
    rawText: resource.snapshot.rawText,
    identityText: resource.snapshot.identityText,
    sourceFormat: resource.sourceFormat,
    document: _authoringCopy(resource.document) as Map<String, Object?>?,
    fromDraft: candidate != null,
    candidate: _authoringCopy(candidate ?? resource.document) as Map<String, Object?>?,
    mediaRefs: List.unmodifiable(resource.mediaRefs),
    media: Map.unmodifiable({
      for (final entry in resource.media.entries) entry.key: Uint8List.fromList(entry.value).asUnmodifiableView(),
    }),
    seedDraftId: resource.seedDraftId,
    knownAuthority: revision == null ? null : TavernAuthorityRevision(domainId: ledger!.domainId, revision: revision),
    knownAuthoritySnapshotHash: ledger?.snapshot == null ? null : _directorHash(ledger!.snapshot!.toJson()),
  );
}

extension _AuthoringRenders on TavernEngine {
  TavernAuthoringTask<TavernAuthoringRenderResult> _renderAuthoringDraft(
    TavernAuthoringRenderRequest request,
    TavernAuthoringPreviewHost host,
  ) {
    _ensureAdmission();
    return _startAuthoringRender(request, host);
  }

  _AuthoringRenderTask _startAuthoringRender(
    TavernAuthoringRenderRequest request,
    TavernAuthoringPreviewHost host, {
    ModelCancellation? cancellation,
  }) {
    cancellation?.check();
    _ensureOpen();
    if (request.requestId.isEmpty ||
        request.draftId.isEmpty ||
        request.draftRevision < 1 ||
        request.physicalResourceId.isEmpty ||
        request.changeIds.any((id) => id.isEmpty) ||
        request.changeIds.toSet().length != request.changeIds.length ||
        request.theme.isEmpty ||
        request.viewportWidth < 1 ||
        request.viewportHeight < 1 ||
        !request.devicePixelRatio.isFinite ||
        request.devicePixelRatio <= 0) {
      _authoringInvalid('Use valid render identities, selection and positive finite viewport dimensions.');
    }
    final task = _AuthoringRenderTask(request, cancellation: cancellation);
    // Register before calling any host method, including synchronously
    // re-entrant openPreview implementations.
    _operations.add(task.drained.future);
    _authoringPreviewCancellations.add(task.cancellation);
    unawaited(_driveAuthoringRender(task, host));
    return task;
  }

  Future<void> _driveAuthoringRender(_AuthoringRenderTask task, TavernAuthoringPreviewHost host) async {
    final request = task.request;
    TavernAuthoringRenderResult? returned;
    TavernAuthoringHostBinding? binding;
    Object? failure, closeFailure;
    StackTrace? failureStack, closeStack;
    try {
      task.cancellation.check();
      final stored = _requireAuthoringDraft(request.draftId, request.draftRevision);
      final draftText = jsonEncode(stored.data);
      final domain = _authoringAuthority.domainId;
      final draft = _authoringView(stored);
      final source = draft.sources
          .where((source) => source.physicalResourceId == request.physicalResourceId)
          .firstOrNull;
      if (source == null) {
        _authoringInvalid('Select a source in this draft.', resourceId: request.physicalResourceId);
      }
      final candidates = _materializeAuthoring(draft, request.changeIds.toSet(), includeDiffs: false).candidates;
      final reader = task.reader = _AuthoringRenderReader(
        task.cancellation,
        candidates,
        (target) => _captureAuthoringResource(target, seedDraft: stored),
      );
      final resource = await reader.read(source.target);
      task.cancellation.check();
      final capture = TavernAuthoringHostCapture(
        request: request,
        captureId: task.captureId,
        resource: resource,
        reader: reader,
        draftTargets: [for (final source in draft.sources) source.target],
      );
      // Never race this original Future against cancellation. A session
      // delivered late still belongs to this owner and must be closed.
      task.session = await Future<TavernAuthoringPreviewSession>.sync(
        () => host.openPreview(capture, _AuthoringRenderToken(task.cancellation)),
      );
      if (task.cancellation.isCancelled) {
        task.startClose();
      }
      task.cancellation.check();
      final session = task.session!;
      binding = session.binding;
      final sourceInvalidated = session.sourceInvalidated;
      if (binding.hostEpoch.isEmpty ||
          binding.maxImageBytes < 1 ||
          binding.maxPixelWidth < 1 ||
          binding.maxPixelHeight < 1) {
        throw const TavernAuthoringException(
          'invalid_render_binding',
          'The renderer supplied invalid limits or identity.',
        );
      }
      if (!binding.renderModes.contains(request.mode) ||
          !binding.formats.any((format) => format == 'image/png' || format == 'image/jpeg')) {
        throw const TavernAuthoringException(
          'unsupported_render',
          'The renderer does not support this static image request.',
        );
      }
      reader.closeAdmission();
      await reader.drain();
      await _recheckCapturedAuthoringResources(
        reader.resources.values,
        check: () {
          task.cancellation.check();
          final fresh = _store.readAuthoringDraftData(request.draftId);
          if (_authoringAuthority.domainId != domain ||
              fresh == null ||
              fresh.revision != request.draftRevision ||
              jsonEncode(fresh.data) != draftText ||
              sourceInvalidated.isCancelled) {
            throw const TavernAuthoringException('capture_conflict', 'Render sources changed before capture sealed.');
          }
        },
      );
      task.cancellation.check();
      returned = await Future<TavernAuthoringRenderResult>.sync(
        () => session.render(
          TavernAuthoringHostRenderRequest(
            request: request,
            captureId: task.captureId,
            resources: reader.renderViews(),
          ),
        ),
      );
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      task.reader?.stop();
      task.startClose();
      try {
        await task.reader?.drain();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      try {
        await task.closing;
      } catch (error, stack) {
        closeFailure = error;
        closeStack = stack;
      }
    }

    // close.error is not evidence that the domain stopped. Keep this failed
    // operation in the engine gate, so backup/close cannot release its root.
    if (closeFailure != null) {
      task.drained.completeError(closeFailure, closeStack);
      task._result.completeError(closeFailure, closeStack);
      return;
    }
    TavernAuthoringRenderResult? result;
    try {
      if (failure != null) {
        Error.throwWithStackTrace(failure, failureStack!);
      }
      final value = returned!;
      // Check error identities too. No invalid or stale host result can become
      // an image for a different request or newly edited draft.
      if (!task.owns(value)) {
        result = task.value(
          TavernAuthoringRenderStatus.superseded,
          issues: const [
            TavernAuthoringIssue(
              type: 'render_identity_mismatch',
              message: 'The renderer returned another request identity.',
            ),
          ],
        );
      } else if (task.cancellation.isCancelled) {
        result = task.value(TavernAuthoringRenderStatus.cancelled);
      } else if (_store.readAuthoringDraftData(request.draftId)?.revision != request.draftRevision) {
        result = task.value(
          TavernAuthoringRenderStatus.superseded,
          issues: const [
            TavernAuthoringIssue(
              type: 'revision_conflict',
              message: 'The draft changed before render could be delivered.',
            ),
          ],
        );
      } else if (value.status == TavernAuthoringRenderStatus.complete) {
        validateAuthoringImage(value, binding!);
        result = value;
      } else {
        result = task.value(value.status, issues: value.issues);
      }
      failure = null;
    } on TavernAuthoringException catch (error) {
      result = task.value(
        switch (error.code) {
          'unsupported_render' || 'unsupported_render_resource' => TavernAuthoringRenderStatus.unsupported,
          'capture_conflict' || 'revision_conflict' => TavernAuthoringRenderStatus.superseded,
          _ => TavernAuthoringRenderStatus.failed,
        },
        issues: [TavernAuthoringIssue(type: error.code, message: error.message)],
      );
      failure = null;
    } on TavernModelException catch (error, stack) {
      if (error.kind == TavernFailure.cancelled) {
        result = task.value(TavernAuthoringRenderStatus.cancelled);
        failure = null;
      } else {
        failure = error;
        failureStack = stack;
      }
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    _authoringPreviewCancellations.remove(task.cancellation);
    _operations.remove(task.drained.future);
    task.drained.complete();
    if (failure != null) {
      task._result.completeError(failure, failureStack!);
    } else {
      task._result.complete(result!);
    }
  }
}
