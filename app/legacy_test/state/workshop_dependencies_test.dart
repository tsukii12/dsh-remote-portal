import 'dart:async';
import 'dart:io';

import 'package:dsh_app/pets/overlay_channel.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _worker = Uri.parse('https://workshop.example');
Matcher _error(String code) => throwsA(isA<WorkshopException>().having((error) => error.code, 'code', code));
Future<void> _settled<T>(Future<T> pending) => pending.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
Future<void> _signal<T>(Completer<void> signal, Future<T> pending) => Future.any([
  signal.future,
  pending.then<void>((_) {
    if (!signal.isCompleted) fail('Dependency operation ended before the expected signal');
  }),
]);

class _Http extends WorkshopHttp {
  int closes = 0;
  @override
  void close() { closes++; }
  @override
  Future<UpdateHttpResponse> request(String method, Uri url, {Map<String, String> headers = const {},
    List<int>? body, Duration timeout = const Duration(seconds: 30)}) async => throw StateError('Unexpected HTTP');
}

class _Packages implements WorkshopPackages {
  @override
  Future<List<WorkshopLocalEntry>> installed() async => [];
  @override
  Future<int> copyOverhead(String kind) async => 0;
  @override
  Future<WorkshopInstalled> install(File archive, WorkshopReceipt receipt, {required bool replaceExisting}) async =>
    throw StateError('Dependency tests do not install');
  @override
  Future<void> remove(WorkshopInstalled installed) async => throw StateError('Dependency tests do not remove');
}

final _retryProvider = Provider<void Function(bool)>((ref) =>
  (includeLocal) => retryWorkshopDependencies(ref, includeLocal: includeLocal));

class _PetPreferences extends PetPrefsController {
  _PetPreferences(this.initial);
  final PetPrefs initial;
  final started = Completer<void>();
  final replacements = <String>[];
  bool restored = false;
  @override
  PetPrefs build() { if (!started.isCompleted) started.complete(); return initial; }
  void restore(PetPrefs value) { restored = true; state = value; }
  @override
  Future<void> replacePack(String id) async {
    replacements.add(id);
    state = state.copyWith(packId: id, packExplicit: true);
  }
}

class _Overlay extends PetOverlayChannel {
  final reloaded = <String>[];
  bool fail = false;
  @override
  Future<void> reloadPack(String id) async {
    reloaded.add(id);
    if (fail) throw StateError('Synthetic overlay refresh failure');
  }
}

WorkshopInstalled _installed({String kind = 'pet'}) => WorkshopInstalled(
  localId: kind == 'pet' ? 'user-cat' : 'companion',
  receipt: WorkshopReceipt(kind: kind, id: 'cat', version: '1.0.0', sha256: 'a' * 64, origin: _worker),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an absent deployment does not load a directory or create HTTP', () async {
    var directories = 0, clients = 0;
    final container = ProviderContainer(overrides: [
      workshopOriginProvider.overrideWithValue(null),
      workshopDirectoryProvider.overrideWithValue(() async { directories++; return Directory('unused-workshop'); }),
      workshopHttpFactoryProvider.overrideWithValue((origin) { clients++; return _Http(); }),
    ]);
    try {
      await expectLater(container.read(workshopClientProvider.future), _error('workshop_unconfigured'));
      expect(directories, 0);
      expect(clients, 0);
    } finally { container.dispose(); }
  });

  test('a directory arriving after disposal cannot create an HTTP client', () async {
    final entered = Completer<void>(), directory = Completer<Directory>();
    var clients = 0, disposed = false;
    final container = ProviderContainer(overrides: [
      workshopOriginProvider.overrideWithValue(_worker),
      workshopDirectoryProvider.overrideWithValue(() { entered.complete(); return directory.future; }),
      workshopHttpFactoryProvider.overrideWithValue((origin) { clients++; return _Http(); }),
    ]);
    final pending = container.read(workshopClientProvider.future);
    final settled = _settled(pending);
    try {
      await _signal(entered, pending);
      container.dispose();
      disposed = true;
      directory.complete(Directory('unused-late-workshop'));
      await expectLater(pending, _error('workshop_cancelled'));
      expect(clients, 0);
    } finally {
      if (!directory.isCompleted) directory.complete(Directory('unused-late-workshop'));
      if (!disposed) container.dispose();
      await settled;
    }
  });

  test('retry replaces a failed repository while keeping healthy dependencies open', () async {
    final http = _Http(), packages = _Packages();
    var directories = 0, clients = 0, packageLoads = 0;
    final container = ProviderContainer(overrides: [
      workshopOriginProvider.overrideWithValue(_worker),
      workshopDirectoryProvider.overrideWithValue(() async {
        directories++;
        if (directories == 2) throw const WorkshopException('workshop_storage');
        return Directory('unused-workshop');
      }),
      workshopHttpFactoryProvider.overrideWithValue((origin) { clients++; return http; }),
      workshopPackagesProvider.overrideWith((ref) async { packageLoads++; return packages; }),
      workshopAppVersionProvider.overrideWithValue('2.0.0'),
    ]);
    try {
      final client = await container.read(workshopClientProvider.future);
      await expectLater(container.read(workshopRepositoryProvider.future), _error('workshop_storage'));
      expect(directories, 2);
      container.read(_retryProvider)(true);
      final repository = await container.read(workshopRepositoryProvider.future);
      expect(repository.client, same(client));
      expect(repository.packages, same(packages));
      expect(clients, 1);
      expect(packageLoads, 1);
      expect(directories, 3);
      expect(http.closes, 0);
      container.read(_retryProvider)(true);
      expect(await container.read(workshopRepositoryProvider.future), same(repository));
      expect(directories, 3);
      expect(http.closes, 0);
    } finally { container.dispose(); }
    expect(http.closes, 1);
  });

  test('local retry is explicit and does not recreate a healthy client', () async {
    final http = _Http(), packages = _Packages();
    var packageLoads = 0, clients = 0;
    final container = ProviderContainer(overrides: [
      workshopOriginProvider.overrideWithValue(_worker),
      workshopDirectoryProvider.overrideWithValue(() async => Directory('unused-workshop')),
      workshopHttpFactoryProvider.overrideWithValue((origin) { clients++; return http; }),
      workshopPackagesProvider.overrideWith((ref) async {
        packageLoads++;
        if (packageLoads == 1) throw const WorkshopException('workshop_storage');
        return packages;
      }),
    ]);
    try {
      final client = await container.read(workshopClientProvider.future);
      await expectLater(container.read(workshopPackagesProvider.future), _error('workshop_storage'));
      container.read(_retryProvider)(false);
      await expectLater(container.read(workshopPackagesProvider.future), _error('workshop_storage'));
      expect(packageLoads, 1);
      container.read(_retryProvider)(true);
      expect(await container.read(workshopPackagesProvider.future), same(packages));
      expect(packageLoads, 2);
      expect(await container.read(workshopClientProvider.future), same(client));
      expect(clients, 1);
      expect(http.closes, 0);
    } finally { container.dispose(); }
  });

  for (final selected in ['user-cat', 'user-other']) {
    test('removal waits for cold preferences before deciding fallback for $selected', () async {
      final preferences = _PetPreferences(const PetPrefs());
      final overlay = _Overlay(), item = _installed();
      final hiddenUntil = DateTime.utc(2026, 11, 12);
      final restored = PetPrefs(packId: selected, hiddenUntil: hiddenUntil, loaded: true);
      final container = ProviderContainer(overrides: [
        petPrefsProvider.overrideWith(() => preferences),
        petOverlayChannelProvider.overrideWithValue(overlay),
      ]);
      final pending = container.read(workshopPackageChangedProvider)(item, removed: true);
      final settled = _settled(pending);
      try {
        await _signal(preferences.started, pending);
        expect(preferences.replacements, isEmpty);
        expect(overlay.reloaded, isEmpty);
        preferences.restore(restored);
        await pending;
        expect(preferences.replacements, selected == item.localId ? [defaultPetId] : isEmpty);
        expect(container.read(petPrefsProvider).packId, selected == item.localId ? defaultPetId : selected);
        expect(container.read(petPrefsProvider).hiddenUntil, hiddenUntil);
        expect(overlay.reloaded, [item.localId]);
      } finally {
        if (!preferences.restored) preferences.restore(restored);
        await settled;
        container.dispose();
      }
    });
  }

  test('disposal releases a callback waiting for cold preferences', () async {
    final preferences = _PetPreferences(const PetPrefs()), overlay = _Overlay();
    final container = ProviderContainer(overrides: [
      petPrefsProvider.overrideWith(() => preferences),
      petOverlayChannelProvider.overrideWithValue(overlay),
    ]);
    var disposed = false;
    final pending = container.read(workshopPackageChangedProvider)(_installed(), removed: true);
    final settled = _settled(pending);
    try {
      await _signal(preferences.started, pending);
      container.dispose();
      disposed = true;
      await expectLater(pending, _error('workshop_local_refresh'));
      expect(preferences.replacements, isEmpty);
      expect(overlay.reloaded, isEmpty);
    } finally {
      if (!disposed) container.dispose();
      await settled;
    }
  });

  test('a refresh failure after a package change has a stable local-refresh code', () async {
    final preferences = _PetPreferences(const PetPrefs(loaded: true));
    final overlay = _Overlay()..fail = true;
    final item = _installed();
    final container = ProviderContainer(overrides: [
      petPrefsProvider.overrideWith(() => preferences),
      petOverlayChannelProvider.overrideWithValue(overlay),
    ]);
    try {
      await expectLater(container.read(workshopPackageChangedProvider)(item, removed: false),
        _error('workshop_local_refresh'));
      expect(overlay.reloaded, [item.localId]);
      expect(preferences.started.isCompleted, isFalse, reason: 'install refresh does not read or overwrite pet selection');
    } finally { container.dispose(); }
  });

  test('companion changes do not fall back a pixel-pet selection', () async {
    final preferences = _PetPreferences(const PetPrefs()), overlay = _Overlay();
    final container = ProviderContainer(overrides: [
      petPrefsProvider.overrideWith(() => preferences),
      petOverlayChannelProvider.overrideWithValue(overlay),
    ]);
    try {
      await container.read(workshopPackageChangedProvider)(_installed(kind: 'companion'), removed: true);
      expect(preferences.started.isCompleted, isFalse);
      expect(preferences.replacements, isEmpty);
      expect(overlay.reloaded, isEmpty);
    } finally { container.dispose(); }
  });
}
