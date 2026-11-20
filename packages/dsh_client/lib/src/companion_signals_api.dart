/// Explicit metadata-only subscription: no replay, reconnect, history or follow.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'carrier.dart';
import 'companion_signals.dart';
import 'errors.dart';
import 'mux.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/signals';

final class CompanionSignalCapabilities {
  const CompanionSignalCapabilities._(this._owner, this.generation, this.available, this.reason);
  final DshClient _owner;
  final String generation;
  final bool available;
  final String? reason;
  bool isFor(DshClient client) => identical(client, _owner);
  bool get devicePowerAvailable => false;
  bool get notificationsAvailable => false;
  bool get replay => false;
  bool get counts => false;
  int get maxEventBytes => 1024;
}

/// Only the authenticated live transport in this library can mint this receipt.
/// Its authority expires as soon as the subscription, mux or consent retires.
final class CompanionRunReceipt {
  CompanionRunReceipt._(this._watch, this.envelope)
    : observedAt = DateTime.now().toUtc(),
      receivedMonotonicMs = companionMonotonicMs();
  final _RunWatch _watch;
  final CompanionRunEnvelope envelope;
  final DateTime observedAt;
  final int receivedMonotonicMs;
  int get ageMs => companionMonotonicMs() - receivedMonotonicMs;
  DshClient get client => _watch.client;
  MuxGeneration get muxGeneration => _watch.muxGeneration;
  CompanionSignalCapabilities get capability => _watch.capability;
  String get hostKey => _watch.hostKey;
  bool get current => _watch.current();

  /// Pure transport state, suitable after a reentrant caller predicate.
  bool get locallyCurrent => _watch._local() && _watch._ready;
  CompanionSignalV1 get signal => envelope.normalize(hostKey, observedAt);
}

extension CompanionSignalsApi on DshClient {
  Future<CompanionSignalCapabilities?> readCompanionSignalCapabilities({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) return null;
    final response = await transport.connection.getBounded(
      _path,
      maxBytes: 4096,
      autoUncompress: true,
      timeout: timeout,
    );
    Object? value;
    try {
      value = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      if (response.statusCode == 404 &&
          const {
            'Not Found',
            'Not found',
            'Not Found\n',
            'Not found\n',
          }.contains(utf8.decode(response.body, allowMalformed: true))) {
        return null;
      }
    }
    final error = value is Map ? value['error'] : null;
    if (response.statusCode == 404 && error is Map && error['code'] == 'companion/not-found') return null;
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, 'companion signal capabilities unavailable');
    }
    if (value is! Map ||
        !_keys(value, const [
          'v',
          'generation',
          'available',
          'reason',
          'kinds',
          'maxEventBytes',
          'replay',
          'counts',
          'devicePower',
          'notifications',
        ]) ||
        value['v'] != 1 ||
        !companionSignalUuid(value['generation']) ||
        value['available'] is! bool ||
        value['maxEventBytes'] != 1024 ||
        value['replay'] != false ||
        value['counts'] != false ||
        !_unavailable(value['devicePower']) ||
        !_unavailable(value['notifications'])) {
      _protocol();
    }
    final available = value['available'] as bool;
    final kinds = value['kinds'];
    final reason = value['reason'];
    if (kinds is! List ||
        (available
            ? kinds.length != 1 || kinds.single != 'run.result' || reason != null
            : kinds.isNotEmpty || !const {'engine-unavailable', 'producer-unavailable'}.contains(reason))) {
      _protocol();
    }
    return CompanionSignalCapabilities._(this, value['generation'] as String, available, reason as String?);
  }

  /// Capture an already-ready mux. Opening this stream never starts a mux or
  /// follows a session. Pause closes it; a fresh explicit subscription is needed.
  Stream<CompanionRunReceipt> watchCompanionRunSignals(
    CompanionSignalCapabilities capability, {
    required String hostKey,
    required bool Function() isAllowed,
  }) {
    final generation = mux.generation;
    if (!capability.isFor(this) ||
        !capability.available ||
        carrier is! DshHttpCarrier ||
        generation == null ||
        !companionSignalId(hostKey)) {
      throw ArgumentError('signal capability requires this ready client');
    }
    return _RunWatch(this, capability, generation, hostKey, isAllowed).stream;
  }
}

bool _keys(Map<Object?, Object?> value, List<String> expected) =>
    value.length == expected.length && expected.every(value.containsKey);
bool _unavailable(Object? value) => value is Map && _keys(value, const ['available']) && value['available'] == false;
Never _protocol() => throw const DshProtocolException('invalid companion signal stream');

final class _RunWatch {
  _RunWatch(this.client, this.capability, this.muxGeneration, this.hostKey, this.isAllowed) {
    _controller = StreamController<CompanionRunReceipt>(
      sync: true,
      onListen: () => unawaited(_start()),
      onCancel: _close,
      onPause: _close,
    );
  }
  final DshClient client;
  final CompanionSignalCapabilities capability;
  final MuxGeneration muxGeneration;
  final String hostKey;
  final bool Function() isAllowed;
  late final StreamController<CompanionRunReceipt> _controller;
  HttpClient? _http;
  StreamSubscription<Object?>? _states;
  Timer? _idle;
  bool _closed = false, _ready = false;
  Stream<CompanionRunReceipt> get stream => _controller.stream;
  bool _local() => !_closed && identical(client.mux.generation, muxGeneration);
  bool current() {
    if (!_local()) return false;
    bool allowed;
    try {
      allowed = isAllowed();
    } catch (_) {
      allowed = false;
    }
    // The predicate may synchronously cancel this very stream or swap the mux.
    if (!allowed || !_local()) {
      _close();
      return false;
    }
    return true;
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _ready = false;
    _idle?.cancel();
    _http?.close(force: true);
    unawaited(_states?.cancel());
    unawaited(
      Future<void>.microtask(() async {
        await _controller.close();
      }),
    );
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 45), _close);
  }

  Future<void> _start() async {
    try {
      if (!current()) return;
      _states = client.mux.states.listen((_) {
        if (!_local()) _close();
      });
      final connection = (client.carrier as DshHttpCarrier).connection;
      final http = _http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..autoUncompress = true;
      _touch();
      final request = await http.getUrl(connection.resolve('$_path/stream'));
      if (!current()) return;
      request.followRedirects = false;
      request.persistentConnection = false;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (connection.hostHeader != null) request.headers.set(HttpHeaders.hostHeader, connection.hostHeader!);
      if (connection.cookie != null) request.headers.set(HttpHeaders.cookieHeader, connection.cookie!.header);
      final response = await request.close();
      if (!current()) return;
      if (response.statusCode != 200 || response.headers.contentType?.mimeType != 'text/event-stream') {
        throw DshHttpException(response.statusCode, 'companion signal subscription refused');
      }
      var line = <int>[];
      String? eventName, data, id;
      var frameBytes = 0;
      void consumeLine() {
        if (!current()) return;
        if (line.isNotEmpty && line.last == 13) line.removeLast();
        final text = utf8.decode(line);
        line = <int>[];
        if (text.isEmpty) {
          if (eventName != null || data != null || id != null) {
            if (eventName == null || data == null || utf8.encode(data!).length > 1024) _protocol();
            final json = jsonDecode(data!);
            if (!_ready) {
              if (eventName != 'companion/ready' ||
                  id != null ||
                  json is! Map ||
                  !_keys(json, const ['v', 'generation']) ||
                  json['v'] != 1 ||
                  json['generation'] != capability.generation) {
                _protocol();
              }
              _ready = true;
            } else if (eventName == 'companion/unavailable') {
              if (json is! Map ||
                  !_keys(json, const ['v', 'generation', 'reason']) ||
                  json['v'] != 1 ||
                  json['generation'] != capability.generation ||
                  !const {'engine-unavailable', 'producer-unavailable'}.contains(json['reason'])) {
                _protocol();
              }
              _close();
            } else {
              if (eventName != 'companion/run-result') _protocol();
              final envelope = CompanionRunEnvelope.fromJson(json);
              if (id != envelope.id || envelope.generation != capability.generation) _protocol();
              if (current()) _controller.add(CompanionRunReceipt._(this, envelope));
            }
          }
          eventName = null;
          data = null;
          id = null;
          frameBytes = 0;
        } else if (!text.startsWith(':')) {
          final split = text.indexOf(':');
          if (split < 1) _protocol();
          final key = text.substring(0, split);
          var value = text.substring(split + 1);
          if (value.startsWith(' ')) value = value.substring(1);
          switch (key) {
            case 'event':
              if (eventName != null) _protocol();
              eventName = value;
            case 'data':
              if (data != null) _protocol();
              data = value;
            case 'id':
              if (id != null) _protocol();
              id = value;
            default:
              _protocol();
          }
        }
      }

      await for (final chunk in response) {
        if (!current()) return;
        _touch();
        for (final byte in chunk) {
          if (_closed) return;
          if (++frameBytes > 4096) _protocol();
          if (byte == 10) {
            consumeLine();
          } else {
            if (line.length >= 2048) _protocol();
            line.add(byte);
          }
        }
      }
    } catch (error, stack) {
      if (!_closed && _local()) {
        _controller.addError(
          error is DshException ? error : const DshProtocolException('invalid companion signal stream'),
          stack,
        );
      }
    } finally {
      _close();
    }
  }
}
