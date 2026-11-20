import 'dart:async';
import 'dart:convert';

import 'agents_api.dart';
import 'carrier.dart';
import 'client_inventory_api.dart';
import 'models.dart';
import 'mux.dart';
import 'session_api.dart';

final _releaseChecks = Expando<_ActivationGeneration>('activationRelease');
final _epochActivations = Expando<_EpochActivation>('epochActivation');

class _ActivationGeneration {
  _ActivationGeneration(this.generation);
  final MuxGeneration generation;
  Future<bool>? release;
  final requests = <String, Future<bool>>{};
}

class _EpochActivation {
  bool requested = false;
}

/// Opt-in interaction activation without replacing a conversation's data stream.
extension SessionActivationApi on DshClient {
  /// Ask the audited Host to activate the Session observed by [epoch].
  ///
  /// The primary follow stays open. Only a short auxiliary follow asks for
  /// activation; its snapshot is consumed here and never forwarded to callers.
  /// True means the Host accepted the opening, not that background promotion
  /// has finished. Unknown releases are passive. One successful request is
  /// remembered per primary epoch; concurrent requests share the same opening.
  /// A failed opening may be retried by a later explicit interaction.
  Future<bool> activateSessionForInteraction(
    String sessionId, {
    required SessionFollowEpoch epoch,
    required bool Function() allowed,
    void Function(bool supported)? onActivationChecked,
  }) {
    final generation = mux.generation;
    bool current() =>
        epoch.isCurrent &&
        generation != null &&
        identical(epoch.generation, generation) &&
        identical(mux.generation, generation) &&
        mux.state == DshConnectionState.connected;
    if (!current() || !allowed() || !current()) return Future.value(false);
    final address = sessionAddressOf(sessionId);
    if (address['kind'] != 'session') return Future.value(false);
    final epochState = _epochActivations[epoch] ??= _EpochActivation();
    if (epochState.requested) return Future.value(true);
    var state = _releaseChecks[this];
    if (state == null || !identical(state.generation, generation)) {
      state = _ActivationGeneration(generation!);
      _releaseChecks[this] = state;
    }
    final evidence = state;
    Future<bool> run() async {
      try {
        final supported = await (evidence.release ??= _readActivationRelease(generation!));
        if (!current() || !allowed() || !current()) return false;
        onActivationChecked?.call(supported);
        // User callbacks can revoke the route or reconnect synchronously.
        if (!supported || !current() || !allowed() || !current()) return false;
        final key = jsonEncode(address);
        var opening = evidence.requests[key];
        if (opening == null) {
          // No await between the last intent/generation check and mux.open.
          opening = _openActivation(address, generation!);
          evidence.requests[key] = opening;
          unawaited(
            opening.whenComplete(() {
              if (identical(evidence.requests[key], opening)) evidence.requests.remove(key);
            }),
          );
        }
        final requested = await opening;
        if (!current()) return false;
        if (requested) epochState.requested = true;
        return requested;
      } on Object {
        // Activation discovery must not fail the already-open history stream.
        return false;
      }
    }

    return run();
  }

  Future<bool> _readActivationRelease(MuxGeneration generation) async {
    try {
      final String? version;
      final transport = carrier;
      if (transport is DshHttpCarrier) {
        // Own HTTP client with a deadline across connect, headers and body;
        // getBounded closes its socket on expiry, not just a Future wrapper.
        final response = await transport.connection.getBounded(
          '/',
          maxBytes: 4 * 1024 * 1024,
          autoUncompress: true,
          timeout: const Duration(seconds: 1),
        );
        version = response.statusCode == 200 ? parseWebBootGraph(response.text)?.release?.version : null;
      } else {
        version = transport.hostVersion;
      }
      return identical(mux.generation, generation) &&
          mux.state == DshConnectionState.connected &&
          (version == '0.2.2-alpha.2' || version == '0.2.2-rc.1');
    } on Object {
      // Negative and unknown results are cached only for this generation.
      return false;
    }
  }

  Future<bool> _openActivation(Map<String, Object?> address, MuxGeneration generation) async {
    MuxStream? stream;
    try {
      stream = mux.open('session/follow', {
        'request': {'address': address, 'activate': true, 'maxMessages': 1},
      });
      final first = await stream.items.first.timeout(const Duration(seconds: 2));
      return identical(mux.generation, generation) &&
          mux.state == DshConnectionState.connected &&
          first is Map &&
          first['type'] == 'snapshot';
    } on Object {
      return false;
    } finally {
      try {
        await stream?.cancel();
      } on Object {
        // A carrier closing concurrently must not leak a cleanup error.
      }
    }
  }
}
