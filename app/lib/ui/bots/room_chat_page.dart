// A group chat: every message with its speaker's face and name, the round's
// events, who speaks now, members waiting for approval, the `@` member
// picker over the chat's composer.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/settings_state.dart';
import '../../state/bots_state.dart';
import '../chat/composer.dart';
import '../chat/widgets/chat_card.dart';
import '../common/status_dot.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import 'bot_stop_guard.dart';
import 'bot_action_scope.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_draft_send.dart';
import 'bot_avatar.dart';
import 'unavailable_message.dart';
import 'bot_chat_kit.dart';
import 'bot_chat_page.dart';
import 'bot_format.dart';
import 'bot_mention.dart';
import 'room_approval_action.dart';
import 'room_details_page.dart';
import 'room_full_text_sheet.dart';

class RoomChatPage extends ConsumerStatefulWidget {
  const RoomChatPage({super.key, required this.roomId});

  final String roomId;

  static Route<void> route(String roomId) => MaterialPageRoute<void>(builder: (_) => RoomChatPage(roomId: roomId));

  @override
  ConsumerState<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends ConsumerState<RoomChatPage> {
  Object? _continueScope;
  int _continueRequest = 0;
  bool _continuing = false;
  String? _continuedPause;
  late final BotStopGuard _stopGuard;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrolled = ValueNotifier(0.0);
  late final DsBotViewingController _viewing;
  late final BotMentionController _mentions = BotMentionController(input: _input);

  @override
  void initState() {
    super.initState();
    _stopGuard = BotStopGuard(ref);
    _viewing = ref.read(dsBotViewingProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _viewing.set(widget.roomId);
    });
  }

  @override
  void dispose() {
    _stopGuard.dispose();
    _viewing.leave(widget.roomId);
    _mentions.dispose();
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  Future<void> _send(BotActionScope target) async {
    if (!mounted || target.roomId != widget.roomId || !target.current(context, ref)) return;
    if (!ref.read(dsBotProvider).ready) return;
    await sendBotDraft(
      context,
      ref,
      _input,
      roomId: widget.roomId,
      send: (text) => ref.read(roomChatProvider(widget.roomId).notifier).send(text),
    );
  }

  Future<void> _continue(DsBotRoom room, BotActionScope target) async {
    // The rendered button belongs to this connection and these parked calls.
    // A click may arrive after a host/boot change but before the next frame.
    if (!mounted || !target.current(context, ref)) return;
    final hub = ref.read(dsBotProvider.notifier);
    final api = target.api;
    if (api == null || _continuing) return;
    final status = ref.read(dsBotProvider);
    final pause = room.pausedCallIds.join('\u0000');
    if (_continuedPause == pause) return;
    if (!status.ready || status.team?.room(room.id)?.pausedCallIds.join('\u0000') != pause) return;
    final scope = _continueScope;
    final request = ++_continueRequest;
    bool current() =>
        mounted &&
        scope == _continueScope &&
        request == _continueRequest &&
        ref.read(dsBotProvider.notifier).api == api &&
        ref.read(dsBotProvider).host == status.host &&
        ref.read(dsBotProvider).hello?.boot == status.hello?.boot;
    setState(() => _continuing = true);
    try {
      await api.continueRoom(room.id);
      if (!current()) return;
      // The queued round clears these calls asynchronously. Do not enqueue
      // another Continue while the same parked calls remain in state.
      setState(() => _continuedPause = pause);
      await hub.refresh();
    } catch (error) {
      if (mounted && current()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    } finally {
      if (current()) setState(() => _continuing = false);
    }
  }

  bool _fullTextOpen = false;

  Future<void> _showAll(DsBotItem item, BotActionScope scope) async {
    if (_fullTextOpen) return;
    _fullTextOpen = true;
    try {
      await showRoomFullText(context, ref, widget.roomId, item, scope: scope);
    } finally {
      _fullTextOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final api = ref.read(dsBotProvider.notifier).api;
    final scope = (status.host, status.hello?.boot, widget.roomId, api);
    if (_continueScope != scope) {
      _continueScope = scope;
      _continueRequest++;
      _continuing = false;
      _continuedPause = null;
    }
    final team = status.team;
    final room = team?.room(widget.roomId);
    final continueTarget = BotActionScope(ref, roomId: widget.roomId);
    final fullTextScope = BotActionScope(ref, roomId: widget.roomId);
    final sendTarget = BotActionScope(ref, roomId: widget.roomId);
    final mobileUnavailable =
        status.availability == DsBotAvailability.missing || status.availability == DsBotAvailability.outdated;
    if (team == null || room == null || mobileUnavailable) {
      return AppPage.list(
        title: l10n.botsGroupChat,
        children: [
          DsBotUnavailableMessage(status: status, goneIcon: AppIcons.groupChat, goneTitle: l10n.botsRoomGone),
        ],
      );
    }
    final members = [for (final id in room.members) ?team.bot(id)];
    _mentions.setMembers(members, room.admin);
    final chat = ref.watch(roomChatProvider(widget.roomId));
    final working = status.live.rooms[room.id] ?? const <DsBotWork>[];
    final approvals = [
      for (final a in status.live.approvals)
        if (a.roomId == room.id && a.answerable) a,
    ];
    final speakingId = chat.speaking ?? working.where((w) => w.speaking).firstOrNull?.botId;
    final speaker = team.bot(speakingId);
    final (String label, StatusTone tone) = switch (()) {
      _ when approvals.isNotEmpty => (l10n.botsMemberNeedsApproval, StatusTone.warn),
      _ when speaker != null => (l10n.botsNamedSpeaking(speaker.name), StatusTone.busy),
      _ when working.isNotEmpty => (
        l10n.botsNamedActivity(
          team.bot(working.first.botId)?.name ?? 'Bot',
          workPhrase(working.first) ?? l10n.botsWorking,
        ),
        StatusTone.busy,
      ),
      _ when chat.running => (l10n.botsDiscussing, StatusTone.busy),
      _ when room.paused => (l10n.commonPaused, StatusTone.warn),
      _ => (l10n.botsMemberCount(room.members.length), StatusTone.ok),
    };
    final typing = speaker == null
        ? null
        : BotTypingRow(
            speaker,
            l10n.botsNamedActivity(speaker.name, workPhrase(status.live.bots[speaker.id]) ?? l10n.botsTyping),
          );
    final rows = transcriptRows(chat.items, pending: chat.pending, typing: typing);
    final topInset = BotChatHeader.heightOf(context);
    final readOnly = status.readOnly != null;

    return BotChatFrame(
      header: BotChatHeader(
        face: RoomAvatar(room: room, team: team, size: BotChatHeader.faceSize),
        title: room.name,
        status: label,
        tone: tone,
        scrolledUnder: _scrolled,
        onDetails: () => Navigator.of(context).push(RoomDetailsPage.route(room.id)),
      ),
      body: chat.loading && chat.items.isEmpty
          ? Padding(
              padding: EdgeInsets.only(top: topInset),
              child: const QuietSpinner(),
            )
          : BotTranscript(
              rows: rows,
              topInset: topInset,
              scrolledUnder: _scrolled,
              hasEarlier: chat.hasEarlier,
              loadingEarlier: chat.loadingEarlier,
              onEarlier: () => ref.read(roomChatProvider(widget.roomId).notifier).loadEarlier(),
              empty: _Members(room: room, team: team),
              rowBuilder: (context, row) => Padding(
                padding: rowPadding(row),
                child: switch (row) {
                  BotTimeRow(:final time) => BotTimeLine(time),
                  BotPendingRow(:final pending) => BotUserMessage(text: pending.text, pending: true),
                  BotStreamingRow() => const SizedBox.shrink(),
                  BotTypingRow(:final bot, :final label) => BotTypingLine(bot: bot, label: label),
                  BotItemRow(:final item, :final continued) => switch (item.kind) {
                    DsBotItemKind.user => BotUserMessage(text: item.text, images: item.images),
                    DsBotItemKind.bot => GroupMessage(
                      item: item,
                      bot: team.bot(item.botId),
                      continued: continued,
                      admin: item.botId != null && item.botId == room.admin,
                      onOpenBot: team.bot(item.botId) == null
                          ? null
                          : () => Navigator.of(context).push(BotChatPage.route(item.botId!)),
                      onShowAll: item.whole == null ? null : () => _showAll(item, fullTextScope),
                    ),
                    DsBotItemKind.event => BotEventLine(
                      text: roomEventText(item),
                      danger: item.event == 'failed',
                      icon: switch (item.event) {
                        'done' => AppIcons.completed,
                        'working' => AppIcons.working,
                        'approval' => AppIcons.approval,
                        'failed' => AppIcons.error,
                        'schedule' => AppIcons.scheduled,
                        _ => null,
                      },
                    ),
                    _ => const SizedBox.shrink(),
                  },
                },
              ),
            ),
      bottom: [
        if (room.paused)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ChatCard(
              key: const ValueKey('room-paused'),
              icon: AppIcons.paused,
              title: l10n.commonPaused,
              tone: ChatCardTone.attention,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, ChatCard.inset),
                  child: FilledButton.icon(
                    key: const ValueKey('room-continue'),
                    onPressed:
                        api == null || readOnly || _continuing || _continuedPause == room.pausedCallIds.join('\u0000')
                        ? null
                        : () => _continue(room, continueTarget),
                    icon: const Icon(AppIcons.play, size: 18),
                    label: Text(l10n.commonContinue),
                  ),
                ),
              ],
            ),
          ),
        for (final approval in approvals)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: api == null
                ? GroupApprovalCard(approval: approval, bot: team.bot(approval.botId), onAnswer: null)
                : RoomApprovalAction(
                    key: ValueKey((
                      status.host,
                      status.hello?.boot,
                      api,
                      approval.id,
                      approval.sessionId,
                      approval.botId,
                      approval.roomId,
                    )),
                    api: api,
                    origin: status,
                    approval: approval,
                    builder: (answer) =>
                        GroupApprovalCard(approval: approval, bot: team.bot(approval.botId), onAnswer: answer),
                  ),
          ),
        ListenableBuilder(
          listenable: _mentions,
          builder: (context, _) => AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            switchInCurve: AppMotion.enter,
            switchOutCurve: AppMotion.exit,
            child: _mentions.isOpen
                ? Padding(
                    key: const ValueKey('mentions'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: BotMentionPicker(controller: _mentions),
                  )
                : const SizedBox(key: ValueKey('none'), width: double.infinity),
          ),
        ),
        BotErrorSlot(
          error: chat.error,
          onDismiss: () => ref.read(roomChatProvider(widget.roomId).notifier).dismissError(),
        ),
        Composer(
          hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
          controller: _input,
          placeholder: l10n.botsGroupComposerHint,
          focusNode: _focus,
          connected: api != null && !readOnly,
          running: chat.running,
          onSend: () => _send(sendTarget),
          onStop: _stopGuard.action(roomId: room.id),
          onKeyEvent: _mentions.handleKey,
          leading: MentionKey(
            onPressed: api == null || readOnly
                ? null
                : () {
                    _mentions.start();
                    _focus.requestFocus();
                  },
          ),
        ),
      ],
    );
  }
}

/// A member waiting for the user's approval inside the group.
class GroupApprovalCard extends StatefulWidget {
  const GroupApprovalCard({super.key, required this.approval, required this.bot, required this.onAnswer});

  final DsBotApproval approval;
  final DsBot? bot;

  /// Null on a read-only team: both keys disabled.
  final Future<void> Function(bool allow)? onAnswer;

  @override
  State<GroupApprovalCard> createState() => _GroupApprovalCardState();
}

class _GroupApprovalCardState extends State<GroupApprovalCard> {
  bool _busy = false;

  Future<void> _answer(bool allow) async {
    final answer = widget.onAnswer;
    // A second tap can land before the rebuild that disables the keys.
    if (_busy || answer == null) return;
    setState(() => _busy = true);
    try {
      await answer(allow);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final name = widget.bot?.name ?? 'Bot';
    final reason = widget.approval.reason.trim();
    return ChatCard(
      icon: AppIcons.approval,
      title: approvalPhrase(name, widget.approval.tool),
      tone: ChatCardTone.attention,
      children: [
        if (reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, 4),
            child: Text(
              reason,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 8, ChatCard.inset, ChatCard.inset),
          child: Row(
            spacing: 12,
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy || widget.onAnswer == null ? null : () => _answer(false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Text(l10n.botsDecline),
                ),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || widget.onAnswer == null ? null : () => _answer(true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.botsAllowOnce),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The empty group: who is in it.
class _Members extends StatelessWidget {
  const _Members({required this.room, required this.team});

  final DsBotRoom room;
  final DsBotTeam team;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final names = [for (final id in room.members) ?team.bot(id)?.name];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoomAvatar(room: room, team: team, size: 64),
        const SizedBox(height: 12),
        Text(room.name, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          names.join(l10n.botsNameSeparator),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
        ),
      ],
    );
  }
}
