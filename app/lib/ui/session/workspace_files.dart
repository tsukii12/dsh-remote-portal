// The 对话详情 「文件」 tab — the conversation's deliverables over the workspace
// browser (ui/files/, after the official file panel) — and the preview route
// for one workspace file.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/artifacts.dart';
import '../chat/artifact_preview.dart';
import '../files/workspace_browser.dart';
import 'session_artifacts.dart';
import 'workspace_upload.dart';

/// `1.2 KB` / `340 B` / `3.4 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// The workspace's files: delivered files atop the root, then the search
/// field, path capsules and the current folder. Pull to refresh; updates itself
/// while the agent writes files.
class WorkspaceFilesTab extends ConsumerStatefulWidget {
  const WorkspaceFilesTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<WorkspaceFilesTab> createState() => _WorkspaceFilesTabState();
}

class _WorkspaceFilesTabState extends ConsumerState<WorkspaceFilesTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return WorkspaceBrowser(
      sessionId: widget.sessionId,
      // Delivered and generated files (possibly outside the workspace): on top at the root.
      header: (rel) => [
        if (rel.isEmpty) SliverToBoxAdapter(child: SessionArtifactsSection(sessionId: widget.sessionId)),
        // Uploads land at the workspace root: offered there only.
        if (rel.isEmpty) SliverToBoxAdapter(child: WorkspaceUploadRow(sessionId: widget.sessionId)),
      ],
      builder: (context, slivers, refresh) => RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 4)),
            ...slivers,
            // Short folders still pull to refresh.
            const WorkspaceFillRest(),
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24)),
          ],
        ),
      ),
    );
  }
}

/// Previews one workspace file ([path] as the Host knows it: absolute, or
/// relative to the workspace).
class FilePreviewPage extends StatelessWidget {
  const FilePreviewPage({super.key, required this.sessionId, required this.path, this.bytes});

  final String sessionId;
  final String path;
  final int? bytes;

  static Route<void> route({required String sessionId, required String path, int? bytes}) => MaterialPageRoute<void>(
    builder: (_) => FilePreviewPage(sessionId: sessionId, path: path, bytes: bytes),
  );

  @override
  Widget build(BuildContext context) => ArtifactPreviewPage(
    sessionId: sessionId,
    artifact: Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0, bytes: bytes),
  );
}
