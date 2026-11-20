import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_skill_use.dart';
import '../../state/phone_state.dart';

/// Returns a reviewed choice; the caller must keep its source through actual send.
Future<PreparedPhoneSkill?> preparePhoneSkillUse(BuildContext context, {
  required String skillId, required String sessionId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final origin = PhoneSkillUseOrigin.capture(container, sessionId);
  if (origin == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.phoneSkillReplaySourceChanged)));
    return null;
  }
  final prepared = await showDialog<PreparedPhoneSkill>(context: context, builder: (_) => PhoneSkillReplayDialog(
    skillId: skillId, origin: origin, container: container, channel: container.read(phoneChannelProvider)));
  if (prepared == null) return null;
  if (!context.mounted || !origin.current(container)) {
    unawaited(prepared.discard());
    return null;
  }
  return prepared;
}

class PhoneSkillReplayDialog extends StatefulWidget {
  const PhoneSkillReplayDialog({super.key, required this.skillId, required this.origin,
    required this.container, required this.channel});
  final String skillId;
  final PhoneSkillUseOrigin origin;
  final ProviderContainer container;
  final PhoneChannel channel;
  @override
  State<PhoneSkillReplayDialog> createState() => _PhoneSkillReplayDialogState();
}

class _PhoneSkillReplayDialogState extends State<PhoneSkillReplayDialog> {
  PhoneSkillReplayInspection? _inspection;
  PhoneSkillReplayApp? _selected;
  bool _confirmed = false;
  bool _busy = true;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    unawaited(_inspect());
  }

  bool get _current => widget.origin.current(widget.container);

  Future<void> _inspect() async {
    if (!_current) {
      setState(() { _busy = false; _stale = true; });
      return;
    }
    final inspection = await widget.channel.inspectSkillReplay(widget.skillId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stale = !_current;
      if (!_stale) _inspection = inspection;
    });
  }

  Future<void> _prepare() async {
    final inspection = _inspection;
    final app = _selected;
    if (_busy || !_confirmed || inspection?.available != true || app == null || _stale) return;
    if (!_current) {
      setState(() { _stale = true; _confirmed = false; });
      return;
    }
    setState(() => _busy = true);
    final ready = await widget.channel.prepareSkillReplay(skillId: widget.skillId, revision: inspection!.revision!,
      sessionId: widget.origin.sessionId, app: app);
    if (!mounted || !_current || ready != null && ready.revision != inspection.revision) {
      if (ready != null) unawaited(widget.channel.discardSkillReplay(ready.invocation));
      if (mounted) setState(() { _busy = false; _stale = true; _confirmed = false; });
      return;
    }
    if (ready == null) {
      setState(() { _busy = false; _confirmed = false; _inspection = const PhoneSkillReplayInspection.unavailable(); });
      return;
    }
    Navigator.of(context).pop(PreparedPhoneSkill(origin: widget.origin, ready: ready, channel: widget.channel,
      text: context.l10n.phoneSkillReplayStartText(jsonEncode({'operation': 'start', 'invocation': ready.invocation}))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inspection = _inspection;
    return AlertDialog(
      title: Text(l10n.phoneSkillReplayReview),
      content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_busy) const LinearProgressIndicator(),
          if (_stale) Text(l10n.phoneSkillReplaySourceChanged)
          else if (inspection != null && !inspection.available) Text(l10n.phoneSkillReplayUnavailable),
          if (!_stale && inspection?.available == true) ...[
            Text(inspection!.summary!),
            Text(l10n.phoneSkillBundleRevision(inspection.revision!)),
            for (final app in inspection.apps) ListTile(
              title: Text(app.label), subtitle: Text(app.packageName),
              selected: identical(_selected, app),
              onTap: _busy ? null : () => setState(() { _selected = app; _confirmed = false; }),
            ),
            CheckboxListTile(contentPadding: EdgeInsets.zero, value: _confirmed,
              onChanged: _busy || _selected == null ? null : (value) => setState(() => _confirmed = value == true),
              title: Text(l10n.phoneSkillReplayConfirm)),
          ],
        ]))),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonClose)),
        if (!_stale && inspection?.available == true) FilledButton(
          onPressed: _busy || !_confirmed || _selected == null ? null : _prepare,
          child: Text(l10n.phoneSkillReplayToComposer)),
      ],
    );
  }
}
