// The receiving half of a native → Dart method channel
// whose arrivals must not be lost (shares, launcher entries). Same contract
// as `AppLinks` (app_links.dart) and LinksPlugin.kt:
//
// - Dart calls `ready` once its handler is set; the native side holds what
//   came before (a cold start) and pushes it then, in order.
// - Here, arrivals wait for the first listener of [NativeInbox.stream], so
//   the one that cold-started the app reaches it exactly once.
// - Without a native side (widget tests, desktop) there is nothing to hear.

import 'dart:async';

import 'package:flutter/services.dart';

class NativeInbox<T> {
  NativeInbox(this.channel, {required this.method, required this.parse}) {
    _controller = StreamController<T>.broadcast(onListen: _flush);
    channel.setMethodCallHandler(_onCall);
    unawaited(_ready());
  }

  final MethodChannel channel;

  /// The native side's push call (`share`, `entry`).
  final String method;

  /// One push's arguments → the item; null drops it.
  final T? Function(Object? raw) parse;
  late final StreamController<T> _controller;
  final _held = <T>[];
  bool _disposed = false;

  /// Arrivals; what comes while nobody listens is held for the next listener.
  Stream<T> get stream => _controller.stream;

  Future<void> _ready() async {
    try {
      await channel.invokeMethod<bool>('ready');
    } on MissingPluginException {
      // No native side: nothing arrives.
    } on PlatformException {
      // Same.
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != method) throw MissingPluginException(call.method);
    final item = parse(call.arguments);
    if (item != null) add(item);
    return null;
  }

  /// Delivers [item] as if it had come from the platform (tests).
  void add(T item) {
    if (_disposed) return;
    if (_controller.hasListener) {
      _controller.add(item);
    } else {
      _held.add(item);
    }
  }

  void _flush() {
    final held = List.of(_held);
    _held.clear();
    held.forEach(_controller.add);
  }

  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
    unawaited(_controller.close());
  }
}
