part of 'engine.dart';

// A distinct single-subscription controller lets each UI consumer pause
// without buffering every later snapshot or pausing another consumer. The
// per-chat hub owns one refresh pump, but retains no trusted snapshot cache.
class _DirectorWatcher {
  _DirectorWatcher(this.owner, this.chatId) {
    _controller = StreamController<TavernDirectorSnapshot>(
      onListen: _listen,
      onPause: () {
        _paused = true;
      },
      onResume: () {
        _paused = false;
        if (!_ended) _hub?.refresh();
      },
      onCancel: _cancel,
    );
  }

  final _DirectorCoordinator owner;
  final String chatId;
  late final StreamController<TavernDirectorSnapshot> _controller;
  _DirectorWatchHub? _hub;
  bool _paused = false;
  bool _ended = false;
  Stream<TavernDirectorSnapshot> get stream => _controller.stream;
  bool get active => !_ended && !_paused && !_controller.isPaused;

  void _listen() {
    if (owner._closed || owner.engine._closing || owner.engine._closed) {
      finish();
      return;
    }
    final hub = owner._watchHubs.putIfAbsent(chatId, () => _DirectorWatchHub(owner, chatId));
    _hub = hub;
    hub.add(this);
  }

  Future<void>? _cancel() {
    _ended = true;
    final hub = _hub;
    _hub = null;
    return hub?.remove(this);
  }

  void finish() {
    if (_ended) return;
    _ended = true;
    _hub = null;
    // A paused UI may never process done. It cannot own engine shutdown or
    // the native file operations already tracked by the refresh pump.
    unawaited(_controller.close());
  }
}

class _DirectorWatchHub {
  _DirectorWatchHub(this.owner, this.chatId) {
    _subscription = owner.changes
        .where((id) => id == chatId)
        .listen(
          (_) => refresh(),
          onDone: () {
            unawaited(close());
          },
        );
  }

  final _DirectorCoordinator owner;
  final String chatId;
  final _clients = <_DirectorWatcher>{};
  late final StreamSubscription<String> _subscription;
  Future<void>? _cancelled;
  bool _dirty = false;
  bool _scheduled = false;
  bool _pumping = false;
  bool _ended = false;
  bool get _open => !_ended && !owner._closed && !owner.engine._closing && !owner.engine._closed;
  bool get _active => _clients.any((client) => client.active);

  void add(_DirectorWatcher client) {
    _clients.add(client);
    // No cached-value replay: async change notifications may still be in
    // flight, so every newly attached/resumed observer requests a fresh read.
    refresh();
  }

  Future<void>? remove(_DirectorWatcher client) {
    _clients.remove(client);
    return _clients.isEmpty ? close() : null;
  }

  void refresh() {
    if (!_open) return;
    _dirty = true;
    _schedule();
  }

  void _schedule() {
    if (!_open || !_dirty || !_active || _scheduled || _pumping) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_open && _dirty && _active && !_pumping) unawaited(_pump());
    });
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (_open && _dirty && _active) {
        // Wait outside _operations: backup capture drains admitted readers,
        // so registering a reader that awaits this gate would self-deadlock.
        final captureDone = owner.engine._backupCaptureDone;
        if (captureDone != null) {
          await captureDone.future;
          continue;
        }
        _dirty = false;
        try {
          final value = await owner.engine._trackOperation(
            Future<TavernDirectorSnapshot>.sync(() => owner.read(chatId)),
          );
          if (_open && !_dirty) {
            for (final client in _clients.toList()) {
              if (client.active) client._controller.add(value);
            }
          }
        } catch (error, stack) {
          if (_open && !_dirty) {
            for (final client in _clients.toList()) {
              if (client.active) client._controller.addError(error, stack);
            }
          }
        }
        // Paused clients receive no new events. Work already admitted stays
        // owned until its real IO settles, even if every client cancels.
      }
    } finally {
      _pumping = false;
      _schedule();
    }
  }

  Future<void> close() {
    if (_ended) return _cancelled ?? Future<void>.value();
    _ended = true;
    // A fresh listener may have installed a successor while an old read or
    // subscription was draining. Old cleanup may only remove its own hub.
    if (identical(owner._watchHubs[chatId], this)) owner._watchHubs.remove(chatId);
    for (final client in _clients.toList()) {
      client.finish();
    }
    _clients.clear();
    return _cancelled = _subscription.cancel();
  }
}
