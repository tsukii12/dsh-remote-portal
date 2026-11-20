import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Brings dsh-go back over a browser sign-in (a Custom Tab on top of its
/// task) once the engine holds the login: the provider's own success page
/// never returns to the app by itself. A no-op without the native side.
final appForegroundProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    try {
      await const MethodChannel('dsh/app').invokeMethod<void>('bringToFront');
    } catch (_) {
      // Tests and hosts without the activity channel.
    }
  },
);
