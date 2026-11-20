import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _LocalPackages extends LocalWorkshopPackages {
  _LocalPackages({required super.pets, required super.companion});
  final removals = <String>[];

  @override
  Future<void> remove(WorkshopInstalled installed) {
    removals.add(installed.localId);
    return super.remove(installed);
  }
}

void main() {
  late Directory temp;
  late Directory petsRoot;
  late PetLibrary pets;
  late CompanionPackStore companion;
  late FakeWorkshopHttp http;
  late WorkshopClient client;
  late _LocalPackages packages;
  late WorkshopRepository repository;

  void useLibrary(PetLibrary library) {
    pets = library;
    packages = _LocalPackages(pets: pets, companion: companion);
    repository = WorkshopRepository(client: client, packages: packages,
      downloadDirectory: Directory('${temp.path}/downloads'), appVersion: '1.0.0');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('workshop-installed');
    petsRoot = Directory('${temp.path}/pets');
    companion = CompanionPackStore(Directory('${temp.path}/companion'));
    http = FakeWorkshopHttp((_, _, _, _) => throw StateError('unexpected network'));
    client = WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http);
    useLibrary(PetLibrary(() async => petsRoot));
  });
  tearDown(() async {
    client.close();
    await temp.delete(recursive: true);
  });

  Directory folder(String id) => Directory('${petsRoot.path}/user-$id');
  File receiptFile(String id) => File('${folder(id).path}/$workshopReceiptName');
  File manifest(String id) => File('${folder(id).path}/pack.json');
  WorkshopReceipt receipt(String id, {String version = '1.0.0'}) => WorkshopReceipt(kind: 'pet', id: id,
    version: version, sha256: workshopMeta(id: id)['sha256'] as String, origin: workshopTestOrigin);

  Future<void> installPet(String id, {bool tracked = true, String version = '1.0.0'}) async {
    final zip = workshopZip(temp, {'pack.json': utf8.encode(jsonEncode(workshopPet(id: id))), 'idle.png': workshopPng()});
    expect((await pets.install(zip, workshop: tracked ? receipt(id, version: version) : null)).id, 'user-$id');
  }

  Future<void> seed() async {
    await installPet('cat');
    await installPet('dog');
    await installPet('manual', tracked: false);
    manifest('manual').writeAsStringSync('{}');
  }

  WorkshopCatalog catalog() => WorkshopCatalog.fromJson(workshopCatalogJson(entries: [
    workshopEntryJson(metadata: workshopMeta(id: 'cat')),
    workshopEntryJson(metadata: workshopMeta(id: 'dog')),
  ]));

  Future<({WorkshopLocalEntry cat, WorkshopInstalled dog})> checkQueries(String issue, {required bool trusted}) async {
    final local = await pets.workshopReceipts();
    expect(local.keys.toSet(), {'user-cat', 'user-dog'});
    expect(local['user-cat']!.issue, issue);
    expect(local['user-cat']!.receipt?.same(receipt('cat')), trusted ? isTrue : isNull);
    expect(local['user-dog']!.receipt!.same(receipt('dog')), isTrue);
    expect(local['user-dog']!.issue, isNull);

    final installed = await repository.installed();
    expect(installed.map((row) => row.localId).toSet(), {'user-cat', 'user-dog'});
    final cat = installed.singleWhere((row) => row.localId == 'user-cat');
    final dog = installed.singleWhere((row) => row.localId == 'user-dog') as WorkshopInstalled;
    expect(cat.issue, issue);
    expect(cat, trusted ? isA<WorkshopInstalled>() : isA<WorkshopInstallationIssue>());
    expect(dog.receipt.same(receipt('dog')), isTrue);
    expect(dog.issue, isNull);

    final states = await repository.states(catalog());
    expect(states, hasLength(2));
    final catState = states.singleWhere((row) => row.entry.metadata.id == 'cat');
    expect(catState.installed, trusted ? isA<WorkshopInstalled>() : isNull);
    if (trusted) expect(catState.installed!.issue, issue);
    final dogState = states.singleWhere((row) => row.entry.metadata.id == 'dog');
    expect(dogState.installed!.receipt.same(receipt('dog')), isTrue);
    expect(dogState.unavailable, isNull);

    final localStates = await repository.installedStates(catalog());
    expect(localStates.map((row) => row.installed.localId).toSet(), {'user-cat', 'user-dog'});
    final localCat = localStates.singleWhere((row) => row.installed.localId == 'user-cat');
    expect(localCat.installed.issue, issue);
    expect(localCat.unavailable, trusted ? isNull : issue);
    expect(localCat.entry, trusted ? isNotNull : isNull);
    final localDog = localStates.singleWhere((row) => row.installed.localId == 'user-dog');
    expect((localDog.installed as WorkshopInstalled).receipt.same(receipt('dog')), isTrue);
    expect(localDog.unavailable, isNull);
    expect(http.requests, isEmpty);
    return (cat: cat, dog: dog);
  }

  Future<void> checkUntrustedRemoval(WorkshopLocalEntry cat, WorkshopInstalled dog) async {
    final before = receiptFile('cat').readAsBytesSync();
    await expectLater(repository.uninstall(cat), workshopError('workshop_install_record'));
    expect(packages.removals, isEmpty);
    expect(receiptFile('cat').readAsBytesSync(), before);
    expect(folder('cat').existsSync(), isTrue);
    await repository.uninstall(dog);
    expect(packages.removals, ['user-dog']);
    expect(folder('dog').existsSync(), isFalse);
    expect(folder('cat').existsSync(), isTrue);
    expect(folder('manual').existsSync(), isTrue);
  }

  test('pack parsing rejects non-finite in-memory numbers before rounding or geometry', () {
    for (final value in [double.infinity, double.negativeInfinity, double.nan]) {
      final rounded = workshopPet()..['scale'] = value;
      expect(() => PetPack.parse(rounded), throwsFormatException, reason: 'scale: $value');
      final geometry = workshopPet()..['anchor'] = {'x': value};
      expect(() => PetPack.parse(geometry), throwsFormatException, reason: 'anchor.x: $value');
    }
  });

  test('pack parsing preserves finite numbers, rounding and optional defaults', () {
    final json = workshopPet()
      ..['scale'] = 1.6
      ..['anchor'] = {'x': -0.25, 'baseline': 15.75}
      ..['sleep'] = {'afterMs': 1200.4};
    final pack = PetPack.parse(json);
    expect(pack.scale, 2);
    expect(pack.anchorX, -0.25);
    expect(pack.baseline, 15.75);
    expect(pack.sleepAfter, const Duration(milliseconds: 1200));
    final defaults = PetPack.parse(workshopPet());
    expect(defaults.scale, 1);
    expect(defaults.anchorX, 8);
    expect(defaults.baseline, 16);
  });

  for (final defect in ['json', 'identity', 'kind']) {
    test('a $defect receipt error does not hide healthy installations or their removal target', () async {
      await seed();
      final invalid = receipt('cat').toJson();
      if (defect == 'identity') invalid['id'] = 'other';
      if (defect == 'kind') invalid['kind'] = 'companion';
      receiptFile('cat').writeAsStringSync(defect == 'json' ? '{' : jsonEncode(invalid));
      final rows = await checkQueries('workshop_install_record', trusted: false);
      await checkUntrustedRemoval(rows.cat, rows.dog);
    });
  }

  test('one receipt read failure is reported locally and a later listing retries it', () async {
    await seed();
    var failRead = true;
    var failures = 0;
    useLibrary(PetLibrary.withWorkshopReceiptReader(() async => petsRoot, readReceipt: (directory) {
      final id = directory.uri.pathSegments.lastWhere((part) => part.isNotEmpty);
      if (id == 'user-cat' && failRead) {
        failures++;
        throw const FileSystemException('injected receipt read failure', '', OSError('IO error', 5));
      }
      return WorkshopReceipt.read(directory);
    }));
    final rows = await checkQueries('workshop_storage', trusted: false);
    expect(failures, 4, reason: 'the direct read and all three repository views attempt this entry');
    await checkUntrustedRemoval(rows.cat, rows.dog);
    failRead = false;
    final recovered = (await repository.installed()).single as WorkshopInstalled;
    expect(recovered.localId, 'user-cat');
    expect(recovered.issue, isNull);
    expect(recovered.receipt.same(receipt('cat')), isTrue);
  });

  for (final missing in [false, true]) {
    test('a ${missing ? 'missing' : 'malformed'} pack keeps its receipt, withdrawal status and uninstall target', () async {
      await seed();
      if (missing) {
        manifest('cat').deleteSync();
      } else {
        manifest('cat').writeAsStringSync('{}');
      }
      final issue = missing ? 'workshop_storage' : 'workshop_pet_bad_pack';
      final rows = await checkQueries(issue, trusted: true);
      expect(workshopPackageValidationCodes.contains(rows.cat.issue), !missing);
      final withdrawn = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [
        workshopEntryJson(metadata: workshopMeta(id: 'dog')),
      ], withdrawn: [
        {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate},
      ]));
      final state = (await repository.installedStates(withdrawn)).singleWhere((row) => row.installed.localId == 'user-cat');
      expect(state.installed.issue, issue);
      expect(state.installedWithdrawn, isTrue);
      expect(state.unavailable, 'workshop_version_withdrawn');
      expect(state.entry, isNull);
      expect((state.installed as WorkshopInstalled).receipt.same(receipt('cat')), isTrue);
      await repository.uninstall(rows.cat);
      expect(packages.removals, ['user-cat']);
      expect(folder('cat').existsSync(), isFalse);
      expect((await repository.installed()).single.localId, 'user-dog');
      expect(folder('manual').existsSync(), isTrue);
      expect(http.requests, isEmpty);
    });
  }

  test('a broken pack removal target cannot delete a later replacement', () async {
    await installPet('cat');
    manifest('cat').writeAsStringSync('{}');
    final before = (await repository.installed()).single as WorkshopInstalled;
    expect(before.issue, 'workshop_pet_bad_pack');
    await installPet('cat', version: '1.1.0');
    await expectLater(repository.uninstall(before), workshopError('workshop_install_conflict'));
    expect((await pets.workshopReceipt('user-cat'))!.same(receipt('cat', version: '1.1.0')), isTrue);
    expect((await pets.load('user-cat')).id, 'user-cat');
    final current = (await repository.installed()).single as WorkshopInstalled;
    expect(current.issue, isNull);
  });

  test('a root failure remains a whole-list failure', () async {
    const failure = FileSystemException('injected root failure');
    final unavailable = PetLibrary(() async => throw failure);
    await expectLater(unavailable.workshopReceipts(), throwsA(same(failure)));
  });

  test('an unexpected reader programming error is not converted into a damaged entry', () async {
    await installPet('cat');
    final failure = StateError('injected programming error');
    final broken = PetLibrary.withWorkshopReceiptReader(() async => petsRoot, readReceipt: (_) => throw failure);
    await expectLater(broken.workshopReceipts(), throwsA(same(failure)));
  });
}
