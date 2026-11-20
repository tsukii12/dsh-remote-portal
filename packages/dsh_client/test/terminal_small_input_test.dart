import 'dart:async';
import 'dart:convert';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/fake_dsh.dart';

void main() {
  for (final (cap, text, fits) in [
    (1, 'A', true),
    (1, 'é', false),
    (2, 'é', true),
    (2, '中', false),
    (3, '中', true),
    (3, '🙂', false),
    (3, 'A🙂', false),
    (4, '🙂', true),
  ]) {
    test('public loopback attachment maxInputBytes=$cap input=$text', () async {
      final host = await FakeDsh.start();
      addTearDown(host.close);
      host.handlers['terminal/environment'] = (_) => {
        'ok': true,
        'value': {'maxInputBytes': cap},
      };
      late FakeMuxSocket socket;
      host.onOpen = (s, id, endpoint, payload) {
        socket = s;
        if (endpoint == 'terminal/attach') {
          s.item(id, {
            'type': 'snapshot',
            'sequence': 1,
            'screen': '',
            'writable': true,
            'inputWindow': {'maxBytes': 262144, 'frameOverheadBytes': 74},
            'info': {
              'id': 't1',
              'shell': {
                'path': '/bin/bash',
                'name': 'bash',
                'args': ['-i'],
              },
              'title': 'local fixture',
              'cwd': '/own',
              'cols': 80,
              'rows': 24,
              'state': 'running',
              'exitCode': null,
            },
          });
        }
        if (endpoint == 'terminal/retain') s.item(id, {'type': 'retained'});
      };
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
      addTearDown(client.close);
      final environment = await client.terminalEnvironment('s1');
      expect(environment.maxInputBytes, cap);
      final attachment = client.attachTerminal('s1', 't1', environment: environment);
      addTearDown(attachment.close);
      final ready = Completer<void>();
      final errors = <Object>[];
      final sub = attachment.frames.listen((frame) {
        if (frame is TerminalSnapshot && !ready.isCompleted) ready.complete();
      }, onError: errors.add);
      addTearDown(sub.cancel);
      await ready.future;
      final accepted = attachment.write(text);
      // A later public stream open on the same native WebSocket is an ordered
      // barrier: all earlier uplink frames were handled before this reply.
      await client.retainTerminal('s1', 't1').first;
      final commands = [
        for (final frame in socket.received)
          if (frame['type'] == 'item') (frame['value']! as Map).cast<String, Object?>(),
      ];
      print(
        jsonEncode({
          'cap': cap,
          'accepted': accepted,
          'commands': commands,
          'bytes': [for (final command in commands) utf8.encode(command['data']! as String).length],
        }),
      );
      if (!fits) {
        expect(accepted, isFalse);
        expect(commands, isEmpty);
        expect(errors.single, isA<TerminalStreamException>().having((e) => e.issue, 'issue', 'inputFull'));
      } else {
        expect(accepted, isTrue);
        expect(commands.single['data'], text);
        expect(utf8.encode(commands.single['data']! as String).length, lessThanOrEqualTo(cap));
        expect(errors, isEmpty);
      }
    });
  }
}
