// 新建 / 编辑自动化任务 (a form page): name, instruction,
// the run time (repeat choice, clock, days, interval, date, 高级 cron, time
// zone) with a live description and the next runs, and — for a new task —
// where it runs (conversation, workspace, model). One pinned primary button.
//
// Edits go through `schedule/update` (the stored record as `expected`, a
// `change` only when the run time changed). The Host has no create Remote:
// like the official 「新建」, a new task is created by the conversation's
// model with `schedule_create`, from an exact request this page writes; the
// page waits for the task to appear in the catalog.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' hide SettingsSection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/connection_state.dart';
import '../../../state/features_state.dart';
import '../../../state/hosts_state.dart';
import '../../../state/models_state.dart';
import '../../../state/schedule_editor_state.dart';
import '../../../state/sessions_state.dart';
import '../../chat/model_sheet.dart';
import '../../chat/widgets/question_card.dart';
import '../../common/discard_guard.dart';
import '../../common/smooth_size.dart';
import '../../providers/provider_widgets.dart';
import '../../settings/settings_widgets.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../feature_widgets.dart';
import 'cron.dart';
import 'schedule_authorization.dart';
import 'schedule_draft.dart';
import 'schedule_pickers.dart';
import 'time_zones.dart';

/// The Host's limit on a task name.
const maxScheduleTitle = 120;

/// Pops with the created or saved task.
class ScheduleEditorPage extends ConsumerStatefulWidget {
  const ScheduleEditorPage({super.key, this.task, this.now});

  /// Null for a new task.
  final ScheduleTask? task;

  /// Clock override (tests).
  final DateTime? now;

  @override
  ConsumerState<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

enum _F { title, prompt, timing }

class _ScheduleEditorPageState extends ConsumerState<ScheduleEditorPage> {
  late final _title = TextEditingController(text: widget.task?.title ?? '');
  late final _prompt = TextEditingController(text: widget.task?.prompt ?? '');
  final _interval = TextEditingController();
  final _cron = TextEditingController();
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  ScheduleDraft? _draft;
  ScheduleDraft? _initial;

  /// Create only: null = a new conversation.
  String? _sessionId;
  String? _workspaceId;
  ModelSelection? _model;

  bool _saving = false;
  ScheduleAuthorization? _authorization;
  String? _authorizationError;
  Map<_F, String> _errors = const {};
  String? _formError;

  /// The conversation a failed creation request went to.
  String? _failedSession;

  bool get _isEdit => widget.task != null;

  /// A rule the builder can't state: shown, not edited, so saving a new name or
  /// instruction can't turn it into what the builder would read it as.
  bool get _customRule => _isEdit && isCustomRule(widget.task!);
  DateTime get _now => widget.now ?? DateTime.now();

  /// The fields as opened (timing compares [_draft] with [_initial]).
  late String _clean;
  late final Listenable _edits = Listenable.merge([_title, _prompt, _interval, _cron]);

  String _signature() => jsonEncode([
    _title.text,
    _prompt.text,
    _interval.text,
    _cron.text,
    _sessionId,
    _workspaceId,
    _model?.provider,
    _model?.model,
    _model?.reasoningEffort,
  ]);

  @override
  void initState() {
    super.initState();
    _clean = _signature();
  }

  @override
  void dispose() {
    _authorization?.dispose();
    _authorization = null;
    _title.dispose();
    _prompt.dispose();
    _interval.dispose();
    _cron.dispose();
    super.dispose();
  }

  void _start(String deviceZone) {
    final task = widget.task;
    final draft = task == null
        ? ScheduleDraft.initial(timeZone: deviceZone, now: _now)
        : ScheduleDraft.fromTask(task, deviceZone: deviceZone, now: _now);
    _draft = draft;
    _initial = draft;
    _interval.text = '${draft.interval}';
    _cron.text = draft.expression;
    _clean = _signature();
  }

  void _update(ScheduleDraft next) {
    setState(() {
      _draft = next;
      _formError = null;
      _errors = {..._errors}..remove(_F.timing);
    });
  }

  void _edited(_F field) {
    if (_errors.containsKey(field) || _formError != null) {
      setState(() {
        _errors = {..._errors}..remove(field);
        _formError = null;
      });
    }
  }

  Future<void> _pickKind(ScheduleDraft draft) async {
    final kind = await showChoiceSheet<RepeatKind>(
      context,
      title: context.l10n.featuresRepeat,
      selected: draft.kind,
      choices: [for (final MapEntry(:key, :value) in repeatLabels.entries) Choice(key, value)],
    );
    if (kind == null || !mounted) return;
    final next = _draft!.withKind(kind);
    if (kind == RepeatKind.cron) _cron.text = next.expression;
    _interval.text = '${next.interval}';
    _update(next);
  }

  Future<void> _pickClock(ScheduleDraft draft) async {
    final picked = await showClockSheet(context, hour: draft.hour, minute: draft.minute);
    if (picked == null || !mounted) return;
    if ((picked.$1, picked.$2) == (draft.hour, draft.minute)) return;
    _update(_draft!.copyWith(hour: picked.$1, minute: picked.$2));
  }

  Future<void> _pickDate(ScheduleDraft draft) async {
    final today = inZone(_now, draft.timeZone) ?? _now;
    final first = DateTime.utc(today.year, today.month, today.day);
    final picked = await showDaySheet(context, date: draft.date.isBefore(first) ? first : draft.date, first: first);
    if (picked == null || !mounted) return;
    _update(_draft!.copyWith(date: picked));
  }

  Future<void> _pickMonthDays(ScheduleDraft draft) async {
    final picked = await showMonthDaysSheet(context, days: draft.monthDays);
    if (picked == null || !mounted) return;
    _update(_draft!.copyWith(monthDays: picked));
  }

  Future<void> _pickZone(ScheduleDraft draft, String device) async {
    final picked = await showZoneSheet(context, selected: draft.timeZone, device: device, at: _now);
    if (picked == null || !mounted) return;
    _update(_draft!.copyWith(timeZone: picked));
  }

  Future<void> _pickConversation(List<SessionSummary> sessions) async {
    final picked = await showChoiceSheet<String>(
      context,
      title: context.l10n.featuresChat,
      selected: _sessionId ?? '',
      choices: [
        Choice('', context.l10n.commonNewChat, icon: AppIcons.newChat),
        for (final s in sessions.take(40)) Choice(s.sessionId, _sessionTitle(s), icon: AppIcons.chat),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() => _sessionId = picked.isEmpty ? null : picked);
  }

  Future<void> _pickWorkspace(List<Workspace> workspaces) async {
    final picked = await showChoiceSheet<String>(
      context,
      title: context.l10n.featuresWorkspace,
      selected: _workspaceId ?? '',
      choices: [
        Choice('', context.l10n.commonDefault, icon: AppIcons.workspace),
        for (final w in workspaces)
          Choice(w.workspaceId, _workspaceTitle(w), subtitle: w.path, icon: AppIcons.workspace),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() => _workspaceId = picked.isEmpty ? null : picked);
  }

  void _pickModel(ModelSelection? current) =>
      showModelSheet(context, current: current, onSelected: (m) => setState(() => _model = m));

  Map<_F, String> _validate(ScheduleDraft draft) {
    final title = _title.text.trim();
    return {
      if (title.isEmpty) _F.title: context.l10n.featuresNameRequired,
      if (_prompt.text.trim().isEmpty) _F.prompt: context.l10n.featuresInstructionRequired,
      if (!_customRule) _F.timing: ?draft.validate(_now),
    };
  }

  void _showErrors(Map<_F, String> errors) {
    setState(() => _errors = errors);
    if (errors.isEmpty) return;
    final first = _F.values.firstWhere(errors.containsKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _fieldKeys[first]!.currentContext;
      if (target == null || !target.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: AppMotion.of(context, AppMotion.emphasized),
          curve: AppMotion.glide,
        ),
      );
    });
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _formError = null;
      _failedSession = null;
    });
    final errors = _validate(draft);
    _showErrors(errors);
    if (errors.isNotEmpty) return;
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null) return setState(() => _formError = context.l10n.commonEngineUnreachable);
    final authorization = ScheduleAuthorization(
      conn.client,
      sessionId: widget.task?.sessionId ?? _sessionId,
      onChanged: _authorizationChanged,
    );
    _authorization = authorization;
    setState(() {
      _saving = true;
      _authorizationError = null;
    });
    try {
      await authorization.start();
      if (!_currentSave(authorization)) return;
      if (widget.task case final task?) {
        await _saveEdit(authorization, task, draft);
      } else {
        await _create(authorization, draft);
      }
    } on Object catch (e) {
      if (_currentSave(authorization)) {
        setState(() => _formError = context.l10n.featuresScheduleSaveError(_short(e)));
      }
    } finally {
      if (identical(_authorization, authorization)) {
        _authorization = null;
        authorization.dispose();
        if (mounted) setState(() => _saving = false);
      }
    }
  }

  bool _currentSave(ScheduleAuthorization authorization) =>
      mounted &&
      identical(_authorization, authorization) &&
      authorization.active &&
      identical(ref.read(activeConnectionProvider).value?.client, authorization.client);

  void _authorizationChanged() {
    if (mounted) setState(() => _authorizationError = null);
  }

  Future<void> _answerAuthorization(
    ScheduleAuthorization authorization,
    UserQuestionRequest request,
    List<QuestionAnswer>? answers,
  ) async {
    if (!_currentSave(authorization)) return;
    try {
      if (answers == null) {
        await authorization.reject(request);
      } else {
        await authorization.answer(request, answers);
      }
    } on Object catch (e) {
      if (_currentSave(authorization)) {
        setState(() => _authorizationError = context.l10n.featuresScheduleSaveError(_short(e)));
      }
    }
  }

  Future<void> _saveEdit(ScheduleAuthorization authorization, ScheduleTask task, ScheduleDraft draft) async {
    final client = authorization.client;
    final title = _title.text.trim();
    final prompt = _prompt.text.trim();
    final timing = draft == _initial ? null : draft.toTiming();
    if (title == task.title && prompt == task.prompt && timing == null) {
      Navigator.of(context).pop(task);
      return;
    }
    try {
      final result = await client.editSchedule(
        task,
        title: title == task.title ? null : title,
        prompt: prompt == task.prompt ? null : prompt,
        timing: timing,
      );
      if (!mounted || !_currentSave(authorization)) return;
      ref.invalidate(schedulesProvider);
      if (result.task case final saved?) {
        Navigator.of(context).pop(saved);
        return;
      }
      setState(() => _formError = scheduleUpdateError(result.code));
    } on Object catch (e) {
      if (_currentSave(authorization)) setState(() => _formError = context.l10n.featuresScheduleSaveError(_short(e)));
    }
  }

  Future<void> _create(ScheduleAuthorization authorization, ScheduleDraft draft) async {
    final client = authorization.client;
    String? sessionId = _sessionId;
    try {
      sessionId ??= await startConversation(ref, ConversationPlan(workspaceId: _workspaceId, model: _model));
      if (!_currentSave(authorization)) return;
      authorization.setSession(sessionId);
      final title = _title.text.trim();
      final created = await requestSchedule(
        client,
        sessionId: sessionId,
        title: title,
        request: scheduleCreateRequest(
          title: title,
          prompt: _prompt.text.trim(),
          timing: draft.toTiming()!,
          rule: draft.describe(now: _now),
        ),
        timeZone: ref.read(deviceTimeZoneProvider).value,
      );
      if (!mounted || !_currentSave(authorization)) return;
      ref.invalidate(schedulesProvider);
      Navigator.of(context).pop(created);
    } on ScheduleCreateFailure catch (f) {
      if (_currentSave(authorization)) {
        setState(() {
          _formError = context.l10n.featuresScheduleCreateError(f.message);
          _failedSession = sessionId;
          // A retry goes to the same conversation, not another new one.
          _sessionId = sessionId;
        });
      }
    } on Object catch (e) {
      if (_currentSave(authorization)) {
        setState(() {
          _formError = context.l10n.featuresScheduleCreateError(_short(e));
          _failedSession = sessionId;
          _sessionId = sessionId;
        });
      }
    }
  }

  void _abandonSave() {
    final authorization = _authorization;
    if (authorization == null) return;
    _authorization = null;
    authorization.dispose();
    setState(() {
      _saving = false;
      _authorizationError = null;
      _formError = context.l10n.commonEngineUnreachable;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeHostProvider, (_, _) => _abandonSave());
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (_, client) {
      if (_authorization case final authorization? when !identical(authorization.client, client)) _abandonSave();
    });
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final connected = ref.watch(activeConnectionProvider).value != null;
    final device = ref.watch(deviceTimeZoneProvider).value;
    if (_draft == null && device != null) _start(device);
    final draft = _draft;

    final List<Widget> body;
    if (draft == null || device == null) {
      body = const [FeatureLoading()];
    } else {
      body = [
        SettingsSection(
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  key: _fieldKeys[_F.title],
                  error: _errors[_F.title],
                  label: l10n.commonName,
                  child: TextField(
                    controller: _title,
                    enabled: !_saving,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [LengthLimitingTextInputFormatter(maxScheduleTitle)],
                    onChanged: (_) => _edited(_F.title),
                    decoration: InputDecoration(
                      hintText: l10n.featuresScheduleNameHint,
                      error: _errors[_F.title] == null ? null : const SizedBox.shrink(),
                    ),
                  ),
                ),
                FormFieldBlock(
                  key: _fieldKeys[_F.prompt],
                  error: _errors[_F.prompt],
                  label: l10n.featuresScheduleInstruction,
                  child: TextField(
                    controller: _prompt,
                    enabled: !_saving,
                    minLines: 4,
                    maxLines: 12,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
                    onChanged: (_) => _edited(_F.prompt),
                    decoration: InputDecoration(
                      hintText: l10n.featuresScheduleInstructionHint,
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(color: colors.textTertiary, height: 1.45),
                      error: _errors[_F.prompt] == null ? null : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          key: _fieldKeys[_F.timing],
          title: l10n.featuresScheduleRunTime,
          children: _timingRows(draft, device),
        ),
        if (!_customRule)
          Padding(
            padding: kSettingsGroupMargin,
            child: SchedulePreview(
              draft: draft,
              deviceZone: device,
              now: _now,
              anchor: _isEdit && draft == _initial && widget.task!.kind == 'every' ? widget.task!.scheduledAt : null,
            ),
          ),
        if (!_isEdit) _placeSection(),
        SmoothSize(
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.std,
          alignment: Alignment.topCenter,
          child: _formError == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(_formError!, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
                      ),
                      if (_failedSession case final id?)
                        FormSmallButton(
                          label: l10n.featuresScheduleOpenChat,
                          onPressed: () => openSessionInChat(context, ref, id),
                        ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: FormBottomBar.height),
      ];
    }

    final page = AppPage.list(
      title: _isEdit ? l10n.featuresScheduleEditTitle : l10n.featuresScheduleCreateTitle,
      children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body)],
    );
    final label = switch ((_saving, _isEdit)) {
      (true, true) => l10n.featuresScheduleSaving,
      (true, false) => l10n.featuresScheduleCreating,
      (false, true) => l10n.commonSave,
      (false, false) => l10n.commonCreate,
    };
    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && (_draft != _initial || _signature() != _clean),
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                onPressed: !connected || _saving || draft == null ? null : _save,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                          ),
                          const SizedBox(width: 10),
                          Text(label),
                        ],
                      )
                    : Text(connected ? label : l10n.featuresWaitingEngine),
              ),
            ),
          ),
          if (_authorization case final authorization? when authorization.requests.isNotEmpty)
            Positioned.fill(
              child: Material(
                color: scheme.surface,
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Align(alignment: Alignment.centerLeft, child: BackButton()),
                        QuestionCard(
                          key: ValueKey(authorization.requests.first.eventId),
                          request: authorization.requests.first,
                          onAnswer: (request, answers) => _answerAuthorization(authorization, request, answers),
                          onReject: (request) => _answerAuthorization(authorization, request, null),
                        ),
                        if (_authorizationError case final error?)
                          Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _timingRows(ScheduleDraft draft, String device) {
    final l10n = context.l10n;
    if (_customRule) return [SettingsTile(title: l10n.featuresRepeat, value: Text(l10n.featuresRepeatCustom))];
    final enabled = !_saving;
    final rows = <Widget>[
      SettingsTile(
        title: l10n.featuresRepeat,
        value: Text(repeatLabels[draft.kind]!),
        onTap: enabled ? () => _pickKind(draft) : null,
      ),
    ];
    final clock = SettingsTile(
      title: l10n.featuresTime,
      value: Text(draft.clockLabel, style: AppType.tabular(const TextStyle())),
      onTap: enabled ? () => _pickClock(draft) : null,
    );
    switch (draft.kind) {
      case RepeatKind.daily:
      case RepeatKind.weekdays:
        rows.add(clock);
      case RepeatKind.weekly:
        rows
          ..add(
            WeekdayPicker(
              selected: draft.weekdays,
              onChanged: enabled ? (days) => _update(_draft!.copyWith(weekdays: days)) : null,
            ),
          )
          ..add(clock);
      case RepeatKind.monthly:
        final days = draft.monthDays.toList()..sort();
        rows
          ..add(
            SettingsTile(
              title: l10n.featuresDate,
              value: Text(
                days.isEmpty
                    ? l10n.featuresNotSelected
                    : l10n.featuresMonthDaysLabel(days.join(l10n.featuresListSeparator)),
              ),
              onTap: enabled ? () => _pickMonthDays(draft) : null,
            ),
          )
          ..add(clock);
      case RepeatKind.interval:
        rows.add(
          IntervalRow(
            controller: _interval,
            unit: draft.unit,
            enabled: enabled,
            onValue: (n) => _update(_draft!.copyWith(interval: n)),
            onUnit: (u) => _update(_draft!.copyWith(unit: u)),
          ),
        );
      case RepeatKind.once:
        final d = draft.date;
        rows
          ..add(
            SettingsTile(
              title: l10n.featuresDate,
              value: Text(
                l10n.featuresDateWeekday(l10n.featuresYearDate(d.year, l10n.monthDay(d)), weekdayNames[d.weekday - 1]),
              ),
              onTap: enabled ? () => _pickDate(draft) : null,
            ),
          )
          ..add(clock);
      case RepeatKind.cron:
        rows.add(
          CronField(
            controller: _cron,
            enabled: enabled,
            onChanged: (v) => _update(_draft!.copyWith(expression: v)),
          ),
        );
    }
    if (draft.kind != RepeatKind.interval) {
      rows.add(
        SettingsTile(
          title: l10n.featuresTimeZone,
          value: Text(zoneLabel(draft.timeZone, at: _now)),
          onTap: enabled ? () => _pickZone(draft, device) : null,
        ),
      );
    }
    return rows;
  }

  Widget _placeSection() {
    final sessions = ref.watch(sessionsProvider).value ?? const <SessionSummary>[];
    final workspaces = ref.watch(hostWorkspacesProvider).value ?? const <Workspace>[];
    final catalog = ref.watch(modelCatalogProvider).value;
    final existing = sessions.where((s) => s.sessionId == _sessionId).firstOrNull;
    final workspace = workspaces.where((w) => w.workspaceId == _workspaceId).firstOrNull;
    final enabled = !_saving;
    final model = _model ?? catalog?.defaultSelection;
    return SettingsSection(
      title: context.l10n.featuresScheduleRunLocation,
      children: [
        SettingsTile(
          title: context.l10n.featuresChat,
          value: Text(
            existing != null
                ? _sessionTitle(existing)
                : _sessionId == null
                ? context.l10n.commonNewChat
                : context.l10n.featuresJustCreatedChat,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: enabled ? () => _pickConversation(sessions) : null,
        ),
        if (_sessionId == null) ...[
          if (workspaces.isNotEmpty)
            SettingsTile(
              title: context.l10n.featuresWorkspace,
              value: Text(workspace == null ? context.l10n.commonDefault : _workspaceTitle(workspace)),
              onTap: enabled ? () => _pickWorkspace(workspaces) : null,
            ),
          SettingsTile(
            title: context.l10n.featuresModel,
            value: Text(
              model == null
                  ? context.l10n.commonDefault
                  : [
                      modelShortName(model, catalog),
                      if (model.reasoningEffort case final e?) effortLabel(e),
                    ].join(' · '),
            ),
            onTap: enabled ? () => _pickModel(model) : null,
          ),
        ],
      ],
    );
  }
}

String _sessionTitle(SessionSummary s) {
  final title = s.projections.title?.trim();
  return title == null || title.isEmpty ? appL10n.commonUntitledChat : title;
}

String _workspaceTitle(Workspace w) => w.title.trim().isNotEmpty ? w.title.trim() : w.path.split('/').last;

String _short(Object error) => switch (error) {
  ScheduleCreateFailure(:final message) => message,
  DshRemoteException() => appL10n.featuresRequestRefused,
  _ => appL10n.commonEngineUnreachable,
};

/// Short Chinese reason for a refused `schedule/update`.
String scheduleUpdateError(String? code) => switch (code) {
  'schedule_not_found' => appL10n.featuresScheduleNotFound,
  'schedule_ended' => appL10n.featuresScheduleEndedError,
  'schedule_conflict' => appL10n.featuresScheduleConflict,
  'invalid_prompt' => appL10n.featuresScheduleInvalidPrompt,
  'invalid_rule' || 'invalid_selector' => appL10n.featuresScheduleInvalidTime,
  'invalid_time_zone' => appL10n.featuresZoneUnavailable,
  'not_future' => appL10n.featuresChooseFutureTime,
  'frequency_too_high' => appL10n.featuresScheduleIntervalTooShort,
  'time_out_of_range' => appL10n.featuresScheduleTimeOutOfRange,
  'subagent_session' => appL10n.featuresScheduleSubagentError,
  _ => appL10n.commonSaveFailed,
};

// ── Rows ─────────────────────────────────────────────────────────────────────

/// Seven round keys, 一 … 日, spread edge to edge with equal gaps.
class WeekdayPicker extends StatelessWidget {
  const WeekdayPicker({super.key, required this.selected, required this.onChanged});

  final Set<int> selected;
  final ValueChanged<Set<int>>? onChanged;

  static const keySize = 36.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var d = 1; d <= 7; d++)
            DayKey(
              label: weekdayNames[d - 1],
              semanticLabel: l10n.featuresWeekdayName(weekdayNames[d - 1]),
              size: keySize,
              selected: selected.contains(d),
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(selected.contains(d) ? ({...selected}..remove(d)) : {...selected, d}),
            ),
        ],
      ),
    );
  }
}

/// 「间隔」: a number and its unit.
class IntervalRow extends StatelessWidget {
  const IntervalRow({
    super.key,
    required this.controller,
    required this.unit,
    required this.enabled,
    required this.onValue,
    required this.onUnit,
  });

  final TextEditingController controller;
  final IntervalUnit unit;
  final bool enabled;
  final ValueChanged<int> onValue;
  final ValueChanged<IntervalUnit> onUnit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 8),
      child: Row(
        children: [
          Text(l10n.featuresEvery, style: settingsTitleStyle(context)),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            height: 40,
            child: TextField(
              controller: controller,
              enabled: enabled,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              style: AppType.tabular(theme.textTheme.bodyLarge!),
              onChanged: (v) => onValue(int.tryParse(v) ?? 0),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
            ),
          ),
          const Spacer(),
          SegmentedPill<IntervalUnit>(
            height: 40,
            expand: false,
            segments: [
              if (unit == IntervalUnit.second) PillSegment(IntervalUnit.second, IntervalUnit.second.label),
              PillSegment(IntervalUnit.minute, IntervalUnit.minute.label),
              PillSegment(IntervalUnit.hour, IntervalUnit.hour.label),
            ],
            selected: unit,
            onChanged: enabled ? onUnit : null,
          ),
        ],
      ),
    );
  }
}

/// 「高级」: the raw five-field expression, checked as it is typed.
class CronField extends StatelessWidget {
  const CronField({super.key, required this.controller, required this.enabled, required this.onChanged});

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final text = controller.text;
    final error = switch (parseCron(text.trim())) {
      CronError(:final message) when text.trim().isNotEmpty => message,
      _ => null,
    };
    final mono = AppType.mono(size: 16, color: theme.colorScheme.onSurface);
    return FormFieldGroup(
      children: [
        FormFieldBlock(
          label: l10n.featuresCronExpression,
          helper: l10n.featuresCronFieldGuide,
          error: error,
          child: TextField(
            controller: controller,
            enabled: enabled,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            style: mono,
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: '0 9 * * 1-5',
              hintStyle: mono.copyWith(color: colors.textTertiary),
              error: error == null ? null : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

/// The rule in words and its next three runs in this phone's time, or why it
/// can't be saved.
class SchedulePreview extends StatelessWidget {
  const SchedulePreview({super.key, required this.draft, required this.deviceZone, required this.now, this.anchor});

  final ScheduleDraft draft;
  final String deviceZone;
  final DateTime now;

  /// Committed target of an unchanged fixed-rate rule.
  final DateTime? anchor;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final error = draft.validate(now);
    final runs = error == null ? draft.nextRuns(now, anchor: anchor) : const <DateTime>[];
    final foreign = draft.kind != RepeatKind.interval && draft.timeZone != deviceZone;
    final title = [
      if (error == null || draft.kind != RepeatKind.cron) draft.describe(now: now),
      if (foreign && (error == null || draft.kind != RepeatKind.cron))
        l10n.featuresZoneTimeSuffix(zoneCity(draft.timeZone)),
    ].join();
    final quick = AppMotion.of(context, AppMotion.quick);
    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 14, SettingsMetrics.inset, 14),
        child: SmoothSize(
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.std,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: quick,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
            child: Column(
              key: ValueKey('$title|${runs.join(',')}|$error'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title.isNotEmpty)
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                if (error != null) ...[
                  if (title.isNotEmpty) const SizedBox(height: 6),
                  Text(error, style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger)),
                ] else ...[
                  const SizedBox(height: 10),
                  Text(
                    foreign ? l10n.featuresScheduleNextLocal : l10n.featuresScheduleNext,
                    style: theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary),
                  ),
                  const SizedBox(height: 4),
                  for (final run in runs)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        formatRun(run, deviceZone, now),
                        style: AppType.tabular(
                          theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
