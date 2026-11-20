// 按住确认: the main key of 解除限制's confirmation page. A tap does nothing;
// holding it for [HoldToConfirmButton.hold] fills it from the left and then
// confirms. Letting go early drains it back.
//
// ```
// ╭──────────────────────────────────────────╮
// │████████████  我了解风险，开启              │  52, stadium, danger
// ╰──────────────────────────────────────────╯
// ```
//
// Raw pointers, not a gesture recogniser: there is no tap or long-press
// semantics action to fire it with, so neither an accessibility action (the
// phone agent's own service included) nor a stray tap can confirm. A screen
// reader's double-tap-and-hold is a real hold and works.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.hint,
    required this.onConfirmed,
    this.enabled = true,
  });

  final String label;

  /// Read with the label: how to use it (「按住按钮约 1.5 秒」).
  final String hint;
  final VoidCallback onConfirmed;
  final bool enabled;

  /// How long to hold. Not shortened when animations are off: it is the
  /// friction, not a decoration.
  static const hold = Duration(milliseconds: 1500);
  static const height = 52.0;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  // preserve: with the system's 移除动画 on, a normal controller runs at 5% (a 75 ms "hold").
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: HoldToConfirmButton.hold,
    animationBehavior: AnimationBehavior.preserve,
  )..addStatusListener(_onStatus);

  /// The finger holding it; others are ignored.
  int? _pointer;
  bool _done = false;

  @override
  void didUpdateWidget(HoldToConfirmButton old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) {
      _release();
    } else if (!old.enabled && _done) {
      // Confirmed, and what that started gave the key back (it failed): hold again.
      _done = false;
      _fill.value = 0;
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _done || _pointer == null) return;
    _done = true;
    unawaited(HapticFeedback.heavyImpact());
    widget.onConfirmed();
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null || _done) return;
    _pointer = e.pointer;
    unawaited(HapticFeedback.selectionClick());
    unawaited(_fill.forward());
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _release();
  }

  void _release() {
    _pointer = null;
    if (_done) return;
    // Drains back quicker than it filled.
    unawaited(_fill.animateBack(0, duration: AppMotion.of(context, AppMotion.standard)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final enabled = widget.enabled;
    final style = theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.2);
    Widget face(Color fill, Color ink) => DecoratedBox(
      decoration: BoxDecoration(color: fill),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: style?.copyWith(color: ink),
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: widget.label,
      hint: widget.hint,
      child: ExcludeSemantics(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.45,
            duration: AppMotion.of(context, AppMotion.quick),
            child: SizedBox(
              key: const ValueKey('hold-to-confirm'),
              height: HoldToConfirmButton.height,
              width: double.infinity,
              child: ClipPath(
                clipper: const ShapeBorderClipper(shape: StadiumBorder()),
                child: AnimatedBuilder(
                  animation: _fill,
                  builder: (context, _) => Stack(
                    fit: StackFit.expand,
                    children: [
                      face(colors.danger.withValues(alpha: 0.12), colors.danger),
                      // The filled face, revealed from the left as the hold goes on;
                      // its label sits exactly over the one below.
                      ClipRect(
                        clipper: _LeftPart(_fill.value),
                        child: face(colors.danger, colors.onDanger),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The left [fraction] of the box.
class _LeftPart extends CustomClipper<Rect> {
  const _LeftPart(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftPart old) => old.fraction != fraction;
}
