part of 'engine.dart';

class _SlashInvocation {
  const _SlashInvocation(this.owner, this.language);
  final _SlashExecutionOwner owner;
  final SlashInvocation language;
  String get command => language.command;
  String get spelling => language.spelling;
  Map<String, Object?> get named => language.named;
  Object? get unnamed => language.unnamed;
  List<Object?> get unnamedParts => language.unnamedParts;
  SlashFrame get frame => language.frame;
  TavernScriptSourceSpan get sourceSpan => language.sourceSpan;
  Object? get incomingPipe => language.incomingPipe;
  bool get hasParsedUnnamed => language.hasParsedUnnamed;
  bool get hasUnnamed => language.hasUnnamed;
  bool has(String name) => language.has(name);
  Object? argument(String name) => language.argument(name);
}

/// The concrete record, rather than its reusable string id, owns cancellation,
/// child generations and all facts admitted before its first terminal result.
class _SlashExecutionOwner {
  _SlashExecutionOwner(this.coordinator, this.context, this.id);
  final _ScriptCoordinator coordinator;
  final _ScriptContextState context;
  final String id;
  final token = _ScriptCancellation();
  final children = <_ScriptGenerationRecord>{};
  final issues = <TavernScriptIssue>[];
  final issueObservations = HashMap<Object, List<TavernScriptIssue>>.identity();
  final effects = <TavernSlashEffect>[];
  late _SlashExecutionRecord record;
  TavernScriptException? cancellationFailure;
  TavernSlashEffectStage stage = TavernSlashEffectStage.defaults;
  SlashInvocation? current;
  TavernScriptSourceSpan? currentSpan;
  bool knownCommitted = false;
  bool get terminal => record.terminal != null;
  bool get committed =>
      knownCommitted || effects.any((effect) => effect.committed) || issues.any((issue) => issue.committed);
  TavernSlashEffects get summary => TavernSlashEffects(committed: committed, entries: effects);
  TavernScriptGenerationResult? get partialGeneration => record.partialGeneration;
  set partialGeneration(TavernScriptGenerationResult? result) {
    if (!terminal) record.partialGeneration = result;
  }

  void checkAlive() {
    if (cancellationFailure case final failure?) throw failure;
    if (token.isCancelled || context.closed || coordinator._closed) {
      throw _scriptError(
        TavernScriptErrorCode.cancelled,
        'triggerSlash',
        'Script execution cancelled.',
        contextId: context.value.id,
        committed: committed,
      );
    }
  }

  void cancel([String reason = 'cancelled', TavernScriptException? failure]) {
    if (terminal) return;
    if (!token.isCancelled) {
      cancellationFailure ??= failure;
      token.cancel(reason);
    }
    for (final child in children.toList()) {
      if (child.terminal == null) child.cancellation.cancel();
    }
  }

  void observeIssues(Iterable<TavernScriptIssue> values, {bool committed = false, Object? observationKey}) {
    if (terminal) return;
    knownCommitted = knownCommitted || committed;
    _appendScriptIssueObservation(issues, issueObservations, values, observationKey: observationKey);
  }

  TavernSlashEffect? recordEffect({
    required TavernSlashEffectKind kind,
    required TavernSlashEffectState state,
    required String operation,
    required TavernJsonObject target,
    bool committed = false,
    TavernSlashEffectStage? stage,
    String? version,
    TavernJsonObject details = const {},
    TavernScriptSourceSpan? sourceSpan,
  }) {
    if (terminal) return null;
    final invocation = current;
    final effect = TavernSlashEffect(
      index: effects.length,
      kind: kind,
      stage: stage ?? this.stage,
      state: state,
      operation: operation,
      target: target,
      committed: committed,
      commandIndex: invocation?.commandIndex,
      command: invocation?.spelling,
      sourceSpan: sourceSpan ?? currentSpan ?? invocation?.sourceSpan,
      version: version,
      details: details,
    );
    effects.add(effect);
    knownCommitted = knownCommitted || committed;
    return effect;
  }

  Future<T> wait<T>(Future<T> future, TavernSlashWaitKind kind) async {
    checkAlive();
    record.waiting(kind);
    try {
      final result = await Future.any<T>([
        future,
        token.whenCancelled.then<T>((_) {
          checkAlive();
          throw _scriptError(TavernScriptErrorCode.cancelled, 'triggerSlash', 'Script execution cancelled.');
        }),
      ]);
      checkAlive();
      return result;
    } finally {
      if (!terminal) record.status = TavernSlashStatus.running;
    }
  }

  /// Accepted real I/O drains before cancellation is reported, so its actual
  /// adoption callback can enter the ledger. This never waits for arbitrary App work.
  Future<T> storage<T>(Future<T> future) async {
    record.waiting(TavernSlashWaitKind.storage);
    try {
      return await future;
    } finally {
      if (!terminal) record.status = TavernSlashStatus.running;
    }
  }
}

abstract class _MacroEffectCapture {
  _MacroEffectCapture({
    required this.context,
    required this.environment,
    required this.global,
    required this.local,
    required this.observation,
    required this.state,
    this.chatId,
    this.anchor,
  });
  final _ScriptContextState context;
  final _MacroEnvironment environment;
  final _ScriptRuntimeIntentMap global, local;
  final _ScriptGenerationObservation observation;
  final Map<String, Object?> state;
  final String? chatId, anchor;
  bool get hasHashUpdate;
  Set<String> get chatTargets => {if (local.hasIntents) 'local', if (hasHashUpdate) 'stChatIdHash'};
  void checkDependencies();
  String requireCharacterName();
}

class _SlashVariablePair {
  const _SlashVariablePair({this.chat, this.global});
  final Map<String, Object?>? chat, global;
}

class _SlashChatAdmission {
  _SlashChatAdmission({
    required this.capture,
    required this.selectionVersion,
    required this.metadataSourceVersion,
    required this.metadataSource,
    required Map<String, Object?> metadata,
    required Map<String, Object?> settings,
  }) : metadata = _copy(metadata),
       settings = _copy(settings);
  final _ScriptChatCapture capture;
  final String selectionVersion, metadataSourceVersion;
  final String? metadataSource;
  final Map<String, Object?> metadata, settings;
}

class _SlashMessageReceipt {
  _SlashMessageReceipt({
    required this.mutation,
    required this.ref,
    required this.messageId,
    required this.text,
    required Map<String, Object?> object,
  }) : object = _copy(object);
  final TavernScriptMutation mutation;
  final TavernScriptMessageRef ref;
  final int messageId;
  final String text;
  final Map<String, Object?> object;
}
