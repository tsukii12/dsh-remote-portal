import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart';
import 'workshop_catalog_state.dart';
import 'workshop_dependencies.dart';
import 'workshop_installed_state.dart';

enum WorkshopInstallPhase { idle, preparing, downloading, verifying, cancelling,
  awaitingReplacement, succeeded, failed, cancelled }

/// Confirmation is tied to this exact offer and controller generation. It is
/// not a reusable permission to overwrite any later selection.
class WorkshopReplacementRequest {
  WorkshopReplacementRequest._(this.entry);
  final WorkshopEntry entry;
}

class WorkshopInstallState {
  const WorkshopInstallState({this.phase = WorkshopInstallPhase.idle, this.entry,
    this.received = 0, this.total, this.result, this.error, this.refreshError, this.replacement});
  final WorkshopInstallPhase phase;
  final WorkshopEntry? entry;
  final int received;
  final int? total;
  final WorkshopInstalled? result;
  final String? error, refreshError;
  final WorkshopReplacementRequest? replacement;

  bool get busy => switch (phase) {
    WorkshopInstallPhase.preparing || WorkshopInstallPhase.downloading ||
    WorkshopInstallPhase.verifying || WorkshopInstallPhase.cancelling => true,
    _ => false,
  };
}

final workshopInstallProvider = NotifierProvider<WorkshopInstallController, WorkshopInstallState>(
  WorkshopInstallController.new,
);

class WorkshopInstallController extends Notifier<WorkshopInstallState> {
  int _generation = 0;
  late Future<WorkshopRepository> _repository;
  CancelToken? _cancel;

  @override
  WorkshopInstallState build() {
    _repository = ref.watch(workshopRepositoryProvider.future);
    unawaited(_repository.then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
    _generation++;
    _cancel?.cancel();
    _cancel = null;
    ref.onDispose(() {
      _generation++;
      _cancel?.cancel();
    });
    return const WorkshopInstallState();
  }

  bool _current(int generation) {
    if (!ref.mounted) return false;
    final _ = state;
    return ref.mounted && generation == _generation;
  }

  Future<bool> install(WorkshopEntry entry) => _run(entry, replaceExisting: false);

  Future<bool> confirmReplacement(WorkshopReplacementRequest request) {
    if (!ref.mounted || !identical(state.replacement, request)) return Future.value(false);
    return _run(request.entry, replaceExisting: true, confirmation: request);
  }

  bool declineReplacement(WorkshopReplacementRequest request) {
    if (!ref.mounted || !identical(state.replacement, request)) return false;
    state = const WorkshopInstallState();
    return true;
  }

  void cancel() {
    if (!ref.mounted || !state.busy) return;
    _cancel?.cancel();
    state = WorkshopInstallState(phase: WorkshopInstallPhase.cancelling,
      entry: state.entry, received: state.received, total: state.total);
  }

  Future<bool> _run(WorkshopEntry entry, {required bool replaceExisting,
    WorkshopReplacementRequest? confirmation}) async {
    if (!ref.mounted) return false;
    if (state.busy) return false;
    final gate = ref.read(workshopMutationProvider.notifier);
    if (ref.read(workshopMutationProvider) != null) return false;
    retryWorkshopDependencies(ref, includeLocal: true);
    final current = state;
    if (current.busy || replaceExisting && !identical(current.replacement, confirmation)) return false;
    final token = gate.claim(WorkshopMutationKind.install, entry.metadata.identity);
    if (token == null) return false;
    final generation = _generation;
    final repositoryFuture = _repository;
    final changed = ref.read(workshopPackageChangedProvider);
    final catalogController = ref.read(workshopCatalogProvider.notifier);
    final installedController = ref.read(workshopInstalledProvider.notifier);
    final cancel = CancelToken();
    _cancel = cancel;
    state = WorkshopInstallState(phase: WorkshopInstallPhase.preparing, entry: entry);
    try {
      final repository = await repositoryFuture;
      final result = await repository.install(entry, replaceExisting: replaceExisting, cancel: cancel,
        onProgress: (progress) {
          if (_current(generation) && !cancel.isCancelled) {
            state = WorkshopInstallState(phase: WorkshopInstallPhase.downloading, entry: entry,
              received: progress.received, total: progress.total);
          }
        },
        onVerifying: () {
          if (_current(generation) && !cancel.isCancelled) {
            state = WorkshopInstallState(phase: WorkshopInstallPhase.verifying, entry: entry,
              received: state.received, total: state.total);
          }
        });
      String? refreshError;
      try { await changed(result, removed: false); }
      on Object { refreshError = 'workshop_local_refresh'; }
      try {
        await installedController.refresh();
        await catalogController.reloadLocal();
      } on Object {
        refreshError = 'workshop_local_refresh';
      }
      if (_current(generation)) {
        // Cancellation cannot revoke an installer that has already committed.
        state = WorkshopInstallState(phase: WorkshopInstallPhase.succeeded, entry: entry,
          received: state.received, total: state.total, result: result, refreshError: refreshError);
      }
    } on Object catch (error) {
      if (_current(generation)) {
        final code = workshopLocalError(error).code;
        final replacement = code == 'workshop_install_conflict' && !cancel.isCancelled
          ? WorkshopReplacementRequest._(entry) : null;
        state = WorkshopInstallState(
          phase: replacement != null ? WorkshopInstallPhase.awaitingReplacement
            : code == 'workshop_cancelled' ? WorkshopInstallPhase.cancelled : WorkshopInstallPhase.failed,
          entry: entry, received: state.received, total: state.total,
          error: code, replacement: replacement);
      }
    } finally {
      if (_current(generation) && identical(_cancel, cancel)) _cancel = null;
      gate.release(token);
    }
    return true;
  }
}
