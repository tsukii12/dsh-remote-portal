// The phone-friendly key row above the keyboard on the terminal page (Esc, Tab,
// sticky Ctrl / Alt, arrows, | ~ / -) and the byte mapping for sticky
// modifiers.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalKey;

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'terminal_palette.dart';

/// Applies Ctrl / Alt to one typed character the way xterm encodes them:
/// Ctrl folds letters and `@[\]^_` (plus the usual aliases) into C0 controls,
/// Alt prefixes ESC. Text of more than one character passes through.
String withModifiers(String text, {bool ctrl = false, bool alt = false}) {
  if (text.isEmpty || text.runes.length != 1) return text;
  var out = text;
  if (ctrl) {
    final c = text.codeUnitAt(0);
    final code = switch (c) {
      >= 0x61 && <= 0x7a => c - 0x60, // a-z
      >= 0x41 && <= 0x5a => c - 0x40, // A-Z
      _ => switch (text) {
        '@' || ' ' || '2' => 0x00,
        '[' || '3' => 0x1b,
        r'\' || '4' => 0x1c,
        ']' || '5' => 0x1d,
        '^' || '~' || '6' => 0x1e,
        '_' || '-' || '/' || '7' => 0x1f,
        '?' || '8' => 0x7f,
        _ => null,
      },
    };
    if (code != null) out = String.fromCharCode(code);
  }
  return alt ? '\x1b$out' : out;
}

enum ModifierMode { off, armed, locked }

/// Sticky Ctrl / Alt: a tap arms one for the next key, a long press locks it
/// until tapped again.
class TerminalModifiers extends ChangeNotifier {
  ModifierMode _ctrl = ModifierMode.off;
  ModifierMode _alt = ModifierMode.off;

  ModifierMode get ctrl => _ctrl;
  ModifierMode get alt => _alt;
  bool get any => _ctrl != ModifierMode.off || _alt != ModifierMode.off;

  void tap(TerminalExtraKey key) {
    switch (key) {
      case TerminalExtraKey.ctrl:
        _ctrl = _ctrl == ModifierMode.off ? ModifierMode.armed : ModifierMode.off;
      case TerminalExtraKey.alt:
        _alt = _alt == ModifierMode.off ? ModifierMode.armed : ModifierMode.off;
      default:
        return;
    }
    notifyListeners();
  }

  void lock(TerminalExtraKey key) {
    switch (key) {
      case TerminalExtraKey.ctrl:
        _ctrl = ModifierMode.locked;
      case TerminalExtraKey.alt:
        _alt = ModifierMode.locked;
      default:
        return;
    }
    notifyListeners();
  }

  /// The modifiers for the key being sent; armed ones are used up.
  ({bool ctrl, bool alt}) consume() {
    final result = (ctrl: _ctrl != ModifierMode.off, alt: _alt != ModifierMode.off);
    var changed = false;
    if (_ctrl == ModifierMode.armed) {
      _ctrl = ModifierMode.off;
      changed = true;
    }
    if (_alt == ModifierMode.armed) {
      _alt = ModifierMode.off;
      changed = true;
    }
    if (changed) notifyListeners();
    return result;
  }

  void clear() {
    if (!any) return;
    _ctrl = ModifierMode.off;
    _alt = ModifierMode.off;
    notifyListeners();
  }
}

enum TerminalExtraKey {
  esc('Esc'),
  tab('Tab'),
  ctrl('Ctrl'),
  alt('Alt'),
  left('←'),
  up('↑'),
  down('↓'),
  right('→'),
  pipe('|'),
  tilde('~'),
  slash('/'),
  dash('-');

  const TerminalExtraKey(this.label);
  final String label;
  String get semantics => switch (this) {
    esc => appL10n.botsKeyEsc,
    tab => appL10n.botsKeyTab,
    left => appL10n.botsKeyLeft,
    up => appL10n.botsKeyUp,
    down => appL10n.botsKeyDown,
    right => appL10n.botsKeyRight,
    pipe => appL10n.botsKeyPipe,
    tilde => appL10n.botsKeyTilde,
    slash => appL10n.botsKeySlash,
    dash => appL10n.botsKeyDash,
    ctrl || alt => label,
  };

  bool get isModifier => this == ctrl || this == alt;

  /// Arrows repeat while held.
  bool get repeats => this == left || this == up || this == down || this == right;

  IconData? get icon => switch (this) {
    left => AppIcons.keyLeft,
    up => AppIcons.keyUp,
    down => AppIcons.keyDown,
    right => AppIcons.keyRight,
    _ => null,
  };

  /// Sends this key to [terminal] with the given modifiers (arrows honour the
  /// application cursor mode through xterm's encoder).
  void send(Terminal terminal, {bool ctrl = false, bool alt = false}) {
    switch (this) {
      case esc:
        terminal.keyInput(TerminalKey.escape, ctrl: ctrl, alt: alt);
      case tab:
        terminal.keyInput(TerminalKey.tab, ctrl: ctrl, alt: alt);
      case left:
        terminal.keyInput(TerminalKey.arrowLeft, ctrl: ctrl, alt: alt);
      case up:
        terminal.keyInput(TerminalKey.arrowUp, ctrl: ctrl, alt: alt);
      case down:
        terminal.keyInput(TerminalKey.arrowDown, ctrl: ctrl, alt: alt);
      case right:
        terminal.keyInput(TerminalKey.arrowRight, ctrl: ctrl, alt: alt);
      case pipe || tilde || slash || dash:
        terminal.textInput(withModifiers(label, ctrl: ctrl, alt: alt));
      case TerminalExtraKey.ctrl || TerminalExtraKey.alt:
        break;
    }
  }
}

/// The bottom slot of the terminal card: same height for the key row and
/// the status row, so swapping them never moves the screen.
abstract final class TerminalBar {
  /// Also each key's touch height (≥ 44).
  static const height = 52.0;

  /// The status row's button; (52 − 36) / 2 = 8 above and below, and 8 from
  /// the card's right edge.
  static const keyHeight = 36.0;

  /// The pill behind a key's label (pressed, armed or locked).
  static const pillHeight = 32.0;

  /// Room either side of a label inside its pill, when the cell has it.
  static const pillPadding = 6.0;

  /// The least room either side of a label inside its pill.
  static const labelMargin = 3.0;

  /// Space kept between neighbouring pills (half on each side of a cell).
  static const pillGap = 2.0;

  /// Equal left and right inset of the key row.
  static const inset = 4.0;

  /// The widest a key's cell gets (12 of them: 768, centred on a wide card).
  static const maxCell = 64.0;
}

/// Twelve equal-width cells across the card, each label centred in its cell.
/// When the widest label (plus its pill) doesn't fit a twelfth of the row —
/// narrow phones, large text — the cells keep that width and the row
/// scrolls sideways instead of shrinking some keys.
///
/// Keys fire on release (a drag scrolls the row instead); arrows repeat
/// while held; Ctrl / Alt toggle on tap and lock on long press.
class ExtraKeysRow extends StatelessWidget {
  const ExtraKeysRow({super.key, required this.modifiers, required this.onKey});

  final TerminalModifiers modifiers;
  final ValueChanged<TerminalExtraKey> onKey;

  /// Width of [key]'s label as drawn.
  static double labelWidth(BuildContext context, TerminalExtraKey key) {
    if (key.icon != null) return _Key.iconSize;
    final painter = TextPainter(
      text: TextSpan(text: key.label, style: _Key.labelStyle(context, key, TerminalPalette.of(context).foreground)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Narrowest cell that holds every label with [TerminalBar.labelMargin]
  /// either side inside its pill, and [TerminalBar.pillGap] between pills;
  /// narrower than this, the row scrolls.
  static double minCellWidth(BuildContext context) {
    var widest = 0.0;
    for (final key in TerminalExtraKey.values) {
      final width = labelWidth(context, key);
      if (width > widest) widest = width;
    }
    return widest + 2 * TerminalBar.labelMargin + TerminalBar.pillGap;
  }

  @override
  Widget build(BuildContext context) {
    final minCell = minCellWidth(context);
    return SizedBox(
      height: TerminalBar.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const count = 12;
          final available = constraints.maxWidth - 2 * TerminalBar.inset;
          final fits = available / count >= minCell;
          // Wide cards (a tablet, a phone on its side) keep the keys a
          // thumb apart, the row centred, instead of strewn edge to edge.
          final cell = fits ? math.min(available / count, TerminalBar.maxCell) : minCell;
          final row = ListenableBuilder(
            listenable: modifiers,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final key in TerminalExtraKey.values)
                  SizedBox(
                    width: cell,
                    height: TerminalBar.height,
                    child: _Key(
                      key: ValueKey('terminal-key-${key.name}'),
                      extraKey: key,
                      pillWidth: (labelWidth(context, key) + 2 * TerminalBar.pillPadding).clamp(
                        TerminalBar.pillHeight < cell - TerminalBar.pillGap
                            ? TerminalBar.pillHeight
                            : cell - TerminalBar.pillGap,
                        cell - TerminalBar.pillGap,
                      ),
                      mode: switch (key) {
                        TerminalExtraKey.ctrl => modifiers.ctrl,
                        TerminalExtraKey.alt => modifiers.alt,
                        _ => ModifierMode.off,
                      },
                      onKey: (k) => k.isModifier ? modifiers.tap(k) : onKey(k),
                      onLock: key.isModifier ? () => modifiers.lock(key) : null,
                    ),
                  ),
              ],
            ),
          );
          if (fits) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: TerminalBar.inset),
              child: Center(child: row),
            );
          }
          return SingleChildScrollView(
            key: const ValueKey('terminal-keys-scroll'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: TerminalBar.inset),
            child: row,
          );
        },
      ),
    );
  }
}

class _Key extends StatefulWidget {
  const _Key({
    super.key,
    required this.extraKey,
    required this.pillWidth,
    required this.mode,
    required this.onKey,
    this.onLock,
  });

  final TerminalExtraKey extraKey;

  /// The label plus [TerminalBar.pillPadding] either side, kept inside the
  /// cell (a circle for one glyph).
  final double pillWidth;
  final ModifierMode mode;
  final ValueChanged<TerminalExtraKey> onKey;
  final VoidCallback? onLock;

  static const iconSize = 20.0;

  /// Single symbols in the mono face, words in the UI face.
  static TextStyle labelStyle(BuildContext context, TerminalExtraKey key, Color color) => key.label.length == 1
      ? AppType.mono(size: 15, color: color, weight: FontWeight.w500, height: 1.2)
      : (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
          fontSize: 12,
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: color,
        );

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> with WidgetsBindingObserver {
  static const _repeatDelay = Duration(milliseconds: 420);
  static const _repeatEvery = Duration(milliseconds: 60);
  static const _lockAfter = Duration(milliseconds: 450);

  bool _down = false;

  /// The hold already acted (locked a modifier, or repeated an arrow).
  bool _held = false;
  int? _pointer;
  Offset? _origin;
  Timer? _timer;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  bool _ownsPress(int pointer) => mounted && _down && _pointer == pointer && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A held gesture ends here. Resuming must not restart it or turn a late
    // pointer-up into a tap; only a fresh pointer-down can begin another hold.
    if (state != AppLifecycleState.resumed) _cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  void _press(PointerDownEvent event) {
    if (!_foreground || _pointer != null) return;
    final pointer = _pointer = event.pointer;
    _origin = event.position;
    _held = false;
    setState(() => _down = true);
    final key = widget.extraKey;
    if (key.isModifier) {
      _timer = Timer(_lockAfter, () {
        if (!_ownsPress(pointer)) return;
        _held = true;
        unawaited(HapticFeedback.selectionClick());
        widget.onLock?.call();
      });
    } else if (key.repeats) {
      _timer = Timer(_repeatDelay, () {
        if (!_ownsPress(pointer)) return;
        _held = true;
        widget.onKey(key);
        if (!_ownsPress(pointer)) return;
        _timer = Timer.periodic(_repeatEvery, (timer) {
          if (!_ownsPress(pointer)) {
            timer.cancel();
            return;
          }
          widget.onKey(key);
        });
      });
    }
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final origin = _origin;
    // Past the touch slop it's a scroll of the row, not a key press.
    if (origin != null && (event.position - origin).distance > kTouchSlop) _cancel();
  }

  void _release(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final fire = _ownsPress(event.pointer) && !_held;
    _cancel();
    if (!fire) return;
    unawaited(HapticFeedback.selectionClick());
    widget.onKey(widget.extraKey);
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _origin = null;
    if (_down && mounted) setState(() => _down = false);
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.extraKey;
    final active = widget.mode != ModifierMode.off;
    final palette = TerminalPalette.of(context);
    final fg = active ? palette.background : palette.foreground;
    final Color fill;
    if (active) {
      fill = palette.foreground.withValues(alpha: _down ? 0.8 : 0.92);
    } else {
      fill = Colors.white.withValues(alpha: _down ? 0.1 : 0);
    }
    final Widget label = key.icon != null
        ? Icon(key.icon, size: _Key.iconSize, color: fg)
        : Text(key.label, maxLines: 1, softWrap: false, style: _Key.labelStyle(context, key, fg));
    return Semantics(
      button: true,
      toggled: key.isModifier ? active : null,
      label: key.semantics,
      excludeSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _press,
        onPointerMove: _move,
        onPointerUp: _release,
        onPointerCancel: (event) {
          if (event.pointer == _pointer) _cancel();
        },
        child: Center(
          // The pill hugs the label (a circle for one glyph), centred in the
          // cell; it only shows while pressed, armed or locked.
          child: AnimatedContainer(
            key: const ValueKey('terminal-key-pill'),
            duration: AppMotion.of(context, AppMotion.press),
            width: widget.pillWidth,
            height: TerminalBar.pillHeight,
            decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
            child: Stack(
              alignment: Alignment.center,
              children: [
                KeyedSubtree(key: const ValueKey('terminal-key-label'), child: label),
                // A locked modifier keeps a short bar under its label.
                if (widget.mode == ModifierMode.locked)
                  Positioned(
                    bottom: 3,
                    child: Container(
                      width: 10,
                      height: 2,
                      decoration: ShapeDecoration(color: fg, shape: const StadiumBorder()),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [ExtraKeysRow]'s stand-in when the shell can't take input: a short status
/// on the left and at most one action, concentric with the card corner.
class TerminalStatusBar extends StatelessWidget {
  const TerminalStatusBar({super.key, required this.label, this.busy = false, this.actionLabel, this.onAction});

  final String label;
  final bool busy;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TerminalPalette.of(context);
    return SizedBox(
      height: TerminalBar.height,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: (TerminalBar.height - TerminalBar.keyHeight) / 2),
        child: Row(
          children: [
            if (busy) ...[
              SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: palette.muted)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: palette.muted),
              ),
            ),
            if (actionLabel case final action?)
              SizedBox(
                height: TerminalBar.keyHeight,
                child: TextButton(
                  key: const ValueKey('terminal-status-action'),
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: palette.foreground,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, TerminalBar.keyHeight),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  child: Text(action),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
