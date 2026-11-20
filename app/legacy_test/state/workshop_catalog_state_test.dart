import 'dart:async';

import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workshop_state_support.dart';

void main() {
  test('cached metadata is visible while receipt projection is waiting', () async {
    final packages = StatePackages();
    final entered = Completer<void>(), release = Completer<void>();
    packages.list = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return [];
    };
    final client = StateClient()..cached = stateSnapshot(stale: true);
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    final pending = container.read(workshopCatalogProvider.notifier).ready;
    final settled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      final state = container.read(workshopCatalogProvider);
      expect(state.snapshot!.stale, isTrue);
      expect(state.items.single.entry.metadata.identity, 'pet/cat');
      expect(state.localStateKnown, isFalse);
      expect(state.loading, isFalse);
      expect(state.refreshing, isTrue);
      release.complete();
      await pending;
      expect(container.read(workshopCatalogProvider).localStateKnown, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      await settled;
      container.dispose();
    }
  });

  test('publishes cached item states before the network settles', () async {
    final packages = StatePackages()..rows = [stateInstalled()];
    final client = StateClient()..cached = stateSnapshot(stale: true);
    final repository = StateRepository(client, packages);
    final networkEntered = Completer<void>();
    final network = Completer<WorkshopCatalogSnapshot>();
    client.readNetwork = (_) {
      networkEntered.complete();
      return network.future;
    };
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)]);
    final controller = container.read(workshopCatalogProvider.notifier);
    final pending = controller.ready, settled = stateSettled(controller.ready);
    try {
      await stateSignal(networkEntered, pending);
      final cached = container.read(workshopCatalogProvider);
      expect(cached.snapshot!.stale, isTrue);
      expect(cached.refreshing, isTrue);
      expect(cached.localStateKnown, isTrue);
      expect(cached.items.single.updateAvailable, isTrue);
      expect(client.events, ['cache', 'network']);
      network.complete(stateSnapshot(entries: [stateEntry(version: '3.0.0')]));
      await pending;
      expect(container.read(workshopCatalogProvider).items.single.entry.metadata.version, '3.0.0');
      expect(container.read(workshopCatalogProvider).refreshing, isFalse);
    } finally {
      if (!network.isCompleted) network.complete(stateSnapshot());
      await settled;
      container.dispose();
    }
  });

  test('offline without a usable copy exposes stable error and cache issue', () async {
    final packages = StatePackages();
    final client = StateClient()..issue = 'workshop_cache_storage'
      ..readNetwork = (_) async => throw const WorkshopException('workshop_network');
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      await container.read(workshopCatalogProvider.notifier).ready;
      final state = container.read(workshopCatalogProvider);
      expect(state.items, isEmpty);
      expect(state.snapshot, isNull);
      expect(state.refreshError, 'workshop_network');
      expect(state.cacheIssue, 'workshop_cache_storage');
      expect(state.loading, isFalse);
    } finally { container.dispose(); }
  });

  test('explicit refresh retries a failed client factory without an automatic loop', () async {
    final packages = StatePackages(), client = StateClient();
    var attempts = 0;
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))],
      loadClient: (source) async {
        attempts++;
        if (attempts == 1) throw const WorkshopException('workshop_storage');
        return source.client;
      });
    try {
      final controller = container.read(workshopCatalogProvider.notifier);
      await controller.ready;
      expect(container.read(workshopCatalogProvider).refreshError, 'workshop_storage');
      expect(attempts, 1);
      expect(client.networkReads, 0);
      await controller.refresh();
      expect(attempts, 2);
      expect(container.read(workshopCatalogProvider).refreshError, isNull);
      expect(container.read(workshopCatalogProvider).items, hasLength(1));
      expect(client.networkReads, 1);
    } finally { container.dispose(); }
  });

  test('a refresh failure keeps the previous catalog and item projection', () async {
    final packages = StatePackages()..rows = [stateInstalled()];
    final client = StateClient();
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopCatalogProvider.notifier);
      await controller.ready;
      final before = container.read(workshopCatalogProvider);
      client.readNetwork = (_) async => throw const WorkshopException('workshop_timeout');
      await controller.refresh();
      final after = container.read(workshopCatalogProvider);
      expect(after.snapshot, same(before.snapshot));
      expect(after.items.single, same(before.items.single));
      expect(after.refreshError, 'workshop_timeout');
      expect(after.refreshing, isFalse);
    } finally { container.dispose(); }
  });

  test('kind and name or author filtering share the unfiltered detail state', () async {
    final packages = StatePackages();
    final client = StateClient()..network = stateSnapshot(companion: false, entries: [
      stateEntry(author: 'Alice', en: 'Golden Cat'),
      stateEntry(kind: 'companion', id: 'model', zh: '角色', en: 'Model', author: 'Bob'),
      stateEntry(id: 'new-app', minApp: '9.0.0'),
      stateEntry(kind: 'future', id: 'unknown'),
      stateEntry(id: 'withdrawn', blocked: ['2.0.0']),
    ]);
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopCatalogProvider.notifier);
      await controller.ready;
      final original = container.read(workshopCatalogProvider).items.first;
      controller.setQuery(' ALICE ');
      expect(container.read(workshopCatalogProvider).visibleItems, [original]);
      controller.setQuery('小猫');
      expect(container.read(workshopCatalogProvider).visibleItems, contains(original));
      controller.setQuery('golden');
      expect(container.read(workshopCatalogProvider).visibleItems, [original]);
      controller.setKind(WorkshopKindFilter.companion);
      expect(container.read(workshopCatalogProvider).visibleItems, isEmpty);
      controller.setQuery('');
      expect(container.read(workshopCatalogProvider).visibleItems.single.entry.metadata.kind, 'companion');
      expect(container.read(workshopItemProvider('pet/cat')), same(original));
      expect(container.read(workshopItemProvider('companion/model'))!.unavailable, 'workshop_companion_disabled');
      expect(container.read(workshopItemProvider('pet/new-app'))!.unavailable, 'workshop_min_app');
      expect(container.read(workshopItemProvider('future/unknown'))!.unavailable, 'workshop_unsupported_kind');
      expect(container.read(workshopItemProvider('pet/withdrawn'))!.unavailable, 'workshop_version_withdrawn');
      expect(container.read(workshopItemProvider('pet/absent')), isNull);
    } finally { container.dispose(); }
  });

  test('local projection failure keeps public metadata and marks installation unknown', () async {
    final packages = StatePackages()..list = () async => throw const WorkshopException('workshop_storage');
    final client = StateClient();
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    try {
      final controller = container.read(workshopCatalogProvider.notifier);
      await controller.ready;
      expect(container.read(workshopCatalogProvider).items.single.entry.metadata.identity, 'pet/cat');
      expect(container.read(workshopCatalogProvider).localStateKnown, isFalse);
      expect(container.read(workshopCatalogProvider).localError, 'workshop_storage');
      packages.list = null;
      packages.rows = [stateInstalled()];
      await controller.reloadLocal();
      expect(container.read(workshopCatalogProvider).localStateKnown, isTrue);
      expect(container.read(workshopCatalogProvider).localError, isNull);
      expect(container.read(workshopCatalogProvider).items.single.updateAvailable, isTrue);
      expect(client.networkReads, 1);
    } finally { container.dispose(); }
  });

  test('old-origin completion cannot overwrite the new catalog', () async {
    final packages = StatePackages();
    final oldClient = StateClient(), newClient = StateClient(origin: otherStateOrigin);
    final entered = Completer<void>(), oldResult = Completer<WorkshopCatalogSnapshot>();
    oldClient.readNetwork = (_) { entered.complete(); return oldResult.future; };
    newClient.network = stateSnapshot(entries: [stateEntry(id: 'new-origin')]);
    final container = stateContainer(packages: packages, sources: [
      StateSource(oldClient, StateRepository(oldClient, packages)),
      StateSource(newClient, StateRepository(newClient, packages)),
    ]);
    final oldPending = container.read(workshopCatalogProvider.notifier).ready;
    final oldSettled = stateSettled(oldPending);
    try {
      await stateSignal(entered, oldPending);
      container.read(stateSourceIndexProvider.notifier).select(1);
      // Do not read the new catalog first: the old completion itself must
      // flush the pending dependency change before checking its generation.
      oldResult.complete(stateSnapshot(entries: [stateEntry(id: 'late-old')]));
      await oldPending;
      await container.read(workshopCatalogProvider.notifier).ready;
      final state = container.read(workshopCatalogProvider);
      expect(state.origin, otherStateOrigin);
      expect(state.items.single.entry.metadata.id, 'new-origin');
    } finally {
      if (!oldResult.isCompleted) oldResult.complete(stateSnapshot());
      await oldSettled;
      container.dispose();
    }
  });

  test('overlapping refresh requests share one network operation', () async {
    final packages = StatePackages(), client = StateClient();
    final container = stateContainer(packages: packages,
      sources: [StateSource(client, StateRepository(client, packages))]);
    final gate = Completer<WorkshopCatalogSnapshot>();
    Future<void>? one, two;
    try {
      final controller = container.read(workshopCatalogProvider.notifier);
      await controller.ready;
      client.readNetwork = (_) => gate.future;
      one = controller.refresh();
      two = controller.refresh();
      final settled = [stateSettled(one), stateSettled(two)];
      gate.complete(stateSnapshot());
      await Future.wait([one, two]);
      await Future.wait(settled);
      expect(client.networkReads, 2, reason: 'one initial request and one shared refresh');
    } finally {
      if (!gate.isCompleted) gate.complete(stateSnapshot());
      if (one != null) await stateSettled(one);
      if (two != null) await stateSettled(two);
      container.dispose();
    }
  });
}
