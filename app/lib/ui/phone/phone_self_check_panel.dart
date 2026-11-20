import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../phone/phone_self_check.dart';
import '../common/list_page_row.dart';
import '../shell/page_frame.dart';
import 'phone_widgets.dart';

class PhoneSelfCheckPage extends StatelessWidget {
  const PhoneSelfCheckPage({super.key});

  @override
  Widget build(BuildContext context) =>
      AppPage.list(title: context.l10n.phoneSelfCheckTitle, children: const [PhoneSelfCheckPanel()]);
}

/// Local partial check, independent of the model/engine and ordinary task actions.
class PhoneSelfCheckPanel extends StatefulWidget {
  const PhoneSelfCheckPanel({super.key, this.channel = const PhoneSelfCheckChannel(), this.report});
  final PhoneSelfCheckChannel channel;
  final PhoneSelfCheckReport? report;

  @override
  State<PhoneSelfCheckPanel> createState() => _PhoneSelfCheckPanelState();
}

class _PhoneSelfCheckPanelState extends State<PhoneSelfCheckPanel> {
  late final PhoneSelfCheckController _controller;
  late final PhoneSelfCheckReport _report;
  late final AppLifecycleListener _lifecycle;
  bool _saving = false;
  String _nextProfile = 'probe_b';

  @override
  void initState() {
    super.initState();
    _controller = PhoneSelfCheckController(channel: widget.channel)..addListener(_changed);
    _report = widget.report ?? PhoneSelfCheckReport();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _controller.setVisible(state == AppLifecycleState.resumed);
      },
    );
    unawaited(_controller.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final snapshot = _controller.snapshot;
    setState(() => _saving = true);
    var saved = false;
    try {
      await _report.save(snapshot);
      saved = true;
    } catch (_) {
      /* No exception details are displayed. */
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(saved ? context.l10n.phoneSelfCheckSaved : context.l10n.phoneSelfCheckSaveFailed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final snapshot = _controller.snapshot;
    final failedStep = snapshot.steps
        .where((step) => step.reason != null && (step.state == 'fail' || step.state == 'unknown'))
        .firstOrNull;
    final reason = _controller.readFailed
        ? 'unavailable'
        : phoneSelfCheckReasonGroup(snapshot.reason ?? failedStep?.reason);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.phoneSelfCheckRunState(snapshot.state), key: const ValueKey('self-check-state')),
                  if (reason != 'none') ...[const SizedBox(height: 4), Text(l10n.phoneSelfCheckReason(reason))],
                  const SizedBox(height: 12),
                  if (snapshot.active)
                    OutlinedButton(
                      key: const ValueKey('self-check-cancel'),
                      onPressed: _controller.canCancel ? () => unawaited(_controller.cancel()) : null,
                      child: Text(l10n.phoneSelfCheckCancel),
                    )
                  else
                    FilledButton(
                      key: const ValueKey('self-check-start'),
                      onPressed: _controller.canStart
                          ? () => unawaited(_controller.start(profile: _nextProfile))
                          : null,
                      child: Text(l10n.phoneSelfCheckStart),
                    ),
                ],
              ),
            ),
          ],
        ),
        PhoneOptionsFold(
          key: const ValueKey('self-check-details'),
          title: l10n.phoneSelfCheckTechnicalDetails,
          children: [
            ListPageCard(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.phoneSelfCheckReportProfile(snapshot.profile ?? 'unknown'),
                        key: const ValueKey('self-check-report-profile'),
                      ),
                      Text(l10n.phoneSelfCheckPartial),
                      const SizedBox(height: 4),
                      Text(
                        snapshot.profile == 'target_c2'
                            ? l10n.phoneSelfCheckTargetC2Scope
                            : snapshot.profile == 'target_c1'
                            ? l10n.phoneSelfCheckTargetScope
                            : l10n.phoneSelfCheckScope,
                      ),
                      const SizedBox(height: 12),
                      Text(l10n.phoneSelfCheckProfileChoice),
                      DropdownButton<String>(
                        key: const ValueKey('self-check-profile'),
                        value: _nextProfile,
                        isExpanded: true,
                        items: [
                          for (final profile in phoneSelfCheckProfiles)
                            DropdownMenuItem(value: profile, child: Text(l10n.phoneSelfCheckProfile(profile))),
                        ],
                        onChanged: _controller.canStart
                            ? (value) {
                                if (value != null && phoneSelfCheckProfiles.contains(value)) {
                                  setState(() => _nextProfile = value);
                                }
                              }
                            : null,
                      ),
                      TextButton(
                        key: const ValueKey('self-check-refresh'),
                        onPressed: _controller.commandPending ? null : () => unawaited(_controller.refresh()),
                        child: Text(l10n.phoneSelfCheckRefresh),
                      ),
                      for (final step in snapshot.steps)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l10n.phoneSelfCheckStage(step.stage)),
                                    if (step.reason != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        l10n.phoneSelfCheckReason(phoneSelfCheckReasonGroup(step.reason)),
                                        key: ValueKey('self-check-reason-${step.stage}'),
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  l10n.phoneSelfCheckStepState(step.state),
                                  key: ValueKey('self-check-step-${step.stage}'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(l10n.phoneSelfCheckReportHint),
                      TextButton(
                        key: const ValueKey('self-check-save'),
                        onPressed: _saving || _controller.commandPending ? null : _save,
                        child: Text(_saving ? l10n.phoneSelfCheckSaving : l10n.phoneSelfCheckSave),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
