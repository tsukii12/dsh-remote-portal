// Hooks the shell wires in: keep DS Bot's
// notifications alive with the shell, and open a Bot or group from a tapped
// notification.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import 'bot_chat_page.dart';
import 'room_chat_page.dart';

/// Draws nothing. Placed in the shell, it keeps the DS Bot connection and its
/// inbox alive so notices become notifications, and reconnects the feed when
/// the app comes back.
class BotAlertsHost extends ConsumerStatefulWidget {
  const BotAlertsHost({super.key});

  @override
  ConsumerState<BotAlertsHost> createState() => _BotAlertsHostState();
}

class _BotAlertsHostState extends ConsumerState<BotAlertsHost> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.read(dsBotProvider.notifier).kick();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(dsBotInboxProvider.select((_) => null));
    return const SizedBox.shrink();
  }
}

/// Opens the Bot or group a tapped notification names; false for any other
/// notification, which the chat handles.
bool openDsBotTap(BuildContext context, NotifyTap tap) {
  final kind = tap.kind;
  if (kind != dsBotTapBot && kind != dsBotTapRoom) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(activeHostProvider.notifier).select(tap.host);
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.popUntil((route) => route.isFirst);
  navigator.push(kind == dsBotTapRoom ? RoomChatPage.route(tap.sessionId) : BotChatPage.route(tap.sessionId));
  return true;
}
