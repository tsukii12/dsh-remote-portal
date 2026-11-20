// Creation drafts belong to the connection on which the form became usable.
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';

class BotCreationScope {
  BotCreationScope._(this.api, this.origin);
  final DsBotApi api;
  final DsBotStatus origin;

  static BotCreationScope? capture(WidgetRef ref) {
    final status = ref.read(dsBotProvider);
    final api = ref.read(dsBotProvider.notifier).api;
    return api != null ? BotCreationScope._(api, status) : null;
  }

  bool connected(WidgetRef ref) {
    final status = ref.read(dsBotProvider);
    return identical(api, ref.read(dsBotProvider.notifier).api) &&
        status.host == origin.host &&
        (origin.hello?.boot == null || status.hello?.boot == origin.hello?.boot);
  }

  bool writable(WidgetRef ref) =>
      connected(ref) && ref.read(dsBotProvider).ready && ref.read(dsBotProvider).readOnly == null;
}
