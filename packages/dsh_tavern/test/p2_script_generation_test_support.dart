import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

export 'p2_script_test_support.dart';

// The same real directory/card/settings/SQLite/production HTTP fixture. A
// distinct marker identifies only B2 fixtures whose actual cleanup completed.
Future<ScriptFixture> generationFixture({bool allowModel = true}) async {
  final fixture = await ScriptFixture.open(allowModel: allowModel, cleanupMarker: 'P2_B2_CLEANUP');
  // Registered after ScriptFixture.dispose, so this runs first even when an
  // assertion fails. The synthetic peer cannot abort an idle SSE source.
  // Release the test-owned source before engine.close awaits the true drain.
  addTearDown(() async {
    for (final plan in fixture.plans) {
      await plan.dispose();
    }
  });
  return fixture;
}

class GenerationHost extends ScriptHost {
  final invocations = <TavernScriptCallbackRequest>[];
  Future<TavernScriptCallbackResult> Function(TavernScriptCallbackRequest, TavernScriptCancellation)? onInvoke;

  @override
  Future<TavernScriptCallbackResult> invoke(
    TavernScriptCallbackRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    invocations.add(request);
    final handler = onInvoke;
    if (handler == null) {
      throw StateError('No B2 callback response was supplied by this fixture.');
    }
    return handler(request, cancellation);
  }
}

ScriptResponsePlan generationJsonResponse(ScriptFixture h, ScriptJson body, {int status = 200}) {
  final plan = ScriptResponsePlan.json(body, status: status);
  h.pending.add(plan);
  h.plans.add(plan);
  return plan;
}

// Feed actual encoded SSE bytes into the production decoder. The caller must
// wait for plan.listening before emitting. This is an HTTP boundary, not a
// fake ModelDelta stream or a claim about socket-level abort behavior.
void generationSse(ScriptResponsePlan plan, ScriptJson payload, {int? splitAt}) {
  final bytes = utf8.encode('data: ${jsonEncode(payload)}\n\n');
  final source = plan.source!;
  if (splitAt == null) {
    source.add(bytes);
    return;
  }
  if (splitAt <= 0 || splitAt >= bytes.length) {
    throw ArgumentError.value(splitAt, 'splitAt', 'Must split inside the encoded frame.');
  }
  source.add(bytes.sublist(0, splitAt));
  source.add(bytes.sublist(splitAt));
}

Future<ScriptRequest> generationRequest(TavernScriptGeneration generation, ScriptResponsePlan plan) => Future.any([
  plan.seen.future,
  generation.result.then<ScriptRequest>(
    (_) => throw TestFailure('Generation completed before its expected HTTP request.'),
  ),
]);

Future<TavernScriptException> generationFailure(TavernScriptGeneration generation) async {
  try {
    await generation.result;
  } on TavernScriptException catch (error) {
    return error;
  }
  throw TestFailure('Expected a structured generation failure.');
}

Future<T> generationSignal<T>(TavernScriptGeneration generation, Future<T> signal) => Future.any([
  signal,
  generation.result.then<T>((_) => throw TestFailure('Generation completed before the expected fixture boundary.')),
]);

List<ScriptJson> generationNodes(ScriptFixture h, String chatId) => h.inspect(
  (db) => [
    for (final row in db.select('SELECT * FROM nodes WHERE chat_id = ? ORDER BY id', [chatId]))
      Map<String, Object?>.from(row),
  ],
);

List<ScriptJson> generationMessages(ScriptRequest request) =>
    (request.body['messages']! as List<Object?>).map(scriptMap).toList();
