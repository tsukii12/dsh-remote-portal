import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';
import 'sessions_state.dart';

class FlagController extends Notifier<bool> {
  FlagController(this.initial);
  final bool initial;
  @override
  bool build() => initial;
  void set(bool value) {
    if (value != state) state = value;
  }
}

final appForegroundProvider = NotifierProvider<FlagController, bool>(() => FlagController(true));
final chatOnScreenProvider = NotifierProvider<FlagController, bool>(() => FlagController(true));
typedef ChatTarget = ({HostRef host, String sessionId});
final viewedChatProvider = Provider<ChatTarget?>((ref) {
  if (!ref.watch(appForegroundProvider) || !ref.watch(chatOnScreenProvider)) return null;
  final session = ref.watch(currentSessionProvider);
  return session == null ? null : (host: ref.watch(activeHostProvider), sessionId: session);
});
