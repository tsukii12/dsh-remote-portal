
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/l10n.dart';

final tavernIslandBuilderProvider = Provider<Widget Function(String html)>(
  (ref) => (html) => TavernHtmlIsland(html: html));

class TavernIslandMessage extends InheritedWidget {
  const TavernIslandMessage({
    super.key,
    required this.chatId,
    required this.nodeId,
    required this.text,
    required this.name,
    required this.user,
    required super.child,
  });

  final String chatId;
  final String nodeId;
  final String text;
  final String name;
  final bool user;

  static TavernIslandMessage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TavernIslandMessage>();

  @override
  bool updateShouldNotify(TavernIslandMessage old) =>
      old.chatId != chatId || old.nodeId != nodeId || old.text != text || old.name != name || old.user != user;
}


class TavernHtmlIsland extends StatelessWidget {
  const TavernHtmlIsland({super.key, required this.html});
  final String html;
  static const minHeight = 24.0;
  static const maxHeight = 4000.0;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(12),
    child: Text(context.l10n.portalWebRemoved));
}
