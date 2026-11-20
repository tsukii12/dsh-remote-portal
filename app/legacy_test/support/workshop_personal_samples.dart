part of 'workshop_page_samples.dart';

WorkshopSubmission _sampleSubmission(WorkshopMetadata metadata, {
  String id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  WorkshopSubmissionStatus status = WorkshopSubmissionStatus.pending,
}) => WorkshopSubmission.fromJson({
  'submissionId': id, 'metadata': metadata.toJson(), 'status': status.name,
  'owner': {'accountOrigin': authAccount.toString(), 'accountId': 42, 'username': '月白创作室'},
  'createdAt': '2026-11-12T00:00:00.000Z', 'updatedAt': '2026-11-12T00:00:00.000Z',
  if (status == WorkshopSubmissionStatus.approved || status == WorkshopSubmissionStatus.rejected)
    'review': {'at': '2026-11-12T00:00:00.000Z',
      'reason': status == WorkshopSubmissionStatus.approved ? '资源与公开声明一致。' : '请补充纹理图片的许可来源，修改后可重新投稿。'},
  if (status == WorkshopSubmissionStatus.withdrawn)
    'withdrawal': {'at': '2026-11-12T00:00:00.000Z', 'reason': '作者准备更新动作适配，先撤回这一版。'},
});

WorkshopSubmission _sampleRow({WorkshopSubmissionStatus status = WorkshopSubmissionStatus.pending,
  String id = personalFirstId, WorkshopSampleText text = WorkshopSampleText.shortChinese}) =>
    _sampleSubmission(workshopSampleEntry(text: text).metadata, id: id, status: status);

class WorkshopSubmissionsSample {
  const WorkshopSubmissionsSample({required this.access, required this.submissions});
  final WorkshopAccessState access;
  final WorkshopSubmissionsState submissions;
}

WorkshopSubmissionsSample _readSubmissions(AuthHarness harness) => WorkshopSubmissionsSample(
  access: harness.state, submissions: harness.container.read(workshopSubmissionsProvider));

Future<T> _withPersonal<T>(Future<T> Function(AuthHarness harness, PersonalClient client) use,
  {bool flagsDisabled = false}) async {
  final client = PersonalClient()
    ..readPage = ((_, _) async => WorkshopSubmissionPage([_sampleRow()], null))
    ..readSubmission = ((id) async => _sampleRow(id: id))
    ..withdrawSubmission = (id, _) async => _sampleRow(id: id, status: WorkshopSubmissionStatus.withdrawn);
  if (flagsDisabled) {
    client.value = WorkshopCapabilities.fromJson(workshopCaps(account: authAccount.toString(), uploads: false, companion: false));
  }
  final harness = personalHarness(client);
  try { await authReady(harness.container); return await use(harness, client); }
  finally { harness.dispose(); }
}

Future<WorkshopSubmissionsSample> submissionsIdle() => _withPersonal((harness, client) async => _readSubmissions(harness));

Future<WorkshopSubmissionsSample> _submissionsStatus(WorkshopSubmissionStatus status) => _withPersonal((harness, client) async {
  client.readPage = (_, _) async => WorkshopSubmissionPage([_sampleRow(status: status)], null);
  await harness.container.read(workshopSubmissionsProvider.notifier).selectStatus(status);
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> submissionsDraft() => _submissionsStatus(WorkshopSubmissionStatus.draft);
Future<WorkshopSubmissionsSample> submissionsPending() => _submissionsStatus(WorkshopSubmissionStatus.pending);
Future<WorkshopSubmissionsSample> submissionsApproved() => _submissionsStatus(WorkshopSubmissionStatus.approved);
Future<WorkshopSubmissionsSample> submissionsRejected() => _submissionsStatus(WorkshopSubmissionStatus.rejected);
Future<WorkshopSubmissionsSample> submissionsWithdrawn() => _submissionsStatus(WorkshopSubmissionStatus.withdrawn);

Future<WorkshopSubmissionsSample> submissionsEmpty() => _withPersonal((harness, client) async {
  client.readPage = (_, _) async => const WorkshopSubmissionPage([], null);
  await harness.container.read(workshopSubmissionsProvider.notifier).refresh();
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> submissionsHasNextPage() => _withPersonal((harness, client) async {
  client.readPage = (_, _) async => WorkshopSubmissionPage([_sampleRow()], personalFirstId);
  await harness.container.read(workshopSubmissionsProvider.notifier).refresh();
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> _submissionsLoading({bool refresh = false, bool more = false}) =>
    _withPersonal((harness, client) async {
  final controller = harness.container.read(workshopSubmissionsProvider.notifier), gate = _SampleGate();
  if (refresh || more) {
    client.readPage = (_, _) async => WorkshopSubmissionPage([_sampleRow()], personalFirstId);
    await controller.refresh();
  }
  client.readPage = (_, _) async {
    await gate.wait();
    return WorkshopSubmissionPage([_sampleRow(id: more ? personalSecondId : personalFirstId)], null);
  };
  return _sampleWhile(more ? controller.loadMore() : controller.refresh(), gate, () => _readSubmissions(harness));
});

Future<WorkshopSubmissionsSample> submissionsLoading() => _submissionsLoading();
Future<WorkshopSubmissionsSample> submissionsRefreshing() => _submissionsLoading(refresh: true);
Future<WorkshopSubmissionsSample> submissionsLoadingMore() => _submissionsLoading(more: true);

Future<WorkshopSubmissionsSample> submissionsPagesComplete() => _withPersonal((harness, client) async {
  client.readPage = (cursor, _) async => cursor == null
    ? WorkshopSubmissionPage([_sampleRow()], personalFirstId)
    : WorkshopSubmissionPage([_sampleRow(id: personalSecondId, text: WorkshopSampleText.emoji),
        _sampleRow(id: personalThirdId, text: WorkshopSampleText.english)], null);
  final controller = harness.container.read(workshopSubmissionsProvider.notifier);
  await controller.refresh();
  await controller.loadMore();
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> _submissionsReadFailure({bool empty = false, bool more = false,
  bool changeFilter = false}) => _withPersonal((harness, client) async {
  final controller = harness.container.read(workshopSubmissionsProvider.notifier);
  if (!empty) {
    client.readPage = (_, _) async => WorkshopSubmissionPage([_sampleRow()], personalFirstId);
    await controller.refresh();
  }
  client.readPage = (_, _) async => throw const WorkshopException('workshop_network');
  if (more) { await controller.loadMore(); }
  else if (changeFilter) { await controller.selectStatus(WorkshopSubmissionStatus.rejected); }
  else { await controller.refresh(); }
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> submissionsInitialReadFailed() => _submissionsReadFailure(empty: true);
Future<WorkshopSubmissionsSample> submissionsRefreshFailedKeepsRows() => _submissionsReadFailure();
Future<WorkshopSubmissionsSample> submissionsNextPageFailed() => _submissionsReadFailure(more: true);
Future<WorkshopSubmissionsSample> submissionsFilterReadFailed() => _submissionsReadFailure(changeFilter: true);

Future<WorkshopSubmissionsSample> submissionsDetailLoading() => _withPersonal((harness, client) async {
  final gate = _SampleGate();
  client.readSubmission = (id) async { await gate.wait(); return _sampleRow(id: id); };
  final controller = harness.container.read(workshopSubmissionsProvider.notifier);
  await controller.refresh();
  return _sampleWhile(controller.refreshSubmission(personalFirstId), gate, () => _readSubmissions(harness));
});

Future<WorkshopSubmissionsSample> submissionsDetailLoaded() => _withPersonal((harness, client) async {
  await harness.container.read(workshopSubmissionsProvider.notifier).refreshSubmission(personalFirstId);
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> submissionsDetailFailedKeepsValue() => _withPersonal((harness, client) async {
  final controller = harness.container.read(workshopSubmissionsProvider.notifier);
  await controller.refreshSubmission(personalFirstId);
  client.readSubmission = (_) async => throw const WorkshopException('workshop_network');
  await controller.refreshSubmission(personalFirstId);
  return _readSubmissions(harness);
});

Future<WorkshopSubmissionsSample> _withdrawal({bool sending = false, bool fail = false,
  bool unknown = false, bool reconcile = false, bool badReason = false}) => _withPersonal((harness, client) async {
  final gate = _SampleGate();
  client.withdrawSubmission = (id, _) async {
    if (sending) await gate.wait();
    if (unknown) throw const WorkshopException('workshop_network', resultUnknown: true);
    if (fail) throw const WorkshopException('workshop_account_unavailable', status: 503);
    return _sampleRow(id: id, status: WorkshopSubmissionStatus.withdrawn);
  };
  final controller = harness.container.read(workshopSubmissionsProvider.notifier);
  await controller.refresh();
  final pending = controller.withdraw(personalFirstId, badReason ? ' ' : '作者准备更新动作适配，先撤回这一版。');
  if (sending) return _sampleWhile(pending, gate, () => _readSubmissions(harness));
  await pending;
  if (reconcile) {
    client.readSubmission = (id) async => _sampleRow(id: id, status: WorkshopSubmissionStatus.withdrawn);
    await controller.refreshSubmission(personalFirstId);
  }
  return _readSubmissions(harness);
}, flagsDisabled: true);

Future<WorkshopSubmissionsSample> submissionsWithdrawalSending() => _withdrawal(sending: true);
Future<WorkshopSubmissionsSample> submissionsWithdrawalSucceeded() => _withdrawal();
Future<WorkshopSubmissionsSample> submissionsWithdrawalFailed() => _withdrawal(fail: true);
Future<WorkshopSubmissionsSample> submissionsWithdrawalInvalidReason() => _withdrawal(badReason: true);
Future<WorkshopSubmissionsSample> submissionsWithdrawalUnknown() => _withdrawal(unknown: true);
Future<WorkshopSubmissionsSample> submissionsWithdrawalReconciled() => _withdrawal(unknown: true, reconcile: true);

class WorkshopReportSample {
  const WorkshopReportSample({required this.access, required this.report, required this.entry, required this.reason});
  final WorkshopAccessState access;
  final WorkshopReportState report;
  final WorkshopEntry entry;
  final String reason;
}

Future<WorkshopReportSample> _report({bool idle = false, bool sending = false,
  bool unknown = false, bool fail = false, bool invalidReason = false, bool newAfterUnknown = false,
  bool throttled = false, bool futureError = false}) => _withPersonal((harness, client) async {
  final entry = workshopSampleEntry(text: WorkshopSampleText.emoji), gate = _SampleGate();
  final reason = invalidReason ? ' ' : '资源页没有说明纹理图片的授权来源，希望管理员核对。';
  client.sendReport = (_, _, _, _) async {
    if (sending) await gate.wait();
    if (unknown || newAfterUnknown) throw const WorkshopException('workshop_timeout', resultUnknown: true);
    if (throttled) throw const WorkshopException('workshop_rate_limited', status: 429, retryAfter: Duration(seconds: 60));
    if (futureError) throw const WorkshopException('workshop_future_rule', status: 409);
    if (fail) throw const WorkshopException('workshop_account_unavailable', status: 503);
    return personalThirdId;
  };
  WorkshopReportSample read() => WorkshopReportSample(access: harness.state,
    report: harness.container.read(workshopReportProvider), entry: entry, reason: reason);
  final controller = harness.container.read(workshopReportProvider.notifier);
  if (idle) return read();
  final pending = controller.submit(entry, reason);
  if (sending) return _sampleWhile(pending, gate, read);
  await pending;
  if (newAfterUnknown) {
    final attempt = harness.container.read(workshopReportProvider).attempt;
    if (!controller.beginNewOperation(confirmedUnknown: attempt) || client.reports.length != 1) {
      throw StateError('Explicit new report did not use its real unknown attempt');
    }
  }
  return read();
}, flagsDisabled: true);

Future<WorkshopReportSample> reportIdle() => _report(idle: true);
Future<WorkshopReportSample> reportSending() => _report(sending: true);
Future<WorkshopReportSample> reportSucceeded() => _report();
Future<WorkshopReportSample> reportFailed() => _report(fail: true);
Future<WorkshopReportSample> reportInvalidReason() => _report(invalidReason: true);
Future<WorkshopReportSample> reportUnknown() => _report(unknown: true);
Future<WorkshopReportSample> reportNewAfterUnknownConfirmed() => _report(newAfterUnknown: true);
Future<WorkshopReportSample> reportRateLimited() => _report(throttled: true);
/// Forward-compatible safe-code display, not a rule in the current Worker.
Future<WorkshopReportSample> reportUnknownFutureErrorCode() => _report(futureError: true);
