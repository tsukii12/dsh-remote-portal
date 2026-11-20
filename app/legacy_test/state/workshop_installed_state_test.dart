import 'dart:async';

import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/state/workshop_installed_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workshop_state_support.dart';

void main() {
  test('local rows appear while catalog networking is still pending', () async {
    final healthy = stateInstalled();
    final brokenPack = stateInstalled(id: 'broken', issue: 'workshop_pet_not_a_pack');
    const issue = WorkshopInstallationIssue(localId: 'user:untrusted', issue: 'workshop_install_record');
    final packages = StatePackages()..rows = [healthy, brokenPack, issue];
    final client = StateClient();
    final network = Completer<WorkshopCatalogSnapshot>(), entered = Completer<void>();
    client.readNetwork = (_) { entered.complete(); return network.future; };
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    final installed = container.read(workshopInstalledProvider.notifier);
    final pending = container.read(workshopCatalogProvider.notifier).ready;
    final settled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      await installed.ready;
      final rows = container.read(workshopInstalledProvider).rows;
      expect(rows.map((row) => row.local), [healthy, brokenPack, issue]);
      expect(rows.map((row) => row.canUninstall), [true, true, false]);
      expect(rows.every((row) => !row.remoteKnown), isTrue);
      expect(rows[1].localIssue, 'workshop_pet_not_a_pack');
      expect(rows[2].remoteUnavailable, isNull);
      expect(rows[2].publicEntry, isNull);
    } finally {
      if (!network.isCompleted) network.complete(stateSnapshot());
      await settled;
      await stateSettled(installed.refresh());
      container.dispose();
    }
  });

  test('without a Worker a trusted broken pack remains removable', () async {
    final entry = stateInstalled(issue: 'workshop_pet_not_a_pack');
    final packages = StatePackages()..rows = [entry];
    final client = StateClient();
    final notices = <({WorkshopInstalled item, bool removed})>[];
    final container = stateContainer(packages: packages, configured: false,
      sources: [StateSource(client, StateRepository(client, packages))],
      changed: (item, {required removed}) async => notices.add((item: item, removed: removed)));
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      final row = container.read(workshopInstalledProvider).rows.single;
      expect(row.local, same(entry));
      expect(row.canUninstall, isTrue);
      expect(row.remoteKnown, isFalse);
      expect(await controller.uninstall(entry), isTrue);
      final after = container.read(workshopInstalledProvider);
      expect(after.rows, isEmpty);
      expect(after.removal.phase, WorkshopRemovalPhase.succeeded);
      expect(packages.removed, [same(entry)]);
      expect(notices, [(item: entry, removed: true)]);
      expect(client.networkReads, 0);
    } finally { container.dispose(); }
  });

  test('explicit local refresh retries a failed packages factory', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry];
    final client = StateClient();
    var attempts = 0;
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))],
      loadPackages: () async {
        attempts++;
        if (attempts == 1) throw const WorkshopException('workshop_storage');
        return packages;
      });
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      expect(attempts, 1);
      expect(container.read(workshopInstalledProvider).loadError, 'workshop_storage');
      await controller.refresh();
      expect(attempts, 2);
      expect(container.read(workshopInstalledProvider).loadError, isNull);
      expect(container.read(workshopInstalledProvider).rows.single.local, same(entry));
    } finally { container.dispose(); }
  });

  test('local issues stay separate from withdrawal disabled and other-origin states', () async {
    final withdrawn = stateInstalled(issue: 'workshop_pet_not_a_pack');
    final companion = stateInstalled(kind: 'companion', id: 'model');
    final other = stateInstalled(id: 'other', origin: otherStateOrigin);
    const issue = WorkshopInstallationIssue(localId: 'user:bad-receipt', issue: 'workshop_install_record');
    final packages = StatePackages()..rows = [withdrawn, companion, other, issue];
    final client = StateClient()..network = stateSnapshot(stale: true,
      refreshError: const WorkshopException('workshop_network'), companion: false,
      entries: [stateEntry(blocked: ['1.0.0']), stateEntry(id: 'other')]);
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      await controller.refresh();
      final state = container.read(workshopInstalledProvider), rows = state.rows;
      expect(rows[0].localIssue, 'workshop_pet_not_a_pack');
      expect(rows[0].installedWithdrawn, isTrue);
      expect(rows[0].updateAvailable, isTrue);
      expect(rows[1].remoteUnavailable, 'workshop_companion_disabled');
      expect(rows[2].remoteUnavailable, 'workshop_other_origin');
      expect(rows[2].publicEntry, isNull);
      expect(rows.take(3).every((row) => row.canUninstall), isTrue);
      expect(rows[3].localIssue, 'workshop_install_record');
      expect(rows[3].remoteKnown, isFalse);
      expect(rows[3].remoteUnavailable, isNull);
      expect(rows[3].installedWithdrawn, isNull);
      expect(state.catalogStale, isTrue);
      expect(state.catalogError, 'workshop_network');
    } finally { container.dispose(); }
  });

  test('an issue-only row is rejected before packages.remove', () async {
    const issue = WorkshopInstallationIssue(localId: 'user:broken', issue: 'workshop_install_record');
    final packages = StatePackages()..rows = [issue];
    final client = StateClient();
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      expect(await controller.uninstall(issue), isTrue);
      expect(packages.removed, isEmpty);
      expect(container.read(workshopInstalledProvider).removal.phase, WorkshopRemovalPhase.failed);
      expect(container.read(workshopInstalledProvider).removal.error, 'workshop_install_record');
      expect(container.read(workshopInstalledProvider).rows.single.local, same(issue));
      expect(container.read(workshopMutationProvider), isNull);
    } finally { container.dispose(); }
  });

  test('failed removal retains its target and can be retried', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry]
      ..removeAction = (_) async => throw const WorkshopException('workshop_install_conflict');
    final client = StateClient();
    var notices = 0;
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))],
      changed: (item, {required removed}) async { notices++; });
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      await controller.uninstall(entry);
      expect(container.read(workshopInstalledProvider).removal.error, 'workshop_install_conflict');
      expect(container.read(workshopInstalledProvider).rows.single.local, same(entry));
      expect(notices, 0);
      packages.removeAction = null;
      await controller.uninstall(entry);
      expect(container.read(workshopInstalledProvider).removal.phase, WorkshopRemovalPhase.succeeded);
      expect(container.read(workshopInstalledProvider).rows, isEmpty);
      expect(notices, 1);
    } finally { container.dispose(); }
  });

  test('post-commit refresh failure does not turn removal into a failure', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry];
    final client = StateClient();
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))],
      changed: (item, {required removed}) async { throw StateError('refresh failed'); });
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      await controller.uninstall(entry);
      final removal = container.read(workshopInstalledProvider).removal;
      expect(removal.phase, WorkshopRemovalPhase.succeeded);
      expect(removal.error, isNull);
      expect(removal.refreshError, 'workshop_local_refresh');
      expect(packages.rows, isEmpty);
      expect(container.read(workshopInstalledProvider).rows, isEmpty);
    } finally { container.dispose(); }
  });

  for (final fails in [false, true]) {
    test('acknowledges ${fails ? 'failed' : 'successful'} removal without I/O or gate changes', () async {
      final entry = stateInstalled();
      final packages = StatePackages()..rows = [entry];
      var reads = 0, notices = 0;
      packages.list = () async {
        reads++;
        return List<WorkshopLocalEntry>.of(packages.rows);
      };
      if (fails) {
        packages.removeAction = (_) async => throw const WorkshopException('workshop_install_conflict');
      }
      final client = StateClient();
      final container = stateContainer(packages: packages, configured: false,
        sources: [StateSource(client, StateRepository(client, packages))],
        changed: (item, {required removed}) async {
          notices++;
          if (!fails) {
            throw StateError('refresh failed');
          }
        });
      final gate = container.read(workshopMutationProvider.notifier);
      WorkshopMutation? token;
      try {
        final controller = container.read(workshopInstalledProvider.notifier);
        await controller.ready;
        await container.read(workshopCatalogProvider.notifier).ready;
        expect(controller.acknowledgeRemoval(), isFalse);
        expect(await controller.uninstall(entry), isTrue);
        final terminal = container.read(workshopInstalledProvider).removal;
        expect(terminal.phase, fails ? WorkshopRemovalPhase.failed : WorkshopRemovalPhase.succeeded);
        expect(terminal.target, same(entry));
        expect(terminal.error, fails ? 'workshop_install_conflict' : null);
        expect(terminal.refreshError, fails ? null : 'workshop_local_refresh');
        await controller.refresh();
        expect(container.read(workshopInstalledProvider).removal, same(terminal));

        token = gate.claim(WorkshopMutationKind.install, 'another-install');
        expect(token, isNotNull);
        final before = container.read(workshopInstalledProvider);
        final calls = (reads, notices, packages.removed.length, packages.installedCalls.length,
          client.cacheReads, client.networkReads);
        expect(controller.acknowledgeRemoval(), isTrue);
        final after = container.read(workshopInstalledProvider);
        expect(after.removal.phase, WorkshopRemovalPhase.idle);
        expect(after.removal.target, isNull);
        expect(after.removal.error, isNull);
        expect(after.removal.refreshError, isNull);
        expect(after.rows, before.rows);
        expect((after.loading, after.refreshing, after.loadError, after.catalogError, after.catalogStale),
          (before.loading, before.refreshing, before.loadError, before.catalogError, before.catalogStale));
        expect(container.read(workshopMutationProvider), same(token));
        expect((reads, notices, packages.removed.length, packages.installedCalls.length,
          client.cacheReads, client.networkReads), calls);
        expect(controller.acknowledgeRemoval(), isFalse);
        expect(container.read(workshopInstalledProvider), same(after));
      } finally {
        if (token != null) {
          gate.release(token);
        }
        container.dispose();
      }
    });
  }

  test('a synchronous terminal listener can acknowledge before the removal releases its gate', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry];
    final client = StateClient();
    final container = stateContainer(packages: packages, configured: false,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      var terminalCount = 0;
      var acknowledged = false;
      WorkshopMutation? beforeAck, afterAck;
      final subscription = container.listen(workshopInstalledProvider, (previous, next) {
        if (next.removal.phase == WorkshopRemovalPhase.succeeded) {
          terminalCount++;
          beforeAck = container.read(workshopMutationProvider);
          acknowledged = controller.acknowledgeRemoval();
          afterAck = container.read(workshopMutationProvider);
        }
      });
      try {
        expect(await controller.uninstall(entry), isTrue);
        expect(terminalCount, 1);
        expect(acknowledged, isTrue);
        expect(beforeAck?.kind, WorkshopMutationKind.uninstall);
        expect(afterAck, same(beforeAck));
        expect(container.read(workshopInstalledProvider).removal.phase, WorkshopRemovalPhase.idle);
        expect(container.read(workshopMutationProvider), isNull);
        expect(packages.removed, [same(entry)]);
      } finally {
        subscription.close();
      }
    } finally {
      container.dispose();
    }
  });

  test('acknowledgement cannot clear a removal that is still in progress', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry];
    final entered = Completer<void>(), release = Completer<void>();
    packages.removeAction = (_) {
      entered.complete();
      return release.future;
    };
    final client = StateClient();
    final container = stateContainer(packages: packages, configured: false,
      sources: [StateSource(client, StateRepository(client, packages))]);
    final settled = <Future<void>>[];
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      await container.read(workshopCatalogProvider.notifier).ready;
      final pending = controller.uninstall(entry);
      settled.add(stateSettled(pending));
      await stateSignal(entered, pending);
      final before = container.read(workshopInstalledProvider);
      final token = container.read(workshopMutationProvider);
      expect(before.removal.phase, WorkshopRemovalPhase.removing);
      expect(before.removal.target, same(entry));
      expect(controller.acknowledgeRemoval(), isFalse);
      expect(container.read(workshopInstalledProvider), same(before));
      expect(container.read(workshopMutationProvider), same(token));
      release.complete();
      expect(await pending, isTrue);
      expect(container.read(workshopInstalledProvider).removal.phase, WorkshopRemovalPhase.succeeded);
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
      await Future.wait(settled);
      container.dispose();
    }
  });

  test('a local refresh failure retains rows and a later refresh clears the error', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry];
    final client = StateClient();
    final container = stateContainer(packages: packages, configured: false,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopInstalledProvider.notifier);
      await controller.ready;
      packages.list = () async => throw const WorkshopException('workshop_storage');
      await controller.refresh();
      expect(container.read(workshopInstalledProvider).rows.single.local, same(entry));
      expect(container.read(workshopInstalledProvider).loadError, 'workshop_storage');
      expect(container.read(workshopInstalledProvider).refreshing, isFalse);
      packages.list = null;
      await controller.refresh();
      expect(container.read(workshopInstalledProvider).loadError, isNull);
    } finally { container.dispose(); }
  });

  for (final localFails in [false, true]) {
    test('catalog change during a local read: ${localFails ? 'failure drops the old projection' : 'success uses the latest snapshot'}', () async {
      final entry = stateInstalled();
      final packages = StatePackages()..rows = [entry];
      final client = StateClient();
      final container = stateContainer(packages: packages,
        sources: [StateSource(client, StateRepository(client, packages))]);
      final controller = container.read(workshopInstalledProvider.notifier);
      final catalog = container.read(workshopCatalogProvider.notifier);
      final local = Completer<List<WorkshopLocalEntry>>(), entered = Completer<void>();
      final settled = <Future<void>>[];
      try {
        await controller.ready;
        await catalog.ready;
        await controller.refresh();
        expect(container.read(workshopInstalledProvider).rows.single.installedWithdrawn, isFalse);
        var held = false;
        packages.list = () {
          if (!held) {
            held = true;
            entered.complete();
            return local.future;
          }
          return Future.value(List<WorkshopLocalEntry>.of(packages.rows));
        };
        final pending = controller.refresh();
        settled.add(stateSettled(pending));
        await stateSignal(entered, pending);
        client.network = stateSnapshot(entries: [stateEntry(blocked: ['1.0.0'])]);
        final updated = catalog.refresh();
        settled.add(stateSettled(updated));
        await updated;
        expect(container.read(workshopInstalledProvider).rows.single.local, same(entry));
        if (localFails) {
          local.completeError(const WorkshopException('workshop_storage'));
        } else {
          local.complete([entry]);
        }
        await pending;
        final state = container.read(workshopInstalledProvider), row = state.rows.single;
        expect(state.refreshing, isFalse);
        expect(row.local, same(entry));
        expect(row.canUninstall, isTrue);
        if (localFails) {
          expect(state.loadError, 'workshop_storage');
          expect(row.remoteKnown, isFalse);
          expect(row.installedWithdrawn, isNull);
          expect(row.publicEntry, isNull);
          expect(state.catalogStale, isNull);
          packages.list = null;
          await controller.refresh();
          expect(container.read(workshopInstalledProvider).loadError, isNull);
          expect(container.read(workshopInstalledProvider).rows.single.installedWithdrawn, isTrue);
        } else {
          expect(state.loadError, isNull);
          expect(row.remoteKnown, isTrue);
          expect(row.installedWithdrawn, isTrue);
        }
      } finally {
        if (!local.isCompleted) local.complete([entry]);
        await Future.wait(settled);
        await stateSettled(controller.refresh());
        container.dispose();
      }
    });
  }

  for (final projectionFails in [false, true]) {
    test('directory failure during enrichment: ${projectionFails ? 'projection failure stays distinct' : 'latest network error survives'}', () async {
      final entry = stateInstalled();
      final packages = StatePackages()..rows = [entry];
      final client = StateClient();
      final container = stateContainer(packages: packages,
        sources: [StateSource(client, StateRepository(client, packages))]);
      final controller = container.read(workshopInstalledProvider.notifier);
      final catalog = container.read(workshopCatalogProvider.notifier);
      final projected = Completer<List<WorkshopLocalEntry>>(), entered = Completer<void>();
      final settled = <Future<void>>[];
      try {
        await controller.ready;
        await catalog.ready;
        await controller.refresh();
        var reads = 0;
        packages.list = () {
          // The first read belongs to _readLocal; the second is the real
          // repository.installedStates projection, held independently of HTTP.
          if (++reads == 2) {
            entered.complete();
            return projected.future;
          }
          return Future.value(List<WorkshopLocalEntry>.of(packages.rows));
        };
        final pending = controller.refresh();
        settled.add(stateSettled(pending));
        await stateSignal(entered, pending);
        final snapshot = container.read(workshopCatalogProvider).snapshot;
        client.readNetwork = (_) async => throw const WorkshopException('workshop_network');
        final failed = catalog.refresh();
        settled.add(stateSettled(failed));
        await failed;
        expect(container.read(workshopCatalogProvider).snapshot, same(snapshot));
        expect(container.read(workshopInstalledProvider).catalogError, 'workshop_network');
        if (projectionFails) {
          projected.completeError(const WorkshopException('workshop_storage'));
        } else {
          projected.complete([entry]);
        }
        await pending;
        final state = container.read(workshopInstalledProvider);
        expect(state.loadError, isNull);
        expect(state.refreshing, isFalse);
        expect(state.rows.single.local, same(entry));
        expect(state.rows.single.remoteKnown, !projectionFails);
        expect(state.catalogError, projectionFails ? 'workshop_storage' : 'workshop_network');
      } finally {
        if (!projected.isCompleted) projected.complete([entry]);
        await Future.wait(settled);
        await stateSettled(controller.refresh());
        container.dispose();
      }
    });
  }

  test('enrichment does not restore an error cleared by a still-pending catalog refresh', () async {
    final entry = stateInstalled();
    final packages = StatePackages()..rows = [entry];
    final client = StateClient()..network = stateSnapshot(stale: true,
      refreshError: const WorkshopException('workshop_timeout'));
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    final controller = container.read(workshopInstalledProvider.notifier);
    final catalog = container.read(workshopCatalogProvider.notifier);
    final projected = Completer<List<WorkshopLocalEntry>>(), entered = Completer<void>();
    final network = Completer<WorkshopCatalogSnapshot>(), networkEntered = Completer<void>();
    final settled = <Future<void>>[];
    try {
      await controller.ready;
      await catalog.ready;
      await controller.refresh();
      expect(container.read(workshopInstalledProvider).catalogError, 'workshop_timeout');
      var reads = 0;
      packages.list = () {
        if (++reads == 2) {
          entered.complete();
          return projected.future;
        }
        return Future.value(List<WorkshopLocalEntry>.of(packages.rows));
      };
      final pending = controller.refresh();
      settled.add(stateSettled(pending));
      await stateSignal(entered, pending);
      client.readNetwork = (_) {
        networkEntered.complete();
        return network.future;
      };
      final refreshing = catalog.refresh();
      settled.add(stateSettled(refreshing));
      await stateSignal(networkEntered, refreshing);
      projected.complete([entry]);
      await pending;
      expect(container.read(workshopCatalogProvider).refreshing, isTrue);
      expect(container.read(workshopInstalledProvider).rows.single.remoteKnown, isTrue);
      expect(container.read(workshopInstalledProvider).catalogError, isNull);
      network.completeError(const WorkshopException('workshop_network'));
      await refreshing;
      expect(container.read(workshopInstalledProvider).catalogError, 'workshop_network');
    } finally {
      if (!projected.isCompleted) projected.complete([entry]);
      if (!network.isCompleted) network.complete(stateSnapshot());
      await Future.wait(settled);
      await stateSettled(controller.refresh());
      container.dispose();
    }
  });
}
