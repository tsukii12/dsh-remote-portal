// Words only the 投稿 page needs: what is wrong with one field or one picked
// cover, what a publisher code means, and why a record could not be let go.
//
// Everything else goes through workshop_text.dart, so a code reads the same
// on every workshop page. A code neither file knows gets the generic line.

import '../../l10n/l10n.dart';
import '../../state/workshop_publication.dart';
import '../../state/workshop_publish_state.dart';
import '../../workshop/workshop_models.dart';
import 'workshop_text.dart';

/// The fields of [WorkshopPublicationInput.errors], by the key it reports.
abstract final class PublishField {
  static const id = 'id';
  static const version = 'version';
  static const titleZh = 'titleZh';
  static const titleEn = 'titleEn';
  static const author = 'author';
  static const license = 'license';
  static const source = 'source';
  static const description = 'description';
  static const tags = 'tags';
  static const rights = 'rightsConfirmed';

  /// The ones the form draws, top to bottom (the first with a problem is
  /// scrolled into view).
  static const drawn = [titleZh, titleEn, id, version, author, license, source, description, tags];
}

/// What is wrong with one field, short enough to sit under it. Null when
/// [code] is null.
String? workshopFieldErrorText(L10n l10n, String? code) => switch (code) {
  null => null,
  'workshop_bad_title' => l10n.workshopPublishBadTitle,
  'workshop_bad_id' => l10n.workshopPublishBadId,
  'workshop_bad_version' => l10n.workshopPublishBadVersion,
  'workshop_bad_author' => l10n.workshopPublishBadAuthor,
  'workshop_bad_license' => l10n.workshopPublishBadLicense,
  'workshop_bad_source' => l10n.workshopPublishBadSource,
  'workshop_bad_description' => l10n.workshopPublishBadDescription,
  'workshop_bad_tags' => l10n.workshopPublishBadTags,
  'workshop_rights_required' => l10n.workshopPublishBadRights,
  _ => l10n.workshopErrorGeneric,
};

/// A publisher failure in a sentence. An unknown result is never worded as a
/// failure: the request may have arrived.
String workshopPublishErrorText(L10n l10n, WorkshopException error) {
  if (error.resultUnknown) return l10n.workshopPublishUnknownTitle;
  return switch (error.code) {
    'workshop_invalid_publication' => l10n.workshopPublishErrorInvalid,
    'workshop_prepared_mismatch' => l10n.workshopPublishErrorMismatch,
    'workshop_pending_submission' => l10n.workshopPublishErrorPending,
    'workshop_body_too_large' => l10n.workshopPublishErrorTooLarge,
    'workshop_bad_metadata' => l10n.workshopPublishErrorMetadata,
    'workshop_pending_check_required' ||
    'workshop_prepare_required' ||
    'workshop_source_required' => l10n.workshopPublishErrorNotReady,
    'workshop_new_submission_unavailable' => l10n.workshopPublishErrorAgain,
    'workshop_draft_cleanup' => l10n.workshopPublishLeftovers,
    'workshop_companion_unavailable' => l10n.workshopPublishNoCompanion,
    // Found while packing, so only a pet's idle frame: a companion's cover
    // is measured when it is picked ([workshopCoverProblemText]).
    'workshop_preview_dimensions' => l10n.workshopPublishErrorPreviewPet,
    'workshop_preview_conflict' => l10n.workshopPublishErrorPreviewConflict,
    'workshop_preview_missing' => l10n.workshopPublishErrorPreviewMissing,
    'workshop_preview_unsupported' => l10n.workshopPublishErrorPreviewUnsupported,
    'workshop_preview_size' => l10n.workshopPublishCoverBadSize,
    'workshop_preview_png' => l10n.workshopPublishCoverBadPng,
    final code => workshopErrorLine(l10n, code),
  };
}

/// Why a picked cover was not taken, short enough to sit under its row. Any
/// code but the three the cover check gives means the file could not be read.
String workshopCoverProblemText(L10n l10n, String code) => switch (code) {
  'workshop_preview_size' => l10n.workshopPublishCoverBadSize,
  'workshop_preview_png' => l10n.workshopPublishCoverBadPng,
  'workshop_preview_dimensions' => l10n.workshopPublishCoverBadDimensions,
  _ => l10n.workshopPublishCoverUnreadable,
};

/// Why the phone's record could not be let go ([WorkshopPublishState.recoveryError]).
String workshopRecoveryErrorText(L10n l10n, WorkshopException error) => switch (error.code) {
  'workshop_confirmation_stale' => l10n.workshopPublishLetGoStale,
  'workshop_recovery_unsupported' => l10n.workshopPublishLetGoUnsupported,
  'workshop_profile_required' => l10n.workshopPublishProfileTitle,
  _ => l10n.workshopErrorPreferences,
};

/// "Not now" rather than "it failed": the controller did not start the
/// command (something else is running, a check has not finished). Said once
/// in a notice; never left standing on the page.
bool workshopPublishDeclined(WorkshopException error) =>
    !error.resultUnknown &&
    const {
      'workshop_busy',
      'workshop_pending_check_required',
      'workshop_prepare_required',
      'workshop_source_required',
    }.contains(error.code);

/// The failure a step keeps on screen, if any: not a declined command, and
/// not "some fields are wrong" while those fields say so themselves.
WorkshopException? workshopPublishFailure(WorkshopPublishState state) {
  final error = state.error;
  if (error == null || workshopPublishDeclined(error)) return null;
  if (error.code == 'workshop_invalid_publication' &&
      state.fieldErrors.keys.every((field) => field == PublishField.rights || PublishField.drawn.contains(field))) {
    return null;
  }
  return error;
}

/// An SPDX id as written; the one that is not a public licence gets words.
String workshopLicenseText(L10n l10n, String license) =>
    license == 'LicenseRef-Author-Permission' ? l10n.workshopPublishLicenseAuthor : license;

/// Tags as one line of text and back. The line is split on commas (either
/// width) and 、; what is between them is kept as typed apart from the
/// spaces around it. Checking the result is the state layer's job.
String workshopTagsLine(List<String> tags) => tags.join(', ');

List<String> workshopTagsOf(String line) => [
  for (final part in line.split(RegExp('[,，、]')))
    if (part.trim().isNotEmpty) part.trim(),
];

/// Whether two inputs describe the same release (the rights tick aside).
bool workshopSameDeclaration(WorkshopPublicationInput a, WorkshopPublicationInput b) =>
    a.id == b.id &&
    a.version == b.version &&
    a.minApp == b.minApp &&
    a.titleZh == b.titleZh &&
    a.titleEn == b.titleEn &&
    a.author == b.author &&
    a.license == b.license &&
    a.source == b.source &&
    a.description == b.description &&
    a.tags.length == b.tags.length &&
    [for (var i = 0; i < a.tags.length; i++) a.tags[i] == b.tags[i]].every((same) => same);
