import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/workshop_page_samples.dart';
import 'workshop_auth_test_support.dart';

void _sameSession(WorkshopPublishSample sample) {
  expect(sample.publish.session, same(sample.access.session));
}

void _unknownPending(WorkshopPublishSample sample, {bool busy = false}) {
  _sameSession(sample);
  final state = sample.publish;
  expect(state.phase, WorkshopPublishPhase.failed);
  expect(state.working, busy);
  expect(state.pendingChecked, isTrue);
  expect(state.hasPending, isTrue);
  expect(state.pendingKnownUnsent, isFalse);
  expect(state.canDiscardUnsentSubmission, isFalse);
  expect(state.canEditMetadata, isFalse);
  expect(state.source, isNotNull);
  expect(state.preparedMetadata, isNotNull);
  expect(state.files, isNotEmpty);
  expect(state.error!.code, 'workshop_timeout');
  expect(state.error!.resultUnknown, isTrue);
  expect(state.preferenceError, isNull);
  expect(state.result, isNull);
}

void _offer(WorkshopPublishState state, WorkshopPendingAbandonRange range) {
  final offer = state.abandonOffer;
  expect(offer, isNotNull);
  expect(offer!.range, range);
  expect((offer.worker, offer.account, offer.accountId), (authWorker, authAccount, 42));
}

void main() {
  test('publishRecoveryReading', () async {
    final sample = await publishRecoveryReading();
    _unknownPending(sample, busy: true);
    expect(sample.publish.canRequestPendingAbandonment, isFalse);
    expect(sample.publish.abandonOffer, isNull);
    expect(sample.publish.recoveryError, isNull);
  });

  test('publishRecoveryCurrentAccountOffer', () async {
    final sample = await publishRecoveryCurrentAccountOffer();
    _unknownPending(sample);
    _offer(sample.publish, WorkshopPendingAbandonRange.currentAccount);
    expect(sample.publish.canRequestPendingAbandonment, isTrue);
    expect(sample.publish.recoveryError, isNull);
    expect(sample.publish.input.titleZh, workshopSampleInput(text: WorkshopSampleText.emoji).titleZh);
  });

  test('publishRecoveryAllAccountsOffer', () async {
    final sample = await publishRecoveryAllAccountsOffer();
    _sameSession(sample);
    final state = sample.publish;
    _offer(state, WorkshopPendingAbandonRange.allLocalAccounts);
    expect(state.phase, WorkshopPublishPhase.failed);
    expect(state.working, isFalse);
    expect(state.pendingChecked, isFalse);
    expect(state.hasPending, isFalse); // An unreadable journal is not a trusted pending record.
    expect(state.preferenceError!.code, 'workshop_preferences');
    expect(state.error, same(state.preferenceError));
    expect(state.recoveryError, isNull);
    expect(state.source, isNull);
    expect(state.preparedMetadata, isNull);
    expect(state.result, isNull);
    expect(state.canRequestPendingAbandonment, isTrue);
    expect(state.canDiscardUnsentSubmission, isFalse);
    expect(state.canEditMetadata, isFalse);
  });

  test('publishRecoveryKnownResultOffer', () async {
    final sample = await publishRecoveryKnownResultOffer();
    _sameSession(sample);
    final state = sample.publish;
    _offer(state, WorkshopPendingAbandonRange.allLocalAccounts);
    expect(state.phase, WorkshopPublishPhase.complete);
    expect(state.working, isFalse);
    expect(state.result!.status, WorkshopSubmissionStatus.rejected);
    expect(state.preparedMetadata!.toJson(), state.result!.metadata.toJson());
    expect(state.input.titleZh, workshopSampleInput(text: WorkshopSampleText.longChinese).titleZh);
    expect(state.hasPending, isTrue);
    expect(state.pendingKnownUnsent, isFalse);
    expect(state.preferenceError!.code, 'workshop_preferences');
    expect(state.error, isNull);
    expect(state.recoveryError, isNull);
    expect(state.canRequestPendingAbandonment, isTrue);
    expect(state.canStartNewSubmission, isFalse);
  });

  test('publishRecoveryReadFailed', () async {
    final sample = await publishRecoveryReadFailed();
    _unknownPending(sample);
    expect(sample.publish.recoveryError!.code, 'workshop_preferences');
    expect(sample.publish.abandonOffer, isNull);
    expect(sample.publish.canRequestPendingAbandonment, isTrue);
  });

  test('publishRecoveryConfirming', () async {
    final sample = await publishRecoveryConfirming();
    _unknownPending(sample, busy: true);
    _offer(sample.publish, WorkshopPendingAbandonRange.currentAccount);
    expect(sample.publish.canRequestPendingAbandonment, isFalse);
    expect(sample.publish.recoveryError, isNull);
  });

  test('publishRecoveryWriteFailed', () async {
    final sample = await publishRecoveryWriteFailed();
    _unknownPending(sample);
    _offer(sample.publish, WorkshopPendingAbandonRange.currentAccount);
    expect(sample.publish.recoveryError!.code, 'workshop_preferences');
    expect(sample.publish.canRequestPendingAbandonment, isTrue);
  });

  test('publishRecoveryOfferStale', () async {
    final sample = await publishRecoveryOfferStale();
    _unknownPending(sample);
    expect(sample.publish.recoveryError!.code, 'workshop_confirmation_stale');
    expect(sample.publish.abandonOffer, isNull);
    expect(sample.publish.canRequestPendingAbandonment, isTrue);
  });

  test('publishRecoveryColdComplete', () async {
    final sample = await publishRecoveryColdComplete();
    _sameSession(sample);
    final state = sample.publish;
    expect(state.phase, WorkshopPublishPhase.idle);
    expect(state.working, isFalse);
    expect(state.pendingChecked, isTrue);
    expect(state.hasPending, isFalse);
    expect(state.pendingKnownUnsent, isFalse);
    expect(state.source, isNull);
    expect(state.preparedMetadata, isNull);
    expect(state.files, isEmpty);
    expect((state.sent, state.total), (0, 0));
    expect(state.input.titleZh, workshopSampleInput(text: WorkshopSampleText.emoji).titleZh);
    expect(state.input.rightsConfirmed, isFalse);
    expect(state.result, isNull);
    expect(state.error, isNull);
    expect(state.preferenceError, isNull);
    expect(state.recoveryError, isNull);
    expect(state.cleanupError, isNull);
    expect(state.abandonOffer, isNull);
    expect(state.canRequestPendingAbandonment, isFalse);
    expect(state.canEditMetadata, isTrue);
  });
}
