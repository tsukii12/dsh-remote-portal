import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _ObservedPackages extends LocalWorkshopPackages {
  _ObservedPackages({required super.pets, required super.companion});
  final removals = <String>[];

  @override
  Future<void> remove(WorkshopInstalled installed) {
    removals.add(installed.localId);
    return super.remove(installed);
  }
}

// Only the receipt-call failure is controlled; normal reads use the real store.
class _ReceiptFailureStore extends CompanionPackStore {
  _ReceiptFailureStore(super.root);
  Object? failure;

  @override
  Future<WorkshopReceipt?> workshopReceipt() async {
    final error = failure;
    if (error != null) {
      throw error;
    }
    return super.workshopReceipt();
  }
}

void main() {
  late Directory temp;
  late Directory petsRoot;
  late PetLibrary pets;
  late CompanionPackStore companion;
  late FakeWorkshopHttp http;
  late WorkshopClient client;
  late _ObservedPackages packages;
  late WorkshopRepository repository;

  void useCompanion(CompanionPackStore store) {
    companion = store;
    packages = _ObservedPackages(pets: pets, companion: companion);
    repository = WorkshopRepository(client: client, packages: packages,
      downloadDirectory: Directory('${temp.path}/downloads'), appVersion: '1.0.0');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('workshop-companion-slot');
    petsRoot = Directory('${temp.path}/pets');
    pets = PetLibrary(() async => petsRoot);
    http = FakeWorkshopHttp((_, _, _, _) => throw StateError('unexpected network'));
    client = WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http);
    useCompanion(CompanionPackStore(Directory('${temp.path}/companion'), expectedRuntime: workshopRuntimeDigest()));
  });
  tearDown(() async {
    client.close();
    await temp.delete(recursive: true);
  });

  Directory petFolder() => Directory('${petsRoot.path}/user-dog');
  File companionReceiptFile() => File('${companion.pack.path}/$workshopReceiptName');
  WorkshopReceipt receipt(String kind, String id) => WorkshopReceipt(kind: kind, id: id,
    version: '1.0.0', sha256: workshopMeta(kind: kind, id: id)['sha256'] as String, origin: workshopTestOrigin);

  Future<void> seed({bool trackedCompanion = true}) async {
    final pet = workshopZip(temp, {'pack.json': utf8.encode(jsonEncode(workshopPet(id: 'dog'))), 'idle.png': workshopPng()});
    await pets.install(pet, workshop: receipt('pet', 'dog'));
    final character = workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()});
    await companion.install(character.path);
    if (trackedCompanion) {
      final characterOnly = workshopZip(temp, workshopCharacter());
      await companion.install(characterOnly.path,
        workshop: receipt('companion', 'character'), replaceExisting: true);
    }
  }

  WorkshopCatalog catalog({bool companionEnabled = true}) => WorkshopCatalog.fromJson(workshopCatalogJson(
    companion: companionEnabled,
    entries: [
      workshopEntryJson(metadata: workshopMeta(id: 'dog')),
      workshopEntryJson(metadata: workshopMeta(id: 'cat')),
      if (companionEnabled) workshopEntryJson(metadata: workshopMeta(kind: 'companion', id: 'character')),
    ],
  ));

  Future<({WorkshopInstallationIssue issue, WorkshopInstalled pet})> checkIssue(String code, {bool companionEnabled = true}) async {
    final local = await repository.installed();
    expect(local.map((row) => row.localId).toSet(), {'user-dog', 'companion'});
    final pet = local.singleWhere((row) => row.localId == 'user-dog') as WorkshopInstalled;
    expect(pet.receipt.same(receipt('pet', 'dog')), isTrue);
    expect(pet.issue, isNull);
    final slot = local.singleWhere((row) => row.localId == 'companion');
    expect(slot, isA<WorkshopInstallationIssue>());
    expect(slot.issue, code);

    final current = catalog(companionEnabled: companionEnabled);
    final states = await repository.states(current);
    expect(states.singleWhere((row) => row.entry.metadata.id == 'dog').installed!.receipt.same(pet.receipt), isTrue);
    expect(states.singleWhere((row) => row.entry.metadata.id == 'cat').installed, isNull,
      reason: 'a companion slot never impersonates an uninstalled public pet');
    if (companionEnabled) {
      expect(states.singleWhere((row) => row.entry.metadata.id == 'character').installed, isNull);
    }

    final installedStates = await repository.installedStates(current);
    expect(installedStates, hasLength(2));
    final issueState = installedStates.singleWhere((row) => row.installed.localId == 'companion');
    expect(issueState.installed, isA<WorkshopInstallationIssue>());
    expect(issueState.installed.issue, code);
    expect(issueState.unavailable, code);
    expect(issueState.entry, isNull);
    expect(issueState.installedWithdrawn, isFalse);
    expect(issueState.updateAvailable, isFalse);
    expect(http.requests, isEmpty);
    return (issue: slot as WorkshopInstallationIssue, pet: pet);
  }

  Future<void> rejectUntrustedRemoval(WorkshopInstallationIssue issue) async {
    final file = companionReceiptFile();
    final before = file.existsSync() ? file.readAsBytesSync() : null;
    await expectLater(repository.uninstall(issue), workshopError('workshop_install_record'));
    expect(packages.removals, isEmpty, reason: 'the repository rejects before dispatching a removal');
    if (before != null) {
      expect(file.readAsBytesSync(), before);
    }
    expect(petFolder().existsSync(), isTrue);
  }

  for (final defect in ['json', 'kind']) {
    test('a companion $defect receipt issue preserves healthy pet queries and cannot be removed', () async {
      await seed();
      final invalid = receipt('companion', 'character').toJson();
      invalid['kind'] = 'pet';
      invalid['id'] = 'cat';
      companionReceiptFile().writeAsStringSync(defect == 'json' ? '{' : jsonEncode(invalid));
      final before = companionReceiptFile().readAsBytesSync();
      final observed = await checkIssue('workshop_install_record');
      await checkIssue('workshop_install_record', companionEnabled: false);
      await rejectUntrustedRemoval(observed.issue);
      await repository.uninstall(observed.pet);
      expect(packages.removals, ['user-dog']);
      expect(petFolder().existsSync(), isFalse);
      expect(companion.pack.existsSync(), isTrue);
      expect(companionReceiptFile().readAsBytesSync(), before);
      expect(http.requests, isEmpty);
    });
  }

  test('a valid companion receipt keeps its identity and strict uninstall target', () async {
    await seed();
    final local = await repository.installed();
    final installed = local.singleWhere((row) => row.localId == 'companion') as WorkshopInstalled;
    expect(installed.receipt.same(receipt('companion', 'character')), isTrue);
    expect(installed.issue, isNull);
    final states = await repository.states(catalog());
    expect(states.singleWhere((row) => row.entry.metadata.id == 'character').installed!.receipt.same(installed.receipt), isTrue);
    final closed = await repository.installedStates(catalog(companionEnabled: false));
    final closedSlot = closed.singleWhere((row) => row.installed.localId == 'companion');
    expect(closedSlot.installed, isA<WorkshopInstalled>());
    expect(closedSlot.installed.issue, isNull);
    expect(closedSlot.unavailable, 'workshop_companion_disabled');
    await repository.uninstall(installed);
    expect(packages.removals, ['companion']);
    expect(companion.pack.existsSync(), isFalse);
    expect((await pets.workshopReceipt('user-dog'))!.same(receipt('pet', 'dog')), isTrue);
    expect(http.requests, isEmpty);
  });

  test('a local companion without a workshop receipt does not create an issue row', () async {
    await seed(trackedCompanion: false);
    final local = await repository.installed();
    expect(local.map((row) => row.localId), ['user-dog']);
    final states = await repository.states(catalog());
    expect(states.singleWhere((row) => row.entry.metadata.id == 'dog').installed, isNotNull);
    expect(states.singleWhere((row) => row.entry.metadata.id == 'character').installed, isNull);
    expect(await repository.installedStates(catalog()), hasLength(1));
    expect(await companion.workshopReceipt(), isNull);
    expect(companion.pack.existsSync(), isTrue);
    expect(http.requests, isEmpty);
  });

  test('a controlled companion storage failure is local and the next query retries', () async {
    await seed();
    final failing = _ReceiptFailureStore(companion.root)
      ..failure = const FileSystemException('injected receipt read failure', '', OSError('IO error', 5));
    useCompanion(failing);
    final observed = await checkIssue('workshop_storage');
    await rejectUntrustedRemoval(observed.issue);
    failing.failure = null;
    final recovered = (await repository.installed()).singleWhere((row) => row.localId == 'companion') as WorkshopInstalled;
    expect(recovered.receipt.same(receipt('companion', 'character')), isTrue);
    expect(recovered.issue, isNull);
    expect(petFolder().existsSync(), isTrue);
    expect(http.requests, isEmpty);
  });

  test('a mapped stop-readers failure during companion recovery is local and can recover later', () async {
    await seed();
    final previous = Directory('${companion.root.path}/pack.previous');
    await companion.pack.rename(previous.path);
    final before = File('${previous.path}/$workshopReceiptName').readAsBytesSync();
    var stops = 0;
    final unregister = companion.beforeChanges(() async {
      stops++;
      throw StateError('the test reader did not stop');
    });
    try {
      final observed = await checkIssue('workshop_readers_busy');
      await rejectUntrustedRemoval(observed.issue);
      expect(stops, greaterThan(0));
      expect(previous.existsSync(), isTrue);
      expect(companion.pack.existsSync(), isFalse);
      expect(File('${previous.path}/$workshopReceiptName').readAsBytesSync(), before);
    } finally {
      unregister();
    }
    final recovered = (await repository.installed()).singleWhere((row) => row.localId == 'companion') as WorkshopInstalled;
    expect(recovered.receipt.same(receipt('companion', 'character')), isTrue);
    expect(previous.existsSync(), isFalse);
    expect(companion.pack.existsSync(), isTrue);
    expect(http.requests, isEmpty);
  });

  test('an unconverted companion programming error still fails the whole query', () async {
    await seed();
    final failure = StateError('unexpected receipt reader error');
    final failing = _ReceiptFailureStore(companion.root)..failure = failure;
    useCompanion(failing);
    await expectLater(packages.installed(), throwsA(same(failure)));
    await expectLater(repository.installed(), workshopError('workshop_bad_response'));
    await expectLater(repository.states(catalog()), workshopError('workshop_bad_response'));
    await expectLater(repository.installedStates(catalog()), workshopError('workshop_bad_response'));
    failing.failure = null;
    expect(await repository.installed(), hasLength(2));
    expect(http.requests, isEmpty);
  });
}
