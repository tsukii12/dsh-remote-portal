import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// dsh-emoji's read-only size preference, in ems of the surrounding text.
/// The four wire values and default match the plugin's settings-model.ts.
/// Only a rendered inline asset watches this; no general settings inventory
/// or extra endpoint permission is needed.
final emojiSizeProvider = NotifierProvider.autoDispose.family<EmojiSizeController, double, DshClient>(
  EmojiSizeController.new,
);

class EmojiSizeController extends Notifier<double> {
  EmojiSizeController(this.client);

  final DshClient client;
  int _generation = 0;

  @override
  double build() {
    final events = client.hostEvents.listen((event) {
      if (event is HostReadyEvent || (event is SettingsUpdatedEvent && event.namespace == 'dsh-emoji')) {
        unawaited(_refresh());
      }
    });
    ref.onDispose(() {
      _generation += 1;
      unawaited(events.cancel());
    });
    unawaited(_refresh());
    return 1.5;
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final document = await client.rpc.call('dsh-emoji-settings/get');
      final settings = document is Map ? document['settings'] : null;
      final size = switch (settings is Map ? settings['displaySize'] : null) {
        'small' => 1.25,
        'normal' => 1.5,
        'large' => 2.0,
        'xlarge' => 2.5,
        _ => null,
      };
      if (ref.mounted && generation == _generation && size != null) state = size;
    } on DshException {
      // Older/missing plugins and a lost connection keep the last valid size,
      // or the plugin's default. Image loading still reports its own failures.
    }
  }
}
