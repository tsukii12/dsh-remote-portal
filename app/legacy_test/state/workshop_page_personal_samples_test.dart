import 'package:dsh_app/state/workshop_report_state.dart';
import 'package:dsh_app/state/workshop_submissions_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/workshop_page_samples.dart';

void _sample<T>(String name, Future<T> Function() factory, void Function(T) verify) {
  test(name, () async => verify(await factory()));
}

void _submissions(WorkshopSubmissionsSample sample) {
  final state = sample.submissions;
  expect(state.session, same(sample.access.session));
  expect(state.busy, state.operation != WorkshopSubmissionsOperation.idle);
  expect(state.hasMore, state.hasLoaded && state.nextCursor != null);
  expect(state.items.map((item) => item.id).toSet().length, state.items.length);
  expect(() => state.items.clear(), throwsUnsupportedError);
  for (final item in state.items) {
    expect(item.ownerOrigin, sample.access.account);
    expect(item.ownerId, sample.access.accountId);
    if (state.status != null) expect(item.status, state.status);
  }
  if (state.detail != null) expect(state.detail!.id, state.detailId);
  if (state.withdrawal.phase == WorkshopWithdrawalPhase.succeeded) {
    expect(state.withdrawal.submission!.status, WorkshopSubmissionStatus.withdrawn);
    expect(state.withdrawal.submission!.id, state.withdrawal.submissionId);
    expect(state.withdrawal.error, isNull);
  }
}

void _report(WorkshopReportSample sample) {
  final state = sample.report;
  expect(state.session, same(sample.access.session));
  expect(state.busy, state.phase == WorkshopReportPhase.sending);
  // Reporting remains available when both upload feature switches are off.
  expect(sample.access.uploadsEnabled, isFalse);
  expect(sample.access.companionEnabled, isFalse);
  expect(sample.access.canAuthenticate, isTrue);
  if (state.attempt != null) {
    expect(state.attempt!.kind, sample.entry.metadata.kind);
    expect(state.attempt!.id, sample.entry.metadata.id);
    expect(state.attempt!.version, sample.entry.metadata.version);
    expect(state.attempt!.reason, sample.reason);
  }
  if (state.phase == WorkshopReportPhase.succeeded) {
    expect(state.reportId, matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(state.error, isNull);
  } else {
    expect(state.reportId, isNull);
  }
  if (state.phase == WorkshopReportPhase.unknown) {
    expect(state.error!.resultUnknown, isTrue);
    expect(state.attempt, isNotNull);
  }
}

void main() {
  _sample('submissionsIdle', submissionsIdle, (sample) {
    _submissions(sample);
    expect(sample.submissions.operation, WorkshopSubmissionsOperation.idle);
    expect(sample.submissions.items, isEmpty);
    expect(sample.submissions.hasLoaded, isFalse);
  });
  for (final (name, factory, status) in <(String, Future<WorkshopSubmissionsSample> Function(), WorkshopSubmissionStatus)>[
    ('submissionsDraft', submissionsDraft, WorkshopSubmissionStatus.draft),
    ('submissionsPending', submissionsPending, WorkshopSubmissionStatus.pending),
    ('submissionsApproved', submissionsApproved, WorkshopSubmissionStatus.approved),
    ('submissionsRejected', submissionsRejected, WorkshopSubmissionStatus.rejected),
    ('submissionsWithdrawn', submissionsWithdrawn, WorkshopSubmissionStatus.withdrawn),
  ]) {
    _sample(name, factory, (sample) {
      _submissions(sample);
      final state = sample.submissions, item = sample.submissions.items.single;
      expect(state.status, status);
      expect(item.status, status);
      expect(state.hasLoaded, isTrue);
      expect(state.hasMore, isFalse);
      if (status == WorkshopSubmissionStatus.rejected || status == WorkshopSubmissionStatus.approved) {
        expect(item.reviewReason, isNotEmpty);
      }
      if (status == WorkshopSubmissionStatus.withdrawn) expect(item.withdrawalReason, isNotEmpty);
      // An approved submission has no "current public release" field here.
    });
  }
  _sample('submissionsEmpty', submissionsEmpty, (sample) {
    _submissions(sample); expect(sample.submissions.hasLoaded, isTrue);
    expect(sample.submissions.items, isEmpty); expect(sample.submissions.error, isNull);
  });
  _sample('submissionsHasNextPage', submissionsHasNextPage, (sample) {
    _submissions(sample); expect(sample.submissions.hasMore, isTrue);
    expect(sample.submissions.items, hasLength(1)); expect(sample.submissions.nextCursor, sample.submissions.items.single.id);
  });
  for (final (name, factory, operation, retained) in <(String, Future<WorkshopSubmissionsSample> Function(), WorkshopSubmissionsOperation, bool)>[
    ('submissionsLoading', submissionsLoading, WorkshopSubmissionsOperation.refresh, false),
    ('submissionsRefreshing', submissionsRefreshing, WorkshopSubmissionsOperation.refresh, true),
    ('submissionsLoadingMore', submissionsLoadingMore, WorkshopSubmissionsOperation.more, true),
  ]) {
    _sample(name, factory, (sample) {
      _submissions(sample); expect(sample.submissions.operation, operation);
      expect(sample.submissions.busy, isTrue); expect(sample.submissions.hasLoaded, retained);
      expect(sample.submissions.items.length, retained ? 1 : 0);
      expect(sample.submissions.error, isNull);
    });
  }
  _sample('submissionsPagesComplete', submissionsPagesComplete, (sample) {
    _submissions(sample); expect(sample.submissions.items, hasLength(3));
    expect(sample.submissions.hasMore, isFalse);
    expect(sample.submissions.items[1].metadata.title['zh'], '云端旅人 ☁️✨');
    expect(sample.submissions.items.last.metadata.title['zh'], 'Evening Fox');
  });
  for (final (name, factory, retained) in <(String, Future<WorkshopSubmissionsSample> Function(), bool)>[
    ('submissionsInitialReadFailed', submissionsInitialReadFailed, false),
    ('submissionsRefreshFailedKeepsRows', submissionsRefreshFailedKeepsRows, true),
    ('submissionsNextPageFailed', submissionsNextPageFailed, true),
    ('submissionsFilterReadFailed', submissionsFilterReadFailed, false),
  ]) {
    _sample(name, factory, (sample) {
      _submissions(sample); expect(sample.submissions.error!.code, 'workshop_network');
      expect(sample.submissions.error!.resultUnknown, isFalse);
      expect(sample.submissions.items.length, retained ? 1 : 0);
      expect(sample.submissions.hasLoaded, retained); expect(sample.submissions.hasMore, retained);
      expect(sample.submissions.busy, isFalse);
      if (name == 'submissionsFilterReadFailed') expect(sample.submissions.status, WorkshopSubmissionStatus.rejected);
    });
  }
  _sample('submissionsDetailLoading', submissionsDetailLoading, (sample) {
    _submissions(sample); expect(sample.submissions.operation, WorkshopSubmissionsOperation.detail);
    expect(sample.submissions.operationSubmissionId, sample.submissions.detailId);
    expect(sample.submissions.detail, isNull); expect(sample.submissions.items, hasLength(1));
  });
  _sample('submissionsDetailLoaded', submissionsDetailLoaded, (sample) {
    _submissions(sample); expect(sample.submissions.detail, isNotNull);
    expect(sample.submissions.detailError, isNull);
    expect(sample.submissions.items, isEmpty); // A detail read does not insert an out-of-page row.
  });
  _sample('submissionsDetailFailedKeepsValue', submissionsDetailFailedKeepsValue, (sample) {
    _submissions(sample); expect(sample.submissions.detail, isNotNull);
    expect(sample.submissions.detailError!.code, 'workshop_network'); expect(sample.submissions.busy, isFalse);
  });
  for (final (name, factory, phase) in <(String, Future<WorkshopSubmissionsSample> Function(), WorkshopWithdrawalPhase)>[
    ('submissionsWithdrawalSending', submissionsWithdrawalSending, WorkshopWithdrawalPhase.sending),
    ('submissionsWithdrawalSucceeded', submissionsWithdrawalSucceeded, WorkshopWithdrawalPhase.succeeded),
    ('submissionsWithdrawalFailed', submissionsWithdrawalFailed, WorkshopWithdrawalPhase.failed),
    ('submissionsWithdrawalInvalidReason', submissionsWithdrawalInvalidReason, WorkshopWithdrawalPhase.failed),
    ('submissionsWithdrawalUnknown', submissionsWithdrawalUnknown, WorkshopWithdrawalPhase.unknown),
    ('submissionsWithdrawalReconciled', submissionsWithdrawalReconciled, WorkshopWithdrawalPhase.succeeded),
  ]) {
    _sample(name, factory, (sample) {
      _submissions(sample);
      final state = sample.submissions;
      expect(sample.access.uploadsEnabled, isFalse); expect(sample.access.companionEnabled, isFalse);
      expect(state.withdrawal.phase, phase);
      expect(state.busy, phase == WorkshopWithdrawalPhase.sending);
      expect(state.withdrawal.reconciled, name == 'submissionsWithdrawalReconciled');
      expect(state.items.single.status, phase == WorkshopWithdrawalPhase.succeeded
        ? WorkshopSubmissionStatus.withdrawn : WorkshopSubmissionStatus.pending);
      if (phase == WorkshopWithdrawalPhase.unknown) expect(state.withdrawal.error!.resultUnknown, isTrue);
      if (name == 'submissionsWithdrawalFailed') {
        expect(state.withdrawal.error!.code, 'workshop_account_unavailable'); expect(state.withdrawal.error!.status, 503);
      }
      if (name == 'submissionsWithdrawalInvalidReason') expect(state.withdrawal.error!.code, 'workshop_bad_reason');
    });
  }

  for (final (name, factory, phase) in <(String, Future<WorkshopReportSample> Function(), WorkshopReportPhase)>[
    ('reportIdle', reportIdle, WorkshopReportPhase.idle),
    ('reportSending', reportSending, WorkshopReportPhase.sending),
    ('reportSucceeded', reportSucceeded, WorkshopReportPhase.succeeded),
    ('reportFailed', reportFailed, WorkshopReportPhase.failed),
    ('reportInvalidReason', reportInvalidReason, WorkshopReportPhase.failed),
    ('reportUnknown', reportUnknown, WorkshopReportPhase.unknown),
    ('reportNewAfterUnknownConfirmed', reportNewAfterUnknownConfirmed, WorkshopReportPhase.idle),
    ('reportRateLimited', reportRateLimited, WorkshopReportPhase.failed),
    ('reportUnknownFutureErrorCode', reportUnknownFutureErrorCode, WorkshopReportPhase.failed),
  ]) {
    _sample(name, factory, (sample) {
      _report(sample); expect(sample.report.phase, phase);
      if (phase == WorkshopReportPhase.idle) expect(sample.report.attempt, isNull);
      if (name == 'reportFailed') {
        expect(sample.report.error!.code, 'workshop_account_unavailable'); expect(sample.report.error!.status, 503);
        expect(sample.report.error!.resultUnknown, isFalse);
      }
      if (name == 'reportInvalidReason') expect(sample.report.error!.code, 'workshop_bad_reason');
      if (name == 'reportRateLimited') {
        expect(sample.report.error!.code, 'workshop_rate_limited'); expect(sample.report.error!.status, 429);
        expect(sample.report.error!.retryAfter, const Duration(seconds: 60));
      }
      if (name == 'reportUnknownFutureErrorCode') {
        expect(sample.report.error!.code, 'workshop_future_rule'); expect(sample.report.error!.status, 409);
        expect(sample.report.error!.resultUnknown, isFalse);
      }
    });
  }
}
