import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';

import '../l10n/l10n.dart';

/// Where a remote host link stands. Local hosts don't use this (the engine
/// page owns their state).
enum HostLinkPhase {
  /// Not started, or closed.
  idle,

  /// First attempt in progress; [HostLinkStatus.step] says which stage.
  connecting,

  /// A [DshClient] is ready.
  connected,

  /// Lost (or never reached) and retrying with backoff.
  reconnecting,

  /// Gave up: a non-retryable error (auth, host key, missing dsh) or too
  /// many attempts. Needs the person to act or to tap "重试".
  failed,
}

/// The visible stages of an SSH connect, in order. Relay links use
/// [connect] and [login] only.
enum HostLinkStep {
  connect,
  verifyHostKey,
  startDsh,
  tunnel,
  login;

  String get label => switch (this) {
    HostLinkStep.connect => appL10n.remoteStepConnect,
    HostLinkStep.verifyHostKey => appL10n.remoteStepVerifyHostKey,
    HostLinkStep.startDsh => appL10n.remoteStepStartDsh,
    HostLinkStep.tunnel => appL10n.remoteStepTunnel,
    HostLinkStep.login => appL10n.commonSignIn,
  };
}

/// Why a link failed, with a sentence a person can act on.
class HostLinkError implements Exception {
  const HostLinkError(this.kind, this.message, {this.detail, this.retryable = false, this.diagnosticCode});

  final HostLinkErrorKind kind;

  /// One sentence for the UI; diagnostics and recovery steps belong in detail.
  final String message;

  /// Raw technical detail (exception text, remote log tail) for "详情".
  final String? detail;

  /// Network-ish failures are retried automatically; the rest need the person.
  final bool retryable;

  /// A closed diagnostic vocabulary; never a server message or exception text.
  final HostLinkDiagnosticCode? diagnosticCode;

  @override
  String toString() => detail == null ? message : appL10n.remoteErrorDetail(message, detail!);
}

/// How a DSH Remote tunnel travels: straight to the computer (LAN or P2P),
/// through a TURN server, or through the Server's relay.
enum RelayPath {
  lan,
  p2p,
  direct,
  turn,
  relay;

  String get label => switch (this) {
    RelayPath.lan => appL10n.remotePathLan,
    RelayPath.p2p => appL10n.remotePathP2p,
    RelayPath.direct => appL10n.remotePathDirect,
    RelayPath.turn => appL10n.remotePathTurn,
    RelayPath.relay => appL10n.remotePathRelay,
  };
}

enum HostLinkErrorKind {
  unreachable,
  authFailed,
  badPrivateKey,
  hostKeyMismatch,
  hostKeyRejected,
  hostKeyUnverified,
  noShell,
  dshNotFound,
  dshStartFailed,
  dshTimeout,
  tunnelFailed,
  loginFailed,
  notLoggedIn,
  hostOffline,
  unavailable,
  other,
}

/// Safe failure provenance for passive diagnostics. Values do not change retry policy.
enum HostLinkDiagnosticCode {
  unknown,
  sshTransportEnded,
  sshKeepaliveMissed,
  sshKickProbeFailed,
  sshTunnelTimedOut,
  sshTunnelRefused,
  sshTunnelFailed,
  remoteHostOffline,
  remoteAccountAuthRequired,
  remoteDeviceRevoked,
  remoteTokenExpired,
  remotePeerIdentityMismatch,
  remoteHostNotTrusted,
  remoteConnectionReplaced,
  remoteConnectionRejected,
  remoteMembershipRequired,
  remoteDeviceNotFound,
  remoteHarnessVersionIncompatible,
  remoteProtocolMismatch,
  remoteUnsupportedVersion,
  remoteCapabilityNotSupported,
  remoteFrameTooLarge,
  remoteInvalidMessage,
  remoteSecureChannelFailed,
  remoteRpcTimeout,
  remoteConnectionFailed,
  remoteRateLimited,
  remoteHistoryModeChanged,
}

enum NetworkIpVersion { ipv4, ipv6 }

enum NetworkIceProtocol { udp, tcp }

/// Measured facts for one encrypted Remote connection. Missing values are unknown.
class RemoteNetworkStatus {
  const RemoteNetworkStatus({
    this.path,
    this.connectDuration,
    this.roundTripTime,
    this.fallbackReason,
    this.observedAt,
    this.localIpVersion,
    this.remoteIpVersion,
    this.iceProtocol,
  });
  final RelayPath? path;
  final Duration? connectDuration;
  final Duration? roundTripTime;
  final NetworkIpVersion? localIpVersion;
  final NetworkIpVersion? remoteIpVersion;
  final NetworkIceProtocol? iceProtocol;

  /// A fixed code, never an arbitrary transport exception or candidate address.
  final String? fallbackReason;
  final DateTime? observedAt;

  String? get safeFallbackReason => fallbackReason == null
      ? null
      : const {
          'webrtcUnavailable',
          'directFailed',
          'directTimeout',
          'directRecentlyFailed',
          'turnUnavailable',
          'turnFailed',
          'turnTimeout',
          'pathUnverified',
        }.contains(fallbackReason)
      ? fallbackReason
      : 'unknown';
}

/// Optional support; SSH links and older backends need no synthetic measurements.
abstract interface class NetworkInspectableHostLink {
  Future<RemoteNetworkStatus?> inspectNetwork();
}

class HostLinkStatus {
  const HostLinkStatus(
    this.phase, {
    this.step,
    this.completed = const {},
    this.error,
    this.attempt = 0,
    this.nextRetryAt,
    this.detail,
    this.path,
    this.network,
  });

  static const idle = HostLinkStatus(HostLinkPhase.idle);

  final HostLinkPhase phase;

  /// Stage in progress while connecting / reconnecting.
  final HostLinkStep? step;

  /// Stages already done in this attempt (for the step-by-step progress list).
  final Set<HostLinkStep> completed;

  /// Last failure: final when [phase] is failed, informative while reconnecting.
  final HostLinkError? error;

  /// Reconnect attempt number (1-based) while [phase] is reconnecting.
  final int attempt;
  final DateTime? nextRetryAt;

  /// Optional one-line progress note ("复用已在运行的 DSH" …).
  final String? detail;

  /// DSH Remote, connected: how the tunnel travels.
  final RelayPath? path;
  final RemoteNetworkStatus? network;

  HostLinkStatus withNetwork(RemoteNetworkStatus value) => HostLinkStatus(
    phase,
    step: step,
    completed: completed,
    error: error,
    attempt: attempt,
    nextRetryAt: nextRetryAt,
    detail: detail,
    path: value.path,
    network: value,
  );

  bool get isConnected => phase == HostLinkPhase.connected;
  bool get isBusy => phase == HostLinkPhase.connecting || phase == HostLinkPhase.reconnecting;

  /// Moves to [next]; every earlier stage counts as done.
  HostLinkStatus withStep(HostLinkStep next, {String? detail}) => HostLinkStatus(
    phase == HostLinkPhase.reconnecting ? HostLinkPhase.reconnecting : HostLinkPhase.connecting,
    step: next,
    completed: {
      for (final s in HostLinkStep.values)
        if (s.index < next.index) s,
    },
    attempt: attempt,
    detail: detail,
  );

  /// Short status text for chips and rows.
  String get summary => switch (phase) {
    HostLinkPhase.idle => appL10n.commonNotConnected,
    HostLinkPhase.connecting => step == null ? appL10n.remoteConnecting : '${step!.label}…',
    HostLinkPhase.connected => appL10n.remoteConnected,
    HostLinkPhase.reconnecting => attempt <= 1 ? appL10n.remoteReconnecting : appL10n.remoteReconnectAttempt(attempt),
    HostLinkPhase.failed => appL10n.commonConnectionFailed,
  };

  @override
  String toString() => 'HostLinkStatus($phase, step: $step, attempt: $attempt, error: $error)';
}

/// A connection to one non-local DSH host, SSH or relay.
///
/// [open] resolves with the first ready [DshClient]; later the link keeps
/// itself alive (keepalive, network changes, backoff) and publishes a fresh
/// client on [clients] when the old one can't be recovered (e.g. the remote
/// `dsh web` restarted on another port). The previous client is closed by
/// the link after the new one has been published.
abstract class HostLink {
  HostLinkStatus get status;
  Stream<HostLinkStatus> get statuses;

  /// The ready client while connected.
  DshClient? get currentClient;

  /// Replacement clients after the first one.
  Stream<DshClient> get clients;

  Future<DshClient> open();

  /// Network changed / app resumed: check now instead of waiting for backoff.
  void kick();

  /// Gives up any backoff and tries again from scratch (the "重试" button).
  void retry();

  Future<void> close();
}

/// Exponential backoff with full jitter: 1, 2, 4 … capped at [max].
class Backoff {
  Backoff({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    this.maxAttempts = 8,
    math.Random? random,
  }) : _random = random ?? math.Random();

  final Duration initial;
  final Duration max;

  /// Attempts before giving up; `null` retries forever.
  final int? maxAttempts;
  final math.Random _random;
  int attempt = 0;

  bool get exhausted => maxAttempts != null && attempt >= maxAttempts!;

  /// Delay before the next attempt; increments [attempt].
  Duration next() {
    attempt++;
    final exp = initial.inMilliseconds * math.pow(2, attempt - 1);
    final capped = math.min(exp.toDouble(), max.inMilliseconds.toDouble());
    // Half fixed, half jitter: never zero, still spread out.
    final ms = capped / 2 + _random.nextDouble() * capped / 2;
    return Duration(milliseconds: ms.round());
  }

  void reset() => attempt = 0;
}

/// A timer that can be cut short (network change / retry) — the wait between
/// reconnect attempts.
class InterruptibleDelay {
  Timer? _timer;
  Completer<void>? _completer;

  Future<void> wait(Duration duration) {
    cancel();
    final completer = _completer = Completer<void>();
    _timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// Ends the current wait now.
  void skip() {
    _timer?.cancel();
    final completer = _completer;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void cancel() => skip();

  bool get waiting => _completer != null && !_completer!.isCompleted;
}
