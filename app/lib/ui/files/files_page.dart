// 文件: one conversation's workspace as a list page — the official file panel
// (`dsh-client-ui-sidebar-files`) and its document preview, native.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/workspace_state.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'workspace_browser.dart';

/// [path] with the Host's home as `~`.
String homePath(String path, String? home) {
  if (home == null || home.isEmpty || home == '/') return path;
  if (path == home) return '~';
  if (path.startsWith('$home/')) return '~${path.substring(home.length)}';
  return path;
}

/// 文件 (list page): large title with the workspace folder as subtitle, then the
/// search field, path capsules and the current folder. Pull to refresh; updates
/// itself while the agent writes files; back goes up a folder first.
class WorkspaceFilesPage extends ConsumerWidget {
  const WorkspaceFilesPage({super.key, required this.sessionId, this.initialPath = '', this.now});

  final String sessionId;

  /// Folder to open, relative to the workspace root.
  final String initialPath;

  /// Clock for the time labels (tests).
  final DateTime Function()? now;

  static Route<void> route(String sessionId, {String initialPath = ''}) => MaterialPageRoute<void>(
    builder: (_) => WorkspaceFilesPage(sessionId: sessionId, initialPath: initialPath),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final root = ref.watch(workspaceRootProvider(sessionId));
    final home = ref.watch(activeConnectionProvider.select((c) => c.value?.client.mux.generation?.home));
    final theme = Theme.of(context);
    return WorkspaceBrowser(
      sessionId: sessionId,
      initialPath: initialPath,
      handleBack: true,
      now: now,
      builder: (context, slivers, refresh) => RefreshIndicator(
        onRefresh: refresh,
        edgeOffset: MediaQuery.paddingOf(context).top + 56,
        child: AppPage(
          title: l10n.botsFiles,
          subtitle: root == null
              ? null
              : TailPath(
                  homePath(root, home),
                  style: AppType.mono(size: 12.5, height: 1.4, color: theme.colorScheme.onSurfaceVariant),
                ),
          slivers: [
            ...slivers,
            // Short folders still pull to refresh.
            const WorkspaceFillRest(),
          ],
        ),
      ),
    );
  }
}

/// A path on one line that keeps its end: leading folders give way to `…/`.
class TailPath extends StatelessWidget {
  const TailPath(this.path, {super.key, this.style});

  final String path;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final text = fitTail(path, constraints.maxWidth, style, MediaQuery.textScalerOf(context));
        return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style, semanticsLabel: path);
      },
    );
  }
}

/// [path] shortened from the front, whole folders at a time, to fit
/// [width].
String fitTail(String path, double width, TextStyle style, TextScaler scaler) {
  if (!width.isFinite) return path;
  final painter = TextPainter(textDirection: TextDirection.ltr, maxLines: 1, textScaler: scaler);
  bool fits(String text) {
    painter.text = TextSpan(text: text, style: style);
    painter.layout();
    return painter.width <= width;
  }

  try {
    if (fits(path)) return path;
    final parts = path.split('/');
    for (var drop = 1; drop < parts.length; drop++) {
      final rest = parts.sublist(math.min(drop, parts.length - 1)).join('/');
      final candidate = '…/$rest';
      if (fits(candidate)) return candidate;
    }
    return '…/${parts.last}';
  } finally {
    painter.dispose();
  }
}
