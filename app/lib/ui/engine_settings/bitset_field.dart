import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'field_sheets.dart';

String bitsetSummary(Map<String, int> bits, int value) {
  final selected = [
    for (final entry in bits.entries)
      if ((value & entry.value) != 0) entry.key,
  ];
  return selected.isEmpty ? appL10n.engineFieldNone : selected.join(' · ');
}

Future<void> showBitsetFieldSheet(
  BuildContext context, {
  required String title,
  required Map<String, int> bits,
  required int current,
  required bool modified,
  required Future<bool> Function(int) onSubmit,
  required Future<bool> Function() onReset,
}) => showFieldSheet<void>(
  context,
  (_) => BitsetFieldSheet(
    title: title,
    bits: bits,
    current: current,
    modified: modified,
    onSubmit: onSubmit,
    onReset: onReset,
  ),
);

/// Named flags from the actual schema. Unknown stored bits survive edits.
class BitsetFieldSheet extends StatefulWidget {
  const BitsetFieldSheet({
    super.key,
    required this.title,
    required this.bits,
    required this.current,
    required this.modified,
    required this.onSubmit,
    required this.onReset,
  });
  final String title;
  final Map<String, int> bits;
  final int current;
  final bool modified;
  final Future<bool> Function(int) onSubmit;
  final Future<bool> Function() onReset;

  @override
  State<BitsetFieldSheet> createState() => _BitsetFieldSheetState();
}

class _BitsetFieldSheetState extends State<BitsetFieldSheet> {
  late int _value = widget.current;
  bool _busy = false;
  bool _failed = false;

  Future<void> _save({bool reset = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    bool ok;
    try {
      ok = reset ? await widget.onReset() : await widget.onSubmit(_value);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
    });
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => FieldSheetFrame(
    title: widget.title,
    actions: EditorSheetActions(
      busy: _busy,
      onDone: () => unawaited(_save()),
      onRestore: widget.modified ? () => unawaited(_save(reset: true)) : null,
    ),
    children: [
      for (final entry in widget.bits.entries)
        CheckboxListTile(
          key: ValueKey('bit-${entry.key}'),
          title: Text(entry.key),
          value: (_value & entry.value) != 0,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          onChanged: _busy || entry.value == 0
              ? null
              : (checked) => setState(() {
                  _value = (checked == true ? _value | entry.value : _value & ~entry.value).toSigned(32);
                  _failed = false;
                }),
        ),
      SheetHelper(error: _failed ? context.l10n.commonSaveFailed : null),
    ],
  );
}
