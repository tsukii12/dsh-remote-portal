import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One request to show a conversation's newest line.
class ChatReveal {
  const ChatReveal(this.sessionId, this.serial);

  final String sessionId;

  /// Counts requests, so the same conversation asked twice is two changes.
  final int serial;
}

/// The app came back to a conversation to show a result (a finished phone
/// task, state/phone_turn_end.dart): its chat jumps to the bottom, wherever it
/// was scrolled. A chat opened fresh starts there anyway.
class ChatRevealController extends Notifier<ChatReveal?> {
  @override
  ChatReveal? build() => null;

  void reveal(String sessionId) => state = ChatReveal(sessionId, (state?.serial ?? 0) + 1);
}

final chatRevealProvider = NotifierProvider<ChatRevealController, ChatReveal?>(ChatRevealController.new);
