// 群聊详情: members and the admin, how
// the group answers, its notice, members at work (with 「停下」), approvals
// waiting, the group memory.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';
import 'unavailable_message.dart';
import 'bot_action_scope.dart';
import 'bot_chat_page.dart';
import 'bot_format.dart';
import 'bot_sheets.dart';
import 'bots_page.dart' show BotTag;
import 'memory_card.dart';
import 'working_folder_sheet.dart';
import 'room_relay_limit_sheet.dart';
import 'room_chat_page.dart' show GroupApprovalCard;

class RoomDetailsPage extends ConsumerWidget {
  const RoomDetailsPage({super.key, required this.roomId});

  final String roomId;

  static Route<void> route(String roomId) => MaterialPageRoute<void>(builder: (_) => RoomDetailsPage(roomId: roomId));

  Future<void> _update(
    BuildContext context,
    WidgetRef ref,
    BotActionScope scope,
    Future<void> Function(DsBotApi api) call,
  ) async {
    final hub = ref.read(dsBotProvider.notifier);
    if (!context.mounted || !scope.current(context, ref)) return;
    final api = scope.api!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await call(api);
      if (context.mounted && scope.current(context, ref)) await hub.refresh();
    } catch (error) {
      if (context.mounted && scope.current(context, ref)) {
        messenger?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    }
  }

  Future<void> _member(BuildContext context, WidgetRef ref, DsBotRoom room, DsBot bot) async {
    final scope = BotActionScope(ref, roomId: room.id);
    final admin = room.admin == bot.id;
    final action = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(bot.name),
            SheetGroup(
              children: [
                ListPageRow(
                  icon: AppIcons.chat,
                  title: context.l10n.botsPrivateChat,
                  onTap: () => Navigator.pop(sheet, 'chat'),
                ),
                if (!admin)
                  ListPageRow(
                    icon: AppIcons.makeAdmin,
                    title: context.l10n.botsSetAdmin,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'admin'),
                  ),
                if (room.members.length > 2)
                  ListPageRow(
                    icon: AppIcons.removeMember,
                    title: context.l10n.botsRemoveMember,
                    danger: true,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'remove'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!context.mounted || !scope.current(context, ref) || action == null) return;
    switch (action) {
      case 'chat':
        await Navigator.of(context).push(BotChatPage.route(bot.id));
      case 'admin':
        await _update(context, ref, scope, (api) => api.updateRoom(room.id, admin: bot.id));
      case 'remove':
        await _update(context, ref, scope, (api) => api.updateRoom(room.id, remove: [bot.id]));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, DsBotRoom room) async {
    final scope = BotActionScope(ref, roomId: room.id);
    final ok = await confirmDelete(
      context,
      title: context.l10n.botsDeleteNamed(room.name),
      body: context.l10n.botsDeleteRoomBody,
    );
    if (!ok || !context.mounted || !scope.current(context, ref)) return;
    final navigator = Navigator.of(context);
    await _update(context, ref, scope, (api) => api.deleteRoom(room.id));
    // Removal is expected after success; only connection identity may govern navigation.
    if (context.mounted && scope.connected(context, ref) && ref.read(dsBotProvider).team?.room(room.id) == null) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final team = status.team;
    final room = team?.room(roomId);
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
    final dsh = DshColors.of(context);
    final writable = status.readOnly == null;
    final scope = BotActionScope(ref, roomId: room.id);
    final members = [
      for (final id in [if (room.admin != null) room.admin!, ...room.members.where((m) => m != room.admin)])
        ?team.bot(id),
    ];
    final working = {for (final w in status.live.rooms[room.id] ?? const <DsBotWork>[]) w.botId: w};
    final approvals = [
      for (final a in status.live.approvals)
        if (a.roomId == room.id && a.answerable) a,
    ];
    final memory = ref.watch(dsBotMemoryProvider((botId: null, roomId: room.id))).value;
    final adminName = team.bot(room.admin)?.name;
    final subtitle = [
      if (adminName != null) l10n.botsNamedAdmin(adminName),
      if (working.isNotEmpty) l10n.botsRoomWorkingCount(working.length),
    ].join(' · ');
    const gap = SizedBox(height: 24);
    return AppPage(
      title: room.name,
      hero: PageHero(
        leading: RoomAvatar(room: room, team: team, size: 56),
        title: room.name,
        subtitle: Text(subtitle.isEmpty ? l10n.botsGroupChat : subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        stats: [
          ('${room.members.length}', l10n.botsMembers),
          (memory == null ? '—' : '${memory.entries.length}', l10n.botsMemoryUnit),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            if (approvals.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  spacing: 8,
                  children: [
                    for (final approval in approvals)
                      GroupApprovalCard(
                        key: ValueKey(approval.id),
                        approval: approval,
                        bot: team.bot(approval.botId),
                        onAnswer: writable
                            ? (allow) =>
                                  _update(context, ref, scope, (api) => api.answerApproval(approval.id, allow: allow))
                            : null,
                      ),
                  ],
                ),
              ),
              gap,
            ],
            ListPageCard(
              title: l10n.botsMembersCountTitle(members.length),
              children: [
                for (final bot in members)
                  ListPageRow(
                    leading: BotAvatar(bot: bot, size: 32, working: working.containsKey(bot.id)),
                    title: bot.name,
                    badge: room.admin == bot.id ? BotTag(l10n.botsAdmin) : null,
                    subtitle: working.containsKey(bot.id)
                        ? workPhrase(working[bot.id]) ?? l10n.botsWorking
                        : (bot.role.isEmpty ? null : bot.role),
                    subtitleColor: working.containsKey(bot.id) ? dsh.info : null,
                    trailing: working.containsKey(bot.id) && writable
                        ? TextButton(
                            onPressed: () => _update(context, ref, scope, (api) => api.stopMemberWork(room.id, bot.id)),
                            child: Text(l10n.botsStopMember),
                          )
                        : null,
                    chevron: !working.containsKey(bot.id),
                    onTap: writable ? () => _member(context, ref, room, bot) : null,
                  ),
                if (writable && members.length < team.bots.length)
                  ListPageRow(
                    icon: AppIcons.addMember,
                    title: l10n.botsAddMember,
                    chevron: false,
                    onTap: () async {
                      final candidates = [
                        for (final bot in team.bots)
                          if (!room.members.contains(bot.id)) bot,
                      ];
                      final picked = await showBotPickerSheet(context, title: l10n.botsAddMember, bots: candidates);
                      if (picked != null && picked.isNotEmpty && context.mounted) {
                        await _update(context, ref, scope, (api) => api.updateRoom(room.id, add: picked));
                      }
                    },
                  ),
              ],
            ),
            gap,
            ListPageCard(
              title: l10n.commonSettings,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    l10n.botsWhoAnswers,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SegmentedPill<String>(
                    height: 40,
                    segments: [
                      PillSegment('admin', l10n.botsAdminFirst),
                      PillSegment('everyone', l10n.botsEveryoneInTurn),
                    ],
                    selected: room.adminFirst ? 'admin' : 'everyone',
                    onChanged: writable
                        ? (mode) => _update(context, ref, scope, (api) => api.updateRoom(room.id, mode: mode))
                        : (_) {},
                  ),
                ),
                if (room.relayLimitDefault != null)
                  ListPageRow(
                    key: const ValueKey('room-relay-limit'),
                    icon: AppIcons.pause,
                    title: l10n.botsRelayLimit,
                    value: room.relayLimit?.toString() ?? l10n.botsRelayLimitDefault(room.relayLimitDefault!),
                    onTap: writable ? () => showRoomRelayLimitSheet(context, room, scope: scope, ref: ref) : null,
                  ),
                ListPageRow(
                  key: const ValueKey('room-working-folder'),
                  icon: AppIcons.folder,
                  title: l10n.botsWorkingFolder,
                  subtitle: room.workDir ?? l10n.botsFolderRoomDefault,
                  subtitleMaxLines: 3,
                  onTap: () =>
                      showWorkingFolderSheet(context, roomId: room.id, workDir: room.workDir, scope: scope, ref: ref),
                ),
                ListPageRow(
                  icon: AppIcons.rename,
                  title: l10n.botsGroupName,
                  value: room.name,
                  onTap: writable
                      ? () async {
                          final next = await showTextEditSheet(
                            context,
                            title: l10n.botsGroupName,
                            initial: room.name,
                            maxLength: 60,
                          );
                          if (next != null && next != room.name && context.mounted) {
                            await _update(context, ref, scope, (api) => api.updateRoom(room.id, name: next));
                          }
                        }
                      : null,
                ),
                ListPageRow(
                  icon: AppIcons.announcement,
                  title: l10n.botsGroupNotice,
                  subtitle: room.notice.isEmpty ? l10n.commonNotSet : room.notice,
                  subtitleMaxLines: 3,
                  onTap: writable
                      ? () async {
                          final next = await showTextEditSheet(
                            context,
                            title: l10n.botsGroupNotice,
                            initial: room.notice,
                            hint: l10n.botsGroupNoticeHint,
                            maxLength: 2000,
                            multiline: true,
                            allowEmpty: true,
                          );
                          if (next != null && next != room.notice && context.mounted) {
                            await _update(context, ref, scope, (api) => api.updateRoom(room.id, notice: next));
                          }
                        }
                      : null,
                ),
              ],
            ),
            gap,
            BotMemoryCard(roomId: room.id),
            if (writable) ...[
              gap,
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: dsh.danger),
                  onPressed: () => _delete(context, ref, room),
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.botsDeleteGroup),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
