// First run on this phone sets up while the runtime unpacks
// (docs/design/onboarding-parallel-setup.md). Shared here: the one way an
// unpack starts, where it stands in first-run terms, the time-left estimate,
// and the quiet capsule + status sheet that keep it in view on the pages that
// run beside it.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/onboarding_state.dart';
import '../common/app_sheet.dart';
import '../common/progress_halo.dart';
import '../engine/engine_status.dart' show humanizeRuntimeError;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'runtime_setup_page.dart' show showRuntimeLogSheet;

// ── State ────────────────────────────────────────────────────────────────────

/// The one way the app starts unpacking the runtime. A request while another
/// is on its way, or while Android is already unpacking, is that same request:
/// paging through first run, or coming back to it, never starts a second one
/// (the native `install_busy` check stays as the second line).
///
/// The state is whether the last request failed before Android reported
/// anything (a bridge that never got going); every other failure Android
/// reports itself, as `phase: error`.
class RuntimeInstallController extends Notifier<bool> {
  Future<void>? _pending;

  @override
  bool build() => false;

  /// [dropKept]: give up what a reset kept but cannot put back.
  Future<void> install({bool dropKept = false}) {
    if (_pending case final pending?) return pending;
    if (ref.read(localRuntimeProvider).status.phase == RuntimePhase.installing) return Future.value();
    final run = _pending = _run(dropKept);
    return run.whenComplete(() {
      if (identical(_pending, run)) _pending = null;
    });
  }

  Future<void> _run(bool dropKept) async {
    state = false;
    // Installing means wanting it here: launches without it no longer skip setup.
    unawaited(ref.read(onboardingPrefsProvider.notifier).setLocalDeclined(false));
    try {
      final runtime = ref.read(localRuntimeProvider.notifier);
      await (dropKept ? runtime.installDroppingKept() : runtime.install());
    } catch (_) {
      if (ref.mounted && ref.read(localRuntimeProvider).status.phase == RuntimePhase.notInstalled) state = true;
    }
  }
}

final runtimeInstallProvider = NotifierProvider<RuntimeInstallController, bool>(RuntimeInstallController.new);

/// Where the runtime stands for first run.
enum SetupRuntime {
  /// Not there and not being unpacked (yet).
  absent,
  unpacking,

  /// Installed and current (the engine may be anywhere from stopped to running).
  ready,

  /// The unpack stopped: Android's error, or a request that never got going.
  failed,
}

SetupRuntime setupRuntimeOf(RuntimeStatus status, {bool launchFailed = false}) => switch (status.phase) {
  RuntimePhase.installing => SetupRuntime.unpacking,
  RuntimePhase.installed ||
  RuntimePhase.starting ||
  RuntimePhase.running ||
  RuntimePhase.stopping => SetupRuntime.ready,
  // An engine error with a current runtime is the engine's business, not setup's.
  RuntimePhase.error =>
    status.installedVersion != null && status.installedVersion == status.bundledVersion
        ? SetupRuntime.ready
        : SetupRuntime.failed,
  RuntimePhase.notInstalled => launchFailed ? SetupRuntime.failed : SetupRuntime.absent,
};

final setupRuntimeProvider = Provider<SetupRuntime>(
  (ref) => setupRuntimeOf(
    ref.watch(localRuntimeProvider.select((s) => s.status)),
    launchFailed: ref.watch(runtimeInstallProvider),
  ),
);

/// Rough time left for the unpack, from how fast it has gone since the first
/// progress report this provider saw; null until there is enough to go on.
/// One estimate for every place that shows the unpack, so they agree.
class InstallEtaController extends Notifier<Duration?> {
  DateTime? _t0;
  double _f0 = 0;

  @override
  Duration? build() {
    ref.listen(localRuntimeProvider.select((s) => s.progress), (_, next) => _track(next));
    // A new unpack (a retry) starts its own samples.
    ref.listen(localRuntimeProvider.select((s) => s.status.phase == RuntimePhase.installing), (was, now) {
      if (now && was == false) _reset();
    });
    return null;
  }

  void _reset() {
    _t0 = null;
    _f0 = 0;
    state = null;
  }

  void _track(RuntimeProgressEvent? progress) {
    if (progress == null) return;
    final now = DateTime.now();
    final f = progress.fraction;
    if (_t0 == null) {
      _t0 = now;
      _f0 = f;
      return;
    }
    final elapsed = now.difference(_t0!);
    final gained = f - _f0;
    if (gained < 0.04 || elapsed < const Duration(seconds: 3)) return;
    final perUnit = elapsed.inMilliseconds / gained;
    final next = Duration(milliseconds: (perUnit * (1 - f)).round());
    // Smooth the estimate so it doesn't jitter with each chunk.
    final eta = state;
    state = eta == null
        ? next
        : Duration(milliseconds: (eta.inMilliseconds * 0.6 + next.inMilliseconds * 0.4).round());
  }
}

final installEtaProvider = NotifierProvider<InstallEtaController, Duration?>(InstallEtaController.new);

/// 「48 / 120 MB · 约 30 秒」: what is under the unpack's progress.
String? installMetaLine(L10n l10n, RuntimeProgressEvent? progress, Duration? eta) {
  if (progress == null) return null;
  String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
  final size = progress.total > 0 ? '${mb(progress.done)} / ${mb(progress.total)} MB' : null;
  final String? remaining;
  if (eta == null) {
    remaining = null;
  } else if (eta.inSeconds < 5) {
    remaining = l10n.shellRuntimeAlmostDone;
  } else if (eta.inSeconds < 60) {
    remaining = l10n.shellRuntimeSecondsRemaining((eta.inSeconds / 5).ceil() * 5);
  } else {
    remaining = l10n.shellRuntimeMinutesRemaining((eta.inSeconds / 60).ceil());
  }
  final line = [?size, ?remaining].join(' · ');
  return line.isEmpty ? null : line;
}

// ── Pieces ───────────────────────────────────────────────────────────────────

/// The percentage inside a progress halo: display figures with a smaller `%`.
class SetupPercent extends StatelessWidget {
  const SetupPercent({super.key, required this.value, this.size = 40});

  final double value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Already display-sized, inside a fixed ring: grows with the font only so far.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${(value * 100).floor()}',
            style: AppType.tabular(AppType.display(size: size, color: theme.colorScheme.onSurface)),
          ),
          const SizedBox(width: 2),
          Text('%', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// A small progress ring: a quiet track, the accent arc as far round as
/// [value]; null turns a short arc slowly (still under reduced motion).
class SetupRing extends StatefulWidget {
  const SetupRing({super.key, this.value, this.size = 16, this.stroke = 2});

  final double? value;
  final double size;
  final double stroke;

  @override
  State<SetupRing> createState() => _SetupRingState();
}

class _SetupRingState extends State<SetupRing> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SetupRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.value == null && !AppMotion.reduced(context)) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.12);
    final value = widget.value;
    return SizedBox.square(
      dimension: widget.size,
      child: value != null
          ? TweenAnimationBuilder<double>(
              tween: Tween(end: value.clamp(0, 1)),
              duration: AppMotion.of(context, AppMotion.slow),
              curve: AppMotion.std,
              builder: (context, v, _) => CustomPaint(
                painter: _RingPainter(track: track, arc: scheme.primary, stroke: widget.stroke, sweep: v),
              ),
            )
          : AnimatedBuilder(
              animation: _spin,
              builder: (context, _) => CustomPaint(
                painter: _RingPainter(
                  track: track,
                  arc: scheme.primary,
                  stroke: widget.stroke,
                  sweep: 0.25,
                  start: _spin.value,
                ),
              ),
            ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.track, required this.arc, required this.stroke, required this.sweep, this.start = 0});

  final Color track;
  final Color arc;
  final double stroke;

  /// Arc length and start, in turns (0–1), clockwise from the top.
  final double sweep;
  final double start;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawOval(rect, paint..color = track);
    if (sweep <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2 + start * 2 * math.pi,
      sweep * 2 * math.pi,
      false,
      paint
        ..color = arc
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.track != track || old.arc != arc || old.stroke != stroke || old.sweep != sweep || old.start != start;
}

// ── Capsule ──────────────────────────────────────────────────────────────────

/// Keeps the unpack in view on the first-run pages that run beside it, never
/// in the way: a glass capsule centred at the bottom.
///
/// ```
///   ( ◌ 准备运行环境 )     asked for, no progress yet
///   ( ◔ 运行环境 42% )     unpacking: the ring as far round as the unpack
///   ( ✓ 运行环境已就绪 )    done: stays [readyHold], then fades
///   ( ! 安装未完成 )        failed: stays, in the danger colour
/// ```
///
/// [inset] on every side of one line; the mark, round in every state, is as
/// tall as that line (up to 1.5× its 1× size), so at the usual text size it
/// sits concentric with the rounded end. A capsule that was already done when it came up stays
/// hidden. Hidden or not, it keeps its size, so nothing around it moves.
/// Tap: [showSetupStatusSheet].
class SetupProgressCapsule extends ConsumerStatefulWidget {
  const SetupProgressCapsule({super.key, this.onRemote});

  /// 「改用远程主机」 in the status sheet when the unpack failed.
  final VoidCallback? onRemote;

  static const inset = 10.0;
  static const gap = 8.0;
  static const readyHold = Duration(milliseconds: 2400);

  @override
  ConsumerState<SetupProgressCapsule> createState() => _SetupProgressCapsuleState();
}

class _SetupProgressCapsuleState extends ConsumerState<SetupProgressCapsule> {
  /// Showing the done state: set when the unpack finishes in view.
  bool _celebrating = false;
  Timer? _hold;

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  void _onRuntime(SetupRuntime? prev, SetupRuntime next) {
    if (next == SetupRuntime.ready && prev != null && prev != SetupRuntime.ready) {
      setState(() => _celebrating = true);
      _hold?.cancel();
      _hold = Timer(SetupProgressCapsule.readyHold, () {
        if (mounted) setState(() => _celebrating = false);
      });
    } else if (next != SetupRuntime.ready && _celebrating) {
      _hold?.cancel();
      setState(() => _celebrating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(setupRuntimeProvider, _onRuntime);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final runtime = ref.watch(setupRuntimeProvider);
    final progress = ref.watch(localRuntimeProvider.select((s) => s.progress));
    final visible = runtime != SetupRuntime.ready || _celebrating;

    final style = AppType.tabular(theme.textTheme.labelMedium!);
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
    final markSize = math.min(line, 1.5 * style.fontSize! * style.height!);
    final percent = progress == null ? null : (progress.fraction * 100).floor().clamp(0, 100);

    final (Widget mark, String label, String semantics, Color color) = switch (runtime) {
      SetupRuntime.ready => (
        Icon(AppIcons.completed, size: markSize, color: scheme.primary),
        l10n.setupCapsuleReady,
        l10n.setupCapsuleReady,
        scheme.primary,
      ),
      SetupRuntime.failed => (
        Icon(AppIcons.error, size: markSize, color: colors.danger),
        l10n.setupCapsuleFailed,
        l10n.setupCapsuleFailed,
        colors.danger,
      ),
      _ when runtime == SetupRuntime.unpacking && percent != null => (
        SetupRing(value: progress!.fraction, size: markSize),
        l10n.setupCapsuleProgress(percent),
        l10n.setupCapsuleProgressSemantics(percent),
        scheme.onSurfaceVariant,
      ),
      _ => (
        SetupRing(size: markSize),
        l10n.setupCapsulePreparing,
        l10n.setupCapsulePreparing,
        scheme.onSurfaceVariant,
      ),
    };

    final pill = GlassSurface(
      key: const ValueKey('setup-capsule'),
      tier: GlassTier.pill,
      stadium: true,
      onTap: visible ? () => unawaited(showSetupStatusSheet(context, onRemote: widget.onRemote)) : null,
      padding: const EdgeInsets.all(SetupProgressCapsule.inset),
      child: Row(
        key: const ValueKey('setup-capsule-content'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(key: const ValueKey('setup-capsule-mark'), dimension: markSize, child: Center(child: mark)),
          const SizedBox(width: SetupProgressCapsule.gap),
          Flexible(
            child: AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
              child: Text(label, key: ValueKey(runtime), maxLines: 1, style: style.copyWith(color: color)),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: visible,
      label: visible ? semantics : null,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        child: IgnorePointer(ignoring: !visible, child: pill),
      ),
    );
  }
}

// ── Status sheet ─────────────────────────────────────────────────────────────

/// Where the unpack stands, from the capsule: progress and time left, or what
/// went wrong with 重试 / 改用远程主机; the log one tap away. A glance, not a
/// task: it sizes to its content and closes by its handle (drag or tap).
Future<void> showSetupStatusSheet(BuildContext context, {VoidCallback? onRemote}) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.drag,
  builder: (_) => _SetupStatusSheet(onRemote: onRemote),
);

class _SetupStatusSheet extends ConsumerWidget {
  const _SetupStatusSheet({this.onRemote});

  final VoidCallback? onRemote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final runtime = ref.watch(setupRuntimeProvider);
    final state = ref.watch(localRuntimeProvider);
    final eta = ref.watch(installEtaProvider);
    final failed = runtime == SetupRuntime.failed;
    final ready = runtime == SetupRuntime.ready;
    final progress = runtime == SetupRuntime.unpacking ? state.progress : null;
    final double? fraction = ready
        ? 1
        : failed
        ? 0
        : progress?.fraction;
    final title = failed
        ? l10n.shellRuntimeIncomplete
        : ready
        ? l10n.shellRuntimeReady
        : l10n.shellRuntimePreparing;
    final body = failed
        ? humanizeRuntimeError(state.status.error) ?? l10n.shellRuntimeExtractFailed
        : ready
        ? l10n.shellRuntimeLocalOnly
        : l10n.shellRuntimeFirstSetup;
    final meta = installMetaLine(l10n, progress, eta);
    final navigator = Navigator.of(context);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 16),
        child: Column(
          key: const ValueKey('setup-status-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ProgressHalo(
                value: fraction,
                size: 112,
                strokeWidth: 4,
                color: failed ? colors.danger : null,
                child: AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.emphasized),
                  child: switch (runtime) {
                    SetupRuntime.ready => Icon(AppIcons.done, key: const ValueKey('done'), size: 36, color: scheme.primary),
                    SetupRuntime.failed => Icon(
                      AppIcons.attention,
                      key: const ValueKey('failed'),
                      size: 34,
                      color: colors.danger,
                    ),
                    _ when fraction != null => SetupPercent(key: const ValueKey('pct'), value: fraction, size: 30),
                    _ => const SizedBox.shrink(key: ValueKey('waiting')),
                  },
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (meta != null) ...[
              const SizedBox(height: 6),
              Text(
                meta,
                textAlign: TextAlign.center,
                style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
              ),
            ],
            const SizedBox(height: 24),
            if (failed) ...[
              _FailedActions(
                onRetry: () => unawaited(ref.read(runtimeInstallProvider.notifier).install()),
                onRemote: switch (onRemote) {
                  final remote? => () {
                    navigator.pop();
                    remote();
                  },
                  null => null,
                },
              ),
              const SizedBox(height: 8),
            ],
            Center(
              child: TextButton(
                // One sheet at a time: this one goes, the log comes up from
                // the page underneath.
                onPressed: () {
                  navigator.pop();
                  unawaited(showRuntimeLogSheet(navigator.context, title: l10n.shellInstallLogs));
                },
                style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                child: Text(l10n.commonViewLogs),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What to do about a stopped unpack: 「改用远程主机」 and 「重试」 as twins
/// side by side when both names fit on one line, as the platform's own
/// dialogs do; else stacked full width, 重试 on top. Without a remote way,
/// just 重试.
class _FailedActions extends StatelessWidget {
  const _FailedActions({required this.onRetry, this.onRemote});

  static const gap = 12.0;

  /// Between stacked buttons, as on the first-run pages.
  static const stackGap = 10.0;

  final VoidCallback onRetry;
  final VoidCallback? onRemote;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final retry = FilledButton(
      key: const ValueKey('setup-retry'),
      onPressed: onRetry,
      child: Text(l10n.commonRetry, textAlign: TextAlign.center),
    );
    final onRemote = this.onRemote;
    if (onRemote == null) return retry;
    final remote = OutlinedButton(
      key: const ValueKey('setup-use-remote'),
      onPressed: onRemote,
      child: Text(l10n.localEnvUseRemote, textAlign: TextAlign.center),
    );
    final theme = Theme.of(context);
    final filledStyle = theme.filledButtonTheme.style;
    final outlinedStyle = theme.outlinedButtonTheme.style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - gap) / 2;
        // Label width plus the button's own side padding (app_theme).
        bool fits(String label, ButtonStyle? style) {
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: style?.textStyle?.resolve(const {}) ?? theme.textTheme.labelLarge,
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          final padding = style?.padding?.resolve(const {})?.horizontal ?? 48;
          return width + padding <= half;
        }

        if (fits(l10n.localEnvUseRemote, outlinedStyle) && fits(l10n.commonRetry, filledStyle)) {
          return Row(
            children: [
              Expanded(child: remote),
              const SizedBox(width: gap),
              Expanded(child: retry),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [retry, const SizedBox(height: stackGap), remote],
        );
      },
    );
  }
}
