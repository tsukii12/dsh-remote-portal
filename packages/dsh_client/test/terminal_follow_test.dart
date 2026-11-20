// The follow route for carriers without uplink items (ds-harness-remote):
// `terminal/follow` bound to an attachment id plus unary `terminal/write` /
// `terminal/resize`, which the Host plugin joins into the official attach.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

Map<String, Object?> infoJson({String? controllerId, String state = 'running'}) => {
  'id': 't1',
  'shell': {'path': '/bin/bash', 'name': 'bash', 'args': <String>[]},
  'title': 'bash',
  'cwd': '/root/work',
  'cols': 80,
  'rows': 24,
  'state': state,
  'exitCode': null,
  'controllerId': ?controllerId,
};

/// The Host's follow frames: the plugin forwards the official attach frames
/// and stamps `info.controllerId` on the attachment holding input.
Map<String, Object?> snapshotJson({String? controllerId}) => {
  'type': 'snapshot',
  'sequence': 1,
  'screen': r'$ ',
  'info': infoJson(controllerId: controllerId),
  // The official attach value for the Host's own attachment, not ours.
  'writable': true,
  'inputWindow': {'maxBytes': 262144, 'frameOverheadBytes': 74},
};

void main() {
  late FakeDsh host;
  late FakeMuxSocket socket;
  late String followId;
  late Map<String, Object?> followArgs;
  var followOpened = false;
  final writes = <Map<String, Object?>>[];

  setUp(() async {
    host = await FakeDsh.start();
    writes.clear();
    followOpened = false;
    host.handlers
      ..['terminal/write'] = (args) {
        writes.add({'endpoint': 'terminal/write', ...args});
        return ok(null);
      }
      ..['terminal/resize'] = (args) {
        writes.add({'endpoint': 'terminal/resize', ...args});
        return ok(null);
      };
    host.onOpen = (s, streamId, endpoint, payload) {
      if (endpoint != 'terminal/follow') return;
      socket = s;
      followId = streamId;
      followArgs = (payload['args']! as Map).cast<String, Object?>();
      followOpened = true;
    };
  });
  tearDown(() async => host.close());

  Future<DshClient> connect({Set<String> refused = const {}, Set<String>? capabilities}) async {
    final local = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
    addTearDown(local.close);
    final client = DshClient.withCarrier(_Tunnel(local.carrier, refused, capabilities));
    addTearDown(client.close);
    return client;
  }

  /// Attaches and plays the snapshot; [controlled] says whether the Host gave
  /// this attachment input control.
  Future<(TerminalAttachment, List<TerminalFrame>, List<Object>)> attach(
    DshClient client, {
    bool controlled = true,
    TerminalEnvironment environment = TerminalEnvironment.defaults,
  }) async {
    final attachment = client.attachTerminal('s1', 't1', environment: environment);
    final frames = <TerminalFrame>[];
    final errors = <Object>[];
    attachment.frames.listen(frames.add, onError: errors.add);
    await _until(() => followOpened);
    socket.item(followId, snapshotJson(controllerId: controlled ? followArgs['attachmentId'] as String : 'someone'));
    await _until(() => frames.isNotEmpty);
    return (attachment, frames, errors);
  }

  test('a carrier without uplink runs terminals when it allows follow, write and resize', () async {
    expect((await connect()).supportsTerminals, isTrue);
    expect((await connect(refused: {'terminal/follow'})).supportsTerminals, isFalse);
    expect((await connect(refused: {'terminal/resize'})).supportsTerminals, isFalse);
  });

  test('a Host that announced its features without harness.terminal.v1 has the terminal off', () async {
    final off = await connect(capabilities: {'harness.remote.v3', 'workspace.upload.v1'});
    expect(
      (off.supportsTerminals, off.terminalsOffOnHost),
      (true, true),
      reason: 'still tried: the switch applies live',
    );
    final on = await connect(capabilities: {'harness.remote.v3', 'harness.terminal.v1'});
    expect(on.terminalsOffOnHost, isFalse);
    expect((await connect()).terminalsOffOnHost, isFalse, reason: 'no probe: the allow-list decides');
  });

  test('follow carries a fresh attachment id; input goes as unary calls bound to it, acked in order', () async {
    final client = await connect();
    final (attachment, frames, errors) = await attach(client);
    expect(followArgs['agentId'], 's1');
    expect(followArgs['id'], 't1');
    expect(followArgs['attachmentId'], matches(RegExp(r'^[A-Za-z0-9_:-]{1,256}$')));
    expect(attachment.writable, isTrue, reason: 'info.controllerId names this attachment');

    expect(attachment.write('ls\r'), isTrue);
    await _until(() => frames.whereType<TerminalAck>().length == 1);
    expect(attachment.resize(100, 30), isTrue);
    await _until(() => frames.whereType<TerminalAck>().length == 2);

    final target = {'agentId': 's1', 'id': 't1', 'attachmentId': followArgs['attachmentId']};
    expect(writes, [
      {'endpoint': 'terminal/write', ...target, 'data': 'ls\r'},
      {'endpoint': 'terminal/resize', ...target, 'cols': 100, 'rows': 30},
    ]);
    expect(frames.whereType<TerminalAck>().map((a) => (a.sequence, a.refusal)), [(1, null), (2, null)]);
    expect(errors, isEmpty);
    expect(socket.received.where((f) => f['type'] == 'item'), isEmpty, reason: 'nothing goes up the stream');

    await attachment.close();
    await _until(() => socket.received.any((f) => f['type'] == 'cancel' && f['streamId'] == followId));
  });

  test('another attachment holding input leaves this one read-only', () async {
    final client = await connect();
    final (attachment, _, _) = await attach(client, controlled: false);
    expect(attachment.writable, isFalse, reason: 'the official writable flag is not ours');
    expect(attachment.write('x'), isFalse);
    await pumpEventQueue();
    expect(writes, isEmpty);
  });

  test('a state frame moving control away ends input', () async {
    final client = await connect();
    final (attachment, frames, _) = await attach(client);
    socket.item(followId, {'type': 'state', 'info': infoJson(controllerId: 'someone'), 'writable': true});
    await _until(() => frames.length == 2);
    expect(attachment.writable, isFalse);
  });

  test('keys typed while a write is in flight go out together', () async {
    final client = await connect();
    final (attachment, frames, _) = await attach(client);
    final gate = Completer<void>();
    var held = false;
    host.beforeRpc = (endpoint, args) async {
      if (held) return;
      held = true;
      await gate.future;
    };
    expect(attachment.write('a'), isTrue);
    await _until(() => held);
    expect(attachment.write('b'), isTrue);
    expect(attachment.write('c'), isTrue);
    gate.complete();
    await _until(() => frames.whereType<TerminalAck>().length == 3);
    expect(writes.map((w) => w['data']), ['a', 'bc']);
    expect(frames.whereType<TerminalAck>().map((a) => a.sequence), [1, 2, 3]);
  });

  test('coalesced keys stay within the Host per-write byte budget', () async {
    final client = await connect();
    final (attachment, frames, _) = await attach(client, environment: const TerminalEnvironment(maxInputBytes: 3));
    final gate = Completer<void>();
    var held = false;
    host.beforeRpc = (endpoint, args) async {
      if (held) return;
      held = true;
      await gate.future;
    };
    expect(attachment.write('a'), isTrue);
    await _until(() => held);
    expect(attachment.write('bc'), isTrue);
    expect(attachment.write('de'), isTrue);
    gate.complete();
    await _until(() => frames.whereType<TerminalAck>().length == 3);
    expect(writes.map((w) => w['data']), ['a', 'bc', 'de'], reason: '"bcde" would be 4 bytes > 3');
  });

  test('a refused call fails the attachment and is never replayed', () async {
    final client = await connect();
    host.handlers['terminal/write'] = (args) {
      writes.add(args);
      return {
        'ok': false,
        'error': {'code': 'PERMISSION_DENIED', 'message': 'not writable', 'details': <String, Object?>{}},
      };
    };
    final (attachment, _, errors) = await attach(client);
    expect(attachment.write('rm -rf build\r'), isTrue);
    await _until(() => errors.isNotEmpty);
    expect(errors.single, isA<DshRemoteException>().having((e) => e.code, 'code', 'PERMISSION_DENIED'));
    expect(attachment.isClosed, isTrue);
    await _until(() => socket.received.any((f) => f['type'] == 'cancel' && f['streamId'] == followId));
    await pumpEventQueue();
    expect(writes, hasLength(1));
  });

  test('Host acks on the follow stream are not ours and are dropped', () async {
    final client = await connect();
    final (attachment, frames, errors) = await attach(client);
    socket.item(followId, {'type': 'ack', 'sequence': 1});
    socket.item(followId, {'type': 'output', 'sequence': 2, 'data': 'hi'});
    await _until(() => frames.length == 2);
    expect(frames.last, isA<TerminalOutput>());
    expect(errors, isEmpty);
    expect(attachment.writable, isTrue);
  });
}

/// The local carrier as the ds-harness-remote tunnel looks: no uplink items,
/// a fixed allow-list.
class _Tunnel extends DshCarrier {
  _Tunnel(this.inner, this.refused, this.capabilities);

  final DshCarrier inner;
  final Set<String> refused;
  final Set<String>? capabilities;

  @override
  Set<String>? get peerCapabilities => capabilities;

  @override
  String get kind => 'tunnel-like';

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  bool allowsEndpoint(String endpoint) => !refused.contains(endpoint);

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      inner.call(endpoint, args, timeout: timeout);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => inner.openLink(options);

  @override
  Future<void> close() async {}
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
