import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';

import '../workshop/support.dart' show workshopEntryJson, workshopSubmissionJson;
import 'workshop_auth_test_support.dart';

const personalFirstId = '00000000000000000000000000000001';
const personalSecondId = '00000000000000000000000000000002';
const personalThirdId = '00000000000000000000000000000003';

WorkshopSubmission personalRow({String id = personalFirstId,
  WorkshopSubmissionStatus status = WorkshopSubmissionStatus.pending, int userId = 42,
  String? account}) => WorkshopSubmission.fromJson({
    ...workshopSubmissionJson(id: id, status: status.name),
    'owner': {'accountOrigin': account ?? authAccount.toString(), 'accountId': userId, 'username': 'test-user'},
  });

WorkshopEntry personalEntry() => WorkshopEntry.fromJson(workshopEntryJson());

/// These overrides return domain values and never open HTTP or local storage.
/// Captured call records contain only public inputs, not credentials.
class PersonalClient extends AuthClient {
  PersonalClient({super.worker, super.account});
  Future<WorkshopSubmissionPage> Function(String? cursor, WorkshopSubmissionStatus? status)? readPage;
  Future<WorkshopSubmission> Function(String id)? readSubmission;
  Future<WorkshopSubmission> Function(String id, String reason)? withdrawSubmission;
  Future<String> Function(String kind, String id, String version, String reason)? sendReport;
  final pages = <({String? cursor, WorkshopSubmissionStatus? status, int limit})>[];
  final details = <String>[];
  final withdrawals = <({String id, String reason})>[];
  final reports = <({String kind, String id, String version, String reason})>[];

  @override
  Future<WorkshopSubmissionPage> submissions({required WorkshopCredential credential, int limit = 20,
    String? cursor, WorkshopSubmissionStatus? status}) async {
    pages.add((cursor: cursor, status: status, limit: limit));
    return readPage == null ? const WorkshopSubmissionPage([], null) : await readPage!(cursor, status);
  }

  @override
  Future<WorkshopSubmission> submission(String id, {required WorkshopCredential credential}) async {
    details.add(id);
    return readSubmission == null ? personalRow(id: id) : await readSubmission!(id);
  }

  @override
  Future<WorkshopSubmission> withdraw(String id, String reason, {required WorkshopCredential credential}) async {
    withdrawals.add((id: id, reason: reason));
    return withdrawSubmission == null ? personalRow(id: id, status: WorkshopSubmissionStatus.withdrawn)
      : await withdrawSubmission!(id, reason);
  }

  @override
  Future<String> report({required String kind, required String id, required String version,
    required String reason, required WorkshopCredential credential}) async {
    reports.add((kind: kind, id: id, version: version, reason: reason));
    return sendReport == null ? personalThirdId : await sendReport!(kind, id, version, reason);
  }
}

AuthHarness personalHarness(PersonalClient client, {WorkshopAccountState? initial, bool consent = true}) {
  final preferences = AuthPreferences();
  if (consent) {
    preferences.accepted.add(preferences.pair(client.origin, authAccount));
  }
  return AuthHarness(client: client, preferences: preferences, initial: initial);
}
