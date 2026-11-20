/// The dsh-go client against a real `dsh web` with the dsh-go bridge and the
/// usage and quick example plugins (examples/plugins): contributions with
/// ETag, a panel view, the stream (hello → welcome conn, a status line's
/// data), taps (a deferred one, a static one the bridge refuses).
///
/// Skipped unless `DSH_GO_LIVE_URL` holds the launch URL (with `?token=`).
/// Boot the host as examples/plugins/e2e/host-e2e.sh does (throwaway
/// DSH_HOME, `dsh plugin --profile web add <example>`, `dsh web --patch`
/// with the bridge), then:
/// ```sh
/// DSH_GO_LIVE_URL='http://127.0.0.1:38251/?token=...' dart test test/live_dsh_go_test.dart
/// ```
@Tags(['live'])
library;

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['DSH_GO_LIVE_URL'];
  final skip = url == null ? 'set DSH_GO_LIVE_URL to run against a live bridge' : null;
  const caps = DshGoCaps(app: '0.9.1', locale: 'zh-CN', components: ['stack', 'text', 'metric']);

  group('live dsh-go bridge', skip: skip, () {
    late DshClient client;

    setUpAll(() async => client = await DshClient.connect(launchUrl: url));
    tearDownAll(() => client.close());

    test('contributions: the two examples, localised, ready; 304 on a re-read', () async {
      final c = await client.readDshGoContributions(caps: caps);
      expect(c, isNotNull, reason: 'the bridge serves dshGo');
      final quick = c!.plugins.firstWhere((p) => p.pkg == 'dsh-go-example-quick');
      final usage = c.plugins.firstWhere((p) => p.pkg == 'dsh-go-example-usage');
      expect((quick.state, quick.native, quick.title), ('ok', true, '快捷'));
      expect(quick.wants, containsAll(['clipboard', 'message']));
      final summarize = quick.composerActions.firstWhere((a) => a.id == 'summarize');
      expect(summarize.effects.single['type'], 'insert', reason: 'static effect, run by the app');
      expect(quick.composerActions.firstWhere((a) => a.id == 'translate').ready, isTrue);
      expect(quick.messageActions.map((a) => a.id), containsAll(['copy-md', 'save-note']));
      final strip = usage.strips.single;
      expect((strip.id, strip.panel, strip.live, strip.tappable), ('today', 'usage', true, true));
      final panel = usage.panels.single;
      expect(panel.placement, containsAll([DshGoPanel.sessionTab, DshGoPanel.features]));
      expect(panel.live, isTrue);
      stdout.writeln('contributions rev ${c.rev}, bridge ${c.bridge}, ${c.plugins.length} plugins');

      final again = await client.readDshGoContributions(caps: caps, previous: c);
      expect(identical(again, c), isTrue, reason: 'If-None-Match → 304');
    });

    test('a panel view with its first data', () async {
      final view = await client.readDshGoView('dsh-go-example-usage', 'usage', caps: caps);
      expect(view.view, isA<Map<String, Object?>>());
      expect(view.live, isTrue);
      stdout.writeln('view ${view.bytes} B, rev ${view.rev}, title ${view.title}');
    });

    test('stream: welcome with conn; the status line data arrives', () async {
      final stream = client.openDshGoStream(locale: 'zh-CN');
      addTearDown(stream.close);
      final conn = await stream.hold(timeout: const Duration(seconds: 5));
      expect(conn, isNotNull, reason: 'bridge ≥ 0.3.0 says its connection id');
      stdout.writeln('bridge ${stream.bridge}, conn $conn');
      final first = await stream
          .subscribe(pkg: 'dsh-go-example-usage', id: 'today')
          .firstWhere((e) => e is DshGoData)
          .timeout(const Duration(seconds: 5));
      stdout.writeln('strip data ${(first as DshGoData).data}');
      stream.release();
    });

    test('taps: a deferred one comes back on the stream; a static one is refused', () async {
      final stream = client.openDshGoStream(locale: 'zh-CN');
      addTearDown(stream.close);
      final conn = await stream.hold(timeout: const Duration(seconds: 5));
      final result = await client.invokeDshGo(
        DshGoInvocation(
          pkg: 'dsh-go-example-quick',
          id: 'translate',
          surface: DshGoSurfaces.composerActions,
          clipboard: '你好，世界',
          locale: 'zh-CN',
          stream: conn,
        ),
      );
      stdout.writeln('translate: effects ${result.effects}, pending ${result.pending?.id} ${result.pending?.label}');
      if (result.pending case final pending?) {
        final outcome = await stream.outcome(pending.id, timeout: pending.timeout + const Duration(seconds: 5));
        stdout.writeln(switch (outcome) {
          DshGoDone(:final effects) => 'translate done: $effects',
          DshGoVoid(:final reason) => 'translate void: $reason',
        });
      }
      stream.release();

      await expectLater(
        client.invokeDshGo(
          const DshGoInvocation(pkg: 'dsh-go-example-quick', id: 'summarize', surface: DshGoSurfaces.composerActions),
        ),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/no-handler')),
      );
    });

    test('a reply menu item with the reply text', () async {
      try {
        final result = await client.invokeDshGo(
          const DshGoInvocation(
            pkg: 'dsh-go-example-quick',
            id: 'copy-md',
            surface: DshGoSurfaces.messageActions,
            scope: DshGoScope(sessionId: 'live-session', messageId: 'm1'),
            message: '**粗体**和`代码`',
            locale: 'zh-CN',
          ),
        );
        stdout.writeln('copy-md: ${result.effects}');
        expect(result.effects, isNotEmpty);
      } on DshRemoteException catch (e) {
        fail('copy-md refused: ${e.code} ${e.message}');
      }
    });
  });
}
