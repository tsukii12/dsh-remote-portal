// Bot 首页: the DS Bot team of the active
// host. Main Bots pinned first, the other Bots by latest activity, then the
// group chats; each row says who it is, what it said or does, and whether
// something is unread. Without a usable DS Bot, the install card.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/fluid_bits.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';
import 'bot_chat_page.dart';
import 'bot_format.dart';
import 'install_card.dart';
import 'new_bot_page.dart';
import 'new_room_sheet.dart';
import 'room_chat_page.dart';

class BotsPage extends ConsumerWidget {
  const BotsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const BotsPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final team = status.team;
    return AppPage.list(
      title: 'DS Bot',
      subtitle: Text(_summary(status)),
      children: [
        if (status.ready && team != null)
          _Team(status: status, team: team)
        else
          switch (status.availability) {
            DsBotAvailability.offline => const FeatureOffline(),
            DsBotAvailability.relay => FeatureMessage(
              icon: AppIcons.disconnected,
              title: l10n.botsRelayUnavailable,
              body: l10n.botsUseSsh,
            ),
            DsBotAvailability.missing || DsBotAvailability.outdated => DsBotInstallCard(status: status),
            DsBotAvailability.failed => FeatureMessage(
              icon: AppIcons.error,
              title: l10n.botsTeamLoadFailed,
              body: status.error,
              action: (l10n.commonRetry, () => ref.read(dsBotProvider.notifier).retry()),
            ),
            _ => const QuietSpinner(),
          },
      ],
    );
  }
}

/// 「本机 · 4 个 Bot · 2 个群聊」.
String _summary(DsBotStatus status) {
  final team = status.team;
  if (!status.ready || team == null) return status.hostLabel;
  return [
    status.hostLabel,
    appL10n.botsBotCount(team.bots.length),
    if (team.rooms.isNotEmpty) appL10n.botsRoomCount(team.rooms.length),
  ].join(' · ');
}

class _Team extends ConsumerWidget {
  const _Team({required this.status, required this.team});

  final DsBotStatus status;
  final DsBotTeam team;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inbox = ref.watch(dsBotInboxProvider);
    final readOnly = status.readOnly != null;
    DateTime? latest(String id) => inbox.latest[id]?.time;
    int newest(DateTime? a, DateTime? b) => (b ?? DateTime(0)).compareTo(a ?? DateTime(0));
    final mains = [for (final id in team.mainBotIds) ?team.bot(id)];
    final others = [
      for (final bot in team.bots)
        if (!team.isMain(bot.id)) bot,
    ]..sort((a, b) => newest(latest(a.id) ?? a.createdAt, latest(b.id) ?? b.createdAt));
    final rooms = [...team.rooms]..sort((a, b) => newest(latest(a.id) ?? a.createdAt, latest(b.id) ?? b.createdAt));
    var index = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          title: 'Bot',
          children: [
            for (final bot in [...mains, ...others])
              FadeSlideIn(
                index: index++,
                child: BotRow(bot: bot, team: team, live: status.live, inbox: inbox),
              ),
            ListPageRow(
              icon: AppIcons.add,
              title: l10n.botsNewBot,
              leadingWidth: 40,
              chevron: false,
              onTap: readOnly ? null : () => Navigator.of(context).push(NewBotPage.route()),
            ),
          ],
        ),
        const SizedBox(height: 24),
        ListPageCard(
          title: l10n.botsGroupChat,
          children: [
            for (final room in rooms)
              FadeSlideIn(
                index: index++,
                child: RoomRow(room: room, team: team, live: status.live, inbox: inbox),
              ),
            ListPageRow(
              icon: AppIcons.newGroupChat,
              title: l10n.botsNewGroup,
              leadingWidth: 40,
              chevron: false,
              onTap: readOnly || team.bots.length < 2 ? null : () => showNewRoomSheet(context),
            ),
          ],
        ),
        if (readOnly) FeatureNote('${status.readOnly}'),
      ],
    );
  }
}

/// A Bot: avatar (with a dot while it works), name with a 「主」 tag, its last
/// words or what it is doing, the time and an unread count.
class BotRow extends StatelessWidget {
  const BotRow({super.key, required this.bot, required this.team, required this.live, required this.inbox});

  final DsBot bot;
  final DsBotTeam team;
  final DsBotLive live;
  final DsBotInbox inbox;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final work = live.bots[bot.id];
    final doing = workPhrase(work, activity: live.activity[bot.id]);
    final notice = inbox.latest[bot.id];
    final unread = inbox.unreadOf(bot.id);
    final question = team.questionOf(bot) != null || team.viewOf(bot) != null;
    final String subtitle;
    Color? subtitleColor;
    if (doing != null) {
      final room = team.room(work?.roomId);
      subtitle = room == null ? doing : '$doing · ${room.name}';
      subtitleColor = DshColors.of(context).info;
    } else if (question) {
      subtitle = l10n.commonWaitingAnswer;
      subtitleColor = DshColors.of(context).warning;
    } else if (bot.waiting) {
      subtitle = l10n.botsChooseModelStart;
      subtitleColor = DshColors.of(context).warning;
    } else if (notice != null && notice.roomId == null && notice.text.isNotEmpty) {
      subtitle = notice.text;
    } else {
      subtitle = bot.role.isEmpty ? l10n.botsNoChats : bot.role;
    }
    void open() => Navigator.of(context).push(BotChatPage.route(bot.id));
    return Semantics(
      button: true,
      onTap: open,
      label: [
        bot.name,
        if (team.isMain(bot.id)) l10n.botsMainBot,
        subtitle,
        if (unread > 0) l10n.botsUnreadCount(unread),
      ].join(l10n.botsListSeparator),
      excludeSemantics: true,
      child: ListPageRow(
        leading: BotAvatar(bot: bot, size: 40, working: work != null),
        leadingWidth: 40,
        title: bot.name,
        badge: team.isMain(bot.id) ? BotTag(l10n.botsMainTag) : null,
        subtitle: subtitle,
        subtitleColor: subtitleColor,
        meta: notice == null ? null : shortTime(notice.time),
        trailing: unread > 0 ? UnreadBadge(unread) : null,
        chevron: false,
        onTap: open,
      ),
    );
  }
}

/// A group chat: members stacked, its name, the last line or who works.
class RoomRow extends StatelessWidget {
  const RoomRow({super.key, required this.room, required this.team, required this.live, required this.inbox});

  final DsBotRoom room;
  final DsBotTeam team;
  final DsBotLive live;
  final DsBotInbox inbox;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final working = live.rooms[room.id] ?? const <DsBotWork>[];
    final notice = inbox.latest[room.id];
    final unread = inbox.unreadOf(room.id);
    final waiting = live.approvals.any((a) => a.roomId == room.id && a.answerable);
    final String subtitle;
    Color? subtitleColor;
    if (waiting) {
      subtitle = l10n.botsMemberNeedsApproval;
      subtitleColor = DshColors.of(context).warning;
    } else if (working.isNotEmpty) {
      final names = [for (final w in working) team.bot(w.botId)?.name ?? 'Bot'];
      subtitle = names.length == 1
          ? l10n.botsNamedWorking(names.first)
          : l10n.botsNamesWorking(names.take(2).join(l10n.botsNameSeparator));
      subtitleColor = DshColors.of(context).info;
    } else {
      final preview = roomPreview(room, team);
      subtitle = preview.isEmpty ? l10n.botsMemberCount(room.members.length) : preview;
    }
    void open() => Navigator.of(context).push(RoomChatPage.route(room.id));
    return Semantics(
      button: true,
      onTap: open,
      label: [room.name, subtitle, if (unread > 0) l10n.botsUnreadCount(unread)].join(l10n.botsListSeparator),
      excludeSemantics: true,
      child: ListPageRow(
        leading: RoomAvatar(room: room, team: team, size: 40),
        leadingWidth: 40,
        title: room.name,
        subtitle: subtitle,
        subtitleColor: subtitleColor,
        meta: notice == null ? null : shortTime(notice.time),
        trailing: unread > 0 ? UnreadBadge(unread) : null,
        chevron: false,
        onTap: open,
      ),
    );
  }
}

/// Count of unread messages: a primary capsule, round for one digit.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge(this.count, {super.key});

  final int count;

  static const height = 20.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: height, minHeight: height, maxHeight: height),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: scheme.primary, shape: const StadiumBorder()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            widthFactor: 1,
            child: RollingCount(
              count > 99 ? '99+' : '$count',
              textScaler: TextScaler.noScaling,
              style: AppType.tabular(
                Theme.of(context).textTheme.labelSmall!
                    .copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w600, height: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small quiet tag after a name (「主」「管理员」).
class BotTag extends StatelessWidget {
  const BotTag(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.07),
        shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusXs),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          textScaler: TextScaler.noScaling,
          style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary, height: 1.2),
        ),
      ),
    );
  }
}
