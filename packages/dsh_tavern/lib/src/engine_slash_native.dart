// /trigger adapts SillyTavern slash-commands.js:4987–5020 at
// 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0). The accepted native
// round belongs to its chat; this observer never owns its cancellation.
part of 'engine.dart';

extension _SlashNativeTurnOperations on _ScriptCoordinator {
  Future<String?> _slashTriggerMember(
    _SlashInvocation invocation,
    _SlashChatAdmission admission,
    TavernGroupChat group,
    String text,
  ) async {
    if (text.isEmpty) return null;
    if (RegExp(r'^[0-9]+$').hasMatch(text)) {
      final index = BigInt.parse(text);
      if (index >= BigInt.from(group.members.length)) {
        throw _slashArgument(
          invocation,
          'unnamed',
          'The group member index is out of range.',
          code: TavernScriptErrorCode.range,
        );
      }
      return group.members[index.toInt()].characterId;
    }
    final owner = invocation.owner;
    final chat = engine._store.chat(group.chatId);
    final settings = _runtimeCopy(engine._effectiveSettings(chat, admission.metadata));
    final members = {for (final member in group.members) member.characterId};
    final currentActor = owner.context.value.characterId;
    final lookup = _bridgeOperation(
      () => engine._libraryOperation(() async {
        final cards = await engine._characterSummaries();
        owner.checkAlive();
        final matches = <String>{};
        if (members.contains(text)) matches.add(text);
        for (final card in cards) {
          if (!members.contains(card.id)) continue;
          final identity = _map(_map(settings['characterIdentities'])[card.id]);
          if (card.id == currentActor) identity.addAll(_map(settings['characterIdentity']));
          if (card.name == text || identity['avatarFilename'] == text) matches.add(card.id);
        }
        if (matches.isEmpty) {
          throw _slashArgument(
            invocation,
            'unnamed',
            'No group member has this identity or name.',
            code: TavernScriptErrorCode.notFound,
          );
        }
        if (matches.length != 1) {
          throw _slashArgument(
            invocation,
            'unnamed',
            'The group member name is ambiguous.',
            code: TavernScriptErrorCode.ambiguousName,
          );
        }
        return matches.single;
      }),
    );
    return owner.wait(lookup, TavernSlashWaitKind.storage);
  }

  Future<String> _executeSlashTrigger(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    final waitForTurn = _slashTrue(invocation, 'await');
    final selector = trimJsWhitespace(_slashBody(invocation));
    final admission = await _captureSlashChat(owner);
    owner.checkAlive();
    final chatId = admission.capture.chatId;
    final group = engine._store.groupChat(chatId);
    if (group == null && selector.isNotEmpty) {
      throw _slashArgument(
        invocation,
        'unnamed',
        'A single chat does not accept a trigger actor selector.',
        code: TavernScriptErrorCode.unsupportedOption,
      );
    }
    final actor = group == null ? null : await _slashTriggerMember(invocation, admission, group, selector);
    owner.checkAlive();
    _checkSlashChatAdmission(owner, admission);
    final target = <String, Object?>{'chatId': chatId, 'mode': group == null ? 'single' : 'group'};
    final accepted = Completer<void>();
    _observeSlashWaitError(accepted.future);
    // A terminal error is data in this private observer. The caller may only
    // await admission, so an unobserved failed Future must not be created.
    final ended = Completer<TavernScriptException?>();
    var observing = true;
    var didAccept = false;
    var finished = false;
    var storedReply = false;
    TavernScriptException? memberFailure;
    final replies = <TavernScriptMessageRef>[];

    void accept() {
      didAccept = true;
      owner.recordEffect(
        kind: TavernSlashEffectKind.nativeTurn,
        state: TavernSlashEffectState.accepted,
        stage: TavernSlashEffectStage.handler,
        operation: 'trigger',
        target: target,
      );
      if (!accepted.isCompleted) accepted.complete();
    }

    TavernScriptException failure(
      TavernFailure kind,
      String? detail, {
      TavernMessage? partial,
      List<TavernScriptIssue> issues = const [],
    }) {
      return TavernScriptException(
        code: kind == TavernFailure.busy
            ? TavernScriptErrorCode.busy
            : kind == TavernFailure.cancelled
            ? TavernScriptErrorCode.cancelled
            : TavernScriptErrorCode.model,
        operation: 'trigger',
        message: detail ?? 'The native turn did not complete.',
        contextId: owner.context.value.id,
        executionId: owner.id,
        sourceSpan: invocation.sourceSpan,
        nodeId: partial?.nodeId,
        modelFailure: kind,
        committed: partial != null || issues.any((issue) => issue.committed),
        issues: issues,
      );
    }

    void noteReply(TavernMessage message) {
      storedReply = true;
      final ref = TavernScriptMessageRef(chatId: chatId, nodeId: message.nodeId);
      if (!replies.any((item) => item.nodeId == ref.nodeId)) replies.add(ref);
    }

    void finish(TavernScriptException? error) {
      if (!observing || finished) return;
      finished = true;
      if (error != null) owner.observeIssues(error.issues, committed: error.committed);
      owner.recordEffect(
        kind: TavernSlashEffectKind.nativeTurn,
        state: error == null
            ? TavernSlashEffectState.completed
            : error.code == TavernScriptErrorCode.cancelled
            ? TavernSlashEffectState.cancelled
            : TavernSlashEffectState.failed,
        stage: TavernSlashEffectStage.handler,
        operation: 'trigger',
        target: target,
        committed: storedReply || error?.committed == true,
        details: {
          if (replies.isNotEmpty)
            'refs': [
              for (final ref in replies) {'chatId': ref.chatId, 'nodeId': ref.nodeId},
            ],
          if (error?.modelFailure case final kind?) 'modelFailure': kind.name,
        },
      );
      if (!didAccept && !accepted.isCompleted) {
        accepted.completeError(error ?? failure(TavernFailure.server, 'native_admission_missing'));
      }
      ended.complete(error);
    }

    void observeTurn(TavernEvent event, {required bool terminal}) {
      if (!observing) return;
      if (event is TavernTurnDone) {
        owner.observeIssues(event.hookIssues);
        noteReply(event.message);
        if (terminal) finish(null);
      } else if (event is TavernTurnFailed) {
        owner.observeIssues(event.hookIssues);
        if (event.partial case final partial?) noteReply(partial);
        final error = failure(event.kind, event.detail, partial: event.partial, issues: event.hookIssues);
        if (terminal) {
          finish(error);
        } else {
          memberFailure = error;
        }
      }
    }

    void onError(Object error, StackTrace stack) {
      if (!observing) return;
      finish(_scriptFailure(error));
    }

    void onDone() {
      if (observing && !finished) finish(failure(TavernFailure.server, 'native_terminal_missing'));
    }

    // listen() is the real admission boundary for these cold streams. No
    // await or second identity lookup occurs between the last check and it.
    owner.checkAlive();
    final StreamSubscription<Object?> subscription;
    if (group == null) {
      subscription = engine
          ._streamTurn(
            chatId,
            _TurnKind.send,
            input: '',
            onAdmitted: (_) {
              accept();
            },
          )
          .listen(
            (event) {
              observeTurn(event, terminal: true);
            },
            onError: onError,
            onDone: onDone,
          );
    } else {
      subscription = engine._groups
          .send(
            chatId,
            '',
            speakerCharacterId: actor,
            onAdmitted: (_) {
              accept();
            },
          )
          .listen(
            (event) {
              if (!observing) return;
              if (event is TavernGroupMemberEvent) {
                observeTurn(event.event, terminal: false);
              } else if (event is TavernGroupFinished) {
                if (event.partial case final partial?) noteReply(partial);
                switch (event.reason) {
                  case TavernGroupEndReason.completed:
                  case TavernGroupEndReason.noSpeakers:
                    finish(null);
                  case TavernGroupEndReason.cancelled:
                    finish(memberFailure ?? failure(TavernFailure.cancelled, event.detail, partial: event.partial));
                  case TavernGroupEndReason.failed:
                    finish(
                      memberFailure ??
                          failure(
                            event.failure ?? TavernFailure.server,
                            event.detail ?? event.code,
                            partial: event.partial,
                          ),
                    );
                }
              }
            },
            onError: onError,
            onDone: onDone,
          );
    }
    try {
      await owner.wait(accepted.future, TavernSlashWaitKind.nativeTurn);
      if (waitForTurn) {
        final error = await owner.wait(ended.future, TavernSlashWaitKind.nativeTurn);
        if (error != null) throw error;
      }
      owner.checkAlive();
      return '';
    } finally {
      observing = false;
      // Existing onCancel removes only this observer. Never call engine.stop,
      // round.cancel, or add this native turn to owner.children.
      await subscription.cancel();
    }
  }
}
