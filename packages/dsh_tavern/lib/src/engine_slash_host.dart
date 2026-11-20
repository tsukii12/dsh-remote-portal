part of 'engine.dart';

class _SlashHostState {
  int serial = 0;
  final calls = <_SlashHostCall>{};
  final leases = <_SlashGenerationLease>{};
}

class _SlashHostCall {
  _SlashHostCall(this.owner, this.host, this.hostVersion, this.requestId, this.operation, this.onRequested);
  final _SlashExecutionOwner owner;
  final TavernScriptHost host;
  final int hostVersion;
  final String requestId, operation;
  final void Function()? onRequested;
  final token = _ScriptCancellation();
  String? revocationReason;
  String? ownershipRevocationReason;
  bool invoked = false;
  bool requestedRecorded = false;
  bool ended = false;

  void noteRequested() {
    if (!invoked || requestedRecorded) return;
    requestedRecorded = true;
    onRequested?.call();
  }
}

// Observing this branch does not replace the Future returned to its caller.
// An owner can already be cancelled when wait() first checks it.
void _observeSlashWaitError<T>(Future<T> future) {
  unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
}

extension _SlashHostOperations on _ScriptCoordinator {
  String _slashRequestId(String kind) => '$epoch:slash:$kind:${++slashHostState.serial}';

  bool _slashHostIdentity(_SlashExecutionOwner owner, TavernScriptHost host, int version) =>
      !owner.context.closed &&
      identical(contexts[owner.context.value.id], owner.context) &&
      identical(_host, host) &&
      _hostVersion == version &&
      !_closed;

  bool _slashOwnershipRevocation(String reason) =>
      reason == 'host-unavailable' || reason == 'context-closed' || reason == 'closed';

  TavernScriptException _slashHostError(
    _SlashInvocation invocation,
    String operation,
    TavernScriptErrorCode code,
    String message,
  ) => TavernScriptException(
    code: code,
    operation: operation,
    message: message,
    contextId: invocation.owner.context.value.id,
    executionId: invocation.owner.id,
    sourceSpan: invocation.sourceSpan,
  );

  TavernScriptException _slashCallCancellation(_SlashInvocation invocation, _SlashHostCall call) {
    try {
      call.owner.checkAlive();
    } on TavernScriptException catch (failure) {
      return failure;
    }
    final reason = call.revocationReason ?? call.ownershipRevocationReason;
    final unavailable =
        reason == 'host-unavailable' || reason == null && !_slashHostIdentity(call.owner, call.host, call.hostVersion);
    return _slashHostError(
      invocation,
      call.operation,
      unavailable ? TavernScriptErrorCode.hostUnavailable : TavernScriptErrorCode.cancelled,
      unavailable ? 'The captured host is no longer attached.' : 'The host operation was cancelled.',
    );
  }

  void _checkSlashHostCall(_SlashInvocation invocation, _SlashHostCall call) {
    call.owner.checkAlive();
    if (call.revocationReason != null || call.token.isCancelled) {
      throw _slashCallCancellation(invocation, call);
    }
    if (!_slashHostIdentity(call.owner, call.host, call.hostVersion)) {
      throw _slashHostError(
        invocation,
        call.operation,
        TavernScriptErrorCode.hostUnavailable,
        'The captured host is no longer attached.',
      );
    }
  }

  void _revokeSlashHostCall(_SlashHostCall call, String reason) {
    if (call.ended) return;
    call.revocationReason ??= reason;
    if (_slashOwnershipRevocation(reason)) {
      call.ownershipRevocationReason ??= reason;
    }
    // A lifecycle hook can be reentered from inside the actual host method.
    // In that case the invocation has happened, even before it returns.
    call.noteRequested();
    call.token.cancel(reason);
  }

  Future<T> _slashHostCall<T>(
    _SlashInvocation invocation,
    String operation,
    String requestId,
    TavernSlashWaitKind waitKind,
    Future<T> Function(TavernScriptHost, TavernScriptCancellation) invoke, {
    void Function()? requested,
    void Function(T)? received,
    void Function(T)? accepted,
    void Function(_SlashHostCall, T)? late,
    void Function(TavernScriptException)? rejected,
  }) async {
    final owner = invocation.owner;
    owner.checkAlive();
    final host = _host;
    if (host == null) {
      throw _slashHostError(
        invocation,
        operation,
        TavernScriptErrorCode.hostUnavailable,
        'This operation requires an attached host.',
      );
    }
    final call = _SlashHostCall(owner, host, _hostVersion, requestId, operation, requested);
    slashHostState.calls.add(call);
    final completed = Completer<T>();
    _observeSlashWaitError(completed.future);

    bool settled() => completed.isCompleted || call.ended || owner.terminal;
    TavernScriptException normalize(Object error) =>
        _scriptReportedFailure(error) ??
        _slashHostError(
          invocation,
          operation,
          TavernScriptErrorCode.hookFailure,
          'The host operation failed (${error.runtimeType}).',
        );

    void reject(Object error, StackTrace stack, {bool fromHost = false}) {
      final original = normalize(error);
      if (settled()) {
        if (fromHost) _slashLateHostIssue(call, original);
        return;
      }
      if (fromHost) {
        owner.observeIssues(original.issues, committed: original.committed, observationKey: call);
      }
      var failure = original;
      try {
        _checkSlashHostCall(invocation, call);
      } on TavernScriptException catch (ownerFailure) {
        failure = ownerFailure;
      }
      if (call.invoked) rejected?.call(failure);
      completed.completeError(failure, stack);
    }

    void receive(T value) {
      if (settled()) {
        try {
          late?.call(call, value);
        } catch (error) {
          _slashLateHostIssue(call, normalize(error));
        }
        return;
      }
      try {
        // A real reply can carry known effects even if the following owner
        // check rejects its value. A settled cancellation goes through late.
        received?.call(value);
        _checkSlashHostCall(invocation, call);
        accepted?.call(value);
        completed.complete(value);
      } catch (error, stack) {
        reject(error, stack);
      }
    }

    unawaited(
      owner.token.whenCancelled.then<void>((_) {
        _revokeSlashHostCall(call, 'cancelled');
      }),
    );
    unawaited(
      call.token.whenCancelled.then<void>((_) {
        if (!settled()) {
          reject(_slashCallCancellation(invocation, call), StackTrace.current);
        }
      }),
    );

    try {
      _checkSlashHostCall(invocation, call);
      Future<T>? response;
      Object? synchronousError;
      StackTrace? synchronousStack;
      var threw = false;
      try {
        call.invoked = true;
        response = invoke(host, call.token);
      } catch (error, stack) {
        threw = true;
        synchronousError = error;
        synchronousStack = stack;
      } finally {
        // A synchronous throw still means the method was actually invoked.
        call.noteRequested();
      }
      if (threw) {
        reject(synchronousError!, synchronousStack!, fromHost: true);
      } else {
        unawaited(
          response!.then<void>(
            receive,
            onError: (Object error, StackTrace stack) {
              reject(error, stack, fromHost: true);
            },
          ),
        );
      }
      try {
        return await owner.wait(completed.future, waitKind);
      } catch (error, stack) {
        if (!settled()) reject(error, stack);
        rethrow;
      }
    } finally {
      call.ended = true;
      call.token.cancel('request-ended');
      slashHostState.calls.remove(call);
    }
  }

  void _publishSlashHost(
    _SlashHostCall call,
    String status, {
    String phase = 'late',
    String? kind,
    bool committed = false,
    List<TavernScriptIssue> issues = const [],
  }) {
    final context = call.owner.context;
    if (context.closed || _closed || _events.isClosed || !identical(contexts[context.value.id], context)) {
      return;
    }
    final dispatch = _dispatch(
      context,
      kind: TavernScriptDispatchKind.lifecycle,
      namespace: 'slash',
      name: 'HOST_OPERATION',
      args: [
        {
          'executionId': call.owner.id,
          'requestId': call.requestId,
          'operation': call.operation,
          'status': status,
          'kind': ?kind,
        },
      ],
    );
    _events.add(
      TavernScriptEvent(
        dispatch: dispatch,
        phase: phase,
        committed: committed || issues.any((issue) => issue.committed),
        issues: issues,
      ),
    );
  }

  void _slashLateHostIssue(_SlashHostCall call, TavernScriptException failure) {
    _publishSlashHost(
      call,
      'failed',
      committed: failure.committed,
      issues: failure.issues.isEmpty
          ? [
              TavernScriptIssue(
                code: failure.code.name,
                message: failure.message,
                committed: failure.committed,
                contextId: call.owner.context.value.id,
                stage: call.operation,
                sourceSpan: failure.sourceSpan,
                cancelled: failure.code == TavernScriptErrorCode.cancelled,
              ),
            ]
          : failure.issues,
    );
  }

  Future<TavernResolvedSlash> _resolveSlashSource(_SlashInvocation invocation, TavernSlashReference reference) async {
    if (reference.contextId != invocation.owner.context.value.id) {
      throw _slashHostError(
        invocation,
        'resolveSlash',
        TavernScriptErrorCode.invalidArgument,
        'The slash source belongs to a different context.',
      );
    }
    final result = await _slashHostCall<TavernResolvedSlash?>(
      invocation,
      'resolveSlash',
      _slashRequestId('resolve'),
      TavernSlashWaitKind.resolveSlash,
      (host, token) => host.resolveSlash(reference, token),
    );
    if (result == null) {
      throw _slashHostError(
        invocation,
        'resolveSlash',
        TavernScriptErrorCode.notFound,
        'The host did not resolve the requested slash source.',
      );
    }
    if (result.assetId.isEmpty || result.version.isEmpty) {
      throw _slashHostError(
        invocation,
        'resolveSlash',
        TavernScriptErrorCode.shapeMismatch,
        'A resolved source must have nonempty asset and version identities.',
      );
    }
    return TavernResolvedSlash(assetId: result.assetId, version: result.version, source: result.source);
  }

  // Pure validation. The return value identifies the two prescribed UI
  // confirmations; it does not infer persistence from ordinary user answers.
  bool _inspectSlashUiResult(
    _SlashInvocation invocation,
    String requestId,
    String kind,
    Map<String, Object?> fields,
    TavernScriptUiResult result,
  ) {
    if (result.requestId != requestId || !const {'submitted', 'cancelled', 'dismissed'}.contains(result.status)) {
      throw _slashHostError(
        invocation,
        'interact',
        TavernScriptErrorCode.shapeMismatch,
        'The UI result has the wrong request or status.',
      );
    }
    switch (kind) {
      case 'input':
        if (result.status == 'submitted' && result.text == null) {
          throw _slashHostError(
            invocation,
            'interact',
            TavernScriptErrorCode.shapeMismatch,
            'A submitted input result needs actual text.',
          );
        }
      case 'buttons':
        if (result.status == 'submitted') {
          final labels = fields['buttonLabels']! as List<String>;
          final index = result.buttonIndex;
          if (index == null ||
              index < 0 ||
              index >= labels.length ||
              result.label != null && result.label != labels[index]) {
            throw _slashHostError(
              invocation,
              'interact',
              TavernScriptErrorCode.shapeMismatch,
              'The selected button index or label is inconsistent.',
            );
          }
        }
      case 'popup':
        break;
      case 'echo':
      case 'setInput':
        if (result.status == 'cancelled' || kind == 'setInput' && result.status != 'submitted') {
          throw _slashHostError(
            invocation,
            'interact',
            TavernScriptErrorCode.cancelled,
            'The UI operation did not confirm its effect.',
          );
        }
        if (result.text == null) {
          throw _slashHostError(
            invocation,
            'interact',
            TavernScriptErrorCode.shapeMismatch,
            'The UI result must include its actual text.',
          );
        }
        return true;
      default:
        throw _slashHostError(invocation, 'interact', TavernScriptErrorCode.invalidArgument, 'Unknown UI kind.');
    }
    return false;
  }

  Future<TavernScriptUiResult> _interactForExecution(
    _SlashInvocation invocation,
    String kind,
    Map<String, Object?> fields,
  ) {
    final owner = invocation.owner;
    final id = _slashRequestId('ui');
    final request = TavernScriptUiRequest(
      requestId: id,
      contextId: owner.context.value.id,
      executionId: owner.id,
      kind: kind,
      fields: fields,
    );
    final target = <String, Object?>{'requestId': id, 'kind': kind};
    var confirmed = false;
    return _slashHostCall<TavernScriptUiResult>(
      invocation,
      'interact',
      id,
      TavernSlashWaitKind.ui,
      (host, token) => host.interact(request, token),
      requested: () {
        owner.recordEffect(
          kind: TavernSlashEffectKind.ui,
          state: TavernSlashEffectState.requested,
          operation: 'interact',
          target: target,
          sourceSpan: invocation.sourceSpan,
        );
      },
      received: (result) {
        confirmed = _inspectSlashUiResult(invocation, id, kind, fields, result);
        if (confirmed) owner.observeIssues(const [], committed: true);
      },
      accepted: (result) {
        owner.recordEffect(
          kind: TavernSlashEffectKind.ui,
          state: result.status == 'cancelled' ? TavernSlashEffectState.cancelled : TavernSlashEffectState.completed,
          operation: 'interact',
          target: target,
          committed: confirmed,
          sourceSpan: invocation.sourceSpan,
          details: {'status': result.status},
        );
      },
      rejected: (failure) {
        // A host exception's unspecified known flag belongs to the summary;
        // only an inspected actual UI confirmation can mark this target true.
        owner.recordEffect(
          kind: TavernSlashEffectKind.ui,
          state: failure.code == TavernScriptErrorCode.cancelled
              ? TavernSlashEffectState.cancelled
              : TavernSlashEffectState.failed,
          operation: 'interact',
          target: target,
          committed: confirmed,
          sourceSpan: invocation.sourceSpan,
          details: {'code': failure.code.name},
        );
      },
      late: (call, result) {
        final actual = _inspectSlashUiResult(invocation, id, kind, fields, result);
        // This is an observation of the original request, never a new
        // execution effect or a successful replacement for cancelled work.
        _publishSlashHost(call, result.status, kind: kind, committed: actual);
      },
    );
  }

  Future<String> _executeSlashUi(_SlashInvocation invocation) async {
    final body = _slashBody(invocation);
    final command = invocation.command;
    final fields = <String, Object?>{'text': body};
    if (command != 'setinput') {
      fields.addAll({'textKind': 'html', 'renderMarkdown': false});
    }
    var popupResult = false;
    List<String> labels = const [];
    switch (command) {
      case 'input':
        {
          final rows = ScriptCoercion.number(_slashNamed(invocation, 'rows', fallback: '4'));
          if (!rows.isFinite || rows <= 0 || rows != rows.floorToDouble()) {
            throw _slashArgument(invocation, 'rows', 'Rows must be a positive finite integer.');
          }
          fields.addAll({
            'defaultValue': _slashNamed(invocation, 'default'),
            'rows': rows.toInt(),
            'wide': _slashTrue(invocation, 'wide'),
            'large': _slashTrue(invocation, 'large'),
            'okButton': _slashNamed(invocation, 'okButton', fallback: 'Ok'),
          });
        }
      case 'buttons':
        {
          final value = await _slashResolveTextValue(invocation, _slashNamed(invocation, 'labels'));
          if (value is! String || value.isEmpty) {
            throw _slashArgument(invocation, 'labels', 'Button labels require a nonempty JSON string array.');
          }
          Object? parsed;
          try {
            parsed = jsonDecode(value);
          } on FormatException {
            throw _slashArgument(
              invocation,
              'labels',
              'Button labels must be valid JSON.',
              code: TavernScriptErrorCode.invalidJson,
            );
          }
          if (parsed is! List<Object?> || parsed.isEmpty || parsed.any((item) => item is! String || item.isEmpty)) {
            throw _slashArgument(invocation, 'labels', 'Button labels must be nonempty strings.');
          }
          labels = parsed.cast<String>();
          fields['buttonLabels'] = labels;
        }
      case 'popup':
        {
          popupResult = _slashTrue(invocation, 'result');
          fields.addAll({
            'wide': _slashTrue(invocation, 'wide'),
            'large': _slashTrue(invocation, 'large'),
            'scroll': !_slashFalse(invocation, 'scroll'),
            'okButton': _slashNamed(invocation, 'okButton', fallback: 'OK'),
          });
          final title = _slashNamed(invocation, 'header');
          if (title.isNotEmpty) fields['title'] = title;
        }
      case 'echo':
        {
          if (body.isEmpty) return '';
          var severity = _slashNamed(invocation, 'severity', fallback: 'info');
          if (severity.isEmpty) severity = 'info';
          if (!const {'error', 'warning', 'success', 'info'}.contains(severity)) {
            invocation.owner.observeIssues([
              TavernScriptIssue(
                code: 'invalidSeverity',
                message: 'The unknown echo severity was replaced by info.',
                committed: false,
                contextId: invocation.owner.context.value.id,
                sourceSpan: invocation.sourceSpan,
                stage: 'handler',
                details: {'severity': severity},
              ),
            ]);
            severity = 'info';
          }
          fields.addAll({
            'textKind': !invocation.has('escapeHtml') || _slashTrue(invocation, 'escapeHtml') ? 'plain' : 'html',
            'severity': severity,
            'awaitDismissal': _slashTrue(invocation, 'awaitDismissal'),
          });
          final title = _slashNamed(invocation, 'title');
          if (title.isNotEmpty) fields['title'] = title;
        }
      case 'setinput':
        break;
      default:
        throw _slashArgument(invocation, 'command', 'Unknown UI command.');
    }
    final result = await _interactForExecution(invocation, command == 'setinput' ? 'setInput' : command, fields);
    return switch (command) {
      'input' => result.status == 'submitted' ? result.text! : '',
      'buttons' => result.status == 'submitted' ? labels[result.buttonIndex!] : '',
      'popup' =>
        !popupResult
            ? body
            : result.status == 'submitted'
            ? '1'
            : result.status == 'cancelled'
            ? '0'
            : '',
      'echo' || 'setinput' => result.text!,
      _ => throw _slashArgument(invocation, 'command', 'Unknown UI command.'),
    };
  }

  void _slashHostReplaced(TavernScriptHost? oldHost, int oldVersion) {
    for (final call in slashHostState.calls.toList()) {
      if (identical(call.host, oldHost) && call.hostVersion == oldVersion) {
        _revokeSlashHostCall(call, 'host-unavailable');
      }
    }
    for (final lease in slashHostState.leases.toList()) {
      if (identical(lease.host, oldHost) && lease.hostVersion == oldVersion) {
        _revokeSlashLease(lease, 'host-unavailable');
      }
    }
  }

  void _slashContextClosed(_ScriptContextState context) {
    for (final call in slashHostState.calls.toList()) {
      if (identical(call.owner.context, context)) {
        _revokeSlashHostCall(call, 'context-closed');
      }
    }
    for (final lease in slashHostState.leases.toList()) {
      if (identical(lease.owner.context, context)) {
        _revokeSlashLease(lease, 'context-closed');
      }
    }
  }

  void _slashHostClosed() {
    for (final call in slashHostState.calls.toList()) {
      _revokeSlashHostCall(call, 'closed');
    }
    for (final lease in slashHostState.leases.toList()) {
      _revokeSlashLease(lease, 'closed');
    }
  }
}
