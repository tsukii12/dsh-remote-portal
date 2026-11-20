// A number setting: a few common values as pills, and 「自定义」 for any other
// within the setting's bounds, typed in a dialog. Once a typed value is in
// use its pill shows it; tapping that pill again edits it.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../settings/settings_widgets.dart';
import '../workspace/text_prompt.dart';

/// 0.85 as `0.85`, 1.0 as `1`, 4096 as `4096`.
String tavernNumberText(num value) {
  if (value == value.roundToDouble()) return value.round().toString();
  var text = value.toStringAsFixed(4);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// Asks for a number between [min] and [max] (whole when [integer]); null
/// when cancelled.
Future<num?> showTavernNumberPrompt(
  BuildContext context, {
  required String title,
  required num min,
  required num max,
  num? initial,
  bool integer = false,
}) async {
  final l10n = context.l10n;
  num? parse(String text) => integer ? int.tryParse(text) : double.tryParse(text);
  final range = integer
      ? l10n.tavernNumberRangeWhole(tavernNumberText(min), tavernNumberText(max))
      : l10n.tavernNumberRange(tavernNumberText(min), tavernNumberText(max));
  final text = await showTextPrompt(
    context,
    title: title,
    // As stored, every digit: confirming unchanged must not round it.
    initial: initial == null ? '' : (initial == initial.roundToDouble() ? '${initial.round()}' : '$initial'),
    caption: range,
    keyboardType: TextInputType.numberWithOptions(decimal: !integer, signed: min < 0),
    validate: (text) => switch (parse(text)) {
      final n? when n >= min && n <= max => null,
      _ => range,
    },
  );
  return text == null ? null : parse(text);
}

class TavernNumberTile extends StatelessWidget {
  const TavernNumberTile({
    super.key,
    this.icon,
    this.tinted = true,
    required this.title,
    this.subtitle,
    required this.presets,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.integer = false,
    this.label = tavernNumberText,
    this.presetLabel,
  });

  final IconData? icon;
  final bool tinted;
  final String title;
  final String? subtitle;
  final List<num> presets;
  final num value;
  final num min;
  final num max;
  final bool integer;
  final ValueChanged<num>? onChanged;

  /// How a typed value reads on its pill (`$0.20`).
  final String Function(num value) label;

  /// How a preset reads, when not as [label] has it (`16K`, 「大」).
  final String Function(num value)? presetLabel;

  @override
  Widget build(BuildContext context) {
    final typed = !presets.contains(value);
    final onChanged = this.onChanged;
    Future<void> ask() async {
      final number = await showTavernNumberPrompt(
        context,
        title: title,
        min: min,
        max: max,
        initial: typed ? value : null,
        integer: integer,
      );
      if (number != null && number != value) onChanged!(number);
    }

    return SettingsSegmentTile<num?>(
      icon: icon,
      tinted: tinted,
      title: title,
      subtitle: subtitle,
      segments: [
        for (final p in presets) PillSegment<num?>(p, (presetLabel ?? label)(p)),
        PillSegment<num?>(null, typed ? label(value) : context.l10n.tavernNumberCustom),
      ],
      selected: typed ? null : value,
      onChanged: onChanged == null
          ? null
          : (picked) {
              picked == null ? unawaited(ask()) : onChanged(picked);
            },
      onReselect: onChanged == null
          ? null
          : (picked) {
              if (picked == null) unawaited(ask());
            },
    );
  }
}
