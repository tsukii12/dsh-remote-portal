import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show FakeWorkshopHttp, workshopCaps, workshopJsonResponse, workshopSubmissionJson;
import 'workshop_auth_test_support.dart';
import 'workshop_publish_test_support.dart';
import 'workshop_recovery_test_support.dart';

const _unknown = WorkshopException('workshop_timeout', resultUnknown: true);

Future<void> _unknownSubmission(PublishHarness harness) async {
  await harness.prepared();
  harness.client.creating = (_) async => throw _unknown;
  await harness.controller.submit();
  expect(harness.state.hasPending, isTrue);
  expect(harness.state.pendingKnownUnsent, isFalse);
  expect(harness.state.error, same(_unknown));
}

class _DraftResponseClient extends PublishClient {
  _DraftResponseClient(super.events) {
    httpProbe = FakeWorkshopHttp((method, url, headers, body) {
      if (method == 'GET' && url.path == '/api/workshop/v1/capabilities') {
        return workshopJsonResponse(workshopCaps());
      }
      if (method == 'POST' && url.path == '/api/workshop/v1/submissions') {
        final request = (jsonDecode(utf8.decode(body!)) as Map).cast<String, Object?>();
        final metadata = WorkshopMetadata.fromJson(request);
        return workshopJsonResponse({'submission': workshopSubmissionJson(metadata: metadata.toJson())});
      }
      throw StateError('Unexpected HTTP in missing-archive test');
    });
    real = WorkshopClient(origin: authWorker, cacheFile: File('unused-pending-recovery-cache.json'), http: httpProbe);
  }
  late final FakeWorkshopHttp httpProbe;
  late final WorkshopClient real;

  @override
  Future<WorkshopSubmission> createSubmission(WorkshopMetadata metadata, {required String requestId,
    required bool rightsConfirmed, required WorkshopCredential credential}) {
    creates.add(PublishCreateCall(metadata, requestId, rightsConfirmed, credential));
    return real.createSubmission(metadata, requestId: requestId,
      rightsConfirmed: rightsConfirmed, credential: credential);
  }

  @override
  Future<WorkshopSubmission> upload(WorkshopSubmission draft, File archive, {
    required WorkshopCredential credential, void Function(int, int)? onProgress}) {
    uploads.add(PublishUploadCall(draft, archive, credential, onProgress));
    return real.upload(draft, archive, credential: credential, onProgress: onProgress);
  }

  @override
  void close() {
    real.close();
    super.close();
  }
}

/// Only this case supplies a real missing File in a private temporary
/// directory, so the production client (not a fake storage error) rejects it.
class _MissingArchiveDrafts extends PublishDrafts {
  _MissingArchiveDrafts(super.events, this.missing);
  final File missing;
  @override
  Future<WorkshopPreparedDraft> restore(WorkshopPendingSubmission pending) async {
    restorations++;
    final probe = PublishDraftProbe(pending.directoryName);
    probe.draft = WorkshopPreparedDraft(
      upload: WorkshopPreparedUpload(file: missing, metadata: pending.metadata, files: pending.files),
      directoryName: pending.directoryName,
      cleanup: () async {
        probe.cleanups++;
        if (!probe.firstCleanup.isCompleted) probe.firstCleanup.complete();
      },
    )..retained = true;
    probes.add(probe);
    return probe.draft;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final whole in [false, true]) {
    test('${whole ? 'container' : 'entry'} corruption needs an explicit scoped offer before local recovery', () async {
      final scope = recoveryScope(), other = recoveryScope(userId: 43);
      final raw = whole ? '{' : jsonEncode({scope: {'directoryName': '../not-a-private-draft'}, other: null});
      final platform = recoveryPlatform({recoveryPendingKey: raw});
      final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
      try {
        await harness.start();
        expect(harness.state.pendingChecked, isFalse);
        expect(harness.state.preferenceError!.code, 'workshop_preferences');
        expect(harness.state.canRequestPendingAbandonment, isTrue);
        expect(harness.state.canDiscardUnsentSubmission, isFalse);
        expect(harness.drafts.restorations, 0);
        final error = harness.state.error;
        await harness.controller.requestPendingAbandonment();
        final offer = harness.state.abandonOffer!;
        expect(offer.range, whole ? WorkshopPendingAbandonRange.allLocalAccounts : WorkshopPendingAbandonRange.currentAccount);
        expect((offer.worker, offer.account, offer.accountId), (authWorker, authAccount, 42));
        expect(harness.state.error, same(error));
        expect(await platform.raw(recoveryPendingKey), raw);
        expect(harness.drafts.probes, isEmpty);
        expect(harness.client.creates, isEmpty);
        await harness.controller.confirmPendingAbandonment(offer);
        expect(harness.state.phase, WorkshopPublishPhase.idle);
        expect(harness.state.pendingChecked, isTrue);
        expect(harness.state.canEditMetadata, isTrue);
        expect(harness.state.hasPending, isFalse);
        expect(harness.state.abandonOffer, isNull);
        expect(harness.state.error, isNull);
        expect(harness.state.preferenceError, isNull);
        expect(harness.drafts.probes, isEmpty); // No path from the bad record was opened or cleaned.
        expect(await platform.raw(recoveryPendingKey), whole ? null : jsonEncode({other: null}));
        expect(harness.client.creates, isEmpty);
        expect(harness.client.uploads, isEmpty);
      } finally { await harness.close(); }
    });
  }

  test('an unreadable store gives no offer and retries only after the storage read succeeds', () async {
    final platform = recoveryPlatform({recoveryPendingKey: '{'})..failRead = true;
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await harness.start();
      expect(harness.state.preferenceError!.code, 'workshop_preferences');
      await harness.controller.requestPendingAbandonment();
      expect(harness.state.abandonOffer, isNull);
      expect(harness.state.recoveryError!.code, 'workshop_preferences');
      expect(platform.pendingWrites + platform.pendingRemoves, 0);
      platform.failRead = false;
      await harness.controller.requestPendingAbandonment();
      expect(harness.state.recoveryError, isNull);
      expect(harness.state.abandonOffer!.range, WorkshopPendingAbandonRange.allLocalAccounts);
      expect(await platform.raw(recoveryPendingKey), '{');
    } finally { await harness.close(); }
  });

  test('a custom preferences implementation without recovery cannot silently fall back to another store', () async {
    final harness = PublishHarness();
    try {
      await _unknownSubmission(harness);
      await harness.controller.requestPendingAbandonment();
      expect(harness.state.recoveryError!.code, 'workshop_recovery_unsupported');
      expect(harness.state.error, same(_unknown));
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.abandonOffer, isNull);
      expect(harness.preferences.pending, hasLength(1));
      expect(harness.drafts.probes.single.draft.retained, isTrue);
      expect(harness.client.creates, hasLength(1));
    } finally { await harness.close(); }
  });

  test('local abandonment preserves unknown evidence until confirmation and never reruns a remote preflight', () async {
    final platform = recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await _unknownSubmission(harness);
      final pending = preferences.saved.single;
      final ids = await platform.raw(recoveryRequestsKey);
      final capabilityReads = harness.client.capabilityReads;
      harness.client.readCapabilities = () async => throw const WorkshopException('workshop_network');
      await harness.controller.requestPendingAbandonment();
      final offer = harness.state.abandonOffer!;
      expect(harness.state.error, same(_unknown));
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.pendingKnownUnsent, isFalse);
      expect(harness.state.canDiscardUnsentSubmission, isFalse);
      expect(harness.drafts.probes.single.cleanups, 0);
      expect((await preferences.real.pendingSubmission(recoveryScope()))!.requestId, pending.requestId);
      await harness.controller.confirmPendingAbandonment(offer);
      expect(harness.state.hasPending, isFalse);
      expect(harness.state.phase, WorkshopPublishPhase.idle);
      expect(harness.state.input.titleZh, publishInput().titleZh);
      expect(harness.state.input.rightsConfirmed, isFalse);
      expect(harness.state.preparedMetadata, isNull);
      expect(harness.state.result, isNull);
      expect(harness.drafts.probes.single.cleanups, 1);
      expect(await platform.raw(recoveryRequestsKey), ids);
      expect(harness.client.capabilityReads, capabilityReads);
      expect(harness.client.creates, hasLength(1));
      expect(harness.client.uploads, isEmpty);
    } finally { await harness.close(); }
  });

  for (final persisted in [false, true]) {
    test('confirmation write failure persisted=$persisted retains intent, offer and owned ZIP for a retry', () async {
      final platform = recoveryPlatform();
      final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
      try {
        await _unknownSubmission(harness);
        await harness.controller.requestPendingAbandonment();
        final offer = harness.state.abandonOffer!;
        platform.failPendingWrite = true;
        platform.persistBeforeFailure = persisted;
        await harness.controller.confirmPendingAbandonment(offer);
        expect(harness.state.recoveryError!.code, 'workshop_preferences');
        expect(harness.state.error, same(_unknown));
        expect(harness.state.abandonOffer, same(offer));
        expect(harness.state.hasPending, isTrue);
        expect(harness.state.busy, isFalse);
        expect(harness.drafts.probes.single.draft.retained, isTrue);
        expect(harness.drafts.probes.single.cleanups, 0);
        platform.failPendingWrite = false;
        await harness.controller.confirmPendingAbandonment(offer);
        expect(harness.state.hasPending, isFalse);
        expect(harness.state.recoveryError, isNull);
        expect(harness.state.abandonOffer, isNull);
        expect(harness.drafts.probes.single.cleanups, 1);
        expect(harness.client.creates, hasLength(1));
        expect(await preferences.real.pendingSubmission(recoveryScope()), isNull);
      } finally { await harness.close(); }
    });
  }

  test('a changed stored request rejects the old offer and keeps the current in-memory intent', () async {
    recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await _unknownSubmission(harness);
      await harness.controller.requestPendingAbandonment();
      final offer = harness.state.abandonOffer!, original = preferences.saved.single;
      final scope = recoveryScope(), replacement = recoveryPending(requestId: 'e' * 32);
      await preferences.real.clearPendingSubmission(scope, original.requestId);
      await preferences.real.savePendingSubmission(scope, replacement);
      await harness.controller.confirmPendingAbandonment(offer);
      expect(harness.state.recoveryError!.code, 'workshop_confirmation_stale');
      expect(harness.state.abandonOffer, isNull);
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.error, same(_unknown));
      expect((await preferences.real.pendingSubmission(scope))!.requestId, replacement.requestId);
      expect(harness.drafts.probes.single.draft.retained, isTrue);
      expect(harness.drafts.probes.single.cleanups, 0);
    } finally { await harness.close(); }
  });

  test('a normal same-intent retry invalidates an earlier local-abandon confirmation', () async {
    recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await _unknownSubmission(harness);
      await harness.controller.requestPendingAbandonment();
      final offer = harness.state.abandonOffer!;
      await harness.controller.retrySubmission();
      expect(harness.state.abandonOffer, isNull);
      await harness.controller.confirmPendingAbandonment(offer);
      expect(harness.state.recoveryError!.code, 'workshop_confirmation_stale');
      expect(preferences.abandonments, 0);
      expect(harness.state.hasPending, isTrue);
      expect(harness.client.creates, hasLength(2));
      expect(harness.client.creates.first.requestId, harness.client.creates.last.requestId);
    } finally { await harness.close(); }
  });

  test('a held confirmation keeps the owned draft borrowed until the conditional write settles', () async {
    final platform = recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? settled;
    try {
      await _unknownSubmission(harness);
      await harness.controller.requestPendingAbandonment();
      final offer = harness.state.abandonOffer!;
      platform.beforePendingWrite = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final pending = harness.controller.confirmPendingAbandonment(offer);
      settled = authSettled(pending);
      await authSignal(entered, pending);
      expect(harness.state.busy, isTrue);
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.canRequestPendingAbandonment, isFalse);
      expect(harness.drafts.probes.single.cleanups, 0);
      await harness.controller.confirmPendingAbandonment(offer);
      expect(preferences.abandonments, 1);
      release.complete();
      await pending;
      expect(harness.state.hasPending, isFalse);
      expect(harness.state.busy, isFalse);
      expect(harness.drafts.probes.single.cleanups, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await harness.close();
    }
  });

  for (final changeWorker in [false, true]) {
    test('a late offer from a previous ${changeWorker ? 'Worker' : 'account'} cannot enter the replacement session', () async {
      recoveryPlatform();
      final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
      final entered = Completer<void>(), release = Completer<void>();
      Future<void>? settled;
      try {
        await _unknownSubmission(harness);
        final session = harness.state.session;
        preferences.afterRecoveryRead = () async {
          entered.complete();
          await release.future;
        };
        final pending = harness.controller.requestPendingAbandonment();
        settled = authSettled(pending);
        await authSignal(entered, pending);
        if (changeWorker) {
          final next = PublishClient([], worker: Uri.parse('https://other-workshop.example'));
          preferences.accepted.add(preferences.pair(next.origin, authAccount));
          harness.chooseClient(next);
        } else {
          harness.account.emit(authSignedIn(userId: 43));
        }
        await authReady(harness.container);
        expect(harness.state.session, isNot(same(session)));
        expect(harness.state.waitingForPreviousOperation, isTrue);
        release.complete();
        await pending;
        expect(harness.state.abandonOffer, isNull);
        expect(harness.state.recoveryError, isNull);
        expect(harness.state.waitingForPreviousOperation, isFalse);
        expect(harness.state.pendingChecked, isFalse);
        expect(await preferences.real.pendingSubmission(recoveryScope()), isNotNull);
        expect(preferences.abandonments, 0);
      } finally {
        if (!release.isCompleted) release.complete();
        if (settled != null) await settled;
        await harness.close();
      }
    });
  }

  test('an old offered token cannot clear a different account after the session changes', () async {
    recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await _unknownSubmission(harness);
      await harness.controller.requestPendingAbandonment();
      final offer = harness.state.abandonOffer!;
      final nextScope = recoveryScope(userId: 43);
      await preferences.real.savePendingSubmission(nextScope, recoveryPending(scope: nextScope));
      harness.account.emit(authSignedIn(userId: 43));
      await authReady(harness.container);
      await harness.controller.confirmPendingAbandonment(offer);
      expect(harness.state.recoveryError!.code, 'workshop_confirmation_stale');
      expect(preferences.abandonments, 0);
      expect(await preferences.real.pendingSubmission(recoveryScope()), isNotNull);
      expect(await preferences.real.pendingSubmission(nextScope), isNotNull);
    } finally { await harness.close(); }
  });

  test('an already accepted local clear may settle its old scope but cannot publish into a new session', () async {
    final platform = recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? settled;
    try {
      await _unknownSubmission(harness);
      final nextScope = recoveryScope(userId: 43);
      await preferences.real.savePendingSubmission(nextScope, recoveryPending(scope: nextScope));
      await harness.controller.requestPendingAbandonment();
      final offer = harness.state.abandonOffer!, session = harness.state.session;
      platform.beforePendingWrite = () async {
        entered.complete();
        await release.future;
      };
      final pending = harness.controller.confirmPendingAbandonment(offer);
      settled = authSettled(pending);
      await authSignal(entered, pending);
      harness.account.emit(authSignedIn(userId: 43));
      await authReady(harness.container);
      expect(harness.state.session, isNot(same(session)));
      expect(harness.state.waitingForPreviousOperation, isTrue);
      release.complete();
      await pending;
      expect(harness.state.waitingForPreviousOperation, isFalse);
      expect(harness.state.pendingChecked, isFalse);
      expect(harness.state.abandonOffer, isNull);
      expect(harness.state.preparedMetadata, isNull);
      expect(await preferences.real.pendingSubmission(recoveryScope()), isNull);
      expect(await preferences.real.pendingSubmission(nextScope), isNotNull);
      expect(harness.drafts.probes.single.cleanups, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await harness.close();
    }
  });

  test('owned cleanup failure is separate from a successful journal abandonment and can be retried', () async {
    recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await _unknownSubmission(harness);
      harness.drafts.cleanup = (_) async => throw const FileSystemException('Synthetic private draft cleanup failure');
      await harness.controller.requestPendingAbandonment();
      await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
      expect(harness.state.hasPending, isFalse);
      expect(harness.state.phase, WorkshopPublishPhase.idle);
      expect(harness.state.recoveryError, isNull);
      expect(harness.state.cleanupError!.code, 'workshop_draft_cleanup');
      expect(harness.state.canEditMetadata, isTrue);
      expect(await preferences.real.pendingSubmission(recoveryScope()), isNull);
      harness.drafts.cleanup = null;
      await harness.controller.retryCleanup();
      expect(harness.state.cleanupError, isNull);
      expect(harness.drafts.probes.single.cleanups, 2);
      expect(harness.client.creates, hasLength(1));
    } finally { await harness.close(); }
  });

  test('abandonment retains request-id mappings so exact metadata reuses an id but edited content can get a new one', () async {
    recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await _unknownSubmission(harness);
      final first = harness.client.creates.single;
      await harness.controller.requestPendingAbandonment();
      await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
      expect(harness.controller.setInput(harness.state.input.copyWith(rightsConfirmed: true)), isTrue);
      await harness.controller.prepare();
      await harness.controller.submit();
      expect(harness.client.creates.last.metadata.toJson(), first.metadata.toJson());
      expect(harness.client.creates.last.requestId, first.requestId);
      await harness.controller.requestPendingAbandonment();
      await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
      expect(harness.controller.setInput(harness.state.input.copyWith(titleZh: '重新整理的小猫', rightsConfirmed: true)), isTrue);
      await harness.controller.prepare();
      await harness.controller.submit();
      expect(harness.client.creates.last.requestId, isNot(first.requestId));
      expect(harness.client.creates, hasLength(3));
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.error, same(_unknown));
      final edited = harness.client.creates.last;
      await harness.controller.requestPendingAbandonment();
      await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
      expect(harness.controller.setPreview(const WorkshopPreviewInput.petIdle()), isTrue);
      expect(harness.controller.setInput(harness.state.input.copyWith(rightsConfirmed: true)), isTrue);
      await harness.controller.prepare();
      await harness.controller.submit();
      expect(harness.client.creates.last.metadata.previewSource, 'pet-idle');
      expect(harness.client.creates.last.metadata.sha256, edited.metadata.sha256);
      expect(harness.client.creates.last.requestId, isNot(edited.requestId));
      expect(harness.client.creates, hasLength(4));
    } finally { await harness.close(); }
  });

  test('a cold restored intent can be knowingly abandoned without a source or any automatic HTTP', () async {
    final scope = recoveryScope(), pending = recoveryPending();
    recoveryPlatform({recoveryPendingKey: jsonEncode({scope: pending.toJson()})});
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await harness.start();
      expect(harness.state.source, isNull);
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.pendingKnownUnsent, isFalse);
      expect(harness.state.canDiscardUnsentSubmission, isFalse);
      await harness.controller.requestPendingAbandonment();
      await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
      expect(harness.state.source, isNull);
      expect(harness.state.hasPending, isFalse);
      expect(harness.state.canEditMetadata, isTrue);
      expect(harness.state.input.titleZh, pending.metadata.title['zh']);
      expect(harness.state.input.rightsConfirmed, isFalse);
      expect(harness.drafts.probes.single.cleanups, 1);
      expect(harness.client.creates, isEmpty);
      expect(harness.client.uploads, isEmpty);
      await harness.controller.prepare();
      expect(harness.state.error!.code, 'workshop_source_required');
    } finally { await harness.close(); }
  });

  test('a real missing ZIP after a real-client draft response has an explicit local exit without a PUT or remote cancellation', () async {
    final directory = await Directory.systemTemp.createTemp('workshop-pending-recovery-');
    final missing = File('${directory.path}/missing.zip');
    final scope = recoveryScope(), pending = recoveryPending();
    recoveryPlatform({recoveryPendingKey: jsonEncode({scope: pending.toJson()})});
    final preferences = RecoveryPreferences([]), client = _DraftResponseClient([]);
    final drafts = _MissingArchiveDrafts([], missing);
    final harness = PublishHarness(preferences: preferences, client: client, drafts: drafts);
    try {
      await harness.start();
      expect(harness.state.source, isNull);
      expect(await missing.exists(), isFalse);
      expect(harness.controller.setInput(harness.state.input.copyWith(rightsConfirmed: true)), isTrue);
      await harness.controller.retrySubmission();
      expect(client.creates, hasLength(1));
      expect(client.creates.single.requestId, pending.requestId);
      expect(client.uploads, hasLength(1));
      expect(client.uploads.single.draft.status, WorkshopSubmissionStatus.draft);
      expect(harness.state.error!.code, 'workshop_storage');
      expect(harness.state.hasPending, isTrue);
      expect(harness.state.pendingKnownUnsent, isFalse);
      expect(harness.state.result, isNull);
      expect(client.httpProbe.requests.map((request) => request.method), ['GET', 'POST']);
      await harness.controller.requestPendingAbandonment();
      expect(harness.state.hasPending, isTrue);
      await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
      expect(harness.state.phase, WorkshopPublishPhase.idle);
      expect(harness.state.hasPending, isFalse);
      expect(harness.state.source, isNull);
      expect(client.httpProbe.requests.map((request) => request.method), ['GET', 'POST']);
      expect(await preferences.real.pendingSubmission(scope), isNull);
      expect(drafts.probes.single.cleanups, 1);
    } finally {
      await harness.close();
      client.close();
      await directory.delete(recursive: true);
    }
  });

  for (final status in [WorkshopSubmissionStatus.pending,
    WorkshopSubmissionStatus.rejected, WorkshopSubmissionStatus.withdrawn]) {
    test('a known $status result survives informed repair of its unreadable local journal', () async {
      final platform = recoveryPlatform();
      final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
      try {
        await harness.prepared();
        harness.client.creating = (call) async {
          // The saved journal becomes unreadable while a known response is
          // returning; the real _finishKnown clear then fails to parse it.
          await platform.setValue('String', 'flutter.$recoveryPendingKey', '{');
          return publishResult(call.metadata, status: status);
        };
        await harness.controller.submit();
        final result = harness.state.result!, pending = preferences.saved.single;
        final ids = await platform.raw(recoveryRequestsKey);
        expect(harness.state.phase, WorkshopPublishPhase.complete);
        expect(result.status, status);
        expect(harness.state.hasPending, isTrue);
        expect(harness.state.preferenceError!.code, 'workshop_preferences');
        expect(harness.state.canStartNewSubmission, isFalse);
        expect(harness.state.canRequestPendingAbandonment, isTrue);
        expect(harness.controller.setInput(harness.state.input.copyWith(rightsConfirmed: false)), isTrue);
        await harness.controller.retrySubmission();
        expect(harness.state.hasPending, isTrue);
        expect(harness.state.preferenceError!.code, 'workshop_preferences');
        expect(harness.client.creates, hasLength(1));
        await harness.controller.requestPendingAbandonment();
        expect(harness.state.abandonOffer!.range, WorkshopPendingAbandonRange.allLocalAccounts);
        expect(harness.state.result, same(result));
        expect(await platform.raw(recoveryPendingKey), '{');
        platform.failPendingWrite = true;
        await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
        expect(harness.state.recoveryError!.code, 'workshop_preferences');
        expect(harness.state.result, same(result));
        expect(harness.state.hasPending, isTrue);
        expect(harness.drafts.probes.single.draft.retained, isTrue);
        platform.failPendingWrite = false;
        await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
        expect(harness.state.result, same(result));
        expect(harness.state.phase, WorkshopPublishPhase.complete);
        expect(harness.state.hasPending, isFalse);
        expect(harness.state.preferenceError, isNull);
        expect(harness.state.recoveryError, isNull);
        expect(harness.state.preparedMetadata!.toJson(), result.metadata.toJson());
        expect(harness.state.input.rightsConfirmed, isFalse);
        expect(harness.drafts.probes.single.cleanups, 1);
        expect(await platform.raw(recoveryRequestsKey), ids); // No implicit retirement.
        expect(harness.client.creates, hasLength(1));
        expect(harness.client.uploads, isEmpty);
        if (status == WorkshopSubmissionStatus.pending) {
          expect(harness.state.canStartNewSubmission, isFalse);
          await harness.controller.retrySubmission();
          expect(harness.state.result, same(result));
          expect(harness.state.hasPending, isFalse);
          expect(await platform.raw(recoveryRequestsKey), ids);
        } else {
          expect(harness.state.canStartNewSubmission, isTrue);
          await harness.controller.startNewSubmission();
          expect(harness.state.phase, WorkshopPublishPhase.idle);
          expect(harness.state.result, isNull);
          expect(await preferences.real.reserveSubmissionRequestId(pending.fingerprint, 'f' * 32), 'f' * 32);
        }
        expect(harness.client.creates, hasLength(1));
        expect(harness.client.uploads, isEmpty);
      } finally { await harness.close(); }
    });
  }

  test('a healthy known non-draft result never offers local abandonment', () async {
    recoveryPlatform();
    final preferences = RecoveryPreferences([]), harness = PublishHarness(preferences: preferences);
    try {
      await harness.prepared();
      harness.client.creating = (call) async => publishResult(call.metadata, status: WorkshopSubmissionStatus.pending);
      await harness.controller.submit();
      expect(harness.state.phase, WorkshopPublishPhase.complete);
      expect(harness.state.result!.status, WorkshopSubmissionStatus.pending);
      expect(harness.state.hasPending, isFalse);
      expect(harness.state.preferenceError, isNull);
      expect(harness.state.canRequestPendingAbandonment, isFalse);
      await harness.controller.requestPendingAbandonment();
      expect(preferences.recoveryReads, 0);
      expect(harness.state.abandonOffer, isNull);
      await harness.controller.retrySubmission();
      expect(harness.state.hasPending, isFalse);
      expect(harness.client.creates, hasLength(1));
    } finally { await harness.close(); }
  });
}
