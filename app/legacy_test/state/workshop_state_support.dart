import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final stateOrigin = Uri.parse('https://workshop.example');
final otherStateOrigin = Uri.parse('https://other-workshop.example');

WorkshopEntry stateEntry({String kind = 'pet', String id = 'cat', String version = '2.0.0',
  String minApp = '1.0.0', String author = 'Author', String zh = '小猫', String en = 'Cat',
  List<String> blocked = const []}) {
  final hash = 'a' * 64;
  return WorkshopEntry.fromJson({
    'kind': kind, 'id': id, 'version': version, 'minApp': minApp,
    'title': {'zh': zh, 'en': en}, 'author': author, 'license': 'CC0-1.0',
    'source': 'https://source.example/cat', 'sha256': hash, 'size': 4,
    'url': '/market/workshop/$kind/$id/$version/$hash.zip', 'blockedVersions': blocked,
  });
}

WorkshopCatalogSnapshot stateSnapshot({List<WorkshopEntry>? entries, bool stale = false,
  bool companion = true, WorkshopException? refreshError, String? cacheIssue}) => WorkshopCatalogSnapshot(
    catalog: WorkshopCatalog.fromJson({
      'schema': 1, 'generatedAt': '2026-11-11T00:00:00.000Z',
      'features': {'uploads': true, 'companion': companion},
      'entries': (entries ?? [stateEntry()]).map((entry) => entry.toJson()).toList(), 'withdrawn': [],
    }),
    fetchedAt: DateTime.utc(2026, 11, 11), stale: stale,
    refreshError: refreshError, cacheIssue: cacheIssue,
  );

WorkshopInstalled stateInstalled({String kind = 'pet', String id = 'cat', String version = '1.0.0',
  String? localId, Uri? origin, String? issue}) => WorkshopInstalled(
    localId: localId ?? (kind == 'companion' ? 'companion' : 'user:$id'), issue: issue,
    receipt: WorkshopReceipt(kind: kind, id: id, version: version, sha256: 'a' * 64, origin: origin ?? stateOrigin),
  );

class _NoNetwork extends WorkshopHttp {
  @override
  Future<UpdateHttpResponse> request(String method, Uri url, {Map<String, String> headers = const {},
    List<int>? body, Duration timeout = const Duration(seconds: 30)}) async {
    throw StateError('State tests must not perform HTTP');
  }
}

int _sourceId = 0;

class StateClient extends WorkshopClient {
  StateClient({Uri? origin}) : super(origin: origin ?? stateOrigin,
    cacheFile: File('state-test-cache-${_sourceId++}.json'), http: _NoNetwork());
  WorkshopCatalogSnapshot? cached;
  WorkshopCatalogSnapshot network = stateSnapshot();
  String? issue;
  int cacheReads = 0, networkReads = 0;
  final events = <String>[];
  Future<WorkshopCatalogSnapshot?> Function()? readCached;
  Future<WorkshopCatalogSnapshot> Function(bool requireFresh)? readNetwork;

  @override
  String? get cacheIssue => issue;
  @override
  Future<WorkshopCatalogSnapshot?> cachedCatalog() async {
    cacheReads++;
    events.add('cache');
    return readCached == null ? cached : await readCached!();
  }
  @override
  Future<WorkshopCatalogSnapshot> catalog({bool requireFresh = false}) async {
    networkReads++;
    events.add(requireFresh ? 'fresh' : 'network');
    return readNetwork == null ? network : await readNetwork!(requireFresh);
  }
}

class StatePackages implements WorkshopPackages {
  List<WorkshopLocalEntry> rows = [];
  final removed = <WorkshopInstalled>[];
  final installedCalls = <({WorkshopReceipt receipt, bool replaceExisting})>[];
  Future<List<WorkshopLocalEntry>> Function()? list;
  Future<void> Function(WorkshopInstalled)? removeAction;

  @override
  Future<List<WorkshopLocalEntry>> installed() async => list == null ? List.of(rows) : await list!();
  @override
  Future<int> copyOverhead(String kind) async => 0;
  @override
  Future<WorkshopInstalled> install(File archive, WorkshopReceipt receipt, {required bool replaceExisting}) async {
    installedCalls.add((receipt: receipt, replaceExisting: replaceExisting));
    final result = WorkshopInstalled(
      localId: receipt.kind == 'companion' ? 'companion' : 'user:${receipt.id}', receipt: receipt);
    rows = [...rows.where((row) => row.localId != result.localId), result];
    return result;
  }
  @override
  Future<void> remove(WorkshopInstalled installed) async {
    removed.add(installed);
    if (removeAction != null) await removeAction!(installed);
    rows = rows.where((row) => !identical(row, installed)).toList();
  }
}

class StateInstallCall {
  StateInstallCall(this.entry, this.replaceExisting, this.cancel, this.onProgress, this.onVerifying);
  final WorkshopEntry entry;
  final bool replaceExisting;
  final CancelToken? cancel;
  final void Function(DownloadProgress)? onProgress;
  final void Function()? onVerifying;
}

/// Only installation scheduling is scripted. Catalog/installed projections are
/// the real repository methods, over fake packages and a fake client.
class StateRepository extends WorkshopRepository {
  StateRepository(StateClient client, StatePackages packages, {super.appVersion = '2.0.0'})
    : super(client: client, packages: packages, downloadDirectory: Directory('state-test-download-${_sourceId++}'),
      freeBytes: () async => null);
  final calls = <StateInstallCall>[];
  Future<WorkshopInstalled> Function(StateInstallCall)? installAction;

  Future<WorkshopInstalled> commit(StateInstallCall call) {
    final metadata = call.entry.metadata;
    return packages.install(File('unused-test-archive.zip'), WorkshopReceipt(
      kind: metadata.kind, id: metadata.id, version: metadata.version,
      sha256: metadata.sha256, origin: client.origin), replaceExisting: call.replaceExisting);
  }

  @override
  Future<WorkshopInstalled> install(WorkshopEntry requested, {bool replaceExisting = false, CancelToken? cancel,
    void Function(DownloadProgress)? onProgress, void Function()? onVerifying}) async {
    final call = StateInstallCall(requested, replaceExisting, cancel, onProgress, onVerifying);
    calls.add(call);
    return installAction == null ? await commit(call) : await installAction!(call);
  }
}

class StateSource {
  StateSource(this.client, this.repository);
  final StateClient client;
  final StateRepository repository;
}

final _sourcesProvider = Provider<List<StateSource>>((ref) => throw StateError('Test sources missing'));
final stateSourceIndexProvider = NotifierProvider<StateSourceIndex, int>(StateSourceIndex.new);
class StateSourceIndex extends Notifier<int> {
  @override
  int build() => 0;
  void select(int value) => state = value;
}

ProviderContainer stateContainer({required StatePackages packages, required List<StateSource> sources,
  bool configured = true, WorkshopPackageChanged? changed,
  Future<StateClient> Function(StateSource)? loadClient,
  Future<WorkshopPackages> Function()? loadPackages,
  Future<WorkshopRepository> Function(StateSource)? loadRepository}) => ProviderContainer(overrides: [
    _sourcesProvider.overrideWithValue(sources),
    workshopClientProvider.overrideWith((ref) async {
      final source = ref.watch(_sourcesProvider)[ref.watch(stateSourceIndexProvider)];
      if (!configured) workshopInvalid('workshop_unconfigured');
      return loadClient == null ? source.client : await loadClient(source);
    }),
    workshopRepositoryProvider.overrideWith((ref) async {
      final source = ref.watch(_sourcesProvider)[ref.watch(stateSourceIndexProvider)];
      final clientFuture = ref.watch(workshopClientProvider.future);
      final packagesFuture = ref.watch(workshopPackagesProvider.future);
      await Future.wait<Object>([clientFuture, packagesFuture]);
      return loadRepository == null ? source.repository : await loadRepository(source);
    }),
    workshopPackagesProvider.overrideWith((ref) async => loadPackages == null ? packages : await loadPackages()),
    workshopAppVersionProvider.overrideWithValue('2.0.0'),
    workshopPackageChangedProvider.overrideWithValue(changed ?? (item, {required removed}) async {}),
  ]);

/// Install observers before releasing a gate, including during failed asserts.
Future<void> stateSettled<T>(Future<T> pending) => pending.then<void>((_) {},
  onError: (Object error, StackTrace stack) {});

Future<void> stateSignal<T>(Completer<void> signal, Future<T> pending) => Future.any([
  signal.future,
  pending.then<void>((_) {
    if (!signal.isCompleted) fail('Operation settled before its expected signal');
  }),
]);
