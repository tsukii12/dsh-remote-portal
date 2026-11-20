// The glyph that marks a drawer folder: the plain
// folder, a folder in one of the identity hues, or an emoji.

import 'package:flutter/material.dart';

import '../../../state/drawer_view_state.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Emoji a folder can wear (the editor's second row).
const folderEmoji = ['📁', '💼', '🧪', '📚', '🛠️', '💡', '🎯', '⭐', '🎨'];

/// Colour-emoji family named as a fallback, so an emoji mark renders the same
/// in tests (where the font is loaded under this name) and on phones (where
/// the system's emoji font stands in when it is missing).
const emojiFontFallback = ['Noto Color Emoji'];

/// A folder's mark in a [size] slot (20 in the drawer rows).
class FolderMarkGlyph extends StatelessWidget {
  const FolderMarkGlyph({super.key, this.tint, this.emoji, this.size = 20});

  FolderMarkGlyph.of(DrawerFolder folder, {super.key, this.size = 20}) : tint = folder.tint, emoji = folder.emoji;

  final int? tint;
  final String? emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final Widget glyph;
    if (emoji case final e?) {
      glyph = Text(
        e,
        textScaler: TextScaler.noScaling,
        style: TextStyle(fontSize: size * 0.82, height: 1, fontFamilyFallback: emojiFontFallback),
      );
    } else if (tint case final t?) {
      glyph = Icon(AppIcons.folderMark, size: size, color: colors.onIdentity[t % colors.onIdentity.length]);
    } else {
      glyph = Icon(AppIcons.folder, size: size, color: Theme.of(context).colorScheme.onSurfaceVariant);
    }
    return SizedBox.square(
      dimension: size,
      child: Center(child: glyph),
    );
  }
}
