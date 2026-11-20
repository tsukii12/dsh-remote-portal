import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';

/// Asks once a new local candidate completes while the phone page is in front.
///
/// Wraps the whole page, so the question does not depend on the lazily built
/// skill card having been scrolled into view. Existing candidates never cause a
/// burst of prompts on entering the page or enabling the setting.
class PhoneSkillAutoPrompt extends ConsumerStatefulWidget {
  const PhoneSkillAutoPrompt({
    super.key,
    required this.status,
    required this.enabled,
    required this.autoPromptReady,
    required this.promptBaseline,
    required this.child,
  });
  final PhoneSkillStatus status;
  /// The skill card is part of the page (status ready and skills available).
  final bool enabled;
  final bool autoPromptReady;
  final int promptBaseline;
  final Widget child;

  @override
  ConsumerState<PhoneSkillAutoPrompt> createState() => _PhoneSkillAutoPromptState();
}

class _PhoneSkillAutoPromptState extends ConsumerState<PhoneSkillAutoPrompt> {
  bool _presenting = false;
  late final AppLifecycleListener _lifecycle;
  int _visibilityEpoch = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (_) { _visibilityEpoch++; });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PhoneSkillAutoPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new completion can ask while this page is visible; candidates already
    // present when the card appeared, or when the setting was turned on, cannot.
    if (_presenting || !oldWidget.enabled || !widget.enabled || !widget.autoPromptReady ||
        oldWidget.promptBaseline != widget.promptBaseline ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !oldWidget.status.askAfterSuccess || !widget.status.askAfterSuccess) {
      return;
    }
    final previous = {for (final c in oldWidget.status.candidates) (c.taskId, c.generation)};
    for (final candidate in widget.status.candidates) {
      if (previous.contains((candidate.taskId, candidate.generation))) continue;
      _presenting = true;
      final epoch = _visibilityEpoch;
      final baseline = widget.promptBaseline;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_visibilityEpoch != epoch || widget.promptBaseline != baseline || !widget.autoPromptReady ||
            !widget.enabled || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
            ModalRoute.of(context)?.isCurrent != true) {
          _presenting = false;
          return;
        }
        unawaited(_ask(candidate));
      });
      break;
    }
  }

  Future<void> _ask(PhoneSkillCandidate candidate) async {
    await openPhoneSkillCandidate(context, ref, candidate);
    if (mounted) _presenting = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Confirms the goal first; only a confirmed candidate opens the draft editor.
Future<void> openPhoneSkillCandidate(BuildContext context, WidgetRef ref, PhoneSkillCandidate candidate) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.phoneSkillConfirmGoal),
      content: Text(context.l10n.phoneSkillConfirmGoalBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.phoneSkillGoalDone)),
      ],
    ),
  );
  if (!context.mounted || confirmed != true) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PhoneSkillEditor(channel: ref.read(phoneChannelProvider), candidate: candidate),
  );
  if (!context.mounted) return;
  unawaited(ref.read(phoneProvider.notifier).refreshStatus());
}

/// Only offers local, completed native candidates; opening and saving are separate decisions.
class PhoneSkillSection extends ConsumerStatefulWidget {
  const PhoneSkillSection({super.key, required this.status});
  final PhoneSkillStatus status;

  @override
  ConsumerState<PhoneSkillSection> createState() => _PhoneSkillSectionState();
}

class _PhoneSkillSectionState extends ConsumerState<PhoneSkillSection> {
  bool _presenting = false;
  bool _setting = false;

  Future<void> _open(PhoneSkillCandidate candidate) async {
    if (_presenting) return;
    setState(() => _presenting = true);
    await openPhoneSkillCandidate(context, ref, candidate);
    if (!mounted) return;
    setState(() => _presenting = false);
  }

  Future<void> _openResult(PhoneSkillSaveResult result) async {
    if (_presenting) return;
    setState(() => _presenting = true);
    await showDialog<void>(context: context, barrierDismissible: false,
      builder: (_) => PhoneSkillEditor.result(channel: ref.read(phoneChannelProvider), result: result));
    if (!mounted) return;
    setState(() => _presenting = false);
    unawaited(ref.read(phoneProvider.notifier).refreshStatus());
  }

  Future<void> _setPrompt(bool value) async {
    setState(() => _setting = true);
    final ok = await ref.read(phoneProvider.notifier).setSkillSavePrompt(value);
    if (!mounted) return;
    setState(() => _setting = false);
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.phoneSkillUnavailable)));
  }

  @override
  Widget build(BuildContext context) => ListPageCard(
    title: context.l10n.phoneSkillSectionTitle,
    children: [
      ListPageRow(
        icon: AppIcons.bookmark,
        title: context.l10n.phoneSkillAskAfterSuccess,
        subtitle: context.l10n.phoneSkillAskAfterSuccessHint,
        trailing: Switch(value: widget.status.askAfterSuccess, onChanged: _setting ? null : _setPrompt),
        chevron: false,
      ),
      for (final result in widget.status.saveResults)
        ListPageRow(
          icon: AppIcons.bookmark,
          title: result.handle.name,
          subtitle: context.l10n.phoneSkillBundleRevision(result.handle.bundleRevision),
          trailing: TextButton(onPressed: _presenting ? null : () => _openResult(result),
            child: Text(context.l10n.phoneSkillCheckWrite)),
          chevron: false,
        ),
      for (final candidate in widget.status.candidates)
        ListPageRow(
          icon: AppIcons.completed,
          title: context.l10n.phoneSkillTask(candidate.taskId, candidate.steps),
          subtitle: context.l10n.phoneSkillCandidateHint,
          trailing: TextButton(
            onPressed: _presenting ? null : () => _open(candidate),
            child: Text(context.l10n.phoneSkillSaveAction),
          ),
          chevron: false,
        ),
    ],
  );
}

class PhoneSkillEditor extends StatefulWidget {
  const PhoneSkillEditor({super.key, required this.channel, required PhoneSkillCandidate this.candidate})
    : result = null;
  const PhoneSkillEditor.result({super.key, required this.channel, required PhoneSkillSaveResult this.result})
    : candidate = null;
  final PhoneChannel channel;
  final PhoneSkillCandidate? candidate;
  final PhoneSkillSaveResult? result;

  @override
  State<PhoneSkillEditor> createState() => _PhoneSkillEditorState();
}

class _PhoneSkillEditorState extends State<PhoneSkillEditor> {
  final _goal = TextEditingController();
  final _prerequisites = TextEditingController();
  final _checks = <int, TextEditingController>{};
  PhoneSkillDraftView? _draft;
  List<int> _order = [];
  bool _busy = true;
  bool _dirty = false;
  bool _confirmed = false;
  bool _pendingWrite = false;
  bool _closing = false;
  bool _allowPop = false;
  bool _saved = false;
  PhoneSkillDraftView? _writeDraft;
  PhoneSkillSaveHandle? _queryHandle;
  PhoneSkillReply? _unverified;
  String? _savedPath;
  String? _savedBundleRevision;
  String? _error;

  @override
  void initState() {
    super.initState();
    final result = widget.result;
    if (result == null) {
      unawaited(_open());
    } else {
      _queryHandle = result.handle;
      _accept(result.reply);
    }
  }

  Future<void> _open() async {
    final reply = await widget.channel.openSkillDraft(widget.candidate!, confirmed: true);
    if (!mounted) {
      // open can finish after this dialog was removed. Cancel only its returned
      // identity; native open always creates a new id, even for the same task.
      if (reply.draft case final draft?) unawaited(widget.channel.discardSkillDraft(draft));
      return;
    }
    _accept(reply, fromOpen: true);
  }

  bool _matchesWrite(PhoneSkillReply reply) {
    final handle = _queryHandle;
    if (handle != null) return reply.name == handle.name && reply.bundleRevision == handle.bundleRevision;
    final expected = _writeDraft ?? _draft;
    if (expected == null || reply.bundleRevision != expected.bundleRevision) return false;
    if (reply.kind == PhoneSkillReplyKind.saving && expected.bundleRevision == null) return reply.name == null;
    return reply.name == expected.skillName;
  }

  void _accept(PhoneSkillReply reply, {bool fromOpen = false, bool fromQuery = false}) {
    if (!mounted) return;
    final openTerminal = fromOpen && _draft == null && _writeDraft == null;
    setState(() {
      _busy = false;
      _error = null;
      switch (reply.kind) {
        case PhoneSkillReplyKind.shown:
          if (fromQuery || widget.candidate == null) { _error = 'stale'; return; }
          final view = reply.draft!;
          final previous = _draft;
          if (view.taskId != widget.candidate!.taskId || view.generation != widget.candidate!.generation ||
              previous != null && (view.draftId != previous.draftId || view.revision < previous.revision)) {
            _error = 'stale';
            return;
          }
          final frozen = _writeDraft;
          if (_unverified != null || frozen != null && frozen.bundleRevision != null &&
              (view.revision != frozen.revision || view.bundleRevision != frozen.bundleRevision ||
               view.skillName != frozen.skillName)) {
            _error = 'stale';
            return;
          }
          _draft = view;
          _order = [...view.stepOrder];
          for (final index in _order) { _checks.putIfAbsent(index, TextEditingController.new); }
          _dirty = false;
          _confirmed = false;
          _pendingWrite = _writeDraft?.bundleRevision != null || view.phase == 'staging' || view.phase == 'committing';
          if (_pendingWrite && view.bundleRevision != null) _queryHandle ??= PhoneSkillSaveHandle.fromDraft(view);
        case PhoneSkillReplyKind.saved:
          if (!openTerminal && !_matchesWrite(reply)) { _error = 'stale'; _confirmed = false; return; }
          _saved = true;
          _unverified = null;
          _pendingWrite = false;
          _savedPath = reply.relativePath;
          _savedBundleRevision = reply.bundleRevision;
          _goal.clear();
          _prerequisites.clear();
          for (final controller in _checks.values) { controller.clear(); }
        case PhoneSkillReplyKind.unverified:
          if (!openTerminal && (_queryHandle == null && _draft?.bundleRevision == null || !_matchesWrite(reply))) {
            _error = 'stale'; _confirmed = false; return;
          }
          _unverified = reply;
          _pendingWrite = false;
          _confirmed = false;
        case PhoneSkillReplyKind.saving:
          if (!_matchesWrite(reply)) { _error = 'stale'; _confirmed = false; return; }
          _pendingWrite = _unverified == null;
          _confirmed = false;
        case PhoneSkillReplyKind.rejected:
          // Only definite installer failures end a pending write. A transport/stale/busy
          // reply cannot establish whether the write has finished.
          if (!fromQuery && (reply.code == 'io' || reply.code == 'no_home' || reply.code == 'conflict')) {
            _pendingWrite = false;
            _writeDraft = null;
            _queryHandle = null;
          }
          _error = fromQuery && const {'io', 'no_home', 'conflict'}.contains(reply.code) ? 'unavailable' : reply.code;
          _confirmed = false;
        case PhoneSkillReplyKind.discarded:
          _error = 'stale';
      }
    });
  }

  void _changed() => setState(() { _dirty = true; _confirmed = false; });

  Future<void> _applyEdits() async {
    if (_busy || _pendingWrite || _unverified != null || _saved || _closing) return;
    final draft = _draft!;
    setState(() { _busy = true; _confirmed = false; });
    final reply = await widget.channel.editSkillDraft(draft, goal: _goal.text,
      prerequisites: _prerequisites.text, checkpoints: [for (final index in _order) _checks[index]!.text],
      stepOrder: [..._order]);
    _accept(reply);
  }

  Future<void> _save() async {
    if (_busy || _pendingWrite || _unverified != null || _saved || _closing || !_confirmed || _dirty) return;
    final draft = _draft!;
    setState(() {
      _busy = true; _confirmed = false; _writeDraft = draft;
      // Freeze before dispatch: losing this ACK does not establish that no bundle was published.
      if (draft.bundleRevision != null) {
        _pendingWrite = true;
        _queryHandle = PhoneSkillSaveHandle.fromDraft(draft);
      }
    });
    _accept(await widget.channel.saveSkillDraft(draft, confirmed: true));
  }

  Future<void> _checkWrite() async {
    if (_busy || _closing || _queryHandle == null && _draft == null) return;
    final handle = _queryHandle;
    final channel = widget.channel;
    final result = widget.result;
    setState(() => _busy = true);
    final reply = handle == null ? await channel.viewSkillDraft(_draft!) : await channel.checkSkillSave(handle);
    if (!mounted || !identical(channel, widget.channel) || !identical(result, widget.result) ||
        !identical(handle, _queryHandle)) {
      return;
    }
    _accept(reply, fromQuery: handle != null);
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    final draft = _draft;
    if (!_saved && _unverified == null && draft != null) {
      final reply = await widget.channel.discardSkillDraft(draft);
      if (!mounted) return;
      if (reply.code == 'cannot_cancel' || reply.code == 'unavailable') {
        final leave = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: Text(context.l10n.phoneSkillWriting),
          content: Text(context.l10n.phoneSkillCannotCancel),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.phoneSkillKeepWaiting)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.commonClose)),
          ],
        ));
        if (!mounted) return;
        if (leave != true) { setState(() => _closing = false); return; }
      } else if (reply.kind == PhoneSkillReplyKind.saved) {
        _accept(reply);
        setState(() => _closing = false);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    final draft = _draft;
    if (!_saved && _unverified == null && !_allowPop && draft != null) unawaited(widget.channel.discardSkillDraft(draft));
    _goal.dispose();
    _prerequisites.dispose();
    for (final controller in _checks.values) { controller.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final draft = _draft;
    final editable = !_busy && !_pendingWrite && _unverified == null && !_saved && !_closing;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) unawaited(_close()); },
      child: AlertDialog(
        title: Text(_saved ? l10n.commonSaved : l10n.phoneSkillSaveAction),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_skillError(context, _error!))),
              if (_saved) ...[
                Text(l10n.phoneSkillSavedBody),
                SelectableText(_savedPath!),
                if (_savedBundleRevision case final revision?) Text(l10n.phoneSkillBundleRevision(revision)),
              ],
              if (_unverified != null) ...[
                Text(_unverified!.publication == 'published'
                  ? l10n.phoneSkillBundlePublishedUnverified : l10n.phoneSkillBundleUnknown),
                SelectableText(_unverified!.relativePath!),
                if (draft == null) Text(l10n.phoneSkillBundleRevision(_unverified!.bundleRevision!)),
              ],
              if (draft == null && _pendingWrite) Text(l10n.phoneSkillWriting),
              if (!_saved && draft != null) ...[
                if (draft.bundleRevision case final revision?) ...[
                  SelectableText(draft.skillName),
                  Text(l10n.phoneSkillBundleRevision(revision)),
                ],
                Text(l10n.phoneSkillPrivacyHint),
                const SizedBox(height: 12),
                TextField(controller: _goal, enabled: editable, maxLength: 2000, onChanged: (_) => _changed(),
                  decoration: InputDecoration(labelText: l10n.phoneSkillGoal)),
                TextField(controller: _prerequisites, enabled: editable, maxLength: 2000, onChanged: (_) => _changed(),
                  decoration: InputDecoration(labelText: l10n.phoneSkillPrerequisites)),
                for (var position = 0; position < _order.length; position++) ...[
                  Row(children: [
                    Expanded(child: Text(l10n.phoneSkillStep(_order[position] + 1))),
                    IconButton(tooltip: l10n.phoneSkillMoveUp, icon: const Icon(AppIcons.collapse),
                      onPressed: editable && position > 0 ? () => setState(() {
                        final index = _order.removeAt(position); _order.insert(position - 1, index); _dirty = true; _confirmed = false;
                      }) : null),
                    IconButton(tooltip: l10n.phoneSkillMoveDown, icon: const Icon(AppIcons.expand),
                      onPressed: editable && position + 1 < _order.length ? () => setState(() {
                        final index = _order.removeAt(position); _order.insert(position + 1, index); _dirty = true; _confirmed = false;
                      }) : null),
                    IconButton(tooltip: l10n.commonDelete, icon: const Icon(AppIcons.delete),
                      onPressed: editable && _order.length > 1 ? () => setState(() {
                        _order.removeAt(position); _dirty = true; _confirmed = false;
                      }) : null),
                  ]),
                  TextField(controller: _checks[_order[position]], enabled: editable, maxLength: 2000,
                    onChanged: (_) => _changed(), decoration: InputDecoration(labelText: l10n.phoneSkillCheckpoint)),
                ],
                TextButton(onPressed: editable && _dirty ? _applyEdits : null, child: Text(l10n.phoneSkillUpdatePreview)),
                const Divider(),
                Text(l10n.phoneSkillPreviewTitle, style: Theme.of(context).textTheme.titleSmall),
                if (draft.parameterizedFields.isNotEmpty) Text(l10n.phoneSkillParameterizedHint),
                SelectableText(draft.markdown),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: _confirmed,
                  onChanged: editable && !_dirty ? (value) => setState(() => _confirmed = value == true) : null,
                  title: Text(l10n.phoneSkillFinalConfirmation)),
                if (_pendingWrite) Text(draft.bundleRevision != null && _error != null
                  ? l10n.phoneSkillBundleUnknown : l10n.phoneSkillWriting),
              ],
            ],
          )),
        ),
        actions: [
          TextButton(onPressed: _closing ? null : _close, child: Text(l10n.commonClose)),
          if ((draft != null || _queryHandle != null) && (_pendingWrite || _unverified != null)) TextButton(onPressed: _busy ? null : _checkWrite, child: Text(l10n.phoneSkillCheckWrite)),
          if (widget.result == null && !_saved && !_pendingWrite && _unverified == null) FilledButton(
            onPressed: editable && draft != null && !_dirty && _confirmed ? _save : null,
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
  }
}

String _skillError(BuildContext context, String code) => switch (code) {
  'stale' => context.l10n.phoneSkillStale,
  'busy' || 'cannot_cancel' => context.l10n.phoneSkillCannotCancel,
  'confirmation_required' => context.l10n.phoneSkillFinalConfirmation,
  'sensitive' => context.l10n.phoneSkillSensitive,
  'invalid' || 'too_large' => context.l10n.phoneSkillInvalid,
  'no_home' || 'conflict' || 'io' => context.l10n.phoneSkillWriteFailed,
  _ => context.l10n.phoneSkillUnavailable,
};
