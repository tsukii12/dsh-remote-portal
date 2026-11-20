import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/overlay_channel.dart';
import '../../state/app_info.dart';
import '../../state/phone_state.dart';
import '../common/capsule_chip.dart';
import '../common/list_page_row.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_widgets.dart';

/// ROM families with their own way to "允许受限制的设置".
enum RomFamily {
  vivo,
  xiaomi,
  oppo,
  honor,
  huawei,
  stock;

  String get label => switch (this) {
    RomFamily.vivo => 'vivo / iQOO',
    RomFamily.xiaomi => appL10n.brandXiaomi,
    RomFamily.oppo => appL10n.brandOppo,
    RomFamily.honor => appL10n.brandHonor,
    RomFamily.huawei => appL10n.brandHuawei,
    RomFamily.stock => appL10n.phoneRomStock,
  };

  /// From `Build.MANUFACTURER` (or brand); unknown → [stock].
  static RomFamily of(String? manufacturer) {
    final m = (manufacturer ?? '').toLowerCase();
    if (m.contains('vivo') || m.contains('iqoo')) return vivo;
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return xiaomi;
    }
    if (m.contains('oppo') || m.contains('oneplus') || m.contains('realme')) {
      return oppo;
    }
    if (m.contains('honor')) return honor;
    if (m.contains('huawei')) return huawei;
    return stock;
  }
}

/// Which switch the restricted setting greys out: phone control's accessibility
/// service, or the floating pet's 「显示在其他应用上层」.
enum RestrictedTarget {
  accessibility,
  overlay;

  /// Where the switch lives in system settings.
  String get place => switch (this) {
    RestrictedTarget.accessibility => appL10n.phoneRestrictedAccessibility,
    RestrictedTarget.overlay => appL10n.phoneRestrictedOverlay,
  };

  /// The page's main button.
  String get action => switch (this) {
    RestrictedTarget.accessibility => appL10n.phoneRestrictedOpenAccessibility,
    RestrictedTarget.overlay => appL10n.phoneRestrictedOpenOverlay,
  };
}

/// Where the option sits on the App info page, for the drawn diagram.
enum GuideSpot { overflowMenu, advancedSection }

class RomGuide {
  const RomGuide({required this.steps, this.spot, this.note, this.noteTone = NoteTone.info});

  final List<String> steps;
  final GuideSpot? spot;
  final String? note;
  final NoteTone noteTone;

  /// [of] with the steps pointing at [target]'s switch.
  static RomGuide forTarget(RomFamily rom, RestrictedTarget target) {
    final overlay = target == RestrictedTarget.overlay;
    final tryOnce = overlay ? appL10n.phoneRestrictedTryOverlay : appL10n.phoneRestrictedTryAccessibility;
    final back = overlay ? appL10n.phoneRestrictedBackOverlay : appL10n.phoneRestrictedBackAccessibility;
    final menuSteps = [tryOnce, appL10n.phoneRestrictedOpenInfoStep, appL10n.phoneRestrictedMenuStep, back];
    return switch (rom) {
      RomFamily.stock || RomFamily.honor => RomGuide(steps: menuSteps, spot: GuideSpot.overflowMenu),
      RomFamily.vivo => RomGuide(steps: menuSteps, spot: GuideSpot.overflowMenu, note: appL10n.phoneRestrictedVivoNote),
      RomFamily.xiaomi => RomGuide(
        steps: [tryOnce, appL10n.phoneRestrictedOpenInfoStep, appL10n.phoneRestrictedAdvancedStep, back],
        spot: GuideSpot.advancedSection,
      ),
      RomFamily.oppo => RomGuide(
        steps: menuSteps,
        spot: GuideSpot.overflowMenu,
        note: appL10n.phoneRestrictedOppoNote,
        noteTone: NoteTone.warn,
      ),
      RomFamily.huawei => RomGuide(
        steps: [
          overlay ? appL10n.phoneRestrictedHuaweiOverlay : appL10n.phoneRestrictedHuaweiAccessibility,
          appL10n.phoneRestrictedHuaweiNote,
        ],
      ),
    };
  }

  static RomGuide of(RomFamily rom) => forTarget(rom, RestrictedTarget.accessibility);
}

/// Step-by-step help for Android 13+'s "restricted settings", which greys out the
/// accessibility switch for sideloaded apps, and the overlay switch too. Text
/// plus a drawn sketch of the App info page; no screenshots, since ROM screens
/// change.
class RestrictedSettingsGuidePage extends ConsumerStatefulWidget {
  const RestrictedSettingsGuidePage({super.key, this.rom, this.target = RestrictedTarget.accessibility});

  /// Preselected family; null → from the device's manufacturer.
  final RomFamily? rom;

  /// Whose switch is greyed out.
  final RestrictedTarget target;

  @override
  ConsumerState<RestrictedSettingsGuidePage> createState() => _RestrictedSettingsGuidePageState();
}

class _RestrictedSettingsGuidePageState extends ConsumerState<RestrictedSettingsGuidePage> {
  /// Picked by the person; until then, from the device.
  RomFamily? _picked;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(
        widget.target == RestrictedTarget.overlay
            ? ref.read(petOverlayProvider.notifier).refresh()
            : ref.read(phoneProvider.notifier).refreshStatus(),
      ),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _open(Future<bool> Function() action, String fallback) async {
    final ok = await action();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(fallback)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final overlay = widget.target == RestrictedTarget.overlay;
    final done = overlay
        ? ref.watch(petOverlayProvider.select((s) => s.permission.usable))
        : ref.watch(phoneProvider.select((s) => s.status.a11y.enabled));
    final rom =
        _picked ?? widget.rom ?? RomFamily.of(ref.watch(phoneProvider.select((s) => s.status.device.manufacturer)));
    final guide = RomGuide.forTarget(rom, widget.target);
    final phone = ref.read(phoneProvider.notifier);
    return AppPage.list(
      title: l10n.phoneRestrictedTitle,
      subtitle: Text(l10n.phoneRestrictedSubtitle(widget.target.place)),
      children: [
        if (done) PhoneNote(icon: AppIcons.completed, text: l10n.phoneRestrictedDone(widget.target.place)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final family in RomFamily.values)
                CapsuleChoiceChip(
                  label: family.label,
                  selected: family == rom,
                  onSelected: () => setState(() => _picked = family),
                ),
            ],
          ),
        ),
        ListPageCard(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          title: l10n.phoneRestrictedSteps,
          children: [NumberedSteps(guide.steps)],
        ),
        if (guide.spot case final spot?)
          ListPageCard(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            title: l10n.phoneRestrictedDiagram,
            children: [GuideDiagram(advanced: spot == GuideSpot.advancedSection)],
          ),
        if (guide.note case final note?) PhoneNote(text: note, tone: guide.noteTone),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => _open(phone.openAppDetails, l10n.phoneOpenAppInfoFailed),
                  child: Text(l10n.phoneRestrictedOpenInfo),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => overlay
                      ? _open(
                          ref.read(petOverlayProvider.notifier).openPermission,
                          l10n.phoneRestrictedOpenOverlayFailed,
                        )
                      : _open(phone.openAccessibilitySettings, l10n.phoneRestrictedOpenAccessibilityFailed),
                  child: Text(widget.target.action),
                ),
              ),
            ],
          ),
        ),
        PageFootnote(l10n.phoneRestrictedFootnote),
      ],
    );
  }
}

/// Two sketched phone screens: App info → the option. Drawn with widgets so it
/// follows the theme and never goes stale like a screenshot would.
class GuideDiagram extends StatelessWidget {
  const GuideDiagram({super.key, this.advanced = false});

  /// Xiaomi-style: the option sits under 「高级设置」 instead of the ⋮ menu.
  final bool advanced;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget caption(String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(color: muted),
      ),
    );

    final first = advanced
        ? _MiniPhone(
            title: l10n.phoneRestrictedAppInfo,
            children: [
              const _MiniApp(),
              _MiniRow(l10n.phoneRestrictedPermissionsManager),
              _MiniRow(l10n.phoneRestrictedBatterySaver),
              _MiniRow(l10n.phoneRestrictedAdvanced, highlight: true, chevron: true),
            ],
          )
        : _MiniPhone(
            title: l10n.phoneRestrictedAppInfo,
            menuHighlight: true,
            children: [
              const _MiniApp(),
              _MiniRow(l10n.phoneControlNotifications),
              _MiniRow(l10n.phoneRestrictedPermissions),
              _MiniRow(l10n.phoneRestrictedBattery),
            ],
          );
    final second = advanced
        ? _MiniPhone(
            title: l10n.phoneRestrictedAdvanced,
            children: [
              const _MiniRow.placeholder(),
              _MiniRow(l10n.phoneRestrictedTitle, highlight: true, toggle: true),
              const _MiniRow.placeholder(),
            ],
          )
        : _MiniPhone(
            title: l10n.phoneRestrictedAppInfo,
            dimmed: true,
            popup: [null, l10n.phoneRestrictedTitle],
            children: [
              const _MiniApp(),
              _MiniRow(l10n.phoneControlNotifications),
              _MiniRow(l10n.phoneRestrictedPermissions),
              _MiniRow(l10n.phoneRestrictedBattery),
            ],
          );

    return Semantics(
      label: advanced ? l10n.phoneRestrictedDiagramAdvanced : l10n.phoneRestrictedDiagramMenu,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    first,
                    caption(advanced ? l10n.phoneRestrictedCaptionAdvanced : l10n.phoneRestrictedCaptionMenu),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 100),
                child: Icon(AppIcons.forward, size: 20, color: muted),
              ),
              Expanded(
                child: Column(
                  children: [
                    second,
                    caption(advanced ? l10n.phoneRestrictedCaptionToggle : l10n.phoneRestrictedCaptionOption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPhone extends StatelessWidget {
  const _MiniPhone({
    required this.title,
    required this.children,
    this.menuHighlight = false,
    this.dimmed = false,
    this.popup,
  });

  final String title;
  final List<Widget> children;
  final bool menuHighlight;

  /// The page under an open popup menu.
  final bool dimmed;

  /// Popup menu items (null: an unlabeled placeholder); the last one is the target.
  final List<String?>? popup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.labelSmall!.copyWith(fontSize: 10, height: 1.3);
    final page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Status bar.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Row(
            children: [
              _Bar(width: 14, color: scheme.outlineVariant),
              const Spacer(),
              _Bar(width: 20, color: scheme.outlineVariant),
            ],
          ),
        ),
        // App bar.
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 4, 4),
          child: Row(
            children: [
              Icon(AppIcons.back, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
                ),
              ),
              _Ring(
                on: menuHighlight,
                circle: true,
                child: Icon(
                  AppIcons.moreVertical,
                  size: 14,
                  color: menuHighlight ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ...children,
        const SizedBox(height: 8),
      ],
    );
    return AspectRatio(
      aspectRatio: 0.6,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: scheme.surface,
          shape: RoundedSuperellipseBorder(
            borderRadius: AppShape.radiusLg,
            side: BorderSide(color: scheme.outlineVariant, width: 1.5),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: AppShape.radiusLg,
          child: Stack(
            children: [
              Positioned.fill(
                child: Opacity(opacity: dimmed ? 0.35 : 1, child: page),
              ),
              if (popup case final items?)
                Positioned(
                  top: 22,
                  right: 4,
                  left: 14,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: scheme.surfaceContainerHighest,
                      shadows: const [BoxShadow(blurRadius: 8, color: Color(0x33000000), offset: Offset(0, 2))],
                      shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusSm),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, item) in items.indexed)
                            item == null
                                ? const _MiniRow.placeholder(dense: true)
                                : _MiniRow(item, highlight: i == items.length - 1, dense: true),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniApp extends StatelessWidget {
  const _MiniApp();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(color: scheme.primary, shape: const CircleBorder()),
            child: const SizedBox.square(dimension: 22),
          ),
          const SizedBox(height: 3),
          Text(AppInfo.name, style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _MiniRow extends StatelessWidget {
  const _MiniRow(this.label, {this.highlight = false, this.chevron = false, this.toggle = false, this.dense = false});

  /// A row whose label doesn't matter: drawn as a bar, so the sketch never
  /// claims a menu item a given ROM may not have.
  const _MiniRow.placeholder({this.dense = false}) : label = null, highlight = false, chevron = false, toggle = false;

  final String? label;
  final bool highlight;
  final bool chevron;
  final bool toggle;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = this.label;
    if (label == null) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 6 : 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _Bar(width: dense ? 48 : 56, color: scheme.outlineVariant),
        ),
      );
    }
    final color = highlight ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        fontSize: 10,
        height: 1.3,
        color: color,
        fontWeight: highlight ? FontWeight.w600 : null,
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: dense ? 3 : 5, vertical: dense ? 1 : 2),
      child: _Ring(
        on: highlight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 5, vertical: dense ? 4 : 5),
          child: Row(
            children: [
              Expanded(child: text),
              if (chevron) Icon(AppIcons.disclosure, size: 12, color: color),
              if (toggle)
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: highlight ? scheme.primary : scheme.outlineVariant,
                    shape: const StadiumBorder(),
                  ),
                  child: SizedBox(
                    width: 18,
                    height: 10,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.all(1.5),
                        child: DecoratedBox(
                          decoration: ShapeDecoration(color: scheme.onPrimary, shape: const CircleBorder()),
                          child: const SizedBox.square(dimension: 7),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The highlight: accent ring + tint around the thing to tap.
class _Ring extends StatelessWidget {
  const _Ring({required this.on, required this.child, this.circle = false});

  final bool on;
  final bool circle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!on) {
      return circle ? Padding(padding: const EdgeInsets.all(3), child: child) : child;
    }
    final side = BorderSide(color: scheme.primary, width: 1.5);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: scheme.primaryContainer,
        shape: circle
            ? CircleBorder(side: side)
            : RoundedSuperellipseBorder(borderRadius: AppShape.radiusXs, side: side),
      ),
      child: circle ? Padding(padding: const EdgeInsets.all(3), child: child) : child,
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
    child: SizedBox(width: width, height: 4),
  );
}
