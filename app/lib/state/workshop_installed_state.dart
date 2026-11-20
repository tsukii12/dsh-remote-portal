import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart';
import 'workshop_catalog_state.dart';
import 'workshop_dependencies.dart';

enum WorkshopMutationKind { install, uninstall }

/// One local mutation at a time per ProviderContainer. The token belongs to
/// the started operation, including its post-commit refresh, not to a page.
class WorkshopMutation {
  WorkshopMutation({required this.kind, required this.identity});
  final WorkshopMutationKind kind;
  final String identity;
}

final workshopMutationProvider = NotifierProvider<WorkshopMutationController, WorkshopMutation?>(
  WorkshopMutationController.new,
);

class WorkshopMutationController extends Notifier<WorkshopMutation?> {
  @override
  WorkshopMutation? build() => null;

  WorkshopMutation? claim(WorkshopMutationKind kind, String identity) {
    if (!ref.mounted || state != null) return null;
    final token = WorkshopMutation(kind: kind, identity: identity);
    state = token;
    return token;
  }

  void release(WorkshopMutation token) {
    if (ref.mounted && identical(state, token)) state = null;
  }
}

class WorkshopInstalledRow {
  const WorkshopInstalledRow({required this.local, this.remote});
  final WorkshopLocalEntry local;
  final WorkshopInstalledState? remote;

  String? get localIssue => local.issue;
  bool get canUninstall => local is WorkshopInstalled;
  bool get remoteKnown => local is WorkshopInstalled && remote != null;
  String? get remoteUnavailable => remoteKnown ? remote!.unavailable : null;
  bool? get installedWithdrawn => remoteKnown ? remote!.installedWithdrawn : null;
  bool? get updateAvailable => remoteKnown ? remote!.updateAvailable : null;
  WorkshopEntry? get publicEntry => remoteKnown ? remote!.entry : null;
}

enum WorkshopRemovalPhase { idle, removing, succeeded, failed }

class WorkshopRemovalState {
  const WorkshopRemovalState({this.phase = WorkshopRemovalPhase.idle, this.target,
    this.error, this.refreshError});
  final WorkshopRemovalPhase phase;
  final WorkshopLocalEntry? target;
  final String? error, refreshError;
}

const _unchanged = Object();

class WorkshopInstalledListState {
  WorkshopInstalledListState({List<WorkshopInstalledRow> rows = const [], this.loading = false,
    this.refreshing = false, this.loadError, this.catalogError,
    this.catalogStale,
    this.removal = const WorkshopRemovalState()}) : rows = List.unmodifiable(rows);
  final List<WorkshopInstalledRow> rows;
  final bool loading, refreshing;
  final String? loadError, catalogError;
  final bool? catalogStale;
  final WorkshopRemovalState removal;

  WorkshopInstalledListState copyWith({List<WorkshopInstalledRow>? rows, bool? loading,
    bool? refreshing, Object? loadError = _unchanged, Object? catalogError = _unchanged,
    Object? catalogStale = _unchanged,
    WorkshopRemovalState? removal}) => WorkshopInstalledListState(
      rows: rows ?? this.rows, loading: loading ?? this.loading,
      refreshing: refreshing ?? this.refreshing,
      loadError: identical(loadError, _unchanged) ? this.loadError : loadError as String?,
      catalogError: identical(catalogError, _unchanged) ? this.catalogError : catalogError as String?,
      catalogStale: identical(catalogStale, _unchanged) ? this.catalogStale : catalogStale as bool?,
      removal: removal ?? this.removal,
    );
}

final workshopInstalledProvider = NotifierProvider<WorkshopInstalledController, WorkshopInstalledListState>(
  WorkshopInstalledController.new,
);

class WorkshopInstalledController extends Notifier<WorkshopInstalledListState> {
  int _generation = 0, _read = 0, _catalogRead = 0;
  bool _readingLocal = true;
  late Future<WorkshopPackages> _packages;
  late Future<void> _ready;
  Future<void> get ready {
    final _ = state;
    return _ready;
  }

  @override
  WorkshopInstalledListState build() {
    _packages = ref.watch(workshopPackagesProvider.future);
    final generation = ++_generation;
    _readingLocal = true;
    ref.onDispose(() => _generation++);
    ref.listen(workshopCatalogProvider, (previous, next) {
      if (!_current(generation)) return;
      if (previous?.origin != next.origin || !identical(previous?.snapshot, next.snapshot)) {
        final catalogRead = ++_catalogRead;
        // A deferred catalog must not leave an old projection marked known
        // if the independent local read fails. Keep the local rows instead.
        if (_readingLocal || previous?.origin != next.origin || next.snapshot == null) {
          state = state.copyWith(rows: [for (final row in state.rows) WorkshopInstalledRow(local: row.local)],
            catalogStale: null, catalogError: next.refreshError);
        }
        // A catalog event must not discard an independent local read. The
        // latter publishes its rows first and then takes the latest catalog.
        if (!_readingLocal) unawaited(_enrich(generation, _read, catalogRead));
      } else if (previous?.refreshError != next.refreshError) {
        state = state.copyWith(catalogError: next.refreshError);
      }
    });
    _ready = Future<void>.microtask(() => _readLocal(generation));
    return WorkshopInstalledListState(loading: true);
  }

  bool _current(int generation) {
    if (!ref.mounted) return false;
    final _ = state;
    return ref.mounted && generation == _generation;
  }
  bool _currentRead(int generation, int read) => _current(generation) && read == _read;

  /// Clears a displayed terminal result without starting or changing a mutation.
  bool acknowledgeRemoval() {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.removal.phase != WorkshopRemovalPhase.succeeded &&
        current.removal.phase != WorkshopRemovalPhase.failed) {
      return false;
    }
    state = current.copyWith(removal: const WorkshopRemovalState());
    return true;
  }

  Future<void> refresh() {
    if (!ref.mounted) return Future.value();
    final _ = state;
    final generation = _generation;
    retryWorkshopDependencies(ref, includeLocal: true);
    final _ = state;
    if (generation != _generation) return _ready;
    return _readLocal(generation);
  }

  Future<void> _readLocal(int generation) async {
    if (!_current(generation)) return;
    final read = ++_read;
    _readingLocal = true;
    _catalogRead++;
    final packagesFuture = _packages;
    state = state.copyWith(refreshing: true, loadError: null);
    try {
      final packages = await packagesFuture;
      final entries = await packages.installed();
      if (!_currentRead(generation, read)) return;
      state = state.copyWith(rows: [for (final entry in entries) WorkshopInstalledRow(local: entry)],
        loading: false, loadError: null, catalogError: null, catalogStale: null);
      _readingLocal = false;
      await _enrich(generation, read, ++_catalogRead);
    } on Object catch (error) {
      if (_currentRead(generation, read)) {
        state = state.copyWith(loadError: workshopLocalError(error).code);
      }
    } finally {
      if (_currentRead(generation, read)) {
        _readingLocal = false;
        state = state.copyWith(loading: false, refreshing: false);
      }
    }
  }

  Future<void> _enrich(int generation, int read, int catalogRead) async {
    bool current() => _currentRead(generation, read) && catalogRead == _catalogRead;
    if (!current()) return;
    final catalog = ref.read(workshopCatalogProvider);
    final snapshot = catalog.snapshot;
    if (snapshot == null) {
      state = state.copyWith(rows: [for (final row in state.rows) WorkshopInstalledRow(local: row.local)],
        catalogError: catalog.refreshError, catalogStale: null, refreshing: false);
      return;
    }
    try {
      final repository = await ref.read(workshopRepositoryProvider.future);
      if (!current()) return;
      if (repository.client.origin != catalog.origin) workshopInvalid('workshop_untrusted_origin');
      final projected = await repository.installedStates(snapshot.catalog);
      if (!current()) return;
      final currentCatalog = ref.read(workshopCatalogProvider);
      if (currentCatalog.origin != catalog.origin || !identical(currentCatalog.snapshot, snapshot)) return;
      state = state.copyWith(rows: [for (final item in projected)
        WorkshopInstalledRow(local: item.installed,
          remote: item.installed is WorkshopInstalled ? item : null)],
        loading: false, refreshing: false, catalogError: currentCatalog.refreshError, catalogStale: snapshot.stale);
    } on Object catch (error) {
      if (current()) {
        state = state.copyWith(catalogError: workshopLocalError(error).code, refreshing: false);
      }
    }
  }

  /// Returns false if another mutation owns the gate. A trusted receipt with
  /// a local issue is still removable; an issue-only row never reaches remove.
  Future<bool> uninstall(WorkshopLocalEntry entry) async {
    if (!ref.mounted) return false;
    final _ = state;
    final gate = ref.read(workshopMutationProvider.notifier);
    if (ref.read(workshopMutationProvider) != null) return false;
    retryWorkshopDependencies(ref, includeLocal: true);
    final _ = state;
    final token = gate.claim(WorkshopMutationKind.uninstall, entry.localId);
    if (token == null) return false;
    final generation = _generation;
    final packagesFuture = _packages;
    final changed = ref.read(workshopPackageChangedProvider);
    final catalogController = ref.read(workshopCatalogProvider.notifier);
    state = state.copyWith(removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.removing, target: entry));
    try {
      if (entry is! WorkshopInstalled) workshopInvalid('workshop_install_record');
      final packages = await packagesFuture;
      await packages.remove(entry);
      String? refreshError;
      try { await changed(entry, removed: true); }
      on Object { refreshError = 'workshop_local_refresh'; }
      // The mutation already committed. List errors have their own fields and
      // cannot turn this result into a failed/rolled-back uninstall.
      try {
        await refresh();
        await catalogController.reloadLocal();
      } on Object {
        refreshError = 'workshop_local_refresh';
      }
      if (_current(generation)) {
        state = state.copyWith(removal: WorkshopRemovalState(
          phase: WorkshopRemovalPhase.succeeded, target: entry, refreshError: refreshError));
      }
    } on Object catch (error) {
      if (_current(generation)) {
        state = state.copyWith(removal: WorkshopRemovalState(
          phase: WorkshopRemovalPhase.failed, target: entry, error: workshopLocalError(error).code));
      }
    } finally {
      gate.release(token);
    }
    return true;
  }
}
