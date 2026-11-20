// The 32dp file-type glyph of the 文件 page's rows, in the artifact cards' visual
// language (a faint squircle tile, the kind's colour): folders, a document-kind
// icon, a photo's own thumbnail on this phone, or the extension as a monogram
// for code and text.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/artifacts.dart';
import '../chat/widgets/artifact_card.dart' show ArtifactThumb, artifactColor, artifactIcon;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The extension as a short monogram (`PY`, `JSON`); null without one.
String? fileMonogram(String name) {
  final lower = name.toLowerCase();
  if (lower == 'dockerfile') return 'DK';
  if (lower == 'makefile') return 'MK';
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toUpperCase();
  return ext.length > 4 ? ext.substring(0, 4) : ext;
}

/// One row's glyph: a folder, a file kind, or a thumbnail.
class FileGlyph extends ConsumerWidget {
  const FileGlyph({
    super.key,
    required this.name,
    this.directory = false,
    this.sessionId,
    this.thumbnailPath,
    this.size = 32,
  });

  final String name;
  final bool directory;

  /// With [thumbnailPath] (an absolute path on a local engine): images show
  /// their own picture.
  final String? sessionId;
  final String? thumbnailPath;
  final double size;

  static const radius = 9.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = artifactKindOf(name);
    if (!directory && kind == ArtifactKind.image && sessionId != null && thumbnailPath != null) {
      return ArtifactThumb(
        sessionId: sessionId!,
        artifact: Artifact(path: thumbnailPath!, origin: ArtifactOrigin.linked, turn: 0),
        size: size,
      );
    }
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final border = BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6), width: 0.5);
    Widget inner;
    if (directory) {
      inner = Icon(AppIcons.folderMark, size: size * 0.58, color: folderColor(context));
    } else if (_kinded(kind)) {
      inner = Icon(artifactIcon(kind), size: size * 0.56, color: artifactColor(context, kind));
    } else if (fileMonogram(name) case final mono?) {
      inner = Text(
        mono,
        maxLines: 1,
        overflow: TextOverflow.clip,
        textScaler: TextScaler.noScaling,
        style: AppType.mono(
          size: mono.length > 3 ? size * 0.25 : size * 0.3,
          height: 1,
          color: theme.colorScheme.onSurfaceVariant,
        ).copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      );
    } else {
      inner = Icon(AppIcons.document, size: size * 0.56, color: dsh.textTertiary);
    }
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: Colors.white.withValues(alpha: dark ? 0.05 : 0.5),
            shape: Squircle.border(radius, side: border),
          ),
          child: Center(child: inner),
        ),
      ),
    );
  }

  /// Kinds with their own icon (documents, media, archives); code, text and
  /// Markdown read better as their extension.
  static bool _kinded(ArtifactKind kind) => switch (kind) {
    ArtifactKind.markdown || ArtifactKind.text || ArtifactKind.other => false,
    _ => true,
  };

  /// A quiet amber, like the official tree's folders.
  static Color folderColor(BuildContext context) {
    final dsh = DshColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? Color.lerp(dsh.warning, const Color(0xFFF2C46A), 0.4)!
        : Color.lerp(dsh.warning, const Color(0xFFF2B544), 0.55)!;
  }
}
