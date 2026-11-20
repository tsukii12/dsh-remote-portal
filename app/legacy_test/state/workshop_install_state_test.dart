import 'dart:async';

import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/state/workshop_install_state.dart';
import 'package:dsh_app/state/workshop_installed_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workshop_state_support.dart';

void main() {
  test('progress and verification precede a success and local list refresh', () async {
    final packages = StatePackages()..rows = [stateInstalled()];
    final client = StateClient(), repository = StateRepository(client, packages);
    final entered = Completer<void>(), release = Completer<void>();
    late StateInstallCall call;
    repository.installAction = (value) async {
      call = value;
      entered.complete();
      await release.future;
      return repository.commit(value);
    };
    final notices = <({WorkshopInstalled item, bool removed})>[];
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)],
      changed: (item, {required removed}) async => notices.add((item: item, removed: removed)));
    final controller = container.read(workshopInstallProvider.notifier);
    final pending = controller.install(stateEntry());
    // Observe the actual operation before any assertion can fail.
    final operationSettled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      call.onProgress!(const DownloadProgress(received: 2, total: 4, source: 'Workshop'));
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.downloading);
      expect(container.read(workshopInstallProvider).received, 2);
      expect(container.read(workshopInstallProvider).total, 4);
      call.onVerifying!();
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.verifying);
      release.complete();
      expect(await pending, isTrue);
      final state = container.read(workshopInstallProvider);
      expect(state.phase, WorkshopInstallPhase.succeeded);
      expect(state.result!.receipt.version, '2.0.0');
      expect(state.error, isNull);
      expect(notices, [(item: state.result!, removed: false)]);
      expect(container.read(workshopInstalledProvider).rows.single.local, same(state.result));
      expect(container.read(workshopItemProvider('pet/cat'))!.updateAvailable, isFalse);
      expect(container.read(workshopMutationProvider), isNull);
    } finally {
      if (!release.isCompleted) release.complete();
      await operationSettled;
      container.dispose();
    }
  });

  test('cancel remains pending until the repository acknowledges cancellation', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages);
    final entered = Completer<void>(), sawCancel = Completer<void>(), release = Completer<void>();
    repository.installAction = (call) async {
      entered.complete();
      await call.cancel!.whenCancelled;
      sawCancel.complete();
      await release.future;
      throw const WorkshopException('workshop_cancelled');
    };
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)]);
    final controller = container.read(workshopInstallProvider.notifier);
    final pending = controller.install(stateEntry());
    final operationSettled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      controller.cancel();
      await stateSignal(sawCancel, pending);
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.cancelling);
      expect(container.read(workshopMutationProvider), isNotNull);
      release.complete();
      await pending;
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.cancelled);
      expect(container.read(workshopInstallProvider).error, 'workshop_cancelled');
      expect(packages.installedCalls, isEmpty);
    } finally {
      controller.cancel();
      if (!release.isCompleted) release.complete();
      await operationSettled;
      container.dispose();
    }
  });

  test('a commit wins over a cancellation requested after installer handoff', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages);
    final entered = Completer<void>(), release = Completer<void>();
    repository.installAction = (call) async {
      entered.complete();
      await release.future;
      return repository.commit(call);
    };
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)],
      changed: (item, {required removed}) async { throw StateError('refresh failed'); });
    final controller = container.read(workshopInstallProvider.notifier);
    final pending = controller.install(stateEntry());
    final settled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      controller.cancel();
      release.complete();
      await pending;
      final state = container.read(workshopInstallProvider);
      expect(state.phase, WorkshopInstallPhase.succeeded);
      expect(state.result, isNotNull);
      expect(state.error, isNull);
      expect(state.refreshError, 'workshop_local_refresh');
      expect(packages.rows, hasLength(1));
    } finally {
      if (!release.isCompleted) release.complete();
      await settled;
      container.dispose();
    }
  });

  test('replacement permission is tied to its offer and starts a new repository call', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages);
    repository.installAction = (call) async {
      if (!call.replaceExisting) throw const WorkshopException('workshop_install_conflict');
      return repository.commit(call);
    };
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)]);
    try {
      final controller = container.read(workshopInstallProvider.notifier);
      await controller.install(stateEntry());
      final first = container.read(workshopInstallProvider).replacement!;
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.awaitingReplacement);
      expect(container.read(workshopMutationProvider), isNull);
      await controller.install(stateEntry(id: 'dog'));
      final second = container.read(workshopInstallProvider).replacement!;
      expect(await controller.confirmReplacement(first), isFalse);
      expect(repository.calls, hasLength(2));
      expect(await controller.confirmReplacement(second), isTrue);
      expect(repository.calls, hasLength(3));
      expect(repository.calls.last.entry, same(second.entry));
      expect(repository.calls.last.replaceExisting, isTrue);
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.succeeded);
      expect(await controller.confirmReplacement(second), isFalse);
    } finally { container.dispose(); }
  });

  test('declining replacement does not install and a downgrade has no confirmation', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages)
      ..installAction = (_) async => throw const WorkshopException('workshop_install_conflict');
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)]);
    try {
      final controller = container.read(workshopInstallProvider.notifier);
      await controller.install(stateEntry());
      final request = container.read(workshopInstallProvider).replacement!;
      expect(controller.declineReplacement(request), isTrue);
      expect(controller.declineReplacement(request), isFalse);
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.idle);
      expect(repository.calls, hasLength(1));
      repository.installAction = (_) async => throw const WorkshopException('workshop_downgrade');
      await controller.install(stateEntry());
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.failed);
      expect(container.read(workshopInstallProvider).error, 'workshop_downgrade');
      expect(container.read(workshopInstallProvider).replacement, isNull);
    } finally { container.dispose(); }
  });

  test('no-space failure has a stable code and no committed result', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages)
      ..installAction = (_) async => throw const WorkshopException('workshop_no_space');
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)]);
    try {
      await container.read(workshopInstallProvider.notifier).install(stateEntry());
      final state = container.read(workshopInstallProvider);
      expect(state.phase, WorkshopInstallPhase.failed);
      expect(state.error, 'workshop_no_space');
      expect(state.result, isNull);
      expect(packages.installedCalls, isEmpty);
      expect(container.read(workshopMutationProvider), isNull);
    } finally { container.dispose(); }
  });

  test('a second explicit install retries a failed repository factory', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages);
    var attempts = 0;
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)],
      loadRepository: (source) async {
        attempts++;
        if (attempts == 1) throw const WorkshopException('workshop_storage');
        return source.repository;
      });
    try {
      final controller = container.read(workshopInstallProvider.notifier);
      await controller.install(stateEntry());
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.failed);
      expect(container.read(workshopInstallProvider).error, 'workshop_storage');
      expect(attempts, 1);
      expect(repository.calls, isEmpty);
      await controller.install(stateEntry());
      expect(attempts, 2);
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.succeeded);
      expect(repository.calls, hasLength(1));
    } finally { container.dispose(); }
  });

  test('the shared gate rejects another install and uninstall without changing ownership', () async {
    final old = stateInstalled();
    final packages = StatePackages()..rows = [old];
    final client = StateClient(), repository = StateRepository(client, packages);
    final entered = Completer<void>(), release = Completer<void>();
    repository.installAction = (call) async {
      entered.complete();
      await release.future;
      return repository.commit(call);
    };
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)]);
    final controller = container.read(workshopInstallProvider.notifier);
    final entry = stateEntry();
    final pending = controller.install(entry);
    final operationSettled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      final token = container.read(workshopMutationProvider);
      expect(await controller.install(stateEntry(id: 'other')), isFalse);
      expect(await container.read(workshopInstalledProvider.notifier).uninstall(old), isFalse);
      expect(container.read(workshopInstallProvider).entry, same(entry));
      expect(container.read(workshopMutationProvider), same(token));
      expect(repository.calls, hasLength(1));
      expect(packages.removed, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await operationSettled;
      container.dispose();
    }
  });

  test('old-origin commit refreshes local resources without replacing new-source operation state', () async {
    final packages = StatePackages();
    final oldClient = StateClient(), newClient = StateClient(origin: otherStateOrigin);
    final oldRepository = StateRepository(oldClient, packages), newRepository = StateRepository(newClient, packages);
    final entered = Completer<void>(), release = Completer<void>();
    oldRepository.installAction = (call) async {
      entered.complete();
      await release.future;
      return oldRepository.commit(call);
    };
    final notices = <Uri>[];
    final container = stateContainer(packages: packages, sources: [
      StateSource(oldClient, oldRepository), StateSource(newClient, newRepository),
    ], changed: (item, {required removed}) async => notices.add(item.receipt.origin));
    final pending = container.read(workshopInstallProvider.notifier).install(stateEntry());
    final settled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      container.read(stateSourceIndexProvider.notifier).select(1);
      final newController = container.read(workshopInstallProvider.notifier);
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.idle);
      expect(await newController.install(stateEntry(id: 'new')), isFalse);
      expect(oldRepository.calls.single.cancel!.isCancelled, isTrue);
      release.complete();
      await pending;
      expect(notices, [stateOrigin]);
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.idle);
      expect(container.read(workshopInstallProvider).entry, isNull);
      expect(container.read(workshopInstalledProvider).rows.single.local,
        isA<WorkshopInstalled>().having((item) => item.receipt.origin, 'origin', stateOrigin));
      expect(container.read(workshopMutationProvider), isNull);
      expect(await newController.install(stateEntry(id: 'new')), isTrue);
      expect(container.read(workshopInstallProvider).result!.receipt.origin, otherStateOrigin);
    } finally {
      if (!release.isCompleted) release.complete();
      await settled;
      container.dispose();
    }
  });

  test('a post-commit callback is awaited while the mutation remains owned', () async {
    final packages = StatePackages(), client = StateClient();
    final repository = StateRepository(client, packages);
    final entered = Completer<void>(), release = Completer<void>();
    final container = stateContainer(packages: packages, sources: [StateSource(client, repository)],
      changed: (item, {required removed}) async { entered.complete(); await release.future; });
    final controller = container.read(workshopInstallProvider.notifier);
    final pending = controller.install(stateEntry());
    final operationSettled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      expect(packages.rows, hasLength(1));
      expect(container.read(workshopMutationProvider), isNotNull);
      expect(container.read(workshopInstallProvider).phase, isNot(WorkshopInstallPhase.succeeded));
      expect(await controller.install(stateEntry(id: 'another')), isFalse);
      release.complete();
      await pending;
      expect(container.read(workshopInstallProvider).phase, WorkshopInstallPhase.succeeded);
    } finally {
      if (!release.isCompleted) release.complete();
      await operationSettled;
      container.dispose();
    }
  });
}
