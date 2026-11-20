import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// Moments worth re-checking remote links: the network changed (Wi-Fi ↔
/// cellular, VPN up/down) or the app came back to the foreground, where
/// Android may have frozen sockets for a while.
///
/// Emits nothing for the initial connectivity state.
Stream<void> networkKicks() {
  late final StreamController<void> controller;
  StreamSubscription<List<ConnectivityResult>>? connectivity;
  AppLifecycleListener? lifecycle;
  List<ConnectivityResult>? last;

  controller = StreamController<void>.broadcast(
    onListen: () {
      try {
        connectivity = Connectivity().onConnectivityChanged.listen((results) {
          final previous = last;
          last = results;
          if (previous == null) return;
          // Coming back online, or switching networks: either way sockets that
          // were bound to the old interface are dead.
          if (!results.contains(ConnectivityResult.none)) controller.add(null);
        }, onError: (_) {});
      } catch (_) {
        // No plugin (tests, desktop without NetworkManager): resume-only.
      }
      lifecycle = AppLifecycleListener(onResume: () => controller.add(null));
    },
    onCancel: () {
      unawaited(connectivity?.cancel());
      lifecycle?.dispose();
      connectivity = null;
      lifecycle = null;
      last = null;
    },
  );
  return controller.stream;
}
