// Colours of the terminal page's dark card, shared by the emulator, the key row
// and the status row. Dark in both app themes, like the engine page's log card;
// tinted by the current palette.

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../theme/theme.dart';

/// The dark terminal card's colours under one palette ([AppAccent]): the
/// palette's dark neutrals one step below the dark code well, and its
/// accent as a soft tone that reads on them. Mist gives the original values.
@immutable
class TerminalPalette {
  TerminalPalette._(AppAccent accent) : this._from(accent, NeutralTones.forAccent(accent));

  TerminalPalette._from(AppAccent accent, NeutralTones n)
    : background = n.terminal,
      key = n.terminalKey,
      foreground = n.paper,
      muted = n.paperFaint,
      accent = _softAccent(accent),
      _ansi = DshColors.dark.ansi;

  /// The palette of the theme around [context].
  static TerminalPalette of(BuildContext context) => forAccent(DshSurfaces.of(context).accent);

  static TerminalPalette forAccent(AppAccent accent) {
    final hit = _cache[accent];
    if (hit != null) return hit;
    if (_cache.length > 8) _cache.clear();
    return _cache[accent] = TerminalPalette._(accent);
  }

  static final _cache = <AppAccent, TerminalPalette>{};

  /// The card: one step deeper than the dark code well.
  final Color background;

  /// Floating pills on the card (selection bar, IME composing).
  final Color key;

  /// Default text.
  final Color foreground;

  /// Status copy and quiet glyphs.
  final Color muted;

  /// `[dsh-app]` log lines, cursor and selection: a soft tone of the accent.
  final Color accent;

  final List<Color> _ansi;

  /// Hairlines on the card (edge, divider above the key row).
  Color get hairline => Colors.white.withValues(alpha: 0.06);

  /// The emulator theme: the app's ANSI palette for code wells (each colour
  /// ≥ 4.5:1 on a background this dark), transparent background so the card
  /// shows through.
  late final TerminalTheme theme = _theme(cursor: accent);

  /// [theme] without a cursor: the shell can't take input (ended, read-only,
  /// connecting).
  late final TerminalTheme quiet = _theme(cursor: const Color(0x00000000));

  /// Mist's terminal accent (OKLCH 0.78 / 0.11 / 271). Other palettes move it
  /// to their dark primary's hue and chroma at the same lightness (≥ 7:1 on
  /// the card).
  static const _mistSoft = Color(0xFF9DB4FF);

  static Color _softAccent(AppAccent accent) {
    if (accent == AppAccent.mist) return _mistSoft;
    final base = Oklch.fromColor(AppAccent.mist.seedDark);
    final own = Oklch.fromColor(accent.seedDark);
    return retint(_mistSoft, hueShift: own.h - base.h, chromaScale: own.c / base.c);
  }

  TerminalTheme _theme({required Color cursor}) {
    final ansi = _ansi;
    return TerminalTheme(
      cursor: cursor,
      selection: accent.withValues(alpha: 0.32),
      foreground: foreground,
      background: background,
      black: ansi[0],
      red: ansi[1],
      green: ansi[2],
      yellow: ansi[3],
      blue: ansi[4],
      magenta: ansi[5],
      cyan: ansi[6],
      white: ansi[7],
      brightBlack: ansi[8],
      brightRed: ansi[9],
      brightGreen: ansi[10],
      brightYellow: ansi[11],
      brightBlue: ansi[12],
      brightMagenta: ansi[13],
      brightCyan: ansi[14],
      brightWhite: ansi[15],
      searchHitBackground: DshColors.dark.warning,
      searchHitBackgroundCurrent: DshColors.dark.success,
      searchHitForeground: background,
    );
  }
}
