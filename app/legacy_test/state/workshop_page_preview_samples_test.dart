import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/workshop_page_samples.dart';
import 'workshop_publish_test_support.dart';
import 'workshop_state_support.dart';

void _preview(WorkshopPreview preview, WorkshopMetadata metadata) {
  final png = workshopSamplePreviewPng();
  final input = WorkshopPreviewInput.companionPng(png);
  expect(preview.sha256, sha256.convert(png).toString());
  expect(preview.size, png.length);
  expect((preview.width, preview.height), (input.width, input.height));
  expect((preview.width, preview.height), (2, 3));
  expect(preview.path,
    '/market/workshop/${metadata.kind}/${metadata.id}/${metadata.version}/${metadata.sha256}/preview/${preview.sha256}.png');
  expect(metadata.previewSource, workshopPreviewSources[metadata.kind]);
}

void _publisher(WorkshopPublishSample sample, String kind) {
  final state = sample.publish, access = sample.access;
  expect(state.session, same(access.session));
  expect(access.canSubmit(kind), isTrue);
  expect(access.worker, stateOrigin);
  expect(access.account, Uri.parse('https://github.com'));
  expect(access.capabilities!.account.origin, access.account);
  expect(access.capabilities!.preview!.sources, {'pet-idle', 'companion-preview'});
  expect(state.pendingChecked, isTrue);
  expect(state.working, isFalse);
  expect(state.source!.kind, kind);
  expect(state.source!.previewSource, workshopPreviewSources[kind]);
  expect(state.source!.preview, isNotNull);
  expect(state.input.declaration(kind), workshopSampleInput().declaration(kind));
  expect(state.preferenceError, isNull);
  expect(state.cleanupError, isNull);
}

void main() {
  test('preview catalog includes both image kinds and the unchanged no-image fallback', () async {
    final state = await browseWithPublicPreviews();
    expect(state.origin, stateOrigin);
    expect(state.loading || state.refreshing, isFalse);
    expect(state.localStateKnown, isTrue);
    expect(state.refreshError, isNull);
    expect(state.localError, isNull);
    expect(state.visibleItems, hasLength(3));
    final client = StateClient(origin: state.origin);
    for (final item in state.visibleItems) {
      final entry = item.entry;
      final preview = entry.preview;
      if (preview == null) {
        expect(entry.metadata.id, 'no-preview');
        expect(entry.metadata.previewSource, isNull);
        expect(client.publicPreviewUri(entry), isNull);
      } else {
        _preview(preview, entry.metadata);
        final uri = client.publicPreviewUri(entry)!;
        expect(uri.origin, state.origin!.origin);
        expect(uri.path, preview.path);
        expect(entry.toJson()['url'], entry.metadata.archivePath);
        expect(WorkshopEntry.fromJson(entry.toJson()).preview!.toJson(), preview.toJson());
      }
    }
    expect(state.visibleItems.where((item) => item.entry.preview != null), hasLength(2));
    expect(client.networkReads, 0, reason: 'URI construction is not an image request');
    final copy = workshopSamplePreviewPng()..fillRange(0, 8, 0);
    expect(copy.take(8), everyElement(0));
    expect(workshopSamplePreviewPng().take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  for (final kind in ['pet', 'companion']) {
    test('$kind detail takes its preview from the actual catalog item projection', () async {
      final sample = await detailWithPublicPreview(kind: kind);
      expect(sample.catalog.refreshError, isNull);
      expect(sample.item, isNotNull);
      final item = sample.item!;
      expect(sample.identity, item.entry.metadata.identity);
      expect(sample.catalog.items.single, same(item));
      expect(item.entry.metadata.kind, kind);
      expect(item.entry.toJson(), workshopSamplePreviewEntry(kind: kind).toJson());
      _preview(item.entry.preview!, item.entry.metadata);
    });

    test('$kind selected, ready and known pending snapshots retain one preview intent', () async {
      final selected = await (kind == 'pet'
        ? publishPetPreviewSelected() : publishCompanionPreviewSelected());
      _publisher(selected, kind);
      expect(selected.publish.phase, WorkshopPublishPhase.idle);
      expect(selected.publish.input.rightsConfirmed, isFalse);
      expect(selected.publish.preparedMetadata, isNull);
      expect(selected.publish.files, isEmpty);
      expect(selected.publish.result, isNull);
      expect(selected.publish.error, isNull);
      final input = selected.publish.source!.preview!;
      if (kind == 'companion') {
        expect((input.width, input.height, input.size), (2, 3, workshopSamplePreviewPng().length));
      } else {
        expect(input.width, isNull, reason: 'the pet selection contains a mode, not derived image bytes');
        expect(input.size, isNull);
      }

      final ready = await (kind == 'pet'
        ? publishPetPreviewReady() : publishCompanionPreviewReady());
      _publisher(ready, kind);
      final metadata = ready.publish.preparedMetadata!;
      expect(ready.publish.phase, WorkshopPublishPhase.ready);
      expect(ready.publish.input.rightsConfirmed, isFalse);
      expect(ready.publish.hasPending, isFalse);
      expect(ready.publish.result, isNull);
      expect(ready.publish.error, isNull);
      expect(metadata.toJson(), workshopSamplePreviewEntry(kind: kind).metadata.toJson());
      if (kind == 'pet') {
        expect(ready.publish.files, ['pack.json', 'idle.png']);
      } else {
        expect(ready.publish.files, [
          'character/character.json', 'character/model.model3.json',
          'character/model.moc3', 'character/texture.png', 'character/preview.png',
        ]);
      }

      final pending = await (kind == 'pet'
        ? publishPetPreviewAwaitingReview() : publishCompanionPreviewAwaitingReview());
      _publisher(pending, kind);
      final result = pending.publish.result!;
      expect(pending.publish.phase, WorkshopPublishPhase.complete);
      expect(result.status, WorkshopSubmissionStatus.pending);
      expect(pending.publish.input.rightsConfirmed, isTrue);
      expect(pending.publish.hasPending, isFalse, reason: 'the known server result cleared the local journal');
      expect(pending.publish.pendingKnownUnsent, isFalse);
      expect(pending.publish.error, isNull);
      expect(result.ownerOrigin, pending.access.account);
      expect(result.ownerId, pending.access.accountId);
      expect(result.metadata.toJson(), metadata.toJson());
      expect(pending.publish.preparedMetadata!.toJson(), metadata.toJson());
      expect(pending.publish.files, ready.publish.files);
      expect((pending.publish.sent, pending.publish.total), (metadata.size, metadata.size));
      _preview(result.preview!, result.metadata);
      expect(result.preview!.toJson(), workshopSamplePreviewEntry(kind: kind).preview!.toJson());
    });
  }

  for (final (kind, code, factory) in [
    ('pet', 'workshop_preview_dimensions', publishPetPreviewDimensionsFailed),
    ('companion', 'workshop_preview_conflict', publishCompanionPreviewConflictFailed),
  ]) {
    test('$kind preparation exposes the actual notifier error for $code', () async {
      final sample = await factory();
      _publisher(sample, kind);
      final state = sample.publish;
      expect(state.phase, WorkshopPublishPhase.failed);
      expect(state.error!.code, code);
      expect(state.error!.resultUnknown, isFalse);
      expect(state.hasPending, isFalse);
      expect(state.preparedMetadata, isNull);
      expect(state.result, isNull);
      expect(state.files, isEmpty);
      expect(state.input.rightsConfirmed, isFalse);
    });
  }

  test('a rejected companion input is a caller error before any notifier action', () async {
    final harness = PublishHarness();
    try {
      await harness.start();
      expect(harness.controller.selectSource(const WorkshopPublishSource(
        kind: 'companion', localId: 'companion', name: 'Companion')), isTrue);
      expect(harness.controller.setInput(workshopSampleInput()), isTrue);
      final before = harness.state;
      expect(() => WorkshopPreviewInput.companionPng(Uint8List(0)),
        throwsA(isA<WorkshopException>().having((error) => error.code, 'code', 'workshop_preview_size')));
      expect(harness.state, same(before));
      expect(harness.state.source!.preview, isNull);
      expect(harness.state.error, isNull);
      expect(harness.drafts.preparations, 0);
      expect(harness.client.creates, isEmpty);
      expect(harness.client.uploads, isEmpty);
    } finally {
      await harness.close();
    }
  });

  test('legacy factories still have no preview opt-in or registered image', () async {
    expect(workshopSampleEntry().metadata.previewSource, isNull);
    expect(workshopSampleEntry().preview, isNull);
    final browse = await browseLoaded();
    for (final item in browse.visibleItems) {
      expect(item.entry.metadata.previewSource, isNull);
      expect(item.entry.preview, isNull);
    }
    final ready = await publishReadyShortChinese();
    expect(ready.publish.source!.preview, isNull);
    expect(ready.publish.preparedMetadata!.previewSource, isNull);
    final complete = await publishComplete();
    expect(complete.publish.result!.metadata.previewSource, isNull);
    expect(complete.publish.result!.preview, isNull);
  });
}
