import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// The buttons of the failure and safe-mode cards: one full-width primary, the
/// secondary actions two to a row when every label fits half the width (an odd
/// one out takes the full width, last), else stacked, and a centred 「查看日志」
/// below — beside 「导出诊断包」 when [onExport] is set, the two quiet links as
/// mirrored halves. Buttons are at least 50 tall, 8 apart; long labels may wrap.
class RecoveryActions extends StatelessWidget {
  const RecoveryActions({
    super.key,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondary = const [],
    this.onLog,
    this.onExport,
  });

  static const double gap = 8;

  final String primaryLabel;
  final VoidCallback? onPrimary;
  final List<({String label, VoidCallback? onPressed})> secondary;
  final VoidCallback? onLog;

  /// 「导出诊断包」, next to 「查看日志」.
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The outlined button's label style and side padding (app_theme).
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15);
    const padding = 2 * 22.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - gap) / 2;
        bool fits(String label, {double? availableWidth, double insets = padding}) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: labelStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width + insets <= (availableWidth ?? half);
        }

        Widget labelText(String label, {double insets = padding}) {
          final singleLine = fits(label, availableWidth: constraints.maxWidth, insets: insets);
          return Text(label, maxLines: singleLine ? 1 : null, textAlign: singleLine ? null : TextAlign.center);
        }
        Widget outlined(({String label, VoidCallback? onPressed}) action) =>
            OutlinedButton(onPressed: action.onPressed, child: labelText(action.label));
        final paired = secondary.length > 1 && secondary.every((a) => fits(a.label));
        Widget link(String label, VoidCallback onPressed) => TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: labelText(label),
        );
        final links = [
          if (onLog case final onLog?) link(l10n.commonViewLogs, onLog),
          if (onExport case final onExport?) link(l10n.phoneDiagnosticsExport, onExport),
        ];
        final linksPaired = links.length == 2 && fits(l10n.commonViewLogs) && fits(l10n.phoneDiagnosticsExport);
        final rows = <Widget>[
          if (paired)
            for (var i = 0; i < secondary.length; i += 2)
              i + 1 < secondary.length
                  ? Row(
                      children: [
                        Expanded(child: outlined(secondary[i])),
                        const SizedBox(width: gap),
                        Expanded(child: outlined(secondary[i + 1])),
                      ],
                    )
                  : outlined(secondary[i])
          else
            for (final action in secondary) outlined(action),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(onPressed: onPrimary, child: labelText(primaryLabel, insets: 48)),
            for (final row in rows) ...[const SizedBox(height: gap), row],
            if (linksPaired) ...[
              const SizedBox(height: gap),
              Row(
                children: [
                  Expanded(child: links[0]),
                  const SizedBox(width: gap),
                  Expanded(child: links[1]),
                ],
              ),
            ] else
              for (final link in links) ...[const SizedBox(height: gap), link],
          ],
        );
      },
    );
  }
}
