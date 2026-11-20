import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import 'bot_chat_page.dart';

/// A copy starts a new Session; it is not a copy of the original conversation.
class DuplicateBotRow extends ConsumerStatefulWidget {
  const DuplicateBotRow({super.key, required this.bot});

  final DsBot bot;

  @override
  ConsumerState<DuplicateBotRow> createState() => _DuplicateBotRowState();
}

class _DuplicateBotRowState extends ConsumerState<DuplicateBotRow> {
  bool _busy = false;
  bool _retired = false;
  StreamSubscription<DsBotFeedEvent>? _feed;

  @override
  void initState() {
    super.initState();
    final boot = ref.read(dsBotProvider).hello?.boot;
    _feed = ref.read(dsBotProvider.notifier).events.listen((event) {
      if (event case DsBotFeedHello(boot: final next?)
          when boot != null && boot.isNotEmpty && next.isNotEmpty && next != boot) {
        // The hub re-opens the connection on a new boot; retire at once so an open
        // confirm cannot write before that lands. The new API identity makes a new row.
        if (mounted) setState(() => _retired = true);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_feed?.cancel());
    super.dispose();
  }

  Future<void> _duplicate() async {
    if (_busy) return;
    final origin = ref.read(dsBotProvider);
    final hub = ref.read(dsBotProvider.notifier);
    final api = hub.api;
    final id = widget.bot.id;
    bool current() {
      if (!mounted || _retired) return false;
      final status = ref.read(dsBotProvider);
      return identical(api, ref.read(dsBotProvider.notifier).api) &&
          status.host == origin.host &&
          status.hello?.boot == origin.hello?.boot &&
          status.ready &&
          status.readOnly == null &&
          status.team?.bot(id) != null;
    }

    if (api == null || !current()) return;
    setState(() => _busy = true);
    try {
      final l10n = context.l10n;
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.botsDuplicateNamed(widget.bot.name)),
          content: Text(l10n.botsDuplicateBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(
              key: const ValueKey('duplicate-bot-confirm'),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l10n.botsDuplicate),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !current()) return;
      final copy = await api.duplicateBot(id);
      if (!mounted || !current()) return;
      await hub.refresh();
      if (!mounted || !current()) return;
      if (ref.read(dsBotProvider).team?.bot(copy.id) == null) {
        // Creation succeeded even when the shared state refresh was busy or failed.
        // Do not present a missing-Bot page or suggest retrying the creation.
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.botsDuplicateCreated)));
        return;
      }
      await Navigator.of(context).push(BotChatPage.route(copy.id));
    } catch (error) {
      if (mounted && current()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(dsBotProvider);
    return ListPageRow(
      key: const ValueKey('duplicate-bot-row'),
      icon: AppIcons.copy,
      title: context.l10n.botsDuplicate,
      subtitle: context.l10n.botsDuplicateHint,
      // An action like 设为主 Bot below it, not a page.
      chevron: false,
      onTap: !_busy && !_retired && status.ready && status.readOnly == null ? _duplicate : null,
    );
  }
}
