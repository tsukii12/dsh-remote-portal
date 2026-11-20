import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_portal/dsh_portal.dart';

import '../dev/remote_benchmark.dart';
import '../state/hosts_state.dart';
import 'link_status.dart';
import 'secret_store.dart';

class PortalHostLink extends HostLink {
  PortalHostLink(this.config, this.secrets, {Stream<void>? kicks}) {
    _kicks = kicks?.listen((_) => kick());
  }
  final PortalHostConfig config;
  final SecretStore secrets;
  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  StreamSubscription<void>? _kicks;
  StreamSubscription<DshConnectionState>? _states;
  StreamSubscription<void>? _expiry;
  PortalSession? _session;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  HostLinkStatus _status = HostLinkStatus.idle;
  @override
  HostLinkStatus get status => _status;
  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;
  @override
  DshClient? get currentClient => _status.phase == HostLinkPhase.connected ? _client : null;
  @override
  Stream<DshClient> get clients => _clients.stream;

  void _set(HostLinkStatus value) {
    if (_closed) return;
    _status = value;
    _statuses.add(value);
  }

  void _expired() => _set(
    const HostLinkStatus(
      HostLinkPhase.failed,
      error: HostLinkError(HostLinkErrorKind.authFailed, 'Sign in again. / 请重新登录。'),
    ),
  );

  @override
  Future<DshClient> open() => _opening ??= _open();
  Future<DshClient> _open() async {
    RemoteBenchmark.start('connect');
    _set(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      final session = _session = PortalSession(
        config.base,
        saveCookies: (value) =>
            value == null ? secrets.delete(config.cookieKey) : secrets.write(config.cookieKey, value),
      );
      final stored = await secrets.read(config.cookieKey);
      if (_closed) throw const DshClosedException();
      try {
        session.restoreCookies(stored);
      } on FormatException {
        await secrets.delete(config.cookieKey);
      }
      if (!session.hasCookies) {
        _expired();
        throw const HostLinkError(HostLinkErrorKind.authFailed, 'Sign in again. / 请重新登录。');
      }
      _expiry = session.expired.listen((_) => _expired());
      final client = _client = DshClient(session.connection);
      _states = client.mux.states.listen((value) {
        switch (value) {
          case DshConnectionState.connected:
            _set(const HostLinkStatus(HostLinkPhase.connected));
          case DshConnectionState.unauthorized:
            session.unauthorized();
          case DshConnectionState.reconnecting:
            _set(const HostLinkStatus(HostLinkPhase.reconnecting));
          default:
            break;
        }
      });
      await client.mux.ready();
      RemoteBenchmark.finish('connect');
      if (_closed) throw const DshClosedException();
      _set(const HostLinkStatus(HostLinkPhase.connected));
      return client;
    } on Object catch (error) {
      RemoteBenchmark.cancel('connect');
      if (error is DshHttpException && error.statusCode == 401) _expired();
      if (_status.phase != HostLinkPhase.failed) {
        _set(
          const HostLinkStatus(
            HostLinkPhase.failed,
            error: HostLinkError(HostLinkErrorKind.unreachable, 'Connection failed. Retry. / 连接失败，请重试。'),
          ),
        );
      }
      rethrow;
    }
  }

  @override
  void kick() {
    if (!_closed && _status.phase == HostLinkPhase.reconnecting) _client?.mux.reconnect();
  }

  @override
  void retry() => _client?.mux.reconnect();
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _kicks?.cancel();
    await _states?.cancel();
    await _expiry?.cancel();
    await _client?.close();
    await _session?.close();
    await _statuses.close();
    await _clients.close();
  }
}
