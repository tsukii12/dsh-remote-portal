// Pieces shared by the 模型渠道 pages: how a provider's state reads, its
// glyph, and the form's field anatomy.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/providers_state.dart';
import '../common/smooth_size.dart';
import '../common/status_chip.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Dot colour + one word for a provider's state.
class ProviderHealthView {
  const ProviderHealthView(this.tone, this.label);

  factory ProviderHealthView.of(ProviderHealth health) => switch (health) {
    ProviderHealth.ready => ProviderHealthView(StatusTone.ok, appL10n.engineProviderReady),
    ProviderHealth.missingKey => ProviderHealthView(StatusTone.warn, appL10n.engineProviderMissingKey),
    ProviderHealth.misconfigured => ProviderHealthView(StatusTone.error, appL10n.engineProviderMisconfigured),
    ProviderHealth.inactive => ProviderHealthView(StatusTone.idle, appL10n.engineProviderInactive),
  };

  final StatusTone tone;
  final String label;
}

/// The list row's second line: what it is when it works, what is wrong when
/// it does not.
String providerSummary(CustomProvider provider, ProviderHealth health) {
  if (health != ProviderHealth.ready) return ProviderHealthView.of(health).label;
  final count = provider.models.length;
  return [
    if (provider.api case final api?) protocolLabel(api) else appL10n.engineProviderConfiguredInWeb,
    if (count > 0) appL10n.engineProviderModels(count),
  ].join(' · ');
}

/// A model row's second line: its id when it has a name, then what it can do
/// (「上下文 256K · 识图 · 思考」). Empty when there is nothing to say.
String modelSummary(BuildContext context, ProviderModelSpec model, {ModelDefaults defaults = const ModelDefaults()}) {
  final l10n = context.l10n;
  return [
    if (model.label != model.id) model.id,
    if (model.contextWindow case final c?) l10n.engineProviderContext(formatTokens(c)),
    if (model.acceptsImages(routeDefault: defaults.input)) l10n.engineModelVision,
    if (model.thinks) l10n.engineModelThinking,
  ].join(' · ');
}

/// Round monogram tile: the first letter of a name on a neutral disc. The
/// one leading graphic of every channel row (32) and detail page (56): no
/// brand colours, no logos.
class Monogram extends StatelessWidget {
  const Monogram(this.name, {super.key, this.size = 32, this.letter});

  final String name;
  final double size;

  /// Overrides the first letter (「G」 for ChatGPT).
  final String? letter;

  static String letterOf(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: dark ? Colors.white.withValues(alpha: 0.1) : theme.colorScheme.onSurface.withValues(alpha: 0.07),
          shape: const CircleBorder(),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: Text(
              letter ?? letterOf(name),
              textScaler: TextScaler.noScaling,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: size * 0.44,
                height: 1,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Status dot at the end of a list row, sized like the rows' other glyphs'
/// visual weight.
class ProviderDot extends StatelessWidget {
  const ProviderDot(this.tone, {super.key});

  final StatusTone tone;

  @override
  Widget build(BuildContext context) => AnimatedStatusDot(tone: tone, size: 8);
}

// ── Form anatomy ─────────────────────────────────────────────────────────────

/// 20 round tick of a multiple choice: a thin ring, or the primary disc with
/// a white check.
class SelectionTick extends StatelessWidget {
  const SelectionTick({super.key, required this.checked, this.dimmed = false});

  final bool checked;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ring = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.22)
        : scheme.onSurface.withValues(alpha: 0.18);
    final fill = dimmed ? scheme.onSurface.withValues(alpha: 0.28) : scheme.primary;
    final quick = AppMotion.of(context, AppMotion.quick);
    return SizedBox.square(
      dimension: 20,
      child: AnimatedContainer(
        duration: quick,
        curve: AppMotion.std,
        decoration: ShapeDecoration(
          color: checked ? fill : Colors.transparent,
          shape: CircleBorder(side: checked ? BorderSide.none : BorderSide(color: ring, width: 1.5)),
        ),
        child: AnimatedOpacity(
          duration: quick,
          opacity: checked ? 1 : 0,
          child: Icon(AppIcons.selected, size: 14, color: scheme.onPrimary),
        ),
      ),
    );
  }
}

/// Fields inside a card: 16 on the sides, 12 above the first label, each field
/// keeps 16 below itself.
class FormFieldGroup extends StatelessWidget {
  const FormFieldGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, SettingsMetrics.inset, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// Label row (at least 28 tall, optional trailing action ending flush with the
/// field), the field, and one line under it on the label's edge: [error] when
/// set, else [helper]. Callers keep the field's red outline with
/// `InputDecoration(error: SizedBox.shrink())` and leave the text to this line.
/// [below] (quick picks for the field) sits 10 under all of that.
class FormFieldBlock extends StatelessWidget {
  const FormFieldBlock({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.error,
    this.trailing,
    this.below,
  });

  final String label;
  final Widget child;
  final String? helper;
  final String? error;
  final Widget? trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormFieldLabel(label, trailing: trailing),
          const SizedBox(height: FormFieldLabel.gap),
          child,
          SmoothSize(
            duration: AppMotion.of(context, AppMotion.standard),
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.standard),
              child: error == null && helper == null
                  ? const SizedBox.shrink()
                  : SizedBox(
                      key: ValueKey((error != null, error ?? helper)),
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                        child: Semantics(
                          liveRegion: error != null,
                          child: Text(
                            error ?? helper!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: error != null ? DshColors.of(context).danger : DshColors.of(context).textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          if (below case final below?) ...[const SizedBox(height: 10), below],
        ],
      ),
    );
  }
}

/// A field's label row, the one label style of a form: at least 28 tall, the
/// label 4 in from the field's edge ([indent]), an optional trailing control
/// ending flush with the field. The field follows [gap] below.
class FormFieldLabel extends StatelessWidget {
  const FormFieldLabel(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  static const indent = 4.0;
  static const gap = 4.0;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 28),
    child: Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: indent),
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A compact text action in a field's label row; its label ends flush with
/// the field's edge.
class FormSmallButton extends StatelessWidget {
  const FormSmallButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: Theme.of(context).textTheme.labelMedium,
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

/// The form page's bottom bar: the primary action stays above the page (and
/// above the keyboard) over a soft fade of the page background.
class FormBottomBar extends StatelessWidget {
  const FormBottomBar({super.key, required this.child});

  final Widget child;

  /// Room to leave at the end of the page so nothing hides under the bar.
  static const height = 88.0;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    final base = DshSurfaces.of(context).backdropBottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [base.withValues(alpha: 0), base.withValues(alpha: 0.96), base.withValues(alpha: 0.98)],
          stops: const [0, 0.26, 1],
        ),
      ),
      child: Padding(padding: EdgeInsets.fromLTRB(16, 24, 16, 12 + bottom), child: child),
    );
  }
}
