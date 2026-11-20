import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/workshop_report_state.dart';
import 'package:dsh_app/state/workshop_submissions_state.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart';
import 'workshop_auth_test_support.dart';
import 'workshop_personal_test_support.dart' show personalEntry, personalFirstId, personalSecondId, personalThirdId;

UpdateHttpResponse _malformedJson() => UpdateHttpResponse(
  status: 200, contentLength: 1, headers: const {}, body: Stream.value([123]));

WorkshopClient _client(FakeWorkshopHttp http) => WorkshopClient(
  origin: authWorker, cacheFile: File('unused-mutation-preflight-cache.json'), http: http);

WorkshopCredential _credential() => WorkshopCredential.forConsentedWorker(
  worker: authWorker, account: authAccount, token: 'TEST_ONLY_PREFLIGHT_KEY', disclosureAccepted: true);

AuthHarness _harness(WorkshopClient client) {
  final preferences = AuthPreferences();
  preferences.accepted.add(preferences.pair(authWorker, authAccount));
  return AuthHarness(preferences: preferences, loadClient: (_) async => client);
}

TypeMatcher<WorkshopException> _failure(String code, {required bool unknown, required bool notSent}) =>
  isA<WorkshopException>().having((error) => error.code, 'code', code)
    .having((error) => error.resultUnknown, 'resultUnknown', unknown)
    .having((error) => error.mutationNotSent, 'mutationNotSent', notSent);

void main() {
  test('create local rights rejection proves no mutation was sent without doing any HTTP', () async {
    final http = FakeWorkshopHttp((method, url, headers, body) => throw StateError('Unexpected HTTP'));
    final client = _client(http);
    try {
      await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()),
        requestId: 'mutation-preflight-01', rightsConfirmed: false, credential: _credential()),
        throwsA(_failure('workshop_rights_required', unknown: false, notSent: true)));
      expect(http.requests, isEmpty);
    } finally { client.close(); }
  });

  for (final scenario in [
    (kind: 'pet', code: 'workshop_upload_disabled', caps: workshopCaps(uploads: false)),
    (kind: 'companion', code: 'workshop_companion_disabled', caps: workshopCaps(companion: false)),
  ]) {
    final kind = scenario.kind;
    test('create $kind capability rejection proves the POST was not attempted', () async {
      final http = FakeWorkshopHttp((method, url, headers, body) => workshopJsonResponse(scenario.caps));
      final client = _client(http);
      try {
        await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta(kind: kind)),
          requestId: 'mutation-preflight-01', rightsConfirmed: true, credential: _credential()),
          throwsA(_failure(scenario.code, unknown: false, notSent: true)));
        expect(http.requests.map((request) => (request.method, request.url.path)),
          [('GET', '/api/workshop/v1/capabilities')]);
      } finally { client.close(); }
    });
  }

  test('create malformed capabilities JSON is a known preflight failure with zero POSTs', () async {
    final http = FakeWorkshopHttp((method, url, headers, body) => _malformedJson());
    final client = _client(http);
    try {
      await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()),
        requestId: 'mutation-preflight-01', rightsConfirmed: true, credential: _credential()),
        throwsA(_failure('workshop_bad_response', unknown: false, notSent: true)));
      expect(http.requests.map((request) => request.method), ['GET']);
    } finally { client.close(); }
  });

  test('create preserves preflight HTTP status and retry information', () async {
    final http = FakeWorkshopHttp((method, url, headers, body) =>
      workshopJsonResponse({}, status: 429, headers: {'retry-after': '7'}));
    final client = _client(http);
    try {
      await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()),
        requestId: 'mutation-preflight-01', rightsConfirmed: true, credential: _credential()),
        throwsA(_failure('workshop_http', unknown: false, notSent: true)
          .having((error) => error.status, 'status', 429)
          .having((error) => error.retryAfter, 'retryAfter', const Duration(seconds: 7))));
      expect(http.requests.map((request) => request.method), ['GET']);
    } finally { client.close(); }
  });

  for (final scenario in <({String name, String code, bool unknown, UpdateHttpResponse Function() respond})>[
    (name: 'known rejection', code: 'workshop_account_origin', unknown: false,
      respond: () => workshopJsonResponse({'error': 'workshop_account_origin'}, status: 409)),
    (name: 'malformed success', code: 'workshop_bad_response', unknown: true, respond: _malformedJson),
    (name: 'timeout', code: 'workshop_timeout', unknown: true,
      respond: () => throw TimeoutException('Synthetic POST timeout')),
  ]) {
    final name = scenario.name;
    test('create POST $name never claims that no mutation was sent', () async {
      final http = FakeWorkshopHttp((method, url, headers, body) =>
        method == 'GET' ? workshopJsonResponse(workshopCaps()) : scenario.respond());
      final client = _client(http);
      try {
        await expectLater(client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()),
          requestId: 'mutation-preflight-01', rightsConfirmed: true, credential: _credential()),
          throwsA(_failure(scenario.code, unknown: scenario.unknown, notSent: false)));
        expect(http.requests.map((request) => (request.method, request.url.path)), [
          ('GET', '/api/workshop/v1/capabilities'), ('POST', '/api/workshop/v1/submissions'),
        ]);
      } finally { client.close(); }
    });
  }

  test('report capabilities parse failure permits a normal retry without duplicate confirmation', () async {
    var malformedCapabilities = false;
    final http = FakeWorkshopHttp((method, url, headers, body) {
      if (method == 'GET') {
        return malformedCapabilities ? _malformedJson() : workshopJsonResponse(workshopCaps());
      }
      expect(url.path, '/api/workshop/v1/reports');
      return workshopJsonResponse({'reportId': personalThirdId});
    });
    final client = _client(http), harness = _harness(client);
    try {
      await authReady(harness.container);
      malformedCapabilities = true;
      final controller = harness.container.read(workshopReportProvider.notifier);
      expect(await controller.submit(personalEntry(), '请复核素材授权'), isTrue);
      var state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.failed);
      expect(state.error!.code, 'workshop_bad_response');
      expect(state.error!.resultUnknown, isFalse);
      expect(http.requests.where((request) => request.method == 'POST'), isEmpty);

      malformedCapabilities = false;
      expect(await controller.submit(personalEntry(), '请复核素材授权'), isTrue);
      state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.succeeded);
      expect(state.reportId, personalThirdId);
      expect(http.requests.where((request) => request.method == 'POST'), hasLength(1));
    } finally { harness.dispose(); client.close(); }
  });

  test('withdrawal capabilities parse failure is known and an explicit retry can succeed', () async {
    var malformedCapabilities = false;
    final http = FakeWorkshopHttp((method, url, headers, body) {
      if (method == 'GET') {
        return malformedCapabilities ? _malformedJson() : workshopJsonResponse(workshopCaps());
      }
      expect(url.path, '/api/workshop/v1/submissions/$personalFirstId/withdraw');
      return workshopJsonResponse({'submission': workshopSubmissionJson(id: personalFirstId, status: 'withdrawn')});
    });
    final client = _client(http), harness = _harness(client);
    try {
      await authReady(harness.container);
      malformedCapabilities = true;
      final controller = harness.container.read(workshopSubmissionsProvider.notifier);
      expect(await controller.withdraw(personalFirstId, '作者申请撤回'), isTrue);
      var state = harness.container.read(workshopSubmissionsProvider);
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.failed);
      expect(state.withdrawal.error!.code, 'workshop_bad_response');
      expect(state.withdrawal.error!.resultUnknown, isFalse);
      expect(state.busy, isFalse);
      expect(http.requests.where((request) => request.method == 'POST'), isEmpty);

      malformedCapabilities = false;
      expect(await controller.withdraw(personalFirstId, '作者申请撤回'), isTrue);
      state = harness.container.read(workshopSubmissionsProvider);
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.succeeded);
      expect(state.withdrawal.reconciled, isFalse);
      expect(state.detail!.id, personalFirstId);
      expect(state.detail!.status, WorkshopSubmissionStatus.withdrawn);
      expect(http.requests.where((request) => request.method == 'POST'), hasLength(1));
    } finally { harness.dispose(); client.close(); }
  });

  test('malformed report POST success remains unknown and cannot be repeated blindly', () async {
    final http = FakeWorkshopHttp((method, url, headers, body) =>
      method == 'GET' ? workshopJsonResponse(workshopCaps()) : _malformedJson());
    final client = _client(http), harness = _harness(client);
    try {
      await authReady(harness.container);
      final controller = harness.container.read(workshopReportProvider.notifier);
      expect(await controller.submit(personalEntry(), '请复核素材授权'), isTrue);
      final state = harness.container.read(workshopReportProvider);
      expect(state.phase, WorkshopReportPhase.unknown);
      expect(state.error!.code, 'workshop_bad_response');
      expect(state.error!.resultUnknown, isTrue);
      expect(state.reportId, isNull);
      expect(await controller.submit(personalEntry(), '请复核素材授权'), isFalse);
      expect(controller.beginNewOperation(), isFalse);
      expect(http.requests.where((request) => request.method == 'POST'), hasLength(1));
    } finally { harness.dispose(); client.close(); }
  });

  test('malformed withdrawal POST success remains unknown', () async {
    final http = FakeWorkshopHttp((method, url, headers, body) =>
      method == 'GET' ? workshopJsonResponse(workshopCaps()) : _malformedJson());
    final client = _client(http), harness = _harness(client);
    try {
      await authReady(harness.container);
      expect(await harness.container.read(workshopSubmissionsProvider.notifier)
        .withdraw(personalFirstId, '作者申请撤回'), isTrue);
      final state = harness.container.read(workshopSubmissionsProvider);
      expect(state.withdrawal.phase, WorkshopWithdrawalPhase.unknown);
      expect(state.withdrawal.error!.resultUnknown, isTrue);
      expect(state.detail, isNull);
      expect(state.busy, isFalse);
      expect(http.requests.where((request) => request.method == 'POST'), hasLength(1));
    } finally { harness.dispose(); client.close(); }
  });

  for (final inconsistency in ['id', 'status', 'account']) {
    test('withdrawal returned $inconsistency mismatch remains unknown after POST', () async {
      final submission = workshopSubmissionJson(
        id: inconsistency == 'id' ? personalSecondId : personalFirstId,
        status: inconsistency == 'status' ? 'pending' : 'withdrawn');
      if (inconsistency == 'account') {
        submission['owner'] = {'accountOrigin': authAccount.toString(), 'accountId': 43, 'username': 'other-author'};
      }
      final http = FakeWorkshopHttp((method, url, headers, body) =>
        method == 'GET' ? workshopJsonResponse(workshopCaps()) : workshopJsonResponse({'submission': submission}));
      final client = _client(http), harness = _harness(client);
      try {
        await authReady(harness.container);
        await harness.container.read(workshopSubmissionsProvider.notifier).withdraw(personalFirstId, '作者申请撤回');
        final state = harness.container.read(workshopSubmissionsProvider);
        expect(state.withdrawal.phase, WorkshopWithdrawalPhase.unknown);
        expect(state.withdrawal.error!.code, 'workshop_bad_response');
        expect(state.withdrawal.error!.resultUnknown, isTrue);
        expect(state.detail, isNull);
        expect(state.items, isEmpty);
        expect(state.busy, isFalse);
        expect(http.requests.where((request) => request.method == 'POST'), hasLength(1));
      } finally { harness.dispose(); client.close(); }
    });
  }
}
