import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workshop_auth_test_support.dart';

const publishSource = WorkshopPublishSource(kind: 'pet', localId: 'user-cat', name: 'Cat');
WorkshopPublicationInput publishInput({bool rights = true}) => WorkshopPublicationInput(
  id: 'cat', titleZh: '小猫', titleEn: 'Cat', author: 'Author', license: 'CC0-1.0',
  source: 'https://source.example/cat', description: 'A small cat', tags: ['pet'], rightsConfirmed: rights,
);

WorkshopSubmission publishResult(WorkshopMetadata metadata, {String? id,
  WorkshopSubmissionStatus status = WorkshopSubmissionStatus.draft, int ownerId = 42, Uri? account}) =>
    WorkshopSubmission.fromJson({
      'submissionId': id ?? 'b' * 32, 'metadata': metadata.toJson(), 'status': status.name,
      'owner': {'accountOrigin': (account ?? authAccount).toString(), 'accountId': ownerId, 'username': 'test-user'},
      'createdAt': '2026-11-11T00:00:00.000Z', 'updatedAt': '2026-11-11T00:00:00.000Z',
    });

class PublishPreferences extends AuthPreferences {
  PublishPreferences(this.events) {
    accepted.add(pair(authWorker, authAccount));
  }
  final List<String> events;
  final ids = <String, String>{};
  final pending = <String, WorkshopPendingSubmission>{};
  final saved = <WorkshopPendingSubmission>[];
  final retired = <({String fingerprint, String requestId})>[];
  int reads = 0, clears = 0;
  Future<WorkshopPendingSubmission?> Function(String)? reading;
  Future<void> Function(String, String)? reserving;
  Future<void> Function(String, WorkshopPendingSubmission)? saving;
  Future<void> Function(String, String)? clearing;
  Future<void> Function(String, String)? retiring;

  @override
  Future<WorkshopPendingSubmission?> pendingSubmission(String scope) async {
    events.add('read-pending');
    reads++;
    return reading == null ? pending[scope] : await reading!(scope);
  }
  @override
  Future<String> reserveSubmissionRequestId(String fingerprint, String proposed) async {
    events.add('reserve');
    if (reserving != null) await reserving!(fingerprint, proposed);
    return ids.putIfAbsent(fingerprint, () => proposed);
  }
  @override
  Future<void> savePendingSubmission(String scope, WorkshopPendingSubmission value) async {
    events.add('save-pending');
    if (saving != null) await saving!(scope, value);
    final old = pending[scope];
    if (old != null && old.requestId != value.requestId) {
      throw const WorkshopException('workshop_pending_submission');
    }
    pending[scope] = value;
    saved.add(value);
  }
  @override
  Future<void> clearPendingSubmission(String scope, String expectedRequestId) async {
    events.add('clear-pending');
    clears++;
    if (clearing != null) await clearing!(scope, expectedRequestId);
    if (pending[scope]?.requestId == expectedRequestId) pending.remove(scope);
  }
  @override
  Future<void> retireSubmissionRequestId(String fingerprint, String expectedRequestId) async {
    events.add('retire');
    if (retiring != null) await retiring!(fingerprint, expectedRequestId);
    retired.add((fingerprint: fingerprint, requestId: expectedRequestId));
    if (ids[fingerprint] == expectedRequestId) ids.remove(fingerprint);
  }
}

class PublishCreateCall {
  PublishCreateCall(this.metadata, this.requestId, this.rights, this.credential);
  final WorkshopMetadata metadata;
  final String requestId;
  final bool rights;
  final WorkshopCredential credential;
}

class PublishUploadCall {
  PublishUploadCall(this.draft, this.archive, this.credential, this.progress);
  final WorkshopSubmission draft;
  final File archive;
  final WorkshopCredential credential;
  final void Function(int, int)? progress;
}

class PublishClient extends AuthClient {
  PublishClient(this.events, {super.worker});
  final List<String> events;
  final creates = <PublishCreateCall>[];
  final uploads = <PublishUploadCall>[];
  Future<WorkshopSubmission> Function(PublishCreateCall)? creating;
  Future<WorkshopSubmission> Function(PublishUploadCall)? uploading;

  @override
  Future<WorkshopSubmission> createSubmission(WorkshopMetadata metadata, {required String requestId,
    required bool rightsConfirmed, required WorkshopCredential credential}) async {
    events.add('create');
    final call = PublishCreateCall(metadata, requestId, rightsConfirmed, credential);
    creates.add(call);
    return creating == null ? publishResult(metadata) : await creating!(call);
  }
  @override
  Future<WorkshopSubmission> upload(WorkshopSubmission draft, File archive, {
    required WorkshopCredential credential, void Function(int, int)? onProgress}) async {
    events.add('upload');
    final call = PublishUploadCall(draft, archive, credential, onProgress);
    uploads.add(call);
    if (uploading != null) return await uploading!(call);
    onProgress?.call(0, draft.metadata.size);
    onProgress?.call(draft.metadata.size, draft.metadata.size);
    return publishResult(draft.metadata, id: draft.id, status: WorkshopSubmissionStatus.pending);
  }
}

class PublishDraftProbe {
  PublishDraftProbe(this.directoryName);
  final String directoryName;
  late final WorkshopPreparedDraft draft;
  int cleanups = 0;
  final firstCleanup = Completer<void>();
}

/// No archive, filesystem, network, or package parser runs in these tests.
/// Prepared files are opaque handles and the fake client never reads them.
class PublishDrafts {
  PublishDrafts(this.events);
  final List<String> events;
  final probes = <PublishDraftProbe>[];
  int preparations = 0, restorations = 0;
  Future<void> Function(PublishDraftProbe)? beforeReturn;
  Future<void> Function(PublishDraftProbe)? cleanup;
  Future<void> Function(WorkshopPendingSubmission)? restoring;

  PublishDraftProbe _draft(String name, WorkshopMetadata metadata, List<String> files, {bool retained = false}) {
    final probe = PublishDraftProbe(name);
    probe.draft = WorkshopPreparedDraft(
      upload: WorkshopPreparedUpload(file: File('private-test-exports/$name/archive.zip'), metadata: metadata, files: files),
      directoryName: name,
      cleanup: () async {
        events.add('cleanup');
        probe.cleanups++;
        try { if (cleanup != null) await cleanup!(probe); }
        finally { if (!probe.firstCleanup.isCompleted) probe.firstCleanup.complete(); }
      },
    )..retained = retained;
    probes.add(probe);
    return probe;
  }
  Future<WorkshopPreparedDraft> prepare(WorkshopPublishSource source, WorkshopPublication publication) async {
    events.add('prepare');
    final probe = _draft('draft-${++preparations}', publication.withArchive('a' * 64, 4), ['pack.json', 'idle.png']);
    if (beforeReturn != null) await beforeReturn!(probe);
    return probe.draft;
  }
  Future<WorkshopPreparedDraft> restore(WorkshopPendingSubmission pending) async {
    events.add('restore');
    restorations++;
    if (restoring != null) await restoring!(pending);
    return _draft(pending.directoryName, pending.metadata, pending.files, retained: true).draft;
  }
}

class _PublishClientChoice extends Notifier<PublishClient> {
  _PublishClientChoice(this.initial);
  final PublishClient initial;
  @override
  PublishClient build() => initial;
  void select(PublishClient client) => state = client;
}
final _publishClientChoice = NotifierProvider<_PublishClientChoice, PublishClient>(
  () => throw StateError('Missing publisher client choice'),
);

class PublishHarness {
  PublishHarness({PublishPreferences? preferences, PublishClient? client, PublishDrafts? drafts,
    WorkshopAccountState? initial, List<String>? events})
    : events = events ?? <String>[], account = AuthAccountController(initial ?? authSignedIn()) {
    this.preferences = preferences ?? PublishPreferences(this.events);
    this.client = client ?? PublishClient(this.events);
    this.drafts = drafts ?? PublishDrafts(this.events);
    container = ProviderContainer(overrides: [
      workshopAccountProvider.overrideWith(() => account),
      _publishClientChoice.overrideWith(() => _PublishClientChoice(this.client)),
      workshopClientProvider.overrideWith((ref) async => ref.watch(_publishClientChoice)),
      workshopPreferencesProvider.overrideWithValue(this.preferences),
      workshopPrepareDraftProvider.overrideWith((ref) {
        if (failPrepareProvider) throw StateError('Synthetic prepare provider initialization failure');
        return this.drafts.prepare;
      }),
      workshopRestoreDraftProvider.overrideWithValue(this.drafts.restore),
      workshopRequestIdProvider.overrideWith((ref) {
        if (failRequestIdProvider) throw StateError('Synthetic request id provider initialization failure');
        return () => (++idsProposed).toRadixString(16).padLeft(32, '0');
      }),
      workshopSourcesLoaderProvider.overrideWithValue(() async => WorkshopPublishSources(values: [publishSource])),
    ]);
  }
  final List<String> events;
  final AuthAccountController account;
  late final PublishPreferences preferences;
  late final PublishClient client;
  late final PublishDrafts drafts;
  late final ProviderContainer container;
  int idsProposed = 0;
  bool failPrepareProvider = false, failRequestIdProvider = false;
  bool disposed = false;

  WorkshopPublishController get controller => container.read(workshopPublishProvider.notifier);
  WorkshopPublishState get state => container.read(workshopPublishProvider);
  Future<void> start() async {
    await authReady(container);
    await controller.restorePending();
  }
  Future<void> prepared({bool rights = true}) async {
    await start();
    controller.selectSource(publishSource);
    controller.setInput(publishInput(rights: rights));
    await controller.prepare();
  }
  void chooseClient(PublishClient client) => container.read(_publishClientChoice.notifier).select(client);
  void dispose() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }
  Future<void> close() async {
    dispose();
    // Every non-retained fake draft must at least reach cleanup. Callers must
    // release/settle their operation gates before entering this final drain.
    await Future.wait(drafts.probes.where((probe) => !probe.draft.retained)
      .map((probe) => probe.firstCleanup.future));
  }
}
