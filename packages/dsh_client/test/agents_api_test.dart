import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

const _parent = 'session-parent';
const _child = 'child-1';

/// A follow snapshot as DSH 0.2.1-rc.2 sends it for a subagent child.
Map<String, Object?> _childSnapshot() => {
  'type': 'snapshot',
  'header': {
    'version': 4,
    'id': _child,
    'createdAt': 0,
    'isSeeded': false,
    'origin': 'subagent',
    'parentSession': _parent,
  },
  'cursor': 0,
  'hasMore': false,
  'records': [
    {
      'type': 'event',
      'event': {
        'seq': 0,
        'time': 1792822153432,
        'type': 'user/message',
        'data': {
          'id': 'm0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'review and report'},
          ],
          'source': {'kind': 'user'},
        },
      },
    },
  ],
  'projections': {
    'asOfSeq': 0,
    'values': {
      'subagent': {'mode': 'continuable', 'label': 'review the diff', 'seq': 0},
    },
  },
};

/// `session/list` rows as DSH 0.2.1-rc.2 returns them (trimmed).
List<Object?> _list() => [
  {
    'sessionId': _parent,
    'updatedAt': 1792822153000,
    'running': false,
    'blank': false,
    'agentAvailable': true,
    'projections': {
      'kind': 'sequenced',
      'asOfSeq': 30,
      'values': {
        'title': '修复登录',
        'subagentCatalog': [
          {'mode': 'continuable', 'label': 'review the diff', 'id': _child, 'createdAt': 1792822153432},
        ],
      },
    },
  },
  {
    'sessionId': _child,
    'updatedAt': 1792822154000,
    'running': false,
    'blank': false,
    'agentAvailable': false,
    'parentSessionId': _parent,
    'origin': 'subagent',
    'projections': {
      'kind': 'cached',
      'asOfSeq': 21,
      'values': {
        'subagent': {'mode': 'continuable', 'label': 'review the diff', 'seq': 0},
        'subagentTiming': {'settledMs': 51, 'lastTurnCompleted': true},
      },
    },
  },
];

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
    addTearDown(client.close);
    return client;
  }

  group('projections', () {
    test('catalog, timing, identity and team read the 0.2.1 shapes', () {
      final rows = _list().map(SessionSummary.fromJson).toList();
      final catalog = rows.first.projections.subagentCatalog!;
      expect(catalog.single.id, _child);
      expect(catalog.single.mode, SubagentMode.continuable);
      expect(catalog.single.label, 'review the diff');
      expect(catalog.single.createdAt, DateTime.fromMillisecondsSinceEpoch(1792822153432));
      final child = rows.last.projections;
      expect(child.subagentIdentity!.mode, SubagentMode.continuable);
      expect(child.subagentTiming!.lastTurnCompleted, isTrue);
      expect(child.subagentTiming!.total, const Duration(milliseconds: 51));
      expect(child.subagentCatalog, isNull);

      final open = SubagentTiming.fromJson({
        'settledMs': 1000,
        'active': {'since': 10000, 'through': 12500},
      })!;
      expect(open.total, const Duration(milliseconds: 3500));
      expect(open.lastTurnCompleted, isNull);

      final team = SessionProjections(1, {
        'agentTeam': {
          'members': [
            {'id': _parent, 'name': 'lead', 'role': 'lead', 'phase': 'active'},
            {'id': _child, 'name': 'reviewer', 'role': 'teammate', 'phase': 'active'},
          ],
          'tasks': [
            {
              'id': 'task-1',
              'revision': 1,
              'subject': 'Write tests',
              'description': 'Cover the login double submit',
              'status': 'pending',
              'blockedBy': [],
              'writeScopes': [],
              'ready': true,
              'writeScopeWarnings': [],
            },
            {'id': 'task-2', 'subject': 'gone', 'status': 'deleted'},
          ],
        },
      }).agentTeam!;
      expect(team.members.first.lead, isTrue);
      expect(team.teammates.single.name, 'reviewer');
      expect(team.tasks.single.ready, isTrue);
      expect(team.isEmpty, isFalse);
      expect(const SessionProjections(1, {}).agentTeam, isNull);
    });

    test('team messages: relay source with the Team prefix, not plain agent messages', () {
      SessionLogEvent message(Map<String, Object?> source, List<String> texts) => SessionLogEvent.fromJson({
        'seq': 7,
        'time': 1792822300000,
        'type': 'user/message',
        'data': {
          'id': 'm7',
          'role': 'user',
          'content': [
            for (final t in texts) {'type': 'text', 'text': t},
          ],
          'source': source,
        },
      });
      final team = TeamMessage.fromEvent(
        _child,
        message(
          {'kind': 'agent-message', 'form': 'relay', 'senderSessionId': _parent},
          ['Team message from lead:', 'Please review the login fix.'],
        ),
      )!;
      expect(team.senderName, 'lead');
      expect(team.senderId, _parent);
      expect(team.recipientId, _child);
      expect(team.text, 'Please review the login fix.');
      expect(team.seq, 7);

      expect(
        TeamMessage.fromEvent(
          _parent,
          message({'kind': 'agent-message', 'form': 'relay', 'senderSessionId': _child}, ['done, see diff']),
        ),
        isNull,
      );
      expect(TeamMessage.fromEvent(_parent, message({'kind': 'user'}, ['hi'])), isNull);
      final legacy = TeamMessage.fromEvent(
        _parent,
        message({'kind': 'team-message', 'senderId': _child, 'senderName': 'reviewer'}, ['looks good']),
      )!;
      expect(legacy.senderName, 'reviewer');
      expect(legacy.text, 'looks good');
    });
  });

  group('routing', () {
    test('a routed child follows, pages, prompts and stops through its parent', () async {
      final requests = <Map<String, Object?>>[];
      host.onOpen = (socket, streamId, endpoint, payload) {
        requests.add(((payload['args'] as Map)['request'] as Map).cast<String, Object?>());
        socket.item(streamId, _childSnapshot());
      };
      Map<String, Object?>? promptArgs;
      Map<String, Object?>? interruptArgs;
      Map<String, Object?>? pageArgs;
      host.handlers['subagents/prompt'] = (args) {
        promptArgs = args;
        return ok({'messageId': 'msg-9'});
      };
      host.handlers['subagents/interruptByParent'] = (args) {
        interruptArgs = args;
        return ok({'accepted': true});
      };
      host.handlers['session/page'] = (args) {
        pageArgs = args;
        return ok({'records': [], 'hasMore': false});
      };

      final client = await connect();
      client.routeSubagent(
        const SubagentAddress(parentSessionId: _parent, childSessionId: _child, mode: SubagentMode.continuable),
      );
      // An unknown mode never downgrades a known one.
      client.routeSubagent(const SubagentAddress(parentSessionId: _parent, childSessionId: _child));
      expect(client.subagentRoute(_child)!.mode, SubagentMode.continuable);

      final first = Completer<SessionSnapshotEvent>();
      final sub = client.watch(_child).listen((e) {
        if (e is SessionSnapshotEvent && !first.isCompleted) first.complete(e);
      });
      addTearDown(sub.cancel);
      await first.future.timeout(const Duration(seconds: 5));
      expect(requests.single['address'], {
        'kind': 'subagent',
        'parentSessionId': _parent,
        'childSessionId': _child,
        'mode': 'continuable',
      });

      await client.history(_child, throughSeq: 0);
      expect(((pageArgs!['request'] as Map)['address'] as Map)['kind'], 'subagent');

      final id = await client.prompt(_child, '再检查一遍', mode: PromptMode.steer);
      final request = promptArgs!['request'] as Map;
      expect(request['requestId'], id);
      expect(request['parentSessionId'], _parent);
      expect(request['childSessionId'], _child);
      expect(request['mode'], 'continuable');
      expect(request['delivery'], 'steer');
      expect(request['content'], [
        {'type': 'text', 'text': '再检查一遍'},
      ]);
      expect(host.rpcCalls.any((c) => c['method'] == 'session/prompt'), isFalse);

      await client.cancel(_child);
      expect(interruptArgs, {'childSessionId': _child, 'parentSessionId': _parent, 'mode': 'continuable'});
    });

    test('an unrouted child is adopted from session/list after session/agent-busy', () async {
      final addresses = <Object?>[];
      host.onOpen = (socket, streamId, endpoint, payload) {
        final address = ((payload['args'] as Map)['request'] as Map)['address'] as Map;
        addresses.add(address);
        if (address['kind'] == 'session') {
          socket.send({
            'type': 'error',
            'streamId': streamId,
            'error': {
              'code': 'session/agent-busy',
              'message': 'subagent Sessions require their durable parent address',
              'details': {'reason': 'use subagent delivery for this child session'},
            },
          });
        } else {
          socket.item(streamId, _childSnapshot());
        }
      };
      host.handlers['session/list'] = (_) => ok({'items': _list()});
      final client = await connect();
      final first = Completer<SessionSnapshotEvent>();
      final sub = client
          .watch(_child)
          .listen(
            (e) {
              if (e is SessionSnapshotEvent && !first.isCompleted) first.complete(e);
            },
            onError: (Object e) {
              if (!first.isCompleted) first.completeError(e);
            },
          );
      addTearDown(sub.cancel);
      final snapshot = await first.future.timeout(const Duration(seconds: 5));
      expect(snapshot.header.origin, 'subagent');
      expect(addresses.map((a) => (a as Map)['kind']), ['session', 'subagent']);
      expect(client.subagentRoute(_child)!.mode, SubagentMode.continuable);
    });

    test('one-shot children and an offline parent refuse with a readable reason', () async {
      host.handlers['subagents/prompt'] = (_) => {
        'ok': false,
        'error': {
          'code': 'subagent/parent-unavailable',
          'message': 'no live parent',
          'details': {'parentSessionId': _parent},
        },
      };
      final client = await connect();
      client.routeSubagent(
        const SubagentAddress(parentSessionId: _parent, childSessionId: 'once', mode: SubagentMode.oneShot),
      );
      await expectLater(
        client.prompt('once', 'hi'),
        throwsA(isA<SubagentReadOnlyException>().having((e) => e.toString(), 'message', '一次性子代理只能查看记录')),
      );
      // Unknown mode resolves through session/projections first.
      host.handlers['session/projections'] = (_) => ok({
        'kind': 'sequenced',
        'asOfSeq': 3,
        'values': {
          'subagent': {'mode': 'continuable', 'label': 'x', 'seq': 0},
        },
      });
      client.routeSubagent(const SubagentAddress(parentSessionId: _parent, childSessionId: _child));
      await expectLater(
        client.prompt(_child, 'hi'),
        throwsA(isA<SubagentReadOnlyException>().having((e) => e.message, 'message', contains('上级对话'))),
      );
      expect(client.subagentRoute(_child)!.mode, SubagentMode.continuable);
      // A one-shot child has nothing to stop.
      await client.cancel('once');
      expect(host.rpcCalls.any((c) => c['method'] == 'subagents/interruptByParent'), isFalse);
    });
  });

  group('reasoning translation', () {
    test('limits and translate use the accepted provider', () async {
      host.handlers['cotTranslation/limits'] = (_) => ok({
        'maxTextChars': 4000,
        'preferences': {'provider': 'bing', 'targetLanguage': 'auto'},
        'availableProviders': ['bing', 'google'],
      });
      Map<String, Object?>? translateArgs;
      host.handlers['cotTranslation/translate'] = (args) {
        translateArgs = args;
        return ok('让我仔细想想。');
      };
      final client = await connect();
      final limits = await client.cotTranslationLimits();
      expect(limits.usable, isTrue);
      expect(limits.targetFor('zh'), 'zh');
      final text = await client.translateReasoning(
        'Let me think about this carefully.',
        targetLanguage: limits.targetFor('zh'),
        provider: limits.provider,
        sessionId: _parent,
      );
      expect(text, '让我仔细想想。');
      expect(translateArgs, {
        'request': {
          'text': 'Let me think about this carefully.',
          'targetLanguage': 'zh',
          'provider': 'bing',
          'sessionId': _parent,
        },
      });
      expect(
        const CotTranslationLimits(
          maxTextChars: 10,
          provider: 'deepseek-account',
          targetLanguage: 'ja',
          availableProviders: ['bing'],
        ).usable,
        isFalse,
      );
    });

    test('fragments keep separators, split long paragraphs at spaces, leave the tail open', () {
      const text = 'First paragraph.\n\nSecond one is a bit longer than ten.\n \nTail still gro';
      final running = reasoningFragments(text, running: true, maxTextChars: 16);
      expect(running.map((f) => f.text + f.suffix).join(), text);
      expect(running.first.text, 'First paragraph.');
      expect(running.last.text, 'Tail still gro');
      expect(running.last.complete, isFalse);
      expect(running.where((f) => !f.complete), hasLength(1));
      for (final f in running) {
        expect(f.text.length, lessThanOrEqualTo(16));
      }
      final done = reasoningFragments(text, running: false, maxTextChars: 4000);
      expect(done.map((f) => f.text), ['First paragraph.', 'Second one is a bit longer than ten.', 'Tail still gro']);
      expect(done.every((f) => f.complete), isTrue);
      expect(done[1].suffix, '\n \n');
    });
  });
}
