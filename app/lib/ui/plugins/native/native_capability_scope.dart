// Where v1.2 capabilities live on the chat screen
// (docs/design/native-plugins-protocol.md §11). Draws nothing. Without a plugin
// that declares a capability it is only a lookup: no platform call, no event
// channel, no runtime.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/native/native_capabilities.dart';
import '../../../plugins/native/native_platform.dart';
import '../../chat/chat_header.dart' show ChatHeader;

class NativeCapabilityScope extends ConsumerWidget {
  const NativeCapabilityScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(nativeCapabilityDiscoveryProvider);
    // Audio, listening and the caption window need the runtime; `micro`
    // alone is drawn in Flutter and needs none.
    if (ref.watch(nativeFeatureStateProvider).any({'audio', 'voice', 'overlay'}.contains)) {
      ref.watch(nativeCapabilityRuntimeProvider);
      // The native indicator and caption go just under the chat header.
      final top = ChatHeader.heightOf(context);
      if (ref.read(nativeOverlayTopProvider) != top) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) ref.read(nativeOverlayTopProvider.notifier).set(top);
        });
      }
    }
    return child;
  }
}
