/// The `/api/remote.mux` WebSocket: many logical streams over one socket.
///
/// Frames (JSON text, one per WebSocket message):
/// ```text
/// client -> host  {"type":"open","streamId":"<uuid>","endpoint":"session/follow","payload":{"args":{...}}}
///                 {"type":"item","streamId":"..","value":...}     uplink item
///                 {"type":"end","streamId":".."}                  uplink half-close
///                 {"type":"cancel","streamId":".."}
/// host -> client  {"type":"item","streamId":"..","value":...}
///                 {"type":"end","streamId":".."}
///                 {"type":"error","streamId":"..","error":{"code","message","details"}}
/// ```
/// The Gateway-internal `$events` stream (payload `{"args":{}}`) opens every
/// connection generation: its first item must be
/// `{"type":"ready","clientId":"..","host":{"home":".."}}`, after which it
/// carries `emit`, `waterfall` and `cancel` items.
///
/// The physical link comes from a [DshCarrier]: the `/api/remote.mux`
/// WebSocket for [DshHttpCarrier] (the Host pings every 2 s; `dart:io`
/// answers), or an encrypted tunnel connection for remote carriers. This
/// class owns everything above one link: ready handshake, generations,
/// reconnect backoff and pending-request bookkeeping.
///
/// Nothing is replayed across sockets: one-way notifications sent while
/// disconnected are lost, pending waterfalls (approvals, questions) are
/// redelivered with the same `eventId`, and every logical stream must be
/// reopened (follow streams start with a fresh snapshot). Settled requests are
/// neither replayed nor cancelled: watches reconcile them after Host ready.
library;

import 'dart:async';
import 'dart:math';

import 'carrier.dart';
import 'connection.dart';
import 'companion_signals.dart';
import 'errors.dart';
import 'json.dart';
import 'models.dart';

const String remoteMuxPath = '/api/remote.mux';
const String hostEventsEndpoint = r'$events';

/// One established connection generation (a socket whose `$events` stream
/// delivered `ready`).
class MuxGeneration {
  const MuxGeneration(this.number, this.clientId, this.home);

  /// Increments on every successful (re)connect, starting at 1.
  final int number;

  /// Must accompany `$events/result` replies sent during this generation.
  final String clientId;
  final String home;
}

/// Metadata-only receipt captured before asynchronous event delivery. It does
/// not retain event content, approval arguments, titles or messages.
final class MuxEventProvenance {
  MuxEventProvenance._(this.mux, this.generation)
    : observedAt = DateTime.now().toUtc(),
      receivedMonotonicMs = companionMonotonicMs();
  final DshMux mux;
  final MuxGeneration generation;
  final DateTime observedAt;
  final int receivedMonotonicMs;
  int get ageMs => companionMonotonicMs() - receivedMonotonicMs;
  bool get current => identical(mux.generation, generation);
}

final class MuxEventReceipt {
  MuxEventReceipt._(this.event, this.provenance);
  final HostEvent event;
  final MuxEventProvenance provenance;
}

class MuxOptions {
  const MuxOptions({
    this.readyTimeout = const Duration(seconds: 15),
    this.pingInterval = const Duration(seconds: 15),
    this.retryCaps = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 10),
    ],
    this.autoReconnect = true,
  });

  /// Deadline for the `ready` item after the socket opens (Host default 15 s).
  final Duration readyTimeout;

  /// Client ping cadence; a missing pong closes the socket (dead-link
  /// detection). Used by WebSocket carriers; tunnel carriers run their own
  /// health checks.
  final Duration pingInterval;

  /// Backoff caps per attempt (50-100 % jitter), the last one repeats; same
  /// schedule as the official web client.
  final List<Duration> retryCaps;
  final bool autoReconnect;
}

class DshMux {
  DshMux(this.carrier, {this.options = const MuxOptions()});

  final DshCarrier carrier;
  final MuxOptions options;

  final StreamController<DshConnectionState> _states = StreamController.broadcast();
  final StreamController<HostEvent> _hostEvents = StreamController.broadcast();
  final StreamController<MuxEventReceipt> _hostReceipts = StreamController.broadcast();
  final Expando<MuxEventProvenance> _provenance = Expando();
  final StreamController<MuxGeneration> _generations = StreamController.broadcast();
  final Map<String, MuxStream> _streams = {};
  final Set<MuxStream> _pendingOpens = {};
  final List<Completer<MuxGeneration>> _readyWaiters = [];
  final Map<String, HostEvent> _pendingRequests = {};
  final Random _random = Random();

  DshConnectionState _state = DshConnectionState.idle;
  DshMuxLink? _link;
  String? _eventsStreamId;
  MuxGeneration? _generation;
  int _generationCounter = 0;
  int _attempt = 0;
  bool _running = false;
  bool _closed = false;
  bool _everConnected = false;
  Future<void>? _connecting;
  Timer? _retryTimer;
  Timer? _readyTimer;
  Object? _lastError;

  DshConnectionState get state => _state;
  Stream<DshConnectionState> get states => _states.stream;

  /// Parsed `$events` items after `ready` (broadcast; not replayed).
  Stream<HostEvent> get hostEvents => _hostEvents.stream;
  Stream<MuxEventReceipt> get hostEventReceipts => _hostReceipts.stream;
  MuxEventProvenance? provenanceFor(HostEvent event) => _provenance[event];

  void _publishHostEvent(HostEvent event) {
    final current = generation;
    if (current != null) {
      final proof = MuxEventProvenance._(this, current);
      _provenance[event] = proof;
      if (!_hostReceipts.isClosed) _hostReceipts.add(MuxEventReceipt._(event, proof));
    }
    if (!_hostEvents.isClosed) _hostEvents.add(event);
  }

  /// Fires on every new ready generation: reopen your logical streams.
  Stream<MuxGeneration> get generations => _generations.stream;
  MuxGeneration? get generation => _state == DshConnectionState.connected ? _generation : null;

  /// Number of the last accepted ready on this mux, or 0 before its first.
  /// Updated synchronously and retained across loss and close, so teardown can
  /// detect an unseen successor even if it cancels queued state notifications.
  /// This is connection history, not live authority: use [generation] for the
  /// current ready connection. A different mux starts its own history at 0.
  int get lastReadyGenerationNumber => _generationCounter;

  Object? get lastError => _lastError;

  /// Approval/question requests delivered in the current generation and not
  /// yet answered or cancelled, in arrival order.
  List<HostEvent> get pendingRequests => List.unmodifiable(_pendingRequests.values);

  /// Starts connecting (if needed) and resolves with the first ready generation.
  Future<MuxGeneration> start({Duration? timeout}) => ready(timeout: timeout);

  /// Resolves once a generation is ready, starting the connection if idle.
  /// Fails immediately while [state] is `unauthorized` or after [close].
  Future<MuxGeneration> ready({Duration? timeout}) {
    if (_closed) return Future.error(const DshClosedException('mux closed'));
    final current = generation;
    if (current != null) return Future.value(current);
    if (_state == DshConnectionState.unauthorized && _lastError != null) {
      return Future.error(_lastError!);
    }
    _running = true;
    final waiter = Completer<MuxGeneration>();
    _readyWaiters.add(waiter);
    _ensureConnecting();
    if (timeout == null) return waiter.future;
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        _readyWaiters.remove(waiter);
        throw DshTransportException('no ready Host generation within $timeout', _lastError);
      },
    );
  }

  /// Drops the current socket (if any) and starts a fresh attempt now,
  /// resetting the backoff. Also the way out of `unauthorized` after a new
  /// login.
  void reconnect() {
    if (_closed) return;
    _running = true;
    final link = _link;
    if (link != null) {
      _handleLoss(link, const DshCarrierLostException('reconnect requested'));
      unawaited(link.close(4000, 'reconnect requested'));
    }
    // The loss above queues a backed-off retry; an explicit reconnect goes now.
    // An attempt still starting (reconnect() from inside link.start) cannot be
    // replaced yet, so it keeps that queued retry.
    _attempt = 0;
    if (_connecting == null) _retryTimer?.cancel();
    _ensureConnecting();
  }

  /// Opens one logical stream. The `open` frame is sent once a generation is
  /// ready; if the socket drops first, or later, [MuxStream.items] fails with
  /// [DshCarrierLostException] and the caller decides whether to reopen.
  MuxStream open(String endpoint, Map<String, Object?> args) {
    if (_closed) throw const DshClosedException('mux closed');
    final stream = MuxStream._(this, uuidV4(), endpoint, {'args': args});
    final link = _link;
    if (link != null && _state == DshConnectionState.connected) {
      _sendOpen(link, stream);
    } else {
      _pendingOpens.add(stream);
      _running = true;
      _ensureConnecting();
    }
    return stream;
  }

  /// Forget a pending request locally (after this client answered it; the
  /// Host only sends `cancel` to the *other* clients).
  void resolvePendingRequest(String eventId) {
    _pendingRequests.remove(eventId);
    _publishHostEvent(HostRequestCancelledEvent(eventId));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _running = false;
    _retryTimer?.cancel();
    _readyTimer?.cancel();
    const error = DshClosedException('mux closed');
    for (final stream in [..._streams.values, ..._pendingOpens]) {
      stream._fail(error);
    }
    _streams.clear();
    _pendingOpens.clear();
    for (final waiter in _readyWaiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _readyWaiters.clear();
    final link = _link;
    _link = null;
    _generation = null;
    if (link != null) await link.close(1000, 'client closed');
    _setState(DshConnectionState.closed);
    // Closing broadcasts stops new events immediately. Their done delivery is
    // owned by listeners, and a paused listener must not hold transport teardown.
    unawaited(_states.close());
    unawaited(_hostEvents.close());
    unawaited(_hostReceipts.close());
    unawaited(_generations.close());
  }

  // ---------------------------------------------------------------------------

  void _setState(DshConnectionState state) {
    if (_state == state || _states.isClosed) return;
    _state = state;
    _states.add(state);
  }

  void _ensureConnecting() {
    if (_closed || _connecting != null || _link != null) return;
    if (_retryTimer?.isActive ?? false) return;
    _connecting = _connectOnce().whenComplete(() => _connecting = null);
  }

  Future<void> _connectOnce() async {
    _setState(_everConnected ? DshConnectionState.reconnecting : DshConnectionState.connecting);
    final DshMuxLink link;
    try {
      link = await carrier.openLink(options);
    } on DshHttpException catch (error) {
      _lastError = error;
      if (error.isUnauthorized || error.isForbidden) {
        _refuse(error);
        return;
      }
      _scheduleRetry();
      return;
    } on DshCarrierRefusedException catch (error) {
      _lastError = error;
      _refuse(error);
      return;
    } on DshException catch (error) {
      _lastError = error;
      _scheduleRetry();
      return;
    }
    if (_closed) {
      unawaited(link.close(1000, 'client closed'));
      return;
    }
    _link = link;
    link.start(
      onFrame: (frame) => _onFrame(link, frame),
      onLost: (failure, cause) {
        if (link != _link) return;
        if (cause != null) _lastError = cause;
        _handleLoss(link, failure);
      },
    );
    if (_link != link) return; // lost while starting
    final eventsId = uuidV4();
    _eventsStreamId = eventsId;
    _trace({
      'type': 'open',
      'streamId': eventsId,
      'endpoint': hostEventsEndpoint,
      'payload': {'args': <String, Object?>{}},
    });
    link.open(eventsId, hostEventsEndpoint, {'args': <String, Object?>{}});
    _readyTimer?.cancel();
    _readyTimer = Timer(options.readyTimeout, () {
      if (_link == link && _generation == null) {
        _lastError = const DshTransportException('Host did not send ready on \$events in time');
        _handleLoss(link, const DshCarrierLostException('ready timeout'));
        unawaited(link.close(4001, 'ready timeout'));
      }
    });
  }

  /// Stops reconnecting until [reconnect]: the carrier needs user action.
  void _refuse(DshException error) {
    _running = false;
    _setState(DshConnectionState.unauthorized);
    _failWaiters(error);
  }

  void _onFrame(DshMuxLink link, Map<String, Object?> frame) {
    if (link != _link) return;
    final streamId = asString(frame['streamId']);
    if (streamId == _eventsStreamId) {
      _onEventsFrame(link, frame);
      return;
    }
    _streams[streamId]?._deliver(frame);
  }

  void _onEventsFrame(DshMuxLink link, Map<String, Object?> frame) {
    final type = frame['type'];
    if (type != 'item') {
      // `$events` ended or failed: this generation is no longer valid.
      final failure = type == 'error'
          ? DshRemoteException.fromJson(frame['error'])
          : const DshCarrierLostException(r'$events ended');
      _lastError = failure;
      _handleLoss(
        link,
        DshCarrierLostException(
          r'$events stream closed: '
          '$failure',
        ),
      );
      unawaited(link.close(4003, r'$events closed'));
      return;
    }
    final event = HostEvent.fromFrame(frame['value']);
    if (_generation == null) {
      if (event is! HostReadyEvent) {
        _protocolFailure(link, r'$events opened without ready');
        return;
      }
      _readyTimer?.cancel();
      _attempt = 0;
      _everConnected = true;
      _pendingRequests.clear();
      final generation = MuxGeneration(++_generationCounter, event.clientId, event.home);
      _generation = generation;
      _setState(DshConnectionState.connected);
      for (final waiter in _readyWaiters) {
        if (!waiter.isCompleted) waiter.complete(generation);
      }
      _readyWaiters.clear();
      final pending = [..._pendingOpens];
      _pendingOpens.clear();
      for (final stream in pending) {
        if (!stream.isClosed) _sendOpen(link, stream);
      }
      if (!_generations.isClosed) _generations.add(generation);
      _publishHostEvent(event);
      return;
    }
    switch (event) {
      case ApprovalRequestedEvent(:final request):
        _pendingRequests[request.eventId] = event;
      case UserQuestionRequestedEvent(:final request):
        _pendingRequests[request.eventId] = event;
      case UnknownHostEvent(:final eventId?):
        _pendingRequests[eventId] = event;
      case HostRequestCancelledEvent(:final eventId):
        _pendingRequests.remove(eventId);
      default:
        break;
    }
    _publishHostEvent(event);
  }

  void _protocolFailure(DshMuxLink link, String reason) {
    _lastError = DshProtocolException(reason);
    _handleLoss(link, DshCarrierLostException('protocol failure: $reason'));
    unawaited(link.close(4002, 'invalid Remote stream frame'));
  }

  /// Cleans up after [link] is gone; ignores links already replaced.
  void _handleLoss(DshMuxLink link, DshException failure) {
    if (link != _link) return;
    _link = null;
    _eventsStreamId = null;
    _generation = null;
    _readyTimer?.cancel();
    _pendingRequests.clear();
    final streams = [..._streams.values];
    _streams.clear();
    for (final stream in streams) {
      stream._fail(failure);
    }
    if (_closed) return;
    if (_running && options.autoReconnect) {
      _setState(DshConnectionState.reconnecting);
      _scheduleRetry();
    } else {
      _setState(DshConnectionState.idle);
      _failWaiters(failure);
    }
  }

  void _scheduleRetry() {
    if (_closed || !_running || !options.autoReconnect) {
      _failWaiters(_lastError ?? const DshCarrierLostException('not connected'));
      if (!_closed) _setState(DshConnectionState.idle);
      return;
    }
    final caps = options.retryCaps;
    final cap = caps[min(_attempt, caps.length - 1)];
    final delay = cap * (0.5 + _random.nextDouble() * 0.5);
    _attempt++;
    _setState(_everConnected ? DshConnectionState.reconnecting : DshConnectionState.connecting);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _ensureConnecting();
    });
  }

  void _failWaiters(Object error) {
    for (final waiter in _readyWaiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _readyWaiters.clear();
    final pending = [..._pendingOpens];
    _pendingOpens.clear();
    for (final stream in pending) {
      stream._fail(error);
    }
  }

  void _sendOpen(DshMuxLink link, MuxStream stream) {
    stream._carrier = link;
    _streams[stream.streamId] = stream;
    _trace({'type': 'open', 'streamId': stream.streamId, 'endpoint': stream.endpoint, 'payload': stream._payload});
    link.open(stream.streamId, stream.endpoint, stream._payload);
    stream._opened = true;
    stream._flushUplink();
  }

  void _traceOut(Map<String, Object?> frame) => _trace(frame);

  /// Records an outgoing frame for carriers that do not trace themselves.
  void _trace(Map<String, Object?> frame) {
    if (carrier is DshHttpCarrier) return; // traced by the WebSocket link
    carrier.tracer?.call(DshTraceEntry('out', 'mux', frame));
  }

  bool _isLive(DshMuxLink? link) => link != null && link == _link;
}

/// One logical stream on the mux.
///
/// [items] emits each `item` value, closes on `end`, and fails with
/// [DshRemoteException] on an `error` frame or [DshCarrierLostException] when
/// the socket drops. Cancelling the subscription sends `cancel`.
class MuxStream {
  MuxStream._(this._mux, this.streamId, this.endpoint, this._payload) {
    _controller = StreamController<Object?>(onCancel: () => cancel());
  }

  final DshMux _mux;
  final String streamId;
  final String endpoint;
  final Map<String, Object?> _payload;
  late final StreamController<Object?> _controller;
  final List<Map<String, Object?>> _uplink = [];
  DshMuxLink? _carrier;
  bool _opened = false;
  bool _terminal = false;
  bool _cancelled = false;

  Stream<Object?> get items => _controller.stream;
  bool get isClosed => _terminal || _cancelled;

  /// Whether this stream's carrier supports uplink items ([send],
  /// [endUplink]). Remote tunnels do not.
  bool get supportsUplink => _mux.carrier.supportsUplink;

  /// Queues one uplink item (endpoints that read `ctx.invocation.uplink()`).
  ///
  /// Throws [UnsupportedError] when the carrier has no uplink (remote
  /// tunnels), [StateError] when the stream is closed.
  void send(Object? value) {
    if (!supportsUplink) {
      throw UnsupportedError('uplink items are not supported by the ${_mux.carrier.kind} carrier');
    }
    if (isClosed) throw StateError('stream $endpoint is closed');
    _uplink.add({'type': 'item', 'streamId': streamId, 'value': value});
    _flushUplink();
  }

  /// Half-closes the uplink (a no-op on carriers without uplink).
  void endUplink() {
    if (isClosed || !supportsUplink) return;
    _uplink.add({'type': 'end', 'streamId': streamId});
    _flushUplink();
  }

  /// Stops the stream: sends `cancel` unless the Host already finished it.
  Future<void> cancel() async {
    if (isClosed) return;
    _cancelled = true;
    _mux._pendingOpens.remove(this);
    _mux._streams.remove(streamId);
    final link = _carrier;
    if (_opened && _mux._isLive(link)) {
      _mux._traceOut({'type': 'cancel', 'streamId': streamId});
      link!.cancel(streamId);
    }
    // Not awaited: `close()` on a never-listened controller never completes.
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  void _flushUplink() {
    final link = _carrier;
    if (!_opened || !_mux._isLive(link)) return;
    for (final frame in _uplink) {
      _mux._traceOut(frame);
      if (frame['type'] == 'item') {
        link!.sendItem(streamId, frame['value']);
      } else {
        link!.endUplink(streamId);
      }
    }
    _uplink.clear();
  }

  void _deliver(Map<String, Object?> frame) {
    if (isClosed) return;
    switch (frame['type']) {
      case 'item':
        _controller.add(frame['value']);
      case 'end':
        _terminal = true;
        _mux._streams.remove(streamId);
        unawaited(_controller.close());
      case 'error':
        _terminal = true;
        _mux._streams.remove(streamId);
        _controller.addError(DshRemoteException.fromJson(frame['error']));
        unawaited(_controller.close());
    }
  }

  void _fail(Object error) {
    if (isClosed) return;
    _terminal = true;
    _controller.addError(error);
    unawaited(_controller.close());
  }
}
