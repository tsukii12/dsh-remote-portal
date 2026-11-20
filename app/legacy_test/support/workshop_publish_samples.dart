part of 'workshop_page_samples.dart';

/// Access and publisher are captured from one container/session. Login and
/// consent are Access facts, not invented publisher phases.
class WorkshopPublishSample {
  const WorkshopPublishSample({required this.access, required this.publish});
  final WorkshopAccessState access;
  final WorkshopPublishState publish;
}

WorkshopPublishSample _readPublish(PublishHarness harness) => WorkshopPublishSample(
  access: harness.container.read(workshopAccessProvider), publish: harness.state);

Future<void> _prepareSample(PublishHarness harness, {bool rights = true,
  WorkshopSampleText text = WorkshopSampleText.shortChinese,
  WorkshopPublishSource source = publishSource}) async {
  await harness.start();
  if (!harness.controller.selectSource(source) ||
      !harness.controller.setInput(workshopSampleInput(text: text, rights: rights))) {
    throw StateError('Sample form did not enter the editor');
  }
  await harness.controller.prepare();
}

Future<WorkshopPublishSample> publishIdleBeforePendingCheck() async {
  final harness = PublishHarness();
  try { await authReady(harness.container); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishLoggedOut() async {
  final harness = PublishHarness(initial: authSignedOut);
  try { await authReady(harness.container); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishDisclosureRequired() async {
  final preferences = PublishPreferences([])..accepted.clear();
  final harness = PublishHarness(preferences: preferences);
  try { await authReady(harness.container); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishEditable() async {
  final harness = PublishHarness();
  try {
    await harness.start();
    harness.controller.selectSource(publishSource);
    return _readPublish(harness);
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishCheckingPending() async {
  final gate = _SampleGate();
  final harness = PublishHarness();
  harness.preferences.reading = (_) async { await gate.wait(); return null; };
  try {
    await authReady(harness.container);
    return await _sampleWhile(harness.controller.restorePending(), gate, () => _readPublish(harness));
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishPendingReadFailed() async {
  final harness = PublishHarness();
  harness.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
  try { await harness.start(); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishProfileRequired() async {
  final harness = PublishHarness(initial: authSignedIn(userId: null));
  try { await harness.start(); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishPreparing() async {
  final gate = _SampleGate();
  final harness = PublishHarness();
  harness.drafts.beforeReturn = (_) => gate.wait();
  try {
    await harness.start();
    harness.controller.selectSource(publishSource);
    harness.controller.setInput(workshopSampleInput());
    return await _sampleWhile(harness.controller.prepare(), gate, () => _readPublish(harness));
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> _publishReady(WorkshopSampleText text) async {
  final harness = PublishHarness();
  try { await _prepareSample(harness, text: text, rights: false); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishReadyShortChinese() => _publishReady(WorkshopSampleText.shortChinese);
Future<WorkshopPublishSample> publishReadyLongChinese() => _publishReady(WorkshopSampleText.longChinese);
Future<WorkshopPublishSample> publishReadyEmoji() => _publishReady(WorkshopSampleText.emoji);
Future<WorkshopPublishSample> publishReadyEnglish() => _publishReady(WorkshopSampleText.english);

Future<void> _pendingUnsentSample(PublishHarness harness) async {
  await _prepareSample(harness, source: const WorkshopPublishSource(
    kind: 'companion', localId: 'companion', name: '月白伙伴'));
  // The production Client supplies this marker only before entering POST.
  // This sample injects that contract into the real notifier; it does not
  // itself execute the Client's transport or its separate regression tests.
  harness.client.creating = (_) async => throw const WorkshopException(
    'workshop_companion_disabled', mutationNotSent: true);
  await harness.controller.submit();
  harness.client.value = WorkshopCapabilities.fromJson(workshopCaps(companion: false));
  await harness.container.read(workshopAccessProvider.notifier).refresh();
}

Future<WorkshopPublishSample> publishPendingKnownUnsent() async {
  final harness = PublishHarness();
  try { await _pendingUnsentSample(harness); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishDiscardingUnsent() async {
  final harness = PublishHarness(), gate = _SampleGate();
  try {
    await _pendingUnsentSample(harness);
    harness.preferences.clearing = (_, _) => gate.wait();
    return await _sampleWhile(harness.controller.discardUnsentSubmission(), gate,
      () => _readPublish(harness));
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishDiscardUnsentPreferenceFailed() async {
  final harness = PublishHarness();
  try {
    await _pendingUnsentSample(harness);
    harness.preferences.clearing = (_, _) async => throw const WorkshopException('workshop_preferences');
    await harness.controller.discardUnsentSubmission();
    return _readPublish(harness);
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishDiscardUnsentComplete() async {
  final harness = PublishHarness();
  try {
    await _pendingUnsentSample(harness);
    await harness.controller.discardUnsentSubmission();
    return _readPublish(harness);
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishDiscardUnsentCleanupFailed() async {
  final harness = PublishHarness();
  try {
    await _pendingUnsentSample(harness);
    harness.drafts.cleanup = (_) async => throw const WorkshopException('workshop_storage');
    await harness.controller.discardUnsentSubmission();
    return _readPublish(harness);
  } finally {
    harness.drafts.cleanup = null;
    await harness.controller.retryCleanup();
    await harness.close();
  }
}

Future<WorkshopPublishSample> _publishInvalid(WorkshopPublicationInput input, {bool rightsOnly = false}) async {
  final harness = PublishHarness();
  try {
    if (rightsOnly) {
      await _prepareSample(harness, rights: false);
      await harness.controller.submit();
    } else {
      await harness.start();
      harness.controller.selectSource(publishSource);
      harness.controller.setInput(input);
      await harness.controller.prepare();
    }
    return _readPublish(harness);
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishInvalidId() => _publishInvalid(workshopSampleInput().copyWith(id: '月白'));
Future<WorkshopPublishSample> publishInvalidVersion() => _publishInvalid(workshopSampleInput().copyWith(version: 'next'));
Future<WorkshopPublishSample> publishInvalidMinimumApp() => _publishInvalid(workshopSampleInput().copyWith(minApp: '1.0'));
Future<WorkshopPublishSample> publishInvalidChineseTitle() => _publishInvalid(workshopSampleInput().copyWith(titleZh: '长' * 121));
Future<WorkshopPublishSample> publishInvalidEnglishTitle() => _publishInvalid(workshopSampleInput().copyWith(titleEn: ''));
Future<WorkshopPublishSample> publishInvalidAuthor() => _publishInvalid(workshopSampleInput().copyWith(author: ''));
Future<WorkshopPublishSample> publishInvalidLicense() => _publishInvalid(workshopSampleInput().copyWith(license: '自定义口头许可'));
Future<WorkshopPublishSample> publishInvalidSource() => _publishInvalid(workshopSampleInput().copyWith(source: 'https://samples.example/a b'));
Future<WorkshopPublishSample> publishInvalidDescription() => _publishInvalid(workshopSampleInput().copyWith(description: '介' * 513));
Future<WorkshopPublishSample> publishInvalidTags() => _publishInvalid(workshopSampleInput().copyWith(tags: ['像素', '像素']));
Future<WorkshopPublishSample> publishRightsRequired() => _publishInvalid(workshopSampleInput(), rightsOnly: true);

Future<WorkshopPublishSample> publishPrepareFailed() async {
  final harness = PublishHarness();
  harness.drafts.beforeReturn = (probe) async {
    // As with the production prepare seam, a throwing producer owns its own
    // incomplete draft; the controller never received that lease.
    await probe.draft.dispose();
    throw const WorkshopException('workshop_no_space');
  };
  try { await _prepareSample(harness); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishPrepareCleanupFailed() async {
  final harness = PublishHarness();
  try {
    await _prepareSample(harness);
    harness.drafts.cleanup = (_) async => throw const WorkshopException('workshop_storage');
    harness.controller.setInput(harness.state.input.copyWith(author: '阿禾与朋友'));
    await harness.controller.prepare();
    return _readPublish(harness);
  } finally {
    harness.drafts.cleanup = null;
    await harness.controller.retryCleanup();
    await harness.close();
  }
}

Future<WorkshopPublishSample> _publishInFlight(WorkshopPublishPhase phase) async {
  final gate = _SampleGate();
  final harness = PublishHarness();
  if (phase == WorkshopPublishPhase.creating) {
    harness.client.creating = (call) async { await gate.wait(); return publishResult(call.metadata); };
  } else if (phase == WorkshopPublishPhase.complete) {
    harness.preferences.clearing = (_, _) => gate.wait();
  } else {
    harness.client.uploading = (call) async {
      call.progress?.call(phase == WorkshopPublishPhase.awaitingResponse ? 4 : 2, 4);
      await gate.wait();
      return publishResult(call.draft.metadata, id: call.draft.id, status: WorkshopSubmissionStatus.pending);
    };
  }
  try {
    await _prepareSample(harness);
    return await _sampleWhile(harness.controller.submit(), gate, () => _readPublish(harness));
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishCreating() => _publishInFlight(WorkshopPublishPhase.creating);
Future<WorkshopPublishSample> publishUploading() => _publishInFlight(WorkshopPublishPhase.uploading);
Future<WorkshopPublishSample> publishAwaitingResponse() => _publishInFlight(WorkshopPublishPhase.awaitingResponse);
Future<WorkshopPublishSample> publishCompleteStillBusy() => _publishInFlight(WorkshopPublishPhase.complete);

Future<WorkshopPublishSample> publishComplete() async {
  final harness = PublishHarness();
  try { await _prepareSample(harness); await harness.controller.submit(); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishUnknownResult() async {
  final harness = PublishHarness();
  harness.client.creating = (_) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
  try { await _prepareSample(harness); await harness.controller.submit(); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishPendingSaveFailed() async {
  final harness = PublishHarness();
  harness.preferences.saving = (_, _) async => throw const WorkshopException('workshop_preferences');
  try { await _prepareSample(harness); await harness.controller.submit(); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishKnownResultPreferenceFailed() async {
  final harness = PublishHarness();
  harness.preferences.clearing = (_, _) async => throw const WorkshopException('workshop_preferences');
  try { await _prepareSample(harness); await harness.controller.submit(); return _readPublish(harness); }
  finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishCompleteCleanupFailed() async {
  final harness = PublishHarness();
  harness.drafts.cleanup = (_) async => throw const WorkshopException('workshop_storage');
  try { await _prepareSample(harness); await harness.controller.submit(); return _readPublish(harness); }
  finally { harness.drafts.cleanup = null; await harness.controller.retryCleanup(); await harness.close(); }
}

Future<WorkshopPublishSample> _publishRecovered({bool knownResult = false,
  bool missingArchive = false, bool uploadsDisabled = false}) async {
  final first = PublishHarness();
  PublishHarness? recovered;
  first.client.creating = (_) async => throw const WorkshopException('workshop_network', resultUnknown: true);
  try {
    await _prepareSample(first);
    await first.controller.submit();
    final originalId = first.client.creates.single.requestId;
    recovered = PublishHarness(preferences: first.preferences);
    final current = recovered;
    if (knownResult) {
      current.client.creating = (call) async => _sampleSubmission(call.metadata,
        status: WorkshopSubmissionStatus.approved);
      current.client.uploading = (_) async => throw StateError('Known result must not borrow an archive');
    } else if (missingArchive) {
      // This is the production archive-read error at its existing client seam.
      // No real file is created or deliberately corrupted by a page sample.
      current.client.uploading = (_) async => throw const WorkshopException('workshop_storage');
    } else if (uploadsDisabled) {
      current.client.value = WorkshopCapabilities.fromJson(workshopCaps(account: authAccount.toString(), uploads: false));
      current.client.creating = (_) async => throw const WorkshopException('workshop_upload_disabled');
    }
    await current.start();
    if (current.client.creates.isNotEmpty || current.client.uploads.isNotEmpty) {
      throw StateError('Restoration sent a mutation');
    }
    if (knownResult || missingArchive || uploadsDisabled) {
      await current.controller.retrySubmission();
      if (current.client.creates.single.requestId != originalId) {
        throw StateError('Recovery changed the pending request id');
      }
    }
    return _readPublish(current);
  } finally {
    if (recovered != null) await recovered.close();
    await first.close();
  }
}

Future<WorkshopPublishSample> publishRestoredPending() => _publishRecovered();
Future<WorkshopPublishSample> publishRestoredKnownWithoutArchive() => _publishRecovered(knownResult: true);
Future<WorkshopPublishSample> publishRestoredArchiveMissing() => _publishRecovered(missingArchive: true);
Future<WorkshopPublishSample> publishPendingUploadsDisabled() => _publishRecovered(uploadsDisabled: true);

Future<WorkshopPublishSample> _publishKnownLocalRetry({bool captureStarting = false}) async {
  final harness = PublishHarness();
  harness.preferences.clearing = (_, _) async => throw const WorkshopException('workshop_preferences');
  ProviderSubscription<WorkshopPublishState>? observation;
  WorkshopPublishState? starting;
  try {
    await _prepareSample(harness);
    await harness.controller.submit();
    harness.controller.setInput(harness.state.input.copyWith(rightsConfirmed: false));
    final credentials = harness.container.read(workshopAccountProvider).credential;
    harness.account.emit(authSignedIn(credential: credentials, userId: null));
    await authReady(harness.container);
    harness.preferences.clearing = null;
    final creates = harness.client.creates.length, uploads = harness.client.uploads.length;
    observation = harness.container.listen(workshopPublishProvider, (_, next) {
      if (next.phase == WorkshopPublishPhase.creating && next.result != null) starting = next;
    });
    await harness.controller.retrySubmission();
    if (harness.client.creates.length != creates || harness.client.uploads.length != uploads) {
      throw StateError('Known-result local retry sent another mutation');
    }
    if (!captureStarting) return _readPublish(harness);
    final captured = starting;
    if (captured == null) throw StateError('Local retry did not emit its actual starting state');
    return WorkshopPublishSample(access: harness.container.read(workshopAccessProvider), publish: captured);
  } finally { observation?.close(); await harness.close(); }
}

Future<WorkshopPublishSample> publishKnownResultRetryStarting() => _publishKnownLocalRetry(captureStarting: true);
Future<WorkshopPublishSample> publishKnownResultLocalRetryComplete() => _publishKnownLocalRetry();

Future<WorkshopPublishSample> _publishTerminal(WorkshopSubmissionStatus status, {bool startNew = false}) async {
  final harness = PublishHarness();
  harness.client.creating = (_) async => throw const WorkshopException('workshop_network', resultUnknown: true);
  try {
    await _prepareSample(harness);
    await harness.controller.submit();
    final originalId = harness.client.creates.single.requestId;
    harness.client.creating = (call) async => _sampleSubmission(call.metadata, status: status);
    await harness.controller.retrySubmission();
    if (harness.client.creates.last.requestId != originalId || harness.client.uploads.isNotEmpty) {
      throw StateError('Known terminal recovery changed the original intent');
    }
    if (startNew) await harness.controller.startNewSubmission();
    return _readPublish(harness);
  } finally { await harness.close(); }
}

Future<WorkshopPublishSample> publishCompleteApproved() => _publishTerminal(WorkshopSubmissionStatus.approved);
Future<WorkshopPublishSample> publishCompleteRejected() => _publishTerminal(WorkshopSubmissionStatus.rejected);
Future<WorkshopPublishSample> publishCompleteWithdrawn() => _publishTerminal(WorkshopSubmissionStatus.withdrawn);
Future<WorkshopPublishSample> publishNewAfterRejected() => _publishTerminal(WorkshopSubmissionStatus.rejected, startNew: true);
Future<WorkshopPublishSample> publishNewAfterWithdrawn() => _publishTerminal(WorkshopSubmissionStatus.withdrawn, startNew: true);

Future<WorkshopPublishSample> publishWaitingForPreviousSession() async {
  final harness = PublishHarness(), gate = _SampleGate();
  harness.client.uploading = (call) async {
    call.progress?.call(2, 4);
    await gate.wait();
    return publishResult(call.draft.metadata, id: call.draft.id, status: WorkshopSubmissionStatus.pending);
  };
  Future<void>? pending;
  try {
    await _prepareSample(harness);
    pending = harness.controller.submit();
    final settled = stateSettled(pending);
    try {
      await stateSignal(gate.entered, pending);
      harness.account.emit(authSignedIn(credential:
        const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      await authReady(harness.container);
      return _readPublish(harness);
    } finally { gate.release(); await settled; }
  } finally {
    gate.release();
    if (pending != null) await stateSettled(pending);
    await harness.close();
  }
}
