import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/state/workshop_install_state.dart';
import 'package:dsh_app/state/workshop_installed_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/workshop_page_samples.dart';

void _sample<T>(String name, Future<T> Function() factory, void Function(T) verify) {
  test(name, () async => verify(await factory()));
}

void _catalog(WorkshopCatalogState state) {
  expect(() => state.items.clear(), throwsUnsupportedError);
  if (state.snapshot == null) expect(state.items, isEmpty);
  for (final item in state.items) {
    if (item.updateAvailable) {
      expect(item.unavailable, isNull);
      expect(item.installed, isNotNull);
      expect(WorkshopVersion.tryParse(item.entry.metadata.version)!
        .compareTo(WorkshopVersion.tryParse(item.installed!.receipt.version)!), greaterThan(0));
    }
  }
}

void _install(WorkshopInstallSample sample) {
  _catalog(sample.catalog);
  final state = sample.install;
  if (state.busy) {
    expect(sample.mutation?.kind, WorkshopMutationKind.install);
    expect(sample.mutation?.identity, state.entry!.metadata.identity);
  } else {
    expect(sample.mutation, isNull);
  }
  if (state.phase == WorkshopInstallPhase.succeeded) {
    expect(state.result, isNotNull);
    expect(state.error, isNull);
    expect(state.result!.receipt.identity, state.entry!.metadata.identity);
    expect(state.result!.receipt.version, state.entry!.metadata.version);
    expect(state.result!.receipt.sha256, state.entry!.metadata.sha256);
    expect(state.result!.localId, 'user-${state.entry!.metadata.id}');
  }
  if (state.phase == WorkshopInstallPhase.awaitingReplacement) {
    expect(state.busy, isFalse);
    expect(state.error, 'workshop_install_conflict');
    expect(state.replacement?.entry, same(state.entry));
  } else {
    expect(state.replacement, isNull);
  }
}

void _installed(WorkshopInstalledListState state) {
  expect(() => state.rows.clear(), throwsUnsupportedError);
  for (final row in state.rows) {
    if (row.local is WorkshopInstalled) {
      expect(row.canUninstall, isTrue); // Local issues and remote flags do not revoke a receipt.
    } else {
      expect(row.canUninstall, isFalse);
      expect(row.remote, isNull);
      expect(row.remoteKnown, isFalse);
      expect(row.remoteUnavailable, isNull);
      expect(row.publicEntry, isNull);
      expect(row.installedWithdrawn, isNull);
      expect(row.updateAvailable, isNull);
    }
    if (row.updateAvailable == true) expect(row.remoteUnavailable, isNull);
  }
}

void main() {
  _sample('browseInitial', browseInitial, (state) {
    _catalog(state);
    expect(state.loading, isTrue);
    expect(state.refreshing, isTrue);
    expect(state.snapshot, isNull);
    expect(state.localStateKnown, isFalse);
  });
  _sample('browseCachedRefreshing', browseCachedRefreshing, (state) {
    _catalog(state);
    expect(state.snapshot!.stale, isTrue);
    expect(state.refreshing, isTrue);
    expect(state.loading, isFalse);
    expect(state.localStateKnown, isTrue);
    expect(state.items.single.updateAvailable, isTrue);
  });
  _sample('browseCachedLocalUnknown', browseCachedLocalUnknown, (state) {
    _catalog(state);
    expect(state.snapshot!.stale, isTrue);
    expect(state.refreshing, isTrue);
    expect(state.localStateKnown, isFalse);
    expect(state.items.single.installed, isNull);
    expect(state.localError, isNull); // Still waiting, not a failed local read.
  });
  _sample('browseLoaded', browseLoaded, (state) {
    _catalog(state);
    expect(state.items, hasLength(4));
    expect(state.visibleItems, state.items);
    expect(state.localStateKnown, isTrue);
    expect(state.refreshing, isFalse);
    expect(state.items.map((item) => item.entry.metadata.title['zh']), contains('云端旅人 ☁️✨'));
    expect(state.items.last.entry.metadata.title['zh'], 'Evening Fox');
  });
  _sample('browseEmpty', browseEmpty, (state) {
    _catalog(state);
    expect(state.snapshot, isNotNull);
    expect(state.items, isEmpty);
    expect(state.localStateKnown, isTrue);
    expect(state.refreshError, isNull);
  });
  _sample('browseFilteredByKind', browseFilteredByKind, (state) {
    _catalog(state);
    expect(state.items, hasLength(4));
    expect(state.kind, WorkshopKindFilter.companion);
    expect(state.visibleItems.single.entry.metadata.identity, 'companion/cloud-traveller');
  });
  _sample('browseFilteredByName', browseFilteredByName, (state) {
    _catalog(state);
    expect(state.query, ' EVENING ');
    expect(state.visibleItems.single.entry.metadata.id, 'evening-fox');
  });
  _sample('browseFilteredByAuthor', browseFilteredByAuthor, (state) {
    _catalog(state);
    expect(state.visibleItems.single.entry.metadata.author, '阿澄 🎨');
  });
  _sample('browseNoSearchResults', browseNoSearchResults, (state) {
    _catalog(state);
    expect(state.items, hasLength(4));
    expect(state.visibleItems, isEmpty);
  });
  _sample('browseCompanionDisabled', browseCompanionDisabled, (state) {
    _catalog(state);
    expect(state.snapshot!.stale, isFalse);
    expect(state.snapshot!.catalog.features.companion, isFalse);
    expect(state.items.every((item) => item.entry.metadata.kind == 'pet'), isTrue);
    expect(state.visibleItems, isEmpty);
  });
  _sample('browseRefreshErrorKeepsContent', browseRefreshErrorKeepsContent, (state) {
    _catalog(state);
    expect(state.refreshError, 'workshop_timeout');
    expect(state.items.single.installed, isNotNull);
    expect(state.localStateKnown, isTrue);
    expect(state.refreshing, isFalse);
  });
  _sample('browseRefreshingKeepsContent', browseRefreshingKeepsContent, (state) {
    _catalog(state); expect(state.items, hasLength(1)); expect(state.refreshing, isTrue);
    expect(state.loading, isFalse); expect(state.snapshot!.stale, isFalse); expect(state.refreshError, isNull);
  });
  _sample('browseOfflineWithoutCache', browseOfflineWithoutCache, (state) {
    _catalog(state);
    expect(state.snapshot, isNull);
    expect(state.refreshError, 'workshop_network');
    expect(state.cacheIssue, 'workshop_cache_storage');
    expect(state.localError, isNull);
  });
  _sample('browseStaleOfflineCopy', browseStaleOfflineCopy, (state) {
    _catalog(state);
    expect(state.items, hasLength(1));
    expect(state.snapshot!.stale, isTrue);
    expect(state.refreshError, 'workshop_network');
    expect(state.cacheIssue, 'workshop_cache_storage');
  });
  _sample('browseLocalProjectionFailed', browseLocalProjectionFailed, (state) {
    _catalog(state);
    expect(state.localStateKnown, isFalse);
    expect(state.localError, 'workshop_storage');
    expect(state.refreshError, isNull);
    expect(state.items.single.installed, isNull);
  });
  _sample('browseLocalReloadFailedKeepsProjection', browseLocalReloadFailedKeepsProjection, (state) {
    _catalog(state);
    expect(state.localStateKnown, isFalse);
    expect(state.localError, 'workshop_storage');
    expect(state.items.single.installed, isNotNull); // Old evidence, not a new successful read.
  });
  _sample('browseUnconfigured', browseUnconfigured, (state) {
    _catalog(state);
    expect(state.refreshError, 'workshop_unconfigured');
    expect(state.snapshot, isNull);
  });

  final detailCases = <(String, Future<WorkshopDetailSample> Function(), String?)>[
    ('detailNotInstalled', detailNotInstalled, null),
    ('detailLatestInstalled', detailLatestInstalled, null),
    ('detailUpdateAvailable', detailUpdateAvailable, null),
    ('detailLocalIssueStillInstalled', detailLocalIssueStillInstalled, null),
    ('detailRequiresNewerApp', detailRequiresNewerApp, 'workshop_min_app'),
    ('detailUnknownAppVersion', detailUnknownAppVersion, 'workshop_app_version_unknown'),
    ('detailVersionRewritten', detailVersionRewritten, 'workshop_version_rewritten'),
    ('detailOtherOriginIsNotCurrentInstall', detailOtherOriginIsNotCurrentInstall, null),
    ('detailFutureKindUnsupported', detailFutureKindUnsupported, 'workshop_unsupported_kind'),
    ('detailWithdrawnOldVersionHasUpdate', detailWithdrawnOldVersionHasUpdate, null),
  ];
  for (final (name, factory, unavailable) in detailCases) {
    _sample(name, factory, (sample) {
      _catalog(sample.catalog);
      final item = sample.item!;
      expect(item, same(sample.catalog.items.single));
      expect(item.entry.metadata.identity, sample.identity);
      expect(item.unavailable, unavailable);
      expect(item.updateAvailable, name == 'detailUpdateAvailable' || name == 'detailWithdrawnOldVersionHasUpdate');
      expect(item.installedWithdrawn, name == 'detailWithdrawnOldVersionHasUpdate');
      if (name == 'detailLatestInstalled') expect(item.installed!.receipt.version, item.entry.metadata.version);
      if (name == 'detailLocalIssueStillInstalled') expect(item.installed!.issue, 'workshop_pet_not_a_pack');
      if (name == 'detailNotInstalled' || name == 'detailOtherOriginIsNotCurrentInstall') expect(item.installed, isNull);
    });
  }
  _sample('detailWithdrawnCurrentAbsent', detailWithdrawnCurrentAbsent, (sample) {
    expect(sample.item, isNull);
    expect(sample.catalog.items, isEmpty);
    expect(sample.catalog.snapshot!.catalog.blocked('pet', 'moon-cat', '2.0.0'), isTrue);
  });
  _sample('detailCompanionDisabledAbsent', detailCompanionDisabledAbsent, (sample) {
    expect(sample.item, isNull);
    expect(sample.catalog.items, isEmpty);
    expect(sample.catalog.snapshot!.catalog.features.companion, isFalse);
  });

  final installPhases = <(String, Future<WorkshopInstallSample> Function(), WorkshopInstallPhase, int, int?)>[
    ('installIdle', installIdle, WorkshopInstallPhase.idle, 0, null),
    ('installPreparing', installPreparing, WorkshopInstallPhase.preparing, 0, null),
    ('installDownloadingStarted', installDownloadingStarted, WorkshopInstallPhase.downloading, 0, 4),
    ('installDownloadingHalf', installDownloadingHalf, WorkshopInstallPhase.downloading, 2, 4),
    ('installDownloadingUnknownTotal', installDownloadingUnknownTotal, WorkshopInstallPhase.downloading, 2, null),
    ('installVerifying', installVerifying, WorkshopInstallPhase.verifying, 4, 4),
    ('installCancelling', installCancelling, WorkshopInstallPhase.cancelling, 2, 4),
    ('installAwaitingReplacement', installAwaitingReplacement, WorkshopInstallPhase.awaitingReplacement, 4, 4),
    ('installConfirmedReplacement', installConfirmedReplacement, WorkshopInstallPhase.succeeded, 4, 4),
    ('installSucceeded', installSucceeded, WorkshopInstallPhase.succeeded, 4, 4),
    ('installSucceededRefreshFailed', installSucceededRefreshFailed, WorkshopInstallPhase.succeeded, 4, 4),
    ('installCancelled', installCancelled, WorkshopInstallPhase.cancelled, 2, 4),
    ('installCancelledButCommitted', installCancelledButCommitted, WorkshopInstallPhase.succeeded, 4, 4),
  ];
  for (final (name, factory, phase, received, total) in installPhases) {
    _sample(name, factory, (sample) {
      _install(sample);
      expect(sample.install.phase, phase);
      expect(sample.install.received, received);
      expect(sample.install.total, total);
      expect(sample.install.refreshError, name == 'installSucceededRefreshFailed' ? 'workshop_local_refresh' : null);
      if (phase == WorkshopInstallPhase.succeeded) expect(sample.item!.installed, isNotNull);
      if (phase == WorkshopInstallPhase.cancelled) expect(sample.install.error, 'workshop_cancelled');
    });
  }
  final installFailures = <(String, Future<WorkshopInstallSample> Function(), String)>[
    ('installNoSpace', installNoSpace, 'workshop_no_space'),
    ('installNetworkFailed', installNetworkFailed, 'workshop_network'),
    ('installChecksumFailed', installChecksumFailed, 'workshop_sha_mismatch'),
    ('installWithdrawnAfterSelection', installWithdrawnAfterSelection, 'workshop_version_withdrawn'),
    ('installCompanionDisabledAfterSelection', installCompanionDisabledAfterSelection, 'workshop_companion_disabled'),
  ];
  for (final (name, factory, code) in installFailures) {
    _sample(name, factory, (sample) {
      _install(sample);
      expect(sample.install.phase, WorkshopInstallPhase.failed);
      expect(sample.install.error, code);
      expect(sample.install.result, isNull);
      if (name == 'installNoSpace') { expect(sample.install.received, 0); expect(sample.install.total, isNull); }
      if (name == 'installChecksumFailed') { expect(sample.install.received, 4); expect(sample.install.total, 4); }
      if (name.endsWith('AfterSelection')) expect(sample.item, isNull);
    });
  }
  _sample('detailOtherItemDownloading', detailOtherItemDownloading, (sample) {
    _install(sample);
    expect(sample.install.phase, WorkshopInstallPhase.downloading);
    expect(sample.install.entry!.metadata.identity, 'pet/moon-cat');
    expect(sample.item!.entry.metadata.identity, 'pet/evening-fox');
    expect(sample.item!.installed, isNull);
    expect(sample.mutation!.identity, isNot(sample.item!.entry.metadata.identity));
  });

  final installedRows = <(String, Future<WorkshopInstalledListState> Function(), String?, String?)>[
    ('installedTrustedHealthy', installedTrustedHealthy, null, null),
    ('installedTrustedLocalIssue', installedTrustedLocalIssue, 'workshop_pet_not_a_pack', null),
    ('installedUntrustedReceiptIssue', installedUntrustedReceiptIssue, 'workshop_install_record', null),
    ('installedUntrustedCompanionRecoveryIssue', installedUntrustedCompanionRecoveryIssue, 'workshop_readers_busy', null),
    ('installedRemoteWithdrawn', installedRemoteWithdrawn, null, 'workshop_version_withdrawn'),
    ('installedCompanionDisabled', installedCompanionDisabled, null, 'workshop_companion_disabled'),
    ('installedOtherOrigin', installedOtherOrigin, null, 'workshop_other_origin'),
    ('installedRestrictedNewVersion', installedRestrictedNewVersion, null, 'workshop_min_app'),
    ('installedWithdrawnOldVersionHasUpdate', installedWithdrawnOldVersionHasUpdate, 'workshop_pet_not_a_pack', null),
  ];
  for (final (name, factory, localIssue, remoteUnavailable) in installedRows) {
    _sample(name, factory, (state) {
      _installed(state);
      final row = state.rows.single;
      expect(row.localIssue, localIssue);
      expect(row.remoteUnavailable, remoteUnavailable);
      expect(row.canUninstall, !name.startsWith('installedUntrusted'));
      if (name == 'installedOtherOrigin') {
        expect(row.remoteKnown, isTrue);
        expect(row.publicEntry, isNull);
        expect((row.local as WorkshopInstalled).receipt.origin.host, 'other-workshop.example');
      }
      if (name == 'installedRemoteWithdrawn') {
        expect(row.publicEntry, isNull);
        expect(row.installedWithdrawn, isTrue);
      }
      if (name == 'installedRestrictedNewVersion' || name == 'installedWithdrawnOldVersionHasUpdate') {
        expect(row.installedWithdrawn, isTrue);
        expect(row.updateAvailable, name == 'installedWithdrawnOldVersionHasUpdate');
      }
    });
  }
  _sample('installedEmpty', installedEmpty, (state) { _installed(state); expect(state.rows, isEmpty); expect(state.loadError, isNull); });
  _sample('installedInitial', installedInitial, (state) { _installed(state); expect(state.loading, isTrue); expect(state.rows, isEmpty); });
  _sample('installedWithoutWorker', installedWithoutWorker, (state) {
    _installed(state);
    expect(state.rows.single.canUninstall, isTrue);
    expect(state.rows.single.remoteKnown, isFalse);
    expect(state.catalogError, 'workshop_unconfigured');
  });
  _sample('installedLocalBeforeCatalog', installedLocalBeforeCatalog, (state) {
    _installed(state);
    expect(state.rows.single.canUninstall, isTrue);
    expect(state.rows.single.remoteKnown, isFalse);
    expect(state.catalogError, isNull);
  });
  _sample('installedCatalogFailedKeepsLocal', installedCatalogFailedKeepsLocal, (state) {
    _installed(state);
    expect(state.rows, hasLength(1));
    expect(state.rows.single.remoteKnown, isFalse);
    expect(state.catalogError, 'workshop_network');
    expect(state.loadError, isNull);
  });
  _sample('installedLocalReadFailed', installedLocalReadFailed, (state) {
    _installed(state);
    expect(state.rows, isEmpty);
    expect(state.loadError, 'workshop_storage');
  });
  _sample('installedRefreshFailedKeepsRows', installedRefreshFailedKeepsRows, (state) {
    _installed(state);
    expect(state.rows, hasLength(1));
    expect(state.loadError, 'workshop_storage');
  });
  _sample('installedRefreshingKeepsRows', installedRefreshingKeepsRows, (state) {
    _installed(state); expect(state.refreshing, isTrue); expect(state.loading, isFalse);
    expect(state.rows, hasLength(1)); expect(state.loadError, isNull);
  });
  final removalCases = <(String, Future<WorkshopInstalledListState> Function(), WorkshopRemovalPhase)>[
    ('installedRemoving', installedRemoving, WorkshopRemovalPhase.removing),
    ('installedRemovalSucceeded', installedRemovalSucceeded, WorkshopRemovalPhase.succeeded),
    ('installedRemovalFailed', installedRemovalFailed, WorkshopRemovalPhase.failed),
    ('installedRemovalRefreshFailed', installedRemovalRefreshFailed, WorkshopRemovalPhase.succeeded),
    ('installedUntrustedRemovalRefused', installedUntrustedRemovalRefused, WorkshopRemovalPhase.failed),
  ];
  for (final (name, factory, phase) in removalCases) {
    _sample(name, factory, (state) {
      _installed(state);
      expect(state.removal.phase, phase);
      expect(state.removal.target, isNotNull);
      expect(state.rows.length, phase == WorkshopRemovalPhase.succeeded ? 0 : 1);
      expect(state.removal.refreshError, name == 'installedRemovalRefreshFailed' ? 'workshop_local_refresh' : null);
      expect(state.removal.error, switch (name) {
        'installedRemovalFailed' => 'workshop_install_conflict',
        'installedUntrustedRemovalRefused' => 'workshop_install_record',
        _ => null,
      });
    });
  }
}
