// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/animation.dart';

import 'liquid_engine.dart';
import 'liquid_transition.dart';

/// The author's plus-menu choreography (sites/gooey `PlusMenu` defaults): a 40 px
/// round ＋ that splits into satellites, all stacked on one slot when closed.
///
/// Satellite icons hold back while merged and fade in (from 2 px blur) once
/// pulled clear; the ＋ turns 45°. Closing dips the whole group [anticipation]
/// px towards the returning satellites and back ([anticipationAt]).
abstract final class LiquidMenu {
  static const button = 40.0;

  /// Satellite offsets from the ＋ (× spread 1).
  static const satellites = [Offset(-54, -34), Offset(0, -64), Offset(54, -34)];

  static const open = LiquidTimed(Duration(milliseconds: 550), Cubic(0.34, 1.56, 0.64, 1));
  static const openStagger = Duration(milliseconds: 40);
  static const close = LiquidTimed(Duration(milliseconds: 250), Cubic(0.22, 1, 0.36, 1));
  static const closeStagger = Duration.zero;

  /// Satellite icon fade in (after [iconDelay] + its stagger) and out.
  static const iconIn = Duration(milliseconds: 180);
  static const iconOut = Duration(milliseconds: 120);
  static const iconDelay = Duration(milliseconds: 120);
  static const iconBlur = 2.0;

  /// The ＋ turning to ×, ease-in-out.
  static const plusTurn = Duration(milliseconds: 250);

  static const anticipation = 5.0;
  static const anticipationDuration = Duration(milliseconds: 700);

  /// The close dip at [t] (0..1 of [anticipationDuration]): down to
  /// [anticipation] by 30 %, back by 100 %, each leg eased (CSS keyframes).
  static double anticipationAt(double t) {
    const ease = Cubic(0.22, 1, 0.36, 1);
    if (t <= 0 || t >= 1) return 0;
    return t < 0.3 ? anticipation * ease.transform(t / 0.3) : anticipation * (1 - ease.transform((t - 0.3) / 0.7));
  }
}

/// The author's liquid tabs (sites/gooey `Tabs`): a 30 px pill slid by your
/// own animation, the liquid trailing it. The demo uses the default
/// [MoveTuning]; at this blur its droplet can show as a separate bead for a
/// couple of frames at full speed. [move] is the reference doc's tab recipe:
/// more stretch, a smaller droplet.
abstract final class LiquidTabs {
  static const move = MoveTuning(stretch: 0.6, trail: 0.35);

  /// Goo blur for a 30 px pill: a larger σ rounds its caps flat.
  static const blur = 3.5;
  static const slide = Duration(milliseconds: 250);
  static const slideCurve = Cubic(0.3, 1.05, 0.4, 1);
  static const height = 30.0;

  /// Around the tabs, and between them.
  static const padding = 3.0;
  static const gap = 3.0;
}
