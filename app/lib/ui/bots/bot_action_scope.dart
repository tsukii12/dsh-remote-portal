// A Bot modal may stay open while the active connection changes. Capture the
// target before opening it, then check again before writing or presenting a result.
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';

class BotActionScope {
  BotActionScope(WidgetRef ref, {this.botId, this.roomId})
    : api = ref.read(dsBotProvider.notifier).api,
      _origin = ref.read(dsBotProvider);

  final DsBotApi? api;
  final DsBotStatus _origin;
  final String? botId;
  final String? roomId;

  bool connected(BuildContext context, WidgetRef ref) {
    if (!context.mounted || api == null || ref.read(dsBotProvider.notifier).api != api) return false;
    final status = ref.read(dsBotProvider);
    return status.host == _origin.host && status.hello?.boot == _origin.hello?.boot;
  }

  bool current(BuildContext context, WidgetRef ref) {
    if (!connected(context, ref)) return false;
    final status = ref.read(dsBotProvider);
    return status.readOnly == null &&
        (botId == null || status.team?.bot(botId) != null) &&
        (roomId == null || status.team?.room(roomId!) != null);
  }
}
