import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

export 'p2_script_generation_test_support.dart';

// This is a newly authored replacement, not recovered pre-outage source.
// It uses the unchanged real B1/B2 storage and production HTTP fixture.
Future<ScriptFixture> slashFixture({bool allowModel = false}) async {
  final fixture = await ScriptFixture.open(allowModel: allowModel, cleanupMarker: 'P2_B3_CLEANUP');
  // Registered after the fixture's real disposal and therefore run first.
  // A held beforeResponse or host callback remains owned by its individual
  // test; that test must register its own completer release after this helper.
  addTearDown(() async {
    for (final plan in fixture.plans) {
      await plan.dispose();
    }
  });
  return fixture;
}

Future<TavernSlashResult> slashRun(
  ScriptFixture fixture,
  String contextId,
  String source, {
  String? executionId,
  String pipe = '',
  Map<String, String> arguments = const {},
}) async {
  final execution = await fixture.bridge.triggerSlash(
    contextId,
    source,
    executionId: executionId,
    pipe: pipe,
    arguments: arguments,
  );
  return execution.result;
}

Future<TavernScriptException> slashFailure(TavernSlashExecution execution) async {
  try {
    await execution.result;
  } on TavernScriptException catch (error) {
    return error;
  }
  throw TestFailure('Expected a structured Slash failure.');
}

Future<T> slashSignal<T>(TavernSlashExecution execution, Future<T> signal) => Future.any([
  signal,
  execution.result.then<T>((_) => throw TestFailure('Slash completed before the expected fixture boundary.')),
]);

// Callback delivery is recorded before invoking any test handler, so a
// synchronous attachHost/close/stop inside a handler sees its true request.
class SlashHost extends GenerationHost {
  final interactions = <TavernScriptUiRequest>[];
  final resolutions = <TavernSlashReference>[];
  Future<TavernScriptUiResult> Function(TavernScriptUiRequest, TavernScriptCancellation)? onInteract;
  Future<TavernResolvedSlash?> Function(TavernSlashReference, TavernScriptCancellation)? onResolve;

  @override
  Future<TavernScriptUiResult> interact(TavernScriptUiRequest request, TavernScriptCancellation cancellation) async {
    interactions.add(request);
    final handler = onInteract;
    if (handler == null) {
      throw StateError('No Slash UI response was supplied by this fixture.');
    }
    return handler(request, cancellation);
  }

  @override
  Future<TavernResolvedSlash?> resolveSlash(TavernSlashReference request, TavernScriptCancellation cancellation) async {
    resolutions.add(request);
    final handler = onResolve;
    if (handler == null) {
      throw StateError('No Slash resolution was supplied by this fixture.');
    }
    return handler(request, cancellation);
  }
}

// The optional lock interface is deliberately absent from SlashHost.
class SlashLockHost extends SlashHost implements TavernScriptGenerationLockHost {
  final acquisitions = <TavernScriptGenerationLockAcquireRequest>[];
  final releases = <TavernScriptGenerationLockReleaseRequest>[];
  final lifetimes = <TavernScriptCancellation>[];
  final releaseTokens = <TavernScriptCancellation>[];
  Future<TavernScriptGenerationLockAck> Function(TavernScriptGenerationLockAcquireRequest, TavernScriptCancellation)?
  onAcquire;
  Future<TavernScriptGenerationLockAck> Function(TavernScriptGenerationLockReleaseRequest, TavernScriptCancellation)?
  onRelease;

  @override
  Future<TavernScriptGenerationLockAck> acquireGenerationLock(
    TavernScriptGenerationLockAcquireRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    acquisitions.add(request);
    lifetimes.add(cancellation);
    final handler = onAcquire;
    if (handler == null) {
      throw StateError('No generation-lock acquire response was supplied by this fixture.');
    }
    return handler(request, cancellation);
  }

  @override
  Future<TavernScriptGenerationLockAck> releaseGenerationLock(
    TavernScriptGenerationLockReleaseRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    releases.add(request);
    releaseTokens.add(cancellation);
    final handler = onRelease;
    if (handler == null) {
      throw StateError('No generation-lock release response was supplied by this fixture.');
    }
    return handler(request, cancellation);
  }
}
