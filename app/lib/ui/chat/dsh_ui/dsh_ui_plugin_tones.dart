// Opaque control colours for view-v2, derived from each node's own surface.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dsh_ui_model.dart';

int _rgb(Color c) => c.toARGB32() & 0xFFFFFF;
Color _opaque(int rgb) => Color(0xFF000000 | rgb);

int _mix(int from, int to, double amount) {
  int channel(int shift) => (((from >> shift) & 255) * (1 - amount) + ((to >> shift) & 255) * amount).round();
  return (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

double _luminance(int rgb) {
  double channel(int shift) {
    final c = ((rgb >> shift) & 255) / 255;
    return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}

/// Every colour a v2 control paints, computed from the node's actual opaque
/// surface, ink and accent (the styles interpreter has already corrected the
/// accent against that surface). Fills are opaque mixes, never alpha; each
/// text colour is re-checked at 4.5:1 against the fill it sits on, and each
/// state boundary (input outline, selected outline, rating star) at 3:1.
///
/// Selection and primary actions use a tonal accent fill with an accent
/// outline. Nothing here is a solid accent fill with inverse text: that is the
/// app's own approval and permission button, which plugin content never gets.
@immutable
class DshUiPluginTones {
  const DshUiPluginTones._({
    required this.surface,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.hairline,
    required this.line,
    required this.well,
    required this.wellInk,
    required this.wellMuted,
    required this.tint,
    required this.onTint,
    required this.accentLine,
    required this.inactive,
  });

  factory DshUiPluginTones.of(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final surface = _rgb(colors.surface);
    final ink = _rgb(colors.onSurface);
    final muted = _rgb(colors.onSurfaceVariant);
    final accent = _rgb(colors.primary);
    final dark = _luminance(surface) < 0.18;
    final well = _mix(surface, ink, dark ? 0.07 : 0.045);
    final tint = _mix(surface, accent, dark ? 0.22 : 0.12);
    return DshUiPluginTones._(
      surface: colors.surface,
      ink: colors.onSurface,
      muted: colors.onSurfaceVariant,
      accent: colors.primary,
      hairline: _opaque(_mix(surface, ink, dark ? 0.16 : 0.13)),
      line: _opaque(dshUiReadableColor(_mix(surface, ink, 0.42), surface, minimum: 3)),
      well: _opaque(well),
      wellInk: _opaque(dshUiReadableColor(ink, well)),
      wellMuted: _opaque(dshUiReadableColor(muted, well)),
      tint: _opaque(tint),
      onTint: _opaque(dshUiReadableColor(accent, tint)),
      accentLine: _opaque(dshUiReadableColor(dshUiReadableColor(accent, tint, minimum: 3), well, minimum: 3)),
      inactive: _opaque(_mix(surface, muted, 0.5)),
    );
  }

  /// The node's own background and text.
  final Color surface;
  final Color ink;
  final Color muted;

  /// Accent text and graphics on [surface] (≥ 4.5:1).
  final Color accent;

  /// Quiet edge of a button or option; its label identifies it.
  final Color hairline;

  /// Edge of an input (≥ 3:1 against [surface]).
  final Color line;

  /// A recessed neutral fill: segmented track, code header, neutral buttons.
  final Color well;
  final Color wellInk;
  final Color wellMuted;

  /// Tonal accent fill of a selected option or a primary action.
  final Color tint;

  /// Accent text on [tint] (≥ 4.5:1).
  final Color onTint;

  /// Selected / primary outline (≥ 3:1 against [tint] and [well]).
  final Color accentLine;

  /// Graphics of a control that cannot act right now.
  final Color inactive;
}
