import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/support/zip_reader.dart';

const _session = 'SYNTHETIC_SESSION_PRIVATE';
const _text = 'SYNTHETIC_PROMPT_PRIVATE';
const _ssh = HostRef.portal('SYNTHETIC_HOST_SSH_PRIVATE');
const _relay = HostRef.portal('SYNTHETIC_HOST_RELAY_PRIVATE', name: 'SYNTHETIC_RELAY_NAME_PRIVATE');
const _writerHeld = DshRemoteException(
  'session/writer-held',
  'SYNTHETIC_MESSAGE_PRIVATE token=SYNTHETIC_TOKEN_PRIVATE',
  {'owner': 'SYNTHETIC_OWNER_PRIVATE', 'path': '/SYNTHETIC_PATH_PRIVATE'},
);
const _imagesRefused = DshRemoteException('session/attachment-invalid', 'SYNTHETIC_IMAGE_REFUSAL_PRIVATE', {
  'reason': 'MODEL_DOES_NOT_SUPPORT_IMAGES',
});

class _PeerTable extends Notifier<Map<HostRef, _Peer>> {
  _PeerTable(this.initial);
  final Map<HostRef, _Peer> initial;
  @override
  Map<HostRef, _Peer> build() => initial;
  void replace(HostRef host, _Peer peer) => state = {...state, host: peer};
}

final _peers = NotifierProvider<_PeerTable, Map<HostRef, _Peer>>(() => _PeerTable(const {}));

// The transport supplies RPC results and mux frames. DshClient, its real
// watch/follow epochs, ChatController and the diagnostic collector are real.
class _Carrier extends DshCarrier {
  final calls = <(String, Map<String, Object?>)>[];
  final links = <_Link>[];
  final follows = <(_Link, String)>[];
  Object? promptError;
  Object? uploadError;
  Completer<RpcResult>? promptGate;
  bool rejectImages = false;
  bool autoReady = true;
  bool autoSnapshot = true;
  int seq = -1;

  List<Map<String, Object?>> argsOf(String endpoint) => [
    for (final (name, args) in calls)
      if (name == endpoint) args,
  ];
  List<Map> get prompts => [for (final args in argsOf('session/prompt')) args['request']! as Map];

  @override
  String get kind => 'SYNTHETIC_CARRIER_PRIVATE';
  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    switch (endpoint) {
      case 'session/prompt':
        final request = args['request']! as Map;
        final content = request['content']! as List;
        if (rejectImages && content.any((part) => (part as Map)['type'] == 'image')) {
          return const RpcError(_imagesRefused);
        }
        if (promptGate case final gate?) return gate.future;
        if (promptError case final error?) {
          if (error is DshRemoteException) return RpcError(error);
          throw error;
        }
        return const RpcOk(null);
      case 'fileUploads/upload':
        if (uploadError case final error?) {
          if (error is DshRemoteException) return RpcError(error);
          throw error;
        }
        return const RpcOk({
          'receiptId': 'SYNTHETIC_RECEIPT_PRIVATE',
          'file': {'name': 'SYNTHETIC_FILE_PRIVATE', 'bytes': 4},
        });
      case 'session/projections':
        return const RpcOk(null);
      default:
        throw StateError('unexpected fixture endpoint $endpoint');
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link(this);
    links.add(link);
    return link;
  }

  void emit(String type, Map<String, Object?> data) {
    final (link, id) = follows.last;
    link.item(id, {
      'type': 'event',
      'event': {'seq': ++seq, 'time': 1800000000000 + seq, 'type': type, 'data': data},
    });
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  _Link(this.carrier);
  final _Carrier carrier;
  late DshMuxFrameHandler _onFrame;
  late DshMuxLossHandler _onLost;
  String? _eventsId;
  final cancelled = <String>{};
  bool closed = false;

  void item(String id, Object? value) {
    if (!closed && !cancelled.contains(id)) _onFrame({'type': 'item', 'streamId': id, 'value': value});
  }

  void end(String id) {
    if (!closed && !cancelled.contains(id)) _onFrame({'type': 'end', 'streamId': id});
  }

  void lose() {
    if (closed) return;
    closed = true;
    _onLost(const DshCarrierLostException('SYNTHETIC_LINK_LOSS_PRIVATE'), null);
  }

  void ready() => item(_eventsId!, {
    'type': 'ready',
    'clientId': 'SYNTHETIC_CLIENT_PRIVATE',
    'host': {'home': '/SYNTHETIC_HOME_PRIVATE'},
  });

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _onLost = onLost;
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      _eventsId = streamId;
      if (carrier.autoReady) scheduleMicrotask(ready);
      return;
    }
    if (endpoint != 'session/follow') throw StateError('unexpected fixture stream $endpoint');
    carrier.follows.add((this, streamId));
    if (!carrier.autoSnapshot) return;
    scheduleMicrotask(
      () => item(streamId, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': _session, 'createdAt': 1800000000000, 'cwd': '/SYNTHETIC_CWD_PRIVATE'},
        'cursor': -1,
        'records': <Object?>[],
        'hasMore': false,
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
      }),
    );
  }

  @override
  void cancel(String streamId) => cancelled.add(streamId);
  @override
  void sendItem(String streamId, Object? value) => throw StateError('no uplink in fixture');
  @override
  void endUplink(String streamId) => throw StateError('no uplink in fixture');
  @override
  Future<void> close(int code, String reason) async => closed = true;
}

class _Peer {
  _Peer(this.host) {
    client = DshClient.withCarrier(carrier, muxOptions: const MuxOptions(autoReconnect: false));
  }
  final HostRef host;
  final carrier = _Carrier();
  late final DshClient client;
  HostConnection get connection => HostConnection(
    client: client,
    label: 'SYNTHETIC_LABEL_PRIVATE',
    isLocal: host.isLocal,
    kind: host.kind,
    hostId: host.id,
    name: 'SYNTHETIC_HOST_NAME_PRIVATE',
    workingDirectory: '/SYNTHETIC_WORKDIR_PRIVATE',
  );
}

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState(loaded: true);
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

class _Bridge extends RuntimeBridge {
  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
  @override
  Future<List<String>> logs({int lines = 500}) async => const [];
  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async => const RuntimeLogSnapshot([], 0);
}

class _Diagnostics extends DiagnosticsChannel {
  @override
  Future<NativeDiagnostics> info() async => const NativeDiagnostics();
  @override
  Future<List<String>> engineLog({int maxBytes = 512 * 1024}) async => const [];
}

class _Phone extends PhoneChannel {
  @override
  Future<PhoneStatus> status() async => const PhoneStatus.notReady();
}

class _Voice extends VoiceSettingsController {
  @override
  VoiceMode build() => VoiceMode.auto;
  @override
  Future<VoiceMode> ready() async => VoiceMode.auto;
}

class _Usage extends UsageStatsController {
  final counted = <UsageCount>[];
  @override
  UsageStatsState build() => const UsageStatsState(loaded: true, enabled: false);
  @override
  void count(UsageCount count) => counted.add(count);
}

class _Reads {
  int connections = 0;
  int links = 0;
}

class _Harness {
  _Harness(this.container, this.peers, this.reads);
  final ProviderContainer container;
  final Map<HostRef, _Peer> peers;
  final _Reads reads;
  final extraPeers = <_Peer>[];
  bool disposed = false;
  ChatController get chat => container.read(chatProvider(_session).notifier);
  ChatState get state => container.read(chatProvider(_session));
  _Peer get peer => container.read(_peers)[container.read(activeHostProvider)]!;
  List<UsageCount> get counts => (container.read(usageStatsProvider.notifier) as _Usage).counted;

  static Future<_Harness> start(WidgetTester tester, {HostRef selected = _ssh, bool initialSnapshot = true}) async {
    final peers = {
      for (final host in [HostRef.none, _ssh, _relay]) host: _Peer(host),
    };
    for (final peer in peers.values) {
      peer.carrier.autoSnapshot = initialSnapshot;
      await peer.client.mux.ready();
    }
    final reads = _Reads();
    final container = ProviderContainer(
      overrides: [
        _peers.overrideWith(() => _PeerTable(peers)),
        activeConnectionProvider.overrideWith((ref) {
          reads.connections++;
          final host = ref.watch(activeHostProvider);
          return AsyncData<HostConnection?>(ref.watch(_peers)[host]?.connection);
        }),
        hostLinkProvider.overrideWith((ref, host) {
          reads.links++;
          throw StateError('diagnostics must not open an unobserved link');
        }),
        localRuntimeProvider.overrideWith(_Runtime.new),
        settingsProvider.overrideWith(_Settings.new),
        runtimeBridgeProvider.overrideWithValue(_Bridge()),
        diagnosticsChannelProvider.overrideWithValue(_Diagnostics()),
        phoneChannelProvider.overrideWithValue(_Phone()),
        voiceSettingsProvider.overrideWith(_Voice.new),
        usageStatsProvider.overrideWith(_Usage.new),
      ],
    );
    final h = _Harness(container, peers, reads);
    container.read(activeHostProvider.notifier).select(selected);
    container.listen(chatProvider(_session), (_, _) {});
    addTearDown(h.closeClients);
    await h.flush(tester);
    expect(h.peer.carrier.follows, hasLength(1));
    expect(h.peer.client.mux.generation, isNotNull);
    expect(h.state.controlReady, initialSnapshot);
    return h;
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  Future<void> closeClients() async {
    dispose();
    for (final peer in [...peers.values, ...extraPeers]) {
      final gate = peer.carrier.promptGate;
      if (gate != null && !gate.isCompleted) gate.complete(const RpcOk(null));
      await peer.client.close();
    }
  }
}

Set<AppErrorRecord> _before() => Set<AppErrorRecord>.identity()..addAll(appErrorLog.snapshot());
List<AppErrorRecord> _added(Set<AppErrorRecord> before) => [
  for (final record in appErrorLog.snapshot())
    if (!before.contains(record) && record.message.startsWith('chat_send_failure ')) record,
];

AppErrorRecord _failure(
  Set<AppErrorRecord> before, {
  String stage = 'prompt',
  String host = 'ssh',
  required String category,
  bool unknown = false,
}) {
  final records = _added(before);
  expect(records, hasLength(1));
  final record = records.single;
  expect(record.source, AppErrorSource.session);
  expect(record.message, 'chat_send_failure stage=$stage host=$host category=$category outcome_unknown=$unknown');
  expect(record.stack, isEmpty);
  expect(record.message, isNot(contains('SYNTHETIC_')));
  return record;
}

DraftAttachment _file() => DraftAttachment.sniff('SYNTHETIC_FILE_PRIVATE.md', Uint8List.fromList(_text.codeUnits));
DraftAttachment _image() => DraftAttachment.sniff(
  'SYNTHETIC_IMAGE_PRIVATE.png',
  base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC'),
);
Map<String, Object?> _message(String requestId) => {
  'id': 'SYNTHETIC_MESSAGE_ID_PRIVATE',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': _text},
  ],
  'source': {'kind': 'user', 'rpcId': requestId},
};

class _PrivateError implements Exception {
  int stringReads = 0;
  @override
  String toString() {
    stringReads++;
    return 'SYNTHETIC_CUSTOM_ERROR_PRIVATE';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final host in [HostRef.none, _ssh, _relay]) {
    testWidgets('current ${host.kind.name} writer-held records a safe failure without a watch error', (tester) async {
      final h = await _Harness.start(tester, selected: host);
      h.peer.carrier.promptError = _writerHeld;
      final before = _before();
      expect(await h.chat.send(_text), isFalse);
      expect(h.peer.carrier.prompts, hasLength(1));
      expect(h.state.pending, isEmpty);
      expect(h.state.error, appL10n.stateActionReason(appL10n.stateSendFailed, appL10n.stateChatWriterHeld));
      expect(h.counts, isEmpty);
      final record = _failure(before, host: host.kind.name, category: 'session_writer_held');

      if (host == _ssh) {
        final reads = h.reads.connections;
        final links = h.peers.values.fold<int>(0, (total, peer) => total + peer.carrier.links.length);
        final snapshot = await h.container.read(Provider((ref) => collectDiagnostics(ref, DateTime.utc(2026, 11, 5))));
        expect(snapshot.appErrors, contains(same(record)));
        expect(snapshot.engineLog, isEmpty);
        expect(h.reads.connections, reads);
        expect(h.reads.links, 0);
        expect(h.peers.values.fold<int>(0, (total, peer) => total + peer.carrier.links.length), links);
        final entries = {
          for (final entry in readZip(DiagnosticsBundle.build(snapshot))) entry.name: utf8.decode(entry.data),
        };
        final exported = jsonDecode(entries['app-errors.json']!) as List;
        expect(exported.any((entry) => (entry as Map)['message'] == record.message), isTrue);
        expect(entries.values.join('\n'), isNot(contains('SYNTHETIC_')));
        expect(entries.values.join('\n'), isNot(contains(h.peer.carrier.prompts.single['requestId'])));
      }
    });
  }

  testWidgets('arbitrary remote code, message and nested details are not copied into the log', (tester) async {
    final h = await _Harness.start(tester);
    h.peer.carrier.promptError = const DshRemoteException('SYNTHETIC_CODE_PRIVATE', 'SYNTHETIC_MESSAGE_PRIVATE', {
      'nested': {'prompt': _text, 'path': '/SYNTHETIC_PATH_PRIVATE'},
    });
    final before = _before();
    expect(await h.chat.send(_text), isFalse);
    _failure(before, category: 'remote_other');
    expect(h.state.error, appL10n.stateSendFailed);
    expect(h.peer.carrier.prompts, hasLength(1));
  });

  testWidgets('unknown custom errors do not acquire another toString read for diagnostics', (tester) async {
    final h = await _Harness.start(tester);
    final error = _PrivateError();
    h.peer.carrier.promptError = error;
    final before = _before();
    expect(await h.chat.send(_text), isFalse);
    _failure(before, category: 'unknown');
    expect(error.stringReads, 1, reason: 'the existing chatErrorText debugPrint remains the only conversion');
    expect(h.state.error, appL10n.stateSendFailed);
  });

  for (final sample in <(Object, String)>[
    (const DshHttpException(403, 'SYNTHETIC_HTTP_PRIVATE', body: 'SYNTHETIC_BODY_PRIVATE'), 'http'),
    (const DshProtocolException('SYNTHETIC_PROTOCOL_PRIVATE'), 'protocol'),
    (const DshCarrierRefusedException('SYNTHETIC_REASON_PRIVATE', 'SYNTHETIC_REFUSAL_PRIVATE'), 'carrier_refused'),
    (const DshClosedException('SYNTHETIC_CLOSED_PRIVATE'), 'closed'),
  ]) {
    testWidgets('typed ${sample.$2} failure keeps free text out of diagnostics', (tester) async {
      final h = await _Harness.start(tester);
      h.peer.carrier.promptError = sample.$1;
      final before = _before();
      expect(await h.chat.send(_text), isFalse);
      _failure(before, category: sample.$2);
      expect(h.state.pending, isEmpty);
      expect(h.state.error, isNot(contains('SYNTHETIC_')));
      expect(h.peer.carrier.prompts, hasLength(1));
      expect(h.counts, isEmpty);
    });
  }

  for (final sample in <(Object, String)>[
    (const DshTransportException('SYNTHETIC_TRANSPORT_PRIVATE'), 'transport'),
    (const DshCarrierLostException('SYNTHETIC_CARRIER_PRIVATE'), 'carrier_lost'),
  ]) {
    testWidgets('${sample.$2} outcome stays unknown and explicit retry keeps the request ID', (tester) async {
      final h = await _Harness.start(tester);
      h.peer.carrier.promptError = sample.$1;
      final before = _before();
      expect(await h.chat.send(_text), isFalse);
      final first = h.peer.carrier.prompts.single['requestId'];
      _failure(before, category: sample.$2, unknown: true);
      expect(h.counts, isEmpty);
      h.peer.carrier.promptError = null;
      expect(await h.chat.send(_text), isTrue);
      expect(h.peer.carrier.prompts.map((request) => request['requestId']), [first, first]);
      expect(h.counts, [UsageCount.turns]);
      expect(_added(before), hasLength(1), reason: 'the successful retry is not another failure');
      expect(await h.chat.send(_text), isTrue);
      expect(h.peer.carrier.prompts.last['requestId'], isNot(first));
      expect(h.counts, [UsageCount.turns, UsageCount.turns]);
    });
  }

  testWidgets('initial attachment upload failure is not a prompt failure', (tester) async {
    final h = await _Harness.start(tester);
    h.peer.carrier.uploadError = const DshRemoteException('UPLOAD_LIMIT', 'SYNTHETIC_UPLOAD_PRIVATE');
    final before = _before();
    expect(await h.chat.send(_text, attachments: [_file()]), isFalse);
    expect(h.peer.carrier.argsOf('fileUploads/upload'), hasLength(1));
    expect(h.peer.carrier.prompts, isEmpty);
    expect(h.state.pending, isEmpty);
    expect(
      h.state.error,
      appL10n.stateActionReason(appL10n.stateAttachmentUploadFailed, appL10n.stateRemoteUploadLimit),
    );
    _failure(before, stage: 'attachment_upload', category: 'remote_other');
  });

  testWidgets('failed image fallback upload reports its own unknown stage', (tester) async {
    final h = await _Harness.start(tester);
    h.peer.carrier.rejectImages = true;
    h.peer.carrier.uploadError = const DshTransportException('SYNTHETIC_FALLBACK_PRIVATE');
    final before = _before();
    expect(await h.chat.send(_text, attachments: [_image()]), isFalse);
    expect(h.peer.carrier.prompts, hasLength(1));
    expect(h.peer.carrier.argsOf('fileUploads/upload'), hasLength(1));
    expect(h.state.pending, isEmpty);
    _failure(before, stage: 'attachment_upload', category: 'transport', unknown: true);
  });

  testWidgets('successful image fallback retains both prompt calls and emits no failure', (tester) async {
    final h = await _Harness.start(tester);
    h.peer.carrier.rejectImages = true;
    final before = _before();
    expect(await h.chat.send(_text, attachments: [_image()]), isTrue);
    expect(h.peer.carrier.prompts, hasLength(2));
    expect(h.peer.carrier.prompts.last['requestId'], h.peer.carrier.prompts.first['requestId']);
    expect(h.peer.carrier.argsOf('fileUploads/upload'), hasLength(1));
    expect(h.state.notice, appL10n.stateChatTextOnlyModel);
    expect(h.state.error, isNull);
    expect(h.counts, [UsageCount.turns]);
    expect(_added(before), isEmpty);
  });

  testWidgets('empty input and normal success keep their original results and logging', (tester) async {
    final h = await _Harness.start(tester);
    final before = _before();
    expect(await h.chat.send('  '), isFalse);
    expect(h.peer.carrier.prompts, isEmpty);
    expect(await h.chat.send(_text), isTrue);
    expect(h.peer.carrier.prompts, hasLength(1));
    expect(h.state.pending, hasLength(1));
    expect(h.state.error, isNull);
    expect(h.counts, [UsageCount.turns]);
    expect(_added(before), isEmpty);
  });

  testWidgets('unsynchronized refusal and virtual sync deadline do not invent RPC failures', (tester) async {
    final h = await _Harness.start(tester, initialSnapshot: false);
    final before = _before();
    expect(await h.chat.send(_text, mode: SendMode.interrupt), isFalse);
    final pending = h.chat.send(_text);
    await tester.pump();
    expect(h.peer.carrier.prompts, isEmpty);
    await tester.pump(const Duration(seconds: 10));
    expect(await pending, isFalse);
    expect(h.peer.carrier.prompts, isEmpty);
    expect(h.state.notice, appL10n.stateChatSyncRequired);
    expect(_added(before), isEmpty);
  });

  for (final feedback in ['echo', 'inbox', 'claim', 'withdrawn', 'failed_pending', 'completed']) {
    testWidgets('durable $feedback before a late RPC error keeps accepted semantics', (tester) async {
      final h = await _Harness.start(tester);
      final gate = h.peer.carrier.promptGate = Completer<RpcResult>();
      final before = _before();
      final result = h.chat.send(_text);
      await h.flush(tester);
      final id = h.peer.carrier.prompts.single['requestId']! as String;
      expect(h.state.pending.single.requestId, id);
      if (feedback == 'echo') {
        h.peer.carrier.emit('user/message', _message(id));
      } else {
        h.peer.carrier.emit('agent/inbox/spliced', {
          'target': 'next-turn',
          'start': 0,
          'removedCount': 0,
          'inserted': [_message(id)],
        });
        if (feedback != 'inbox') {
          h.peer.carrier.emit('turn/start', {'turn': 1});
          h.peer.carrier.emit('agent/inbox/spliced', {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 1,
            'inserted': <Object?>[],
            if (feedback == 'withdrawn') 'outcome': 'canceled',
          });
          if (feedback == 'failed_pending' || feedback == 'completed') {
            h.peer.carrier.emit('turn/end', {
              'turn': 1,
              'reason': {'kind': feedback == 'failed_pending' ? 'error' : 'completed'},
            });
          }
        }
      }
      await h.flush(tester);
      if (feedback == 'failed_pending') expect(h.state.pending.single.failed, isTrue);
      gate.completeError(const DshCarrierLostException('SYNTHETIC_LATE_REPLY_PRIVATE'));
      expect(await result, isTrue);
      expect(h.peer.carrier.prompts, hasLength(1));
      expect(h.counts, [UsageCount.turns]);
      expect(_added(before), isEmpty, reason: 'accepted does not mean the agent completed successfully');
      if (feedback == 'failed_pending') {
        expect(h.state.pending.single.requestId, id);
        expect(h.state.pending.single.failed, isTrue, reason: 'keep the existing recovery card');
      }
    });
  }

  for (final change in [
    'host',
    'host_aba_no_frame',
    'replacement_client',
    'new_generation',
    'follow_retired',
    'invalidate',
    'dispose',
  ]) {
    testWidgets('late error after $change cannot add a current send failure', (tester) async {
      final h = await _Harness.start(tester);
      final old = h.peer;
      final generation = old.client.mux.generation;
      final gate = old.carrier.promptGate = Completer<RpcResult>();
      final before = _before();
      final result = h.chat.send(_text);
      await h.flush(tester);
      expect(old.carrier.prompts, hasLength(1));
      switch (change) {
        case 'host':
          h.container.read(activeHostProvider.notifier).select(_relay);
          await h.flush(tester);
          expect(h.state.controlReady, isTrue);
        case 'host_aba_no_frame':
          final selected = h.container.read(activeHostProvider.notifier);
          selected.select(_relay);
          selected.select(_ssh);
        // No intervening read, pump, or microtask drain before resolving A.
        case 'replacement_client':
          final replacement = _Peer(_ssh);
          h.extraPeers.add(replacement);
          await replacement.client.mux.ready();
          h.container.read(_peers.notifier).replace(_ssh, replacement);
          await h.flush(tester);
          expect(h.container.read(activeConnectionProvider).value?.client, same(replacement.client));
          expect(h.state.controlReady, isTrue);
        case 'new_generation':
          old.carrier.autoReady = false;
          old.carrier.links.last.lose();
          await h.flush(tester);
          expect(old.client.mux.generation, isNull);
          expect(h.state.controlReady, isFalse);
          // The real follow can request a reconnect even with mux automatic
          // backoff disabled. Hold and release only its ready wire frame.
          old.carrier.links.last.ready();
          await old.client.mux.start();
          await h.flush(tester);
          expect(old.client.mux.generation, isNot(same(generation)));
          expect(h.state.controlReady, isTrue);
        case 'follow_retired':
          old.carrier.autoSnapshot = false;
          final (link, stream) = old.carrier.follows.last;
          link.end(stream);
          await tester.pump();
          expect(old.client.mux.generation, same(generation));
          expect(h.state.controlReady, isFalse, reason: 'real SDK follow retirement without mux replacement');
        case 'invalidate':
          h.container.invalidate(chatProvider(_session));
          await h.flush(tester);
          expect(h.state.controlReady, isTrue);
        case 'dispose':
          h.dispose();
      }
      gate.completeError(_writerHeld);
      expect(await result, isFalse);
      if (!h.disposed) {
        await h.flush(tester);
        expect(h.state.error, isNull);
        expect(h.counts, isEmpty);
      }
      expect(_added(before), isEmpty);
      expect(old.carrier.prompts, hasLength(1));
      // End the real SDK timers before the widget binding checks invariants.
      await h.closeClients();
      await tester.pump();
    });
  }

  testWidgets('link loss without a replacement suppresses the late request diagnostic', (tester) async {
    final h = await _Harness.start(tester);
    final old = h.peer;
    final gate = old.carrier.promptGate = Completer<RpcResult>();
    final before = _before();
    final result = h.chat.send(_text);
    await h.flush(tester);
    old.carrier.autoReady = false;
    old.carrier.links.last.lose();
    await h.flush(tester);
    expect(old.client.mux.generation, isNull);
    expect(h.state.controlReady, isFalse);
    gate.completeError(_writerHeld);
    expect(await result, isFalse);
    expect(_added(before), isEmpty);
    await h.closeClients();
    await tester.pump();
  });

  testWidgets('a full 40-record ring still retains exactly the new safe send observation', (tester) async {
    final h = await _Harness.start(tester);
    for (var i = 0; i < 40; i++) {
      appErrorLog.record(AppErrorSource.platform, 'older controlled record $i', StackTrace.empty);
    }
    final snapshot = appErrorLog.snapshot();
    final before = _before();
    expect(snapshot, hasLength(40));
    h.peer.carrier.promptError = _writerHeld;
    expect(await h.chat.send(_text), isFalse);
    final record = _failure(before, category: 'session_writer_held');
    expect(appErrorLog.snapshot(), hasLength(40));
    expect(appErrorLog.snapshot().last, same(record));
    expect(appErrorLog.snapshot(), isNot(contains(same(snapshot.first))));
    expect(snapshot, hasLength(40), reason: 'the pre-send snapshot remains unchanged');
  });
}
