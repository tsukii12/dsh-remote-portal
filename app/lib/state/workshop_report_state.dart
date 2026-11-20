import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import 'workshop_auth_state.dart';

enum WorkshopReportPhase { idle, sending, succeeded, failed, unknown }

/// Public, in-memory inputs only. A report has no requestId or author query.
class WorkshopReportAttempt {
  const WorkshopReportAttempt._({required this.kind, required this.id,
    required this.version, required this.reason});
  final String kind, id, version, reason;
}

class WorkshopReportState {
  const WorkshopReportState({required this.session, this.phase = WorkshopReportPhase.idle,
    this.attempt, this.reportId, this.error});
  final Object session;
  final WorkshopReportPhase phase;
  final WorkshopReportAttempt? attempt;
  final String? reportId;
  final WorkshopException? error;
  bool get busy => phase == WorkshopReportPhase.sending;
}

final workshopReportProvider = NotifierProvider<WorkshopReportController, WorkshopReportState>(
  WorkshopReportController.new,
);

class WorkshopReportController extends Notifier<WorkshopReportState> {
  @override
  WorkshopReportState build() => WorkshopReportState(
    session: ref.watch(workshopAccessProvider.select((value) => value.session)),
  );

  bool _current(Object session) {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    return ref.mounted && identical(current.session, session);
  }

  /// Success and unknown results stay visible until an explicit new operation.
  /// For an unknown result the UI must explain that another send can duplicate
  /// the report, then return this exact attempt as the confirmation token.
  bool beginNewOperation({WorkshopReportAttempt? confirmedUnknown}) {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.busy || current.phase == WorkshopReportPhase.unknown &&
        !identical(confirmedUnknown, current.attempt)) {
      return false;
    }
    state = WorkshopReportState(session: current.session);
    return true;
  }

  /// True means one attempt was admitted, not that it succeeded. No automatic
  /// retry occurs; inspect phase/reportId/error after awaiting this Future.
  Future<bool> submit(WorkshopEntry entry, String reason) async {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.busy || current.phase == WorkshopReportPhase.unknown ||
        current.phase == WorkshopReportPhase.succeeded) {
      return false;
    }
    final session = current.session, metadata = entry.metadata;
    final attempt = WorkshopReportAttempt._(kind: metadata.kind, id: metadata.id,
      version: metadata.version, reason: reason);
    state = WorkshopReportState(session: session, phase: WorkshopReportPhase.sending, attempt: attempt);
    try {
      if (!metadata.supported) {
        workshopInvalid('workshop_unsupported_kind');
      }
      if (!workshopText(reason, 2000)) {
        workshopInvalid('workshop_bad_reason');
      }
      final authorization = await ref.read(workshopAccessProvider.notifier).authorize();
      if (!_current(session) || !identical(authorization.session, session)) {
        workshopInvalid('workshop_cancelled');
      }
      final id = await authorization.client.report(kind: attempt.kind, id: attempt.id,
        version: attempt.version, reason: attempt.reason, credential: authorization.credential);
      if (_current(session)) {
        state = WorkshopReportState(session: session, phase: WorkshopReportPhase.succeeded,
          attempt: attempt, reportId: id);
      }
    } on Object catch (error) {
      if (_current(session)) {
        // The Client distinguishes its read-only preflight from the report POST.
        final failure = workshopTransportError(error);
        state = WorkshopReportState(session: session,
          phase: failure.resultUnknown ? WorkshopReportPhase.unknown : WorkshopReportPhase.failed,
          attempt: attempt, error: failure);
        workshopForgetRefusedAccount(ref, failure);
      }
    }
    return true;
  }
}
