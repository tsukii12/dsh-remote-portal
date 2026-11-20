import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';
import 'bot_chat_kit.dart';
import 'install_card.dart';

/// Owns pending-answer state for one Host, boot, Bot Session and card.
class BotPendingCard extends ConsumerStatefulWidget {
  const BotPendingCard({
    super.key,
    required this.api,
    required this.origin,
    required this.bot,
    this.question,
    this.view,
  });
  final DsBotApi api;
  final DsBotStatus origin;
  final DsBot bot;
  final DsBotQuestion? question;
  final DsBotViewCard? view;

  @override
  ConsumerState<BotPendingCard> createState() => _BotPendingCardState();
}

class _BotPendingCardState extends ConsumerState<BotPendingCard> {
  bool _retired = false;
  ProviderSubscription<DsBotStatus>? _status;
  StreamSubscription<DsBotFeedEvent>? _feed;

  bool _current() {
    if (!mounted || _retired) return false;
    final status = ref.read(dsBotProvider);
    if (!identical(widget.api, ref.read(dsBotProvider.notifier).api) ||
        status.host != widget.origin.host ||
        status.hello?.boot != widget.origin.hello?.boot ||
        !status.ready) {
      return false;
    }
    final bot = status.team?.bot(widget.bot.id);
    if (bot == null || bot.sessionId != widget.bot.sessionId) return false;
    return widget.question != null
        ? status.team?.questionOf(bot)?.id == widget.question!.id
        : status.team?.questionOf(bot) == null && status.team?.viewOf(bot)?.id == widget.view?.id;
  }

  void _retire() {
    if (mounted && !_retired) setState(() => _retired = true);
  }

  @override
  void initState() {
    super.initState();
    if (!_current()) _retired = true;
    _status = ref.listenManual(dsBotProvider, (_, _) {
      if (!_current()) _retire();
    });
    final boot = widget.origin.hello?.boot;
    _feed = ref.read(dsBotProvider.notifier).events.listen((event) {
      if (event case DsBotFeedHello(boot: final next?)
          when boot != null && boot.isNotEmpty && next.isNotEmpty && next != boot) {
        _retire();
      }
    });
  }

  Future<bool> _run(Future<void> Function() call) async {
    if (!_current() || ref.read(dsBotProvider).readOnly != null) return false;
    try {
      // A request already sent can finish on its original Host. Retirement only
      // prevents its completion from refreshing or reporting into a new target.
      await call();
      if (!_current()) return false;
      await ref.read(dsBotProvider.notifier).refresh();
      return _current();
    } catch (error) {
      if (mounted && _current()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
      return false;
    }
  }

  @override
  void dispose() {
    _status?.close();
    unawaited(_feed?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_current()) return const SizedBox.shrink();
    if (widget.question case final question?) {
      return BotQuestionCard(
        question: question,
        onAnswer: (selected, custom) =>
            _run(() => widget.api.answerQuestion(widget.bot, question, selected: selected, custom: custom)),
        onDismiss: () => unawaited(_run(() => widget.api.dismissQuestion(widget.bot))),
      );
    }
    final view = widget.view!;
    return BotViewCard(
      view: view,
      onOpenInWeb: () {
        if (_current()) ref.read(dsBotWebOpenerProvider)(context, ref);
      },
      onAnswer: (action, values) => _run(() => widget.api.answerView(widget.bot, view, action, values)),
      onDismiss: () => unawaited(_run(() => widget.api.dismissView(widget.bot))),
    );
  }
}
