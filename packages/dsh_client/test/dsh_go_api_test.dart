import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// Shaped like docs/design/native-plugins-protocol.md §4.1.
const _contributions = {
  'v': 1,
  'bridge': '0.2.0',
  'rev': 'r1',
  'bootRev': 'b1',
  'limits': {'composerActions': 2},
  'plugins': [
    {
      'pkg': 'dsh-go-example-quick',
      'version': '0.1.0',
      'title': '快捷指令',
      'icon': 'bolt',
      'wants': ['clipboard', 'draft'],
      'state': 'ok',
      'native': true,
      'contributes': {
        'composer.actions': [
          {'id': 'translate', 'label': '译成英文', 'icon': 'translate', 'ready': true},
          {
            'id': 'hello',
            'label': '打招呼',
            'effect': [
              {'type': 'insert', 'text': '你好'},
            ],
            'ready': true,
          },
          {'label': 'no id'},
        ],
        'message.actions': [
          {'id': 'speak', 'label': '朗读', 'icon': 'speaker', 'ready': false},
        ],
        'composer.strip': [],
        'panels': [],
      },
      'issues': [
        {
          'path': '/dshGo/contributes/composer.actions/2/id',
          'code': 'missing-field',
          'severity': 'error',
          'message': 'id',
        },
      ],
    },
    {
      'pkg': '@acme/usage',
      'version': '1.0.0',
      'title': '用量',
      'wants': [],
      'state': 'ok',
      'native': true,
      'contributes': {
        'composer.actions': [],
        'message.actions': [],
        'composer.strip': [
          {'id': 'cost', 'icon': 'coin', 'text': null, 'panel': 'usage', 'ready': true, 'tappable': true, 'live': true},
        ],
        'panels': [
          {
            'id': 'usage',
            'title': '用量',
            'icon': 'chart',
            'placement': ['session.tab', 'features'],
            'ready': true,
            'live': true,
          },
          {'id': 'solo', 'ready': true, 'live': false},
        ],
      },
      'issues': [],
    },
    {
      'pkg': 'old-plugin',
      'version': '1.0.0',
      'title': 'Old',
      'state': 'needs-app',
      'native': false,
      'contributes': {'composer.actions': [], 'message.actions': [], 'composer.strip': [], 'panels': []},
      'issues': [
        {'path': '/dshGo/minApp', 'code': 'needs-app', 'severity': 'error'},
      ],
    },
    {'version': 'nameless'},
  ],
};

void main() {
  group('models', () {
    test('contributions read leniently', () {
      final c = DshGoContributions.fromJson(_contributions)!;
      expect(c.rev, 'r1');
      expect(c.bridge, '0.2.0');
      expect(c.plugins.map((p) => p.pkg), ['dsh-go-example-quick', '@acme/usage', 'old-plugin']);
      final quick = c.plugins.first;
      expect(quick.wants, {'clipboard', 'draft'});
      expect(quick.composerActions.map((a) => a.id), ['translate', 'hello']);
      expect(quick.composerActions.last.effects.single, {'type': 'insert', 'text': '你好'});
      expect(quick.messageActions.single.ready, isFalse);
      expect(quick.issues.single.isError, isTrue);
      expect(quick.issues.single.code, 'missing-field');
      final usage = c.plugins[1];
      final strip = usage.strips.single;
      expect((strip.panel, strip.tappable, strip.live, strip.text), ('usage', true, true, null));
      expect(usage.panels.first.placement, [DshGoPanel.sessionTab, DshGoPanel.features]);
      expect(usage.panels.last.placement, [DshGoPanel.sessionTab], reason: 'placement defaults to session.tab');
      expect(usage.panels.last.title, 'solo', reason: 'a panel without a title is called by its id');
      final old = c.plugins.last;
      expect((old.state, old.native), ('needs-app', false));
    });

    test('not a contributions object', () {
      expect(DshGoContributions.fromJson('x'), isNull);
      expect(DshGoContributions.fromJson({'v': 1}), isNull);
      expect(DshGoContributions.fromJson({'plugins': []})!.plugins, isEmpty);
    });

    test('invoke body carries only what is set; scope is normalised', () {
      final body = const DshGoInvocation(
        pkg: 'p',
        id: 'usage',
        surface: DshGoSurfaces.panel,
        action: 'pick',
        value: {'value': 'b'},
        scope: DshGoScope(turnId: '', sessionId: 's1', messageId: 'm'),
        clipboard: 'x',
        locale: 'zh-CN',
      ).toJson();
      expect(body, {
        'v': 1,
        'pkg': 'p',
        'id': 'usage',
        'surface': 'panel',
        'action': 'pick',
        'value': {'value': 'b'},
        'scope': {'messageId': 'm', 'sessionId': 's1'},
        'context': {'clipboard': 'x'},
        'locale': 'zh-CN',
      });
      expect(
        const DshGoInvocation(pkg: 'p', id: 'a', surface: 'composer.actions').toJson().containsKey('context'),
        isFalse,
      );
    });

    test('caps go out as query parameters', () {
      expect(const DshGoCaps(app: '0.9.1', locale: 'zh-CN', components: ['stack', 'text']).query, {
        'v': '1',
        'app': '0.9.1',
        'locale': 'zh-CN',
        'surfaces': 'composer.actions,message.actions,composer.strip,panels',
        'components': 'stack,text',
      });
    });

    test('invoke result: pending (v1.1), timeout clamped', () {
      final r = DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [],
        'pending': {'id': 'p3f9', 'label': '翻译中', 'timeoutMs': 120000},
        'issues': [],
      });
      expect(r.pending?.id, 'p3f9');
      expect(r.pending?.label, '翻译中');
      expect(r.pending?.timeout, const Duration(seconds: 60));
      expect(
        const DshGoInvocation(pkg: 'p', id: 'x', surface: 'composer.actions', stream: 'Yc1').toJson()['stream'],
        'Yc1',
      );
    });

    test('invoke result: effects and dropped ones', () {
      final r = DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [
          {'type': 'insert', 'text': 'hi'},
          3,
        ],
        'issues': [
          {'path': '/runtime/x', 'code': 'unknown-effect'},
        ],
      });
      expect(r.effects, [
        {'type': 'insert', 'text': 'hi'},
      ]);
      expect(r.issues.single.code, 'unknown-effect');
      expect(DshGoInvokeResult.fromJson(null).effects, isEmpty);
    });

    test('a scoped package takes two path segments', () {
      expect(dshGoViewPath('@acme/usage-meter', 'usage'), '/dsh-go/v1/views/@acme/usage-meter/usage');
      expect(dshGoViewPath('plain', 'a b'), '/dsh-go/v1/views/plain/a%20b');
    });

    test('merge patch (RFC 7386)', () {
      expect(
        mergePatch(
          {
            'a': 1,
            'b': {'c': 2, 'd': 3},
            'e': [1, 2],
          },
          {
            'a': null,
            'b': {'c': 9},
            'e': [3],
            'f': 'new',
          },
        ),
        {
          'b': {'c': 9, 'd': 3},
          'e': [3],
          'f': 'new',
        },
      );
      expect(mergePatch({'a': 1}, 'whole'), 'whole');
      expect(mergePatch(null, {'a': null, 'b': 1}), {'b': 1});
    });
  });

  group('calls', () {
    late _FakeHost host;
    late DshClient client;

    setUp(() async {
      host = await _FakeHost.start();
      client = await DshClient.connect(baseUri: host.baseUri, token: _FakeHost.token, startMux: false);
    });

    tearDown(() async {
      await client.close();
      await host.close();
    });

    test('bridge capabilities distinguish legacy unknown, an empty list, and future names', () async {
      expect(await client.readDshGoBridgeCapabilities(), isNull);
      host.capabilities = {'v': 1, 'bridge': '0.4.0', 'capabilities': <String>[]};
      final empty = await client.readDshGoBridgeCapabilities();
      expect(empty?.v, 1);
      expect(empty?.capabilities, isEmpty);
      host.capabilities = {
        'v': 1,
        'bridge': '999.0.0',
        'capabilities': ['native-ui', 'future-capability'],
      };
      final next = await client.readDshGoBridgeCapabilities();
      expect(next?.bridge, '999.0.0', reason: 'bridge version is diagnostic, v determines support');
      expect(next?.capabilities, {'native-ui', 'future-capability'});
      expect(host.requests.last.rawPath, dshGoCapabilitiesPath);
      expect(host.requests.last.cookie, contains(_FakeHost.cookieName));
    });

    test('negotiation rejects unsupported majors and malformed capability declarations', () async {
      host.capabilities = {'v': 2};
      await expectLater(
        client.readDshGoBridgeCapabilities(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/unsupported-version')),
      );
      for (final body in [
        {'bridge': '0.4.0', 'capabilities': []},
        {'v': '1', 'bridge': '0.4.0', 'capabilities': []},
        {'v': 1, 'bridge': '0.4.0'},
        {'v': 1, 'capabilities': []},
        {
          'v': 1,
          'bridge': '0.4.0',
          'capabilities': ['native-ui', 7],
        },
      ]) {
        host.capabilities = body;
        await expectLater(client.readDshGoBridgeCapabilities(), throwsA(isA<DshProtocolException>()));
      }
    });

    test('structured contributions resource errors propagate without a negotiation request', () async {
      host.status = 404;
      for (final body in [
        {
          'error': {'code': 'not-found', 'message': 'resource missing'},
        },
        {'code': 'not-found', 'message': 'resource missing'},
      ]) {
        host.body = jsonEncode(body);
        host.requests.clear();
        await expectLater(
          client.readDshGoContributions(),
          throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/not-found')),
        );
        expect(host.requests.map((r) => r.rawPath), [dshGoContributionsPath]);
      }
      host.body = jsonEncode({
        'error': {'code': 'route-not-found', 'message': 'route missing'},
      });
      host.requests.clear();
      expect(await client.readDshGoContributions(), isNull);
      expect(host.requests.map((r) => r.rawPath), [dshGoContributionsPath]);
    });

    test('ambiguous contributions 404 is checked against a fresh capability declaration', () async {
      host.status = 404;
      host.body = 'not found';
      host.capabilities = {'v': 1, 'bridge': '0.4.0', 'capabilities': <String>[]};
      host.requests.clear();
      expect(await client.readDshGoContributions(), isNull);
      expect(host.requests.map((r) => r.rawPath), [dshGoContributionsPath, dshGoCapabilitiesPath]);
      host.capabilities = {
        'v': 1,
        'bridge': '0.4.0',
        'capabilities': ['native-ui'],
      };
      await expectLater(
        client.readDshGoContributions(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/http-404')),
      );
      host.capabilities = null;
      expect(await client.readDshGoContributions(), isNull, reason: 'legacy unknown is not cached as absence');
    });

    test('negotiation failures never become unsupported-bridge null', () async {
      host.status = 404;
      for (final status in [401, 403, 503]) {
        host.capabilitiesStatus = status;
        await expectLater(
          client.readDshGoContributions(),
          throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/http-$status')),
        );
      }
      host.capabilitiesStatus = 404;
      host.capabilitiesBody = jsonEncode({
        'error': {'code': 'not-found', 'message': 'resource missing'},
      });
      await expectLater(
        client.readDshGoContributions(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/not-found')),
      );
      host.capabilitiesBody = jsonEncode({
        'error': {'code': 'route-not-found', 'message': 'route missing'},
      });
      expect(await client.readDshGoContributions(), isNull);
      host.capabilitiesBody = null;
      host.capabilitiesStatus = null;
      host.capabilities = {'v': 2};
      await expectLater(
        client.readDshGoContributions(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/unsupported-version')),
      );
    });

    test('successful contributions and 304 need no negotiation and reject unknown protocol majors', () async {
      host.contributions = {..._contributions, 'bridge': '999.0.0'};
      host.requests.clear();
      final first = await client.readDshGoContributions();
      expect(first?.bridge, '999.0.0');
      expect(identical(await client.readDshGoContributions(previous: first), first), isTrue);
      expect(host.requests.map((r) => r.rawPath), [dshGoContributionsPath, dshGoContributionsPath]);
      host.contributions = {..._contributions, 'v': 2};
      await expectLater(
        client.readDshGoContributions(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/unsupported-version')),
      );
      host.contributions = {'plugins': []};
      await expectLater(client.readDshGoContributions(), throwsA(isA<DshProtocolException>()));
    });

    test('contributions: no bridge, caps, ETag round trip, refusal, bad body', () async {
      expect(client.canReachDshGo, isTrue);
      expect(await client.readDshGoContributions(), isNull);

      host.contributions = _contributions;
      final first = await client.readDshGoContributions(
        caps: const DshGoCaps(app: '0.9.1', locale: 'zh-CN'),
      );
      expect(first?.plugins, hasLength(3));
      final request = host.requests.last;
      expect(request.cookie, contains(_FakeHost.cookieName));
      expect(request.query['app'], '0.9.1');
      expect(request.query['locale'], 'zh-CN');
      expect(request.query['v'], '1');

      // Unchanged: 304, and the same object back.
      final again = await client.readDshGoContributions(previous: first);
      expect(identical(again, first), isTrue);
      expect(host.requests.last.ifNoneMatch, '"r1"');
      expect(host.lastStatus, 304);

      host.status = 403;
      host.body = 'forbidden';
      await expectLater(
        client.readDshGoContributions(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/http-403')),
      );
      host.status = null;
      host.body = '<html>';
      await expectLater(client.readDshGoContributions(), throwsA(isA<DshProtocolException>()));
    });

    test('view: path, scope and caps in the query, size', () async {
      host.view = {
        'v': 1,
        'pkg': '@acme/usage',
        'id': 'usage',
        'title': '用量',
        'view': {'type': 'text', 'text': 'hi'},
        'data': {'a': 1},
        'rev': 'a7.3',
        'live': true,
        'stats': {'bytes': 2140, 'nodes': 18, 'depth': 4},
        'issues': [],
      };
      final view = await client.readDshGoView(
        '@acme/usage',
        'usage',
        scope: const DshGoScope(sessionId: 's1'),
        caps: const DshGoCaps(app: '0.9.1'),
      );
      expect((view.title, view.rev, view.live, view.bytes), ('用量', 'a7.3', true, 2140));
      expect(view.data, {'a': 1});
      final request = host.requests.last;
      expect(request.rawPath, '/dsh-go/v1/views/@acme/usage/usage');
      expect(request.query['sessionId'], 's1');
      expect(request.query['app'], '0.9.1');
    });

    test('invoke: body, effects, the bridge error code', () async {
      host.invoke = {
        'v': 1,
        'effects': [
          {'type': 'insert', 'text': 'Hello'},
        ],
        'issues': [],
      };
      final result = await client.invokeDshGo(
        const DshGoInvocation(
          pkg: 'dsh-go-example-quick',
          id: 'translate',
          surface: DshGoSurfaces.composerActions,
          scope: DshGoScope(sessionId: 's1'),
          clipboard: '你好',
        ),
      );
      expect(result.effects.single, {'type': 'insert', 'text': 'Hello'});
      expect(host.lastBody, {
        'v': 1,
        'pkg': 'dsh-go-example-quick',
        'id': 'translate',
        'surface': 'composer.actions',
        'scope': {'sessionId': 's1'},
        'context': {'clipboard': '你好'},
      });
      host.status = 504;
      host.body = jsonEncode({
        'v': 1,
        'error': {'code': 'timeout', 'message': 'handler took longer than 3 s'},
      });
      await expectLater(
        client.invokeDshGo(const DshGoInvocation(pkg: 'p', id: 'x', surface: 'composer.actions')),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/timeout')),
      );
    });

    test('HTTP errors accept nested and legacy flat codes, with nested taking precedence', () async {
      host.status = 422;
      for (final body in [
        {
          'error': {'code': 'invalid-config', 'message': 'check field'},
          'code': 'obsolete-code',
          'message': 'obsolete message',
        },
        {'v': 1, 'code': 'invalid-config', 'message': 'check field'},
      ]) {
        host.body = jsonEncode(body);
        await expectLater(
          client.readDshGoView('p', 'view'),
          throwsA(
            isA<DshRemoteException>()
                .having((e) => e.code, 'code', 'dsh-go/invalid-config')
                .having((e) => e.message, 'message', 'check field'),
          ),
        );
      }
      host.status = 503;
      for (final body in ['Service Unavailable', '<html>upstream failure</html>']) {
        host.body = body;
        await expectLater(
          client.readDshGoView('p', 'view'),
          throwsA(
            isA<DshRemoteException>()
                .having((e) => e.code, 'code', 'dsh-go/http-503')
                .having((e) => e.message, 'message', '${dshGoViewPath('p', 'view')}: HTTP 503'),
          ),
        );
      }
    });

    test('stream over a real socket: hello, sub, data, patch, changed, unsub', () async {
      final stream = client.openDshGoStream(locale: 'zh-CN');
      addTearDown(stream.close);
      final events = <DshGoEvent>[];
      final sub = stream
          .subscribe(
            pkg: '@acme/usage',
            id: 'cost',
            scope: const DshGoScope(sessionId: 's1'),
          )
          .listen(events.add);
      expect(await host.socketMessages.next, {
        't': 'hello',
        'v': [1],
        'locale': 'zh-CN',
      });
      final hello = await host.socketMessages.next;
      expect(hello, {
        't': 'sub',
        'sub': 's1',
        'pkg': '@acme/usage',
        'id': 'cost',
        'scope': {'sessionId': 's1'},
      });
      var changes = 0;
      final changed = stream.changes.listen((_) => changes++);
      host.push({'t': 'welcome', 'v': 1, 'bridge': '0.2.0', 'hb': 25});
      host.push({
        't': 'data',
        'sub': 's1',
        'rev': '1',
        'data': {'text': '本对话 ¥0.42', 'tone': 'muted'},
      });
      host.push({
        't': 'patch',
        'sub': 's1',
        'rev': '2',
        'base': '1',
        'merge': {'text': '本对话 ¥0.50'},
      });
      host.push({'t': 'data', 'sub': 'other', 'rev': '1', 'data': {}});
      host.push({'t': 'changed'});
      await _settle(() => events.length == 2 && changes == 1);
      expect(stream.bridge, '0.2.0');
      expect(events.first, isA<DshGoData>().having((e) => e.rev, 'rev', '1'));
      expect(events.last, isA<DshGoData>().having((e) => e.data, 'data', {'text': '本对话 ¥0.50', 'tone': 'muted'}));

      // A patch on a base the app doesn't hold: the app asks again with its rev.
      host.push({
        't': 'patch',
        'sub': 's1',
        'rev': '9',
        'base': '7',
        'merge': {'text': 'x'},
      });
      expect(await host.socketMessages.next, {
        't': 'sub',
        'sub': 's1',
        'pkg': '@acme/usage',
        'id': 'cost',
        'scope': {'sessionId': 's1'},
        'rev': '2',
      });
      expect(events, hasLength(2));

      await sub.cancel();
      await changed.cancel();
      await _settle(() => stream.link == DshGoLink.idle);
    });

    group('host end over a real socket', () {
      test('last surface ends and its App-style cancel closes the idle socket', () async {
        final stream = client.openDshGoStream();
        addTearDown(stream.close);
        final ended = Completer<void>();
        final events = <DshGoEvent>[];
        late final StreamSubscription<DshGoEvent> subscription;
        subscription = stream.subscribe(pkg: '@acme/usage', id: 'cost').listen((event) {
          events.add(event);
          if (event is DshGoEnded) {
            // NativeSurfaceController._onEvent calls _stop(), which cancels.
            unawaited(subscription.cancel().then((_) => ended.complete()));
          }
        });
        expect((await host.socketMessages.next)['t'], 'hello');
        final sub = await host.socketMessages.next;
        expect(sub['t'], 'sub');
        host.push({'t': 'welcome', 'v': 1, 'bridge': '0.3.0', 'conn': 'c1', 'hb': 25});
        host.push({'t': 'end', 'sub': sub['sub'], 'reason': 'not-found'});

        await ended.future.timeout(const Duration(seconds: 5));
        expect(events.single, isA<DshGoEnded>().having((e) => e.reason, 'reason', 'not-found'));
        expect(stream.subscriptionCount, 0);
        expect(stream.link, DshGoLink.idle);
        expect(stream.conn, isNull);
        expect(await host.socketClosed.future.timeout(const Duration(seconds: 5)), 1000);
      });

      test('another surface survives until its own final end', () async {
        final stream = client.openDshGoStream();
        addTearDown(stream.close);
        final aDone = Completer<void>();
        final bDone = Completer<void>();
        final bData = Completer<DshGoData>();
        final aEvents = <DshGoEvent>[];
        final bEvents = <DshGoEvent>[];
        stream.subscribe(pkg: '@acme/usage', id: 'a').listen(aEvents.add, onDone: aDone.complete);
        stream.subscribe(pkg: '@acme/usage', id: 'b').listen((event) {
          bEvents.add(event);
          if (event is DshGoData) bData.complete(event);
        }, onDone: bDone.complete);
        expect((await host.socketMessages.next)['t'], 'hello');
        final a = await host.socketMessages.next;
        final b = await host.socketMessages.next;
        expect([a['id'], b['id']], ['a', 'b']);
        host.push({'t': 'welcome', 'v': 1, 'bridge': '0.3.0', 'conn': 'c1', 'hb': 25});
        host.push({'t': 'end', 'sub': a['sub'], 'reason': 'not-found'});

        await aDone.future.timeout(const Duration(seconds: 5));
        expect(aEvents.single, isA<DshGoEnded>());
        expect(stream.subscriptionCount, 1);
        expect(stream.link, DshGoLink.open);
        expect(host.socketClosed.isCompleted, isFalse);
        host.push({
          't': 'data',
          'sub': b['sub'],
          'rev': 'r1',
          'data': {'text': 'still live'},
        });
        expect((await bData.future.timeout(const Duration(seconds: 5))).data, {'text': 'still live'});
        host.push({'t': 'end', 'sub': b['sub'], 'reason': 'degraded'});

        await bDone.future.timeout(const Duration(seconds: 5));
        expect(bEvents.last, isA<DshGoEnded>().having((e) => e.reason, 'reason', 'degraded'));
        expect(stream.subscriptionCount, 0);
        expect(stream.link, DshGoLink.idle);
        expect(await host.socketClosed.future.timeout(const Duration(seconds: 5)), 1000);
      });

      test('an explicit hold keeps deferred results alive after the last surface ends', () async {
        final stream = client.openDshGoStream();
        addTearDown(stream.close);
        final ended = Completer<void>();
        stream.subscribe(pkg: '@acme/usage', id: 'cost').listen((_) {}, onDone: ended.complete);
        final connection = stream.hold();
        expect((await host.socketMessages.next)['t'], 'hello');
        final sub = await host.socketMessages.next;
        host.push({'t': 'welcome', 'v': 1, 'bridge': '0.3.0', 'conn': 'c1', 'hb': 25});
        expect(await connection, 'c1');
        final outcome = stream.outcome('p1', timeout: const Duration(seconds: 5));
        host.push({'t': 'end', 'sub': sub['sub'], 'reason': 'not-found'});

        await ended.future.timeout(const Duration(seconds: 5));
        expect(stream.subscriptionCount, 0);
        expect(stream.link, DshGoLink.open);
        expect(stream.conn, 'c1');
        expect(host.socketClosed.isCompleted, isFalse);
        host.push({
          't': 'done',
          'pending': 'p1',
          'effects': [
            {'type': 'toast', 'text': 'done'},
          ],
        });
        expect(await outcome, isA<DshGoDone>().having((e) => e.effects.single['text'], 'text', 'done'));

        stream.release();
        expect(stream.link, DshGoLink.idle);
        expect(await host.socketClosed.future.timeout(const Duration(seconds: 5)), 1000);
      });

      test('a micro subscription keeps receiving after the last surface ends', () async {
        final stream = client.openDshGoStream(features: const ['micro']);
        addTearDown(stream.close);
        final panelDone = Completer<void>();
        final microDone = Completer<void>();
        final microData = Completer<DshGoData>();
        final microEvents = <DshGoEvent>[];
        stream.subscribe(pkg: '@acme/usage', id: 'cost').listen((_) {}, onDone: panelDone.complete);
        stream.subscribeMicro(pkg: '@acme/usage', id: 'caption').listen((event) {
          microEvents.add(event);
          if (event is DshGoData) microData.complete(event);
        }, onDone: microDone.complete);
        expect((await host.socketMessages.next)['features'], ['micro']);
        final panel = await host.socketMessages.next;
        expect(panel['t'], 'sub');
        host.push({
          't': 'welcome',
          'v': 1,
          'bridge': '0.3.0',
          'conn': 'c1',
          'hb': 25,
          'features': ['micro'],
        });
        final micro = await host.socketMessages.next;
        expect(micro['t'], 'micro.sub');
        host.push({'t': 'end', 'sub': panel['sub'], 'reason': 'not-found'});

        await panelDone.future.timeout(const Duration(seconds: 5));
        expect(stream.subscriptionCount, 0);
        expect(stream.link, DshGoLink.open);
        expect(host.socketClosed.isCompleted, isFalse);
        host.push({
          't': 'micro.data',
          'sub': micro['sub'],
          'rev': '0123456789abcdef.1',
          'data': {'text': 'still live'},
        });
        expect((await microData.future.timeout(const Duration(seconds: 5))).data, {'text': 'still live'});
        host.push({'t': 'micro.end', 'sub': micro['sub'], 'reason': 'not-found'});

        await microDone.future.timeout(const Duration(seconds: 5));
        expect(microEvents.last, isA<DshGoEnded>());
        expect(stream.link, DshGoLink.idle);
        expect(await host.socketClosed.future.timeout(const Duration(seconds: 5)), 1000);
      });
    });
  });

  group('stream lifecycle (fake socket)', () {
    test('one socket for many subscriptions; drop → backoff → hello and subs with rev', () async {
      final sockets = <_FakeSocket>[];
      final stream = DshGoStream(() async {
        final s = _FakeSocket();
        sockets.add(s);
        return s;
      }, backoff: (_) => const Duration(milliseconds: 10));
      addTearDown(stream.close);
      final a = stream.subscribe(pkg: 'p', id: 'a', rev: 'r0', data: {'n': 0}).listen((_) {});
      final b = stream.subscribe(pkg: 'p', id: 'b').listen((_) {});
      await _settle(() => sockets.length == 1 && sockets.single.sent.length == 3);
      expect(sockets.single.sent.map((m) => m['t']), ['hello', 'sub', 'sub']);
      expect(sockets.single.sent[1]['rev'], 'r0');

      sockets.single.push({'t': 'data', 'sub': 's2', 'rev': 'x1', 'data': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      sockets.single.drop();
      await _settle(() => sockets.length == 2 && sockets.last.sent.length == 3);
      expect(stream.link, DshGoLink.open);
      expect(sockets.last.sent.map((m) => m['t']), ['hello', 'sub', 'sub']);
      expect(sockets.last.sent.map((m) => m['rev']), [null, 'r0', 'x1'], reason: 'each sub carries its rev');

      await a.cancel();
      expect(sockets.last.sent.last, {'t': 'unsub', 'sub': 's1'});
      await b.cancel();
      expect(stream.link, DshGoLink.idle);
      expect(sockets.last.closedWith, 1000);
    });

    test('a silent socket is dropped and reconnected', () async {
      final sockets = <_FakeSocket>[];
      final stream = DshGoStream(
        () async {
          final s = _FakeSocket();
          sockets.add(s);
          return s;
        },
        silence: const Duration(milliseconds: 40),
        backoff: (_) => const Duration(milliseconds: 5),
      );
      addTearDown(stream.close);
      final sub = stream.subscribe(pkg: 'p', id: 'a').listen((_) {});
      addTearDown(sub.cancel);
      await _settle(() => sockets.length == 2);
      expect(sockets.first.closedWith, 1000);
    });

    test('background closes after the grace; foreground reconnects and catches up', () async {
      final sockets = <_FakeSocket>[];
      final stream = DshGoStream(() async {
        final s = _FakeSocket();
        sockets.add(s);
        return s;
      }, backgroundGrace: const Duration(milliseconds: 30));
      addTearDown(stream.close);
      final sub = stream.subscribe(pkg: 'p', id: 'cost').listen((_) {});
      addTearDown(sub.cancel);
      await _settle(() => stream.link == DshGoLink.open);

      // Back within the grace: nothing happens.
      stream.background();
      stream.foreground();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sockets, hasLength(1));
      expect(sockets.single.closedWith, isNull);

      stream.background();
      await _settle(() => stream.link == DshGoLink.background);
      expect(sockets.single.closedWith, 1000);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sockets, hasLength(1), reason: 'no reconnect while in the background');

      stream.foreground();
      await _settle(() => stream.link == DshGoLink.open && sockets.length == 2);
      await _settle(() => sockets.last.sent.length == 2);
      expect(sockets.last.sent.map((m) => m['t']), ['hello', 'sub']);
    });

    test('end closes the subscription; stale passes through', () async {
      final socket = _FakeSocket();
      final stream = DshGoStream(() async => socket);
      addTearDown(stream.close);
      final events = <DshGoEvent>[];
      final done = Completer<void>();
      stream.subscribe(pkg: 'p', id: 'usage').listen(events.add, onDone: done.complete);
      await _settle(() => socket.sent.length == 2);
      socket.push({'t': 'stale', 'sub': 's1'});
      socket.push({'t': 'end', 'sub': 's1', 'reason': 'not-found'});
      await done.future.timeout(const Duration(seconds: 1));
      expect(events.first, isA<DshGoStale>());
      expect(events.last, isA<DshGoEnded>().having((e) => e.reason, 'reason', 'not-found'));
      expect(stream.subscriptionCount, 0);
    });

    test('deferred results: hold for conn, done (also early), void, cancel, drop voids', () async {
      final sockets = <_FakeSocket>[];
      final stream = DshGoStream(() async {
        final s = _FakeSocket();
        sockets.add(s);
        return s;
      }, backoff: (_) => const Duration(milliseconds: 5));
      addTearDown(stream.close);

      // No subscriptions: a hold still opens the socket and waits for welcome.
      final conn = stream.hold();
      await _settle(() => sockets.length == 1 && sockets.single.sent.isNotEmpty);
      sockets.single.push({'t': 'welcome', 'v': 1, 'bridge': '0.3.0', 'hb': 25, 'conn': 'Yc1'});
      expect(await conn, 'Yc1');

      // done after the invoke answered.
      final first = stream.outcome('p1', timeout: const Duration(seconds: 1));
      sockets.single.push({
        't': 'done',
        'pending': 'p1',
        'effects': [
          {'type': 'insert', 'text': 'Hello'},
        ],
      });
      expect(await first, isA<DshGoDone>().having((d) => d.effects.single['text'], 'text', 'Hello'));

      // done before the invoke answered (out of order): kept for a moment.
      sockets.single.push({'t': 'done', 'pending': 'p2', 'effects': []});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await stream.outcome('p2', timeout: const Duration(seconds: 1)), isA<DshGoDone>());

      // cancel → void cancelled.
      final third = stream.outcome('p3', timeout: const Duration(seconds: 1));
      stream.cancel('p3');
      expect(sockets.single.sent.last, {'t': 'cancel', 'pending': 'p3'});
      sockets.single.push({'t': 'void', 'pending': 'p3', 'reason': 'cancelled'});
      expect(await third, isA<DshGoVoid>().having((v) => v.reason, 'reason', 'cancelled'));

      // Our own timeout.
      expect(
        await stream.outcome('p4', timeout: const Duration(milliseconds: 20)),
        isA<DshGoVoid>().having((v) => v.reason, 'reason', 'timeout'),
      );

      // A drop voids what was waiting, and the new connection has no id yet.
      final fifth = stream.outcome('p5', timeout: const Duration(seconds: 1));
      sockets.single.drop();
      expect(await fifth, isA<DshGoVoid>().having((v) => v.reason, 'reason', 'disconnected'));
      expect(stream.conn, isNull);
      await _settle(() => sockets.length == 2);

      // Last hold gone, nothing subscribed: the socket closes.
      stream.release();
      expect(stream.link, DshGoLink.idle);
      expect(sockets.last.closedWith, 1000);
    });

    test('an older bridge: welcome without conn', () async {
      final socket = _FakeSocket();
      final stream = DshGoStream(() async => socket);
      addTearDown(stream.close);
      final conn = stream.hold();
      await _settle(() => socket.sent.isNotEmpty);
      socket.push({'t': 'welcome', 'v': 1, 'bridge': '0.2.0', 'hb': 25});
      expect(await conn, isNull);
      stream.release();
    });

    test('a failing connect retries with backoff', () async {
      var calls = 0;
      final stream = DshGoStream(() async {
        if (++calls < 3) throw const DshTransportException('refused');
        return _FakeSocket();
      }, backoff: (_) => const Duration(milliseconds: 5));
      addTearDown(stream.close);
      final sub = stream.subscribe(pkg: 'p', id: 'x').listen((_) {});
      addTearDown(sub.cancel);
      await _settle(() => stream.link == DshGoLink.open);
      expect(calls, 3);
    });

    test('closed stream: subscriptions end', () async {
      final stream = DshGoStream(() async => _FakeSocket());
      final done = Completer<void>();
      stream.subscribe(pkg: 'p', id: 'x').listen((_) {}, onDone: done.complete);
      await stream.close();
      await done.future.timeout(const Duration(seconds: 1));
      expect(stream.link, DshGoLink.closed);
      expect(await stream.subscribe(pkg: 'p', id: 'y').isEmpty, isTrue);
    });
  });
}

Future<void> _settle(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

class _FakeSocket implements DshGoSocket {
  final _in = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];
  int? closedWith;

  @override
  Stream<Object?> get messages => _in.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, Object?>);

  @override
  Future<void> close([int? code]) async {
    closedWith = code;
    await _in.close();
  }

  void push(Map<String, Object?> message) => _in.add(jsonEncode(message));

  void drop() => unawaited(_in.close());
}

class _Request {
  _Request(this.method, this.rawPath, this.query, this.cookie, this.ifNoneMatch);
  final String method;
  final String rawPath;
  final Map<String, String> query;
  final String? cookie;
  final String? ifNoneMatch;
}

/// `dsh web` with the bridge's dshGo routes.
class _FakeHost {
  _FakeHost._(this._server);

  static const token = 'launch-token';
  static const cookieName = 'dsh-auth-k1';

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((request) => unawaited(host._handle(request)));
    return host;
  }

  final HttpServer _server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');
  final requests = <_Request>[];

  Map<String, Object?>? contributions;
  Map<String, Object?>? capabilities;
  int? capabilitiesStatus;
  String? capabilitiesBody;
  Map<String, Object?>? view;
  Map<String, Object?>? invoke;
  String? body;
  int? status;
  int? lastStatus;
  Object? lastBody;
  WebSocket? _socket;
  final socketClosed = Completer<int?>();
  final _socketIn = StreamController<Map<String, Object?>>();
  late final socketMessages = _Queue(_socketIn.stream);

  void push(Map<String, Object?> message) => _socket?.add(jsonEncode(message));

  Future<void> close() async {
    await _socket?.close();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final cookie = request.headers.value(HttpHeaders.cookieHeader);
    final raw = request.uri.toString().split('?').first;
    final etag = request.headers.value('if-none-match');
    requests.add(_Request(request.method, raw, request.uri.queryParameters, cookie, etag));
    final response = request.response;
    final authed = cookie?.contains('$cookieName=v1.sig') ?? false;
    final path = request.uri.path;
    if (path == '/' && request.uri.queryParameters['token'] == token) {
      response
        ..statusCode = 303
        ..headers.set('location', './')
        ..headers.add('set-cookie', '$cookieName=v1.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict');
      await response.close();
      return;
    }
    if (!authed) {
      response.statusCode = 401;
      await response.close();
      return;
    }
    if (path == dshGoStreamPath && WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      _socket = ws;
      ws.listen(
        (m) => _socketIn.add(jsonDecode(m as String) as Map<String, Object?>),
        onError: (_) {},
        onDone: () => socketClosed.complete(ws.closeCode),
      );
      return;
    }
    final replyStatus = path == dshGoCapabilitiesPath ? capabilitiesStatus : status;
    final replyBody = path == dshGoCapabilitiesPath ? capabilitiesBody : body;
    Object? payload;
    if (path == dshGoCapabilitiesPath) {
      payload = capabilities;
    } else if (path == dshGoContributionsPath) {
      payload = contributions;
      final rev = contributions?['rev'];
      if (rev != null && etag == '"$rev"' && replyStatus == null) {
        response.statusCode = lastStatus = 304;
        await response.close();
        return;
      }
    } else if (path.startsWith('$dshGoViewsPath/')) {
      payload = view;
    } else if (path == dshGoInvokePath) {
      lastBody = jsonDecode(await utf8.decodeStream(request));
      payload = invoke;
    }
    if (replyStatus case final s?) {
      response.statusCode = s;
      if (replyBody case final b?) response.write(b);
    } else if (replyBody case final b?) {
      response.write(b);
    } else if (payload != null) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(payload));
    } else {
      response.statusCode = 404;
    }
    lastStatus = response.statusCode;
    await response.close();
  }
}

/// A pull queue over a stream (just what the tests need).
class _Queue<T> {
  _Queue(Stream<T> stream) {
    stream.listen((v) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(v);
      } else {
        _buffer.add(v);
      }
    });
  }

  final _buffer = <T>[];
  final _waiting = <Completer<T>>[];

  Future<T> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<T>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }
}
