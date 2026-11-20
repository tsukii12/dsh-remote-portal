// The phone's take on the official file panel (`dsh-client-ui-sidebar-files`):
// one folder at a time under path capsules, a name search over the workspace,
// rows with a type glyph, size and time, long-press actions, and every open
// folder kept current by the Host's change feed. Shared by the 文件 page and the
// 对话详情 「文件」 tab.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/artifact_files.dart';
import '../../state/artifacts.dart';
import '../../state/workspace_state.dart';
import '../chat/artifact_preview.dart';
import '../chat/widgets/artifact_card.dart' show showArtifactMenu;
import '../chat/widgets/change_card.dart' show copyPath;
import '../common/app_sheet.dart';
import '../common/breadcrumb_row.dart';
import '../common/empty_view.dart';
import '../common/expand_reveal.dart';
import '../common/feature_tile.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../session/workspace_files.dart' show FilePreviewPage, formatBytes;
import '../settings/settings_widgets.dart' show SettingsTile;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'file_glyph.dart';

/// `14:20` today, `昨天 14:20`, `10月3日` this year, else `2025/1/3`.
String fileTimeLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(local.hour)}:${two(local.minute)}';
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (days <= 0) return hm;
  if (days == 1) return appL10n.botsYesterdayTime(hm);
  if (local.year == now.year) return appL10n.monthDay(local);
  return '${local.year}/${local.month}/${local.day}';
}

/// A short sentence for a folder or search that could not be read.
String workspaceErrorText(Object error) {
  final code = switch (error) {
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'workspace-file/not-found' => appL10n.botsFolderGone,
    'workspace-file/outside-workspace' => appL10n.botsOutsideWorkspace,
    'workspace-file/not-directory' => appL10n.botsNotFolder,
    'offline' => appL10n.commonEngineUnreachable,
    'gateway/lookup-not-found' => appL10n.botsChatNotFound,
    _ when code.startsWith('gateway/') || code == 'METHOD_NOT_ALLOWED' => appL10n.botsBrowseUnsupported,
    _ => appL10n.botsFolderReadFailed,
  };
}

/// Builds the scroll view around the browser's slivers; [refresh] relists
/// the folder on screen (pull to refresh).
typedef WorkspaceBrowserBuilder = Widget Function(
  BuildContext context,
  List<Widget> slivers,
  Future<void> Function() refresh,
);

/// Search field, path capsules and the current folder (folders first). Tap a
/// file to preview it; long-press for more actions.
class WorkspaceBrowser extends ConsumerStatefulWidget {
  const WorkspaceBrowser({
    super.key,
    required this.sessionId,
    required this.builder,
    this.initialPath = '',
    this.header,
    this.handleBack = false,
    this.now,
  });

  final String sessionId;
  final WorkspaceBrowserBuilder builder;

  /// Folder to start in, relative to the workspace root.
  final String initialPath;

  /// Extra slivers above the search field, for the folder at [rel].
  final List<Widget> Function(String rel)? header;

  /// System back goes up a folder (and leaves search) before leaving.
  final bool handleBack;

  /// Clock for the time labels (tests).
  final DateTime Function()? now;

  @override
  ConsumerState<WorkspaceBrowser> createState() => _WorkspaceBrowserState();
}

class _WorkspaceBrowserState extends ConsumerState<WorkspaceBrowser> with SingleTickerProviderStateMixin {
  late String _rel = widget.initialPath;
  final _search = TextEditingController();
  final _contentKey = GlobalKey();
  Timer? _debounce;
  String _query = '';

  /// What each folder held when first shown, and what arrived later.
  final Map<String, FolderArrivals> _seen = {};

  /// Fades the list in when the folder changes.
  late final AnimationController _swap = AnimationController(vsync: this, duration: AppMotion.quick, value: 1);

  bool get _searching => _query.isNotEmpty;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _swap.dispose();
    super.dispose();
  }

  void _go(String rel) {
    if (rel == _rel && !_searching) return;
    HapticFeedback.selectionClick();
    final wasSearching = _searching;
    setState(() {
      _rel = rel;
      if (wasSearching) {
        _search.clear();
        _query = '';
      }
    });
    FocusManager.instance.primaryFocus?.unfocus();
    final duration = AppMotion.of(context, AppMotion.quick);
    if (duration == Duration.zero) {
      _swap.value = 1;
    } else {
      _swap
        ..duration = duration
        ..forward(from: 0);
    }
    // Back to the top: a new folder starts at its first row.
    final position = Scrollable.maybeOf(_contentKey.currentContext ?? context)?.position;
    if (position != null && position.pixels > position.minScrollExtent) {
      position.jumpTo(position.minScrollExtent);
    }
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      setState(() => _query = '');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _query = query);
    });
    setState(() {}); // the clear button
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = '');
  }

  Future<void> _refresh() async {
    if (_searching) {
      ref.invalidate(workspaceSearchProvider((widget.sessionId, _query)));
      await ref
          .read(workspaceSearchProvider((widget.sessionId, _query)).future)
          .catchError((Object _) => const <FileReferenceCandidate>[]);
      return;
    }
    await ref.read(workspaceDirProvider((widget.sessionId, _rel)).notifier).refresh();
  }

  void _openFile(String rel, int? bytes) {
    final root = ref.read(workspaceRootProvider(widget.sessionId));
    Navigator.of(context)
        .push(FilePreviewPage.route(sessionId: widget.sessionId, path: workspaceHostPath(root, rel), bytes: bytes));
  }

  Future<void> _fileMenu(String rel, int? bytes) async {
    final root = ref.read(workspaceRootProvider(widget.sessionId));
    await showWorkspaceFileMenu(
      context,
      ref,
      sessionId: widget.sessionId,
      path: workspaceHostPath(root, rel),
      bytes: bytes,
    );
  }

  Future<void> _folderMenu(String rel) async {
    final root = ref.read(workspaceRootProvider(widget.sessionId));
    final open = await showWorkspaceFolderMenu(
      context,
      ref,
      sessionId: widget.sessionId,
      name: rel.isEmpty ? appL10n.botsWorkspace : rel.split('/').last,
      path: workspaceHostPath(root, rel),
    );
    if (open == true && mounted) _go(rel);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sessionId = widget.sessionId;
    final connected = ref.watch(workspaceSourceProvider(sessionId)) != null;
    final root = ref.watch(workspaceRootProvider(sessionId));
    final slivers = <Widget>[
      ...?widget.header?.call(_rel),
      SliverToBoxAdapter(
        key: _contentKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: WorkspaceSearchField(controller: _search, onChanged: _onQuery, onClear: _clearSearch),
        ),
      ),
      if (!connected)
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.disconnected,
            title: l10n.commonEngineUnreachable,
            padding: EdgeInsets.fromLTRB(32, 48, 32, 24),
          ),
        )
      else if (_searching)
        _SearchSliver(
          sessionId: sessionId,
          query: _query,
          root: root,
          onFolder: _go,
          onFile: _openFile,
          onFileMenu: _fileMenu,
          onFolderMenu: _folderMenu,
        )
      else ...[
        SliverToBoxAdapter(
          child: WorkspaceCrumbs(path: _rel, onSelect: _go),
        ),
        SliverFadeTransition(
          opacity: _swap,
          sliver: _FolderSliver(
            key: ValueKey(_rel),
            sessionId: sessionId,
            rel: _rel,
            root: root,
            seen: _seen.putIfAbsent(_rel, FolderArrivals.new),
            now: widget.now ?? DateTime.now,
            onFolder: (name) => _go(workspaceChild(_rel, name)),
            onFile: (name, bytes) => _openFile(workspaceChild(_rel, name), bytes),
            onFileMenu: (name, bytes) => _fileMenu(workspaceChild(_rel, name), bytes),
            onFolderMenu: (name) => _folderMenu(workspaceChild(_rel, name)),
            onUp: () => _go(workspaceParent(_rel)),
          ),
        ),
      ],
    ];
    final child = widget.builder(context, slivers, _refresh);
    if (!widget.handleBack) return child;
    return PopScope(
      canPop: _rel.isEmpty && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searching) {
          _clearSearch();
        } else {
          _go(workspaceParent(_rel));
        }
      },
      child: child,
    );
  }
}

/// A 44 tall capsule: the magnifier on the left and the clear key on the right
/// each take a mirrored 44 slot, so the field is as tall empty as filled.
class WorkspaceSearchField extends StatelessWidget {
  const WorkspaceSearchField({super.key, required this.controller, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  static const height = 44.0;
  static const slot = 44.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    const capsule = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(999)),
      borderSide: BorderSide.none,
    );
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.05),
          hintText: l10n.botsSearchFiles,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(color: dsh.textTertiary),
          contentPadding: EdgeInsets.zero,
          prefixIcon: Icon(AppIcons.search, size: 20, color: dsh.textTertiary),
          prefixIconConstraints: const BoxConstraints.tightFor(width: slot, height: height),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox(width: slot, height: height)
                : Semantics(
                    button: true,
                    label: l10n.commonClear,
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
          suffixIconConstraints: const BoxConstraints.tightFor(width: slot, height: height),
          border: capsule,
          enabledBorder: capsule,
          focusedBorder: capsule,
        ),
      ),
    );
  }
}

// ── Path capsules ───────────────────────────────────────────────────────────

/// Path capsules, 「工作区 › app › lib」: the current level in a heavier weight,
/// parents tappable. One horizontally scrolling line, aligned (16) with the
/// search field and the list card.
class WorkspaceCrumbs extends StatelessWidget {
  const WorkspaceCrumbs({super.key, required this.path, required this.onSelect});

  final String path;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final parts = path.isEmpty ? const <String>[] : path.split('/');
    return Padding(
      padding: const EdgeInsets.only(top: BreadcrumbRow.gap),
      child: BreadcrumbRow(
        crumbs: [
          (label: l10n.botsWorkspace, path: ''),
          for (final (i, part) in parts.indexed) (label: part, path: parts.take(i + 1).join('/')),
        ],
        onTap: onSelect,
      ),
    );
  }
}

/// Fills what is left of the viewport, so a short folder still scrolls (and
/// pulls to refresh).
class WorkspaceFillRest extends StatelessWidget {
  const WorkspaceFillRest({super.key});

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) => SliverToBoxAdapter(
      child: SizedBox(height: math.max(0.0, constraints.viewportMainAxisExtent - constraints.precedingScrollExtent)),
    ),
  );
}

// ── Card sliver ─────────────────────────────────────────────────────────────

/// A list card (the [ListPageCard] look: card glass, radius 20, 4 above and
/// below the rows) whose rows are built lazily, for folders with thousands
/// of entries.
class WorkspaceCardSliver extends StatelessWidget {
  const WorkspaceCardSliver({super.key, required this.count, required this.itemBuilder});

  final int count;
  final IndexedWidgetBuilder itemBuilder;

  static const radius = AppShape.lg;

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final style = surfaces.glass(GlassTier.card);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final reduce = !surfaces.blurEnabled || highContrast;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: DecoratedSliver(
        decoration: _CardDecoration(
          fill: reduce ? style.fallbackFill : style.fill,
          hairline: style.hairline,
          hairlineWidth: style.hairlineWidth,
          rim: style.rim,
        ),
        sliver: SliverPadding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          sliver: SliverList.builder(
            itemCount: count,
            itemBuilder: (context, i) {
              final row = Material(type: MaterialType.transparency, child: itemBuilder(context, i));
              // Ink stays inside the rounded corners.
              const inner = Radius.circular(radius - 4);
              if (count == 1) {
                return ClipRSuperellipse(borderRadius: const BorderRadius.all(inner), child: row);
              }
              if (i == 0) {
                return ClipRSuperellipse(
                  borderRadius: const BorderRadius.vertical(top: inner),
                  child: row,
                );
              }
              if (i == count - 1) {
                return ClipRSuperellipse(
                  borderRadius: const BorderRadius.vertical(bottom: inner),
                  child: row,
                );
              }
              return row;
            },
          ),
        ),
      ),
    );
  }
}

/// The card glass ([GlassSurface], card tier) as a [Decoration]: fill, inner
/// hairline, top rim.
class _CardDecoration extends Decoration {
  const _CardDecoration({required this.fill, required this.hairline, required this.hairlineWidth, required this.rim});

  final Color fill;
  final Color hairline;
  final double hairlineWidth;
  final Color rim;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _CardPainter(this);

  @override
  bool operator ==(Object other) =>
      other is _CardDecoration &&
      other.fill == fill &&
      other.hairline == hairline &&
      other.hairlineWidth == hairlineWidth &&
      other.rim == rim;

  @override
  int get hashCode => Object.hash(fill, hairline, hairlineWidth, rim);
}

class _CardPainter extends BoxPainter {
  _CardPainter(this.decoration);

  final _CardDecoration decoration;

  static const _shape = RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    canvas.drawPath(_shape.getOuterPath(rect), Paint()..color = decoration.fill);
    final width = math.max(decoration.hairlineWidth, 0.5);
    final edge = _shape.getOuterPath(rect.deflate(width / 2));
    if (decoration.hairline.a > 0) {
      canvas.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = decoration.hairline,
      );
    }
    if (decoration.rim.a > 0) {
      // Only the top edge catches the light (as on [GlassSurface], whose
      // gradient runs over a short card; a long list keeps it to the top).
      final reach = math.min(size.height * 0.45, 120.0);
      canvas.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(width, 0.8)
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [decoration.rim, decoration.rim.withValues(alpha: 0)],
          ).createShader(Rect.fromLTWH(rect.left, rect.top, rect.width, reach)),
      );
    }
  }
}

// ── Folder ──────────────────────────────────────────────────────────────────

class _FolderSliver extends ConsumerWidget {
  const _FolderSliver({
    super.key,
    required this.sessionId,
    required this.rel,
    required this.root,
    required this.seen,
    required this.now,
    required this.onFolder,
    required this.onFile,
    required this.onFileMenu,
    required this.onFolderMenu,
    required this.onUp,
  });

  final String sessionId;
  final String rel;
  final String? root;
  final FolderArrivals seen;
  final DateTime Function() now;
  final ValueChanged<String> onFolder;
  final void Function(String name, int? bytes) onFile;
  final void Function(String name, int? bytes) onFileMenu;
  final ValueChanged<String> onFolderMenu;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final key = (sessionId, rel);
    final dir = ref.watch(workspaceDirProvider(key));
    if (!dir.loaded) {
      if (dir.error case final error?) {
        final gone = error is DshRemoteException && error.code == 'workspace-file/not-found' && rel.isNotEmpty;
        return SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.noFolder,
            title: l10n.botsFolderOpenFailed,
            message: workspaceErrorText(error),
            actionLabel: gone ? l10n.botsGoUp : l10n.commonRetry,
            onAction: gone ? onUp : () => ref.read(workspaceDirProvider(key).notifier).refresh(),
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
          ),
        );
      }
      return const SliverToBoxAdapter(child: QuietSpinner());
    }
    final entries = dir.entries;
    if (entries.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyView(
          art: FeatureTile(FeatureKind.files, size: FeatureTile.empty),
          title: l10n.botsEmptyFolder,
          padding: EdgeInsets.fromLTRB(32, 36, 32, 24),
        ),
      );
    }
    seen.note(entries.map((e) => e.name));
    final folders = entries.where((e) => e.isDirectory).length;
    final files = entries.length - folders;
    final clock = now();
    final local = ref.watch(artifactFilesProvider.select((f) => f.isLocal));
    return SliverMainAxisGroup(
      slivers: [
        WorkspaceCardSliver(
          count: entries.length,
          itemBuilder: (context, i) {
            final entry = entries[i];
            final hostPath = workspaceHostPath(root, workspaceChild(rel, entry.name));
            final row = WorkspaceEntryRow(
              entry: entry,
              sessionId: sessionId,
              thumbnailPath: local && hostPath.startsWith('/') ? hostPath : null,
              modified: dir.times[entry.name],
              now: clock,
              onTap: switch (entry.type) {
                DshWorkspaceEntryType.directory => () => onFolder(entry.name),
                DshWorkspaceEntryType.file => () => onFile(entry.name, entry.size),
                DshWorkspaceEntryType.other => null,
              },
              onLongPress: switch (entry.type) {
                DshWorkspaceEntryType.directory => () => onFolderMenu(entry.name),
                DshWorkspaceEntryType.file => () => onFileMenu(entry.name, entry.size),
                DshWorkspaceEntryType.other => null,
              },
            );
            return _Entrance(key: ValueKey(entry.name), index: i, arrived: seen.arrivedAt(entry.name), child: row);
          },
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Text(
              [
                if (folders > 0) l10n.botsFolderCount(folders),
                if (files > 0) l10n.botsFileCount(files),
                if (dir.truncated) l10n.botsTruncatedItems(entries.length),
              ].join(l10n.botsListSeparator),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
        ),
      ],
    );
  }
}

/// Names a folder held when first listed, and when later ones arrived.
class FolderArrivals {
  final Set<String> _names = {};
  final Map<String, DateTime> _arrived = {};
  bool _listed = false;

  /// Records a listing: names not seen before arrived now (none on the
  /// first listing).
  void note(Iterable<String> names) {
    final now = DateTime.now();
    for (final name in names) {
      if (_names.add(name) && _listed) _arrived[name] = now;
    }
    _listed = true;
  }

  DateTime? arrivedAt(String name) => _arrived[name];
}

/// A row's entrance, chosen once per row: one that just arrived grows in
/// (and fades in); the first rows of a folder rise in with the list.
class _Entrance extends StatefulWidget {
  const _Entrance({super.key, required this.index, required this.arrived, required this.child});

  final int index;
  final DateTime? arrived;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> {
  /// Built within a moment of arriving (not scrolled back to later).
  late final bool _arriving =
      widget.arrived != null && DateTime.now().difference(widget.arrived!) < const Duration(milliseconds: 800);
  bool _open = false;

  @override
  void initState() {
    super.initState();
    if (_arriving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _open = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) => _arriving
      ? ExpandReveal(open: _open, child: widget.child)
      : FadeSlideIn(index: widget.index, child: widget.child);
}

/// One folder entry: glyph, name, size · time; folders end in ›.
class WorkspaceEntryRow extends StatelessWidget {
  const WorkspaceEntryRow({
    super.key,
    required this.entry,
    required this.sessionId,
    required this.now,
    this.thumbnailPath,
    this.modified,
    this.onTap,
    this.onLongPress,
  });

  final DshWorkspaceEntry entry;
  final String sessionId;
  final String? thumbnailPath;
  final DateTime? modified;
  final DateTime now;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final directory = entry.isDirectory;
    final dim = entry.name.startsWith('.') || entry.type == DshWorkspaceEntryType.other;
    final subtitle = directory
        ? null
        : [
            if (entry.size case final size?) formatBytes(size),
            if (modified case final at?) fileTimeLabel(at, now),
          ].join(' · ');
    final row = ListPageRow(
      leading: FileGlyph(name: entry.name, directory: directory, sessionId: sessionId, thumbnailPath: thumbnailPath),
      title: entry.name,
      titleStyle: dim ? theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4, color: dsh.textTertiary) : null,
      subtitle: subtitle == null || subtitle.isEmpty ? null : subtitle,
      chevron: directory,
      onTap: onTap,
    );
    if (onLongPress == null) return row;
    return Semantics(
      onLongPress: onLongPress,
      onLongPressHint: l10n.botsMoreActions,
      child: GestureDetector(
        onLongPress: () {
          HapticFeedback.mediumImpact();
          onLongPress!();
        },
        child: row,
      ),
    );
  }
}

// ── Search ──────────────────────────────────────────────────────────────────

class _SearchSliver extends ConsumerWidget {
  const _SearchSliver({
    required this.sessionId,
    required this.query,
    required this.root,
    required this.onFolder,
    required this.onFile,
    required this.onFileMenu,
    required this.onFolderMenu,
  });

  final String sessionId;
  final String query;
  final String? root;
  final ValueChanged<String> onFolder;
  final void Function(String rel, int? bytes) onFile;
  final void Function(String rel, int? bytes) onFileMenu;
  final ValueChanged<String> onFolderMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final results = ref.watch(workspaceSearchProvider((sessionId, query)));
    final list = results.value;
    if (list == null) {
      if (results.hasError) {
        return SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.noResults,
            title: l10n.botsSearchFailed,
            message: workspaceErrorText(results.error!),
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
          ),
        );
      }
      return const SliverToBoxAdapter(child: QuietSpinner());
    }
    if (list.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyView(
          icon: AppIcons.noResults,
          title: l10n.botsNoResults,
          padding: EdgeInsets.fromLTRB(32, 36, 32, 24),
        ),
      );
    }
    final dsh = DshColors.of(context);
    return SliverMainAxisGroup(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        WorkspaceCardSliver(
          count: list.length,
          itemBuilder: (context, i) {
            final hit = list[i];
            final row = ListPageRow(
              leading: FileGlyph(name: hit.name, directory: hit.isDirectory),
              title: hit.name,
              subtitle: hit.parent.isEmpty ? l10n.botsWorkspace : hit.parent,
              subtitleColor: dsh.textTertiary,
              chevron: hit.isDirectory,
              onTap: hit.isDirectory ? () => onFolder(hit.path) : () => onFile(hit.path, null),
            );
            return Semantics(
              onLongPressHint: l10n.botsMoreActions,
              child: GestureDetector(
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  hit.isDirectory ? onFolderMenu(hit.path) : onFileMenu(hit.path, null);
                },
                child: row,
              ),
            );
          },
        ),
      ],
    );
  }
}

// ── Menus ───────────────────────────────────────────────────────────────────

/// Long press on a file: preview, open (with…), share, save to the phone,
/// copy the path. [path] is what the Host knows the file by.
Future<void> showWorkspaceFileMenu(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String path,
  int? bytes,
}) async {
  final files = ref.read(artifactFilesProvider);
  final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0, bytes: bytes);
  final action = await showArtifactMenu(
    context,
    artifact: artifact,
    canFetch: files.canFetch,
    officeToPdf: files.canConvertOffice,
  );
  if (action == null || !context.mounted) return;
  await runArtifactAction(context, ref, sessionId: sessionId, artifact: artifact, action: action);
}

/// Long press on a folder: open it, or copy its path. True: open.
Future<bool?> showWorkspaceFolderMenu(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String name,
  required String path,
}) {
  HapticFeedback.selectionClick();
  return showAppSheet<bool>(
    context,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final dsh = DshColors.of(sheet);
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    path,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono(size: 12, height: 1.4, color: dsh.textTertiary),
                  ),
                ],
              ),
            ),
            SheetGroup(
              children: [
                SettingsTile(
                  icon: AppIcons.folderOpen,
                  tinted: false,
                  title: context.l10n.commonOpen,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, true),
                ),
                SettingsTile(
                  icon: AppIcons.copy,
                  tinted: false,
                  title: context.l10n.botsCopyPath,
                  chevron: false,
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(
                      resolveWorkspacePath(ref, sessionId, path).then((full) {
                        if (context.mounted) return copyPath(context, full);
                      }),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}

/// [path] as an absolute path: as is, or asked of the Host when only the
/// workspace-relative form is known (the folder of a relative path is
/// found through one of its files' stat; a folder stays relative).
Future<String> resolveWorkspacePath(WidgetRef ref, String sessionId, String path) async {
  if (path.startsWith('/')) return path;
  final source = ref.read(workspaceSourceProvider(sessionId));
  if (source == null) return path;
  try {
    final stat = await source.stat(path);
    return stat.absolutePath.isEmpty ? path : stat.absolutePath;
  } catch (_) {
    return path;
  }
}
