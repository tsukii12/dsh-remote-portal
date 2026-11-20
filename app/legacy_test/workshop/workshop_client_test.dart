import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Only the first read fails; all cache bytes and successful IO are real.
class _FirstReadFails implements File {
  _FirstReadFails(this.delegate);
  final File delegate;
  int reads = 0;

  @override String get path => delegate.path;
  @override File get absolute => delegate.absolute;
  @override Directory get parent => delegate.parent;
  @override Future<bool> exists() => delegate.exists();
  @override Future<int> length() => delegate.length();
  @override Future<String> readAsString({Encoding encoding = utf8}) async {
    reads++;
    if (reads == 1) throw const FileSystemException('synthetic first cache read failure');
    return delegate.readAsString(encoding: encoding);
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProgressHttp extends FakeWorkshopHttp implements WorkshopUploadHttp {
  _ProgressHttp(super.route);
  int uploads = 0;
  @override
  Future<UpdateHttpResponse> upload(Uri url, {required List<int> body, Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30), void Function(int sent, int total)? onProgress}) async {
    uploads++;
    onProgress?.call(0, body.length);
    onProgress?.call(2, body.length);
    final response = await request('PUT', url, headers: headers, body: body, timeout: timeout);
    onProgress?.call(body.length, body.length);
    return response;
  }
}

void main() {
  late Directory temp;
  late FakeWorkshopHttp http;
  late WorkshopClient client;
  late WorkshopCredential credential;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('workshop-client');
    http = FakeWorkshopHttp((_, url, _, _) {
      if (url.path.endsWith('/capabilities')) return workshopJsonResponse(workshopCaps());
      return workshopJsonResponse(workshopCatalogJson(), headers: {'etag': '"one"'});
    });
    client = WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http,
      clock: () => DateTime.utc(2026, 11, 11, 1, 2, 3, 456, 789));
    credential = WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin, account: workshopTestAccount,
      token: 'synthetic_test_token', disclosureAccepted: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('cachedCatalog returns no view for a missing cache without making an HTTP request', () async {
    expect(await client.cachedCatalog(), isNull);
    expect(client.cacheIssue, isNull);
    expect(http.requests, isEmpty);
  });

  test('cachedCatalog restores display metadata with original time and a stale marker without HTTP', () async {
    final metadata = {...workshopMeta(), 'description': 'A cached companion', 'tags': ['cat', 'small']};
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(entries: [workshopEntryJson(metadata: metadata)]));
    final fresh = await client.catalog();
    final restoredFile = client.cacheFile.copySync('${temp.path}/cached-only.json');
    final offline = FakeWorkshopHttp((_, _, _, _) => throw StateError('cachedCatalog must not request HTTP'));
    final restarted = WorkshopClient(origin: workshopTestOrigin, cacheFile: restoredFile, http: offline);
    final cached = (await restarted.cachedCatalog())!;
    expect(cached.stale, isTrue);
    expect(cached.fetchedAt, fresh.fetchedAt);
    expect(cached.refreshError, isNull);
    expect(cached.cacheIssue, isNull);
    expect(cached.catalog.entries.single.metadata.description, 'A cached companion');
    expect(cached.catalog.entries.single.metadata.tags, ['cat', 'small']);
    expect(offline.requests, isEmpty);
  });

  test('cachedCatalog reports cache issues and retries an initial storage read without HTTP', () async {
    await client.catalog();
    final disk = client.cacheFile.copySync('${temp.path}/cached-retry.json');
    final once = _FirstReadFails(disk);
    final offline = FakeWorkshopHttp((_, _, _, _) => throw StateError('unexpected HTTP'));
    final recovering = WorkshopClient(origin: workshopTestOrigin, cacheFile: once, http: offline);
    expect(await recovering.cachedCatalog(), isNull);
    expect(recovering.cacheIssue, 'workshop_cache_storage');
    expect((await recovering.cachedCatalog())!.cacheIssue, isNull);
    expect(once.reads, 2);
    final damaged = File('${temp.path}/cached-damaged.json')..writeAsStringSync('{bad');
    final invalid = WorkshopClient(origin: workshopTestOrigin, cacheFile: damaged, http: offline);
    expect(await invalid.cachedCatalog(), isNull);
    expect(invalid.cacheIssue, 'workshop_cache_invalid');
    expect(offline.requests, isEmpty);
  });

  test('cachedCatalog queues behind a refresh and preserves its newly known withdrawal', () async {
    await client.catalog();
    final gone = {'kind': 'pet', 'id': 'old', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate};
    http.route = (_, _, _, _) async => workshopJsonResponse(workshopCatalogJson(
      withdrawn: [gone], at: '2026-11-12T00:00:00.000Z'));
    final values = await Future.wait<WorkshopCatalogSnapshot?>([client.catalog(requireFresh: true), client.cachedCatalog()]);
    expect(values[1]!.stale, isTrue);
    expect(values[1]!.fetchedAt, values[0]!.fetchedAt);
    expect(values[1]!.catalog.generatedAt, values[0]!.catalog.generatedAt);
    expect(values[1]!.catalog.blocked('pet', 'old', '1.0.0'), isTrue);
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(at: '2026-11-13T00:00:00.000Z'));
    await expectLater(client.catalog(requireFresh: true), workshopError('workshop_catalog_rollback'));
  });

  test('disk cache survives microsecond clocks, 304, and an offline restart', () async {
    final first = await client.catalog();
    expect(first.stale, isFalse);
    expect(first.fetchedAt.microsecond, 0);
    http.route = (_, _, headers, _) {
      expect(headers['if-none-match'], '"one"');
      return UpdateHttpResponse(status: 304, body: const Stream.empty());
    };
    // An unseen path simulates a cold process with only persisted bytes,
    // without reusing this process's shared in-memory cache coordinator.
    final restored = client.cacheFile.copySync('${temp.path}/restart.json');
    final restarted = WorkshopClient(origin: workshopTestOrigin, cacheFile: restored, http: http);
    expect((await restarted.catalog(requireFresh: true)).cacheIssue, isNull);
    http.route = (_, _, _, _) => throw const SocketException('offline');
    final cached = await restarted.catalog();
    expect(cached.stale, isTrue);
    expect(cached.refreshError?.code, 'workshop_network');
    expect(cached.catalog.entries.single.metadata.id, 'cat');
    await expectLater(restarted.catalog(requireFresh: true), workshopError('workshop_network'));
  });

  test('damaged cache is observable when fresh fetch cannot replace it', () async {
    client.cacheFile.writeAsStringSync('{bad');
    http.route = (_, _, _, _) => throw const SocketException('offline');
    await expectLater(client.catalog(), workshopError('workshop_network'));
    expect(client.cacheIssue, 'workshop_cache_invalid');
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson());
    expect((await client.catalog()).stale, isFalse);
    expect(jsonDecode(client.cacheFile.readAsStringSync()), isA<Map>());
  });

  test('a first disk storage failure retries on the same client while offline', () async {
    await client.catalog();
    final disk = client.cacheFile.copySync('${temp.path}/disk-retry.json');
    final once = _FirstReadFails(disk);
    final recovering = WorkshopClient(origin: workshopTestOrigin, cacheFile: once, http: http);
    http.route = (_, _, _, _) => throw const SocketException('offline');
    await expectLater(recovering.catalog(), workshopError('workshop_network'));
    expect(recovering.cacheIssue, 'workshop_cache_storage');
    expect(once.reads, 1);

    final cached = await recovering.catalog();
    expect(cached.stale, isTrue);
    expect(cached.catalog.entries.single.metadata.id, 'cat');
    expect(cached.cacheIssue, isNull);
    expect(recovering.cacheIssue, isNull);
    expect(once.reads, 2);
    await expectLater(recovering.catalog(requireFresh: true), workshopError('workshop_network'));
    expect(once.reads, 2, reason: 'a healthy memory copy needs no additional disk read');
  });

  test('a replacement client at the same normalized path can retry failed disk loading', () async {
    await client.catalog();
    final disk = client.cacheFile.copySync('${temp.path}/replacement-retry.json');
    final once = _FirstReadFails(disk);
    final first = WorkshopClient(origin: workshopTestOrigin, cacheFile: once, http: http);
    http.route = (_, _, _, _) => throw const SocketException('offline');
    await expectLater(first.catalog(), workshopError('workshop_network'));
    expect(first.cacheIssue, 'workshop_cache_storage');
    final replacement = WorkshopClient(origin: workshopTestOrigin,
      cacheFile: File('${temp.path}/./replacement-retry.json'), http: http);
    final cached = await replacement.catalog();
    expect(cached.stale, isTrue);
    expect(cached.catalog.entries.single.metadata.id, 'cat');
    expect(cached.cacheIssue, isNull);
    expect(first.cacheIssue, isNull, reason: 'the shared storage issue was cleared by the successful read');
    await expectLater(replacement.catalog(requireFresh: true), workshopError('workshop_network'));
  });

  test('failed disk retry never replaces newer memory after a failed save', () async {
    await client.catalog();
    final disk = client.cacheFile.copySync('${temp.path}/keep-newer.json');
    final oldBytes = disk.readAsBytesSync();
    final once = _FirstReadFails(disk);
    // A real directory at the staging-file path makes the disk save fail.
    Directory('${disk.path}.part').createSync();
    final gone = {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate};
    http.route = (_, _, _, _) => workshopJsonResponse(
      workshopCatalogJson(entries: [], withdrawn: [gone], at: '2026-11-12T00:00:00.000Z'));
    final recovering = WorkshopClient(origin: workshopTestOrigin, cacheFile: once, http: http);
    final fresh = await recovering.catalog(requireFresh: true);
    expect(fresh.stale, isFalse);
    expect(fresh.catalog.blocked('pet', 'cat', '1.0.0'), isTrue);
    expect(fresh.cacheIssue, 'workshop_cache_storage');
    expect(disk.readAsBytesSync(), oldBytes, reason: 'the disk still contains the old catalog');
    expect(once.reads, 1);

    http.route = (_, _, _, _) => throw const SocketException('offline');
    final retained = await recovering.catalog();
    expect(retained.stale, isTrue);
    expect(retained.catalog.entries, isEmpty);
    expect(retained.catalog.blocked('pet', 'cat', '1.0.0'), isTrue);
    expect(retained.cacheIssue, 'workshop_cache_storage');
    expect(once.reads, 1, reason: 'the newer memory copy is authoritative despite its failed save');
    final replacement = WorkshopClient(origin: workshopTestOrigin,
      cacheFile: File('${temp.path}/./keep-newer.json'), http: http);
    expect((await replacement.catalog()).catalog.blocked('pet', 'cat', '1.0.0'), isTrue);
    await expectLater(replacement.catalog(requireFresh: true), workshopError('workshop_network'));
  });

  test('cache from another deployment cannot authorize a 304', () async {
    await client.catalog();
    final map = jsonDecode(client.cacheFile.readAsStringSync()) as Map;
    map['origin'] = 'https://another.example';
    final foreign = File('${temp.path}/foreign.json')..writeAsStringSync(jsonEncode(map));
    http.route = (_, _, _, _) => UpdateHttpResponse(status: 304, body: const Stream.empty());
    final restarted = WorkshopClient(origin: workshopTestOrigin, cacheFile: foreign, http: http);
    await expectLater(restarted.catalog(requireFresh: true), workshopError('workshop_bad_catalog'));
  });

  test('known withdrawals cannot disappear in a later catalog response', () async {
    final gone = {'kind': 'pet', 'id': 'old', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate};
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(withdrawn: [gone]));
    await client.catalog();
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(at: '2026-11-12T00:00:00.000Z'));
    await expectLater(client.catalog(requireFresh: true), workshopError('workshop_catalog_rollback'));
  });

  test('blocked versions cannot disappear but may move to the withdrawal ledger', () async {
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(entries: [workshopEntryJson(blocked: ['0.9.0'])]));
    await client.catalog();
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(at: '2026-11-12T00:00:00.000Z'));
    await expectLater(client.catalog(requireFresh: true), workshopError('workshop_catalog_rollback'));
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(at: '2026-11-12T00:00:00.000Z', withdrawn: [
      {'kind': 'pet', 'id': 'cat', 'version': '0.9.0', 'reason': 'withdrawn', 'at': workshopTestDate},
    ]));
    expect((await client.catalog(requireFresh: true)).catalog.blocked('pet', 'cat', '0.9.0'), isTrue);
  });

  test('clients sharing a cache serialize late responses and retain the newest withdrawal', () async {
    final entered = Completer<void>(), release = Completer<UpdateHttpResponse>();
    http.route = (_, _, _, _) { entered.complete(); return release.future; };
    final first = client.catalog(requireFresh: true);
    await entered.future;
    final gone = {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate};
    final secondHttp = FakeWorkshopHttp((_, _, _, _) => workshopJsonResponse(
      workshopCatalogJson(entries: [], withdrawn: [gone], at: '2026-11-12T00:00:00.000Z')));
    final secondClient = WorkshopClient(origin: workshopTestOrigin,
      cacheFile: File('${temp.path}/./catalog.json'), http: secondHttp);
    final second = secondClient.catalog(requireFresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(secondHttp.requests, isEmpty, reason: 'the earlier request still owns the cache transaction');
    release.complete(workshopJsonResponse(workshopCatalogJson()));
    await first;
    await second;
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(at: '2026-11-13T00:00:00.000Z'));
    await expectLater(client.catalog(requireFresh: true), workshopError('workshop_catalog_rollback'));
    final disk = jsonDecode(client.cacheFile.readAsStringSync()) as Map;
    expect(((disk['catalog'] as Map)['withdrawn'] as List).single['version'], '1.0.0');
    expect(File('${client.cacheFile.path}.part').existsSync(), isFalse);
  });

  test('redirect response is an error, never followed with the key', () async {
    http.route = (method, url, headers, _) {
      if (url.path.endsWith('/capabilities')) return workshopJsonResponse(workshopCaps());
      expect(headers['Authorization'], 'Bearer synthetic_test_token');
      return UpdateHttpResponse(status: 302, headers: {'location': 'https://other.example/steal'}, body: const Stream.empty());
    };
    await expectLater(client.submission(workshopTestId, credential: credential), workshopError('workshop_redirect'));
    expect(http.requests.every((r) => r.url.origin == workshopTestOrigin.origin), isTrue);
    expect(http.requests, hasLength(2));
  });

  test('both consent target and account origin must match before sending a token', () async {
    expect(() => WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin, account: workshopTestAccount,
      token: 'synthetic_test_token', disclosureAccepted: false), workshopError('workshop_consent_required'));
    final other = WorkshopCredential.forConsentedWorker(worker: Uri.parse('https://other.example'), account: workshopTestAccount,
      token: 'synthetic_test_token', disclosureAccepted: true);
    await expectLater(client.submission(workshopTestId, credential: other), workshopError('workshop_consent_required'));
    expect(http.requests, isEmpty);
    http.route = (_, _, _, _) => workshopJsonResponse(workshopCaps(account: 'https://different-account.example'));
    await expectLater(client.submission(workshopTestId, credential: credential), workshopError('workshop_account_origin'));
    expect(http.requests.every((r) => !r.headers.containsKey('Authorization')), isTrue);
    expect(credential.toString(), isNot(contains('synthetic_test_token')));
  });

  test('credential uses the Worker token charset and 255-character limit', () {
    expect(() => WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin, account: workshopTestAccount,
      token: 'a' * 255, disclosureAccepted: true), returnsNormally);
    expect(() => WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin, account: workshopTestAccount,
      token: 'a' * 256, disclosureAccepted: true), workshopError('workshop_account_auth_required'));
    expect(() => WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin, account: workshopTestAccount,
      token: 'gho-with-dash', disclosureAccepted: true), workshopError('workshop_account_auth_required'));
    expect(http.requests, isEmpty);
  });

  test('every author operation asserts the normalized account origin and accepts matching IPv6 response ownership', () async {
    const account = 'https://[2001:db8::1]';
    credential = WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin,
      account: Uri.parse('https://[2001:0db8:0000:0000:0000:0000:0000:0001]:443/'),
      token: 'synthetic_test_token', disclosureAccepted: true);
    Map<String, Object?> row(String status) => {
      ...workshopSubmissionJson(status: status),
      'owner': {'accountOrigin': account, 'accountId': 42, 'username': 'author'},
    };
    var authorCalls = 0;
    http.route = (method, url, headers, _) {
      if (url.path.endsWith('/capabilities')) {
        expect(headers.containsKey('Authorization'), isFalse);
        expect(headers.containsKey('X-Workshop-Account-Origin'), isFalse);
        return workshopJsonResponse(workshopCaps(account: account));
      }
      authorCalls++;
      expect(headers['Authorization'], 'Bearer synthetic_test_token');
      expect(headers['X-Workshop-Account-Origin'], account);
      if (url.path.endsWith('/reports')) {
        return workshopJsonResponse({'reportId': workshopTestId}, status: 201);
      }
      if (url.path.endsWith('/withdraw')) {
        return workshopJsonResponse({'submission': row('withdrawn')});
      }
      if (url.path.endsWith('/archive')) {
        return workshopJsonResponse({'submission': row('pending')});
      }
      if (method == 'GET' && url.path.endsWith('/submissions')) {
        return workshopJsonResponse({'submissions': [row('draft')], 'nextCursor': null});
      }
      return workshopJsonResponse({'submission': row('draft')}, status: method == 'POST' ? 201 : 200);
    };
    final draft = await client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()), requestId: workshopTestId,
      rightsConfirmed: true, credential: credential);
    final archive = File('${temp.path}/asserted.zip')..writeAsBytesSync([1, 2, 3, 4]);
    expect((await client.upload(draft, archive, credential: credential)).status, WorkshopSubmissionStatus.pending);
    expect((await client.submission(workshopTestId, credential: credential)).ownerOrigin, credential.account);
    expect((await client.submissions(credential: credential)).submissions.single.ownerOrigin, credential.account);
    expect((await client.withdraw(workshopTestId, 'take down', credential: credential)).status, WorkshopSubmissionStatus.withdrawn);
    expect(await client.report(kind: 'pet', id: 'cat', version: '1.0.0', reason: 'report', credential: credential), workshopTestId);
    expect(authorCalls, 6);
    expect(credential.account.toString(), account);
  });

  test('normalized account origins still reject a different single or paged response owner', () async {
    const account = 'https://[2001:db8::1]';
    credential = WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin, account: Uri.parse(account),
      token: 'synthetic_test_token', disclosureAccepted: true);
    final row = {...workshopSubmissionJson(),
      'owner': {'accountOrigin': 'https://[2001:db8::2]', 'accountId': 42, 'username': 'author'}};
    http.route = (_, url, _, _) {
      if (url.path.endsWith('/capabilities')) {
        return workshopJsonResponse(workshopCaps(account: account));
      }
      return workshopJsonResponse(url.path.endsWith('/submissions')
        ? {'submissions': [row], 'nextCursor': null} : {'submission': row});
    };
    await expectLater(client.submission(workshopTestId, credential: credential), workshopError('workshop_bad_response'));
    await expectLater(client.submissions(credential: credential), workshopError('workshop_bad_response'));
  });

  test('an account assertion conflict after capabilities is a known stable failure', () async {
    http.route = (_, url, _, _) => url.path.endsWith('/capabilities') ? workshopJsonResponse(workshopCaps()) :
      workshopJsonResponse({'error': 'workshop_account_origin'}, status: 409);
    await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()), requestId: workshopTestId,
      rightsConfirmed: true, credential: credential), workshopError('workshop_account_origin', unknown: false));
  });

  test('sharing-rights confirmation is explicit even for existing catalog metadata', () async {
    final meta = WorkshopEntry.fromJson(workshopEntryJson()).metadata;
    await expectLater(client.createSubmission(meta, requestId: WorkshopClient.newRequestId(), rightsConfirmed: false,
      credential: credential), workshopError('workshop_rights_required'));
    expect(http.requests, isEmpty);
  });

  test('create and upload use the same bounded bytes and keep private state out of cache', () async {
    final bytes = [1, 2, 3, 4];
    final meta = {...workshopMeta(bytes: bytes), 'description': 'A small cat', 'tags': ['pet', 'cat']};
    final progress = <List<int>>[];
    final archive = File('${temp.path}/archive.zip')..writeAsBytesSync(bytes);
    final requestId = WorkshopClient.newRequestId();
    http.route = (method, url, headers, body) {
      if (url.path.endsWith('/capabilities')) return workshopJsonResponse(workshopCaps());
      if (url.path.endsWith('/workshop.json')) return workshopJsonResponse(workshopCatalogJson());
      expect(headers['Authorization'], 'Bearer synthetic_test_token');
      if (method == 'POST') {
        final json = jsonDecode(utf8.decode(body!)) as Map;
        expect(json['requestId'], requestId);
        expect(json['rightsConfirmed'], isTrue);
        expect(json['description'], 'A small cat');
        expect(json['tags'], ['pet', 'cat']);
        expect(json.containsKey('Authorization'), isFalse);
        return workshopJsonResponse({'submission': workshopSubmissionJson(metadata: meta)}, status: 201);
      }
      expect(method, 'PUT');
      expect(headers['content-type'], 'application/zip');
      expect(body, bytes);
      return workshopJsonResponse({'submission': workshopSubmissionJson(status: 'pending', metadata: meta)});
    };
    final result = await client.submit(WorkshopMetadata.fromJson(meta), archive,
      requestId: requestId, rightsConfirmed: true, credential: credential,
      onProgress: (sent, total) => progress.add([sent, total]));
    expect(result.status, WorkshopSubmissionStatus.pending);
    expect(result.metadata.description, 'A small cat');
    expect(result.metadata.tags, ['pet', 'cat']);
    expect(progress, [[0, 4], [4, 4]]);
    expect(client.cacheFile.existsSync(), isFalse);
    await client.catalog();
    expect(client.cacheFile.readAsStringSync(), isNot(contains('synthetic_test_token')));
    expect(client.cacheFile.readAsStringSync(), isNot(contains('accountId')));
  });

  test('same requestId retry returns pending without uploading twice', () async {
    final archive = File('${temp.path}/archive.zip')..writeAsBytesSync([1, 2, 3, 4]);
    final progress = <List<int>>[];
    http.route = (_, url, _, _) => url.path.endsWith('/capabilities') ? workshopJsonResponse(workshopCaps()) :
      workshopJsonResponse({'submission': workshopSubmissionJson(status: 'pending')});
    final result = await client.submit(WorkshopMetadata.fromJson(workshopMeta()), archive,
      requestId: workshopTestId, rightsConfirmed: true, credential: credential,
      onProgress: (sent, total) => progress.add([sent, total]));
    expect(result.status, WorkshopSubmissionStatus.pending);
    expect(http.requests.where((r) => r.method == 'PUT'), isEmpty);
    expect(progress, isEmpty);
  });

  test('upload uses optional transport progress without changing old HTTP doubles', () async {
    final transport = _ProgressHttp((_, url, _, _) => url.path.endsWith('/capabilities')
      ? workshopJsonResponse(workshopCaps()) : workshopJsonResponse({'submission': workshopSubmissionJson(status: 'pending')}));
    final uploading = WorkshopClient(origin: workshopTestOrigin, cacheFile: client.cacheFile, http: transport);
    final archive = File('${temp.path}/progress.zip')..writeAsBytesSync([1, 2, 3, 4]);
    final progress = <List<int>>[];
    final result = await uploading.upload(WorkshopSubmission.fromJson(workshopSubmissionJson()), archive, credential: credential,
      onProgress: (sent, total) => progress.add([sent, total]));
    expect(result.status, WorkshopSubmissionStatus.pending);
    expect(transport.uploads, 1);
    expect(progress, [[0, 4], [2, 4], [4, 4]]);
  });

  test('complete fallback byte progress does not turn a rejected upload into success', () async {
    http.route = (_, url, _, _) => url.path.endsWith('/capabilities') ? workshopJsonResponse(workshopCaps()) :
      workshopJsonResponse({'error': 'workshop_account_origin'}, status: 409);
    final archive = File('${temp.path}/rejected-progress.zip')..writeAsBytesSync([1, 2, 3, 4]);
    final progress = <List<int>>[];
    await expectLater(client.upload(WorkshopSubmission.fromJson(workshopSubmissionJson()), archive, credential: credential,
      onProgress: (sent, total) => progress.add([sent, total])), workshopError('workshop_account_origin', unknown: false));
    expect(progress, [[0, 4], [4, 4]]);
  });

  test('write timeout and malformed success leave an explicitly unknown result', () async {
    http.route = (_, url, _, _) {
      if (url.path.endsWith('/capabilities')) return workshopJsonResponse(workshopCaps());
      throw TimeoutException('synthetic-test-key must not be exposed');
    };
    await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()), requestId: workshopTestId,
      rightsConfirmed: true, credential: credential), workshopError('workshop_timeout', unknown: true));
    http.route = (_, url, _, _) => url.path.endsWith('/capabilities') ? workshopJsonResponse(workshopCaps()) : workshopJsonResponse({'submission': {}});
    await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()), requestId: workshopTestId,
      rightsConfirmed: true, credential: credential), workshopError('workshop_bad_response', unknown: true));
  });

  test('withdraw and report remain available while uploads are paused', () async {
    http.route = (_, url, _, _) {
      if (url.path.endsWith('/capabilities')) return workshopJsonResponse(workshopCaps(uploads: false, companion: false));
      if (url.path.endsWith('/withdraw')) return workshopJsonResponse({'submission': workshopSubmissionJson(status: 'withdrawn')});
      return workshopJsonResponse({'reportId': workshopTestId}, status: 201);
    };
    expect((await client.withdraw(workshopTestId, 'take down', credential: credential)).status, WorkshopSubmissionStatus.withdrawn);
    expect(await client.report(kind: 'pet', id: 'cat', version: '1.0.0', reason: 'report', credential: credential), workshopTestId);
    await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()), requestId: workshopTestId,
      rightsConfirmed: true, credential: credential), workshopError('workshop_upload_disabled'));
  });

  test('pagination carries status/cursor without inventing a consistent snapshot', () async {
    http.route = (_, url, _, _) {
      if (url.path.endsWith('/capabilities')) return workshopJsonResponse(workshopCaps());
      expect(url.queryParameters, {'limit': '2', 'cursor': workshopTestId, 'status': 'rejected'});
      return workshopJsonResponse({'submissions': [workshopSubmissionJson(status: 'rejected')], 'nextCursor': null});
    };
    final page = await client.submissions(credential: credential, limit: 2, cursor: workshopTestId, status: WorkshopSubmissionStatus.rejected);
    expect(page.submissions.single.reviewReason, 'review reason');
    expect(page.nextCursor, isNull);
  });

  test('a legal 100-row multibyte submission page may exceed one MiB', () async {
    final rows = [for (var i = 0; i < 100; i++) {
      ...workshopSubmissionJson(id: i.toRadixString(16).padLeft(32, '0'), status: 'withdrawn',
        metadata: {...workshopMeta(id: 'cat-$i'), 'source': 'https://source.example/${'😀' * 1900}'}),
      'withdrawal': {'at': workshopTestDate, 'reason': '😀' * 2000},
    }];
    final value = {'submissions': rows, 'nextCursor': null};
    expect(utf8.encode(jsonEncode(value)).length, greaterThan(1024 * 1024));
    http.route = (_, url, _, _) => url.path.endsWith('/capabilities') ? workshopJsonResponse(workshopCaps()) : workshopJsonResponse(value);
    final page = await client.submissions(credential: credential, limit: 100);
    expect(page.submissions, hasLength(100));
    expect(page.submissions.last.withdrawalReason, '😀' * 2000);
  });

  test('submission list remains bounded at eight MiB without Content-Length', () async {
    http.route = (_, url, _, _) => url.path.endsWith('/capabilities') ? workshopJsonResponse(workshopCaps()) :
      UpdateHttpResponse(status: 200, body: Stream.fromIterable([
        List<int>.filled(4 * 1024 * 1024, 32), List<int>.filled(4 * 1024 * 1024 + 1, 32),
      ]));
    await expectLater(client.submissions(credential: credential, limit: 100), workshopError('workshop_bad_response'));
  });

  test('altered archive fails before any authenticated request', () async {
    final archive = File('${temp.path}/archive.zip')..writeAsBytesSync([4, 3, 2, 1]);
    await expectLater(client.upload(WorkshopSubmission.fromJson(workshopSubmissionJson()), archive, credential: credential), workshopError('workshop_sha_mismatch'));
    expect(http.requests, isEmpty);
  });

  test('server error details are discarded; retry-after is retained', () async {
    http.route = (_, _, _, _) => workshopJsonResponse({'error': 'workshop_rate_limited', 'detail': 'synthetic-secret'}, status: 429, headers: {'retry-after': '60'});
    try {
      await client.capabilities();
      fail('expected rate limit');
    } on WorkshopException catch (error) {
      expect(error.code, 'workshop_rate_limited');
      expect(error.retryAfter, const Duration(seconds: 60));
      expect(error.toString(), isNot(contains('synthetic-secret')));
    }
  });
}
