import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show FakeWorkshopHttp, workshopCaps, workshopJsonResponse, workshopSubmissionJson;
import 'workshop_auth_test_support.dart';
import 'workshop_publish_test_support.dart';

/// Auth and archive preparation use the existing memory harness. The mutation
/// itself runs the real Client preflight, HTTP boundary and response parser.
/// The fake transport records the exact request method; no socket/file opens.
class _PreflightPublishClient extends PublishClient {
  _PreflightPublishClient(super.events) {
    transport = FakeWorkshopHttp((method, url, headers, body) {
      if (method == 'GET' && url.path == '/api/workshop/v1/capabilities') {
        return workshopJsonResponse(workshopCaps(companion: companionEnabled));
      }
      if (method == 'POST' && url.path == '/api/workshop/v1/submissions') {
        if (postFailure != null) {
          throw postFailure!;
        }
        if (rejectAfterPost) {
          return workshopJsonResponse({'error': 'workshop_companion_disabled'}, status: 409);
        }
        final metadata = WorkshopMetadata.fromJson(jsonDecode(utf8.decode(body!)));
        return workshopJsonResponse({'submission': workshopSubmissionJson(
          metadata: metadata.toJson(), status: 'pending')});
      }
      throw StateError('Unexpected publisher recovery request: $method ${url.path}');
    });
    delegate = WorkshopClient(origin: origin, cacheFile: File('unused-publish-recovery-cache.json'), http: transport);
  }
  late final FakeWorkshopHttp transport;
  late final WorkshopClient delegate;
  bool companionEnabled = false, rejectAfterPost = false;
  SocketException? postFailure;
  int get posts => transport.requests.where((request) => request.method == 'POST').length;

  @override
  Future<WorkshopSubmission> createSubmission(WorkshopMetadata metadata, {required String requestId,
    required bool rightsConfirmed, required WorkshopCredential credential}) {
    events.add('create');
    creates.add(PublishCreateCall(metadata, requestId, rightsConfirmed, credential));
    return delegate.createSubmission(metadata, requestId: requestId,
      rightsConfirmed: rightsConfirmed, credential: credential);
  }
}

Future<void> _prepareCompanion(PublishHarness h) async {
  await h.start();
  expect(h.controller.selectSource(const WorkshopPublishSource(
    kind: 'companion', localId: 'companion', name: '小猫伙伴')), isTrue);
  expect(h.controller.setInput(publishInput()), isTrue);
  await h.controller.prepare();
  expect(h.state.phase, WorkshopPublishPhase.ready);
}

void main() {
  test('real create preflight rejection can leave its unsent journal and select a pet', () async {
    final events = <String>[];
    final client = _PreflightPublishClient(events);
    final h = PublishHarness(client: client, events: events);
    try {
      await _prepareCompanion(h);
      final input = h.state.input;
      await h.controller.submit();
      final pending = h.preferences.pending.values.single;
      expect(h.state.error?.code, 'workshop_companion_disabled');
      expect(h.state.error?.mutationNotSent, isTrue);
      expect(h.state.error?.resultUnknown, isFalse);
      expect(client.posts, 0);
      expect(client.transport.requests.single.method, 'GET');
      expect(h.state.hasPending, isTrue);
      expect(h.state.pendingKnownUnsent, isTrue);
      expect(h.state.canDiscardUnsentSubmission, isTrue);
      expect(h.state.canEditMetadata, isFalse);
      expect(h.drafts.probes.single.draft.retained, isTrue);
      await h.controller.discardUnsentSubmission();
      expect(h.state.phase, WorkshopPublishPhase.idle);
      expect(h.state.hasPending, isFalse);
      expect(h.state.pendingKnownUnsent, isFalse);
      expect(h.state.canDiscardUnsentSubmission, isFalse);
      expect(h.state.canEditMetadata, isTrue);
      expect(h.state.source?.kind, 'companion');
      expect(h.state.input.declaration('companion'), input.declaration('companion'));
      expect(h.state.input.rightsConfirmed, isFalse);
      expect(h.state.preparedMetadata, isNull);
      expect(h.preferences.pending, isEmpty);
      expect(h.preferences.ids[pending.fingerprint], pending.requestId);
      expect(h.preferences.retired, isEmpty);
      expect(h.drafts.probes.single.cleanups, 1);
      expect(client.transport.requests, hasLength(1));
      expect(h.controller.selectSource(publishSource), isTrue);
      expect(h.controller.setInput(publishInput()), isTrue);
      await h.controller.prepare();
      await h.controller.submit();
      expect(client.posts, 1);
      expect(client.creates.last.metadata.kind, 'pet');
      expect(client.creates.last.requestId, isNot(pending.requestId));
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
      expect(h.state.hasPending, isFalse);
    } finally { await h.close(); }
  });

  test('the same error code returned by an actual POST does not permit discarding', () async {
    final events = <String>[];
    final client = _PreflightPublishClient(events)
      ..companionEnabled = true
      ..rejectAfterPost = true;
    final h = PublishHarness(client: client, events: events);
    try {
      await _prepareCompanion(h);
      await h.controller.submit();
      final pending = h.preferences.pending.values.single;
      expect(client.posts, 1);
      expect(h.state.error?.code, 'workshop_companion_disabled');
      expect(h.state.error?.mutationNotSent, isFalse);
      expect(h.state.error?.resultUnknown, isFalse);
      expect(h.state.pendingKnownUnsent, isFalse);
      expect(h.state.canDiscardUnsentSubmission, isFalse);
      final refusal = h.state.error;
      await h.controller.discardUnsentSubmission();
      expect(h.state.error, same(refusal));
      expect(h.preferences.pending.values.single, same(pending));
      expect(h.preferences.clears, 0);
      expect(h.drafts.probes.single.draft.retained, isTrue);
      expect(client.posts, 1);
    } finally { await h.close(); }
  });

  test('a later unsent preflight cannot erase an earlier unknown create', () async {
    final events = <String>[];
    final client = _PreflightPublishClient(events)..companionEnabled = true
      ..postFailure = const SocketException('Synthetic response loss');
    final h = PublishHarness(client: client, events: events);
    try {
      await _prepareCompanion(h);
      await h.controller.submit();
      final pending = h.preferences.pending.values.single;
      expect(h.state.error?.resultUnknown, isTrue);
      expect(h.state.canDiscardUnsentSubmission, isFalse);
      expect(client.posts, 1);
      final unknown = h.state.error;
      await h.controller.discardUnsentSubmission();
      expect(h.state.error, same(unknown));
      expect(h.state.error?.resultUnknown, isTrue);
      expect(h.preferences.clears, 0);
      client.companionEnabled = false;
      client.postFailure = null;
      await h.controller.retrySubmission();
      expect(h.state.error?.code, 'workshop_companion_disabled');
      expect(h.state.error?.mutationNotSent, isTrue);
      expect(h.state.pendingKnownUnsent, isFalse);
      expect(h.state.canDiscardUnsentSubmission, isFalse);
      expect(client.posts, 1);
      expect(client.creates.map((call) => call.requestId), [pending.requestId, pending.requestId]);
      final preflight = h.state.error;
      await h.controller.discardUnsentSubmission();
      expect(h.state.error, same(preflight));
      expect(h.preferences.pending.values.single, same(pending));
      expect(h.preferences.clears, 0);
      expect(h.drafts.probes.single.cleanups, 0);
      client.companionEnabled = true;
      await h.controller.retrySubmission();
      expect(client.creates.last.requestId, pending.requestId);
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
      expect(h.preferences.pending, isEmpty);
    } finally { await h.close(); }
  });

  test('a restored journal has no in-memory unsent proof even after a new preflight rejection', () async {
    final events = <String>[];
    final client = _PreflightPublishClient(events);
    final first = PublishHarness(client: client, events: events);
    PublishHarness? recovered;
    try {
      await _prepareCompanion(first);
      await first.controller.submit();
      final pending = first.preferences.pending.values.single;
      expect(first.state.canDiscardUnsentSubmission, isTrue);
      await first.close();
      final next = _PreflightPublishClient(events);
      recovered = PublishHarness(client: next, preferences: first.preferences, events: events);
      await recovered.start();
      expect(recovered.state.source, isNull);
      expect(recovered.state.hasPending, isTrue);
      expect(recovered.state.pendingKnownUnsent, isFalse);
      expect(recovered.state.canDiscardUnsentSubmission, isFalse);
      expect(next.transport.requests, isEmpty);
      recovered.controller.setInput(recovered.state.input.copyWith(rightsConfirmed: true));
      await recovered.controller.retrySubmission();
      expect(recovered.state.error?.mutationNotSent, isTrue);
      expect(next.posts, 0);
      expect(recovered.state.canDiscardUnsentSubmission, isFalse);
      final preflight = recovered.state.error;
      await recovered.controller.discardUnsentSubmission();
      expect(recovered.state.error, same(preflight));
      expect(first.preferences.pending.values.single.requestId, pending.requestId);
      expect(first.preferences.clears, 0);
      expect(recovered.drafts.probes.single.draft.retained, isTrue);
    } finally {
      if (recovered != null) await recovered.close();
      await first.close();
    }
  });

  test('a failed journal setter before create can be cleared without sending any request', () async {
    final h = PublishHarness();
    h.preferences.saving = (scope, pending) async {
      h.preferences.pending[scope] = pending;
      throw const WorkshopException('workshop_preferences');
    };
    try {
      await h.prepared();
      await h.controller.submit();
      final pending = h.preferences.pending.values.single;
      expect(h.client.creates, isEmpty);
      expect(h.state.preferenceError?.code, 'workshop_preferences');
      expect(h.state.canDiscardUnsentSubmission, isTrue);
      await h.controller.discardUnsentSubmission();
      expect(h.preferences.pending, isEmpty);
      expect(h.preferences.ids[pending.fingerprint], pending.requestId);
      expect(h.state.hasPending, isFalse);
      expect(h.state.preferenceError, isNull);
      expect(h.state.canEditMetadata, isTrue);
      expect(h.drafts.probes.single.cleanups, 1);
      expect(h.client.creates, isEmpty);
    } finally { await h.close(); }
  });

  for (final removedBeforeFailure in [false, true]) {
    test('unsent journal clear failure after disk removal=$removedBeforeFailure stays retained and retries locally', () async {
      final events = <String>[];
      final client = _PreflightPublishClient(events);
      final h = PublishHarness(client: client, events: events);
      try {
        await _prepareCompanion(h);
        await h.controller.submit();
        final pending = h.preferences.pending.values.single;
        h.preferences.clearing = (scope, expected) async {
          expect(expected, pending.requestId);
          if (removedBeforeFailure && h.preferences.pending[scope]?.requestId == expected) {
            h.preferences.pending.remove(scope);
          }
          throw const WorkshopException('workshop_preferences');
        };
        await h.controller.discardUnsentSubmission();
        expect(h.state.preferenceError?.code, 'workshop_preferences');
        expect(h.state.hasPending, isTrue);
        expect(h.state.canDiscardUnsentSubmission, isTrue);
        expect(h.state.canEditMetadata, isFalse);
        expect(h.preferences.pending.length, removedBeforeFailure ? 0 : 1);
        expect(h.drafts.probes.single.draft.retained, isTrue);
        expect(h.drafts.probes.single.cleanups, 0);
        expect(h.controller.selectSource(publishSource), isFalse);
        h.preferences.clearing = null;
        await h.controller.discardUnsentSubmission();
        expect(h.state.hasPending, isFalse);
        expect(h.state.preferenceError, isNull);
        expect(h.state.error, isNull);
        expect(h.state.canEditMetadata, isTrue);
        expect(h.preferences.pending, isEmpty);
        expect(h.preferences.ids[pending.fingerprint], pending.requestId);
        expect(h.drafts.probes.single.cleanups, 1);
        expect(client.transport.requests, hasLength(1));
        expect(client.posts, 0);
      } finally { await h.close(); }
    });
  }

  test('late unsent discard clears only its captured account and releases the draft after storage settles', () async {
    final events = <String>[];
    final client = _PreflightPublishClient(events);
    final h = PublishHarness(client: client, events: events);
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? pending, settled;
    try {
      await _prepareCompanion(h);
      await h.controller.submit();
      final oldSession = h.state.session;
      final old = h.preferences.pending.entries.single;
      h.preferences.clearing = (scope, expected) async {
        expect(scope, old.key);
        expect(expected, old.value.requestId);
        entered.complete();
        await release.future;
      };
      pending = h.controller.discardUnsentSubmission();
      settled = authSettled(pending);
      await authSignal(entered, pending);
      expect(h.state.busy, isTrue);
      expect(h.state.canDiscardUnsentSubmission, isFalse);
      expect(h.drafts.probes.single.draft.retained, isTrue);
      expect(h.drafts.probes.single.cleanups, 0);
      await h.controller.discardUnsentSubmission();
      expect(h.state.error, isNull);
      expect(h.state.busy, isTrue);
      expect(h.preferences.clears, 1);
      h.account.emit(authSignedIn(credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      await authReady(h.container);
      expect(h.state.session, isNot(same(oldSession)));
      expect(h.state.waitingForPreviousOperation, isTrue);
      release.complete();
      await pending;
      expect(h.preferences.pending, isEmpty);
      expect(h.preferences.ids[old.value.fingerprint], old.value.requestId);
      expect(h.drafts.probes.single.cleanups, 1);
      expect(h.state.source, isNull);
      expect(h.state.result, isNull);
      expect(h.state.pendingChecked, isFalse);
      expect(h.state.pendingKnownUnsent, isFalse);
      expect(h.state.hasPending, isFalse);
      expect(h.state.working, isFalse);
      expect(client.posts, 0);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });

  test('known unsent local cleanup needs no rights, profile or successful capabilities refresh', () async {
    const credentials = WorkshopAccountCredential('TEST_ONLY_KEY_A');
    final events = <String>[];
    final client = _PreflightPublishClient(events);
    final h = PublishHarness(client: client, events: events,
      initial: authSignedIn(credential: credentials));
    try {
      await _prepareCompanion(h);
      await h.controller.submit();
      final session = h.state.session;
      expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: false)), isTrue);
      h.account.emit(authSignedIn(credential: credentials, userId: null));
      await authReady(h.container);
      expect(h.state.session, same(session));
      expect(h.container.read(workshopAccessProvider).accountId, isNull);
      client.readCapabilities = () async => throw const WorkshopException('workshop_network');
      await h.container.read(workshopAccessProvider.notifier).refresh();
      expect(h.container.read(workshopAccessProvider).error?.code, 'workshop_network');
      expect(h.state.session, same(session));
      final reads = client.capabilityReads;
      await h.controller.discardUnsentSubmission();
      expect(h.state.hasPending, isFalse);
      expect(h.state.input.rightsConfirmed, isFalse);
      expect(h.state.error, isNull);
      expect(client.capabilityReads, reads);
      expect(client.transport.requests, hasLength(1));
      expect(client.posts, 0);
    } finally { await h.close(); }
  });

  test('owned archive cleanup failure does not recreate a cleared unsent journal', () async {
    final events = <String>[];
    final client = _PreflightPublishClient(events);
    final h = PublishHarness(client: client, events: events);
    h.drafts.cleanup = (_) async => throw StateError('Synthetic cleanup failure');
    try {
      await _prepareCompanion(h);
      await h.controller.submit();
      await h.controller.discardUnsentSubmission();
      expect(h.state.phase, WorkshopPublishPhase.idle);
      expect(h.state.hasPending, isFalse);
      expect(h.state.canEditMetadata, isTrue);
      expect(h.state.error, isNull);
      expect(h.state.cleanupError?.code, 'workshop_draft_cleanup');
      expect(h.preferences.pending, isEmpty);
      expect(h.drafts.probes.single.draft.retained, isFalse);
      h.drafts.cleanup = null;
      await h.controller.retryCleanup();
      expect(h.state.cleanupError, isNull);
      expect(h.drafts.probes.single.cleanups, 2);
      expect(client.transport.requests, hasLength(1));
      expect(client.posts, 0);
    } finally {
      h.drafts.cleanup = null;
      await h.close();
    }
  });

  test('editing waits for one successful pending check and later keystrokes are synchronous', () async {
    final h = PublishHarness();
    try {
      await authReady(h.container);
      expect(h.controller.selectSource(publishSource), isFalse);
      expect(h.state.error?.code, 'workshop_pending_check_required');
      await h.controller.restorePending();
      expect(h.state.pendingChecked, isTrue);
      expect(h.preferences.reads, 1);
      expect(h.controller.selectSource(publishSource), isTrue);
      expect(h.state.input.rightsConfirmed, isFalse);
      expect(h.controller.setInput(publishInput()), isTrue);
      expect(h.controller.setInput(h.state.input.copyWith(titleEn: 'Another cat')), isTrue);
      expect(h.state.input.titleEn, 'Another cat');
      await h.controller.restorePending();
      await h.container.read(workshopPublishSourcesProvider.notifier).refresh();
      expect(h.state.input.titleEn, 'Another cat');
      expect(h.preferences.reads, 1);
      expect(h.client.creates, isEmpty);
      expect(h.client.uploads, isEmpty);
    } finally { await h.close(); }
  });

  test('failed cold pending storage is not an empty journal and explicit retry can recover', () async {
    final h = PublishHarness();
    h.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
    try {
      await h.start();
      expect(h.state.pendingChecked, isFalse);
      expect(h.state.preferenceError?.code, 'workshop_preferences');
      expect(h.controller.selectSource(publishSource), isFalse);
      await h.controller.prepare();
      expect(h.drafts.preparations, 0);
      expect(h.client.creates, isEmpty);
      h.preferences.reading = null;
      await h.controller.restorePending();
      expect(h.state.pendingChecked, isTrue);
      expect(h.state.preferenceError, isNull);
      expect(h.preferences.reads, 2);
      expect(h.controller.selectSource(publishSource), isTrue);
    } finally { await h.close(); }
  });

  test('unknown profile cannot check an account journal and first profile arrival can retry', () async {
    const credentials = WorkshopAccountCredential('TEST_ONLY_KEY_A');
    final h = PublishHarness(initial: authSignedIn(credential: credentials, userId: null));
    try {
      await h.start();
      final session = h.state.session;
      expect(h.state.error?.code, 'workshop_profile_required');
      expect(h.preferences.reads, 0);
      h.account.emit(authSignedIn(credential: credentials));
      await authReady(h.container);
      expect(h.state.session, same(session));
      await h.controller.restorePending();
      expect(h.state.pendingChecked, isTrue);
      expect(h.preferences.reads, 1);
    } finally { await h.close(); }
  });

  test('field validation precedes prepare and rights confirmation is required only for submit', () async {
    final h = PublishHarness();
    try {
      await h.start();
      h.controller.selectSource(publishSource);
      await h.controller.prepare();
      expect(h.state.fieldErrors.keys, containsAll(['author', 'license', 'source']));
      expect(h.drafts.preparations, 0);
      h.controller.setInput(publishInput(rights: false));
      await h.controller.prepare();
      final metadata = h.state.preparedMetadata;
      expect(metadata, isNotNull);
      await h.controller.submit();
      expect(h.state.fieldErrors['rightsConfirmed'], 'workshop_rights_required');
      expect(h.client.creates, isEmpty);
      expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: true)), isTrue);
      expect(h.state.preparedMetadata, same(metadata));
      await h.controller.submit();
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
    } finally { await h.close(); }
  });

  test('metadata edits including attribution and discovery fields invalidate the prepared archive', () async {
    final h = PublishHarness();
    try {
      await h.prepared();
      final edits = [
        h.state.input.copyWith(id: 'another-cat'),
        h.state.input.copyWith(author: 'Another author'),
        h.state.input.copyWith(license: 'CC-BY-4.0'),
        h.state.input.copyWith(source: 'https://source.example/another'),
        h.state.input.copyWith(titleZh: '另一只猫'),
        h.state.input.copyWith(titleEn: 'Another cat'),
        h.state.input.copyWith(version: '2.0.0'),
        h.state.input.copyWith(minApp: '2.0.0'),
        h.state.input.copyWith(description: 'Another description'),
        h.state.input.copyWith(tags: ['cat', 'pet']),
      ];
      for (final input in edits) {
        final old = h.drafts.probes.last;
        expect(h.controller.setInput(input), isTrue);
        expect(h.state.preparedMetadata, isNull);
        expect(h.state.files, isEmpty);
        await h.controller.prepare();
        expect(old.cleanups, 1);
        expect(h.state.preparedMetadata?.author, input.author);
        expect(h.state.preparedMetadata?.license, input.license);
        expect(h.state.preparedMetadata?.source, input.source);
        expect(h.state.preparedMetadata?.description, input.description);
        expect(h.state.preparedMetadata?.tags, input.tags);
      }
      expect(h.client.creates, isEmpty);
    } finally { await h.close(); }
  });

  test('persisted intent precedes create and 100 percent waits for the server response', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? pending, settled;
    h.client.uploading = (call) async {
      call.progress?.call(1, 4);
      call.progress?.call(4, 4);
      entered.complete();
      await release.future;
      return publishResult(call.draft.metadata, id: call.draft.id, status: WorkshopSubmissionStatus.pending);
    };
    try {
      await h.prepared();
      pending = h.controller.submit();
      settled = authSettled(pending);
      await authSignal(entered, pending);
      expect(h.events, ['read-pending', 'prepare', 'reserve', 'save-pending', 'create', 'upload']);
      expect(h.state.phase, WorkshopPublishPhase.awaitingResponse);
      expect([h.state.sent, h.state.total], [4, 4]);
      expect(h.state.result, isNull);
      expect(h.state.hasPending, isTrue);
      expect(h.drafts.probes.single.cleanups, 0);
      expect(h.controller.setInput(h.state.input.copyWith(titleEn: 'Busy edit')), isFalse);
      await h.controller.submit();
      expect(h.state.error?.code, 'workshop_busy');
      expect(h.client.creates, hasLength(1));
      release.complete();
      await pending;
      expect(h.state.phase, WorkshopPublishPhase.complete);
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
      expect(h.state.result?.id, isNot(h.client.creates.single.requestId));
      expect(h.state.error, isNull);
      expect(h.state.hasPending, isFalse);
      expect(h.preferences.pending, isEmpty);
      expect(h.drafts.probes.single.cleanups, 1);
      expect(h.events.sublist(h.events.length - 2), ['clear-pending', 'cleanup']);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });
  test('request id storage failure sends nothing and a persisted first id survives retry', () async {
    final h = PublishHarness();
    String? firstId;
    h.preferences.reserving = (fingerprint, proposed) async {
      firstId = proposed;
      h.preferences.ids[fingerprint] = proposed;
      throw const WorkshopException('workshop_preferences');
    };
    try {
      await h.prepared();
      await h.controller.submit();
      expect(h.state.preferenceError?.code, 'workshop_preferences');
      expect(h.client.creates, isEmpty);
      expect(h.drafts.probes.single.draft.retained, isFalse);
      h.preferences.reserving = null;
      await h.controller.retrySubmission();
      expect(h.client.creates.single.requestId, firstId);
      expect(h.idsProposed, 2);
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
    } finally { await h.close(); }
  });

  test('journal write uncertainty retains the archive before save and retries the exact intent', () async {
    final h = PublishHarness();
    WorkshopPendingSubmission? attempted;
    h.preferences.saving = (scope, value) async {
      expect(h.drafts.probes.single.draft.retained, isTrue);
      attempted = value;
      h.preferences.pending[scope] = value;
      throw const WorkshopException('workshop_preferences');
    };
    try {
      await h.prepared();
      await h.controller.submit();
      expect(h.state.preferenceError?.code, 'workshop_preferences');
      expect(h.state.hasPending, isTrue);
      expect(h.client.creates, isEmpty);
      expect(h.drafts.probes.single.cleanups, 0);
      expect(h.controller.selectSource(publishSource), isFalse);
      expect(h.state.error?.code, 'workshop_pending_submission');
      expect(h.controller.setInput(h.state.input.copyWith(author: 'Changed')), isFalse);
      h.preferences.saving = null;
      await h.controller.retrySubmission();
      expect(h.client.creates.single.requestId, attempted!.requestId);
      expect(h.client.creates.single.metadata.toJson(), attempted!.metadata.toJson());
      expect(h.idsProposed, 1);
      expect(h.state.preferenceError, isNull);
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
    } finally { await h.close(); }
  });

  test('unknown create keeps the same request and cannot silently start a new submission', () async {
    final h = PublishHarness();
    h.client.creating = (_) async => throw const WorkshopException('workshop_network', resultUnknown: true);
    try {
      await h.prepared();
      await h.controller.submit();
      final first = h.client.creates.single;
      expect(h.state.error?.resultUnknown, isTrue);
      expect(h.state.hasPending, isTrue);
      expect(h.drafts.probes.single.draft.retained, isTrue);
      await h.controller.startNewSubmission();
      expect(h.state.error?.code, 'workshop_new_submission_unavailable');
      expect(h.preferences.retired, isEmpty);
      expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: false)), isTrue);
      await h.controller.retrySubmission();
      expect(h.client.creates, hasLength(1));
      h.controller.setInput(h.state.input.copyWith(rightsConfirmed: true));
      h.client.creating = (call) async => publishResult(call.metadata, status: WorkshopSubmissionStatus.pending);
      await h.controller.retrySubmission();
      expect(h.client.creates.last.requestId, first.requestId);
      expect(h.client.creates.last.metadata.toJson(), first.metadata.toJson());
      expect(h.client.uploads, isEmpty);
      expect(h.preferences.pending, isEmpty);
    } finally { await h.close(); }
  });

  test('cold recovery is read-only and reconciles a known result before needing an archive', () async {
    final first = PublishHarness();
    PublishHarness? recovered;
    first.client.creating = (_) async => throw const WorkshopException('workshop_network', resultUnknown: true);
    try {
      await first.prepared();
      await first.controller.submit();
      final id = first.client.creates.single.requestId;
      await first.close();
      recovered = PublishHarness(preferences: first.preferences);
      recovered.client.creating = (call) async => publishResult(call.metadata, status: WorkshopSubmissionStatus.approved);
      recovered.client.uploading = (_) async => throw StateError('A known result must not open or upload the missing archive');
      await recovered.start();
      expect(recovered.state.hasPending, isTrue);
      expect(recovered.state.source, isNull);
      expect(recovered.state.preparedMetadata?.id, 'cat');
      expect(recovered.drafts.restorations, 1);
      expect(recovered.client.creates, isEmpty);
      expect(recovered.client.uploads, isEmpty);
      await recovered.controller.retrySubmission();
      expect(recovered.client.creates.single.requestId, id);
      expect(recovered.client.uploads, isEmpty);
      expect(recovered.state.result?.status, WorkshopSubmissionStatus.approved);
      expect(recovered.preferences.pending, isEmpty);
    } finally {
      if (recovered != null) await recovered.close();
      await first.close();
    }
  });

  test('a journal fingerprint must match the account scope and complete metadata', () async {
    final first = PublishHarness();
    PublishHarness? recovered;
    first.client.creating = (_) async => throw const WorkshopException('workshop_network', resultUnknown: true);
    try {
      await first.prepared();
      await first.controller.submit();
      final entry = first.preferences.pending.entries.single;
      first.preferences.pending[entry.key] = WorkshopPendingSubmission(
        requestId: entry.value.requestId, fingerprint: 'f' * 64,
        directoryName: entry.value.directoryName, metadata: entry.value.metadata, files: entry.value.files);
      await first.close();
      recovered = PublishHarness(preferences: first.preferences);
      await recovered.start();
      expect(recovered.state.pendingChecked, isFalse);
      expect(recovered.state.preferenceError?.code, 'workshop_preferences');
      expect(recovered.drafts.restorations, 0);
      expect(recovered.client.creates, isEmpty);
      expect(recovered.controller.selectSource(publishSource), isFalse);
      expect(first.preferences.pending, hasLength(1));
    } finally {
      if (recovered != null) await recovered.close();
      await first.close();
    }
  });

  for (final mismatch in ['metadata', 'ownerId', 'ownerOrigin', 'uploadId']) {
    test('a $mismatch response mismatch is unknown and cannot clear the original journal', () async {
      final h = PublishHarness();
      if (mismatch == 'uploadId') {
        h.client.uploading = (call) async => publishResult(call.draft.metadata,
          id: 'c' * 32, status: WorkshopSubmissionStatus.pending);
      } else {
        h.client.creating = (call) async => publishResult(
          mismatch == 'metadata' ? WorkshopMetadata.fromJson({...call.metadata.toJson(), 'author': 'Other'}) : call.metadata,
          ownerId: mismatch == 'ownerId' ? 43 : 42,
          account: mismatch == 'ownerOrigin' ? Uri.parse('https://another-account.example') : authAccount,
        );
      }
      try {
        await h.prepared();
        await h.controller.submit();
        expect(h.state.error?.code, 'workshop_bad_response');
        expect(h.state.error?.resultUnknown, isTrue);
        expect(h.state.result, isNull);
        expect(h.state.hasPending, isTrue);
        expect(h.preferences.clears, 0);
        expect(h.preferences.pending, hasLength(1));
        expect(h.drafts.probes.single.cleanups, 0);
        expect(h.client.uploads.length, mismatch == 'uploadId' ? 1 : 0);
      } finally { await h.close(); }
    });
  }
  test('journal removal failure preserves the known result and local retry needs no new rights confirmation', () async {
    final h = PublishHarness();
    h.preferences.clearing = (_, _) async => throw const WorkshopException('workshop_preferences');
    try {
      await h.prepared();
      await h.controller.submit();
      final known = h.state.result;
      expect(known?.status, WorkshopSubmissionStatus.pending);
      expect(h.state.phase, WorkshopPublishPhase.complete);
      expect(h.state.preferenceError?.code, 'workshop_preferences');
      expect(h.state.error, isNull);
      expect(h.state.hasPending, isTrue);
      expect(h.drafts.probes.single.draft.retained, isTrue);
      expect(h.drafts.probes.single.cleanups, 0);
      await h.controller.retryCleanup();
      expect(h.state.preferenceError?.code, 'workshop_preferences');
      expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: false)), isTrue);
      final capabilityReads = h.client.capabilityReads;
      h.preferences.clearing = null;
      await h.controller.retrySubmission();
      expect(h.state.result, same(known));
      expect(h.state.preferenceError, isNull);
      expect(h.state.hasPending, isFalse);
      expect(h.client.creates, hasLength(1));
      expect(h.client.uploads, hasLength(1));
      expect(h.client.capabilityReads, capabilityReads);
      expect(h.drafts.probes.single.cleanups, 1);
    } finally { await h.close(); }
  });

  test('cleanup failure is separate from submission success and explicit retry only cleans', () async {
    final h = PublishHarness();
    h.drafts.cleanup = (_) async => throw StateError('Synthetic owned-directory cleanup failure');
    try {
      await h.prepared();
      await h.controller.submit();
      final result = h.state.result;
      expect(result?.status, WorkshopSubmissionStatus.pending);
      expect(h.state.hasPending, isFalse);
      expect(h.state.error, isNull);
      expect(h.state.cleanupError?.code, 'workshop_draft_cleanup');
      expect(h.preferences.pending, isEmpty);
      h.drafts.cleanup = null;
      await h.controller.retryCleanup();
      expect(h.state.result, same(result));
      expect(h.state.cleanupError, isNull);
      expect(h.drafts.probes.single.cleanups, 2);
      expect(h.client.creates, hasLength(1));
      expect(h.client.uploads, hasLength(1));
    } finally {
      h.drafts.cleanup = null;
      await h.close();
    }
  });

  for (final status in [WorkshopSubmissionStatus.rejected, WorkshopSubmissionStatus.withdrawn]) {
    test('known ${status.name} requires explicit expected-id retirement before a new identical intent', () async {
      final h = PublishHarness();
      h.client.creating = (call) async => publishResult(call.metadata, status: status);
      try {
        await h.prepared();
        await h.controller.submit();
        final first = h.client.creates.single.requestId;
        expect(h.state.canStartNewSubmission, isTrue);
        expect(h.preferences.retired, isEmpty);
        await h.controller.startNewSubmission();
        expect(h.preferences.retired.single.requestId, first);
        expect(h.state.result, isNull);
        expect(h.state.preparedMetadata, isNull);
        expect(h.state.input.rightsConfirmed, isFalse);
        await h.controller.prepare();
        h.controller.setInput(h.state.input.copyWith(rightsConfirmed: true));
        h.client.creating = (call) async => publishResult(call.metadata, id: 'c' * 32,
          status: WorkshopSubmissionStatus.pending);
        await h.controller.submit();
        expect(h.client.creates.last.requestId, isNot(first));
        expect(h.client.creates.last.metadata.toJson(), h.client.creates.first.metadata.toJson());
        expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
      } finally { await h.close(); }
    });
  }

  test('late preparation is cleaned without writing the replacement account and releases its operation gate', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? pending, settled;
    h.drafts.beforeReturn = (_) async { entered.complete(); await release.future; };
    try {
      await h.start();
      h.controller.selectSource(publishSource);
      h.controller.setInput(publishInput());
      final oldSession = h.state.session;
      pending = h.controller.prepare();
      settled = authSettled(pending);
      await authSignal(entered, pending);
      h.account.emit(authSignedIn(credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      await authReady(h.container);
      // Do not read publisher state before the old completion. _current must
      // flush the pending session rebuild instead of trusting ref.mounted.
      release.complete();
      await pending;
      expect(h.state.session, isNot(same(oldSession)));
      expect(h.state.source, isNull);
      expect(h.state.preparedMetadata, isNull);
      expect(h.state.result, isNull);
      expect(h.state.working, isFalse);
      expect(h.drafts.probes.single.cleanups, 1);
      expect(h.client.creates, isEmpty);
      await h.controller.restorePending();
      expect(h.state.pendingChecked, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });

  test('account switch during upload keeps the borrowed archive and old result out of the new session', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? pending, settled;
    h.client.uploading = (call) async {
      entered.complete();
      await release.future;
      return publishResult(call.draft.metadata, id: call.draft.id, status: WorkshopSubmissionStatus.pending);
    };
    try {
      await h.prepared();
      final oldSession = h.state.session;
      pending = h.controller.submit();
      settled = authSettled(pending);
      await authSignal(entered, pending);
      h.account.emit(authSignedIn(credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      await authReady(h.container);
      expect(h.state.session, isNot(same(oldSession)));
      expect(h.state.waitingForPreviousOperation, isTrue);
      await h.controller.restorePending();
      expect(h.state.error?.code, 'workshop_busy');
      expect(h.preferences.reads, 1);
      expect(h.drafts.probes.single.cleanups, 0);
      release.complete();
      await pending;
      expect(h.state.result, isNull);
      expect(h.state.source, isNull);
      expect(h.state.working, isFalse);
      expect(h.preferences.clears, 0);
      expect(h.preferences.pending, hasLength(1));
      expect(h.drafts.probes.single.draft.retained, isTrue);
      expect(h.drafts.probes.single.cleanups, 0);
      await h.controller.restorePending();
      expect(h.state.pendingChecked, isTrue);
      expect(h.state.hasPending, isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });
  test('disposal during an upload retains the journal and observes the eventual completion', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? pending, settled;
    h.client.uploading = (call) async {
      entered.complete();
      await release.future;
      return publishResult(call.draft.metadata, id: call.draft.id, status: WorkshopSubmissionStatus.pending);
    };
    try {
      await h.prepared();
      pending = h.controller.submit();
      settled = authSettled(pending);
      await authSignal(entered, pending);
      h.dispose();
      expect(h.drafts.probes.single.cleanups, 0);
      release.complete();
      await pending;
      expect(h.preferences.pending, hasLength(1));
      expect(h.preferences.clears, 0);
      expect(h.drafts.probes.single.draft.retained, isTrue);
      expect(h.drafts.probes.single.cleanups, 0);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });

  test('late authorization from replaced credentials cannot reserve or send an old intent', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? refresh, refreshSettled, pending, settled;
    var first = true;
    try {
      await h.prepared();
      h.client.readCapabilities = () async {
        if (first) { first = false; entered.complete(); await release.future; }
        return h.client.value;
      };
      refresh = h.container.read(workshopAccessProvider.notifier).refresh();
      refreshSettled = authSettled(refresh);
      await authSignal(entered, refresh);
      pending = h.controller.submit();
      settled = authSettled(pending);
      h.account.emit(authSignedIn(credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B')));
      await authReady(h.container);
      release.complete();
      await pending;
      await refresh;
      expect(h.client.creates, isEmpty);
      expect(h.preferences.ids, isEmpty);
      expect(h.preferences.pending, isEmpty);
      expect(h.state.source, isNull);
      expect(h.state.result, isNull);
      expect(h.state.working, isFalse);
      expect(h.drafts.probes.single.cleanups, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      if (refreshSettled != null) await refreshSettled;
      await h.close();
    }
  });

  test('Worker replacement clears form state and performs a separate account journal check', () async {
    final h = PublishHarness();
    try {
      await h.prepared();
      final session = h.state.session;
      final next = PublishClient(h.events, worker: Uri.parse('https://other-workshop.example'));
      h.preferences.accepted.add(h.preferences.pair(next.origin, authAccount));
      h.chooseClient(next);
      await authReady(h.container);
      expect(h.state.session, isNot(same(session)));
      expect(h.state.source, isNull);
      expect(h.state.preparedMetadata, isNull);
      expect(h.state.pendingChecked, isFalse);
      await h.controller.restorePending();
      expect(h.preferences.reads, 2);
      expect(h.state.pendingChecked, isTrue);
      expect(next.creates, isEmpty);
    } finally { await h.close(); }
  });

  test('synchronous provider initialization failures release operation and draft-borrow gates', () async {
    final h = PublishHarness();
    try {
      await h.start();
      h.controller.selectSource(publishSource);
      h.controller.setInput(publishInput());
      h.failPrepareProvider = true;
      await h.controller.prepare();
      expect(h.state.error, isNotNull);
      expect(h.state.working, isFalse);
      expect(h.drafts.preparations, 0);
      h.failPrepareProvider = false;
      h.container.invalidate(workshopPrepareDraftProvider);
      await h.controller.prepare();
      expect(h.state.preparedMetadata, isNotNull);
      h.failRequestIdProvider = true;
      await h.controller.submit();
      expect(h.state.error, isNotNull);
      expect(h.state.working, isFalse);
      expect(h.client.creates, isEmpty);
      expect(h.preferences.ids, isEmpty);
      // Invalidation/edit cleanup proves the failed submission released its
      // borrow as well as the visible busy flag.
      h.controller.setInput(h.state.input.copyWith(author: 'After failure'));
      await h.controller.prepare();
      expect(h.drafts.probes.first.cleanups, 1);
      h.failRequestIdProvider = false;
      h.container.invalidate(workshopRequestIdProvider);
      await h.controller.submit();
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
      expect(h.state.working, isFalse);
    } finally { await h.close(); }
  });
  test('a known result keeps its draft borrowed until delayed journal cleanup settles across an account switch', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? pending, settled;
    h.preferences.clearing = (_, _) async { entered.complete(); await release.future; };
    try {
      await h.prepared();
      pending = h.controller.submit();
      settled = authSettled(pending);
      await authSignal(entered, pending);
      expect(h.state.result?.status, WorkshopSubmissionStatus.pending);
      expect(h.state.busy, isTrue);
      h.client.uploads.single.progress?.call(2, 4);
      expect(h.state.phase, WorkshopPublishPhase.complete);
      expect(h.drafts.probes.single.cleanups, 0);
      h.account.emit(authSignedIn(credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      await authReady(h.container);
      expect(h.state.result, isNull);
      expect(h.state.waitingForPreviousOperation, isTrue);
      await h.controller.restorePending();
      expect(h.preferences.reads, 1);
      release.complete();
      await pending;
      expect(h.preferences.pending, isEmpty);
      expect(h.drafts.probes.single.draft.retained, isFalse);
      expect(h.drafts.probes.single.cleanups, 1);
      expect(h.state.result, isNull);
      expect(h.state.working, isFalse);
      await h.controller.restorePending();
      expect(h.state.pendingChecked, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });

  test('a token the Worker refuses signs the account out and keeps the journal for the next sign-in', () async {
    final h = PublishHarness();
    try {
      await h.prepared();
      h.client.creating = (_) async => throw const WorkshopException('workshop_account_auth_invalid', status: 401);
      await h.controller.submit();
      expect(h.account.invalidated, 1);
      expect(h.container.read(workshopAccessProvider).signedIn, isFalse);
      expect(h.preferences.pending, hasLength(1));
    } finally { await h.close(); }
  });
}
