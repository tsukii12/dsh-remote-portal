import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../theme/theme.dart';
import 'setup_progress.dart';

/// Where a first-run page sits in the flow; [OnboardingScaffold] draws it as a
/// thin step bar in the top row. Provided by `OnboardingFlow`; absent when a
/// page is opened on its own (API key from settings).
class OnboardingProgress extends InheritedWidget {
  const OnboardingProgress({
    super.key,
    required this.step,
    required this.steps,
    this.since,
    this.runtime = false,
    this.onRemote,
    required super.child,
  });

  /// 1-based step shown as current.
  final int step;
  final int steps;

  /// When this step began. The current segment fills in only on a page built
  /// right then, not again when a step swaps its own inner pages.
  final DateTime? since;

  /// The runtime unpacks beside this step (first run on this phone): the
  /// scaffold keeps it in view with a [SetupProgressCapsule].
  final bool runtime;

  /// The way to a remote host when the unpack fails.
  final VoidCallback? onRemote;

  static OnboardingProgress? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OnboardingProgress>();

  @override
  bool updateShouldNotify(OnboardingProgress oldWidget) =>
      step != oldWidget.step ||
      steps != oldWidget.steps ||
      runtime != oldWidget.runtime ||
      onRemote != oldWidget.onRemote;
}

/// Shared frame for the first-run pages: backdrop, safe area, a 440dp reading column
/// centred on tablets, and a column that fills the screen but scrolls when the
/// keyboard (or a large font scale) needs more room.
///
/// A fixed 56dp top row holds an optional back button 12 in from the left and,
/// inside the flow, the step bar centred on the screen. While the runtime
/// unpacks beside the step ([OnboardingProgress.runtime]) a fixed bottom row
/// holds its capsule, centred; the row keeps its height whether the capsule
/// shows or not, and steps aside for the keyboard.
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({super.key, required this.children, this.leading, this.showRuntime = true});

  /// Laid out in a full-height column; use [Spacer]s to distribute space.
  final List<Widget> children;

  /// Optional widget pinned at the top-left (the back button).
  final Widget? leading;

  /// False on a page that shows the unpack itself (a big halo): no capsule.
  final bool showRuntime;

  /// Space under the capsule, above the bottom safe area.
  static const capsuleBottom = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = OnboardingProgress.maybeOf(context);
    final capsule = showRuntime && (progress?.runtime ?? false) && MediaQuery.viewInsetsOf(context).bottom == 0;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            // Width is capped *outside* IntrinsicHeight: intrinsic heights are
            // measured at the incoming width, and measuring wrapped text at the
            // full tablet width would under-estimate the column and overflow.
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  children: [
                    // Fixed above the scrolling content, like a page's top bar:
                    // the back key 12 in, the step bar centred on the screen.
                    SizedBox(
                      height: 56,
                      width: double.infinity,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (progress != null)
                            OnboardingStepBar(
                              step: progress.step,
                              steps: progress.steps,
                              animate:
                                  progress.since != null &&
                                  DateTime.now().difference(progress.since!) < const Duration(milliseconds: 400),
                            ),
                          if (leading case final leading?) Positioned(left: 12, child: leading),
                        ],
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: constraints.maxHeight),
                            child: IntrinsicHeight(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (capsule)
                      Padding(
                        key: const ValueKey('setup-capsule-slot'),
                        padding: const EdgeInsets.only(bottom: capsuleBottom),
                        child: Center(child: SetupProgressCapsule(onRemote: progress!.onRemote)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin segmented bar: one segment per step, done ones filled, the current one
/// filling in as the page arrives, the rest a quiet track.
class OnboardingStepBar extends StatelessWidget {
  const OnboardingStepBar({super.key, required this.step, required this.steps, this.animate = true});

  final int step;
  final int steps;

  /// Fill the current segment in (true) or show it already full.
  final bool animate;

  static const width = 120.0;
  static const height = 3.0;
  static const gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final track = scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.14 : 0.10);
    Widget segment(double fill) => ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: track),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: fill,
              child: ColoredBox(color: scheme.primary),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: l10n.shellOnboardingStep(step, steps),
      child: SizedBox(
        width: width,
        child: Row(
          children: [
            for (var i = 1; i <= steps; i++) ...[
              if (i > 1) const SizedBox(width: gap),
              Expanded(
                child: i < step
                    ? segment(1)
                    : i > step
                    ? segment(0)
                    : TweenAnimationBuilder<double>(
                        tween: Tween(begin: animate ? 0 : 1, end: 1),
                        duration: AppMotion.of(context, AppMotion.slow),
                        curve: AppMotion.enter,
                        builder: (context, t, _) => segment(t),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cross-fade between first-run pages with a short horizontal drift: forward,
/// the new page comes from the right and the old one leaves left; back, the
/// other way. Each child needs its own key.
class OnboardingSwitcher extends StatelessWidget {
  const OnboardingSwitcher({super.key, required this.child, this.forward = true});

  final Widget child;
  final bool forward;

  static const _drift = 24.0;

  @override
  Widget build(BuildContext context) {
    final current = child.key;
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.page),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) {
        // The outgoing page's animation runs 1 → 0, so "from" is where it goes.
        final incoming = child.key == current;
        final from = (incoming == forward ? 1 : -1) * _drift;
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) => Transform.translate(
            offset: Offset(from * (1 - animation.value), 0),
            child: Opacity(opacity: animation.value, alwaysIncludeSemantics: incoming, child: child),
          ),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// Top of a first-run form step: a soft icon tile, the title, one short line.
class OnboardingHeader extends StatelessWidget {
  const OnboardingHeader({super.key, required this.icon, required this.title, this.message});

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(color: scheme.primaryContainer, shape: Squircle.border(AppShape.md)),
          child: SizedBox.square(dimension: 52, child: Icon(icon, size: 26, color: scheme.onPrimaryContainer)),
        ),
        const SizedBox(height: 22),
        Text(title, style: theme.textTheme.headlineMedium),
        if (message case final message?) ...[
          const SizedBox(height: 6),
          Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// One plain fact on a first-run step: a 20dp line icon and a short line.
class OnboardingFact extends StatelessWidget {
  const OnboardingFact({super.key, required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;

  /// Icon and text in one colour (a warning); null: the usual pair.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
