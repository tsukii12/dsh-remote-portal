// The parameter sheet of generation mode (docs/design/media-generation.md
// §4.2–§4.3): [图像 | 视频], the model (a page of its own in the sheet,
// grouped by service), then the choices the model allows — aspect, number and
// quality (「自动」 first: the host's) for pictures; length and resolution for
// video — and 「约 ¥0.60」 when the catalogue has a price. A set the catalogue
// leaves empty doesn't show. No 声音: header v1 has no sound field (§4.6.4).
// A choice applies at once; the sheet has no done key.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show MediaCost;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/media_generation.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../common/segmented_pill.dart';
import '../../common/sheet_navigator.dart';
import '../../common/sheet_title_bar.dart';
import '../../settings/media_settings_page.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'media_format.dart';

/// Opens the sheet on [params]; every change goes to [onChanged].
Future<void> showGenerateSheet(
  BuildContext context, {
  required GenerateParams params,
  required ValueChanged<GenerateParams> onChanged,
}) async {
  final controller = GenerateSheetController(params, onChanged);
  try {
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: SheetNavigator(root: (_) => GenerateSheet(controller: controller)),
        ),
      ),
    );
  } finally {
    controller.dispose();
  }
}

/// The values the sheet edits, outside its pages (the model page replaces
/// the first one while it shows).
class GenerateSheetController extends ValueNotifier<GenerateParams> {
  GenerateSheetController(super.value, this.onChanged) : _byKind = {value.kind: value};

  final ValueChanged<GenerateParams> onChanged;

  /// Each kind keeps its own values while the sheet is open.
  final Map<GenerateKind, GenerateParams> _byKind;

  /// [next], fitted to what its model allows, applied at once.
  void apply(GenerateParams next, MediaCatalog catalog) {
    final fitted = next.fitTo(catalog);
    if (fitted == value) return;
    HapticFeedback.selectionClick();
    value = fitted;
    _byKind[fitted.kind] = fitted;
    onChanged(fitted);
  }

  /// [kind]'s values: as last left in this sheet, else [start] (on this
  /// host's models).
  void switchKind(GenerateKind kind, MediaCatalog catalog, GenerateParams start) {
    if (kind == value.kind) return;
    apply(_byKind[kind] ?? start.startOn(catalog), catalog);
  }
}

/// The estimate for [params] on [model]: per picture × number, or per
/// second × length; null without a price.
double? estimateCost(GenerateParams params, MediaModel? model) {
  final price = model?.price;
  if (price == null) return null;
  if (!price.perSecond) return price.amount * params.count;
  final seconds = params.seconds;
  return seconds == null ? null : price.amount * seconds;
}

class GenerateSheet extends ConsumerWidget {
  const GenerateSheet({super.key, required this.controller});

  final GenerateSheetController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder<GenerateParams>(
    valueListenable: controller,
    builder: (context, params, _) => _page(context, ref, params),
  );

  Widget _page(BuildContext context, WidgetRef ref, GenerateParams params) {
    void set(GenerateParams next) => controller.apply(next, ref.read(mediaCatalogProvider));
    void kind(GenerateKind kind) =>
        controller.switchKind(kind, ref.read(mediaCatalogProvider), ref.read(generateModeProvider).startOf(kind));
    final l10n = context.l10n;
    final catalog = ref.watch(mediaCatalogProvider);
    // Null while the mode names a model this host can't pin: 「请选择」.
    final entry = catalog.resolve(params.model, params.kind);
    final model = entry?.model;
    final cost = estimateCost(params, model);
    const inset = SheetTitleBar.inset;

    Widget choices<T>(String label, List<(T, String)> options, T selected, ValueChanged<T> onPick) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        SheetSectionLabel(label),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: inset),
          child: SegmentedPill<T>(
            height: 40,
            expand: true,
            segments: [for (final (value, text) in options) PillSegment(value, text)],
            selected: options.any((o) => o.$1 == selected) ? selected : options.first.$1,
            onChanged: onPick,
          ),
        ),
      ],
    );

    final ratios = model?.ratios ?? const <String>[];
    final qualities = model?.qualities ?? const <String>[];
    final durations = (model?.durations ?? const <int>[]).take(3).toList();
    final resolutions = (model?.resolutions ?? const <String>[]).where((r) => r != '4k' && r != '2160p').toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // [图像 | 视频] only where the host has models of both.
        if (catalog.kinds.length == 1)
          const SizedBox(height: 4)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(inset, 4, inset, 12),
            child: SegmentedPill<GenerateKind>(
              height: 40,
              expand: true,
              segments: [
                PillSegment(GenerateKind.image, l10n.mediaKindImage),
                PillSegment(GenerateKind.video, l10n.mediaKindVideo),
              ],
              selected: params.kind,
              onChanged: kind,
            ),
          ),
        SheetGroup(
          margin: const EdgeInsets.symmetric(horizontal: inset),
          children: [
            ListPageRow(
              title: l10n.mediaParamModel,
              value: model?.label ?? l10n.mediaModelPick,
              onTap: () => SheetNavigator.of(context).push(
                (_) => _ModelPage(
                  kind: params.kind,
                  selected: entry?.key,
                  // The model page outlives this one: it applies with its own ref.
                  onPick: (e, catalog) => controller.apply(controller.value.copyWith(model: e.ref), catalog),
                ),
              ),
            ),
          ],
        ),
        if (ratios.length > 1)
          choices(
            l10n.mediaParamAspect,
            [for (final r in ratios) (r, r)],
            params.aspect,
            (v) => set(params.copyWith(aspect: v)),
          ),
        if (!params.isVideo && (model?.maxN ?? 1) > 1)
          choices(
            l10n.mediaParamCount,
            [for (var n = 1; n <= (model?.maxN ?? 1); n++) (n, '$n')],
            params.count,
            (v) => set(params.copyWith(count: v)),
          ),
        if (!params.isVideo && qualities.isNotEmpty)
          choices<String?>(
            l10n.mediaParamQuality,
            [(null, l10n.mediaQualityAuto), for (final q in qualities) (q, qualityWord(q))],
            params.quality,
            (v) => set(params.copyWith(quality: v)),
          ),
        if (params.isVideo && durations.length > 1)
          choices(
            l10n.mediaParamDuration,
            [for (final s in durations) (s, l10n.mediaSeconds(s))],
            params.seconds ?? durations.first,
            (v) => set(params.copyWith(seconds: v)),
          ),
        if (params.isVideo && resolutions.length > 1)
          choices(
            l10n.mediaParamQuality,
            [for (final r in resolutions) (r, r)],
            params.resolution ?? resolutions.first,
            (v) => set(params.copyWith(resolution: v)),
          ),
        const SizedBox(height: 12),
        _CostLine(text: cost == null ? null : mediaCostText(MediaCost(cost, model!.price!.currency))),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// A catalogue quality in words: 「标准」 · 「高清」 · 「4K」, 「低」 · 「中」 ·
/// 「高」; any other value as it is. The header carries the value itself.
String qualityWord(String id) => switch (id) {
  '1k' => appL10n.mediaQualityStandard,
  '2k' => appL10n.mediaQualityHigh,
  '4k' => appL10n.mediaQuality4k,
  'low' => appL10n.mediaQualityLevelLow,
  'medium' => appL10n.mediaQualityLevelMedium,
  'high' => appL10n.mediaQualityLevelHigh,
  _ => id,
};

/// 「约 ¥0.60」: 13, tertiary, centred, tabular figures; a new value fades in.
/// Nothing when the model has no price.
class _CostLine extends StatelessWidget {
  const _CostLine({required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final style = AppType.tabular(
      Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 13, color: DshColors.of(context).textTertiary),
    );
    final text = this.text;
    if (text == null) return const SizedBox.shrink();
    return Center(
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        child: Text(text, key: ValueKey(text), style: style),
      ),
    );
  }
}

/// 模型: grouped by service (one model on two services is a row under each),
/// each with its unit price; 管理 › at the end.
class _ModelPage extends ConsumerWidget {
  const _ModelPage({required this.kind, required this.selected, required this.onPick});

  final GenerateKind kind;

  /// [MediaEntry.key] of the mode's model.
  final String? selected;
  final void Function(MediaEntry entry, MediaCatalog catalog) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final entries = ref.watch(mediaCatalogProvider).of(kind);
    final namespaces = {for (final e in entries) e.namespace};
    final groups = <String, ({String title, List<MediaEntry> rows})>{};
    for (final e in entries) {
      groups
          .putIfAbsent(
            '${e.namespace}/${e.service.id}',
            // Two instances of the plugin: which one, too.
            () => (title: namespaces.length > 1 ? '${e.service.title} · ${e.namespace}' : e.service.title, rows: []),
          )
          .rows
          .add(e);
    }
    String? price(MediaModel m) {
      final p = m.price;
      if (p == null) return null;
      final money = formatMoney(p.amount, p.currency);
      return p.perSecond ? l10n.mediaPricePerSecond(money) : l10n.mediaPricePerImage(money);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(l10n.mediaParamModel),
        for (final (:title, :rows) in groups.values)
          SheetGroup(
            title: title,
            children: [
              for (final e in rows)
                Semantics(
                  selected: e.key == selected,
                  inMutuallyExclusiveGroup: true,
                  child: ListPageRow(
                    title: e.model.label,
                    meta: price(e.model),
                    chevron: false,
                    trailing: e.key == selected
                        ? Icon(AppIcons.selected, size: 22, color: theme.colorScheme.primary)
                        : const SizedBox.square(dimension: 22),
                    onTap: () {
                      onPick(e, ref.read(mediaCatalogProvider));
                      SheetNavigator.of(context).pop();
                    },
                  ),
                ),
            ],
          ),
        SheetGroup(
          children: [
            ListPageRow(
              title: l10n.mediaManageModels,
              onTap: () => unawaited(
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MediaSettingsPage())),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
