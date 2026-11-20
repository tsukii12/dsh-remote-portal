// The Agent Teams panel as a detail page. DSH Web's experimental
// `dsh-experimental-client-ui-agent-team` shows
// the roster and the shared task board in a header popover; here they are a
// page with the team's messages added (what members received in their
// inboxes), reachable from the chat header and the feature hub. With the
// bundle off the page offers to switch it on.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart';
import '../../state/connection_state.dart';
import '../../state/models_state.dart';
import '../../state/plugins_state.dart';
import '../../state/sessions_state.dart';
import '../chat/model_sheet.dart' show modelShortName;
import '../chat/widgets/live_clock.dart' show runClock;
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../common/status_chip.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../features/feature_widgets.dart' show FeatureOffline;
import '../plugins/plugin_actions.dart' show togglePluginBundle;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'agent_widgets.dart';

enum _TeamTab { members, tasks, messages }

class TeamPage extends ConsumerStatefulWidget {
  const TeamPage({super.key, this.sessionId});

  /// A conversation of the team (the Lead or a teammate); null: the
  /// conversation on screen.
  final String? sessionId;

  static Route<void> route({String? sessionId}) =>
      MaterialPageRoute<void>(builder: (_) => TeamPage(sessionId: sessionId));

  @override
  ConsumerState<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends ConsumerState<TeamPage> {
  _TeamTab _tab = _TeamTab.members;
  bool _enabling = false;

  Future<void> _enable(PluginBundle bundle) async {
    setState(() => _enabling = true);
    await togglePluginBundle(context, bundle, true);
    if (!mounted) return;
    setState(() => _enabling = false);
  }

  void _open(String leadId, TeamMember member) {
    if (member.lead) {
      selectConversation(ref, member.id);
    } else {
      selectSubagent(
        ref,
        SubagentAddress(parentSessionId: leadId, childSessionId: member.id, mode: SubagentMode.continuable),
      );
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sessionId = widget.sessionId ?? ref.watch(currentSessionProvider);
    final connected = ref.watch(activeConnectionProvider).value != null;
    if (!connected) {
      return AppPage.list(title: l10n.botsAgentTeam, children: const [FeatureOffline()]);
    }
    if (sessionId == null) {
      return AppPage.list(
        title: l10n.botsAgentTeam,
        children: [
          EmptyView(icon: AppIcons.team, title: l10n.botsOpenChatFirst, padding: EdgeInsets.fromLTRB(32, 40, 32, 24)),
        ],
      );
    }
    final leadId = ref.watch(subagentParentProvider(sessionId))?.address.parentSessionId ?? sessionId;
    final async = ref.watch(teamProvider(leadId));
    final team = async.value;
    if (team == null) {
      return AppPage.list(
        title: l10n.botsAgentTeam,
        children: [
          if (async.isLoading)
            const QuietSpinner()
          else
            _TeamOff(
              enabling: _enabling,
              onEnable: _enable,
              onRetry: () => ref.read(teamProvider(leadId).notifier).refresh(),
            ),
        ],
      );
    }
    return _TeamView(
      leadId: leadId,
      currentId: sessionId,
      team: team,
      tab: _tab,
      onTab: (tab) => setState(() => _tab = tab),
      onOpen: (member) => _open(leadId, member),
    );
  }
}

/// The bundle is off (or this host doesn't offer it, or it is on but the
/// Lead has no Team projection yet).
class _TeamOff extends ConsumerWidget {
  const _TeamOff({required this.enabling, required this.onEnable, required this.onRetry});

  final bool enabling;
  final ValueChanged<PluginBundle> onEnable;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final bundle = ref.watch(agentTeamBundleProvider);
    final row = bundle.value;
    final canSwitch = row != null && row.readOnlyReason == null && !ref.watch(localSafeModeProvider);
    if (bundle.isLoading && row == null) return const QuietSpinner();
    if (row != null && row.enabled) {
      return EmptyView(
        icon: AppIcons.team,
        title: l10n.botsTeamReadFailed,
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
        actionLabel: l10n.commonRetry,
        onAction: onRetry,
      );
    }
    return EmptyView(
      icon: AppIcons.team,
      title: row == null ? l10n.botsNoTeamOnHost : l10n.botsTeamNotEnabled,
      message: row == null ? null : l10n.botsTeamDescription,
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
      action: !canSwitch
          ? null
          : FilledButton(
              onPressed: enabling ? null : () => onEnable(row),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              child: Text(enabling ? l10n.botsTeamEnabling : l10n.botsTeamEnable),
            ),
    );
  }
}

class _TeamView extends ConsumerWidget {
  const _TeamView({
    required this.leadId,
    required this.currentId,
    required this.team,
    required this.tab,
    required this.onTab,
    required this.onOpen,
  });

  final String leadId;
  final String currentId;
  final TeamSnapshot team;
  final _TeamTab tab;
  final ValueChanged<_TeamTab> onTab;
  final ValueChanged<TeamMember> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessions = ref.watch(hostSessionsProvider);
    final members = teamMembers(team, sessions);
    final leadTitle = sessions[leadId]?.title?.trim();
    final running = members.where((m) => m.running).length;
    final done = team.tasks.where((t) => t.status == 'completed').length;
    final colors = DshColors.of(context);

    final content = switch (tab) {
      _TeamTab.members => _MembersTab(members: members, currentId: currentId, onOpen: onOpen),
      _TeamTab.tasks => _TasksTab(tasks: team.tasks),
      _TeamTab.messages => _MessagesTab(leadId: leadId, members: members),
    };

    return AppPage(
      title: l10n.botsAgentTeam,
      hero: PageHero(
        leading: _AvatarStack(names: [for (final m in members) m.member.name]),
        title: leadTitle == null || leadTitle.isEmpty ? l10n.botsAgentTeam : leadTitle,
        subtitle: Row(
          children: [
            StatusDot(tone: running > 0 ? StatusTone.busy : StatusTone.idle, size: 6),
            const SizedBox(width: 6),
            Flexible(child: Text(running > 0 ? l10n.botsMembersWorking(running) : l10n.botsTeamStandby)),
          ],
        ),
        stats: [
          ('${members.length}', l10n.botsMembers),
          ('${team.tasks.length}', l10n.botsTasks),
          ('$done', l10n.commonCompleted),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            if (team.failure case final failure?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: ListPageCard(
                  margin: EdgeInsets.zero,
                  children: [
                    ListPageRow(
                      icon: AppIcons.error,
                      iconColor: colors.danger,
                      title: l10n.botsTeamRecordUnreadable,
                      subtitle: failure,
                      subtitleMaxLines: 3,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SegmentedPill<_TeamTab>(
                segments: [
                  PillSegment(_TeamTab.members, l10n.botsMembers),
                  PillSegment(_TeamTab.tasks, l10n.botsTasks),
                  PillSegment(_TeamTab.messages, l10n.botsMessages),
                ],
                selected: tab,
                onChanged: onTab,
              ),
            ),
            AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
              child: KeyedSubtree(key: ValueKey(tab), child: content),
            ),
          ],
        ),
      ],
    );
  }
}

/// Up to four overlapping avatars (the hero's graphic).
class _AvatarStack extends StatelessWidget {
  const _AvatarStack({required this.names});

  final List<String> names;

  static const size = 40.0;
  static const step = 26.0;

  @override
  Widget build(BuildContext context) {
    final shown = names.take(names.length > 4 ? 3 : 4).toList();
    final rest = names.length - shown.length;
    final ring = DshSurfaces.of(context).backdropTop;
    final count = shown.length + (rest > 0 ? 1 : 0);
    if (count == 0) {
      return const SizedBox.square(dimension: size);
    }
    return SizedBox(
      width: size + step * (count - 1),
      height: size,
      child: Stack(
        children: [
          for (final (i, name) in shown.indexed)
            Positioned(
              left: step * i,
              child: AgentAvatar(name, size: size, ring: ring),
            ),
          if (rest > 0)
            Positioned(
              left: step * shown.length,
              child: AgentAvatar('+$rest', size: size, ring: ring),
            ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 成员

class _MembersTab extends ConsumerWidget {
  const _MembersTab({required this.members, required this.currentId, required this.onOpen});

  final List<TeamMemberView> members;
  final String currentId;
  final ValueChanged<TeamMember> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final catalog = ref.watch(modelCatalogProvider).value;
    final sessions = ref.watch(hostSessionsProvider);
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    final lone = members.where((m) => !m.member.lead).isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          children: [
            for (final (i, view) in members.indexed)
              FadeSlideIn(
                index: i,
                child: Builder(
                  builder: (context) {
                    final m = view.member;
                    final current = m.id == currentId;
                    final duty = m.lead ? l10n.botsOwner : sessions[m.id]?.projections.subagentIdentity?.label;
                    final model = view.model == null ? null : modelShortName(view.model, catalog);
                    final failed = m.error != null;
                    return AgentRow(
                      name: m.name,
                      title: m.name,
                      badge: current ? const _CurrentTag() : null,
                      subtitle: Text(
                        failed ? m.error! : [?duty, ?model].join(' · '),
                        style: failed ? TextStyle(color: colors.danger) : null,
                      ),
                      tone: agentTone(view.state),
                      stateLabel: view.stateLabel,
                      onTap: current || m.phase != 'active' ? null : () => onOpen(m),
                    );
                  },
                ),
              ),
          ],
        ),
        if (lone)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Text(
              l10n.botsTeamCreateHint,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
          ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

class _CurrentTag extends StatelessWidget {
  const _CurrentTag();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: ShapeDecoration(
        color: colors.infoContainer,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(AppShape.sm)),
      ),
      child: Text(l10n.botsCurrent, style: theme.textTheme.labelSmall?.copyWith(color: colors.onInfoContainer)),
    );
  }
}

// -----------------------------------------------------------------------------
// 任务

class _TasksTab extends StatelessWidget {
  const _TasksTab({required this.tasks});

  final List<TeamTask> tasks;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (tasks.isEmpty) {
      return EmptyView(
        icon: AppIcons.todo,
        title: l10n.botsNoTasks,
        compact: true,
        padding: EdgeInsets.fromLTRB(32, 24, 32, 24),
      );
    }
    final groups = [
      (
        l10n.botsTodo,
        [
          for (final t in tasks)
            if (t.status == 'pending') t,
        ],
      ),
      (
        l10n.commonInProgress,
        [
          for (final t in tasks)
            if (t.status == 'in_progress') t,
        ],
      ),
      (
        l10n.commonDone,
        [
          for (final t in tasks)
            if (t.status == 'completed') t,
        ],
      ),
    ];
    var index = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (title, list) in groups)
          if (list.isNotEmpty) ...[
            ListPageCard(
              title: '$title · ${list.length}',
              children: [
                for (final task in list)
                  FadeSlideIn(
                    index: index++,
                    child: _TaskRow(task: task),
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        SizedBox(height: MediaQuery.paddingOf(context).bottom),
      ],
    );
  }
}

/// A task's state glyph: ready / blocked / in progress / done.
Widget _taskGlyph(BuildContext context, TeamTask task) {
  final colors = DshColors.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (task.status) {
    'completed' => Icon(AppIcons.success, size: 20, color: colors.success),
    'in_progress' => const StatusDot(tone: StatusTone.busy, size: 10),
    _ when !task.ready => Icon(AppIcons.taskBlocked, size: 20, color: colors.warning),
    _ => Icon(AppIcons.pending, size: 20, color: scheme.outline),
  };
}

String _taskSubtitle(TeamTask task) => [
  task.ownerName ?? appL10n.botsUnassigned,
  if (task.status == 'pending' && !task.ready && task.blockedBy.isNotEmpty)
    appL10n.botsTaskWaitingFor(task.blockedBy.join(appL10n.botsNameSeparator)),
  task.id,
].join(' · ');

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final TeamTask task;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return ListPageRow(
      leading: _taskGlyph(context, task),
      title: task.subject,
      titleMaxLines: 2,
      subtitle: task.warnings.isNotEmpty ? l10n.botsWriteOverlap : _taskSubtitle(task),
      subtitleColor: task.warnings.isNotEmpty ? colors.warning : null,
      onTap: () => _showTask(context, task),
    );
  }
}

Future<void> _showTask(BuildContext context, TeamTask task) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      final colors = DshColors.of(context);
      final state = switch (task.status) {
        'completed' => (context.l10n.commonCompleted, StatusTone.ok),
        'in_progress' => (context.l10n.commonInProgress, StatusTone.busy),
        _ when !task.ready => (context.l10n.botsWaitingDependencies, StatusTone.warn),
        _ => (context.l10n.botsReadyToStart, StatusTone.idle),
      };
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(task.subject),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, MediaQuery.paddingOf(context).bottom + 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusChip(tone: state.$2, label: state.$1),
                    if (task.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      SelectableText(task.description.trim(), style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
                    ],
                    const SizedBox(height: 20),
                    SheetGroup(
                      margin: EdgeInsets.zero,
                      children: [
                        _Fact(context.l10n.botsOwner, task.ownerName ?? context.l10n.botsUnassigned),
                        _Fact(context.l10n.botsTaskId, task.id),
                        if (task.blockedBy.isNotEmpty)
                          _Fact(context.l10n.botsDependencies, task.blockedBy.join(context.l10n.botsNameSeparator)),
                        if (task.writeScopes.isNotEmpty)
                          _Fact(context.l10n.botsWriteScopes, task.writeScopes.join('\n')),
                      ],
                    ),
                    for (final warning in task.warnings) ...[
                      const SizedBox(height: 12),
                      Text(warning, style: theme.textTheme.bodySmall?.copyWith(color: colors.warning)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListPageRow(title: label, value: value);
}

// -----------------------------------------------------------------------------
// 消息

class _MessagesTab extends ConsumerWidget {
  const _MessagesTab({required this.leadId, required this.members});

  final String leadId;
  final List<TeamMemberView> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(teamMessagesProvider(leadId));
    final snapshot = async.value;
    final retry = async.isLoading ? null : () => ref.invalidate(teamMessagesProvider(leadId));
    // Same size and place as the empty inbox: both sit under the tabs.
    final failure = EmptyView(
      icon: AppIcons.conversations,
      title: l10n.botsMessagesReadFailed,
      actionLabel: retry == null ? null : l10n.commonRetry,
      onAction: retry,
      compact: true,
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
    );
    if (snapshot == null) {
      return async.hasError ? failure : const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 40));
    }
    final messages = snapshot.messages;
    final incomplete = async.hasError || snapshot.unreadableMembers.isNotEmpty;
    if (messages.isEmpty && incomplete) return failure;
    if (messages.isEmpty) {
      return EmptyView(
        icon: AppIcons.conversations,
        title: l10n.botsNoMemberMessages,
        compact: true,
        padding: EdgeInsets.fromLTRB(32, 24, 32, 24),
      );
    }
    final names = {for (final m in members) m.member.id: m.member.name};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // What was read stays; one line says some is missing and retries.
        // 16 below it, as the tabs keep 16 above it: centred between them.
        if (incomplete)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Center(
              child: TextButton(onPressed: retry, child: Text(l10n.botsMessagesIncomplete)),
            ),
          ),
        ListPageCard(
          children: [
            for (final (i, message) in messages.indexed)
              FadeSlideIn(
                index: i,
                child: _MessageRow(
                  message: message,
                  from: message.senderName ?? names[message.senderId] ?? l10n.botsMembers,
                  to: names[message.recipientId] ?? l10n.botsMembers,
                ),
              ),
          ],
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message, required this.from, required this.to});

  final TeamMessage message;
  final String from;
  final String to;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return InkWell(
      onTap: () => _showMessage(context, from, to, message),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ListPageRow.horizontal, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: ListPageRow.glyphSlot,
              child: Center(child: AgentAvatar(from, size: 32)),
            ),
            const SizedBox(width: ListPageRow.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: from),
                              TextSpan(
                                text: '  →  ',
                                style: TextStyle(color: colors.textTertiary),
                              ),
                              TextSpan(text: to),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontSize: 14),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _clock(message.time),
                        style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message.text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「14:08」, or 「10月23日 14:08」 for an earlier day.
String _clock(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = now ?? runClock();
  final hm =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  final sameDay = local.year == today.year && local.month == today.month && local.day == today.day;
  return sameDay ? hm : appL10n.botsDateTime(appL10n.monthDay(local), hm);
}

Future<void> _showMessage(BuildContext context, String from, String to, TeamMessage message) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar('$from → $to'),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, MediaQuery.paddingOf(context).bottom + 20),
              child: SelectableText(message.text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6)),
            ),
          ),
        ],
      ),
    ),
  );
}
