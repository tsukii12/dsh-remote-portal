import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final configuredOrigin = Platform.environment['DSH_WORKSHOP_E2E_ORIGIN'];

  test('local Worker catalog installs and uninstalls through the real Dart stack', () async {
    var step = 'configuration';
    try {
      final parsed = Uri.tryParse(configuredOrigin!);
      if (parsed == null) {
        throw StateError('DSH_WORKSHOP_E2E_ORIGIN must be a loopback HTTPS origin');
      }
      final origin = workshopOrigin(parsed);
      final address = InternetAddress.tryParse(origin.host);
      if (address == null || !address.isLoopback) {
        throw StateError('DSH_WORKSHOP_E2E_ORIGIN must use a numeric loopback address');
      }
      final caFile = Platform.environment['DSH_WORKSHOP_E2E_CA_FILE'];
      if (caFile == null || caFile.isEmpty) {
        throw StateError('DSH_WORKSHOP_E2E_CA_FILE must name the local rehearsal CA');
      }
      final itemId = Platform.environment['DSH_WORKSHOP_E2E_ITEM_ID'] ?? 'workshop-local-pet';
      final expectedVersion = Platform.environment['DSH_WORKSHOP_E2E_ITEM_VERSION'];
      final context = SecurityContext(withTrustedRoots: false)..setTrustedCertificates(caFile);
      final temp = await Directory.systemTemp.createTemp('workshop-local-e2e-');
      addTearDown(() async {
        await temp.delete(recursive: true);
      });

      // No widget binding: the repository and transport keep real sockets.
      // Only this client trusts the rehearsal CA; hostname checks stay enabled.
      final transport = IoWorkshopHttp(origin, client: HttpClient(context: context)
        ..findProxy = (_) => 'DIRECT');
      addTearDown(transport.close);
      final client = WorkshopClient(
        origin: origin,
        cacheFile: File('${temp.path}/catalog.json'),
        http: transport,
      );
      final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
      final repository = WorkshopRepository(
        client: client,
        packages: LocalWorkshopPackages(
          pets: pets,
          companion: CompanionPackStore(Directory('${temp.path}/companion')),
        ),
        downloadDirectory: Directory('${temp.path}/downloads'),
        appVersion: '1.0.0',
        // A desktop rehearsal has no Android free-space platform channel.
        freeBytes: () async => null,
      );

      step = 'catalog: GET /market/workshop.json';
      final snapshot = await client.catalog(requireFresh: true);
      expect(snapshot.stale, isFalse);
      expect(snapshot.refreshError, isNull);
      expect(snapshot.cacheIssue, isNull);
      final entry = snapshot.catalog.find('pet', itemId);
      expect(entry, isNotNull, reason: 'the approved rehearsal pet must be public');
      final current = entry!;
      if (expectedVersion != null) {
        expect(current.metadata.version, expectedVersion);
      }
      step = 'public preview: parse the real catalog and construct a same-origin URI';
      expect(current.metadata.previewSource, 'pet-idle');
      expect(current.preview, isNotNull);
      final preview = current.preview!;
      final previewUri = client.publicPreviewUri(current)!;
      expect(previewUri, origin.resolve(preview.path));
      expect(previewUri.origin, origin.origin);
      expect(previewUri.scheme, 'https');
      expect(previewUri.userInfo, isEmpty);
      expect(previewUri.query, isEmpty);
      expect(previewUri.fragment, isEmpty);
      expect(previewUri.path,
        '/market/workshop/pet/$itemId/${current.metadata.version}/${current.metadata.sha256}/preview/${preview.sha256}.png');
      // This synchronous address method does not request image bytes. The
      // Node phase checks the actual public PNG over the same local HTTPS.
      expect(await repository.installed(), isEmpty);

      step = 'install: GET ${current.metadata.archivePath} and catalog revalidation';
      final installed = await repository.install(current);
      expect(installed.localId, 'user-$itemId');
      expect(installed.receipt.origin, origin);
      expect(installed.receipt.kind, current.metadata.kind);
      expect(installed.receipt.id, current.metadata.id);
      expect(installed.receipt.version, current.metadata.version);
      expect(installed.receipt.sha256, current.metadata.sha256);
      expect((await pets.load(installed.localId)).id, installed.localId);

      step = 'installed list: read real pack and receipt files';
      final rows = await repository.installed();
      expect(rows, hasLength(1));
      expect(rows.single, isA<WorkshopInstalled>());
      final listed = rows.single as WorkshopInstalled;
      expect(listed.localId, installed.localId);
      expect(listed.receipt.same(installed.receipt), isTrue);
      expect(listed.issue, isNull);

      step = 'uninstall: remove the receipt-fenced local installation';
      await repository.uninstall(listed);
      expect(await repository.installed(), isEmpty);
      expect(await pets.list(), isEmpty);
      expect(await (await pets.folder(installed.localId)).exists(), isFalse);
    } on Object {
      printOnFailure('Workshop local HTTP rehearsal failed at: $step');
      rethrow;
    }
  },
    skip: configuredOrigin == null ? 'Set DSH_WORKSHOP_E2E_ORIGIN via the local rehearsal entry point' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
