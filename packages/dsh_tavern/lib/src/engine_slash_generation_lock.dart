part of 'engine.dart';

class _SlashGenerationLease {
  _SlashGenerationLease(this.invocation, this.host, this.hostVersion, this.leaseId, this.acquireId);
  final _SlashInvocation invocation;
  _SlashExecutionOwner get owner => invocation.owner;
  final TavernScriptHost host;
  final int hostVersion;
  final String leaseId, acquireId;
  final lifetime = _ScriptCancellation();
  _SlashLeaseRequest? acquireRequest;
  _SlashLeaseRequest? releaseRequest;
  String? revocationReason;
  String? deliveryRevocationReason;
  bool acquired = false;
  bool released = false;
  bool cleanupRequested = false;
  bool unconfirmedRecorded = false;
  bool ended = false;
  bool get acquireInvoked => acquireRequest?.invoked == true;
}

class _SlashLeaseRequest {
  _SlashLeaseRequest(this.lease, this.operation, this.requestId, this.token);
  final _SlashGenerationLease lease;
  final String operation, requestId;
  String get operationName => operation == 'acquire' ? 'acquireGenerationLock' : 'releaseGenerationLock';
  final _ScriptCancellation token;
  final completed = Completer<void>();
  bool invoked = false;
  bool requestedRecorded = false;
}

extension _SlashGenerationLocks on _ScriptCoordinator {
  Map<String, Object?> _leaseTarget(_SlashGenerationLease lease, [_SlashLeaseRequest? request]) => {
    'leaseId': lease.leaseId,
    'acquireRequestId': lease.acquireId,
    if (request != null && request.invoked) 'requestId': request.requestId,
  };

  void _publishSlashLease(
    _SlashGenerationLease lease,
    String operation,
    String status, {
    _SlashLeaseRequest? request,
    String? phase,
    bool committed = false,
    List<TavernScriptIssue> issues = const [],
  }) {
    final context = lease.owner.context;
    if (context.closed || _closed || _events.isClosed || !identical(contexts[context.value.id], context)) {
      return;
    }
    final dispatch = _dispatch(
      context,
      kind: TavernScriptDispatchKind.lifecycle,
      namespace: 'slash',
      name: 'GENERATION_LOCK',
      args: [
        {
          'executionId': lease.owner.id,
          'leaseId': lease.leaseId,
          'acquireRequestId': lease.acquireId,
          'operation': operation,
          'status': status,
          if (request != null && request.invoked) 'requestId': request.requestId,
        },
      ],
    );
    _events.add(
      TavernScriptEvent(
        dispatch: dispatch,
        phase: lease.owner.terminal ? 'late' : phase ?? status,
        committed: committed || issues.any((issue) => issue.committed),
        issues: issues,
      ),
    );
  }

  void _leaseEffect(
    _SlashGenerationLease lease,
    TavernSlashEffectState state,
    String operation,
    String status, {
    _SlashLeaseRequest? request,
    bool committed = false,
    bool knownCommitted = false,
    String? phase,
    String? reason,
    List<TavernScriptIssue> issues = const [],
  }) {
    // The receiving path admits issues exactly once. This records only the
    // target fact; an unrelated known flag never fabricates acquired/released.
    lease.owner.recordEffect(
      kind: TavernSlashEffectKind.generationLock,
      state: state,
      operation: operation == 'acquire' ? 'acquireGenerationLock' : 'releaseGenerationLock',
      target: _leaseTarget(lease, request),
      committed: committed,
      stage: operation == 'release' ? TavernSlashEffectStage.release : TavernSlashEffectStage.handler,
      sourceSpan: lease.invocation.sourceSpan,
      details: {'status': status, 'reason': ?reason},
    );
    _publishSlashLease(
      lease,
      operation,
      status,
      request: request,
      phase: phase,
      committed: committed || knownCommitted,
      issues: issues,
    );
  }

  void _noteSlashLeaseRequested(_SlashLeaseRequest request) {
    if (!request.invoked || request.requestedRecorded) return;
    request.requestedRecorded = true;
    _leaseEffect(
      request.lease,
      request.operation == 'acquire'
          ? TavernSlashEffectState.acquireRequested
          : TavernSlashEffectState.releaseRequested,
      request.operation,
      'requested',
      request: request,
    );
  }

  void _noteSlashLeaseUnconfirmed(_SlashGenerationLease lease, String reason, {String? phase}) {
    if (!lease.acquireInvoked || lease.unconfirmedRecorded || lease.released) return;
    lease.unconfirmedRecorded = true;
    _leaseEffect(
      lease,
      TavernSlashEffectState.unconfirmed,
      'release',
      'unconfirmed',
      request: lease.releaseRequest,
      reason: reason,
      phase: phase,
    );
  }

  TavernScriptException _leaseDeliveryFailure(_SlashGenerationLease lease, String operation) {
    final reason = lease.deliveryRevocationReason;
    final closed =
        reason == 'context-closed' ||
        reason == 'closed' ||
        lease.owner.context.closed ||
        _closed ||
        !identical(contexts[lease.owner.context.value.id], lease.owner.context);
    return _slashHostError(
      lease.invocation,
      operation,
      closed ? TavernScriptErrorCode.cancelled : TavernScriptErrorCode.hostUnavailable,
      closed ? 'The lease context is closed.' : 'The captured generation lock host is no longer attached.',
    );
  }

  void _checkSlashLeaseRequest(_SlashLeaseRequest request) {
    final lease = request.lease;
    if (request.operation == 'acquire') lease.owner.checkAlive();
    if (lease.deliveryRevocationReason != null || !_slashHostIdentity(lease.owner, lease.host, lease.hostVersion)) {
      throw _leaseDeliveryFailure(
        lease,
        request.operation == 'acquire' ? 'acquireGenerationLock' : 'releaseGenerationLock',
      );
    }
    if (request.token.isCancelled) {
      throw _slashHostError(
        lease.invocation,
        request.operation == 'acquire' ? 'acquireGenerationLock' : 'releaseGenerationLock',
        TavernScriptErrorCode.cancelled,
        'The generation lock request was cancelled.',
      );
    }
  }

  TavernScriptException _normalizeSlashLeaseError(_SlashLeaseRequest request, Object error) =>
      _scriptReportedFailure(error) ??
      _slashHostError(
        request.lease.invocation,
        request.operation == 'acquire' ? 'acquireGenerationLock' : 'releaseGenerationLock',
        TavernScriptErrorCode.hookFailure,
        'The generation lock host failed (${error.runtimeType}).',
      );

  List<TavernScriptIssue> _slashLeaseFailureIssues(
    _SlashLeaseRequest request,
    TavernScriptException failure, {
    bool preserveKnown = true,
  }) => preserveKnown && failure.issues.isNotEmpty
      ? failure.issues
      : [
          TavernScriptIssue(
            code: failure.code.name,
            message: failure.message,
            committed: preserveKnown && failure.committed,
            contextId: request.lease.owner.context.value.id,
            sourceSpan: request.lease.invocation.sourceSpan,
            stage: request.operation == 'release' ? 'release' : 'handler',
            cancelled: failure.code == TavernScriptErrorCode.cancelled,
            details: {
              'leaseId': request.lease.leaseId,
              'acquireRequestId': request.lease.acquireId,
              'operation': request.operation,
              if (request.invoked) 'requestId': request.requestId,
            },
          ),
        ];

  void _finishSlashLease(_SlashGenerationLease lease) {
    if (lease.ended) return;
    lease.ended = true;
    slashHostState.leases.remove(lease);
    lease.releaseRequest?.token.cancel('request-ended');
  }

  void _failSlashLeaseRequest(
    _SlashLeaseRequest request,
    TavernScriptException failure,
    StackTrace stack, {
    List<TavernScriptIssue> receivedIssues = const [],
    bool receivedCommitted = false,
    bool preserveFailureFacts = false,
  }) {
    if (request.completed.isCompleted) return;
    final lease = request.lease;
    // Retain the first observed business/request failure before publishing any
    // event that could synchronously replace the host.
    lease.cleanupRequested = true;
    final issues = _slashLeaseFailureIssues(request, failure, preserveKnown: preserveFailureFacts);
    lease.owner.observeIssues(issues, committed: preserveFailureFacts && failure.committed);
    request.completed.completeError(failure, stack);
    if (request.invoked) {
      _leaseEffect(
        lease,
        failure.code == TavernScriptErrorCode.cancelled
            ? TavernSlashEffectState.cancelled
            : TavernSlashEffectState.failed,
        request.operation,
        failure.code == TavernScriptErrorCode.cancelled ? 'cancelled' : 'failed',
        request: request,
        knownCommitted: preserveFailureFacts && failure.committed || receivedCommitted,
        issues: [...receivedIssues, ...issues],
      );
    }
    if (request.operation == 'release') {
      _noteSlashLeaseUnconfirmed(lease, failure.code.name);
      _finishSlashLease(lease);
    }
  }

  void _lateSlashLeaseFailure(_SlashLeaseRequest request, TavernScriptException failure) {
    _publishSlashLease(
      request.lease,
      request.operation,
      'failed',
      request: request,
      phase: 'late',
      committed: failure.committed,
      issues: _slashLeaseFailureIssues(request, failure),
    );
  }

  void _lateSlashLeaseAck(_SlashLeaseRequest request, TavernScriptGenerationLockAck ack) {
    // A cancelled/revoked acquire, or a release whose delivery already lost,
    // cannot acquire a successful state merely from a late success word.
    _publishSlashLease(
      request.lease,
      request.operation,
      'unconfirmed',
      request: request,
      phase: 'late',
      issues: [
        ...ack.issues,
        TavernScriptIssue(
          code: 'lateGenerationLockAck',
          message: 'The acknowledgement arrived outside the request acceptance window.',
          committed: false,
          contextId: request.lease.owner.context.value.id,
          sourceSpan: request.lease.invocation.sourceSpan,
          stage: request.operation == 'release' ? 'release' : 'handler',
          details: {
            'receivedRequestId': ack.requestId,
            'receivedLeaseId': ack.leaseId,
            'receivedStatus': ack.status.name,
          },
        ),
      ],
    );
  }

  void _receiveSlashLeaseAck(_SlashLeaseRequest request, TavernScriptGenerationLockAck ack) {
    final lease = request.lease;
    if (request.completed.isCompleted || request.operation == 'acquire' && lease.owner.terminal) {
      _lateSlashLeaseAck(request, ack);
      return;
    }
    // These are received known facts, not proof that this lease was acquired.
    lease.owner.observeIssues(ack.issues, observationKey: request);
    try {
      _checkSlashLeaseRequest(request);
      final desired = request.operation == 'acquire'
          ? TavernScriptGenerationLockStatus.acquired
          : TavernScriptGenerationLockStatus.released;
      if (ack.requestId != request.requestId ||
          ack.leaseId != lease.leaseId ||
          ack.status != desired &&
              ack.status != TavernScriptGenerationLockStatus.cancelled &&
              ack.status != TavernScriptGenerationLockStatus.failed) {
        throw _slashHostError(
          lease.invocation,
          request.operationName,
          TavernScriptErrorCode.shapeMismatch,
          'The generation lock acknowledgement has inconsistent identity or status.',
        );
      }
      if (ack.status == TavernScriptGenerationLockStatus.cancelled) {
        throw _slashHostError(
          lease.invocation,
          request.operationName,
          TavernScriptErrorCode.cancelled,
          'The host cancelled the generation lock operation.',
        );
      }
      if (ack.status == TavernScriptGenerationLockStatus.failed) {
        throw _slashHostError(
          lease.invocation,
          request.operationName,
          TavernScriptErrorCode.hookFailure,
          'The host failed the generation lock operation.',
        );
      }
      if (request.operation == 'acquire') {
        lease.acquired = true;
      } else {
        lease.released = true;
      }
      request.completed.complete();
      if (request.operation == 'release') {
        // The release is already accepted. Remove the active dependency before
        // a synchronous watcher can detach the host in response to this fact.
        _finishSlashLease(lease);
      }
      _leaseEffect(
        lease,
        request.operation == 'acquire' ? TavernSlashEffectState.acquired : TavernSlashEffectState.released,
        request.operation,
        desired.name,
        request: request,
        committed: true,
        issues: ack.issues,
      );
    } catch (error, stack) {
      _failSlashLeaseRequest(request, _normalizeSlashLeaseError(request, error), stack, receivedIssues: ack.issues);
    }
  }

  void _receiveSlashLeaseError(_SlashLeaseRequest request, Object error, StackTrace stack) {
    final original = _normalizeSlashLeaseError(request, error);
    final lease = request.lease;
    if (request.completed.isCompleted || request.operation == 'acquire' && lease.owner.terminal) {
      _lateSlashLeaseFailure(request, original);
      return;
    }
    lease.owner.observeIssues(original.issues, committed: original.committed, observationKey: request);
    var failure = original;
    try {
      _checkSlashLeaseRequest(request);
    } on TavernScriptException catch (ownerFailure) {
      failure = ownerFailure;
    }
    if (identical(failure, original)) {
      _failSlashLeaseRequest(request, original, stack, preserveFailureFacts: true);
    } else {
      // The owner error wins control flow, without erasing a received host
      // exception's independent known flag or original issues.
      _failSlashLeaseRequest(
        request,
        failure,
        stack,
        receivedIssues: original.issues,
        receivedCommitted: original.committed,
      );
    }
  }

  Future<void> _startSlashLeaseRequest(
    _SlashLeaseRequest request,
    Future<TavernScriptGenerationLockAck> Function() invoke,
  ) {
    _observeSlashWaitError(request.completed.future);
    unawaited(
      request.token.whenCancelled.then<void>((_) {
        if (request.completed.isCompleted) return;
        TavernScriptException failure;
        try {
          _checkSlashLeaseRequest(request);
          failure = _slashHostError(
            request.lease.invocation,
            request.operationName,
            TavernScriptErrorCode.cancelled,
            'The generation lock request was cancelled.',
          );
        } on TavernScriptException catch (error) {
          failure = error;
        }
        _failSlashLeaseRequest(request, failure, StackTrace.current);
      }),
    );
    try {
      _checkSlashLeaseRequest(request);
    } catch (error, stack) {
      _failSlashLeaseRequest(request, _normalizeSlashLeaseError(request, error), stack);
      return request.completed.future;
    }
    Future<TavernScriptGenerationLockAck>? response;
    Object? synchronousError;
    StackTrace? synchronousStack;
    var threw = false;
    try {
      request.invoked = true;
      response = invoke();
    } catch (error, stack) {
      threw = true;
      synchronousError = error;
      synchronousStack = stack;
    } finally {
      _noteSlashLeaseRequested(request);
    }
    if (threw) {
      _receiveSlashLeaseError(request, synchronousError!, synchronousStack!);
    } else {
      unawaited(
        response!.then<void>(
          (ack) {
            _receiveSlashLeaseAck(request, ack);
          },
          onError: (Object error, StackTrace stack) {
            _receiveSlashLeaseError(request, error, stack);
          },
        ),
      );
    }
    return request.completed.future;
  }

  Future<_SlashGenerationLease> _acquireSlashLease(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    owner.checkAlive();
    final host = _host;
    if (host == null) {
      throw _slashHostError(
        invocation,
        'acquireGenerationLock',
        TavernScriptErrorCode.hostUnavailable,
        'A generation lock requires an attached host.',
      );
    }
    if (host is! TavernScriptGenerationLockHost) {
      throw _slashHostError(
        invocation,
        'acquireGenerationLock',
        TavernScriptErrorCode.unsupportedCapability,
        'The attached host does not implement generation locks.',
      );
    }
    final lease = _SlashGenerationLease(
      invocation,
      host,
      _hostVersion,
      _slashRequestId('lease'),
      _slashRequestId('acquire'),
    );
    final pending = _SlashLeaseRequest(lease, 'acquire', lease.acquireId, lease.lifetime);
    lease.acquireRequest = pending;
    slashHostState.leases.add(lease);
    unawaited(
      owner.token.whenCancelled.then<void>((_) {
        _revokeSlashLease(lease, 'cancelled');
      }),
    );
    final request = TavernScriptGenerationLockAcquireRequest(
      requestId: lease.acquireId,
      contextId: owner.context.value.id,
      executionId: owner.id,
      leaseId: lease.leaseId,
    );
    try {
      final future = _startSlashLeaseRequest(
        pending,
        () => (host as TavernScriptGenerationLockHost).acquireGenerationLock(request, lease.lifetime),
      );
      await owner.wait(future, TavernSlashWaitKind.generationLockAcquire);
      return lease;
    } catch (error, stack) {
      // The acquire command wait has lost. No later acquire reply may add
      // facts to this execution while independent release is being started.
      if (!pending.completed.isCompleted) {
        _failSlashLeaseRequest(pending, _normalizeSlashLeaseError(pending, error), stack);
      }
      _cleanupSlashLease(lease);
      rethrow;
    }
  }

  Future<void> _releaseSlashLease(_SlashGenerationLease lease) async {
    try {
      lease.owner.checkAlive();
      lease.lifetime.cancel('normal-release');
      // The command wait is cancellable. The one release delivery has its own
      // token and remains the independent cleanup if the script stops here.
      await lease.owner.wait(_beginSlashLeaseRelease(lease), TavernSlashWaitKind.generationLockRelease);
    } catch (_) {
      _cleanupSlashLease(lease);
      rethrow;
    }
  }

  Future<void> _beginSlashLeaseRelease(_SlashGenerationLease lease) {
    final existing = lease.releaseRequest;
    if (existing != null) return existing.completed.future;
    if (lease.ended ||
        lease.deliveryRevocationReason != null ||
        !_slashHostIdentity(lease.owner, lease.host, lease.hostVersion)) {
      _noteSlashLeaseUnconfirmed(lease, lease.deliveryRevocationReason ?? 'delivery-unavailable');
      _finishSlashLease(lease);
      final future = Future<void>.error(_leaseDeliveryFailure(lease, 'releaseGenerationLock'));
      _observeSlashWaitError(future);
      return future;
    }
    if (!lease.acquireInvoked) {
      _finishSlashLease(lease);
      final future = Future<void>.error(
        _slashHostError(
          lease.invocation,
          'releaseGenerationLock',
          TavernScriptErrorCode.hookFailure,
          'No acquire request was issued for this lease.',
        ),
      );
      _observeSlashWaitError(future);
      return future;
    }
    final pending = _SlashLeaseRequest(lease, 'release', _slashRequestId('release'), _ScriptCancellation());
    lease.releaseRequest = pending;
    final request = TavernScriptGenerationLockReleaseRequest(
      requestId: pending.requestId,
      contextId: lease.owner.context.value.id,
      executionId: lease.owner.id,
      leaseId: lease.leaseId,
      acquireRequestId: lease.acquireId,
    );
    return _startSlashLeaseRequest(
      pending,
      () => (lease.host as TavernScriptGenerationLockHost).releaseGenerationLock(request, pending.token),
    );
  }

  void _cleanupSlashLease(_SlashGenerationLease lease) {
    lease.cleanupRequested = true;
    lease.revocationReason ??= lease.owner.token.isCancelled ? 'cancelled' : 'failure-cleanup';
    lease.lifetime.cancel(lease.revocationReason!);
    if (lease.ended) return;
    if (!lease.acquireInvoked) {
      _finishSlashLease(lease);
      return;
    }
    _noteSlashLeaseUnconfirmed(lease, lease.revocationReason!);
    if (lease.deliveryRevocationReason != null || !_slashHostIdentity(lease.owner, lease.host, lease.hostVersion)) {
      lease.releaseRequest?.token.cancel(lease.deliveryRevocationReason ?? 'host-unavailable');
      _finishSlashLease(lease);
      return;
    }
    // No second request is made when normal release is already in flight.
    // Its pending delivery also remains registered for close/detach.
    if (lease.releaseRequest != null) return;
    unawaited(
      _beginSlashLeaseRelease(lease).then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // The actual request's receiving path records its failure once.
          // Cleanup never replaces or blocks the original business failure.
        },
      ),
    );
  }

  void _revokeSlashLease(_SlashGenerationLease lease, String reason) {
    if (lease.ended) return;
    final ownership = _slashOwnershipRevocation(reason);
    final firstRevocation = lease.revocationReason == null;
    final firstOwnershipRevocation = ownership && lease.deliveryRevocationReason == null;
    if (!firstRevocation && !firstOwnershipRevocation) return;
    final cancelDependentOwner = !lease.cleanupRequested && !lease.owner.token.isCancelled && !lease.owner.terminal;
    lease.revocationReason ??= reason;
    if (ownership) lease.deliveryRevocationReason ??= reason;

    // The reason is installed before any callbacks or shared host/context
    // fields change. A synchronous replacement can never release to old host.
    final acquire = lease.acquireRequest;
    if (acquire != null) _noteSlashLeaseRequested(acquire);
    final release = lease.releaseRequest;
    if (release != null) _noteSlashLeaseRequested(release);
    lease.lifetime.cancel(reason);
    if (ownership) release?.token.cancel(reason);
    _noteSlashLeaseUnconfirmed(lease, reason, phase: 'cancelled');

    if (cancelDependentOwner && reason == 'host-unavailable') {
      lease.owner.cancel(
        reason,
        _slashHostError(
          lease.invocation,
          'generationLock',
          TavernScriptErrorCode.hostUnavailable,
          'The generation lock host was replaced or detached.',
        ),
      );
    } else if (cancelDependentOwner && (reason == 'context-closed' || reason == 'closed')) {
      lease.owner.cancel(reason);
    }
    _cleanupSlashLease(lease);
  }
}
