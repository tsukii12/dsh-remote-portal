import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'pressable.dart';

/// iOS-style search: a filled capsule, no outline. The glass and the clear
/// key each take a 44 slot, so the field keeps its size with or without text.
class SearchCapsule extends StatelessWidget {
  const SearchCapsule({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final FocusNode? focusNode;
  final bool autofocus;

  static const slot = 44.0;

  /// What the text field leaves between the glass's slot and the text.
  static const textGap = 4.0;

  /// The capsule's height at the current text size.
  static double heightOf(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium!;
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize!) * (style.height ?? 1.4);
    return math.max(slot, line + 22);
  }

  /// The capsule's fill.
  static Color fillOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.07)
        : theme.colorScheme.onSurface.withValues(alpha: 0.05);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final style = theme.textTheme.bodyMedium!;
    // Taller only when a large system text size needs it.
    final height = heightOf(context);
    const capsule = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(999)),
      borderSide: BorderSide.none,
    );
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: style,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: fillOf(context),
          hintText: hint,
          hintStyle: style.copyWith(color: dsh.textTertiary),
          contentPadding: EdgeInsets.zero,
          prefixIcon: Icon(AppIcons.search, size: 20, color: dsh.textTertiary),
          prefixIconConstraints: BoxConstraints.tightFor(width: slot, height: height),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? SizedBox(width: slot, height: height)
                : Semantics(
                    button: true,
                    label: l10n.commonClear,
                    onTap: onClear,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onClear,
                      child: SizedBox(
                        width: slot,
                        height: height,
                        child: Icon(AppIcons.clear, size: 18, color: dsh.textTertiary),
                      ),
                    ),
                  ),
          ),
          suffixIconConstraints: BoxConstraints.tightFor(width: slot, height: height),
          border: capsule,
          enabledBorder: capsule,
          focusedBorder: capsule,
        ),
      ),
    );
  }
}

/// A [SearchCapsule] that opens search elsewhere (the settings hub): the same
/// capsule, glass and hint in the same places, with no field of its own.
class SearchCapsuleButton extends StatelessWidget {
  const SearchCapsuleButton({super.key, required this.hint, required this.onTap});

  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final style = theme.textTheme.bodyMedium!;
    final height = SearchCapsule.heightOf(context);
    return Pressable(
      onTap: onTap,
      semanticLabel: hint,
      child: ExcludeSemantics(
        child: Container(
          height: height,
          decoration: ShapeDecoration(color: SearchCapsule.fillOf(context), shape: const StadiumBorder()),
          child: Row(
            children: [
              SizedBox(
                width: SearchCapsule.slot,
                height: height,
                child: Icon(AppIcons.search, size: 20, color: dsh.textTertiary),
              ),
              // The field's own gap between its glass and the text.
              const SizedBox(width: SearchCapsule.textGap),
              Expanded(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.copyWith(color: dsh.textTertiary),
                ),
              ),
              const SizedBox(width: SearchCapsule.slot),
            ],
          ),
        ),
      ),
    );
  }
}
