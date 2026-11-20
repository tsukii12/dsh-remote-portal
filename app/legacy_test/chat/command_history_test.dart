import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _event(int seq, String type, Map<String, Object?> data) => {
  'seq': seq,
  'time': 1792700000000 + seq,
  'type': type,
  'data': data,
};

class _Mux extends DshMux {
  _Mux(super.carrier);

  @override
  Stream<DshConnectionState> get states => const Stream.empty();
}

class _Client extends DshClient {
  _Client(this.kind) : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final String kind;
  late final _mux = _Mux(carrier);

  @override
  _Mux get mux => _mux;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => Stream.value(
    SessionSnapshotEvent.fromJson(sessionId, {
      'cursor': 3,
      'hasMore': true,
      'records': [
        {
          'type': 'event',
          'event': _event(2, 'command/done', {
            'commandId': 'finished',
            'kind': kind,
            'text': 'The command has finished.',
          }),
        },
        {
          'type': 'event',
          'event': _event(3, 'command/run', {'commandId': 'pending', 'name': 'compact'}),
        },
      ],
    }),
  );

  @override
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) async {
    expect(beforeSeq, 2);
    return HistoryPage([
      SessionLogEvent.fromJson(_event(1, 'command/run', {'commandId': 'finished', 'name': 'compact'})),
    ], false);
  }
}

void main() {
  for (final kind in ['success', 'error']) {
    testWidgets('older command keeps its loaded $kind result', (tester) async {
      final client = _Client(kind);
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(hostId: '', client: client, label: 'Local', isLocal: true)),
          ),
        ],
      );
      final sub = container.listen(chatProvider('s'), (_, _) {});
      addTearDown(() {
        sub.close();
        container.dispose();
      });
      await tester.pump(const Duration(milliseconds: 40));
      expect(sub.read().commands.map((c) => c.id), ['pending']);

      await container.read(chatProvider('s').notifier).loadOlder();

      final notices = sub.read().commands;
      expect(notices.map((c) => c.id), ['finished', 'pending']);
      expect(notices.first.done, isTrue);
      expect(notices.first.success, kind == 'success');
      expect(notices.first.text, 'The command has finished.');
      expect(notices.last.done, isFalse, reason: 'No terminal event was received for the other command.');
    });
  }
}
