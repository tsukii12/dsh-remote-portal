part of 'workshop_page_samples.dart';

Future<WorkshopCatalogState> browseInitial() async {
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog());
  final initial = harness.container.read(workshopCatalogProvider);
  try {
    return initial;
  } finally {
    await stateSettled(harness.catalogReady());
    harness.dispose();
  }
}

Future<WorkshopCatalogState> browseCachedRefreshing() async {
  final gate = _SampleGate();
  final client = StateClient()..cached = _sampleCatalog(stale: true);
  client.readNetwork = (_) async { await gate.wait(); return _sampleCatalog(); };
  final harness = _LocalSample(client: client,
    packages: StatePackages()..rows = [workshopSampleInstalled(version: '1.0.0')]);
  try {
    return await _sampleWhile(harness.catalogReady(), gate,
      () => harness.container.read(workshopCatalogProvider));
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseCachedLocalUnknown() async {
  final gate = _SampleGate();
  final packages = StatePackages()..list = () async { await gate.wait(); return []; };
  final harness = _LocalSample(packages: packages,
    client: StateClient()..cached = _sampleCatalog(stale: true)..network = _sampleCatalog());
  try {
    return await _sampleWhile(harness.catalogReady(), gate,
      () => harness.container.read(workshopCatalogProvider));
  } finally { harness.dispose(); }
}

List<WorkshopEntry> _textEntries() => [
  workshopSampleEntry(),
  workshopSampleEntry(id: 'bookshop-cat', text: WorkshopSampleText.longChinese),
  workshopSampleEntry(kind: 'companion', id: 'cloud-traveller', text: WorkshopSampleText.emoji),
  workshopSampleEntry(id: 'evening-fox', text: WorkshopSampleText.english),
];

Future<WorkshopCatalogState> _browseLoaded({List<WorkshopEntry>? entries,
  bool companion = true, WorkshopKindFilter kind = WorkshopKindFilter.all, String query = ''}) async {
  final harness = _LocalSample(client: StateClient()
    ..network = _sampleCatalog(entries: entries ?? _textEntries(), companion: companion));
  try {
    await harness.catalogReady();
    final controller = harness.container.read(workshopCatalogProvider.notifier);
    controller.setKind(kind);
    controller.setQuery(query);
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseLoaded() => _browseLoaded();
Future<WorkshopCatalogState> browseEmpty() => _browseLoaded(entries: []);
Future<WorkshopCatalogState> browseFilteredByKind() => _browseLoaded(kind: WorkshopKindFilter.companion);
Future<WorkshopCatalogState> browseFilteredByName() => _browseLoaded(query: ' EVENING ');
Future<WorkshopCatalogState> browseFilteredByAuthor() => _browseLoaded(query: '阿澄');
Future<WorkshopCatalogState> browseNoSearchResults() => _browseLoaded(query: '不存在的角色名');

/// Fresh disabled projections omit companion entries, rather than showing an
/// imaginary disabled companion entry that the current Worker never publishes.
Future<WorkshopCatalogState> browseCompanionDisabled() => _browseLoaded(
  entries: _textEntries().where((entry) => entry.metadata.kind == 'pet').toList(),
  companion: false, kind: WorkshopKindFilter.companion);

Future<WorkshopCatalogState> browseRefreshErrorKeepsContent() async {
  final client = StateClient()..network = _sampleCatalog();
  final harness = _LocalSample(client: client,
    packages: StatePackages()..rows = [workshopSampleInstalled()]);
  try {
    await harness.catalogReady();
    client.readNetwork = (_) async => throw const WorkshopException('workshop_timeout');
    await harness.container.read(workshopCatalogProvider.notifier).refresh();
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseRefreshingKeepsContent() async {
  final gate = _SampleGate();
  final client = StateClient()..network = _sampleCatalog();
  final harness = _LocalSample(client: client);
  try {
    await harness.catalogReady();
    client.readNetwork = (_) async { await gate.wait(); return _sampleCatalog(); };
    return await _sampleWhile(harness.container.read(workshopCatalogProvider.notifier).refresh(),
      gate, () => harness.container.read(workshopCatalogProvider));
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseOfflineWithoutCache() async {
  final harness = _LocalSample(client: StateClient()
    ..issue = 'workshop_cache_storage'
    ..readNetwork = (_) async => throw const WorkshopException('workshop_network'));
  try {
    await harness.catalogReady();
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseStaleOfflineCopy() async {
  final stale = _sampleCatalog(stale: true,
    refreshError: const WorkshopException('workshop_network'), cacheIssue: 'workshop_cache_storage');
  final harness = _LocalSample(client: StateClient()..cached = stale..network = stale);
  try {
    await harness.catalogReady();
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseLocalProjectionFailed() async {
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(),
    packages: StatePackages()..list = () async => throw const WorkshopException('workshop_storage'));
  try {
    await harness.catalogReady();
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseLocalReloadFailedKeepsProjection() async {
  final packages = StatePackages()..rows = [workshopSampleInstalled()];
  final harness = _LocalSample(client: StateClient()..network = _sampleCatalog(), packages: packages);
  try {
    await harness.catalogReady();
    packages.list = () async => throw const WorkshopException('workshop_storage');
    await harness.container.read(workshopCatalogProvider.notifier).reloadLocal();
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

Future<WorkshopCatalogState> browseUnconfigured() async {
  final harness = _LocalSample(configured: false);
  try {
    await harness.catalogReady();
    return await harness.container.read(workshopCatalogProvider);
  } finally { harness.dispose(); }
}

/// The item comes from the production family provider, never from visibleItems.
class WorkshopDetailSample {
  const WorkshopDetailSample({required this.catalog, required this.identity, this.item});
  final WorkshopCatalogState catalog;
  final String identity;
  final WorkshopItemState? item;
}

Future<WorkshopDetailSample> _detail({WorkshopEntry? entry,
  List<WorkshopLocalEntry> installed = const [], String appVersion = '2.0.0',
  WorkshopCatalogSnapshot? snapshot, String? identity}) async {
  final selected = entry ?? workshopSampleEntry();
  final harness = _LocalSample(appVersion: appVersion,
    client: StateClient()..network = snapshot ?? _sampleCatalog(entries: [selected]),
    packages: StatePackages()..rows = installed);
  final key = identity ?? selected.metadata.identity;
  try {
    await harness.catalogReady();
    return WorkshopDetailSample(catalog: harness.container.read(workshopCatalogProvider),
      identity: key, item: harness.container.read(workshopItemProvider(key)));
  } finally { harness.dispose(); }
}

Future<WorkshopDetailSample> detailNotInstalled() => _detail();
Future<WorkshopDetailSample> detailLatestInstalled() => _detail(installed: [workshopSampleInstalled()]);
Future<WorkshopDetailSample> detailUpdateAvailable() => _detail(installed: [workshopSampleInstalled(version: '1.0.0')]);
Future<WorkshopDetailSample> detailLocalIssueStillInstalled() => _detail(
  installed: [workshopSampleInstalled(issue: 'workshop_pet_not_a_pack')]);
Future<WorkshopDetailSample> detailRequiresNewerApp() => _detail(entry: workshopSampleEntry(minApp: '9.0.0'));
Future<WorkshopDetailSample> detailUnknownAppVersion() => _detail(appVersion: 'development');
Future<WorkshopDetailSample> detailVersionRewritten() => _detail(
  installed: [workshopSampleInstalled(hash: 'b' * 64)]);
Future<WorkshopDetailSample> detailOtherOriginIsNotCurrentInstall() => _detail(
  installed: [workshopSampleInstalled(origin: otherStateOrigin)]);

/// Forward-compatible catalog contract, not a kind the bundled Worker emits.
Future<WorkshopDetailSample> detailFutureKindUnsupported() => _detail(
  entry: workshopSampleEntry(kind: 'future-kind'));

Future<WorkshopDetailSample> detailWithdrawnOldVersionHasUpdate() {
  final old = workshopSampleInstalled(version: '1.0.0');
  return _detail(installed: [old], snapshot: _sampleCatalog(
    entries: [workshopSampleEntry(blocked: ['1.0.0'])], withdrawn: [old]));
}

Future<WorkshopDetailSample> detailWithdrawnCurrentAbsent() {
  final old = workshopSampleInstalled();
  return _detail(snapshot: _sampleCatalog(entries: [], withdrawn: [old]), installed: [old]);
}

Future<WorkshopDetailSample> detailCompanionDisabledAbsent() {
  final old = workshopSampleInstalled(kind: 'companion', id: 'cloud-traveller');
  return _detail(snapshot: _sampleCatalog(entries: [], companion: false),
    installed: [old], identity: old.receipt.identity);
}
