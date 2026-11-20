// Native mirror of the official session-header job list
// (`dsh-client-ui-jobs`): a session's background jobs grouped into 进行中 /
// 已结束, each with its streamed output and a confirmed stop.

import 'dart:async';
import 'dart:collection';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/features_state.dart';
import '../chat/render/ansi_text.dart' show stripAnsi;
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/status_dot.dart';
import '../engine/log_view.dart' show TerminalCard;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'feature_format.dart';
import 'feature_kit.dart';
import 'feature_widgets.dart';

StatusTone _tone(JobInfo job) => switch (job.status) {
  'running' || 'stopping' => StatusTone.busy,
  'completed' => StatusTone.ok,
  'failed' => StatusTone.error,
  _ => StatusTone.idle,
};

class JobsPage extends ConsumerWidget {
  const JobsPage({super.key, required this.sessionId, this.now});

  final String sessionId;

  /// Clock override (tests).
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final connected = ref.watch(activeConnectionProvider).value != null;
    final jobs = ref.watch(jobsProvider(sessionId));
    final list = jobs.value;
    final live = [...?list?.where((j) => j.live)];
    final ended = [...?list?.where((j) => !j.live)];
    Widget row(JobInfo job) => _JobRow(
      job: job,
      now: now,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => JobOutputPage(sessionId: sessionId, job: job),
        ),
      ),
    );
    return AppPage.list(
      title: l10n.featuresJobs,
      subtitle: Text(l10n.featuresJobsSubtitle),
      children: [
        if (!connected)
          const FeatureOffline()
        else if (list == null && jobs.hasError)
          FeatureMessage.error(
            title: l10n.featuresJobsReadFailed,
            error: jobs.error!,
            onRetry: () => ref.invalidate(jobsProvider(sessionId)),
          )
        else if (list == null)
          const FeatureLoading()
        else if (list.isEmpty)
          FeatureMessage(icon: AppIcons.terminal, title: l10n.featuresJobsEmpty, body: l10n.featuresJobsEmptyHint)
        else ...[
          if (live.isNotEmpty)
            ListPageCard(
              title: l10n.commonInProgress,
              children: [for (final (i, j) in live.indexed) FadeSlideIn(index: i, child: row(j))],
            ),
          if (live.isNotEmpty && ended.isNotEmpty) const SizedBox(height: 24),
          if (ended.isNotEmpty)
            ListPageCard(
              title: l10n.featuresJobsEndedCount(ended.length),
              children: [for (final (i, j) in ended.indexed) FadeSlideIn(index: live.length + i, child: row(j))],
            ),
        ],
      ],
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.onTap, this.now});

  final JobInfo job;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return ListPageRow(
      leading: StatusDot(tone: _tone(job)),
      title: job.label,
      titleStyle: AppType.monoLabel(color: theme.colorScheme.onSurface).copyWith(fontSize: 13, height: 1.45),
      subtitle: jobSummary(job, now: now),
      subtitleColor: job.status == 'failed' ? colors.danger : null,
      onTap: onTap,
    );
  }
}

/// One job's output, streamed (`job/follow`), with a confirmed stop.
class JobOutputPage extends ConsumerStatefulWidget {
  const JobOutputPage({super.key, required this.sessionId, required this.job});

  final String sessionId;
  final JobInfo job;

  @override
  ConsumerState<JobOutputPage> createState() => _JobOutputPageState();
}

class _JobOutputPageState extends ConsumerState<JobOutputPage> {
  late JobInfo _job = widget.job;
  final _output = JobOutputBuffer();
  bool _stopping = false;
  Object? _error;
  StreamSubscription<JobFrame>? _sub;

  @override
  void initState() {
    super.initState();
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    _sub = client
        .followJob(widget.sessionId, widget.job.id)
        .listen(
          _onFrame,
          onError: (Object e) {
            debugPrint('Job output failed: $e');
            if (mounted) setState(() => _error = e);
          },
        );
  }

  void _onFrame(JobFrame frame) {
    if (!mounted) return;
    setState(() {
      switch (frame) {
        case JobOpened(:final job) || JobStatusChanged(:final job):
          _job = job;
        case JobOutput(:final chunks, :final lossy):
          if (lossy) _output.trimmed = true;
          for (final c in chunks) {
            if (c.gapBefore) _output.trimmed = true;
            _output.add(c.text);
          }
      }
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _stop() async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.featuresJobStopTitle),
        content: Text(_job.label, maxLines: 4, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonStop),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    setState(() => _stopping = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final requested = await client.killJob(widget.sessionId, _job.id);
      if (!requested) {
        messenger?.showSnackBar(SnackBar(content: Text(l10n.featuresJobAlreadyEnded)));
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(featureErrorText(l10n.featuresJobStopFailed, e))));
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lines = _output.lines;
    return AppPage(
      padBottom: false,
      title: l10n.featuresJobOutput,
      subtitle: Text(jobSummary(_job)),
      actions: [
        // The DSH Remote relay doesn't forward `job/kill`.
        if (_job.live &&
            (ref.watch(activeConnectionProvider).value?.client.carrier.allowsEndpoint('job/kill') ?? false))
          GlassIconButton(
            icon: AppIcons.stop,
            tooltip: l10n.commonStop,
            onPressed: _stopping ? null : () => unawaited(_stop()),
          ),
      ],
      slivers: [
        SliverFillRemaining(
          hasScrollBody: true,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.paddingOf(context).bottom + 16),
            child: TerminalCard(
              title: l10n.featuresOutput,
              command: _job.label,
              lines: lines,
              countLabel: _output.trimmed ? l10n.featuresJobRecentLines(JobOutputBuffer.maxLines) : null,
              shareSubject: l10n.featuresJobOutputSubject,
              emptyText: _error != null
                  ? l10n.featuresJobOutputReadFailed
                  : _job.live
                  ? l10n.featuresJobOutputWaiting
                  : l10n.featuresJobOutputEmpty,
            ),
          ),
        ),
      ],
    );
  }
}

/// The last 1000 lines of a job's output, colour codes stripped. The line
/// still being written is kept raw across chunks, so a line or an escape
/// sequence split between two chunks comes out whole.
@visibleForTesting
class JobOutputBuffer {
  static const maxLines = 1000;
  static const _maxLine = 4000;

  final _lines = ListQueue<String>();
  String _partial = '';

  /// Earlier output was dropped (here or by the host).
  bool trimmed = false;

  List<String> get lines => [..._lines, if (_partial.isNotEmpty) _clean(_partial)];

  void add(String chunk) {
    final parts = (_partial + chunk).split('\n');
    _partial = parts.removeLast();
    // A bare CR redraws the line (progress bars); a trailing one may be the
    // first half of a CRLF.
    if (_partial.length > 1) {
      final cr = _partial.lastIndexOf('\r', _partial.length - 2);
      if (cr >= 0) _partial = _partial.substring(cr + 1);
    }
    if (_partial.length > _maxLine) _partial = _partial.substring(0, _maxLine);
    _lines.addAll(parts.map(_clean));
    while (_lines.length > (_partial.isEmpty ? maxLines : maxLines - 1)) {
      _lines.removeFirst();
      trimmed = true;
    }
  }

  static String _clean(String raw) {
    var line = stripAnsi(raw);
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    line = line.substring(line.lastIndexOf('\r') + 1);
    return line.length > _maxLine ? line.substring(0, _maxLine) : line;
  }
}
