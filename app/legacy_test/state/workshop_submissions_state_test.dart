import 'dart:async';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_report_state.dart';
import 'package:dsh_app/state/workshop_submissions_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show workshopCaps;
import 'workshop_auth_test_support.dart';
import 'workshop_personal_test_support.dart';

void main() {
  test('personal pages are explicit, deduplicate ids and retain status reasons while uploads are disabled', () async {
    final client = PersonalClient()
      ..value = WorkshopCapabilities.fromJson(workshopCaps(account: authAccount.toString(), uploads: false, companion: false));
    client.readPage = (cursor, status) async => cursor == null
      ? WorkshopSubmissionPage([personalRow(), personalRow(id: personalSecondId)], personalSecondId)
      : WorkshopSubmissionPage([personalRow(id: personalSecondId, status: WorkshopSubmissionStatus.rejected),
          personalRow(id: personalThirdId, status: WorkshopSubmissionStatus.approved)], null);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      expect(harness.container.read(workshopSubmissionsProvider).hasLoaded, isFalse);
      expect(client.pages, isEmpty);
      expect(await controller.refresh(), isTrue);
      expect(harness.container.read(workshopSubmissionsProvider).hasMore, isTrue);
      expect(await controller.loadMore(), isTrue);
      final state = harness.container.read(workshopSubmissionsProvider);
      expect(state.items.map((item) => item.id), [personalFirstId, personalSecondId, personalThirdId]);
      expect(state.items[1].reviewReason, 'review reason');
      expect(state.items.last.status, WorkshopSubmissionStatus.approved);
      expect(state.hasMore, isFalse);
      expect(await controller.loadMore(), isFalse);
      expect(client.pages, [(cursor: null, status: null, limit: 20),
        (cursor: personalSecondId, status: null, limit: 20)]);
      expect(() => state.items.clear(), throwsUnsupportedError);
    } finally { harness.dispose(); }
  });

  test('a failed next page retains its cursor and rows for an explicit retry', () async {
    final client = PersonalClient();
    client.readPage = (cursor, status) async {
      if (cursor == null) {
        return WorkshopSubmissionPage([personalRow()], personalFirstId);
      }
      throw const WorkshopException('workshop_network');
    };
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      await controller.refresh();
      await controller.loadMore();
      var state = harness.container.read(workshopSubmissionsProvider);
      expect(state.items.single.id, personalFirstId);
      expect(state.nextCursor, personalFirstId);
      expect(state.error!.code, 'workshop_network');
      expect(state.busy, isFalse);
      client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow(id: personalSecondId)], null);
      await controller.loadMore();
      state = harness.container.read(workshopSubmissionsProvider);
      expect(state.items, hasLength(2));
      expect(state.error, isNull);
      expect(client.pages.last.cursor, personalFirstId);
    } finally { harness.dispose(); }
  });

  test('filter refresh rejects mismatched pages and individual observations remove nonmatching rows', () async {
    final client = PersonalClient()
      ..readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow(status: status!)], null))
      ..readSubmission = (id) async => personalRow(id: id, status: WorkshopSubmissionStatus.rejected);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      await controller.selectStatus(WorkshopSubmissionStatus.pending);
      client.readPage = (cursor, status) async => WorkshopSubmissionPage([
        personalRow(), personalRow(id: personalSecondId, status: WorkshopSubmissionStatus.approved),
      ], null);
      await controller.refresh();
      expect(harness.container.read(workshopSubmissionsProvider).items.single.id, personalFirstId);
      expect(harness.container.read(workshopSubmissionsProvider).error!.code, 'workshop_bad_response');
      await controller.refreshSubmission(personalFirstId);
      var state = harness.container.read(workshopSubmissionsProvider);
      expect(state.items, isEmpty);
      expect(state.detail!.status, WorkshopSubmissionStatus.rejected);
      expect(state.detail!.reviewReason, 'review reason');
      expect(state.detailError, isNull);
      client.readPage = (cursor, status) async => throw const WorkshopException('workshop_network');
      await controller.selectStatus(WorkshopSubmissionStatus.rejected);
      state = harness.container.read(workshopSubmissionsProvider);
      expect(state.status, WorkshopSubmissionStatus.rejected);
      expect(state.hasLoaded, isFalse);
      expect(state.nextCursor, isNull);
      expect(state.error!.code, 'workshop_network');
      expect(client.pages.last, (cursor: null, status: WorkshopSubmissionStatus.rejected, limit: 20));
    } finally { harness.dispose(); }
  });

  test('one in-flight personal operation blocks overlapping page, detail and withdrawal calls and releases after failure', () async {
    final client = PersonalClient(), entered = Completer<void>();
    final release = Completer<WorkshopSubmissionPage>();
    client.readPage = (cursor, status) { entered.complete(); return release.future; };
    final harness = personalHarness(client);
    Future<bool>? pending;
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      pending = controller.refresh();
      final settled = authSettled(pending);
      await authSignal(entered, pending).timeout(const Duration(seconds: 10));
      expect(await controller.refresh(), isFalse);
      expect(await controller.loadMore(), isFalse);
      expect(await controller.refreshSubmission(personalFirstId), isFalse);
      expect(await controller.withdraw(personalFirstId, 'Take down'), isFalse);
      expect(client.pages, hasLength(1));
      expect(client.details, isEmpty);
      expect(client.withdrawals, isEmpty);
      release.completeError(const WorkshopException('workshop_network'));
      await pending;
      await settled;
      expect(harness.container.read(workshopSubmissionsProvider).busy, isFalse);
      expect(await controller.refreshSubmission(personalFirstId), isTrue);
      expect(client.details, [personalFirstId]);
    } finally {
      if (!release.isCompleted) {
        release.complete(const WorkshopSubmissionPage([], null));
      }
      if (pending != null) {
        await authSettled(pending);
      }
      harness.dispose();
    }
  });

  test('known profile ownership is checked atomically and a not-yet-loaded profile can still query', () async {
    final client = PersonalClient()
      ..readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow(), personalRow(id: personalSecondId, userId: 43)], null);
    final harness = personalHarness(client);
    final unknownProfile = personalHarness(client, initial: authSignedIn(userId: null));
    try {
      await authReady(harness.container);
      await harness.container.read(workshopSubmissionsProvider.notifier).refresh();
      expect(harness.container.read(workshopSubmissionsProvider).items, isEmpty);
      expect(harness.container.read(workshopSubmissionsProvider).error!.code, 'workshop_bad_response');
      await authReady(unknownProfile.container);
      await unknownProfile.container.read(workshopSubmissionsProvider.notifier).refresh();
      expect(unknownProfile.container.read(workshopSubmissionsProvider).items, hasLength(2));
      expect(unknownProfile.container.read(workshopSubmissionsProvider).error, isNull);
    } finally {
      unknownProfile.dispose();
      harness.dispose();
    }
  });

  test('a changed account ignores an old page without requiring the new state to be read first', () async {
    final client = PersonalClient(), entered = Completer<void>();
    final release = Completer<WorkshopSubmissionPage>();
    client.readPage = (cursor, status) { entered.complete(); return release.future; };
    final harness = personalHarness(client);
    Future<bool>? pending;
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      pending = controller.refresh();
      final settled = authSettled(pending);
      await authSignal(entered, pending).timeout(const Duration(seconds: 10));
      harness.account.emit(authSignedIn(credential:
        const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      release.complete(WorkshopSubmissionPage([personalRow()], null));
      await pending;
      await settled;
      final state = harness.container.read(workshopSubmissionsProvider);
      expect(state.items, isEmpty);
      expect(state.hasLoaded, isFalse);
      expect(state.busy, isFalse);
      await authReady(harness.container);
      client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow(userId: 43)], null);
      await controller.refresh();
      expect(harness.container.read(workshopSubmissionsProvider).items.single.ownerId, 43);
    } finally {
      if (!release.isCompleted) {
        release.complete(const WorkshopSubmissionPage([], null));
      }
      if (pending != null) {
        await authSettled(pending);
      }
      harness.dispose();
    }
  });

  test('an authorization waiting across sign-out never starts an author query', () async {
    final client = PersonalClient(), entered = Completer<void>();
    final release = Completer<WorkshopCapabilities>();
    final harness = personalHarness(client);
    Future<void>? refreshing;
    Future<bool>? pending;
    try {
      await authReady(harness.container);
      var reads = 0;
      client.readCapabilities = () {
        if (reads++ == 0) { entered.complete(); return release.future; }
        return Future.value(client.value);
      };
      refreshing = harness.controller.refresh();
      final refreshingSettled = authSettled(refreshing);
      await authSignal(entered, refreshing).timeout(const Duration(seconds: 10));
      pending = harness.container.read(workshopSubmissionsProvider.notifier).refresh();
      final settled = authSettled(pending);
      harness.account.emit(authSignedOut);
      release.complete(client.value);
      await pending;
      await refreshing;
      await settled;
      await refreshingSettled;
      expect(client.pages, isEmpty);
      expect(harness.container.read(workshopSubmissionsProvider).items, isEmpty);
    } finally {
      if (!release.isCompleted) {
        release.complete(client.value);
      }
      if (pending != null) {
        await authSettled(pending);
      }
      if (refreshing != null) {
        await authSettled(refreshing);
      }
      harness.dispose();
    }
  });

  test('withdrawal preserves its response reason and is available while uploads are disabled', () async {
    final client = PersonalClient()
      ..value = WorkshopCapabilities.fromJson(workshopCaps(account: authAccount.toString(), uploads: false, companion: false))
      ..readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      await controller.refresh();
      expect(await controller.withdraw(personalFirstId, 'Author requests removal'), isTrue);
      final state = harness.container.read(workshopSubmissionsProvider);
      expect(state.items.single.status, WorkshopSubmissionStatus.withdrawn);
      expect(state.detail!.withdrawalReason, 'author withdrew');
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.succeeded);
      expect(state.withdrawal.reconciled, isFalse);
      expect(client.withdrawals, [(id: personalFirstId, reason: 'Author requests removal')]);
      expect(client.pages, hasLength(1));
    } finally { harness.dispose(); }
  });

  test('an unknown withdrawal keeps the old row and a later explicit query can observe withdrawn', () async {
    final client = PersonalClient()
      ..readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow()], null))
      ..withdrawSubmission = ((id, reason) async => throw const WorkshopException('workshop_network', resultUnknown: true))
      ..readSubmission = (id) async => personalRow(id: id, status: WorkshopSubmissionStatus.withdrawn);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      await controller.refresh();
      await controller.withdraw(personalFirstId, 'Take down');
      var state = harness.container.read(workshopSubmissionsProvider);
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.unknown);
      expect(state.withdrawal.error!.resultUnknown, isTrue);
      expect(state.items.single.status, WorkshopSubmissionStatus.pending);
      expect(client.withdrawals, hasLength(1));
      expect(client.details, isEmpty);
      await controller.refreshSubmission(personalFirstId);
      state = harness.container.read(workshopSubmissionsProvider);
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.succeeded);
      expect(state.withdrawal.reconciled, isTrue);
      expect(state.items.single.status, WorkshopSubmissionStatus.withdrawn);
      expect(client.withdrawals, hasLength(1));
    } finally { harness.dispose(); }
  });

  test('withdrawal distinguishes known rejection, invalid reason and inconsistent success', () async {
    final client = PersonalClient()
      ..withdrawSubmission = (id, reason) async => throw const WorkshopException('workshop_account_origin', status: 409);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      await controller.withdraw(personalFirstId, 'Take down');
      var result = harness.container.read(workshopSubmissionsProvider).withdrawal;
      expect(result.phase, WorkshopWithdrawalPhase.failed);
      expect(result.error!.resultUnknown, isFalse);
      await controller.withdraw(personalFirstId, ' \u0085');
      result = harness.container.read(workshopSubmissionsProvider).withdrawal;
      expect(result.error!.code, 'workshop_bad_reason');
      expect(client.withdrawals, hasLength(1));
      client.withdrawSubmission = (id, reason) async => personalRow(id: id);
      await controller.withdraw(personalFirstId, 'Take down');
      final state = harness.container.read(workshopSubmissionsProvider);
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.unknown);
      expect(state.withdrawal.error!.code, 'workshop_bad_response');
      expect(state.withdrawal.error!.resultUnknown, isTrue);
      expect(state.detail, isNull);
      expect(client.withdrawals, hasLength(2));
    } finally { harness.dispose(); }
  });

  test('disposing an in-flight detail query settles the action without writing to a disposed provider', () async {
    final client = PersonalClient(), entered = Completer<void>();
    final release = Completer<WorkshopSubmission>();
    client.readSubmission = (id) { entered.complete(); return release.future; };
    final harness = personalHarness(client);
    Future<bool>? pending;
    var disposed = false;
    try {
      await authReady(harness.container);
      pending = harness.container.read(workshopSubmissionsProvider.notifier).refreshSubmission(personalFirstId);
      final settled = authSettled(pending);
      await authSignal(entered, pending).timeout(const Duration(seconds: 10));
      harness.dispose();
      disposed = true;
      release.completeError(const WorkshopException('workshop_network'));
      expect(await pending, isTrue);
      await settled;
      expect(client.details, [personalFirstId]);
    } finally {
      if (!release.isCompleted) {
        release.complete(personalRow());
      }
      if (pending != null) {
        await authSettled(pending);
      }
      if (!disposed) {
        harness.dispose();
      }
    }
  });

  test('a token the Worker refuses signs the account out, from a page read and from a report', () async {
    const refused = WorkshopException('workshop_account_auth_invalid', status: 401);
    final client = PersonalClient()
      ..readPage = ((cursor, status) async => throw refused)
      ..sendReport = ((kind, id, version, reason) async => throw refused);
    for (final act in [
      (AuthHarness h) => h.container.read(workshopSubmissionsProvider.notifier).refresh(),
      (AuthHarness h) => h.container.read(workshopReportProvider.notifier).submit(personalEntry(), 'Please review'),
    ]) {
      final harness = personalHarness(client);
      try {
        await authReady(harness.container);
        await act(harness);
        expect(harness.account.invalidated, 1);
        expect(harness.state.signedIn, isFalse);
      } finally { harness.dispose(); }
    }
  });
}
