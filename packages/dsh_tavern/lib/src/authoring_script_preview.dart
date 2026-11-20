import 'authoring.dart';
import 'authoring_preview.dart';
import 'authoring_render.dart' show TavernAuthoringCaptureReader, TavernAuthoringCapturedResource;
import 'scripts.dart';

enum TavernAuthoringCallbackStatus { completed, unsupported, cancelled, failed }

enum TavernAuthoringRuntimeOperation {
  getVariables,
  replaceVariables,
  mutateVariables,
  injectPrompts,
  uninjectPrompts,
  releaseInjectionLease,
  listInjections,
}

/// A copied handler inventory, including an explicit empty inventory. Its
/// version covers both handlers and the lexical environment copied by App.
final class TavernAuthoringLifecycleSource {
  TavernAuthoringLifecycleSource({
    required this.contextId,
    required this.instanceId,
    required this.manifestVersion,
    required Set<String> handlers,
  }) : handlers = Set.unmodifiable(handlers);
  final String contextId, instanceId, manifestVersion;
  final Set<String> handlers;
}

final class TavernAuthoringFilterSource {
  const TavernAuthoringFilterSource({required this.ref, required this.sourceVersion});
  final TavernScriptCallbackRef ref;
  final String sourceVersion;
}

/// Capabilities of this newly opened prompt domain, not the live script host.
/// An absent operation must fail before execution. The source versions also
/// cover captured mutable environments; callback IDs alone are insufficient.
final class TavernAuthoringScriptBinding {
  TavernAuthoringScriptBinding({
    required this.hostEpoch,
    required List<TavernAuthoringLifecycleSource> lifecycleSources,
    required List<TavernAuthoringFilterSource> filterSources,
    required Set<TavernAuthoringRuntimeOperation> runtimeOperations,
  }) : lifecycleSources = List.unmodifiable(lifecycleSources),
       filterSources = List.unmodifiable(filterSources),
       runtimeOperations = Set.unmodifiable(runtimeOperations);
  final String hostEpoch;
  final List<TavernAuthoringLifecycleSource> lifecycleSources;
  final List<TavernAuthoringFilterSource> filterSources;
  final Set<TavernAuthoringRuntimeOperation> runtimeOperations;
}

/// App receives a detached view. Mutating this JSON does not perform a local
/// operation: handlers use their invocation's runtime for observable writes.
final class TavernAuthoringPromptHostCapture {
  TavernAuthoringPromptHostCapture({
    required this.request,
    required this.captureId,
    required List<TavernScriptContext> contexts,
    required this.workspace,
    required Map<String, TavernAuthoringCapturedResource> resources,
    required this.reader,
  }) : contexts = List.unmodifiable(contexts),
       resources = Map.unmodifiable(resources);
  final TavernAuthoringPromptRequest request;
  final String captureId;
  final List<TavernScriptContext> contexts;
  final Map<String, Object?> workspace;
  final Map<String, TavernAuthoringCapturedResource> resources;
  final TavernAuthoringCaptureReader reader;
}

/// These methods operate only on this preview's detached carriers. The
/// runtime is bound to one context and invocation; after its callback ends,
/// new calls fail while already accepted calls are drained by the owner.
/// Only global/chat/message variables in the captured chat are supported.
abstract interface class TavernAuthoringPromptRuntime {
  Future<TavernVariableSnapshot> getVariables(TavernVariableTarget target);
  Future<TavernVariableSnapshot> replaceVariables(
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  });
  Future<TavernVariableMutation> mutateVariables(
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  });
  Future<TavernScriptInjectionLease> injectPrompts(List<TavernScriptInjection> prompts, {bool once = false});
  Future<void> uninjectPrompts(List<String> ids);
  Future<void> releaseInjectionLease(String leaseId);
  Future<List<TavernScriptInjectionView>> listInjections();
}

final class TavernAuthoringPreparationRequest {
  const TavernAuthoringPreparationRequest({
    required this.requestId,
    required this.captureId,
    required this.invocationId,
    required this.context,
    required this.lifecycle,
    required this.runtime,
  });
  final String requestId, captureId, invocationId, lifecycle;
  final TavernScriptContext context;
  final TavernAuthoringPromptRuntime runtime;
}

final class TavernAuthoringPreparationResult {
  TavernAuthoringPreparationResult({
    required this.requestId,
    required this.captureId,
    required this.invocationId,
    required this.contextId,
    required this.instanceId,
    required this.lifecycle,
    required this.status,
    List<TavernAuthoringIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final String requestId, captureId, invocationId, contextId, instanceId, lifecycle;
  final TavernAuthoringCallbackStatus status;
  final List<TavernAuthoringIssue> issues;
}

final class TavernAuthoringFilterRequest {
  const TavernAuthoringFilterRequest({
    required this.requestId,
    required this.captureId,
    required this.invocationId,
    required this.ref,
    required this.runtime,
  });
  final String requestId, captureId, invocationId;
  final TavernScriptCallbackRef ref;
  final TavernAuthoringPromptRuntime runtime;
  String get kind => 'filter';
  List<Object?> get args => const [];
}

final class TavernAuthoringFilterResult {
  TavernAuthoringFilterResult({
    required this.requestId,
    required this.captureId,
    required this.invocationId,
    required this.ref,
    required this.status,
    this.value,
    List<TavernAuthoringIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final String requestId, captureId, invocationId;
  final TavernScriptCallbackRef ref;
  final TavernAuthoringCallbackStatus status;
  final bool? value;
  final List<TavernAuthoringIssue> issues;
}

/// An actual independent App execution domain is required. The App must map
/// its supported SDK to the invocation's local runtime and capture reader;
/// it must not forward calls to the live bridge, network or parent closures.
/// Opening copies sources but never executes preparation or filter handlers.
abstract interface class TavernAuthoringPromptHost {
  Future<TavernAuthoringPromptSession> openPromptPreview(
    TavernAuthoringPromptHostCapture capture,
    TavernScriptCancellation cancellation,
  );
}

abstract interface class TavernAuthoringPromptSession {
  TavernAuthoringScriptBinding get binding;

  /// Synchronous source invalidation until the capture seals. Changes inside
  /// the copied domain do not invalidate its original source evidence.
  TavernScriptCancellation get sourceInvalidated;
  Future<TavernAuthoringPreparationResult> prepare(TavernAuthoringPreparationRequest request);
  Future<TavernAuthoringFilterResult> filter(TavernAuthoringFilterRequest request);

  /// Idempotent. Success proves all domain callbacks have ended. A failed
  /// open must clean up its unreturned domain; close failure is not drain.
  Future<void> close();
}
