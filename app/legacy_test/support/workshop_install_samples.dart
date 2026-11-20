part of 'workshop_page_samples.dart';

class WorkshopInstallSample {
  const WorkshopInstallSample({required this.catalog, required this.install, this.item, this.mutation});
  final WorkshopCatalogState catalog;
  final WorkshopItemState? item;
  final WorkshopInstallState install;
  final WorkshopMutation? mutation;
}

WorkshopInstallSample _readInstall(_LocalSample harness, WorkshopEntry entry) => WorkshopInstallSample(
  catalog: harness.container.read(workshopCatalogProvider),
  item: harness.container.read(workshopItemProvider(entry.metadata.identity)),
  install: harness.container.read(workshopInstallProvider),
  mutation: harness.container.read(workshopMutationProvider));

Future<WorkshopInstalled> _sampleCommit(_LocalSample harness, StateInstallCall call) async {
  final saved = await harness.repository.commit(call);
  if (saved.receipt.kind != 'pet') return saved;
  // Keep the existing seam's call recording, but use PetLibrary's real prefix
  // instead of StatePackages' arbitrary local label in page-facing samples.
  final local = WorkshopInstalled(localId: 'user-${saved.receipt.id}', receipt: saved.receipt);
  harness.packages.rows = [for (final row in harness.packages.rows) identical(row, saved) ? local : row];
  return local;
}

Future<WorkshopInstallSample> installIdle() async {
  final entry = workshopSampleEntry();
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(entries: [entry]));
  try {
    await harness.catalogReady();
    return _readInstall(harness, entry);
  } finally { harness.dispose(); }
}

Future<WorkshopInstallSample> _installInFlight({int? received, int? total,
  bool verifying = false, bool cancelling = false}) async {
  final entry = workshopSampleEntry();
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(entries: [entry]));
  final gate = _SampleGate();
  harness.repository.installAction = (call) async {
    if (received != null) {
      call.onProgress?.call(DownloadProgress(received: received, total: total, source: 'Workshop'));
    }
    if (verifying) call.onVerifying?.call();
    await gate.wait();
    if (call.cancel?.isCancelled == true) {
      throw const WorkshopException('workshop_cancelled');
    }
    return _sampleCommit(harness, call);
  };
  try {
    await harness.catalogReady();
    final controller = harness.container.read(workshopInstallProvider.notifier);
    final pending = controller.install(entry);
    return await _sampleWhile(pending, gate, () {
      if (cancelling) controller.cancel();
      return _readInstall(harness, entry);
    });
  } finally { harness.dispose(); }
}

Future<WorkshopInstallSample> installPreparing() => _installInFlight();
Future<WorkshopInstallSample> installDownloadingStarted() => _installInFlight(received: 0, total: 4);
Future<WorkshopInstallSample> installDownloadingHalf() => _installInFlight(received: 2, total: 4);
/// The notifier's nullable progress contract. The current repository normally
/// supplies metadata.size to its downloader, so this is a seam-level sample.
Future<WorkshopInstallSample> installDownloadingUnknownTotal() => _installInFlight(received: 2);
Future<WorkshopInstallSample> installVerifying() => _installInFlight(received: 4, total: 4, verifying: true);
Future<WorkshopInstallSample> installCancelling() => _installInFlight(received: 2, total: 4, cancelling: true);

Future<WorkshopInstallSample> _installFinished({String? error, bool refreshFailure = false,
  bool cancel = false, bool committedDespiteCancel = false, bool confirmReplacement = false}) async {
  final entry = workshopSampleEntry();
  final gate = _SampleGate();
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(entries: [entry]),
    changed: (item, {required removed}) async {
      if (refreshFailure) throw const WorkshopException('workshop_storage');
    });
  harness.repository.installAction = (call) async {
    if (error == 'workshop_no_space') throw const WorkshopException('workshop_no_space');
    call.onProgress?.call(const DownloadProgress(received: 2, total: 4, source: 'Workshop'));
    if (cancel && !committedDespiteCancel) await gate.wait();
    if (error == 'workshop_network') throw const WorkshopException('workshop_network');
    if (call.cancel?.isCancelled == true && !committedDespiteCancel) {
      throw const WorkshopException('workshop_cancelled');
    }
    call.onProgress?.call(const DownloadProgress(received: 4, total: 4, source: 'Workshop'));
    call.onVerifying?.call();
    if (error != null && !call.replaceExisting) throw WorkshopException(error);
    final result = await _sampleCommit(harness, call);
    // Model cancellation after the installer has committed, not cancellation
    // before the repository's last cancellation check.
    if (cancel && committedDespiteCancel) await gate.wait();
    return result;
  };
  Future<bool>? pending;
  try {
    await harness.catalogReady();
    final controller = harness.container.read(workshopInstallProvider.notifier);
    pending = controller.install(entry);
    if (cancel) {
      await _sampleWhile(pending, gate, () { controller.cancel(); return null; });
    } else {
      await pending;
    }
    if (confirmReplacement) {
      final offered = harness.container.read(workshopInstallProvider).replacement;
      if (offered == null) throw StateError('Conflict did not produce its confirmation');
      await controller.confirmReplacement(offered);
    }
    return _readInstall(harness, entry);
  } finally {
    gate.release();
    if (pending != null) await stateSettled(pending);
    harness.dispose();
  }
}

Future<WorkshopInstallSample> installAwaitingReplacement() => _installFinished(error: 'workshop_install_conflict');
Future<WorkshopInstallSample> installConfirmedReplacement() => _installFinished(
  error: 'workshop_install_conflict', confirmReplacement: true);
Future<WorkshopInstallSample> installNoSpace() => _installFinished(error: 'workshop_no_space');
Future<WorkshopInstallSample> installNetworkFailed() => _installFinished(error: 'workshop_network');
Future<WorkshopInstallSample> installChecksumFailed() => _installFinished(error: 'workshop_sha_mismatch');
Future<WorkshopInstallSample> installSucceeded() => _installFinished();
Future<WorkshopInstallSample> installSucceededRefreshFailed() => _installFinished(refreshFailure: true);
Future<WorkshopInstallSample> installCancelled() => _installFinished(cancel: true);
Future<WorkshopInstallSample> installCancelledButCommitted() => _installFinished(cancel: true, committedDespiteCancel: true);

/// This uses the REAL repository preflight with an old selected entry. The
/// fresh catalog no longer contains that entry. _current rejects before any
/// downloader/filesystem work, rather than a fake inventing the rejection.
Future<WorkshopInstallSample> _installOldSelection({required bool companionDisabled}) async {
  final entry = workshopSampleEntry(kind: companionDisabled ? 'companion' : 'pet');
  final old = workshopSampleInstalled(kind: entry.metadata.kind);
  final client = StateClient()..network = _sampleCatalog(entries: [],
    companion: !companionDisabled, withdrawn: companionDisabled ? [] : [old]);
  final harness = _LocalSample(client: client);
  final realRepository = WorkshopRepository(client: client, packages: harness.packages,
    downloadDirectory: harness.repository.downloadDirectory, appVersion: '2.0.0', freeBytes: () async => null);
  harness.repository.installAction = (call) => realRepository.install(call.entry,
    cancel: call.cancel, replaceExisting: call.replaceExisting,
    onProgress: call.onProgress, onVerifying: call.onVerifying);
  try {
    await harness.catalogReady();
    await harness.container.read(workshopInstallProvider.notifier).install(entry);
    if (harness.packages.installedCalls.isNotEmpty || !client.events.contains('fresh')) {
      throw StateError('Sample did not exercise the fresh preflight rejection');
    }
    return _readInstall(harness, entry);
  } finally { harness.dispose(); }
}

Future<WorkshopInstallSample> installWithdrawnAfterSelection() => _installOldSelection(companionDisabled: false);
Future<WorkshopInstallSample> installCompanionDisabledAfterSelection() => _installOldSelection(companionDisabled: true);

Future<WorkshopInstallSample> detailOtherItemDownloading() async {
  final installing = workshopSampleEntry(), displayed = workshopSampleEntry(id: 'evening-fox', text: WorkshopSampleText.english);
  final gate = _SampleGate();
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(entries: [installing, displayed]));
  harness.repository.installAction = (call) async {
    call.onProgress?.call(const DownloadProgress(received: 2, total: 4, source: 'Workshop'));
    await gate.wait();
    return _sampleCommit(harness, call);
  };
  try {
    await harness.catalogReady();
    return await _sampleWhile(harness.container.read(workshopInstallProvider.notifier).install(installing), gate,
      () => WorkshopInstallSample(catalog: harness.container.read(workshopCatalogProvider),
        item: harness.container.read(workshopItemProvider(displayed.metadata.identity)),
        install: harness.container.read(workshopInstallProvider),
        mutation: harness.container.read(workshopMutationProvider)));
  } finally { harness.dispose(); }
}
