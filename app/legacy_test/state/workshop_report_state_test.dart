import 'dart:async';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_report_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show workshopCaps;
import 'workshop_auth_test_support.dart';
import 'workshop_personal_test_support.dart';

void main() {
  test('report sends one explicit attempt, retains the id and works while uploads are disabled', () async {
    final client = PersonalClient()
      ..value = WorkshopCapabilities.fromJson(workshopCaps(account: authAccount.toString(), uploads: false, companion: false));
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopReportProvider.notifier);
      expect(client.reports, isEmpty);
      expect(await controller.submit(personalEntry(), 'Attribution needs review'), isTrue);
      final state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.succeeded);
      expect(state.reportId, personalThirdId);
      expect(state.attempt!.kind, 'pet');
      expect(state.attempt!.id, 'cat');
      expect(state.attempt!.version, '1.0.0');
      expect(state.attempt!.reason, 'Attribution needs review');
      expect(await controller.submit(personalEntry(), 'Same report'), isFalse);
      expect(client.reports, hasLength(1));
      expect(controller.beginNewOperation(), isTrue);
      expect(harness.container.read(workshopReportProvider).phase, WorkshopReportPhase.idle);
    } finally { harness.dispose(); }
  });

  test('unknown reports cannot be blindly repeated and only the exact attempt confirms a new operation', () async {
    final client = PersonalClient()
      ..sendReport = (kind, id, version, reason) async => throw const WorkshopException('workshop_network', resultUnknown: true);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopReportProvider.notifier);
      await controller.submit(personalEntry(), 'Please review');
      final unknown = harness.container.read(workshopReportProvider);
      expect(unknown.phase, WorkshopReportPhase.unknown);
      expect(unknown.error!.resultUnknown, isTrue);
      expect(unknown.reportId, isNull);
      expect(await controller.submit(personalEntry(), 'Please review'), isFalse);
      expect(controller.beginNewOperation(), isFalse);
      expect(client.reports, hasLength(1));
      expect(controller.beginNewOperation(confirmedUnknown: unknown.attempt), isTrue);
      client.sendReport = null;
      expect(await controller.submit(personalEntry(), 'New operation, possible duplicate acknowledged'), isTrue);
      expect(client.reports, hasLength(2));
      expect(harness.container.read(workshopReportProvider).phase, WorkshopReportPhase.succeeded);
    } finally { harness.dispose(); }
  });

  test('known rejection and local reason validation do not invent an unknown report', () async {
    final client = PersonalClient()
      ..sendReport = (kind, id, version, reason) async => throw const WorkshopException('workshop_account_origin', status: 409);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopReportProvider.notifier);
      await controller.submit(personalEntry(), 'Please review');
      var state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.failed);
      expect(state.error!.code, 'workshop_account_origin');
      expect(state.error!.resultUnknown, isFalse);
      await controller.submit(personalEntry(), ' \u0085');
      state = harness.container.read(workshopReportProvider);
      expect(state.error!.code, 'workshop_bad_reason');
      expect(state.error!.resultUnknown, isFalse);
      expect(client.reports, hasLength(1));
    } finally { harness.dispose(); }
  });

  test('missing disclosure prevents any report call', () async {
    final client = PersonalClient();
    final harness = personalHarness(client, consent: false);
    try {
      await authReady(harness.container);
      await harness.container.read(workshopReportProvider.notifier).submit(personalEntry(), 'Please review');
      final state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.failed);
      expect(state.error!.code, 'workshop_consent_required');
      expect(state.error!.resultUnknown, isFalse);
      expect(client.reports, isEmpty);
    } finally { harness.dispose(); }
  });

  test('an in-flight report rejects a duplicate click and ignores completion after a lazy account switch', () async {
    final client = PersonalClient(), entered = Completer<void>();
    final release = Completer<String>();
    client.sendReport = (kind, id, version, reason) { entered.complete(); return release.future; };
    final harness = personalHarness(client);
    Future<bool>? pending;
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopReportProvider.notifier);
      pending = controller.submit(personalEntry(), 'Please review');
      final settled = authSettled(pending);
      await authSignal(entered, pending).timeout(const Duration(seconds: 10));
      expect(await controller.submit(personalEntry(), 'Second click'), isFalse);
      expect(controller.beginNewOperation(), isFalse);
      harness.account.emit(authSignedIn(credential:
        const WorkshopAccountCredential('TEST_ONLY_KEY_B'), userId: 43));
      release.complete(personalThirdId);
      await pending;
      await settled;
      final state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.idle);
      expect(state.attempt, isNull);
      expect(state.reportId, isNull);
      expect(client.reports, hasLength(1));
    } finally {
      if (!release.isCompleted) {
        release.complete(personalThirdId);
      }
      if (pending != null) {
        await authSettled(pending);
      }
      harness.dispose();
    }
  });

  test('authorization cannot start a report after its captured account has signed out', () async {
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
      pending = harness.container.read(workshopReportProvider.notifier).submit(personalEntry(), 'Please review');
      final settled = authSettled(pending);
      harness.account.emit(authSignedOut);
      release.complete(client.value);
      await pending;
      await refreshing;
      await settled;
      await refreshingSettled;
      expect(client.reports, isEmpty);
      expect(harness.container.read(workshopReportProvider).phase, WorkshopReportPhase.idle);
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

  test('an old unknown-result confirmation cannot clear a different attempt after account replacement', () async {
    final client = PersonalClient()
      ..sendReport = (kind, id, version, reason) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
    final harness = personalHarness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopReportProvider.notifier);
      await controller.submit(personalEntry(), 'First operation');
      final old = harness.container.read(workshopReportProvider).attempt;
      harness.account.emit(authSignedIn(credential:
        const WorkshopAccountCredential('TEST_ONLY_KEY_B')));
      await authReady(harness.container);
      await controller.submit(personalEntry(), 'Second operation');
      final current = harness.container.read(workshopReportProvider);
      expect(current.phase, WorkshopReportPhase.unknown);
      expect(current.attempt, isNot(same(old)));
      expect(controller.beginNewOperation(confirmedUnknown: old), isFalse);
      expect(harness.container.read(workshopReportProvider).attempt, same(current.attempt));
      expect(client.reports, hasLength(2));
    } finally { harness.dispose(); }
  });
}
