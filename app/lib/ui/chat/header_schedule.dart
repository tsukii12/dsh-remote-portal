// The chat header's schedule clock (official `dsh-client-ui-schedule`: an
// icon-only clock in the session header while the open session has active
// reminders; one task opens its detail, more open a list).
//
// Here the clock is a round key inside the title pill, concentric with its
// trailing end, so the header keeps its four mirrored pieces. It reads the
// conversation itself ([headerSchedulesProvider]); the header only places it
// where the pill's own right padding would be. Tapping opens a compact sheet:
// the task's name, rule and next runs, 「立即运行」 and 「管理」 (the native
// detail page). The Host has no pause: the official README states the page
// offers neither pause nor run-now, and the record has no paused state.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/header_schedule_state.dart';
import '../../state/schedule_editor_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../features/schedules_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'header_schedule_format.dart';

/// Rebuilds the moment a time on screen would read differently (a distance
/// drops a unit, a day turns over).
mixin _Retick<T extends StatefulWidget> on State<T> {
  Timer? _retick;

  /// From `build`: rebuild once more after [wait].
  void retickIn(Duration wait) {
    _retick?.cancel();
    _retick = Timer(wait, () {
      if (mounted) setState(() {});
    });
  }

  void stopRetick() {
    _retick?.cancel();
    _retick = null;
  }

  @override
  void dispose() {
    _retick?.cancel();
    super.dispose();
  }
}

/// The title pill's trailing end: a clock key while the conversation has
/// automation tasks, else the pill's own [padding].
///
/// ```
/// ( 修复登录重复提交      )        ( 修复登录重复提交  (◷) )
/// ( ● 本机                )   →    ( ● 本机               )
///                       ↑ 16                    ↑ gap  ↑ inset
/// ```
///
/// The key is a [size] circle with the same [insetFor] gap above, below and
/// to the right, so it sits concentric with the pill's round end at any text
/// size; its touch area is the pill's whole height from [gap] on. When the
/// bar is too tight to keep the title's floor beside it, the header leaves
/// it out (unpainted, untouchable, not read out) rather than shorten the
/// title further; the tasks stay one tap away on 自动化任务.
class HeaderScheduleCap extends ConsumerStatefulWidget {
  const HeaderScheduleCap({super.key, required this.pillHeight});

  /// The title pill's height ([ChatHeader.pillHeightOf]).
  final double pillHeight;

  /// The key's diameter.
  static const size = 36.0;

  /// Between the title and status lines and the key.
  static const gap = 8.0;

  /// The pill's own side padding, which the cap stands in for.
  static const padding = 16.0;

  /// Above, below and to the right of the key: concentric with the pill's
  /// end.
  static double insetFor(double pillHeight) => math.max(0.0, (pillHeight - size) / 2);

  /// How much wider the pill is with the key than with its plain padding.
  static double extraFor(double pillHeight) => gap + size + insetFor(pillHeight) - padding;

  @override
  ConsumerState<HeaderScheduleCap> createState() => _HeaderScheduleCapState();
}

class _HeaderScheduleCapState extends ConsumerState<HeaderScheduleCap> with _Retick<HeaderScheduleCap> {
  bool _pressed = false;

  void _open(HeaderSchedules schedules) {
    final sessionId = schedules.sessionId;
    if (sessionId == null) return;
    HapticFeedback.selectionClick();
    unawaited(showHeaderSchedules(context, sessionId: sessionId, tasks: schedules.tasks));
  }

  @override
  Widget build(BuildContext context) {
    final schedules = ref.watch(headerSchedulesProvider);
    final Widget child;
    if (!schedules.shown) {
      stopRetick();
      child = const SizedBox(key: ValueKey('plain'), width: HeaderScheduleCap.padding);
    } else {
      final now = ref.watch(scheduleClockProvider)();
      // The read-out says 「今天 / 明天」: refresh it at midnight.
      retickIn(untilNextDay(now));
      child = _key(context, schedules, now);
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.quick),
      switchInCurve: AppMotion.std,
      switchOutCurve: AppMotion.std,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerRight, children: [...previous, ?current]),
      child: child,
    );
  }

  Widget _key(BuildContext context, HeaderSchedules schedules, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final inset = HeaderScheduleCap.insetFor(widget.pillHeight);
    // The quiet well of the sheet's round keys; deeper while pressed.
    final alpha = switch ((dark, _pressed)) {
      (false, false) => 0.06,
      (false, true) => 0.12,
      (true, false) => 0.10,
      (true, true) => 0.18,
    };
    void open() => _open(schedules);
    return Semantics(
      key: const ValueKey('cap'),
      container: true,
      button: true,
      label: headerScheduleLabel(schedules.tasks, now),
      onTap: open,
      excludeSemantics: true,
      child: Tooltip(
        message: context.l10n.viewScheduleTitle,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('chat-schedule'),
            onTap: open,
            onHighlightChanged: (on) => setState(() => _pressed = on),
            splashFactory: rowSplash(context),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            child: Padding(
              padding: EdgeInsets.fromLTRB(HeaderScheduleCap.gap, inset, inset, inset),
              child: AnimatedContainer(
                key: const ValueKey('chat-schedule-key'),
                duration: AppMotion.of(context, AppMotion.quick),
                curve: AppMotion.std,
                width: HeaderScheduleCap.size,
                height: HeaderScheduleCap.size,
                decoration: ShapeDecoration(
                  color: scheme.onSurface.withValues(alpha: alpha),
                  shape: const CircleBorder(),
                ),
                child: Icon(AppIcons.scheduled, size: 18, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [sessionId]'s automation tasks: a single task on its own page (the
/// official clock opens that task's detail directly), more as a list.
/// 「管理」 closes the sheet and pushes the task's detail page where
/// [context] lives.
Future<void> showHeaderSchedules(BuildContext context, {required String sessionId, required List<ScheduleTask> tasks}) {
  final navigator = Navigator.of(context);
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (_) => HeaderScheduleSheet(
      sessionId: sessionId,
      single: tasks.length == 1 ? tasks.single : null,
      onManage: (task) =>
          unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => ScheduleDetailPage(task: task)))),
    ),
  );
}

/// The header clock's sheet: [single]'s page, or the conversation's tasks.
class HeaderScheduleSheet extends StatelessWidget {
  const HeaderScheduleSheet({super.key, required this.sessionId, required this.onManage, this.single});

  final String sessionId;

  /// Opens straight on this task's page.
  final ScheduleTask? single;

  /// After the sheet closes: show the task's detail page.
  final ValueChanged<ScheduleTask> onManage;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
    child: SheetNavigator(
      root: (context) => switch (single) {
        final task? => ScheduleTaskSheetPage(sessionId: sessionId, initial: task, onManage: onManage),
        null => ScheduleTaskSheetList(sessionId: sessionId, onManage: onManage),
      },
    ),
  );
}

/// 「没能刷新 · 重试」 under the tasks while the latest read failed (the last
/// ones read stay on screen).
class _RefreshFailed extends ConsumerWidget {
  const _RefreshFailed({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SheetGroup(
    children: [
      ListPageRow(
        icon: AppIcons.error,
        iconColor: DshColors.of(context).warning,
        title: context.l10n.viewScheduleRefreshFailed,
        meta: context.l10n.commonRetry,
        onTap: () => ref.invalidate(sessionSchedulesProvider(sessionId)),
      ),
    ],
  );
}

/// The conversation's tasks, soonest first; a row opens its page.
class ScheduleTaskSheetList extends ConsumerStatefulWidget {
  const ScheduleTaskSheetList({super.key, required this.sessionId, required this.onManage});

  final String sessionId;
  final ValueChanged<ScheduleTask> onManage;

  @override
  ConsumerState<ScheduleTaskSheetList> createState() => _ScheduleTaskSheetListState();
}

class _ScheduleTaskSheetListState extends ConsumerState<ScheduleTaskSheetList> with _Retick<ScheduleTaskSheetList> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final read = ref.watch(sessionSchedulesProvider(widget.sessionId));
    final tasks = read.value ?? const <ScheduleTask>[];
    final now = ref.watch(scheduleClockProvider)();
    final deviceZone = ref.watch(deviceTimeZoneProvider).value;
    var wait = untilNextDay(now);
    for (final task in tasks) {
      if (task.scheduledAt case final at?) {
        final change = scheduleRelativeChangesIn(at, now);
        if (change < wait) wait = change;
      }
    }
    retickIn(wait);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(l10n.viewScheduleTitle),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (tasks.isEmpty)
                  EmptyView(
                    art: FeatureTile(FeatureKind.automation, size: FeatureTile.compact),
                    title: l10n.viewScheduleNone,
                    compact: true,
                  )
                else
                  SheetGroup(children: [for (final task in tasks) _row(context, task, now, deviceZone, colors)]),
                if (read.hasError) _RefreshFailed(sessionId: widget.sessionId),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, ScheduleTask task, DateTime now, String? deviceZone, DshColors colors) {
    final at = task.scheduledAt;
    final overdue = at != null && !at.isAfter(now);
    final rule = scheduleRuleLine(task, deviceZone: deviceZone, at: now);
    final when = at == null
        ? null
        : overdue
        ? scheduleRelative(at, now)
        : context.l10n.viewScheduleNext(scheduleStamp(at, now));
    return ListPageRow(
      icon: task.recurring ? AppIcons.recurring : AppIcons.automation,
      title: task.title.isEmpty ? context.l10n.viewScheduleUntitled : task.title,
      subtitle: when == null ? rule : '$rule · $when',
      subtitleColor: overdue ? colors.warning : null,
      onTap: () => SheetNavigator.of(context)
          .push((_) => ScheduleTaskSheetPage(sessionId: widget.sessionId, initial: task, onManage: widget.onManage)),
    );
  }
}

/// One task: its rule, its next runs on this phone's clock (the first with
/// how far off it is), 「立即运行」 and 「管理」.
///
/// ```
///   日报提醒                         (×)
///   每天 21:30
///     接下来
///   ┌────────────────────────────────┐
///   │ 今天 21:30            6 小时后 │
///   │ 明天 21:30                     │
///   │ 周一 21:30                     │
///   └────────────────────────────────┘
///   [  立即运行  ]  [     管理     ]
/// ```
class ScheduleTaskSheetPage extends ConsumerStatefulWidget {
  const ScheduleTaskSheetPage({super.key, required this.sessionId, required this.initial, required this.onManage});

  final String sessionId;

  /// The task as last seen; the live copy replaces it while it is listed.
  final ScheduleTask initial;
  final ValueChanged<ScheduleTask> onManage;

  /// The actions' height.
  static const actionHeight = 48.0;

  @override
  ConsumerState<ScheduleTaskSheetPage> createState() => _ScheduleTaskSheetPageState();
}

class _ScheduleTaskSheetPageState extends ConsumerState<ScheduleTaskSheetPage> with _Retick<ScheduleTaskSheetPage> {
  late ScheduleTask _task = widget.initial;
  bool _sending = false;
  String? _error;

  Future<void> _runNow() async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) {
      setState(() => _error = appL10n.commonEngineUnreachable);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await runScheduleNow(client, _task, timeZone: ref.read(deviceTimeZoneProvider).value);
      if (!mounted) return;
      HapticFeedback.selectionClick();
      // The instruction lands in this conversation, right under the sheet.
      Navigator.of(context).pop();
    } on Object {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = appL10n.viewScheduleSendFailed;
      });
    }
  }

  void _manage() {
    Navigator.of(context).pop();
    widget.onManage(_task);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final read = ref.watch(sessionSchedulesProvider(widget.sessionId));
    final listed = read.value;
    final live = listed?.where((t) => t.id == _task.id).firstOrNull;
    if (live != null) _task = live;
    // Read and no longer listed: delivered (a one-shot) or deleted.
    final ended = listed != null && live == null;
    final task = _task;
    final now = ref.watch(scheduleClockProvider)();
    final deviceZone = ref.watch(deviceTimeZoneProvider).value;
    final runs = ended ? const <DateTime>[] : scheduleNextRuns(task, deviceZone: deviceZone ?? task.timeZone ?? 'UTC');
    var wait = untilNextDay(now);
    if (runs.firstOrNull case final next?) {
      final change = scheduleRelativeChangesIn(next, now);
      if (change < wait) wait = change;
    }
    retickIn(wait);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final stampStyle = AppType.tabular(theme.textTheme.bodyLarge!.copyWith(fontSize: 15, height: 1.4));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(task.title.isEmpty ? l10n.viewScheduleUntitled : task.title),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
          child: Text(
            scheduleRuleLine(task, deviceZone: deviceZone, at: now),
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ended)
                  SheetGroup(
                    children: [
                      ListPageRow(
                        icon: AppIcons.completed,
                        iconColor: colors.textTertiary,
                        title: l10n.viewScheduleEnded,
                      ),
                    ],
                  )
                else ...[
                  SheetSectionLabel(l10n.viewScheduleUpcoming),
                  // The next run says how far off it is; the ones after it
                  // already read as 「明天」「周一」.
                  SheetGroup(
                    children: [
                      for (final (i, at) in runs.indexed)
                        ListPageRow(
                          title: scheduleStamp(at, now),
                          titleStyle: stampStyle,
                          meta: i == 0 ? scheduleRelative(at, now) : null,
                          metaColor: at.isAfter(now) ? null : colors.warning,
                        ),
                    ],
                  ),
                ],
                if (read.hasError) _RefreshFailed(sessionId: widget.sessionId),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, 12 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SmoothSize(
                duration: AppMotion.of(context, AppMotion.quick),
                curve: AppMotion.std,
                alignment: Alignment.topCenter,
                child: _error == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
                        ),
                      ),
              ),
              SizedBox(
                height: ScheduleTaskSheetPage.actionHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('schedule-run-now'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(ScheduleTaskSheetPage.actionHeight),
                        ),
                        onPressed: _sending ? null : () => unawaited(_runNow()),
                        child: Text(_sending ? l10n.viewScheduleSending : l10n.viewScheduleRunNow),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('schedule-manage'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(ScheduleTaskSheetPage.actionHeight),
                        ),
                        onPressed: _manage,
                        child: Text(l10n.viewScheduleManage),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
