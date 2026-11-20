import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../common/fade_in.dart';
import '../fx/metal/metal_text.dart';
import '../shell/brand_mark.dart';
import '../theme/theme.dart';
import 'onboarding_scaffold.dart';
import 'usage_notice_row.dart';

/// First screen on a fresh install: mostly empty space, the brand mark easing
/// in, one sentence and one button. Over the button, the one thing everyone
/// is told on first run: anonymous usage statistics, with their switch. The
/// slogan sits quietly at the bottom.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return OnboardingScaffold(
      children: [
        const Spacer(flex: 5),
        const Center(child: _BrandArrival()),
        const SizedBox(height: 36),
        FadeSlideIn(
          delay: const Duration(milliseconds: 180),
          // Letter spacing also trails the last letter: pad the leading side
          // by the same amount so the word sits on the centre line.
          child: Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Text(
              AppInfo.wordmark,
              textAlign: TextAlign.center,
              style: AppType.wordmark(size: 15, color: colors.textTertiary).copyWith(letterSpacing: 3),
            ),
          ),
        ),
        const SizedBox(height: 10),
        FadeSlideIn(
          delay: const Duration(milliseconds: 220),
          // The one metal word on this page (Libraries.dev Metal).
          child: MetalText(
            l10n.shellWelcomeMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(height: 1.35),
          ),
        ),
        const Spacer(flex: 6),
        const FadeSlideIn(delay: Duration(milliseconds: 280), child: UsageNoticeRow()),
        const SizedBox(height: 20),
        FadeSlideIn(
          delay: const Duration(milliseconds: 320),
          child: FilledButton(onPressed: onStart, child: Text(l10n.shellGetStarted)),
        ),
        const SizedBox(height: 16),
        Text(
          AppInfo.slogan,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
        ),
      ],
    );
  }
}

/// The brand mark (the colour glyph) over a soft glow, easing in (fade + a slight
/// grow) the first time the page shows. Still under reduced motion.
class _BrandArrival extends StatefulWidget {
  const _BrandArrival();

  @override
  State<_BrandArrival> createState() => _BrandArrivalState();
}

class _BrandArrivalState extends State<_BrandArrival> with SingleTickerProviderStateMixin {
  late final AnimationController _arrive = AnimationController(vsync: this, duration: AppMotion.slow);
  late final Animation<double> _curve = CurvedAnimation(parent: _arrive, curve: AppMotion.enter);

  static const _mark = 60.0;
  static const _glow = 220.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _arrive.value = 1;
    } else if (_arrive.isDismissed) {
      _arrive.forward();
    }
  }

  @override
  void dispose() {
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return SizedBox(
      // Layout keeps the mark's size; the glow spills around it unclipped.
      width: _mark * BrandMark.aspect,
      height: _mark,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) => Opacity(
          opacity: _curve.value,
          child: Transform.scale(scale: 0.92 + 0.08 * _curve.value, child: child),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              // The glow centres on the glyph's visual centre, not its box.
              child: Transform.translate(
                offset: -BrandMark.opticalShift(_mark),
                child: OverflowBox(
                  maxWidth: _glow,
                  maxHeight: _glow,
                  child: IgnorePointer(
                    child: SizedBox.square(
                      dimension: _glow,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              scheme.primary.withValues(alpha: dark ? 0.22 : 0.16),
                              scheme.primary.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const BrandMark(size: _mark),
          ],
        ),
      ),
    );
  }
}
