// A draft (STAGE2-IMPLEMENTATION-R3 §6): its changes by resource, each with
// what it was and what it becomes; the ones ticked go to the real card or
// book with 应用, or to a new one with 另存为新的. The AI changes the draft
// from the box at the bottom and never the real thing.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_authoring.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../../tavern/tavern_usage_summary.dart';
import '../bots/bot_format.dart' show shortTime;
import '../bots/bot_sheets.dart' show confirmDelete;
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../providers/provider_widgets.dart' show FormBottomBar;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_page.dart';
import 'tavern_draft_history_page.dart';
import 'tavern_draft_prompt_page.dart';
import 'tavern_draft_trial_page.dart';
import 'tavern_pack_export_page.dart';

class TavernDraftPage extends ConsumerStatefulWidget {
  const TavernDraftPage({super.key, required this.draftId});

  final String draftId;

  static Route<void> route(String draftId) =>
      MaterialPageRoute<void>(builder: (_) => TavernDraftPage(draftId: draftId));

  @override
  ConsumerState<TavernDraftPage> createState() => _TavernDraftPageState();
}

class _TavernDraftPageState extends ConsumerState<TavernDraftPage> {
  late final Tavern _tavern = ref.read(tavernProvider);
  final _input = TextEditingController();

  TavernAuthoringDraft? _draft;
  bool _loaded = false;

  /// The ticked changes. New ones arrive ticked.
  final _selected = <String>{};
  Set<String> _known = {};

  /// The static check of the ticked changes, for the revision it was run on.
  TavernAuthoringPreview? _check;

  /// An apply or save-as under way, by resource: its operation id, kept until
  /// the engine answers so that trying again sends the very same one.
  final _operations = <String, String>{};

  /// What became of the last apply or save-as, by resource.
  final _outcomes = <String, String>{};

  /// Resources whose saved base is behind the real one: apply needs 按现在的继续.
  final _behind = <String>{};

  /// Changes the real one took on this visit; 按现在的继续 leaves them out.
  final _applied = <String>{};
  bool _busy = false;

  // The AI run on screen.
  TavernAuthoringRun? _run;
  StreamSubscription<TavernAuthoringRunEvent>? _events;
  String _asked = '';
  String _answer = '';
  TavernAuthoringRunStatus? _status;
  String? _runError;

  /// What the last run's requests reported using.
  TavernUsageSummary? _usage;
  List<TavernAuthoringRunSummary> _runs = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load(attach: true));
  }

  @override
  void dispose() {
    // Leaving does not stop the AI: it finishes and is here next time.
    unawaited(_events?.cancel());
    _input.dispose();
    super.dispose();
  }

  Future<void> _load({bool attach = false}) async {
    final draft = await _tavern.readAuthoringDraft(widget.draftId);
    final runs = await _tavern.listAuthoringRuns(draftId: widget.draftId, limit: 20);
    if (!mounted) return;
    setState(() {
      _draft = draft;
      _loaded = true;
      _runs = runs;
      if (draft != null) {
        final ids = {for (final c in draft.changes) c.id};
        _selected
          ..retainAll(ids)
          ..addAll(ids.difference(_known));
        _known = ids;
      }
    });
    if (draft != null) unawaited(_recheck());
    // One still running from before: follow it (the same id never asks again).
    if (attach && _run == null) {
      if (runs.where((r) => r.status == TavernAuthoringRunStatus.running).firstOrNull case final running?) {
        final snapshot = await _tavern.readAuthoringRun(running.runId);
        if (snapshot != null && mounted) {
          _follow(_tavern.startAuthoringRun(snapshot.request), snapshot.request.instruction);
        }
      }
    }
  }

  Future<void> _recheck() async {
    final draft = _draft;
    if (draft == null || _selected.isEmpty) {
      setState(() => _check = null);
      return;
    }
    try {
      final check = await _tavern.previewAuthoringDraft(
        draft.id,
        draftRevision: draft.draftRevision,
        changeIds: _ticked,
      );
      if (mounted && _draft?.draftRevision == check.draftRevision) setState(() => _check = check);
    } on TavernAuthoringException {
      // A newer revision is on its way; it is checked when it arrives.
      if (mounted) setState(() => _check = null);
    }
  }

  void _toggle(TavernAuthoringChange change, bool on) {
    final changes = _draft!.changes;
    setState(() {
      if (on) {
        _selected.addAll(tavernDraftWithDependencies([change.id], changes));
      } else {
        _selected.removeAll(tavernDraftWithDependents([change.id], changes));
      }
    });
    unawaited(_recheck());
  }

  // AI ----------------------------------------------------------------------

  void _ask() {
    final draft = _draft;
    final text = _input.text.trim();
    if (draft == null || text.isEmpty || _run != null) return;
    final TavernAuthoringRun run;
    try {
      run = _tavern.startAuthoringRun(
        TavernAuthoringRunRequest(
          runId: tavernNewId(),
          draftId: draft.id,
          draftRevision: draft.draftRevision,
          instruction: text,
        ),
      );
    } on TavernAuthoringException catch (e) {
      // Refused before it began (the draft moved on, say): the text stays.
      showBriefNotice(context, e.message);
      return;
    }
    _input.clear();
    _follow(run, text);
  }

  void _follow(TavernAuthoringRun run, String asked) {
    setState(() {
      _run = run;
      _asked = asked;
      _answer = '';
      _status = TavernAuthoringRunStatus.running;
      _runError = null;
      _usage = null;
    });
    _events = run.events.listen((event) {
      if (!mounted) return;
      setState(() {
        _status = event.status;
        switch (event.kind) {
          case TavernAuthoringRunEventKind.snapshot:
            _answer = event.snapshot?.answer ?? _answer;
          case TavernAuthoringRunEventKind.text:
            _answer += event.delta ?? '';
          case TavernAuthoringRunEventKind.request || TavernAuthoringRunEventKind.terminal:
            break;
          case TavernAuthoringRunEventKind.receipt:
            unawaited(_load());
        }
      });
    });
    unawaited(() async {
      try {
        final done = await run.result;
        if (mounted) {
          setState(() {
            _status = done.status;
            _usage = TavernUsageSummary.fromJson(done.usage);
            _answer = done.answer;
          });
        }
      } on Object catch (e) {
        if (mounted) setState(() => _runError = '$e'.split('\n').first);
      }
      await _events?.cancel();
      _events = null;
      if (!mounted) return;
      setState(() => _run = null);
      await _load();
    }());
  }

  // Apply, save as, catch up ------------------------------------------------

  /// Every ticked change, in the draft's order: what the prompt and the trial
  /// put in.
  List<String> get _ticked => [
    for (final c in _draft!.changes)
      if (_selected.contains(c.id)) c.id,
  ];

  /// The ticked changes of [source] not applied yet, in the draft's order.
  List<String> _picked(TavernAuthoringSource source) => [
    for (final c in _draft!.changes)
      if (c.physicalResourceId == source.physicalResourceId && _selected.contains(c.id) && !_applied.contains(c.id))
        c.id,
  ];

  Future<void> _apply(TavernAuthoringSource source) async {
    final draft = _draft!;
    final l10n = context.l10n;
    final id = source.physicalResourceId;
    final name = tavernDraftSourceName(l10n, source);
    final picked = _picked(source);
    final operation = _operations[id] ??= tavernNewId();
    setState(() => _busy = true);
    try {
      final receipt = await _tavern.applyAuthoringChanges(
        draft.id,
        draftRevision: draft.draftRevision,
        physicalResourceId: id,
        changeIds: picked,
        expectedAuthorityRevision: source.authorityRevision!,
        operationId: operation,
      );
      _operations.remove(id);
      _outcomes[id] = _receiptText(l10n, receipt, name);
      // Its base is the old one now: more changes to it go in after 按现在的继续.
      if (receipt.committed ?? true) _behind.add(id);
      if (receipt.committed == true) {
        _applied.addAll(picked);
        // The character page behind this one shows the card as it is now.
        ref.invalidate(tavernCharacterDetailProvider);
      }
    } on TavernAuthoringException catch (e) {
      _operations.remove(id);
      _failed(l10n, e, source, name);
    } on Object catch (e) {
      // Not answered: the same operation goes again on the next tap.
      _outcomes[id] = l10n.tavernDraftApplyUnknown('$e'.split('\n').first);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveAsNew(TavernAuthoringSource source) async {
    final draft = _draft!;
    final l10n = context.l10n;
    final id = source.physicalResourceId;
    final key = 'new:$id';
    final operation = _operations[key] ??= tavernNewId();
    setState(() => _busy = true);
    try {
      final receipt = await _tavern.saveAuthoringAsNew(
        draft.id,
        draftRevision: draft.draftRevision,
        physicalResourceId: id,
        changeIds: _picked(source),
        operationId: operation,
        media: source.origin == TavernAuthoringSourceOrigin.seed
            ? TavernAuthoringMediaSelection.seedCaptured
            : TavernAuthoringMediaSelection.currentSource,
      );
      _operations.remove(key);
      final target = receipt.newTarget;
      _outcomes[id] = receipt.committed == true
          ? l10n.tavernDraftSavedNew
          : _receiptText(l10n, receipt.outcome, tavernDraftSourceName(l10n, source));
      if (receipt.committed == true && target != null && mounted) {
        if (target.kind == TavernAuthoringTargetKind.character) {
          unawaited(Navigator.of(context).push(TavernCharacterPage.route(target.id)));
        } else {
          showBriefNotice(context, l10n.tavernDraftSavedNew);
        }
      }
    } on TavernAuthoringException catch (e) {
      _operations.remove(key);
      _failed(l10n, e, source, tavernDraftSourceName(l10n, source));
    } on Object catch (e) {
      _outcomes[id] = l10n.tavernDraftApplyUnknown('$e'.split('\n').first);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _failed(L10n l10n, TavernAuthoringException e, TavernAuthoringSource source, String name) {
    final id = source.physicalResourceId;
    switch (e.code) {
      case 'authority_conflict' || 'capture_conflict':
        _behind.add(id);
        _outcomes[id] = l10n.tavernDraftBehind(name);
      case 'revision_conflict':
        _outcomes[id] = l10n.tavernDraftChangedMeanwhile;
        unawaited(_load());
      case 'pending_operation' || 'pending_confirmation':
        _outcomes[id] = l10n.tavernDraftPending;
      default:
        _outcomes[id] = e.receipt == null ? e.message : _receiptText(l10n, e.receipt!, name);
    }
  }

  String _receiptText(L10n l10n, TavernAuthoringReceipt receipt, String name) => switch (receipt.state) {
    TavernAuthoringOperationState.adopted || TavernAuthoringOperationState.published => l10n.tavernDraftApplied(name),
    TavernAuthoringOperationState.noChange => l10n.tavernDraftNoChange,
    TavernAuthoringOperationState.notAdopted => l10n.tavernDraftNotApplied(receipt.issue?.message ?? ''),
    TavernAuthoringOperationState.prepared || TavernAuthoringOperationState.unconfirmed => l10n.tavernDraftUnconfirmed,
  };

  /// Takes the real one as the new base for every resource, keeping the
  /// changes not yet applied; the player looks them over again.
  Future<void> _catchUp() async {
    final draft = _draft!;
    setState(() => _busy = true);
    try {
      await _tavern.rebaseAuthoringDraft(
        draft.id,
        draftRevision: draft.draftRevision,
        changes: [
          for (final c in draft.changes)
            if (!_applied.contains(c.id)) c,
        ],
      );
      _behind.clear();
      _applied.clear();
      _outcomes.clear();
    } on TavernAuthoringException catch (e) {
      if (mounted) showBriefNotice(context, e.message);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _removeChange(TavernAuthoringChange change) async {
    final draft = _draft!;
    final gone = tavernDraftWithDependents([change.id], draft.changes);
    try {
      await _tavern.editAuthoringDraft(
        draft.id,
        draftRevision: draft.draftRevision,
        changes: [
          for (final c in draft.changes)
            if (!gone.contains(c.id)) c,
        ],
      );
    } on TavernAuthoringException catch (e) {
      if (mounted) {
        showBriefNotice(context, e.code == 'revision_conflict' ? context.l10n.tavernDraftChangedMeanwhile : e.message);
      }
    }
    await _load();
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final draft = _draft!;
    if (!await confirmDelete(context, title: l10n.tavernDraftDeleteTitle, body: l10n.tavernDraftDeleteBody)) return;
    try {
      await _tavern.deleteAuthoringDraft(draft.id, draftRevision: draft.draftRevision);
    } on TavernAuthoringException catch (e) {
      if (mounted) {
        showBriefNotice(context, e.code == 'revision_conflict' ? l10n.tavernDraftChangedMeanwhile : e.message);
      }
      return;
    }
    ref.invalidate(tavernDraftsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  // UI ----------------------------------------------------------------------

  Future<void> _showChange(TavernAuthoringSource source, TavernAuthoringChange change) {
    final l10n = context.l10n;
    final place = tavernDraftPlace(l10n, change.path);
    final (had, before) = tavernDraftValueAt(source.base, change.path);
    return showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final dsh = DshColors.of(sheet);
        Widget block(String label, String? text) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label, style: theme.textTheme.labelMedium?.copyWith(color: dsh.textTertiary)),
              const SizedBox(height: 6),
              SelectableText(
                text ?? l10n.tavernDraftAbsent,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.55,
                  color: text == null ? dsh.textTertiary : null,
                ),
              ),
            ],
          ),
        );
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(place),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        block(l10n.tavernDraftBefore, had ? tavernDraftValueText(before) : null),
                        block(
                          l10n.tavernDraftAfter,
                          change.operation == TavernAuthoringChangeKind.remove
                              ? null
                              : tavernDraftValueText(change.value),
                        ),
                        if (change.dependsOn.isNotEmpty)
                          Text(
                            l10n.tavernDraftDependsOn(change.dependsOn.length),
                            style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                          ),
                      ],
                    ),
                  ),
                ),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  children: [
                    SettingsTile(
                      key: const ValueKey('tavern-draft-change-remove'),
                      icon: AppIcons.delete,
                      danger: true,
                      tinted: false,
                      chevron: false,
                      title: l10n.tavernDraftRemoveChange,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_removeChange(change));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _source(TavernAuthoringSource source) {
    final l10n = context.l10n;
    final draft = _draft!;
    final id = source.physicalResourceId;
    final changes = [
      for (final c in draft.changes)
        if (c.physicalResourceId == id) c,
    ];
    final findings = _check?.issues[id] ?? const <TavernImportFinding>[];
    final picked = _picked(source);
    final seed = source.origin == TavernAuthoringSourceOrigin.seed;
    final canApply = source.applySupported && !seed;
    final outcome = _outcomes[id];
    final dsh = DshColors.of(context);
    return Column(
      key: ValueKey('tavern-draft-source-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: seed
              ? l10n.tavernDraftNewSource(tavernDraftSourceName(l10n, source))
              : tavernDraftSourceName(l10n, source),
          footer: switch ((canApply, seed)) {
            (false, false) => Text(l10n.tavernDraftCannotApply),
            _ when outcome != null => Text(outcome, key: ValueKey('tavern-draft-outcome-$id')),
            _ => null,
          },
          children: [
            if (changes.isEmpty)
              SettingsTile(title: l10n.tavernDraftNoChanges, subtitle: l10n.tavernDraftNoChangesHint, chevron: false),
            for (final change in changes)
              _ChangeTile(
                key: ValueKey('tavern-draft-change-${change.id}'),
                change: change,
                place: tavernDraftPlace(l10n, change.path),
                selected: _selected.contains(change.id),
                applied: _applied.contains(change.id),
                onSelected: (on) => _toggle(change, on),
                onTap: () => unawaited(_showChange(source, change)),
              ),
            for (final finding in findings)
              SettingsTile(
                icon: finding.kind == TavernImportFindingKind.invalid ? AppIcons.error : AppIcons.info,
                tinted: false,
                danger: finding.kind == TavernImportFindingKind.invalid,
                title: finding.message,
                subtitle: tavernDraftPlace(l10n, finding.path),
                chevron: false,
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canApply && _behind.contains(id))
                FilledButton.tonal(
                  key: ValueKey('tavern-draft-catch-up-$id'),
                  onPressed: _busy ? null : () => unawaited(_catchUp()),
                  child: Text(l10n.tavernDraftCatchUp),
                )
              else if (canApply)
                FilledButton(
                  key: ValueKey('tavern-draft-apply-$id'),
                  onPressed: _busy || picked.isEmpty ? null : () => unawaited(_apply(source)),
                  child: Text(l10n.tavernDraftApply(picked.length)),
                ),
              if (seed)
                FilledButton(
                  key: ValueKey('tavern-draft-save-new-$id'),
                  onPressed: _busy ? null : () => unawaited(_saveAsNew(source)),
                  child: Text(l10n.tavernDraftSaveNew),
                )
              else if (source.target.kind == TavernAuthoringTargetKind.character ||
                  source.target.kind == TavernAuthoringTargetKind.lorebook)
                OutlinedButton(
                  key: ValueKey('tavern-draft-save-new-$id'),
                  onPressed: _busy ? null : () => unawaited(_saveAsNew(source)),
                  child: Text(l10n.tavernDraftSaveNew),
                ),
              if (source.target.kind == TavernAuthoringTargetKind.character)
                OutlinedButton(
                  key: ValueKey('tavern-draft-pack-$id'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(Navigator.of(context).push(TavernPackDraftExportPage.route(_draft!, id))),
                  child: Text(l10n.tavernPackDraftExport),
                ),
              if (findings.isEmpty && picked.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    l10n.tavernDraftChecked,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The AI's last answer, or the one under way: what was asked, what it said,
  /// how it ended.
  Widget? _conversation() {
    final l10n = context.l10n;
    if (_status == null) return null;
    final theme = Theme.of(context);
    final running = _run != null;
    return SettingsSection(
      key: const ValueKey('tavern-draft-ai'),
      title: l10n.tavernDraftAiTitle,
      footer: Text(
        [
          _runError ?? _statusText(l10n, _status!),
          if (_usage case final usage?) tavernDraftUsageText(l10n, usage),
        ].join(' · '),
        key: const ValueKey('tavern-draft-ai-status'),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_asked, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              if (_answer.isEmpty && running)
                const Align(alignment: Alignment.centerLeft, child: QuietSpinner())
              else
                SelectableText(_answer, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55)),
            ],
          ),
        ),
      ],
    );
  }

  static String _statusText(L10n l10n, TavernAuthoringRunStatus status) => switch (status) {
    TavernAuthoringRunStatus.running => l10n.tavernDraftAiRunning,
    TavernAuthoringRunStatus.completed => l10n.tavernDraftAiDone,
    TavernAuthoringRunStatus.cancelled => l10n.tavernDraftAiStopped,
    TavernAuthoringRunStatus.conflict => l10n.tavernDraftAiConflict,
    TavernAuthoringRunStatus.budget => l10n.tavernDraftAiBudget,
    TavernAuthoringRunStatus.failed => l10n.tavernDraftAiFailed,
    TavernAuthoringRunStatus.interrupted => l10n.tavernDraftAiInterrupted,
  };

  Widget _composer() {
    final l10n = context.l10n;
    final running = _run != null;
    return FormBottomBar(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('tavern-draft-ask'),
              controller: _input,
              minLines: 1,
              maxLines: 5,
              enabled: !running,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(hintText: l10n.tavernDraftAskHint),
            ),
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            key: const ValueKey('tavern-draft-send'),
            icon: running ? AppIcons.stop : AppIcons.send,
            tooltip: running ? l10n.tavernDraftAiStop : l10n.tavernDraftAiSend,
            onPressed: running ? () => unawaited(_run!.cancel()) : _ask,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final draft = _draft;
    if (!_loaded || draft == null) {
      return AppPage.list(
        title: l10n.tavernDraft,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: _loaded
                ? EmptyView(icon: AppIcons.article, title: l10n.tavernDraftGone, compact: true)
                : const Center(child: QuietSpinner()),
          ),
        ],
      );
    }
    final applicable = [
      for (final s in draft.sources)
        if (s.applySupported && s.origin == TavernAuthoringSourceOrigin.existing) s,
    ];
    final conversation = _conversation();
    final earlier = [
      for (final r in _runs)
        if (r.runId != _run?.runId) r,
    ];
    final page = AppPage(
      title: draft.sources.length == 1 ? tavernDraftSourceName(l10n, draft.sources.single) : l10n.tavernDraft,
      subtitle: Text(l10n.tavernDraftSubtitle),
      actions: [
        if (applicable.length == 1)
          GlassIconButton(
            key: const ValueKey('tavern-draft-history'),
            icon: AppIcons.history,
            tooltip: l10n.tavernDraftHistory,
            onPressed: () => unawaited(Navigator.of(context).push(TavernDraftHistoryPage.route(applicable.single))),
          ),
        if (draft.sources.any((s) => s.target.kind == TavernAuthoringTargetKind.character)) ...[
          GlassIconButton(
            key: const ValueKey('tavern-draft-prompt'),
            icon: AppIcons.preview,
            tooltip: l10n.tavernDraftPrompt,
            onPressed: () =>
                unawaited(Navigator.of(context).push(TavernDraftPromptPage.route(draft: draft, changeIds: _ticked))),
          ),
          GlassIconButton(
            key: const ValueKey('tavern-draft-trial'),
            icon: AppIcons.play,
            tooltip: l10n.tavernDraftTrial,
            onPressed: () =>
                unawaited(Navigator.of(context).push(TavernDraftTrialPage.route(draft: draft, changeIds: _ticked))),
          ),
        ],
        GlassIconButton(
          key: const ValueKey('tavern-draft-delete'),
          icon: AppIcons.delete,
          tooltip: l10n.tavernDraftDelete,
          onPressed: _busy || _run != null ? null : () => unawaited(_delete()),
        ),
      ],
      slivers: [
        SliverList.list(
          children: [
            for (final source in draft.sources) _source(source),
            ?conversation,
            if (earlier.isNotEmpty)
              SettingsSection(
                key: const ValueKey('tavern-draft-runs'),
                title: l10n.tavernDraftEarlier,
                children: [
                  for (final run in earlier.take(5))
                    _RunTile(key: ValueKey('tavern-draft-run-${run.runId}'), summary: run),
                ],
              ),
            const SizedBox(height: FormBottomBar.height + 24),
          ],
        ),
      ],
    );
    return Stack(
      children: [
        page,
        // Outside the page's own Scaffold: the field needs a Material of its own.
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: Material(type: MaterialType.transparency, child: _composer()),
        ),
      ],
    );
  }
}

/// One change: ticked or not, where, and what it becomes in a line or two.
class _ChangeTile extends StatelessWidget {
  const _ChangeTile({
    super.key,
    required this.change,
    required this.place,
    required this.selected,
    required this.applied,
    required this.onSelected,
    required this.onTap,
  });

  final TavernAuthoringChange change;
  final String place;
  final bool selected;

  /// Already in the real one: shown as such, no longer to tick.
  final bool applied;
  final ValueChanged<bool> onSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final after = applied
        ? l10n.tavernDraftAppliedChange
        : change.operation == TavernAuthoringChangeKind.remove
        ? l10n.tavernDraftRemoved
        : tavernDraftValueText(change.value).replaceAll('\n', ' ');
    return InkWell(
      onTap: onTap,
      splashFactory: rowSplash(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, SettingsMetrics.inset, 6),
        child: Row(
          children: [
            Checkbox(value: selected || applied, onChanged: applied ? null : (on) => onSelected(on ?? false)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(place, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    after,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.4),
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

/// An earlier ask: when, how it ended; a tap shows what was asked and said.
class _RunTile extends ConsumerWidget {
  const _RunTile({super.key, required this.summary});

  final TavernAuthoringRunSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return SettingsTile(
      icon: AppIcons.askAi,
      tinted: false,
      title: _TavernDraftPageState._statusText(l10n, summary.status),
      value: Text(shortTime(summary.createdAt.toLocal())),
      onTap: () => unawaited(_open(context, ref)),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final run = await ref.read(tavernProvider).readAuthoringRun(summary.runId);
    if (run == null || !context.mounted) return;
    final l10n = context.l10n;
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final dsh = DshColors.of(sheet);
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.75),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(_TavernDraftPageState._statusText(l10n, run.status)),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          run.request.instruction,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        SelectableText(run.answer, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55)),
                        const SizedBox(height: 12),
                        Text(
                          [
                            l10n.tavernDraftRunReceipts(
                              run.receipts.where((r) => r.status == TavernAuthoringToolStatus.succeeded).length,
                              run.requests.length,
                            ),
                            if (TavernUsageSummary.fromJson(run.usage) case final usage?)
                              tavernDraftUsageText(l10n, usage),
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                        ),
                        for (final issue in run.issues)
                          Text(issue.message, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
