import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Mux extends DshMux {
  _Mux(super.carrier);

  @override
  Stream<DshConnectionState> get states => const Stream.empty();
}

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final events = StreamController<DshEvent>.broadcast();
  final calls = <Completer<CommandResult>>[];
  late final _mux = _Mux(carrier);

  @override
  _Mux get mux => _mux;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<CommandResult> executeCommand(String sessionId, String line) {
    final result = Completer<CommandResult>();
    calls.add(result);
    return result.future;
  }
}

void main() {
  late _Client client;
  late ProviderContainer container;
  TestWidgetsFlutterBinding.ensureInitialized();
  var seq = 0;
  Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 60));
  ChatController chat() => container.read(chatProvider('s').notifier);
  List<CommandNotice> commands() => container.read(chatProvider('s')).commands;
  void emit(String type, String id, {String? kind}) => client.events.add(
    SessionLogEvent.fromJson({
      'seq': ++seq,
      'time': 1792700000000 + seq,
      'type': type,
      'data': {'commandId': id, 'name': 'compact', 'kind': ?kind},
    }),
  );

  setUp(() {
    seq = 0;
    client = _Client();
    container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(hostId: '', client: client, label: 'Local', isLocal: true)),
        ),
      ],
    );
    container.listen(chatProvider('s'), (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await client.events.close();
    client.close();
  });

  test('the durable command is shown once while execute is still waiting', () async {
    final running = chat().runCommand('/compact');
    emit('command/run', 'host-command');
    await flush();
    expect(commands().map((command) => command.id), ['host-command']);
    expect(commands().single.done, isFalse);

    emit('command/done', 'host-command', kind: 'success');
    await flush();
    expect(commands().single.done, isTrue);
    client.calls.single.complete(const CommandResult('host-command', true, 'Finished'));
    expect(await running, isTrue);
    expect(commands().map((command) => command.id), ['host-command']);
    expect(commands().single.text, 'Finished');
  });

  test('concurrent commands with identical text keep their distinct host ids', () async {
    final first = chat().runCommand('/compact');
    final second = chat().runCommand('/compact');
    emit('command/run', 'one');
    emit('command/run', 'two');
    await flush();
    expect(commands().map((command) => command.id), ['one', 'two']);
    client.calls[1].complete(const CommandResult('two', true, 'Second'));
    expect(await second, isTrue);
    client.calls[0].complete(const CommandResult('one', false, 'First failed'));
    expect(await first, isFalse);
    expect(commands().map((command) => command.id), ['one', 'two']);
    expect(commands().map((command) => command.success), [false, true]);
  });

  test('a result before the log remains finished when command/run arrives', () async {
    final running = chat().runCommand('/compact');
    client.calls.single.complete(const CommandResult('host-command', true, 'Finished'));
    await running;
    emit('command/run', 'host-command');
    await flush();
    expect(commands(), hasLength(1));
    expect(commands().single.done, isTrue);
    expect(commands().single.seq, 1);
  });

  test('admission failures without host ids still have an inline result', () async {
    final running = chat().runCommand('/unknown');
    client.calls.single.complete(const CommandResult(null, false, 'Unknown command'));
    expect(await running, isFalse);
    expect(commands(), hasLength(1));
    expect(commands().single.done, isTrue);
    expect(commands().single.text, 'Unknown command');
  });
}
