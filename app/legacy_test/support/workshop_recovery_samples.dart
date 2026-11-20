part of 'workshop_page_samples.dart';

// An offer here describes a snapshot whose container has already been disposed.
// It is NOT authorization for another live controller. Interactive previews
// must drive their own notifier and obtain that notifier's current offer.

class _RecoverySampleSnapshot implements WorkshopPendingRecoverySnapshot {
  const _RecoverySampleSnapshot(this.scope, this.range);
  final String scope;
  @override
  final WorkshopPendingAbandonRange range;
}

/// Scripts only the existing recovery-store seam, over the existing in-memory
/// preferences fake. It does not duplicate SharedPreferences or its CAS logic.
/// Public offers and every returned page state come from the real notifier.
class _RecoverySamplePreferences extends PublishPreferences
    implements WorkshopPendingRecoveryStore {
  _RecoverySamplePreferences({this.range = WorkshopPendingAbandonRange.currentAccount})
      : super(<String>[]);

  final WorkshopPendingAbandonRange range;
  Future<void> Function()? beforeRecoveryRead;
  Future<void> Function()? beforeRecoveryClear;

  @override
  Future<WorkshopPendingRecoverySnapshot> pendingRecovery(String scope) async {
    final before = beforeRecoveryRead;
    if (before != null) {
      await before();
    }
    return _RecoverySampleSnapshot(scope, range);
  }

  @override
  Future<void> abandonPendingRecovery(WorkshopPendingRecoverySnapshot snapshot) async {
    final before = beforeRecoveryClear;
    if (before != null) {
      await before();
    }
    final offered = snapshot as _RecoverySampleSnapshot;
    if (offered.range == WorkshopPendingAbandonRange.allLocalAccounts) {
      pending.clear();
    } else {
      pending.remove(offered.scope);
    }
    reading = null;
    clearing = null;
  }
}

Future<void> _recoveryUnknown(PublishHarness harness) async {
  await _prepareSample(harness, text: WorkshopSampleText.emoji);
  harness.client.creating = (_) async => throw const WorkshopException(
    'workshop_timeout', resultUnknown: true);
  await harness.controller.submit();
}

Future<WorkshopPublishSample> publishRecoveryReading() async {
  final preferences = _RecoverySamplePreferences(), gate = _SampleGate();
  final harness = PublishHarness(preferences: preferences);
  try {
    await _recoveryUnknown(harness);
    preferences.beforeRecoveryRead = gate.wait;
    return await _sampleWhile(harness.controller.requestPendingAbandonment(), gate,
      () => _readPublish(harness));
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryCurrentAccountOffer() async {
  final harness = PublishHarness(preferences: _RecoverySamplePreferences());
  try {
    await _recoveryUnknown(harness);
    await harness.controller.requestPendingAbandonment();
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryAllAccountsOffer() async {
  final preferences = _RecoverySamplePreferences(
    range: WorkshopPendingAbandonRange.allLocalAccounts);
  // The real store offers this range when the container cannot be parsed.
  // No malformed text or private path is needed to render that public state.
  preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
  final harness = PublishHarness(preferences: preferences);
  try {
    await harness.start();
    await harness.controller.requestPendingAbandonment();
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryKnownResultOffer() async {
  final preferences = _RecoverySamplePreferences(
    range: WorkshopPendingAbandonRange.allLocalAccounts);
  preferences.clearing = (_, _) async => throw const WorkshopException('workshop_preferences');
  final harness = PublishHarness(preferences: preferences);
  harness.client.creating = (call) async => publishResult(call.metadata,
    status: WorkshopSubmissionStatus.rejected);
  try {
    await _prepareSample(harness, text: WorkshopSampleText.longChinese);
    await harness.controller.submit();
    final known = harness.state.result!;
    await harness.controller.requestPendingAbandonment();
    if (!identical(harness.state.result, known)) {
      throw StateError('A recovery offer replaced the already checked server result');
    }
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryReadFailed() async {
  final preferences = _RecoverySamplePreferences();
  preferences.beforeRecoveryRead = () async => throw const WorkshopException('workshop_preferences');
  final harness = PublishHarness(preferences: preferences);
  try {
    await _recoveryUnknown(harness);
    await harness.controller.requestPendingAbandonment();
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryConfirming() async {
  final preferences = _RecoverySamplePreferences(), gate = _SampleGate();
  final harness = PublishHarness(preferences: preferences);
  try {
    await _recoveryUnknown(harness);
    await harness.controller.requestPendingAbandonment();
    final offer = harness.state.abandonOffer!;
    preferences.beforeRecoveryClear = gate.wait;
    return await _sampleWhile(harness.controller.confirmPendingAbandonment(offer), gate,
      () => _readPublish(harness));
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryWriteFailed() async {
  final preferences = _RecoverySamplePreferences();
  preferences.beforeRecoveryClear = () async => throw const WorkshopException('workshop_preferences');
  final harness = PublishHarness(preferences: preferences);
  try {
    await _recoveryUnknown(harness);
    await harness.controller.requestPendingAbandonment();
    final offer = harness.state.abandonOffer!;
    await harness.controller.confirmPendingAbandonment(offer);
    if (!identical(harness.state.abandonOffer, offer)) {
      throw StateError('A failed local write lost the retryable confirmation offer');
    }
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

Future<WorkshopPublishSample> publishRecoveryOfferStale() async {
  final preferences = _RecoverySamplePreferences();
  // The existing store reports this when its captured version is no longer
  // current. The page sample does not reimplement that storage comparison.
  preferences.beforeRecoveryClear = () async => throw const WorkshopException('workshop_confirmation_stale');
  final harness = PublishHarness(preferences: preferences);
  try {
    await _recoveryUnknown(harness);
    await harness.controller.requestPendingAbandonment();
    await harness.controller.confirmPendingAbandonment(harness.state.abandonOffer!);
    return _readPublish(harness);
  } finally {
    await harness.close();
  }
}

/// Unlike the existing ordinary idle samples, a recovered form can retain its
/// text while having no selected source. The page must offer source selection.
Future<WorkshopPublishSample> publishRecoveryColdComplete() async {
  final preferences = _RecoverySamplePreferences();
  final first = PublishHarness(preferences: preferences);
  PublishHarness? recovered;
  try {
    await _recoveryUnknown(first);
    await first.close();
    recovered = PublishHarness(preferences: preferences);
    final current = recovered;
    await current.start();
    await current.controller.requestPendingAbandonment();
    await current.controller.confirmPendingAbandonment(current.state.abandonOffer!);
    if (current.client.creates.isNotEmpty || current.client.uploads.isNotEmpty) {
      throw StateError('Local recovery of the cold form sent a submission');
    }
    return _readPublish(current);
  } finally {
    if (recovered != null) {
      await recovered.close();
    }
    await first.close();
  }
}
