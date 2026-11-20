part of 'engine.dart';

/// A captured source is separate from its raw id and its assembler identifier.
/// In particular a persistent and a transient source may have the same raw id.
class _ScriptInjectionCandidate {
  _ScriptInjectionCandidate({
    required this.source,
    required this.rawId,
    required this.sourceRef,
    required this.raw,
    required this.assemblerId,
    required this.sourceOrder,
    this.injection,
    this.registration,
    this.persistentVersion,
    this.persistentSource,
    this.filterStatus = 'none',
    this.issues = const [],
  });
  final String source, rawId, assemblerId;
  final Map<String, Object?> sourceRef;
  final Object? raw;
  final int sourceOrder;
  final TavernScriptInjection? injection;
  final _ScriptInjectionRegistration? registration;
  final String? persistentVersion;
  final ChatJsonlMetadataSource? persistentSource;
  final String filterStatus;
  final List<TavernScriptIssue> issues;
}

class _ScriptInjectionRegistration {
  _ScriptInjectionRegistration({
    required this.chatId,
    required this.ownerContextId,
    required this.ownerInstanceId,
    required this.version,
    required this.leaseId,
    required this.injection,
    required this.once,
  });
  final String chatId, ownerContextId, ownerInstanceId, version, leaseId;
  final TavernScriptInjection injection;
  final bool once;
  bool claimed = false;
}

class _ScriptInjectionUseSet {
  _ScriptInjectionUseSet(Iterable<_ScriptInjectionCandidate> used, {Iterable<TavernScriptIssue> hookIssues = const []})
    : used = List.unmodifiable(used),
      hookIssues = List.unmodifiable(hookIssues);
  final List<_ScriptInjectionCandidate> used;
  final List<TavernScriptIssue> hookIssues;
}

class _ScriptPreparedInjections {
  _ScriptPreparedInjections({required Iterable<String> scanTexts, required Iterable<PromptInjection> prompts})
    : scanTexts = List.unmodifiable(scanTexts),
      prompts = List.unmodifiable(prompts);
  final List<String> scanTexts;
  final List<PromptInjection> prompts;
}

/// Engine-owned, ephemeral registrations. No entry in this service is written
/// to chat JSON, a backup, or the public persistent variable store.
class _ScriptInjectionRegistry {
  _ScriptInjectionRegistry(this.owner);
  final _ScriptCoordinator owner;
  final _byChat = <String, Map<String, _ScriptInjectionRegistration>>{};
  final _leases = <String, TavernScriptInjectionLease>{};
  int _serial = 0;

  String _identity(String kind) => '${owner.epoch}/$kind/${++_serial}';

  TavernScriptInjectionLease register(String contextId, List<TavernScriptInjection> prompts, {bool once = false}) {
    final context = owner._context(contextId);
    final chatId = context.value.chatId;
    if (chatId == null) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'injectPrompts',
        'An injection registration requires the calling context chat.',
        contextId: contextId,
      );
    }
    owner.engine._store.chat(chatId);
    final ids = <String>{};
    final captured = <TavernScriptInjection>[];
    // Validate the entire batch before changing a single current registration.
    for (final prompt in prompts) {
      if (!ids.add(prompt.id)) {
        throw _scriptError(
          TavernScriptErrorCode.duplicateId,
          'injectPrompts',
          'A registration batch contains a duplicate raw id.',
          contextId: contextId,
        );
      }
      validateCallbackOwner(prompt, context);
      captured.add(_copyInjection(prompt));
    }
    final leaseId = _identity('lease');
    final registrations = <TavernScriptInjectionRegistration>[];
    final updates = <_ScriptInjectionRegistration>[];
    for (final prompt in captured) {
      final version = _identity('registration');
      updates.add(
        _ScriptInjectionRegistration(
          chatId: chatId,
          ownerContextId: contextId,
          ownerInstanceId: context.value.instanceId,
          version: version,
          leaseId: leaseId,
          injection: prompt,
          once: once,
        ),
      );
      registrations.add(TavernScriptInjectionRegistration(id: prompt.id, registrationVersion: version));
    }
    final lease = TavernScriptInjectionLease(
      leaseId: leaseId,
      chatId: chatId,
      ownerContextId: contextId,
      ownerInstanceId: context.value.instanceId,
      registrations: registrations,
    );
    if (updates.isNotEmpty) {
      final current = _byChat.putIfAbsent(chatId, () => {});
      for (final update in updates) {
        current[update.injection.id] = update;
      }
    }
    _leases[leaseId] = lease;
    return lease;
  }

  void validateCallbackOwner(TavernScriptInjection injection, _ScriptContextState origin) {
    final ref = injection.filter;
    if (ref == null) return;
    if (ref.contextId != origin.value.id ||
        ref.instanceId != origin.value.instanceId ||
        ref.callbackId.isEmpty ||
        origin.closed) {
      throw _scriptError(
        TavernScriptErrorCode.callbackUnavailable,
        'injectionFilter',
        'The callback must belong to the live calling context instance.',
        contextId: origin.value.id,
      );
    }
  }

  void uninject(String contextId, List<String> ids) {
    final context = owner._context(contextId);
    final chatId = context.value.chatId;
    if (chatId == null) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'uninjectPrompts',
        'This context has no chat.',
        contextId: contextId,
      );
    }
    if (ids.any((id) => id.isEmpty)) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'uninjectPrompts',
        'Injection ids must be nonempty.',
        contextId: contextId,
      );
    }
    final current = _byChat[chatId];
    if (current == null) return;
    for (final id in ids) {
      current.remove(id);
    }
    if (current.isEmpty) _byChat.remove(chatId);
  }

  void release(String leaseId) {
    final lease = _leases.remove(leaseId);
    if (lease == null) return;
    final current = _byChat[lease.chatId];
    if (current == null) return;
    for (final entry in lease.registrations) {
      final registration = current[entry.id];
      if (registration != null &&
          registration.version == entry.registrationVersion &&
          registration.ownerContextId == lease.ownerContextId &&
          registration.ownerInstanceId == lease.ownerInstanceId &&
          registration.leaseId == leaseId) {
        current.remove(entry.id);
      }
    }
    if (current.isEmpty) _byChat.remove(lease.chatId);
  }

  void closeOwner(String contextId, String instanceId) {
    for (final chatId in _byChat.keys.toList()) {
      final current = _byChat[chatId]!;
      current.removeWhere((_, entry) => entry.ownerContextId == contextId && entry.ownerInstanceId == instanceId);
      if (current.isEmpty) _byChat.remove(chatId);
    }
    _leases.removeWhere((_, lease) => lease.ownerContextId == contextId && lease.ownerInstanceId == instanceId);
  }

  List<TavernScriptInjectionView> list(String contextId) {
    final context = owner._context(contextId);
    final chatId = context.value.chatId;
    if (chatId == null) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'listInjections',
        'This context has no chat.',
        contextId: contextId,
      );
    }
    final metadata = owner.engine._chatCodec.metadataForNode(owner.engine._store, chatId);
    final result = <TavernScriptInjectionView>[];
    for (final candidate in _persistent(chatId, metadata, observe: false)) {
      result.add(
        TavernScriptInjectionView(
          source: TavernScriptInjectionSource.persistent,
          sourceRef: candidate.sourceRef,
          raw: candidate.raw,
          injection: candidate.injection,
          filterStatus: candidate.filterStatus,
          issues: candidate.issues,
        ),
      );
    }
    for (final registration in _byChat[chatId]?.values ?? <_ScriptInjectionRegistration>[]) {
      final candidate = _transient(registration);
      result.add(
        TavernScriptInjectionView(
          source: TavernScriptInjectionSource.transient,
          sourceRef: candidate.sourceRef,
          raw: candidate.raw,
          injection: candidate.injection,
          filterStatus: candidate.filterStatus,
          ownerContextId: registration.ownerContextId,
          ownerInstanceId: registration.ownerInstanceId,
          registrationVersion: registration.version,
          once: registration.once,
          claimed: registration.claimed,
          leaseId: registration.leaseId,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  List<_ScriptInjectionCandidate> capture({
    required String? chatId,
    required Map<String, Object?> metadata,
    required ChatJsonlMetadataSource? persistentSource,
    List<TavernScriptInjection> request = const [],
  }) {
    final result = <_ScriptInjectionCandidate>[];
    if (chatId != null) {
      if (persistentSource == null) throw StateError('A captured chat requires its metadata source.');
      result.addAll(_persistent(chatId, metadata, source: persistentSource, observe: true));
      for (final registration in _byChat[chatId]?.values ?? <_ScriptInjectionRegistration>[]) {
        if (!registration.claimed) result.add(_transient(registration));
      }
    }
    for (final (requestIndex, injection) in request.indexed) {
      final copy = _copyInjection(injection);
      result.add(
        _ScriptInjectionCandidate(
          source: 'request',
          rawId: copy.id,
          sourceRef: {'kind': 'request', 'chatId': chatId, 'rawId': copy.id, 'index': requestIndex},
          raw: _injectionJson(copy),
          assemblerId: _assemblerId(),
          sourceOrder: 2,
          injection: copy,
          filterStatus: copy.filter == null ? 'none' : 'callback',
        ),
      );
    }
    return List.unmodifiable(result);
  }

  String _assemblerId() => 'dshScriptInjection${++_serial}';

  _ScriptInjectionCandidate _transient(_ScriptInjectionRegistration registration) =>
      _transientScriptInjection(registration, assemblerId: _assemblerId());

  List<_ScriptInjectionCandidate> _persistent(
    String chatId,
    Map<String, Object?> metadata, {
    ChatJsonlMetadataSource? source,
    required bool observe,
  }) {
    final raw = _persistentScriptInjections(chatId, metadata);
    return [
      for (final entry in raw.entries)
        _persistentEntry(chatId, entry.key, _captureScriptJson(entry.value), source: source, observe: observe),
    ];
  }

  _ScriptInjectionCandidate _persistentEntry(
    String chatId,
    String rawId,
    Object? raw, {
    ChatJsonlMetadataSource? source,
    required bool observe,
  }) {
    final parsed = _parsePersistentScriptInjection(chatId, rawId, raw);
    return _ScriptInjectionCandidate(
      source: 'persistent',
      rawId: rawId,
      sourceRef: parsed.sourceRef,
      raw: raw,
      assemblerId: _assemblerId(),
      sourceOrder: 0,
      injection: parsed.injection,
      issues: parsed.issues,
      filterStatus: parsed.filterStatus,
      persistentSource: source,
      persistentVersion: observe ? owner.persistentInjectionVersion(chatId, source!, rawId, raw) : null,
    );
  }

  Future<_ScriptInjectionUseSet> filter(
    List<_ScriptInjectionCandidate> candidates, {
    required String generationId,
    required ModelCancellation cancellation,
    void Function(Object request, List<TavernScriptIssue> issues, bool committed)? onObservedIssues,
  }) async {
    final used = <_ScriptInjectionCandidate>[];
    final hookIssues = <TavernScriptIssue>[];
    try {
      for (final candidate in candidates) {
        cancellation.check();
        if (candidate.injection == null || candidate.filterStatus == 'unsupportedPersistent') {
          final code = candidate.injection == null
              ? TavernScriptErrorCode.shapeMismatch
              : TavernScriptErrorCode.unsupportedCapability;
          throw _filterFailure(
            code,
            'A captured persistent injection cannot be prepared.',
            candidate,
            generationId,
            issues: candidate.issues,
          );
        }
        final ref = candidate.injection!.filter;
        if (ref == null ||
            await _invokeFilter(
              ref,
              candidate,
              generationId,
              cancellation,
              hookIssues,
              onObservedIssues: onObservedIssues,
            )) {
          used.add(candidate);
        }
      }
      cancellation.check();
    } on TavernScriptException catch (error) {
      final known = <TavernScriptIssue>[...hookIssues];
      for (final issue in error.issues) {
        if (!known.contains(issue)) known.add(issue);
      }
      throw TavernScriptException(
        code: error.code,
        operation: error.operation,
        message: error.message,
        contextId: error.contextId,
        generationId: error.generationId,
        fieldPath: error.fieldPath,
        committed: error.committed || known.any((issue) => issue.committed),
        issues: known,
        modelFailure: error.modelFailure,
      );
    } on TavernModelException catch (error) {
      if (error.kind != TavernFailure.cancelled) rethrow;
      throw TavernScriptException(
        code: TavernScriptErrorCode.cancelled,
        operation: 'injectionFilter',
        message: 'The injection filter preparation was cancelled.',
        generationId: generationId,
        committed: hookIssues.any((issue) => issue.committed),
        issues: hookIssues,
      );
    }
    return _ScriptInjectionUseSet(used, hookIssues: hookIssues);
  }

  Future<bool> _invokeFilter(
    TavernScriptCallbackRef ref,
    _ScriptInjectionCandidate candidate,
    String generationId,
    ModelCancellation cancellation,
    List<TavernScriptIssue> hookIssues, {
    void Function(Object request, List<TavernScriptIssue> issues, bool committed)? onObservedIssues,
  }) async {
    final context = owner.contexts[ref.contextId];
    if (context == null || context.closed || context.value.instanceId != ref.instanceId || ref.callbackId.isEmpty) {
      throw _filterFailure(
        TavernScriptErrorCode.callbackUnavailable,
        'The filter owner instance is no longer available.',
        candidate,
        generationId,
      );
    }
    final host = owner._host;
    if (host == null) {
      throw _filterFailure(
        TavernScriptErrorCode.hostUnavailable,
        'No script host can invoke this filter.',
        candidate,
        generationId,
      );
    }
    final hostVersion = owner._hostVersion;
    final token = _ScriptCancellation();
    context.hostCallbacks.add(token);
    var settled = false;
    if (cancellation.isCancelled) token.cancel();
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!settled) token.cancel();
      }),
    );
    final request = TavernScriptCallbackRequest(
      requestId: _identity('filter'),
      ref: ref,
      kind: 'filter',
      args: const [],
    );
    try {
      final TavernScriptCallbackResult? result;
      try {
        result = await owner._ownDelivery(
          () => Future.any<TavernScriptCallbackResult?>([
            if (!token.isCancelled) Future<TavernScriptCallbackResult>.sync(() => host.invoke(request, token)),
            token.whenCancelled.then<TavernScriptCallbackResult?>((_) => null),
          ]),
        );
      } catch (error) {
        final reported = owner._scriptReportedFailure(error);
        final issues = reported?.issues ?? const <TavernScriptIssue>[];
        final committed = reported?.committed == true;
        // Only the outcome which won Future.any reaches this boundary. A
        // subsequent owner/host check cannot erase its already received facts.
        onObservedIssues?.call(request, issues, committed);
        if (context.closed || context.value.instanceId != ref.instanceId) {
          throw _filterFailure(
            TavernScriptErrorCode.callbackUnavailable,
            'The filter owner ended before its result.',
            candidate,
            generationId,
            issues: issues,
            committed: committed,
          );
        }
        if (hostVersion != owner._hostVersion) {
          throw _filterFailure(
            TavernScriptErrorCode.hostUnavailable,
            'The script host changed before its filter result.',
            candidate,
            generationId,
            issues: issues,
            committed: committed,
          );
        }
        if (token.isCancelled || cancellation.isCancelled) {
          throw _filterFailure(
            TavernScriptErrorCode.cancelled,
            'The injection filter was cancelled.',
            candidate,
            generationId,
            issues: issues,
            committed: committed,
          );
        }
        throw _filterFailure(
          TavernScriptErrorCode.hookFailure,
          'The script host threw while invoking the filter.',
          candidate,
          generationId,
          issues: issues,
          committed: committed,
        );
      }
      if (result != null) onObservedIssues?.call(request, result.issues, false);
      if (context.closed || context.value.instanceId != ref.instanceId) {
        throw _filterFailure(
          TavernScriptErrorCode.callbackUnavailable,
          'The filter owner ended before its result.',
          candidate,
          generationId,
          issues: result?.issues ?? const [],
        );
      }
      if (hostVersion != owner._hostVersion) {
        throw _filterFailure(
          TavernScriptErrorCode.hostUnavailable,
          'The script host changed before its filter result.',
          candidate,
          generationId,
          issues: result?.issues ?? const [],
        );
      }
      if (result == null || token.isCancelled || cancellation.isCancelled) {
        throw _filterFailure(
          TavernScriptErrorCode.cancelled,
          'The injection filter was cancelled.',
          candidate,
          generationId,
          issues: result?.issues ?? const [],
        );
      }
      for (final issue in result.issues) {
        if (!hookIssues.contains(issue)) hookIssues.add(issue);
      }
      if (result.requestId != request.requestId) {
        throw _filterFailure(
          TavernScriptErrorCode.hookFailure,
          'The filter returned a different request identity.',
          candidate,
          generationId,
          issues: result.issues,
        );
      }
      if (result.status == 'cancelled') {
        throw _filterFailure(
          TavernScriptErrorCode.cancelled,
          'The script host cancelled the filter.',
          candidate,
          generationId,
          issues: result.issues,
        );
      }
      if (result.status != 'completed') {
        throw _filterFailure(
          TavernScriptErrorCode.hookFailure,
          'The script host failed the filter.',
          candidate,
          generationId,
          issues: result.issues,
        );
      }
      if (result.value is! bool) {
        throw _filterFailure(
          TavernScriptErrorCode.shapeMismatch,
          'A completed filter must return a boolean.',
          candidate,
          generationId,
          issues: result.issues,
        );
      }
      return result.value!;
    } finally {
      settled = true;
      context.hostCallbacks.remove(token);
    }
  }

  _ScriptPreparedInjections prepareInjections(_ScriptInjectionUseSet uses, _MacroEnvironment environment) =>
      _prepareScriptInjections(uses, environment);

  /// All validation precedes all claims and there is deliberately no await.
  List<TavernJsonObject> claim(_ScriptInjectionUseSet uses, {required String generationId}) {
    for (final candidate in uses.used) {
      final captured = candidate.registration;
      if (captured != null) {
        final current = _byChat[captured.chatId]?[candidate.rawId];
        _checkScriptRegistrationClaim(candidate, current, generationId);
      } else if (candidate.source == 'persistent') {
        final chatId = candidate.sourceRef['chatId']! as String;
        final current = owner.currentPersistentInjectionVersion(chatId, candidate.persistentSource!, candidate.rawId);
        _checkScriptPersistentClaim(candidate, current, generationId);
      }
    }
    return _claimScriptInjectionOnce(uses);
  }

  TavernScriptException _filterFailure(
    TavernScriptErrorCode code,
    String message,
    _ScriptInjectionCandidate candidate,
    String generationId, {
    List<TavernScriptIssue> issues = const [],
    String stage = 'injectionFilter',
    bool committed = false,
  }) => _scriptInjectionFailure(
    code,
    message,
    candidate,
    generationId,
    issues: issues,
    stage: stage,
    committed: committed,
  );
}

Map<String, Object?> _persistentScriptInjections(String chatId, Map<String, Object?> metadata) {
  if (!metadata.containsKey('script_injects')) {
    return const {};
  }
  final raw = metadata['script_injects'];
  if (raw is! Map<String, Object?>) {
    throw _scriptError(
      TavernScriptErrorCode.shapeMismatch,
      'scriptInjections',
      'metadata.script_injects must be an object.',
      fieldPath: 'script_injects',
      issues: [
        _sourceIssue('shapeMismatch', 'metadata.script_injects must be an object.', {
          'kind': 'persistent',
          'chatId': chatId,
          'field': 'script_injects',
        }),
      ],
    );
  }
  return raw;
}

({
  Map<String, Object?> sourceRef,
  TavernScriptInjection? injection,
  String filterStatus,
  List<TavernScriptIssue> issues,
})
_parsePersistentScriptInjection(String chatId, String rawId, Object? raw) {
  final sourceRef = <String, Object?>{'kind': 'persistent', 'chatId': chatId, 'rawId': rawId};
  final issues = <TavernScriptIssue>[];
  TavernScriptInjection? injection;
  var filterStatus = 'none';
  try {
    if (rawId.isEmpty || raw is! Map<String, Object?> || raw['value'] is! String) {
      throw const FormatException('Expected a nonempty id and an object with a string value.');
    }
    final depth = raw['depth'] ?? 4;
    final position = raw['position'] ?? 0;
    final role = raw['role'] ?? 0;
    final scan = raw['scan'] ?? false;
    final filter = raw['filter'];
    if (depth is! num ||
        !depth.isFinite ||
        depth != depth.truncateToDouble() ||
        depth < 0 ||
        depth > 10000 ||
        scan is! bool ||
        (filter != null && filter is! String)) {
      throw const FormatException('Persistent injection depth, scan or filter has an incompatible shape.');
    }
    final projectedPosition = switch (position) {
      -1 => TavernScriptInjectionPosition.scanOnly,
      0 => TavernScriptInjectionPosition.afterMain,
      1 => TavernScriptInjectionPosition.inChat,
      2 => TavernScriptInjectionPosition.beforeMain,
      _ => throw const FormatException('Unsupported persistent injection position.'),
    };
    final projectedRole = switch (role) {
      0 || 'system' => TavernScriptPromptRole.system,
      1 || 'user' => TavernScriptPromptRole.user,
      2 || 'assistant' => TavernScriptPromptRole.assistant,
      _ => throw const FormatException('Unsupported persistent injection role.'),
    };
    injection = TavernScriptInjection(
      id: rawId,
      content: raw['value']! as String,
      role: projectedRole,
      position: projectedPosition,
      depth: depth.toInt(),
      scan: scan,
    );
    if (filter is String && filter.isNotEmpty) {
      filterStatus = 'unsupportedPersistent';
      issues.add(
        _sourceIssue(
          'unsupportedCapability',
          'Serialized persistent filters require the STscript execution capability.',
          sourceRef,
        ),
      );
    }
  } on FormatException catch (error) {
    issues.add(_sourceIssue('shapeMismatch', error.message, sourceRef));
  }
  return (sourceRef: sourceRef, injection: injection, filterStatus: filterStatus, issues: List.unmodifiable(issues));
}

_ScriptInjectionCandidate _transientScriptInjection(
  _ScriptInjectionRegistration registration, {
  required String assemblerId,
}) {
  final injection = registration.injection;
  return _ScriptInjectionCandidate(
    source: 'transient',
    rawId: injection.id,
    sourceRef: {
      'kind': 'transient',
      'chatId': registration.chatId,
      'rawId': injection.id,
      'ownerContextId': registration.ownerContextId,
      'ownerInstanceId': registration.ownerInstanceId,
      'registrationVersion': registration.version,
    },
    raw: _injectionJson(injection),
    assemblerId: assemblerId,
    sourceOrder: 1,
    injection: injection,
    registration: registration,
    filterStatus: injection.filter == null ? 'none' : 'callback',
  );
}

_ScriptPreparedInjections _prepareScriptInjections(_ScriptInjectionUseSet uses, _MacroEnvironment environment) {
  final scanTexts = <String>[];
  final prompts = <PromptInjection>[];
  for (final candidate in uses.used) {
    final injection = candidate.injection!;
    final scan = injection.scan == true;
    final prompt = injection.position != TavernScriptInjectionPosition.scanOnly;
    // Closed outlets still participate in claim but never evaluate text.
    if (!scan && !prompt) {
      continue;
    }
    final text = environment.expand(injection.content, const {});
    if (scan) {
      scanTexts.add(text);
    }
    if (prompt) {
      prompts.add(
        PromptInjection(
          fragment: PromptFragment(
            text,
            PromptSource('scriptInjection', candidate.assemblerId, details: candidate.sourceRef),
            expandMacros: false,
          ),
          role: injection.role.name,
          depth: injection.depth,
          sortKey: candidate.rawId,
          sourceOrder: candidate.sourceOrder,
          placement: switch (injection.position) {
            TavernScriptInjectionPosition.beforeMain => PromptPlacement.beforeMain,
            TavernScriptInjectionPosition.afterMain => PromptPlacement.afterMain,
            _ => PromptPlacement.inChat,
          },
        ),
      );
    }
  }
  return _ScriptPreparedInjections(scanTexts: scanTexts, prompts: prompts);
}

void _checkScriptRegistrationClaim(
  _ScriptInjectionCandidate candidate,
  _ScriptInjectionRegistration? current,
  String generationId,
) {
  final captured = candidate.registration!;
  if (current == null ||
      !identical(current, captured) ||
      current.version != captured.version ||
      current.ownerContextId != captured.ownerContextId ||
      current.ownerInstanceId != captured.ownerInstanceId ||
      current.claimed) {
    throw _scriptInjectionFailure(
      TavernScriptErrorCode.revisionConflict,
      'A participating injection registration changed before acceptance.',
      candidate,
      generationId,
      stage: 'injectionClaim',
    );
  }
}

void _checkScriptPersistentClaim(_ScriptInjectionCandidate candidate, String? current, String generationId) {
  if (current == null || current != candidate.persistentVersion) {
    throw _scriptInjectionFailure(
      TavernScriptErrorCode.revisionConflict,
      'A participating persistent injection changed before acceptance.',
      candidate,
      generationId,
      stage: 'injectionClaim',
    );
  }
}

List<TavernJsonObject> _claimScriptInjectionOnce(_ScriptInjectionUseSet uses) {
  final claimed = <TavernJsonObject>[];
  for (final candidate in uses.used) {
    final registration = candidate.registration;
    if (registration != null && registration.once) {
      registration.claimed = true;
      claimed.add(_captureScriptObject({...candidate.sourceRef, 'sourceRef': candidate.sourceRef}));
    }
  }
  return List.unmodifiable(claimed);
}

TavernScriptException _scriptInjectionFailure(
  TavernScriptErrorCode code,
  String message,
  _ScriptInjectionCandidate candidate,
  String generationId, {
  List<TavernScriptIssue> issues = const [],
  String stage = 'injectionFilter',
  bool committed = false,
}) {
  final knownCommitted = committed || issues.any((issue) => issue.committed);
  return TavernScriptException(
    code: code,
    operation: stage,
    message: message,
    generationId: generationId,
    contextId: candidate.registration?.ownerContextId ?? candidate.injection?.filter?.contextId,
    committed: knownCommitted,
    issues: [
      ...issues,
      TavernScriptIssue(
        code: code.name,
        message: message,
        committed: knownCommitted,
        generationId: generationId,
        stage: stage,
        cancelled: code == TavernScriptErrorCode.cancelled,
        details: {'sourceRef': candidate.sourceRef},
      ),
    ],
  );
}

TavernScriptIssue _sourceIssue(String code, String message, Map<String, Object?> sourceRef) => TavernScriptIssue(
  code: code,
  message: message,
  committed: false,
  stage: 'injectionCapture',
  details: {'sourceRef': sourceRef},
);

TavernScriptInjection _copyInjection(TavernScriptInjection value) => TavernScriptInjection(
  id: value.id,
  content: value.content,
  role: value.role,
  position: value.position,
  depth: value.depth,
  scan: value.scan,
  filter: value.filter,
);

Map<String, Object?> _injectionJson(TavernScriptInjection value) => {
  'id': value.id,
  'content': value.content,
  'role': value.role.name,
  'position': value.position.name,
  'depth': value.depth,
  'scan': value.scan,
  if (value.filter case final ref?)
    'filter': {'contextId': ref.contextId, 'instanceId': ref.instanceId, 'callbackId': ref.callbackId},
};
