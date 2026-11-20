part of 'engine.dart';

extension _SlashChatEffects on _ScriptCoordinator {
  ({String? source, ChatJsonlMetadataSource target, Map<String, Object?> metadata}) _slashMetadataSource(
    StoredChat chat,
  ) {
    // metadataForNode uses root metadata for an empty selected path. For a
    // real page, capture the concrete carrier, including a files fallback's
    // slot. The private string is a route identity, not merely its raw label.
    final target = engine._chatCodec.metadataSourceForNode(engine._store, chat.id);
    final metadata = engine._chatCodec.readMetadataSource(chat.metadata, target)!;
    return (
      source: target.carrier == ChatJsonlMetadataCarrier.root ? null : target.identity,
      target: target,
      metadata: metadata,
    );
  }

  Future<_SlashChatAdmission> _captureSlashChat(_SlashExecutionOwner owner) => _bridgeOperation(() {
    owner.checkAlive();
    final capture = _captureChat(owner.context.value.id);
    if (!identical(capture.context, owner.context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        'slashChat',
        'The captured context instance is no longer active.',
        contextId: owner.context.value.id,
      );
    }
    final chat = engine._store.chat(capture.chatId);
    final selected = _slashMetadataSource(chat);
    return _SlashChatAdmission(
      capture: capture,
      selectionVersion: _generationFieldVersion(chat.id, 'selection'),
      metadataSourceVersion: _generationFieldVersion(chat.id, 'metadataSource'),
      metadataSource: selected.source,
      metadata: selected.metadata,
      settings: chat.settings,
    );
  });

  void _checkSlashChatAdmission(_SlashExecutionOwner owner, _SlashChatAdmission admission) {
    owner.checkAlive();
    final capture = admission.capture;
    if (!identical(_context(owner.context.value.id), owner.context) ||
        !identical(capture.context, owner.context) ||
        capture.chatId != owner.context.value.chatId) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        'slashChat',
        'The captured context instance is no longer active.',
        contextId: owner.context.value.id,
      );
    }
    final chat = engine._store.chat(capture.chatId);
    if (_generationFieldVersion(chat.id, 'selection') != admission.selectionVersion ||
        _generationFieldVersion(chat.id, 'metadataSource') != admission.metadataSourceVersion ||
        _slashMetadataSource(chat).source != admission.metadataSource) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'slashChat',
        'The selected path or metadata source changed after admission.',
        contextId: owner.context.value.id,
      );
    }
  }

  Map<String, String> _captureSlashBindingVersions(_SlashExecutionOwner owner, _SlashChatAdmission admission) {
    _checkSlashChatAdmission(owner, admission);
    return {
      for (final field in const ['metadata:world_info', 'settings:stLorebookIds', 'settings:lorebooks.chat'])
        field: _generationFieldVersion(admission.capture.chatId, field),
    };
  }

  TavernJsonObject _slashMessageTarget(String chatId, Iterable<TavernScriptMessageRef> refs) => {
    'kind': 'messages',
    'chatId': chatId,
    'refs': [
      for (final ref in refs) {'chatId': ref.chatId, 'nodeId': ref.nodeId},
    ],
  };

  void _checkSlashMessageRefs(_SlashChatAdmission admission, Iterable<TavernScriptMessageRef> refs, String operation) {
    final ids = {for (final node in admission.capture.path) node.message.nodeId};
    for (final ref in refs) {
      if (ref.chatId != admission.capture.chatId || !ids.contains(ref.nodeId)) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          operation,
          'The stable message reference is outside the admitted selected path.',
          contextId: admission.capture.context.value.id,
          nodeId: ref.nodeId,
        );
      }
    }
  }

  Future<T> _runSlashMessagePlan<T>(
    _SlashExecutionOwner owner,
    _SlashChatAdmission admission, {
    required String operation,
    required bool structural,
    required bool exactRevision,
    required TavernJsonObject target,
    required void Function(_ScriptMessagePlan plan) prepare,
    required T Function(_ScriptMessagePlan plan, TavernScriptMutation mutation) project,
    void Function()? check,
    List<_ScriptLifecycle> Function(T value)? additionalEvents,
  }) async {
    final scope = _ScriptEffectScope.slash(this, owner);
    var started = false;
    var sqlCommitted = false;
    late _ScriptMessagePlan plan;
    late TavernScriptMutation mutation;
    try {
      final result = await scope.drain(
        _bridgeOperation(() {
          T action(_ToolPreparationPermit? permit) {
            scope.checkAlive();
            _checkSlashChatAdmission(owner, admission);
            _checkChatCapture(
              admission.capture,
              expectedRevision: exactRevision ? admission.capture.revision : null,
              requireSamePath: true,
            );
            check?.call();
            started = true;
            owner.recordEffect(
              kind: TavernSlashEffectKind.storage,
              stage: TavernSlashEffectStage.handler,
              state: TavernSlashEffectState.started,
              operation: operation,
              target: target,
              details: const {'carrier': 'sql'},
            );
            return _toolPreparationSql(
              engine,
              permit,
              () {
                plan = _ScriptMessagePlan(this, admission.capture, operation, const TavernScriptWriteOptions());
                prepare(plan);
                mutation = plan.commit();
                // Projection is prepared in the same SQL transaction. A projection
                // failure rolls back; the COMMIT callback does no SQL or host work.
                return project(plan, mutation);
              },
              onCommitted: () {
                sqlCommitted = true;
                plan.adoptCommitted();
                if (plan.changed) {
                  scope.adopted();
                  owner.recordEffect(
                    kind: TavernSlashEffectKind.storage,
                    stage: TavernSlashEffectStage.handler,
                    state: TavernSlashEffectState.adopted,
                    operation: operation,
                    target: target,
                    version: mutation.pathRevision,
                    committed: true,
                    details: const {'carrier': 'sql'},
                  );
                }
              },
            );
          }

          return structural
              ? _structureWrite(admission.capture, () => action(null))
              : _dataWrite(admission.capture, action);
        }),
      );
      scope.checkAlive();
      await _publishMutation(
        admission.capture.context,
        mutation,
        events: [...plan.lifecycle(mutation), ...?additionalEvents?.call(result)],
        effectScope: scope,
      );
      scope.checkAlive();
      return result;
    } catch (error, stack) {
      scope.observe(error);
      final failure = _scriptFailure(error);
      if (started && !sqlCommitted) {
        owner.recordEffect(
          kind: TavernSlashEffectKind.storage,
          stage: TavernSlashEffectStage.handler,
          state: TavernSlashEffectState.failed,
          operation: operation,
          target: target,
          details: {'carrier': 'sql', 'code': failure.code.name},
        );
      }
      Error.throwWithStackTrace(_scriptEffectException(scope, failure), stack);
    } finally {
      scope.finish();
    }
  }

  Future<_SlashMessageReceipt> _createSlashMessage(
    _SlashExecutionOwner owner,
    _SlashChatAdmission admission, {
    required int insertion,
    required TavernRole role,
    required String name,
    required String text,
    bool hidden = false,
    String? speakerCharacterId,
    Map<String, _ScriptSpeakerCapture> speakers = const {},
    Map<String, Object?> extra = const {},
    String? lifecycleName,
  }) async {
    _checkSlashChatAdmission(owner, admission);
    if (insertion < 0 || insertion > admission.capture.path.length) {
      throw _scriptError(
        TavernScriptErrorCode.range,
        'createSlashMessage',
        'The insertion slot is outside the admitted path.',
        contextId: owner.context.value.id,
      );
    }
    final capturedExtra = _captureScriptObject(extra);
    _checkUserExtra(owner.context.value.id, 'createSlashMessage', capturedExtra, '/extra');
    final capturedParent = insertion == 0 ? null : admission.capture.path[insertion - 1].message.nodeId;
    final forceGameplay = engine
        ._stateAt(admission.capture.chatId, capturedParent)
        .containsKey('dshgoPackDefinitionConfigId');
    final data = await owner.storage(
      _bridgeOperation(() => _prepareDataContext(admission.capture.chatId, forceGameplay: forceGameplay)),
    );
    final id = engine._store.newNodeId();
    final ref = _scriptRef(admission.capture.chatId, id);
    return _runSlashMessagePlan(
      owner,
      admission,
      operation: 'createSlashMessage',
      structural: true,
      exactRevision: false,
      target: _slashMessageTarget(admission.capture.chatId, [ref]),
      check: () {
        _checkDataContext(data);
        _checkMessageSpeakers(admission.capture, speakers, 'createSlashMessage');
      },
      prepare: (plan) {
        final oldPath = List<String>.of(plan.path);
        final before = insertion < oldPath.length ? oldPath[insertion] : null;
        final oldFamily = before == null ? <String>[] : plan.children(plan.links[before]!.parentId, physical: true);
        final parent = insertion == 0 ? null : oldPath[insertion - 1];
        final initial = parent == null ? _initialMessageState(data) : null;
        final baseline = initial?.state ?? _copy(plan.page(parent!).state);
        if (initial != null && initial.adoptedGameplay != null) {
          plan.initialized[id] = initial;
        }
        plan.add(
          _ScriptWorkingPage(
            id: id,
            created: true,
            role: role,
            name: name,
            text: text,
            hidden: hidden,
            speakerCharacterId: speakerCharacterId,
            state: _copy(baseline),
            extra: _copy(capturedExtra),
            original: <String, Object?>{},
          ),
          parent,
        );
        for (final sibling in oldFamily) {
          plan.reparent(sibling, id);
        }
        plan.path = [...oldPath.take(insertion), id, ...oldPath.skip(insertion)];
        if (lifecycleName != null) {
          final chat = engine._store.chat(plan.chatId);
          final selected = _slashMetadataSource(chat);
          final metadata = engine._chatCodec.updateMetadataSource(
            chat.metadata,
            sourceFile: selected.target.sourceFile,
            target: selected.target,
            update: (current) => {...current, 'tainted': true},
          );
          engine._store.updateChat(plan.chatId, metadata: metadata);
        }
      },
      project: (plan, mutation) {
        final saved = engine._store.node(plan.chatId, id);
        return _SlashMessageReceipt(
          mutation: mutation,
          ref: ref,
          messageId: plan.path.indexOf(id),
          text: saved.message.text,
          object: engine._chatCodec.projectMessage(engine._store, plan.chatId, id),
        );
      },
      additionalEvents: lifecycleName == null
          ? null
          : (receipt) => [
              _ScriptLifecycle(
                name: lifecycleName,
                nodeRef: receipt.ref,
                location: (messageId: receipt.messageId, swipeId: 0, pathRevision: receipt.mutation.pathRevision),
                args: [receipt.messageId, if (lifecycleName == 'MESSAGE_RECEIVED') 'command'],
              ),
            ],
    );
  }

  Future<TavernScriptMutation> _setSlashHidden(
    _SlashExecutionOwner owner,
    _SlashChatAdmission admission,
    List<TavernScriptMessageRef> refs,
    bool hidden,
  ) {
    _checkSlashChatAdmission(owner, admission);
    _checkSlashMessageRefs(admission, refs, 'setSlashHidden');
    final selected = List<TavernScriptMessageRef>.of(refs);
    return _runSlashMessagePlan(
      owner,
      admission,
      operation: 'setSlashHidden',
      structural: false,
      exactRevision: true,
      target: _slashMessageTarget(admission.capture.chatId, selected),
      prepare: (plan) {
        for (final ref in selected) {
          final family = plan.children(plan.links[ref.nodeId]!.parentId);
          plan.applyPatch(
            _CapturedMessagePatch(
              nodeId: ref.nodeId,
              fields: {'hidden': hidden},
              familyIds: family,
              newIds: const [],
              selectedIndex: family.indexOf(ref.nodeId),
              needsCurrentPath: true,
              structural: false,
            ),
            null,
          );
        }
      },
      project: (_, mutation) => mutation,
    );
  }

  Future<TavernScriptMutation> _deleteSlashMessages(
    _SlashExecutionOwner owner,
    _SlashChatAdmission admission,
    List<TavernScriptMessageRef> refs,
  ) {
    _checkSlashChatAdmission(owner, admission);
    _checkSlashMessageRefs(admission, refs, 'deleteSlashMessages');
    final selected = List<TavernScriptMessageRef>.of(refs);
    return _runSlashMessagePlan(
      owner,
      admission,
      operation: 'deleteSlashMessages',
      structural: selected.isNotEmpty,
      exactRevision: true,
      target: _slashMessageTarget(admission.capture.chatId, selected),
      prepare: (plan) => plan.deleteFamilies({for (final ref in selected) ref.nodeId}),
      project: (_, mutation) => mutation,
    );
  }

  Future<T> _mutateSlashMetadata<T>(
    _SlashExecutionOwner owner,
    _SlashChatAdmission admission, {
    required String operation,
    required TavernJsonObject target,
    Map<String, String> expectedVersions = const {},
    required ({
      bool changed,
      T value,
      Map<String, Object?> metadata,
      Map<String, Object?>? settings,
      Set<String> injectionIds,
    })
    Function(Map<String, Object?> metadata, Map<String, Object?> settings)
    transform,
  }) async {
    final scope = _ScriptEffectScope.slash(this, owner);
    final capturedTarget = _captureScriptObject(target);
    final versions = Map<String, String>.of(expectedVersions);
    final chatId = admission.capture.chatId;
    var started = false;
    var adopted = false;
    try {
      final value = await scope.drain(
        _bridgeOperation(
          () => _scriptEffectChatWrite(chatId, (permit) {
            scope.checkAlive();
            _checkSlashChatAdmission(owner, admission);
            for (final entry in versions.entries) {
              if (!const {
                'metadata:world_info',
                'settings:stLorebookIds',
                'settings:lorebooks.chat',
              }.contains(entry.key)) {
                throw _scriptError(
                  TavernScriptErrorCode.invalidArgument,
                  operation,
                  'An unsupported metadata target version was supplied.',
                  contextId: owner.context.value.id,
                );
              }
              if (_generationFieldVersion(chatId, entry.key) != entry.value) {
                throw _scriptError(
                  TavernScriptErrorCode.revisionConflict,
                  operation,
                  'A binding target changed after admission.',
                  contextId: owner.context.value.id,
                );
              }
            }
            final chat = engine._store.chat(chatId);
            final selected = _slashMetadataSource(chat);
            final next = transform(_copy(selected.metadata), _copy(chat.settings));
            if (!next.changed) {
              return next.value;
            }
            final metadata = _captureScriptObject(next.metadata);
            final settings = next.settings == null ? null : _captureScriptObject(next.settings!);
            final ids = Set<String>.of(next.injectionIds);
            final root = engine._chatCodec.updateMetadataSource(
              chat.metadata,
              sourceFile: selected.target.sourceFile,
              target: selected.target,
              update: (_) => metadata,
            );
            final adoptedInjections = <String, ({String fingerprint, bool present})>{};
            scope.checkAlive();
            started = true;
            owner.recordEffect(
              kind: TavernSlashEffectKind.storage,
              stage: TavernSlashEffectStage.handler,
              state: TavernSlashEffectState.started,
              operation: operation,
              target: capturedTarget,
              details: const {'carrier': 'sql'},
            );
            return _toolPreparationSql(
              engine,
              permit,
              () {
                engine._store.updateChat(chatId, metadata: root, settings: settings);
                final raw = metadata['script_injects'];
                for (final id in ids) {
                  adoptedInjections[id] = (
                    fingerprint: _persistentInjectionFingerprint(chatId, selected.target, id),
                    present: raw is Map<String, Object?> && raw.containsKey(id),
                  );
                }
                return next.value;
              },
              onCommitted: () {
                adopted = true;
                scope.adopted();
                owner.recordEffect(
                  kind: TavernSlashEffectKind.storage,
                  stage: TavernSlashEffectStage.handler,
                  state: TavernSlashEffectState.adopted,
                  operation: operation,
                  target: capturedTarget,
                  committed: true,
                  details: const {'carrier': 'sql'},
                );
                final observation = _generationChatObservations.putIfAbsent(
                  chatId,
                  () => _ScriptChatObservation(++_nextGenerationObservation),
                );
                for (final entry in adoptedInjections.entries) {
                  final key = _persistentInjectionKey(selected.target, entry.key);
                  final observed = observation.persistent.putIfAbsent(
                    key,
                    () => _ScriptPersistentObservation(
                      identity: ++observation.nextPersistentIdentity,
                      source: selected.target,
                      rawId: entry.key,
                      fingerprint: entry.value.fingerprint,
                    ),
                  );
                  // A real same-payload replacement is a new incarnation of this
                  // exact selected source. Prepare its value in SQL; adopt once
                  // before the ordinary observer without touching another header.
                  observed.value.fingerprint = entry.value.fingerprint;
                  observed.value.revision++;
                  final version = _persistentInjectionToken(observation, observed);
                  owner.recordEffect(
                    kind: TavernSlashEffectKind.injection,
                    stage: TavernSlashEffectStage.handler,
                    state: TavernSlashEffectState.adopted,
                    operation: operation,
                    target: {
                      'sourceRef': {'kind': 'persistent', 'chatId': chatId, 'rawId': entry.key},
                    },
                    version: version,
                    committed: true,
                    details: {'removed': !entry.value.present},
                  );
                }
              },
            );
          }, metadataOnly: true),
        ),
      );
      scope.checkAlive();
      if (adopted) {
        await _confirmScriptEffectCaches(scope);
      }
      scope.checkAlive();
      return value;
    } catch (error, stack) {
      scope.observe(error);
      final failure = _scriptFailure(error);
      if (started && !adopted) {
        owner.recordEffect(
          kind: TavernSlashEffectKind.storage,
          stage: TavernSlashEffectStage.handler,
          state: TavernSlashEffectState.failed,
          operation: operation,
          target: capturedTarget,
          details: {'carrier': 'sql', 'code': failure.code.name},
        );
      }
      Error.throwWithStackTrace(_scriptEffectException(scope, failure), stack);
    } finally {
      scope.finish();
    }
  }
}
