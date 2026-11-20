import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

List<DshEvent> parseFollow(String fixture, {String sessionId = 's'}) =>
    loadJsonl(fixture).map((v) => parseFollowFrame(sessionId, v)).toList();

void main() {
  group('follow frames: reply OK turn', () {
    final events = parseFollow('follow_reply_ok.jsonl');

    test('opens with a snapshot', () {
      final snapshot = events.first as SessionSnapshotEvent;
      expect(snapshot.cursor, 4);
      expect(snapshot.header.version, 4);
      expect(snapshot.header.agentPreset, 'standard');
      expect(snapshot.events.map((e) => e.seq), [0, 1, 2, 3, 4]);
      expect(snapshot.events.first, isA<PermissionPresetChangedEvent>());
      expect(snapshot.events[1], isA<SandboxModeChangedEvent>());
      expect((snapshot.events[2] as ApprovalPolicyChangedEvent).policy, 'ask');
      expect((snapshot.events[3] as TitleChangedEvent).sourceKind, 'user');
      expect((snapshot.events[4] as ModelSelectedEvent).selection!.reasoningEffort, 'high');
      expect(snapshot.assistantRevision, 0);
      expect(snapshot.activeAttempt, isNull);
      expect(snapshot.projections.permissionPreset, 'workspace-write');
      expect(snapshot.projections.title, 'Probe session');
    });

    test('durable events are contiguous and typed', () {
      final log = events.whereType<SessionLogEvent>().toList();
      expect(log.map((e) => e.seq), List.generate(14, (i) => i + 5));
      final users = log.whereType<UserMessageEvent>().toList();
      expect(users, hasLength(3));
      expect(users[0].isHumanPrompt, isTrue);
      expect(users[0].message.text, 'Reply with exactly the word OK and nothing else.');
      expect(users[0].requestId, startsWith('req-'));
      expect(users[1].message.source.kind, 'runtime-context');
      expect(users[2].message.source.kind, 'skill-catalog');
      expect(users.skip(1).every((u) => !u.isHumanPrompt), isTrue);

      final assistant = log.whereType<AssistantMessageEvent>().single;
      expect(assistant.message.text, 'OK');
      expect(assistant.message.source.model, 'deepseek-flash');
      expect(assistant.usage!.outputTokens, 2);
      expect(assistant.interrupted, isFalse);
      final replayed = assistant.chunks.map((c) => c.chunk).whereType<TextDeltaChunk>();
      expect(replayed.map((c) => c.text).join(), 'OK');

      final end = log.whereType<TurnEndedEvent>().single;
      expect(end.reason.isCompleted, isTrue);
      final header = log.firstWhere((e) => e.type == 'request/header');
      expect(header, isA<UnknownEvent>());
      expect((header as UnknownEvent).isKnownType, isTrue);
    });

    test('assistant stream frames: start, dense chunks, committed end', () {
      final stream = events.whereType<AssistantStreamEvent>().toList();
      final start = stream.first as AssistantStreamStarted;
      expect(start.startedAfterSeq, 14);
      expect(start.revision, 1);
      final revisions = stream.map((e) => e.revision).toList();
      expect(revisions, List.generate(revisions.length, (i) => i + 1));
      final chunks = stream.whereType<AssistantChunkEvent>().toList();
      expect(chunks.map((c) => c.index), List.generate(chunks.length, (i) => i));
      expect(chunks.map((c) => c.chunk).whereType<TextDeltaChunk>().single.text, 'OK');
      expect(chunks.map((c) => c.chunk).whereType<FinishChunk>().single.reason, 'stop');
      expect(chunks.map((c) => c.chunk).whereType<UsageChunk>().single.usage.inputTokens, greaterThan(0));
      final end = stream.last as AssistantStreamEnded;
      expect(end.committed, isTrue);
      expect(end.committedEventType, 'assistant/message');
      expect(end.committedSeq, 16);
    });

    test('follow without assistantStream carries no stream frames', () {
      final plain = parseFollow('follow_reply_ok_no_assistant_stream.jsonl');
      expect(plain.whereType<AssistantStreamEvent>(), isEmpty);
      expect((plain.first as SessionSnapshotEvent).assistantRevision, isNull);
      expect(plain.whereType<AssistantMessageEvent>(), hasLength(1));
    });
  });

  group('follow frames: approval turn with a mid-stream resync', () {
    final events = parseFollow('follow_approval_with_resync.jsonl');

    test('second snapshot carries the active attempt baseline', () {
      final snapshots = events.whereType<SessionSnapshotEvent>().toList();
      expect(snapshots, hasLength(2));
      final resync = snapshots[1];
      expect(resync.cursor, 17);
      expect(resync.assistantRevision, 76);
      final attempt = resync.activeAttempt!;
      expect(attempt.nextIndex, 75);
      expect(attempt.startedAfterSeq, 12);
      expect(attempt.chunks.first.chunk, isA<BlockStartChunk>());
      final reasoning = attempt.chunks.map((c) => c.chunk).whereType<ReasoningDeltaChunk>();
      expect(reasoning.length, 74);
      final firstAfter = events.skipWhile((e) => e != resync).skip(1).first as AssistantChunkEvent;
      expect(firstAfter.index, attempt.nextIndex);
      expect(firstAfter.revision, resync.assistantRevision! + 1);
      final titles = resync.events.whereType<TitleChangedEvent>().map((t) => t.sourceKind);
      expect(titles, ['fallback', 'provider']);
    });

    test('tool call, approval audit and tool result', () {
      final call = events.whereType<ToolCallEvent>().single;
      expect(call.name, 'bash');
      expect(call.decodedArguments!['sandbox_permissions'], 'danger-full-access');
      final asked = events.whereType<ApprovalAskedEvent>().single;
      expect(asked.callId, call.callId);
      expect(asked.toolName, 'bash');
      expect(events.whereType<ApprovalDecidedEvent>().single.outcome, ApprovalOutcome.allowedOnce);
      final result = events.whereType<ToolResultEvent>().single;
      expect(result.callId, call.callId);
      expect(result.isError, isFalse);
      expect(result.message.text, 'hi\n');
      final assistant = events.whereType<AssistantMessageEvent>().first;
      expect(assistant.message.toolCalls.single.id, call.callId);
      expect(assistant.message.reasoning, isNotEmpty);
      final toolDeltas = events
          .whereType<AssistantChunkEvent>()
          .map((e) => e.chunk)
          .whereType<ToolCallDeltaChunk>()
          .map((c) => c.argumentsDelta)
          .join();
      expect(toolDeltas, contains('"sandbox_permissions": "danger-full-access"'));
    });
  });

  test('cancelled turn: interrupted prefix and aborted reason', () {
    final events = parseFollow('follow_cancel.jsonl');
    final assistant = events.whereType<AssistantMessageEvent>().single;
    expect(assistant.interrupted, isTrue);
    expect(assistant.usage, isNull);
    expect(assistant.message.text, startsWith('one two three'));
    final end = events.whereType<TurnEndedEvent>().single;
    expect(end.reason.isAborted, isTrue);
    expect(end.reason.cancelCause, 'user');
    expect((events.whereType<AssistantStreamEnded>().single).committed, isTrue);
  });

  group('host events', () {
    test('approval waterfall, ready, session lifecycle', () {
      final events = loadJsonl('events_approval.jsonl').map(HostEvent.fromFrame).toList();
      expect(events.whereType<HostReadyEvent>(), hasLength(2));
      final added = events.whereType<SessionAddedEvent>().first.summary;
      expect(added.blank, isTrue);
      expect(added.projections.permissionPreset, 'workspace-write');
      expect(events.whereType<SessionStatusEvent>().map((e) => e.running), [true, false]);
      final request = events.whereType<ApprovalRequestedEvent>().single.request;
      expect(request.toolName, 'bash');
      expect(request.sessionId, startsWith('session-'));
      expect(request.callId, startsWith('call_'));
      expect(request.describe(), startsWith('Allow this operation'));
      expect(request.describe('zh'), startsWith('允许本次操作'));
    });

    test('credentials and settings notifications', () {
      final events = loadJsonl('events_basic.jsonl').map(HostEvent.fromFrame).toList();
      expect(events.whereType<CredentialUpdatedEvent>().first.ref, 'DSH_APP_PROBE_DUMMY');
      final settings = events.whereType<SettingsUpdatedEvent>().single;
      expect(settings.namespace, 'agent-default-model');
      expect(settings.revision, 1);
    });

    test('unknown frames and events are kept, never thrown', () {
      expect(HostEvent.fromFrame({'type': 'emit', 'event': 'schedule/changed', 'args': []}), isA<UnknownHostEvent>());
      final waterfall = HostEvent.fromFrame({
        'type': 'waterfall',
        'event': 'future/thing',
        'eventId': 'e1',
        'agentId': 'a1',
        'request': {},
      });
      expect(waterfall, isA<UnknownHostEvent>().having((e) => e.eventId, 'eventId', 'e1'));
      expect(HostEvent.fromFrame('garbage'), isA<UnknownHostEvent>());
      expect(HostEvent.fromFrame({'type': 'cancel', 'eventId': 'e1'}), isA<HostRequestCancelledEvent>());
    });
  });

  test('tolerant parsing of unknown and malformed follow frames', () {
    expect(parseFollowFrame('s', {'type': 'brand-new'}), isA<UnknownFrameEvent>());
    expect(parseFollowFrame('s', null), isA<UnknownFrameEvent>());
    final unknown = parseFollowFrame('s', {
      'type': 'event',
      'event': {'type': 'plugin/custom', 'seq': 7, 'time': 1, 'data': 42},
    });
    expect(unknown, isA<UnknownEvent>().having((e) => e.isKnownType, 'known', isFalse));
    expect((unknown as UnknownEvent).rawData, 42);
    final odd = parseFollowFrame('s', {
      'type': 'event',
      'event': {
        'type': 'tool/result',
        'seq': 'x',
        'data': {'message': 'nope'},
      },
    });
    expect(odd, isA<ToolResultEvent>().having((e) => e.seq, 'seq', -1));
    expect(Part.fromJson({'type': 'tool-addition', 'toolName': 'x'}), isA<UnknownPart>());
    expect(StreamChunk.fromJson({'type': 'mystery'}), isA<UnknownChunk>());
    expect(AssistantStreamEvent.fromFrame({'type': 'later'}), isA<UnknownFrameEvent>());
  });

  test('workspace follow frames', () {
    final updates = loadJsonl('workspace_follow.jsonl').map(WorkspaceUpdate.fromJson).toList();
    expect(updates.first, isA<WorkspaceBaseline>());
    expect(updates[1], isA<WorkspaceUpsert>().having((u) => u.workspace.title, 'title', 'ws'));
    expect(updates[2], isA<WorkspaceOrder>());
    expect(updates.whereType<WorkspaceArchivedUpdate>().map((u) => u.archivedSessionIds.length), [1, 0]);
  });

  test('control stream baseline and projection frames', () {
    final frames = loadJsonl('control_reply_ok.jsonl');
    final baseline = frames.first as Map<String, Object?>;
    expect(baseline['type'], 'baseline');
    final projections = (baseline['value'] as Map)['projections'] as Map;
    final one = SessionProjections.fromJson(projections.values.first);
    expect(one.title, 'Probe session');
    final keys = frames.skip(1).map((f) => (f as Map)['key']).toSet();
    expect(keys, containsAll(['inbox', 'turnOutline', 'tokenUsage', 'modelSelection']));
    final inbox = frames.skip(1).firstWhere((f) => (f as Map)['key'] == 'inbox') as Map;
    final withQueued = one.withValue('inbox', inbox['value'], inbox['seq'] as int);
    expect(withQueued.queuedMessages.single.text, startsWith('Reply with exactly'));
  });

  group('RPC values', () {
    final exchanges = (loadJson('rpc_exchanges.json') as List).cast<Map<String, Object?>>();
    Map<String, Object?> result(String endpoint, [int nth = 0]) =>
        exchanges.where((x) => x['endpoint'] == endpoint).elementAt(nth)['response']! as Map<String, Object?>;
    Object? value(String endpoint, [int nth = 0]) => (result(endpoint, nth)['result'] as Map)['value'];

    test('session list rows', () {
      final items = ((value('session/list', 1) as Map)['items'] as List).map(SessionSummary.fromJson).toList();
      expect(items, hasLength(3));
      expect(items.first.blank, isTrue);
      expect(items.first.cwd, '/tmp/dsh-home/ws');
      expect(items.first.projectionsKind, 'sequenced');
      expect(items.first.projections.imageLimits!['maxImagesPerMessage'], 20);
    });

    test('model catalog', () {
      final catalog = ModelCatalog.fromJson(value('session/modelCatalog'));
      expect(catalog.defaultSelection.toString(), 'deepseek-official/deepseek-flash');
      expect(catalog.routableProviders, ['deepseek-official']);
      final flash = catalog.models.firstWhere((m) => m.id == 'deepseek-flash');
      expect(flash.efforts.map((e) => e.id), ['off', 'low', 'high', 'max']);
      expect(flash.defaultEffort, 'high');
    });

    test('credentials and typed errors', () {
      final described = (value('credentials/describe') as Map).map(
        (k, v) => MapEntry(k as String, CredentialStatus.fromJson(v)),
      );
      expect(described['DEEPSEEK_API_KEY']!.source, 'env');
      expect(described['DEEPSEEK_API_KEY']!.writable, isFalse);
      expect((result('credentials/set')['result'] as Map).containsKey('value'), isFalse);
      final rejected = DshRemoteException.fromJson((result('credentials/set', 1)['result'] as Map)['error']);
      expect(rejected.code, 'credential/rejected');
      expect(rejected.details['ref'], 'DEEPSEEK_API_KEY');
      final unavailable = DshRemoteException.fromJson((result('session/selectModel', 1)['result'] as Map)['error']);
      expect(unavailable.code, 'session/model-unavailable');
      expect(unavailable.isGatewayError, isFalse);
    });
  });

  test('DshLaunchUrl parses the dsh web line', () {
    final launch = DshLaunchUrl.tryParse('dsh web: http://127.0.0.1:3080/?token=abc_DEF-123')!;
    expect(launch.baseUri.toString(), 'http://127.0.0.1:3080');
    expect(launch.token, 'abc_DEF-123');
    expect(DshLaunchUrl.tryParse('http://127.0.0.1:3080/'), isNull);
  });
}
