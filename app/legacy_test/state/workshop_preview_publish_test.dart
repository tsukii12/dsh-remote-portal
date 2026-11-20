import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show FakeWorkshopHttp, workshopCaps, workshopJsonResponse,
  workshopPng, workshopSubmissionJson;
import 'workshop_auth_test_support.dart';
import 'workshop_publish_test_support.dart';
import 'workshop_state_support.dart' show stateSettled, stateSignal;

const _companion = WorkshopPublishSource(kind: 'companion', localId: 'companion',
  author: 'Author', license: 'CC0-1.0', source: 'https://source.example/cat');

/// A shape-valid server result. File/PNG equality is covered separately by the
/// real preparation tests; this fake only drives the actual notifier protocol.
WorkshopSubmission _pending(WorkshopMetadata metadata) => WorkshopSubmission.fromJson({
  ...workshopSubmissionJson(id: 'b' * 32, metadata: metadata.toJson(), status: 'pending'),
  if (metadata.previewSource != null) 'preview': {
    'path': '/market/workshop/${metadata.kind}/${metadata.id}/${metadata.version}/${metadata.sha256}/preview/${'b' * 64}.png',
    'sha256': 'b' * 64, 'size': 91, 'width': 2, 'height': 3,
  },
});

class _OldPreviewClient extends PublishClient {
  _OldPreviewClient(super.events) {
    transport = FakeWorkshopHttp((method, url, headers, body) {
      if (method == 'GET' && url.path == '/api/workshop/v1/capabilities') {
        return workshopJsonResponse(workshopCaps()); // An older worker has no preview contract.
      }
      if (method == 'POST' && url.path == '/api/workshop/v1/submissions') {
        final metadata = WorkshopMetadata.fromJson(jsonDecode(utf8.decode(body!)));
        return workshopJsonResponse({'submission': workshopSubmissionJson(
          metadata: metadata.toJson(), status: 'pending')});
      }
      throw StateError('Unexpected preview publisher request: $method ${url.path}');
    });
    delegate = WorkshopClient(origin: origin, cacheFile: File('unused-preview-publish-cache.json'), http: transport);
  }
  late final FakeWorkshopHttp transport;
  late final WorkshopClient delegate;
  @override
  Future<WorkshopSubmission> createSubmission(WorkshopMetadata metadata, {required String requestId,
    required bool rightsConfirmed, required WorkshopCredential credential}) {
    final call = PublishCreateCall(metadata, requestId, rightsConfirmed, credential);
    creates.add(call);
    return delegate.createSubmission(metadata, requestId: requestId,
      rightsConfirmed: rightsConfirmed, credential: credential);
  }
}

Future<void> _ready(PublishHarness h, WorkshopPublishSource source) async {
  await h.start();
  expect(h.controller.selectSource(source), isTrue);
  expect(h.controller.setInput(publishInput()), isTrue);
  await h.controller.prepare();
  expect(h.state.phase, WorkshopPublishPhase.ready);
  expect(h.state.error, isNull);
}

void main() {
  for (final kind in ['pet', 'companion']) {
    test('$kind opt-in is in both expected prepared metadata and the persisted upload intent', () async {
      final h = PublishHarness();
      h.client.uploading = (call) async => _pending(call.draft.metadata);
      final preview = kind == 'pet' ? const WorkshopPreviewInput.petIdle()
          : WorkshopPreviewInput.companionPng(workshopPng(2, 3));
      final source = (kind == 'pet' ? publishSource : _companion).withPreview(preview);
      try {
        await _ready(h, source);
        final metadata = h.state.preparedMetadata!;
        expect(metadata.previewSource, workshopPreviewSources[kind]);
        expect(metadata.source, h.state.input.source);
        expect(h.client.creates, isEmpty);
        await h.controller.submit();
        expect(h.state.phase, WorkshopPublishPhase.complete);
        expect(h.state.result?.metadata.toJson(), metadata.toJson());
        expect(h.state.result?.preview, isNotNull);
        expect(h.preferences.saved.single.metadata.toJson(), metadata.toJson());
        expect(h.client.creates.single.metadata.toJson(), metadata.toJson());
        expect(h.client.uploads.single.draft.metadata.toJson(), metadata.toJson());
        expect(h.client.uploads.single.archive.path, h.drafts.probes.single.draft.upload.file.path);
        expect(h.preferences.pending, isEmpty);
      } finally { await h.close(); }
    });
  }

  test('selecting, changing and removing a companion image preserves text and resets preparation and rights', () async {
    final h = PublishHarness();
    try {
      await _ready(h, _companion);
      final original = h.state.input.declaration('companion');
      for (final preview in <WorkshopPreviewInput?>[
        WorkshopPreviewInput.companionPng(workshopPng(2, 3)),
        WorkshopPreviewInput.companionPng(workshopPng(3, 2)),
        null,
      ]) {
        final old = h.drafts.probes.last;
        expect(h.controller.setPreview(preview), isTrue);
        expect(h.state.input.declaration('companion'), original);
        expect(h.state.input.rightsConfirmed, isFalse);
        expect(h.state.source?.localId, 'companion');
        expect(h.state.source?.preview, same(preview));
        expect(h.state.preparedMetadata, isNull);
        expect(h.state.result, isNull);
        expect(h.state.files, isEmpty);
        expect(h.state.phase, WorkshopPublishPhase.idle);
        await old.firstCleanup.future;
        expect(old.cleanups, 1);
        await h.controller.prepare();
        expect(h.state.phase, WorkshopPublishPhase.ready);
        expect(h.state.preparedMetadata?.previewSource, preview?.source);
        final prepared = h.state.preparedMetadata;
        expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: true)), isTrue);
        expect(h.state.preparedMetadata, same(prepared), reason: 'a checkbox-only change keeps the same archive');
      }
      expect(h.client.creates, isEmpty);
    } finally { await h.close(); }
  });

  test('preview edits require a selected matching source and cannot rewrite a pending intent', () async {
    final h = PublishHarness();
    try {
      await h.start();
      expect(h.controller.setPreview(const WorkshopPreviewInput.petIdle()), isFalse);
      expect(h.state.error?.code, 'workshop_source_required');
      expect(h.controller.selectSource(publishSource), isTrue);
      expect(h.controller.setInput(publishInput()), isTrue);
      final png = WorkshopPreviewInput.companionPng(workshopPng(1, 1));
      expect(h.controller.setPreview(png), isFalse);
      expect(h.state.error?.code, 'workshop_bad_metadata');
      expect(h.state.source, same(publishSource));
      expect(h.state.input.rightsConfirmed, isTrue);
      expect(h.controller.selectSource(_companion.withPreview(const WorkshopPreviewInput.petIdle())), isFalse);
      expect(h.state.error?.code, 'workshop_bad_metadata');
      expect(h.state.source, same(publishSource));
      expect(h.controller.setPreview(const WorkshopPreviewInput.petIdle()), isTrue);
      expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: true)), isTrue);
      await h.controller.prepare();
      h.client.creating = (call) async => throw const WorkshopException('workshop_network', resultUnknown: true);
      await h.controller.submit();
      final pending = h.preferences.pending.values.single;
      expect(h.state.error?.resultUnknown, isTrue);
      expect(h.controller.setPreview(null), isFalse);
      expect(h.state.error?.code, 'workshop_pending_submission');
      expect(h.state.source?.previewSource, 'pet-idle');
      expect(h.state.preparedMetadata?.toJson(), pending.metadata.toJson());
      expect(h.preferences.pending.values.single, same(pending));
      expect(h.state.canDiscardUnsentSubmission, isFalse);
    } finally { await h.close(); }
  });

  test('a preview edit during preparation cannot replace the pending source snapshot', () async {
    final h = PublishHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<void>? operation, settled;
    try {
      await h.start();
      expect(h.controller.selectSource(publishSource.withPreview(const WorkshopPreviewInput.petIdle())), isTrue);
      expect(h.controller.setInput(publishInput()), isTrue);
      h.drafts.beforeReturn = (probe) async { entered.complete(); await release.future; };
      operation = h.controller.prepare();
      settled = stateSettled(operation);
      await stateSignal(entered, operation);
      expect(h.controller.setPreview(null), isFalse);
      expect(h.state.error?.code, 'workshop_busy');
      expect(h.state.source?.previewSource, 'pet-idle');
      release.complete();
      await operation;
      expect(h.state.phase, WorkshopPublishPhase.ready);
      expect(h.state.preparedMetadata?.previewSource, 'pet-idle');
    } finally {
      if (!release.isCompleted) release.complete();
      if (settled != null) await settled;
      await h.close();
    }
  });

  test('cold recovery retains the preview metadata and the single archive without selecting or preparing an image again', () async {
    final first = PublishHarness();
    PublishHarness? restored;
    try {
      await _ready(first, _companion.withPreview(WorkshopPreviewInput.companionPng(workshopPng(2, 3))));
      first.client.creating = (call) async => throw const WorkshopException('workshop_network', resultUnknown: true);
      await first.controller.submit();
      final pending = first.preferences.pending.values.single;
      expect(pending.metadata.previewSource, 'companion-preview');
      expect(first.drafts.probes.single.draft.retained, isTrue);
      await first.close();
      final next = PublishHarness(preferences: first.preferences);
      restored = next;
      next.client.creating = (call) async => _pending(call.metadata);
      await next.start();
      expect(next.state.source, isNull);
      expect(next.state.preparedMetadata?.toJson(), pending.metadata.toJson());
      expect(next.state.canDiscardUnsentSubmission, isFalse);
      expect(next.drafts.preparations, 0);
      expect(next.drafts.restorations, 1);
      expect(next.controller.setPreview(null), isFalse);
      expect(next.state.error?.code, 'workshop_pending_submission');
      await next.controller.retrySubmission();
      expect(next.client.creates.single.requestId, pending.requestId);
      expect(next.client.creates.single.metadata.toJson(), pending.metadata.toJson());
      expect(next.client.uploads, isEmpty, reason: 'a known non-draft result precedes opening a missing local archive');
      expect(next.drafts.preparations, 0);
      expect(next.state.phase, WorkshopPublishPhase.complete);
      expect(next.state.result?.metadata.previewSource, 'companion-preview');
      expect(next.preferences.pending, isEmpty);
    } finally {
      if (restored != null) await restored.close();
      await first.close();
    }
  });

  test('an old worker rejects preview before POST and explicit unsent recovery can remove the opt-in', () async {
    final events = <String>[];
    final client = _OldPreviewClient(events);
    final h = PublishHarness(client: client, events: events);
    try {
      await _ready(h, publishSource.withPreview(const WorkshopPreviewInput.petIdle()));
      await h.controller.submit();
      expect(h.state.error?.code, 'workshop_preview_unsupported');
      expect(h.state.error?.mutationNotSent, isTrue);
      expect(h.state.error?.resultUnknown, isFalse);
      expect(h.state.canDiscardUnsentSubmission, isTrue);
      expect(client.transport.requests.where((request) => request.method == 'POST'), isEmpty);
      await h.controller.discardUnsentSubmission();
      expect(h.state.hasPending, isFalse);
      expect(h.controller.setPreview(null), isTrue);
      expect(h.state.input.rightsConfirmed, isFalse);
      expect(h.controller.setInput(h.state.input.copyWith(rightsConfirmed: true)), isTrue);
      await h.controller.prepare();
      expect(h.state.preparedMetadata?.previewSource, isNull);
      await h.controller.submit();
      expect(client.transport.requests.where((request) => request.method == 'POST'), hasLength(1));
      expect(h.state.phase, WorkshopPublishPhase.complete);
      expect(h.state.result?.metadata.previewSource, isNull);
      expect(h.preferences.pending, isEmpty);
    } finally { await h.close(); }
  });

  test('an account change removes selected image state and cleans its unretained prepared draft', () async {
    final h = PublishHarness();
    try {
      await _ready(h, _companion.withPreview(WorkshopPreviewInput.companionPng(workshopPng(2, 3))));
      final oldSession = h.state.session;
      final oldDraft = h.drafts.probes.single;
      h.account.emit(authSignedIn(userId: 43));
      expect(h.state.session, isNot(same(oldSession)));
      expect(h.state.source, isNull);
      expect(h.state.preparedMetadata, isNull);
      expect(h.state.hasPending, isFalse);
      await oldDraft.firstCleanup.future;
      expect(oldDraft.cleanups, 1);
    } finally { await h.close(); }
  });

  test('publication input adds only the explicit preview mode and does not rewrite author fields', () {
    final input = WorkshopPublicationInput(id: 'cat', titleZh: '雨夜的小猫', titleEn: 'Rainy Cat',
      author: '作者甲', license: 'CC-BY-4.0', source: 'https://source.example/%E7%8C%AB',
      description: 'A chosen public preview', tags: ['夜晚', 'cat']);
    final old = input.publication('pet').withArchive('a' * 64, 4);
    final next = input.publication('pet', previewSource: 'pet-idle').withArchive('a' * 64, 4);
    expect(old.previewSource, isNull);
    expect(next.toJson(), {...old.toJson(), 'previewSource': 'pet-idle'});
    expect(input.declaration('pet').containsKey('previewSource'), isFalse);
  });
}
