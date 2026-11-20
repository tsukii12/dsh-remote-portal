// The reason field of 撤回 and 举报: a few wrapping lines, a counter in the
// unit the workshop counts in, and the problem in words under it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'workshop_mine_text.dart';

/// A reason is one paragraph: the workshop refuses line breaks and other
/// control characters, so Enter finishes the field and a pasted break turns
/// into a space. The counter counts code points, like the limit does.
class WorkshopReasonField extends StatelessWidget {
  const WorkshopReasonField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.error,
    this.enabled = true,
    this.autofocus = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;

  /// The problem with what is typed, in words.
  final String? error;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  static final _control = RegExp(r'[\u0000-\u001f]');

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final count = value.text.runes.length;
        return TextField(
          controller: controller,
          enabled: enabled,
          autofocus: autofocus,
          minLines: 3,
          maxLines: 6,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [FilteringTextInputFormatter.deny(_control, replacementString: ' ')],
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            hintMaxLines: 2,
            alignLabelWithHint: true,
            errorText: error,
            errorMaxLines: 3,
            counterText: '$count/$workshopReasonLimit',
            counterStyle: count > workshopReasonLimit
                ? AppType.tabular(Theme.of(context).textTheme.bodySmall!.copyWith(color: colors.danger))
                : null,
          ),
        );
      },
    );
  }
}
