// Sheets of the run-time editor: a one-choice list (重复 / 对话 / 工作区), the
// clock and date wheels, the month-day grid and the searchable time-zone list.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../common/search_capsule.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'time_zones.dart';

/// One row of [showChoiceSheet].
class Choice<T> {
  const Choice(this.value, this.title, {this.subtitle, this.icon, this.meta});
  final T value;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? meta;
}

/// A titled list of choices; pops with the tapped value.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<Choice<T>> choices,
  required T selected,
}) => showAppSheet<T>(
  context,
  isScrollControlled: true,
  builder: (sheet) {
    final max = MediaQuery.sizeOf(sheet).height * 0.62;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(title),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: max),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: SheetGroup(
                children: [
                  for (final c in choices)
                    ListPageRow(
                      icon: c.icon,
                      title: c.title,
                      subtitle: c.subtitle,
                      meta: c.value == selected ? null : c.meta,
                      trailing: c.value == selected ? const SelectedMark() : null,
                      chevron: false,
                      onTap: () => Navigator.pop(sheet, c.value),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  },
);

/// The check at the end of the chosen row.
class SelectedMark extends StatelessWidget {
  const SelectedMark({super.key});

  @override
  Widget build(BuildContext context) => Icon(AppIcons.selected, size: 20, color: Theme.of(context).colorScheme.primary);
}

/// Wheels follow the app theme, not the platform brightness.
Widget _wheelTheme(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  return CupertinoTheme(
    data: CupertinoThemeData(
      brightness: theme.brightness,
      textTheme: CupertinoTextThemeData(
        dateTimePickerTextStyle: AppType.tabular(
          theme.textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w400, color: theme.colorScheme.onSurface),
        ),
      ),
    ),
    child: child,
  );
}

Future<T?> _wheelSheet<T>(
  BuildContext context, {
  required String title,
  required Widget Function(ValueSetter<T> onChanged) wheel,
  required T initial,
}) {
  var value = initial;
  return showAppSheet<T>(
    context,
    dismissal: SheetDismissal.button,
    builder: (sheet) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(title),
          SizedBox(height: 216, child: _wheelTheme(sheet, wheel((v) => value = v))),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 12, SheetTitleBar.inset, 12),
            child: FilledButton(onPressed: () => Navigator.pop(sheet, value), child: Text(context.l10n.commonDone)),
          ),
        ],
      ),
    ),
  );
}

/// A 24-hour clock wheel; pops with `(hour, minute)`.
Future<(int, int)?> showClockSheet(BuildContext context, {required int hour, required int minute}) =>
    _wheelSheet<(int, int)>(
      context,
      title: context.l10n.featuresTime,
      initial: (hour, minute),
      wheel: (onChanged) => CupertinoDatePicker(
        mode: CupertinoDatePickerMode.time,
        use24hFormat: true,
        initialDateTime: DateTime(2000, 1, 1, hour, minute),
        onDateTimeChanged: (d) => onChanged((d.hour, d.minute)),
      ),
    );

/// A date wheel from [first]; pops with the date (UTC midnight).
Future<DateTime?> showDaySheet(BuildContext context, {required DateTime date, required DateTime first}) =>
    _wheelSheet<DateTime>(
      context,
      title: context.l10n.featuresDate,
      initial: date,
      wheel: (onChanged) => CupertinoDatePicker(
        mode: CupertinoDatePickerMode.date,
        dateOrder: DatePickerDateOrder.ymd,
        initialDateTime: DateTime(date.year, date.month, date.day),
        minimumDate: DateTime(first.year, first.month, first.day),
        maximumDate: DateTime(first.year + 5, 12, 31),
        onDateTimeChanged: (d) => onChanged(DateTime.utc(d.year, d.month, d.day)),
      ),
    );

/// Round day key (weekday row, month grid): ink when on, faint when off.
class DayKey extends StatelessWidget {
  const DayKey({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.size = 36,
    this.semanticLabel,
  });

  final String label;

  /// Read instead of [label] (`周一`, `15 日`).
  final String? semanticLabel;
  final bool selected;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final quick = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: size / 2 + 4,
        child: AnimatedContainer(
          duration: quick,
          curve: AppMotion.std,
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: selected
                ? scheme.onSurface
                : dark
                ? Colors.white.withValues(alpha: 0.07)
                : scheme.onSurface.withValues(alpha: 0.05),
            shape: const CircleBorder(),
          ),
          child: Text(
            label,
            style: AppType.tabular(
              theme.textTheme.labelLarge!.copyWith(
                fontSize: 13,
                color: selected ? scheme.surface : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Days of the month (7 × 5 grid); pops with the chosen set.
Future<Set<int>?> showMonthDaysSheet(BuildContext context, {required Set<int> days}) {
  final picked = {...days};
  return showAppSheet<Set<int>>(
    context,
    dismissal: SheetDismissal.button,
    builder: (sheet) => SafeArea(
      top: false,
      child: StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(context.l10n.featuresDate),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset + 4),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const columns = 7;
                  final key = ((constraints.maxWidth - 6 * 8) / columns).clamp(32.0, 44.0);
                  final gap = (constraints.maxWidth - columns * key) / (columns - 1);
                  return Wrap(
                    spacing: gap,
                    runSpacing: 10,
                    children: [
                      for (var d = 1; d <= 31; d++)
                        DayKey(
                          label: '$d',
                          semanticLabel: context.l10n.featuresMonthDayChoice(d),
                          size: key,
                          selected: picked.contains(d),
                          onTap: () => setState(() => picked.contains(d) ? picked.remove(d) : picked.add(d)),
                        ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 20, SheetTitleBar.inset, 12),
              child: FilledButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(sheet, picked),
                child: Text(context.l10n.commonDone),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// `上海 · UTC+08:00`.
String zoneLabel(String name, {DateTime? at}) {
  final offset = zoneOffset(name, at: at);
  return offset == null ? name : '${zoneCity(name)} · ${formatUtcOffset(offset)}';
}

/// The searchable zone list: this phone's zone first, then every zone by
/// its offset [at] (now when null). Pops with the IANA name.
Future<String?> showZoneSheet(BuildContext context, {required String selected, required String device, DateTime? at}) =>
    showAppSheet<String>(
      context,
      heightFactor: 0.82,
      builder: (_) => _ZoneSheet(selected: selected, device: device, at: at),
    );

class _ZoneSheet extends StatefulWidget {
  const _ZoneSheet({required this.selected, required this.device, this.at});

  final String selected;
  final String device;
  final DateTime? at;

  @override
  State<_ZoneSheet> createState() => _ZoneSheetState();
}

class _ZoneSheetState extends State<_ZoneSheet> {
  late final _zones = allZones(at: widget.at);
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final pinned = <String>{widget.device, if (widget.selected != widget.device) widget.selected};
    final searching = _query.trim().isNotEmpty;
    // Rows: a section label (String) or a zone.
    final shown = <Object>[
      if (searching)
        for (final z in _zones)
          if (z.matches(_query)) z,
      if (!searching) ...[
        for (final name in pinned) ?_zones.where((z) => z.name == name).firstOrNull,
        l10n.featuresZonesCommon,
        for (final z in _zones)
          if (isCommonZone(z.name) && !pinned.contains(z.name)) z,
        l10n.featuresZonesAll,
        for (final z in _zones)
          if (!isCommonZone(z.name) && !pinned.contains(z.name)) z,
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(l10n.featuresTimeZone),
        Padding(
          padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
          child: SearchCapsule(
            hint: l10n.featuresZoneSearchHint,
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            onClear: () => setState(() {
              _search.clear();
              _query = '';
            }),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(
                    l10n.featuresZonesNoMatch,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    SheetTitleBar.inset - ListPageRow.horizontal,
                    0,
                    SheetTitleBar.inset - ListPageRow.horizontal,
                    16 + MediaQuery.viewPaddingOf(context).bottom,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final item = shown[i];
                    if (item is String) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SheetSectionLabel(item, inset: ListPageRow.horizontal - 8),
                      );
                    }
                    final z = item as ZoneChoice;
                    final picked = z.name == widget.selected;
                    return ListPageRow(
                      title: z.city,
                      subtitle: z.name == widget.device ? l10n.featuresZoneThisPhone(z.name) : z.name,
                      meta: picked ? null : z.offsetLabel,
                      trailing: picked
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  z.offsetLabel,
                                  style: AppType.tabular(
                                    theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const SelectedMark(),
                              ],
                            )
                          : null,
                      chevron: false,
                      onTap: () => Navigator.pop(context, z.name),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
