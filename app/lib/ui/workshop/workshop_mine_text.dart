// Words for a submission's status, and for the reason someone has to type
// before withdrawing or reporting (我的投稿, 举报).

import '../../l10n/l10n.dart';
import '../../workshop/workshop_models.dart';
import '../common/status_chip.dart' show StatusTone;

/// 待审核 / 已通过 / 已拒绝 / 已撤回 / 草稿.
String workshopStatusLabel(L10n l10n, WorkshopSubmissionStatus status) => switch (status) {
  WorkshopSubmissionStatus.pending => l10n.workshopMineStatusPending,
  WorkshopSubmissionStatus.approved => l10n.workshopMineStatusApproved,
  WorkshopSubmissionStatus.rejected => l10n.workshopMineStatusRejected,
  WorkshopSubmissionStatus.withdrawn => l10n.workshopMineStatusWithdrawn,
  WorkshopSubmissionStatus.draft => l10n.workshopMineStatusDraft,
};

/// The chip's colour: waiting is amber, passed green, refused red; a draft
/// and a withdrawn one are over and stay grey. Nothing breathes.
StatusTone workshopStatusTone(WorkshopSubmissionStatus status) => switch (status) {
  WorkshopSubmissionStatus.pending => StatusTone.warn,
  WorkshopSubmissionStatus.approved => StatusTone.ok,
  WorkshopSubmissionStatus.rejected => StatusTone.error,
  WorkshopSubmissionStatus.withdrawn || WorkshopSubmissionStatus.draft => StatusTone.idle,
};

/// The status in a sentence. 已通过 says the review passed, not that the
/// release is public now: only the catalogue knows that.
String workshopStatusAbout(L10n l10n, WorkshopSubmissionStatus status) => switch (status) {
  WorkshopSubmissionStatus.pending => l10n.workshopMineAboutPending,
  WorkshopSubmissionStatus.approved => l10n.workshopMineAboutApproved,
  WorkshopSubmissionStatus.rejected => l10n.workshopMineAboutRejected,
  WorkshopSubmissionStatus.withdrawn => l10n.workshopMineAboutWithdrawn,
  WorkshopSubmissionStatus.draft => l10n.workshopMineAboutDraft,
};

/// 「2026-11-11 08:30」 in the phone's time zone.
String workshopStamp(DateTime at) {
  final t = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The longest reason the workshop takes, in code points (as the state layer
/// and the server count it).
const workshopReasonLimit = 2000;

/// Why [text] can't be sent as a reason, in words; null when it can. The
/// rule itself is the state layer's ([workshopText]); this only says which
/// part of it failed.
String? workshopReasonProblem(L10n l10n, String text) {
  if (workshopText(text, workshopReasonLimit)) return null;
  if (text.trim().isEmpty) return l10n.workshopMineReasonEmpty;
  if (text.runes.length > workshopReasonLimit) return l10n.workshopMineReasonTooLong('$workshopReasonLimit');
  return l10n.workshopMineReasonBadChars;
}
