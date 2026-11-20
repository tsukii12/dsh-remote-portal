import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/workshop_page_samples.dart';

void _sample<T>(String name, Future<T> Function() factory, void Function(T) verify) {
  test(name, () async => verify(await factory()));
}

void _access(WorkshopAccessState state) {
  if (state.canAuthenticate) {
    expect(state.loading, isFalse);
    expect(state.signedIn, isTrue);
    expect(state.error, isNull);
    expect(state.disclosureAccepted, isTrue);
    expect(state.capabilities, isNotNull);
  }
  if (state.canSubmit('companion')) {
    expect(state.canAuthenticate, isTrue);
    expect(state.accountId, isNotNull);
    expect(state.uploadsEnabled && state.companionEnabled, isTrue);
  }
  if (state.disclosure != null) {
    expect(state.disclosure!.worker, state.worker);
    expect(state.disclosure!.account, state.account);
  }
}

void _publisher(WorkshopPublishSample sample) {
  _access(sample.access);
  final state = sample.publish;
  expect(state.session, same(sample.access.session));
  expect(state.working, state.busy || state.waitingForPreviousOperation);
  expect(state.canEditMetadata, state.pendingChecked && !state.working && !state.hasPending);
  expect(state.canDiscardUnsentSubmission, !state.working && state.hasPending && state.pendingKnownUnsent);
  if (state.pendingKnownUnsent) {
    expect(state.hasPending, isTrue);
    expect(state.result, isNull);
  }
  expect(() => state.files.clear(), throwsUnsupportedError);
  expect(() => state.fieldErrors.clear(), throwsUnsupportedError);
  if (state.phase == WorkshopPublishPhase.awaitingResponse) {
    expect(state.sent, state.total);
    expect(state.total, greaterThan(0));
    expect(state.busy, isTrue);
    expect(state.result, isNull);
  }
  if (state.phase == WorkshopPublishPhase.complete) {
    expect(state.result, isNotNull);
    expect(state.result!.status, isNot(WorkshopSubmissionStatus.draft));
  }
  if (state.error?.resultUnknown == true) {
    expect(state.phase, WorkshopPublishPhase.failed);
    expect(state.hasPending, isTrue);
    expect(state.preparedMetadata, isNotNull);
    expect(state.canEditMetadata, isFalse);
    expect(state.pendingKnownUnsent, isFalse);
  }
  if (state.preparedMetadata != null) {
    final metadata = state.preparedMetadata!;
    expect(metadata.title['zh'], state.input.titleZh);
    expect(metadata.title['en'], state.input.titleEn);
    expect(metadata.author, state.input.author);
    expect(metadata.license, state.input.license);
    expect(metadata.source, state.input.source);
    expect(metadata.description, state.input.description);
    expect(metadata.tags, state.input.tags);
  }
}

void main() {
  _sample('publishPendingKnownUnsent', publishPendingKnownUnsent, (sample) {
    _publisher(sample);
    expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.source!.kind, 'companion');
    expect(sample.access.canSubmit('companion'), isFalse);
    expect(sample.publish.error!.code, 'workshop_companion_disabled');
    expect(sample.publish.error!.mutationNotSent, isTrue);
    expect(sample.publish.error!.resultUnknown, isFalse);
    expect(sample.publish.pendingKnownUnsent, isTrue);
    expect(sample.publish.canDiscardUnsentSubmission, isTrue);
    expect(sample.publish.canEditMetadata, isFalse);
    expect(sample.publish.preparedMetadata, isNotNull);
  });
  _sample('publishDiscardingUnsent', publishDiscardingUnsent, (sample) {
    _publisher(sample);
    expect(sample.publish.phase, WorkshopPublishPhase.checking);
    expect(sample.publish.busy, isTrue);
    expect(sample.publish.hasPending, isTrue);
    expect(sample.publish.pendingKnownUnsent, isTrue);
    expect(sample.publish.canDiscardUnsentSubmission, isFalse);
    expect(sample.publish.canEditMetadata, isFalse);
    expect(sample.publish.preparedMetadata, isNotNull);
    expect(sample.publish.error, isNull);
  });
  _sample('publishDiscardUnsentPreferenceFailed', publishDiscardUnsentPreferenceFailed, (sample) {
    _publisher(sample);
    expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.busy, isFalse);
    expect(sample.publish.pendingKnownUnsent, isTrue);
    expect(sample.publish.canDiscardUnsentSubmission, isTrue);
    expect(sample.publish.error!.code, 'workshop_preferences');
    expect(sample.publish.preferenceError!.code, 'workshop_preferences');
    expect(sample.publish.preparedMetadata, isNotNull);
  });
  _sample('publishDiscardUnsentComplete', publishDiscardUnsentComplete, (sample) {
    _publisher(sample);
    expect(sample.publish.phase, WorkshopPublishPhase.idle);
    expect(sample.publish.source!.kind, 'companion');
    expect(sample.publish.input.id, 'moon-cat');
    expect(sample.publish.input.rightsConfirmed, isFalse);
    expect(sample.publish.hasPending, isFalse);
    expect(sample.publish.pendingKnownUnsent, isFalse);
    expect(sample.publish.canDiscardUnsentSubmission, isFalse);
    expect(sample.publish.canEditMetadata, isTrue);
    expect(sample.publish.preparedMetadata, isNull);
    expect(sample.publish.result, isNull);
    expect(sample.publish.error, isNull);
    expect(sample.publish.preferenceError, isNull);
    expect(sample.publish.cleanupError, isNull);
  });
  _sample('publishDiscardUnsentCleanupFailed', publishDiscardUnsentCleanupFailed, (sample) {
    _publisher(sample);
    expect(sample.publish.phase, WorkshopPublishPhase.idle);
    expect(sample.publish.input.rightsConfirmed, isFalse);
    expect(sample.publish.hasPending, isFalse);
    expect(sample.publish.pendingKnownUnsent, isFalse);
    expect(sample.publish.canEditMetadata, isTrue);
    expect(sample.publish.preparedMetadata, isNull);
    expect(sample.publish.result, isNull);
    expect(sample.publish.error, isNull);
    expect(sample.publish.cleanupError!.code, 'workshop_draft_cleanup');
  });
  _sample('accessLoading', accessLoading, (state) {
    _access(state);
    expect(state.loading, isTrue);
    expect(state.capabilities, isNull);
    expect(state.uploadsEnabled, isFalse); // Unknown, not a known disabled response.
  });
  _sample('accessAccountRestoring', accessAccountRestoring, (state) {
    _access(state);
    expect(state.accountRestoring, isTrue);
    expect(state.signedIn, isFalse);
    expect(state.canAuthenticate, isFalse);
  });
  _sample('accessSignedOut', accessSignedOut, (state) {
    _access(state);
    expect(state.signedIn, isFalse);
    expect(state.accountRestoring, isFalse);
    expect(state.disclosure, isNull);
  });
  _sample('accessDisclosureRequired', accessDisclosureRequired, (state) {
    _access(state);
    expect(state.signedIn, isTrue);
    expect(state.disclosure, isNotNull);
    expect(state.disclosureAccepted, isFalse);
    expect(state.canAuthenticate, isFalse);
  });
  _sample('accessProfilePending', accessProfilePending, (state) {
    _access(state);
    expect(state.accountId, isNull);
    expect(state.canAuthenticate, isTrue);
    expect(state.canSubmit('pet'), isFalse);
  });
  _sample('accessUploadsDisabled', accessUploadsDisabled, (state) {
    _access(state);
    expect(state.capabilities!.features.uploads, isFalse);
    expect(state.canAuthenticate, isTrue);
    expect(state.canSubmit('pet'), isFalse);
    expect(state.canSubmit('companion'), isFalse);
  });
  _sample('accessCompanionDisabled', accessCompanionDisabled, (state) {
    _access(state);
    expect(state.canSubmit('pet'), isTrue);
    expect(state.canSubmit('companion'), isFalse);
  });
  for (final (name, factory, code) in <(String, Future<WorkshopAccessState> Function(), String)>[
    ('accessAccountMismatch', accessAccountMismatch, 'workshop_account_origin'),
    ('accessNetworkFailed', accessNetworkFailed, 'workshop_network'),
    ('accessUnconfigured', accessUnconfigured, 'workshop_unconfigured'),
    ('accessStaleDisclosure', accessStaleDisclosure, 'workshop_confirmation_stale'),
  ]) {
    _sample(name, factory, (state) { _access(state); expect(state.error!.code, code); expect(state.canAuthenticate, isFalse); });
  }
  _sample('accessDisclosureReadFailed', accessDisclosureReadFailed, (state) {
    _access(state);
    expect(state.preferenceError!.code, 'workshop_preferences');
    expect(state.disclosureAccepted, isFalse);
    expect(state.error, isNull);
  });
  _sample('accessSavingDisclosure', accessSavingDisclosure, (state) {
    _access(state);
    expect(state.savingDisclosure, isTrue);
    expect(state.disclosureAccepted, isTrue);
    expect(state.disclosureSaved, isFalse);
  });
  _sample('accessDisclosureSaved', accessDisclosureSaved, (state) {
    _access(state);
    expect(state.disclosureSaved, isTrue);
    expect(state.savingDisclosure, isFalse);
    expect(state.canSubmit('pet'), isTrue);
  });
  _sample('accessDisclosureSaveFailed', accessDisclosureSaveFailed, (state) {
    _access(state);
    expect(state.disclosureAccepted, isTrue);
    expect(state.disclosureSaved, isFalse);
    expect(state.preferenceError!.code, 'workshop_preferences');
    expect(state.canAuthenticate, isTrue);
  });

  _sample('publishSourcesLoading', publishSourcesLoading, (state) {
    expect(state.loading, isTrue); expect(state.values, isEmpty); expect(state.issues, isEmpty);
  });
  _sample('publishSourcesChoices', publishSourcesChoices, (state) {
    expect(state.loading, isFalse);
    expect(state.values.map((value) => value.kind), ['pet', 'companion']);
    final pet = state.values.first.initialInput(), companion = state.values.last.initialInput();
    expect(pet.id, 'moon-cat');
    expect(pet.titleZh, '月白');
    expect(pet.rightsConfirmed, isFalse);
    expect(companion.id, isEmpty);
    expect(companion.titleZh, isEmpty); // No private companion nickname/persona copied.
    expect(companion.rightsConfirmed, isFalse);
    expect(() => state.values.clear(), throwsUnsupportedError);
  });
  _sample('publishSourcesEmpty', publishSourcesEmpty, (state) {
    expect(state.loading, isFalse); expect(state.values, isEmpty);
    expect(state.issues['companion']!.code, 'workshop_companion_unavailable');
  });
  _sample('publishSourcesPetFailed', publishSourcesPetFailed, (state) {
    expect(state.values.single.kind, 'companion'); expect(state.issues['pet']!.code, 'workshop_storage');
  });
  _sample('publishSourcesCompanionMissing', publishSourcesCompanionMissing, (state) {
    expect(state.values.single.kind, 'pet'); expect(state.issues['companion']!.code, 'workshop_companion_unavailable');
  });
  _sample('publishSourcesRefreshing', publishSourcesRefreshing, (state) {
    expect(state.loading, isTrue); expect(state.values, hasLength(2));
  });
  _sample('publishSourcesRefreshFailedKeepsChoices', publishSourcesRefreshFailedKeepsChoices, (state) {
    expect(state.loading, isFalse); expect(state.values, hasLength(2));
    expect(state.issues['all']!.code, 'workshop_storage');
  });

  _sample('publishIdleBeforePendingCheck', publishIdleBeforePendingCheck, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.idle);
    expect(sample.publish.pendingChecked, isFalse); expect(sample.publish.canEditMetadata, isFalse);
  });
  _sample('publishLoggedOut', publishLoggedOut, (sample) {
    _publisher(sample); expect(sample.access.signedIn, isFalse);
    expect(sample.publish.phase, WorkshopPublishPhase.idle); expect(sample.publish.error, isNull);
  });
  _sample('publishDisclosureRequired', publishDisclosureRequired, (sample) {
    _publisher(sample); expect(sample.access.disclosure, isNotNull);
    expect(sample.access.disclosureAccepted, isFalse); expect(sample.publish.phase, WorkshopPublishPhase.idle);
  });
  _sample('publishEditable', publishEditable, (sample) {
    _publisher(sample); expect(sample.publish.canEditMetadata, isTrue);
    expect(sample.publish.source, isNotNull); expect(sample.publish.input.rightsConfirmed, isFalse);
  });
  _sample('publishCheckingPending', publishCheckingPending, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.checking);
    expect(sample.publish.busy, isTrue); expect(sample.publish.pendingChecked, isFalse);
  });
  _sample('publishPendingReadFailed', publishPendingReadFailed, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.pendingChecked, isFalse);
    expect(sample.publish.preferenceError!.code, 'workshop_preferences');
  });
  _sample('publishProfileRequired', publishProfileRequired, (sample) {
    _publisher(sample); expect(sample.access.accountId, isNull);
    expect(sample.publish.error!.code, 'workshop_profile_required'); expect(sample.publish.pendingChecked, isFalse);
  });
  _sample('publishPreparing', publishPreparing, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.preparing);
    expect(sample.publish.busy, isTrue); expect(sample.publish.preparedMetadata, isNull);
  });
  for (final (name, factory) in <(String, Future<WorkshopPublishSample> Function())>[
    ('publishReadyShortChinese', publishReadyShortChinese),
    ('publishReadyLongChinese', publishReadyLongChinese),
    ('publishReadyEmoji', publishReadyEmoji),
    ('publishReadyEnglish', publishReadyEnglish),
  ]) {
    _sample(name, factory, (sample) {
      _publisher(sample);
      final state = sample.publish;
      expect(state.phase, WorkshopPublishPhase.ready);
      expect(state.input.errors(includeRights: false), isEmpty);
      expect(state.input.errors(), {'rightsConfirmed': 'workshop_rights_required'});
      expect(state.preparedMetadata, isNotNull);
      expect(state.files, ['pack.json', 'idle.png']);
      expect(state.busy, isFalse);
      if (name == 'publishReadyLongChinese') {
        expect(state.input.titleZh.runes.length, inInclusiveRange(100, 120));
        expect(state.input.description.runes.length, inInclusiveRange(300, 512));
      }
      if (name == 'publishReadyEmoji') expect(state.input.titleZh, contains('☁️✨'));
      if (name == 'publishReadyEnglish') {
        expect(state.input.titleZh, 'Evening Fox'); expect(state.input.titleEn, 'Evening Fox');
      }
    });
  }
  final invalidFields = <(String, Future<WorkshopPublishSample> Function(), String, String)>[
    ('publishInvalidId', publishInvalidId, 'id', 'workshop_bad_id'),
    ('publishInvalidVersion', publishInvalidVersion, 'version', 'workshop_bad_version'),
    ('publishInvalidMinimumApp', publishInvalidMinimumApp, 'minApp', 'workshop_bad_min_app'),
    ('publishInvalidChineseTitle', publishInvalidChineseTitle, 'titleZh', 'workshop_bad_title'),
    ('publishInvalidEnglishTitle', publishInvalidEnglishTitle, 'titleEn', 'workshop_bad_title'),
    ('publishInvalidAuthor', publishInvalidAuthor, 'author', 'workshop_bad_author'),
    ('publishInvalidLicense', publishInvalidLicense, 'license', 'workshop_bad_license'),
    ('publishInvalidSource', publishInvalidSource, 'source', 'workshop_bad_source'),
    ('publishInvalidDescription', publishInvalidDescription, 'description', 'workshop_bad_description'),
    ('publishInvalidTags', publishInvalidTags, 'tags', 'workshop_bad_tags'),
    ('publishRightsRequired', publishRightsRequired, 'rightsConfirmed', 'workshop_rights_required'),
  ];
  for (final (name, factory, field, code) in invalidFields) {
    _sample(name, factory, (sample) {
      _publisher(sample);
      expect(sample.publish.fieldErrors, {field: code});
      expect(sample.publish.error!.code, 'workshop_invalid_publication');
      expect(sample.publish.busy, isFalse);
      expect(sample.publish.hasPending, isFalse);
      expect(sample.publish.phase, field == 'rightsConfirmed' ? WorkshopPublishPhase.ready : WorkshopPublishPhase.idle);
    });
  }
  _sample('publishPrepareFailed', publishPrepareFailed, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.error!.code, 'workshop_no_space'); expect(sample.publish.hasPending, isFalse);
  });
  _sample('publishPrepareCleanupFailed', publishPrepareCleanupFailed, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.cleanupError!.code, 'workshop_draft_cleanup');
    expect(sample.publish.error, isNull); expect(sample.publish.preparedMetadata, isNull);
  });
  for (final (name, factory, phase) in <(String, Future<WorkshopPublishSample> Function(), WorkshopPublishPhase)>[
    ('publishCreating', publishCreating, WorkshopPublishPhase.creating),
    ('publishUploading', publishUploading, WorkshopPublishPhase.uploading),
    ('publishAwaitingResponse', publishAwaitingResponse, WorkshopPublishPhase.awaitingResponse),
    ('publishCompleteStillBusy', publishCompleteStillBusy, WorkshopPublishPhase.complete),
  ]) {
    _sample(name, factory, (sample) {
      _publisher(sample); expect(sample.publish.phase, phase); expect(sample.publish.busy, isTrue);
      expect(sample.publish.hasPending, isTrue);
      if (phase == WorkshopPublishPhase.uploading) { expect(sample.publish.sent, 2); expect(sample.publish.total, 4); }
      if (phase == WorkshopPublishPhase.complete) expect(sample.publish.result!.status, WorkshopSubmissionStatus.pending);
    });
  }
  _sample('publishComplete', publishComplete, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.complete);
    expect(sample.publish.result!.status, WorkshopSubmissionStatus.pending);
    expect(sample.publish.hasPending, isFalse); expect(sample.publish.busy, isFalse);
    expect(sample.publish.preferenceError, isNull); expect(sample.publish.cleanupError, isNull);
  });
  _sample('publishUnknownResult', publishUnknownResult, (sample) {
    _publisher(sample); expect(sample.publish.error!.resultUnknown, isTrue);
    expect(sample.publish.error!.code, 'workshop_timeout'); expect(sample.publish.result, isNull);
  });
  _sample('publishPendingSaveFailed', publishPendingSaveFailed, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.hasPending, isTrue); expect(sample.publish.preferenceError!.code, 'workshop_preferences');
    expect(sample.publish.error, isNull); expect(sample.publish.result, isNull);
    expect(sample.publish.canDiscardUnsentSubmission, isTrue);
  });
  _sample('publishKnownResultPreferenceFailed', publishKnownResultPreferenceFailed, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.complete);
    expect(sample.publish.hasPending, isTrue); expect(sample.publish.result!.status, WorkshopSubmissionStatus.pending);
    expect(sample.publish.preferenceError!.code, 'workshop_preferences'); expect(sample.publish.error, isNull);
  });
  _sample('publishCompleteCleanupFailed', publishCompleteCleanupFailed, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.complete);
    expect(sample.publish.hasPending, isFalse); expect(sample.publish.cleanupError!.code, 'workshop_draft_cleanup');
    expect(sample.publish.error, isNull);
  });
  _sample('publishRestoredPending', publishRestoredPending, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.ready);
    expect(sample.publish.source, isNull); expect(sample.publish.hasPending, isTrue);
    expect(sample.publish.pendingChecked, isTrue); expect(sample.publish.preparedMetadata!.id, 'moon-cat');
    expect(sample.publish.pendingKnownUnsent, isFalse);
    expect(sample.publish.canDiscardUnsentSubmission, isFalse);
  });
  _sample('publishRestoredKnownWithoutArchive', publishRestoredKnownWithoutArchive, (sample) {
    _publisher(sample); expect(sample.publish.result!.status, WorkshopSubmissionStatus.approved);
    expect(sample.publish.source, isNull); expect(sample.publish.hasPending, isFalse);
  });
  _sample('publishRestoredArchiveMissing', publishRestoredArchiveMissing, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.failed);
    expect(sample.publish.error!.code, 'workshop_storage'); expect(sample.publish.error!.resultUnknown, isFalse);
    expect(sample.publish.hasPending, isTrue); expect(sample.publish.source, isNull);
  });
  _sample('publishPendingUploadsDisabled', publishPendingUploadsDisabled, (sample) {
    _publisher(sample); expect(sample.access.canSubmit('pet'), isFalse);
    expect(sample.publish.error!.code, 'workshop_upload_disabled'); expect(sample.publish.hasPending, isTrue);
    expect(sample.publish.canStartNewSubmission, isFalse);
  });
  _sample('publishKnownResultRetryStarting', publishKnownResultRetryStarting, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.creating);
    expect(sample.publish.result!.status, WorkshopSubmissionStatus.pending); expect(sample.publish.busy, isTrue);
    expect(sample.publish.input.rightsConfirmed, isFalse);
    expect(sample.access.accountId, isNull); expect(sample.access.canSubmit('pet'), isFalse);
  });
  _sample('publishKnownResultLocalRetryComplete', publishKnownResultLocalRetryComplete, (sample) {
    _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.complete);
    expect(sample.publish.hasPending, isFalse); expect(sample.publish.preferenceError, isNull);
    expect(sample.publish.input.rightsConfirmed, isFalse);
    expect(sample.access.accountId, isNull); expect(sample.access.canSubmit('pet'), isFalse);
  });
  for (final (name, factory, status) in <(String, Future<WorkshopPublishSample> Function(), WorkshopSubmissionStatus)>[
    ('publishCompleteApproved', publishCompleteApproved, WorkshopSubmissionStatus.approved),
    ('publishCompleteRejected', publishCompleteRejected, WorkshopSubmissionStatus.rejected),
    ('publishCompleteWithdrawn', publishCompleteWithdrawn, WorkshopSubmissionStatus.withdrawn),
  ]) {
    _sample(name, factory, (sample) {
      _publisher(sample); expect(sample.publish.result!.status, status);
      expect(sample.publish.canStartNewSubmission, status != WorkshopSubmissionStatus.approved);
      expect(sample.publish.hasPending, isFalse);
    });
  }
  for (final (name, factory) in <(String, Future<WorkshopPublishSample> Function())>[
    ('publishNewAfterRejected', publishNewAfterRejected), ('publishNewAfterWithdrawn', publishNewAfterWithdrawn),
  ]) {
    _sample(name, factory, (sample) {
      _publisher(sample); expect(sample.publish.phase, WorkshopPublishPhase.idle);
      expect(sample.publish.canEditMetadata, isTrue); expect(sample.publish.input.rightsConfirmed, isFalse);
      expect(sample.publish.preparedMetadata, isNull); expect(sample.publish.result, isNull);
    });
  }
  _sample('publishWaitingForPreviousSession', publishWaitingForPreviousSession, (sample) {
    _publisher(sample); expect(sample.access.accountId, 43);
    expect(sample.publish.waitingForPreviousOperation, isTrue); expect(sample.publish.busy, isFalse);
    expect(sample.publish.canEditMetadata, isFalse); expect(sample.publish.source, isNull);
    expect(sample.publish.result, isNull); expect(sample.publish.preparedMetadata, isNull);
    expect(sample.publish.input.id, isEmpty);
  });
}
