part of 'workshop_page_samples.dart';

Future<WorkshopInstalledListState> _installedRows(List<WorkshopLocalEntry> rows,
  {WorkshopCatalogSnapshot? catalog, bool configured = true}) async {
  final harness = _LocalSample(packages: StatePackages()..rows = rows,
    client: StateClient()..network = catalog ?? _sampleCatalog(), configured: configured);
  try {
    if (configured) {
      await harness.installedReady();
    } else {
      // A page sample should not perform a second explicit dependency retry
      // while it is demonstrating the first unconfigured read.
      await harness.container.read(workshopInstalledProvider.notifier).ready;
      await harness.catalogReady();
    }
    return await harness.container.read(workshopInstalledProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopInstalledListState> installedTrustedHealthy() => _installedRows([workshopSampleInstalled()]);
Future<WorkshopInstalledListState> installedTrustedLocalIssue() => _installedRows([
  workshopSampleInstalled(issue: 'workshop_pet_not_a_pack'),
]);
Future<WorkshopInstalledListState> installedUntrustedReceiptIssue() => _installedRows([
  const WorkshopInstallationIssue(localId: 'user-unreadable', issue: 'workshop_install_record'),
]);
Future<WorkshopInstalledListState> installedUntrustedCompanionRecoveryIssue() => _installedRows([
  const WorkshopInstallationIssue(localId: 'companion', issue: 'workshop_readers_busy'),
]);

Future<WorkshopInstalledListState> installedRemoteWithdrawn() {
  final row = workshopSampleInstalled();
  return _installedRows([row], catalog: _sampleCatalog(entries: [], withdrawn: [row]));
}

Future<WorkshopInstalledListState> installedCompanionDisabled() => _installedRows([
  workshopSampleInstalled(kind: 'companion', id: 'cloud-traveller'),
], catalog: _sampleCatalog(entries: [], companion: false));

Future<WorkshopInstalledListState> installedOtherOrigin() => _installedRows([
  workshopSampleInstalled(origin: otherStateOrigin),
]);

Future<WorkshopInstalledListState> installedRestrictedNewVersion() => _installedRows([
  workshopSampleInstalled(version: '1.0.0'),
], catalog: _sampleCatalog(entries: [workshopSampleEntry(minApp: '9.0.0', blocked: ['1.0.0'])],
  withdrawn: [workshopSampleInstalled(version: '1.0.0')]));

Future<WorkshopInstalledListState> installedWithdrawnOldVersionHasUpdate() => _installedRows([
  workshopSampleInstalled(version: '1.0.0', issue: 'workshop_pet_not_a_pack'),
], catalog: _sampleCatalog(entries: [workshopSampleEntry(blocked: ['1.0.0'])],
  withdrawn: [workshopSampleInstalled(version: '1.0.0')]));

Future<WorkshopInstalledListState> installedEmpty() => _installedRows([]);
Future<WorkshopInstalledListState> installedWithoutWorker() => _installedRows([
  workshopSampleInstalled(issue: 'workshop_pet_not_a_pack'),
], configured: false);

Future<WorkshopInstalledListState> installedInitial() async {
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog());
  final initial = harness.container.read(workshopInstalledProvider);
  try {
    return initial;
  } finally {
    await stateSettled(harness.installedReady());
    harness.dispose();
  }
}

Future<WorkshopInstalledListState> installedLocalBeforeCatalog() async {
  final gate = _SampleGate();
  final client = StateClient()..readNetwork = (_) async {
    await gate.wait();
    return _sampleCatalog();
  };
  final harness = _LocalSample(client: client,
    packages: StatePackages()..rows = [workshopSampleInstalled()]);
  final controller = harness.container.read(workshopInstalledProvider.notifier);
  final pending = harness.catalogReady();
  final settled = stateSettled(pending);
  try {
    await controller.ready;
    return await _sampleWhile(pending, gate,
      () => harness.container.read(workshopInstalledProvider));
  } finally {
    gate.release();
    await settled;
    await stateSettled(controller.refresh());
    harness.dispose();
  }
}

Future<WorkshopInstalledListState> installedCatalogFailedKeepsLocal() async {
  final harness = _LocalSample(packages: StatePackages()..rows = [workshopSampleInstalled()],
    client: StateClient()..readNetwork = (_) async => throw const WorkshopException('workshop_network'));
  try {
    await harness.installedReady();
    return await harness.container.read(workshopInstalledProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopInstalledListState> installedLocalReadFailed() async {
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(),
    packages: StatePackages()..list = () async => throw const WorkshopException('workshop_storage'));
  try {
    await harness.installedReady();
    return await harness.container.read(workshopInstalledProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopInstalledListState> installedRefreshFailedKeepsRows() async {
  final packages = StatePackages()..rows = [workshopSampleInstalled()];
  final harness = _LocalSample(packages: packages, client: StateClient()..network = _sampleCatalog());
  try {
    await harness.installedReady();
    packages.list = () async => throw const WorkshopException('workshop_storage');
    await harness.container.read(workshopInstalledProvider.notifier).refresh();
    return await harness.container.read(workshopInstalledProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopInstalledListState> installedRefreshingKeepsRows() async {
  final gate = _SampleGate();
  final packages = StatePackages()..rows = [workshopSampleInstalled()];
  final harness = _LocalSample(packages: packages, client: StateClient()..network = _sampleCatalog());
  try {
    await harness.installedReady();
    packages.list = () async { await gate.wait(); return List.of(packages.rows); };
    return await _sampleWhile(harness.container.read(workshopInstalledProvider.notifier).refresh(),
      gate, () => harness.container.read(workshopInstalledProvider));
  } finally { harness.dispose(); }
}

Future<WorkshopInstalledListState> _installedRemoval({bool captureRemoving = false,
  bool untrusted = false, bool fail = false, bool refreshFailure = false}) async {
  final WorkshopLocalEntry row = untrusted
    ? const WorkshopInstallationIssue(localId: 'user-unreadable', issue: 'workshop_install_record')
    : workshopSampleInstalled(issue: 'workshop_pet_not_a_pack');
  final gate = _SampleGate();
  final packages = StatePackages()..rows = [row];
  packages.removeAction = (_) async {
    if (captureRemoving) await gate.wait();
    if (fail) throw const WorkshopException('workshop_install_conflict');
  };
  final harness = _LocalSample(packages: packages, client: StateClient()..network = _sampleCatalog(),
    changed: (item, {required removed}) async {
      if (refreshFailure) throw const WorkshopException('workshop_storage');
    });
  Future<bool>? pending;
  try {
    await harness.installedReady();
    pending = harness.container.read(workshopInstalledProvider.notifier).uninstall(row);
    if (captureRemoving) {
      return await _sampleWhile(pending, gate, () => harness.container.read(workshopInstalledProvider));
    }
    await pending;
    if (untrusted && packages.removed.isNotEmpty) {
      throw StateError('Untrusted row crossed the expected-receipt removal boundary');
    }
    return await harness.container.read(workshopInstalledProvider);
  } finally {
    gate.release();
    if (pending != null) await stateSettled(pending);
    harness.dispose();
  }
}

Future<WorkshopInstalledListState> installedRemoving() => _installedRemoval(captureRemoving: true);
Future<WorkshopInstalledListState> installedRemovalSucceeded() => _installedRemoval();
Future<WorkshopInstalledListState> installedRemovalFailed() => _installedRemoval(fail: true);
Future<WorkshopInstalledListState> installedRemovalRefreshFailed() => _installedRemoval(refreshFailure: true);
Future<WorkshopInstalledListState> installedUntrustedRemovalRefused() => _installedRemoval(untrusted: true);
