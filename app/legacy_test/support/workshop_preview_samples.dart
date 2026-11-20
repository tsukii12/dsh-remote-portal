part of 'workshop_page_samples.dart';

// A tiny, original 2 x 3 RGBA PNG, with no ancillary metadata. The descriptor
// below identifies these exact bytes. This is a page image substitute, not an
// image fetched from the synthetic workshop.example URL.
const _samplePreviewPng = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 2, 0, 0, 0, 3, 8, 6, 0, 0, 0, 185, 234, 222, 129,
  0, 0, 0, 38, 73, 68, 65, 84, 120, 1, 1, 27, 0, 228, 255, 0,
  224, 96, 64, 255, 64, 128, 224, 255, 0, 64, 192, 128, 255, 240,
  208, 64, 255, 0, 160, 96, 208, 255, 240, 240, 240, 255, 212,
  211, 17, 59, 119, 24, 112, 28, 0, 0, 0, 0, 73, 69, 78, 68,
  174, 66, 96, 130,
];
const _samplePreviewHash = '9a1a82301ed3c19b338ec7feac4b8bff9af71499fbc01682c7fcbc512b4abf35';

/// A fresh image substitute for widget/golden image loaders. The sample URI
/// is only an identity example; these factories never serve or fetch images.
Uint8List workshopSamplePreviewPng() => Uint8List.fromList(_samplePreviewPng);

// Archive identity is opaque scripted transport data, as in PublishDrafts.
// Distinct kinds use distinct identities; no sample claims a real ZIP hash.
(String, int) _previewArchive(String kind) => switch (kind) {
  'pet' => ('a' * 64, 4096),
  'companion' => ('c' * 64, 8192),
  _ => throw ArgumentError.value(kind, 'kind', 'Expected pet or companion'),
};

Map<String, Object?> _previewDescriptor(WorkshopMetadata metadata) => {
  'path': '/market/workshop/${metadata.release}/${metadata.sha256}/preview/$_samplePreviewHash.png',
  'sha256': _samplePreviewHash, 'size': _samplePreviewPng.length,
  'width': 2, 'height': 3,
};

/// Opt-in fixtures are separate from workshopSampleEntry's legacy no-image
/// default. Metadata, archive URL and image URL share one release identity.
WorkshopEntry workshopSamplePreviewEntry({String kind = 'pet'}) {
  final (hash, size) = _previewArchive(kind);
  final metadata = workshopSampleInput().publication(kind,
    previewSource: workshopPreviewSources[kind]).withArchive(hash, size);
  return WorkshopEntry.fromJson({...metadata.toJson(submission: false),
    'url': metadata.archivePath, 'blockedVersions': <String>[],
    'preview': _previewDescriptor(metadata)});
}

/// Both supported kinds have an image; the third entry is the ordinary
/// no-image fallback. No image-load failure is put into refreshError.
Future<WorkshopCatalogState> browseWithPublicPreviews() => _browseLoaded(entries: [
  workshopSamplePreviewEntry(), workshopSamplePreviewEntry(kind: 'companion'),
  workshopSampleEntry(id: 'no-preview'),
]);

Future<WorkshopDetailSample> detailWithPublicPreview({String kind = 'pet'}) =>
  _detail(entry: workshopSamplePreviewEntry(kind: kind));

class _PreviewSampleDrafts extends PublishDrafts {
  _PreviewSampleDrafts(super.events, {this.failure});
  final String? failure;

  @override
  Future<WorkshopPreparedDraft> prepare(WorkshopPublishSource source, WorkshopPublication publication) async {
    events.add('prepare');
    preparations++;
    if (source.previewSource != publication.previewSource) {
      throw StateError('Preview sample source and declaration differ');
    }
    final code = failure;
    if (code != null) {
      // The real repository can report these errors while preparing. This
      // seam reports one to the real notifier; it does not fabricate state.
      throw WorkshopException(code);
    }
    final (hash, size) = _previewArchive(source.kind);
    final probe = PublishDraftProbe('draft-preview-$preparations');
    probe.draft = WorkshopPreparedDraft(
      upload: WorkshopPreparedUpload(
        file: File('private-test-exports/${probe.directoryName}/archive.zip'),
        metadata: publication.withArchive(hash, size),
        files: List.unmodifiable(source.kind == 'pet'
          ? ['pack.json', 'idle.png']
          : ['character/character.json', 'character/model.model3.json',
            'character/model.moc3', 'character/texture.png', 'character/preview.png']),
      ),
      directoryName: probe.directoryName,
      cleanup: () async {
        events.add('cleanup');
        probe.cleanups++;
        if (!probe.firstCleanup.isCompleted) {
          probe.firstCleanup.complete();
        }
      },
    );
    probes.add(probe);
    return probe.draft;
  }
}

enum _PreviewSampleMoment { selected, ready, pending }

Future<WorkshopPublishSample> _publishPreviewSample(String kind, _PreviewSampleMoment moment,
  {String? prepareFailure}) async {
  final events = <String>[];
  final client = PublishClient(events);
  client.value = WorkshopCapabilities.fromJson({...workshopCaps(), 'preview': {
    'schema': 1, 'format': 'png', 'sources': ['pet-idle', 'companion-preview'],
    'maxWidth': 512, 'maxHeight': 512, 'maxPixels': 262144, 'maxBytes': 2097152,
  }});
  client.uploading = (call) async {
    call.progress?.call(0, call.draft.metadata.size);
    call.progress?.call(call.draft.metadata.size, call.draft.metadata.size);
    return WorkshopSubmission.fromJson({
      'submissionId': call.draft.id, 'metadata': call.draft.metadata.toJson(),
      'status': 'pending',
      'owner': {'accountOrigin': authAccount.toString(), 'accountId': 42, 'username': 'test-user'},
      'createdAt': '2026-11-11T00:00:00.000Z', 'updatedAt': '2026-11-11T00:00:00.000Z',
      'preview': _previewDescriptor(call.draft.metadata),
    });
  };
  final drafts = _PreviewSampleDrafts(events, failure: prepareFailure);
  final harness = PublishHarness(client: client, drafts: drafts, events: events);
  try {
    await harness.start();
    final source = switch (kind) {
      'pet' => publishSource,
      'companion' => const WorkshopPublishSource(kind: 'companion', localId: 'companion', name: 'Companion'),
      _ => throw ArgumentError.value(kind, 'kind', 'Expected pet or companion'),
    };
    final preview = kind == 'pet' ? const WorkshopPreviewInput.petIdle()
        : WorkshopPreviewInput.companionPng(workshopSamplePreviewPng());
    if (!harness.controller.selectSource(source) ||
        !harness.controller.setInput(workshopSampleInput(rights: true)) ||
        !harness.controller.setPreview(preview)) {
      throw StateError('Preview sample did not enter the editor');
    }
    if (moment != _PreviewSampleMoment.selected) {
      await harness.controller.prepare();
    }
    if (moment == _PreviewSampleMoment.pending) {
      if (!harness.controller.setInput(harness.state.input.copyWith(rightsConfirmed: true))) {
        throw StateError('Preview sample did not confirm rights');
      }
      await harness.controller.submit();
    }
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishPetPreviewSelected() =>
  _publishPreviewSample('pet', _PreviewSampleMoment.selected);
Future<WorkshopPublishSample> publishCompanionPreviewSelected() =>
  _publishPreviewSample('companion', _PreviewSampleMoment.selected);
Future<WorkshopPublishSample> publishPetPreviewReady() =>
  _publishPreviewSample('pet', _PreviewSampleMoment.ready);
Future<WorkshopPublishSample> publishCompanionPreviewReady() =>
  _publishPreviewSample('companion', _PreviewSampleMoment.ready);

/// Server pending is known after upload; the local intent is already cleared.
/// These are not the unknown-result/hasPending recovery snapshots.
Future<WorkshopPublishSample> publishPetPreviewAwaitingReview() =>
  _publishPreviewSample('pet', _PreviewSampleMoment.pending);
Future<WorkshopPublishSample> publishCompanionPreviewAwaitingReview() =>
  _publishPreviewSample('companion', _PreviewSampleMoment.pending);

Future<WorkshopPublishSample> publishPetPreviewDimensionsFailed() =>
  _publishPreviewSample('pet', _PreviewSampleMoment.ready, prepareFailure: 'workshop_preview_dimensions');
Future<WorkshopPublishSample> publishCompanionPreviewConflictFailed() =>
  _publishPreviewSample('companion', _PreviewSampleMoment.ready, prepareFailure: 'workshop_preview_conflict');
