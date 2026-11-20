// 图片快捷方式: a home-screen shortcut with the user's own picture that opens the app
// (ShortcutManager.requestPinShortcut). Android doesn't let an app make its launcher icon any
// picture; this is the honest way to have one. Native side: icons/PictureShortcutPlugin.kt
// (`dsh/picture_shortcut`: `pin`, and `pinned` back once the launcher has added one).
// Where to allow it when no dialog shows: the maker's own permission page for this app
// (runtime/VendorSettings.kt, `popup`: vivo's 权限管理 and Xiaomi's 其他权限 hold
// 桌面快捷方式 there), else the system's app details.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_state.dart';

/// What asking for a pinned shortcut came to.
enum PinRequest {
  /// The launcher shows its own confirmation now ([IconShortcutChannel.pinned] once added).
  asked,

  /// This launcher doesn't take pinned shortcuts.
  unsupported,

  /// The request didn't go through.
  failed,
}

class IconShortcutChannel {
  IconShortcutChannel({this.channel = const MethodChannel('dsh/picture_shortcut'), this.openPermissions});

  final MethodChannel channel;

  /// Opens the page to allow it on; what opened (`vendor`, `details`) or null.
  final Future<String?> Function()? openPermissions;

  final _pinned = StreamController<void>.broadcast();
  bool _listening = false;

  /// One event each time the launcher reports a picture shortcut added.
  Stream<void> get pinned {
    if (!_listening) {
      _listening = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'pinned') _pinned.add(null);
      });
    }
    return _pinned.stream;
  }

  /// Asks the launcher to add a shortcut called [label] with [png]: the full 108 dp adaptive
  /// layer, its visible part the middle two thirds.
  Future<PinRequest> pin(String label, Uint8List png) async {
    try {
      final raw = await channel.invokeMapMethod<String, Object?>('pin', {'label': label, 'png': png});
      if (raw?['supported'] == false) return PinRequest.unsupported;
      return raw?['requested'] == true ? PinRequest.asked : PinRequest.failed;
    } on MissingPluginException {
      return PinRequest.unsupported;
    } on PlatformException {
      return PinRequest.failed;
    }
  }

  /// The page where this app may be allowed to add home-screen shortcuts; true if one opened.
  Future<bool> openAppSettings() async => await openPermissions?.call() != null;
}

final iconShortcutChannelProvider = Provider<IconShortcutChannel>(
  (ref) => IconShortcutChannel(openPermissions: () => ref.read(runtimeBridgeProvider).openVendorSettings('popup')),
);
