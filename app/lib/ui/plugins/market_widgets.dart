// What the official market adds to a plugin's card and detail
// (docs/design/plugin-market.md §5, §6): the section tag, the risk tag, the
// checks' flags in plain words, and the screenshots.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/plugins_state.dart';
import '../common/display_image.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'plugin_widgets.dart';

/// 「官方」 / 「适配 DSH Go」, then the risk tag: none for low, amber for
/// medium, red for high.
List<Widget> marketEntryBadges(BuildContext context, MarketEntry entry) {
  final l10n = context.l10n;
  final listing = entry.listing;
  return [
    switch (entry.section) {
      MarketSection.official => PluginBadge(l10n.marketTierOfficial, tone: PluginBadgeTone.official),
      MarketSection.adapted => PluginBadge(l10n.marketTierAdapted),
      null => null,
    },
    if (listing != null) MarketRiskChip.maybe(listing.risk),
  ].nonNulls.toList();
}

/// The risk tag of a medium or high risk plugin.
class MarketRiskChip extends StatelessWidget {
  const MarketRiskChip(this.risk, {super.key});

  final MarketRisk risk;

  static Widget? maybe(MarketRisk risk) => risk == MarketRisk.low ? null : MarketRiskChip(risk);

  @override
  Widget build(BuildContext context) => risk == MarketRisk.high
      ? PluginBadge(context.l10n.marketRiskHigh, tone: PluginBadgeTone.danger)
      : PluginBadge(context.l10n.marketRiskMedium, tone: PluginBadgeTone.warning);
}

/// A flag in a few words, and what the check saw (§5).
(String title, String explanation) marketFlagText(L10n l10n, String flag) => switch (flag) {
  'install-scripts' => (l10n.marketFlagInstallScripts, l10n.marketFlagInstallScriptsBody),
  'native-code' => (l10n.marketFlagNativeCode, l10n.marketFlagNativeCodeBody),
  'shell' => (l10n.marketFlagShell, l10n.marketFlagShellBody),
  'network' => (l10n.marketFlagNetwork, l10n.marketFlagNetworkBody),
  'filesystem' => (l10n.marketFlagFilesystem, l10n.marketFlagFilesystemBody),
  'obfuscated' => (l10n.marketFlagObfuscated, l10n.marketFlagObfuscatedBody),
  'not-adapted' => (l10n.marketFlagNotAdapted, l10n.marketFlagNotAdaptedBody),
  _ => (flag, l10n.marketFlagOtherBody),
};

/// The dot before a flag: red for high, amber for medium, quiet for low (or
/// a flag this app doesn't know).
Color marketFlagColor(BuildContext context, String flag) {
  final colors = DshColors.of(context);
  return switch (marketRiskFlagLevels[flag]) {
    MarketRisk.high => colors.danger,
    MarketRisk.medium => colors.warning,
    _ => colors.textTertiary,
  };
}

/// 「自动检查」: every flag explained, then the note that they are features,
/// not a verdict.
class MarketRiskCard extends StatelessWidget {
  const MarketRiskCard({super.key, required this.listing});

  final DshGoListing listing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final checked = listing.checkedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          margin: EdgeInsets.zero,
          title: l10n.marketChecksTitle,
          children: [
            if (listing.flags.isEmpty)
              ListPageRow(
                leading: Icon(AppIcons.verified, size: 20, color: colors.success),
                title: l10n.marketChecksClean,
              )
            else
              for (final flag in listing.flags)
                ListPageRow(
                  leading: _Dot(color: marketFlagColor(context, flag)),
                  title: marketFlagText(l10n, flag).$1,
                  subtitle: marketFlagText(l10n, flag).$2,
                  subtitleMaxLines: 3,
                ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            [
              l10n.marketChecksNote,
              if (checked != null) l10n.marketCheckedOn(l10n.monthDay(checked.toLocal())),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.6),
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 8,
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}

/// The installed version was withdrawn from the market: say so, and offer
/// the uninstall where the sheet has no other way to it.
class MarketBlockedBox extends StatelessWidget {
  const MarketBlockedBox({super.key, required this.version, this.onUninstall});

  final String version;
  final VoidCallback? onUninstall;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return PluginFailureBox(
      failure: PluginFailure(PluginFailureKind.unknown, l10n.marketBlockedTitle, l10n.marketBlockedMessage(version)),
      actions: [
        if (onUninstall case final uninstall?)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.onDanger,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: uninstall,
            child: Text(l10n.hubPluginUninstall),
          ),
      ],
    );
  }
}

/// The listing's screenshots side by side, phone-shaped (9:16) frames; one
/// that doesn't load keeps its frame with a quiet mark.
class MarketScreenshots extends StatelessWidget {
  const MarketScreenshots({super.key, required this.urls});

  final List<Uri> urls;

  static const height = 240.0;
  static const width = height * 9 / 16;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(child: Icon(AppIcons.image, size: 24, color: colors.textTertiary)),
    );
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => Squircle.clip(
          radius: AppShape.md,
          child: SizedBox(
            width: width,
            height: height,
            child: Image(
              image: imageForDisplay(NetworkImage(urls[i].toString()), width: width, height: height, pixelRatio: dpr),
              fit: BoxFit.cover,
              semanticLabel: context.l10n.marketScreenshot(i + 1),
              errorBuilder: (_, _, _) => placeholder,
              frameBuilder: (context, child, frame, sync) => frame == null && !sync ? placeholder : child,
            ),
          ),
        ),
      ),
    );
  }
}
