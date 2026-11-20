import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import 'workshop_auth_state.dart';

enum WorkshopSubmissionsOperation { idle, refresh, more, detail, withdraw }
enum WorkshopWithdrawalPhase { idle, sending, succeeded, failed, unknown }

class WorkshopWithdrawalState {
  const WorkshopWithdrawalState({this.phase = WorkshopWithdrawalPhase.idle,
    this.submissionId, this.submission, this.error, this.reconciled = false});
  final WorkshopWithdrawalPhase phase;
  final String? submissionId;
  final WorkshopSubmission? submission;
  final WorkshopException? error;
  /// A later query observed withdrawn; it does not identify which request won.
  final bool reconciled;
}

const _unchanged = Object();

class WorkshopSubmissionsState {
  WorkshopSubmissionsState({required this.session, List<WorkshopSubmission> items = const [],
    this.status, this.nextCursor, this.hasLoaded = false,
    this.operation = WorkshopSubmissionsOperation.idle, this.operationSubmissionId,
    this.error, this.detailId, this.detail, this.detailError,
    this.withdrawal = const WorkshopWithdrawalState()}) : items = List.unmodifiable(items);

  final Object session;
  final List<WorkshopSubmission> items;
  final WorkshopSubmissionStatus? status;
  final String? nextCursor;
  final bool hasLoaded;
  final WorkshopSubmissionsOperation operation;
  final String? operationSubmissionId;
  final WorkshopException? error, detailError;
  final String? detailId;
  final WorkshopSubmission? detail;
  final WorkshopWithdrawalState withdrawal;

  bool get busy => operation != WorkshopSubmissionsOperation.idle;
  bool get hasMore => hasLoaded && nextCursor != null;

  WorkshopSubmissionsState copyWith({List<WorkshopSubmission>? items,
    Object? status = _unchanged, Object? nextCursor = _unchanged, bool? hasLoaded,
    WorkshopSubmissionsOperation? operation, Object? operationSubmissionId = _unchanged,
    Object? error = _unchanged, Object? detailId = _unchanged,
    Object? detail = _unchanged, Object? detailError = _unchanged,
    WorkshopWithdrawalState? withdrawal}) => WorkshopSubmissionsState(
      session: session, items: items ?? this.items,
      status: identical(status, _unchanged) ? this.status : status as WorkshopSubmissionStatus?,
      nextCursor: identical(nextCursor, _unchanged) ? this.nextCursor : nextCursor as String?,
      hasLoaded: hasLoaded ?? this.hasLoaded, operation: operation ?? this.operation,
      operationSubmissionId: identical(operationSubmissionId, _unchanged)
        ? this.operationSubmissionId : operationSubmissionId as String?,
      error: identical(error, _unchanged) ? this.error : error as WorkshopException?,
      detailId: identical(detailId, _unchanged) ? this.detailId : detailId as String?,
      detail: identical(detail, _unchanged) ? this.detail : detail as WorkshopSubmission?,
      detailError: identical(detailError, _unchanged) ? this.detailError : detailError as WorkshopException?,
      withdrawal: withdrawal ?? this.withdrawal,
    );
}

final workshopSubmissionsProvider = NotifierProvider<WorkshopSubmissionsController, WorkshopSubmissionsState>(
  WorkshopSubmissionsController.new,
);

/// Author queries are explicit. One operation at a time avoids a late page
/// replacing a just-observed withdrawal; pages still are not a server snapshot.
class WorkshopSubmissionsController extends Notifier<WorkshopSubmissionsState> {
  @override
  WorkshopSubmissionsState build() => WorkshopSubmissionsState(
    session: ref.watch(workshopAccessProvider.select((value) => value.session)),
  );

  bool _current(Object session) {
    if (!ref.mounted) {
      return false;
    }
    // Reading state flushes a lazy account/deployment rebuild before comparing.
    final current = state;
    return ref.mounted && identical(current.session, session);
  }

  Future<WorkshopAuthorization> _authorize(Object session) async {
    final authorization = await ref.read(workshopAccessProvider.notifier).authorize();
    if (!_current(session) || !identical(authorization.session, session)) {
      workshopInvalid('workshop_cancelled');
    }
    return authorization;
  }

  void _owner(WorkshopSubmission item, WorkshopAuthorization authorization) {
    if (item.ownerOrigin != authorization.credential.account ||
        authorization.accountId != null && item.ownerId != authorization.accountId) {
      workshopInvalid();
    }
  }

  /// All action booleans mean admitted, not successful. Inspect state after
  /// awaiting; false means busy, disposed, or no next page, with no new request.
  Future<bool> refresh() {
    if (!ref.mounted) {
      return Future.value(false);
    }
    final current = state;
    return _firstPage(current.status);
  }

  Future<bool> selectStatus(WorkshopSubmissionStatus? status) => _firstPage(status);

  Future<bool> _firstPage(WorkshopSubmissionStatus? status) async {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.busy) {
      return false;
    }
    final session = current.session;
    final changingFilter = status != current.status;
    state = current.copyWith(status: status, operation: WorkshopSubmissionsOperation.refresh,
      operationSubmissionId: null, error: null,
      items: changingFilter ? const [] : current.items,
      nextCursor: changingFilter ? null : current.nextCursor,
      hasLoaded: changingFilter ? false : current.hasLoaded);
    await _page(session, status: status, append: false);
    return true;
  }

  Future<bool> loadMore() async {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.busy || !current.hasMore) {
      return false;
    }
    final session = current.session;
    state = current.copyWith(operation: WorkshopSubmissionsOperation.more,
      operationSubmissionId: null, error: null);
    await _page(session, status: current.status, cursor: current.nextCursor, append: true);
    return true;
  }

  Future<void> _page(Object session, {required WorkshopSubmissionStatus? status,
    String? cursor, required bool append}) async {
    try {
      final authorization = await _authorize(session);
      if (!_current(session) || !identical(authorization.session, session)) {
        return;
      }
      final page = await authorization.client.submissions(credential: authorization.credential,
        status: status, cursor: cursor);
      if (!_current(session)) {
        return;
      }
      for (final item in page.submissions) {
        _owner(item, authorization);
        if (status != null && item.status != status) {
          workshopInvalid();
        }
      }
      final rows = <String, WorkshopSubmission>{
        if (append) for (final item in state.items) item.id: item,
        for (final item in page.submissions) item.id: item,
      };
      final detailId = state.detailId;
      state = state.copyWith(items: rows.values.toList(), nextCursor: page.nextCursor,
        hasLoaded: true, error: null,
        detail: detailId != null && rows.containsKey(detailId) ? rows[detailId] : state.detail,
        detailError: detailId != null && rows.containsKey(detailId) ? null : state.detailError);
    } on Object catch (error) {
      if (_current(session)) {
        final failure = workshopTransportError(error);
        state = state.copyWith(error: failure);
        workshopForgetRefusedAccount(ref, failure);
      }
    } finally {
      if (_current(session)) {
        state = state.copyWith(operation: WorkshopSubmissionsOperation.idle, operationSubmissionId: null);
      }
    }
  }

  Future<bool> refreshSubmission(String id) async {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.busy) {
      return false;
    }
    final session = current.session;
    state = current.copyWith(operation: WorkshopSubmissionsOperation.detail,
      operationSubmissionId: id, detailId: id,
      detail: current.detailId == id ? current.detail : null, detailError: null);
    try {
      final authorization = await _authorize(session);
      if (!_current(session) || !identical(authorization.session, session)) {
        return true;
      }
      final item = await authorization.client.submission(id, credential: authorization.credential);
      if (!_current(session)) {
        return true;
      }
      if (item.id != id) {
        workshopInvalid();
      }
      _owner(item, authorization);
      _observed(item);
      if (state.withdrawal.phase == WorkshopWithdrawalPhase.unknown &&
          state.withdrawal.submissionId == item.id && item.status == WorkshopSubmissionStatus.withdrawn) {
        state = state.copyWith(withdrawal: WorkshopWithdrawalState(
          phase: WorkshopWithdrawalPhase.succeeded, submissionId: item.id, submission: item, reconciled: true));
      }
    } on Object catch (error) {
      if (_current(session)) {
        final failure = workshopTransportError(error);
        state = state.copyWith(detailError: failure);
        workshopForgetRefusedAccount(ref, failure);
      }
    } finally {
      if (_current(session)) {
        state = state.copyWith(operation: WorkshopSubmissionsOperation.idle, operationSubmissionId: null);
      }
    }
    return true;
  }

  void _observed(WorkshopSubmission item) {
    // A detail query does not insert an out-of-page row. An observed status
    // change removes an existing row that no longer matches the chosen filter.
    state = state.copyWith(items: [for (final old in state.items)
      if (old.id != item.id) old
      else if (state.status == null || state.status == item.status) item],
      detailId: item.id, detail: item, detailError: null);
  }

  Future<bool> withdraw(String id, String reason) async {
    if (!ref.mounted) {
      return false;
    }
    final current = state;
    if (current.busy) {
      return false;
    }
    final session = current.session;
    var receivedResponse = false;
    state = current.copyWith(operation: WorkshopSubmissionsOperation.withdraw,
      operationSubmissionId: id, withdrawal: WorkshopWithdrawalState(
        phase: WorkshopWithdrawalPhase.sending, submissionId: id));
    try {
      if (!workshopText(reason, 2000)) {
        workshopInvalid('workshop_bad_reason');
      }
      final authorization = await _authorize(session);
      if (!_current(session) || !identical(authorization.session, session)) {
        return true;
      }
      final item = await authorization.client.withdraw(id, reason, credential: authorization.credential);
      receivedResponse = true;
      if (!_current(session)) {
        return true;
      }
      if (item.id != id || item.status != WorkshopSubmissionStatus.withdrawn) {
        workshopInvalid();
      }
      _owner(item, authorization);
      _observed(item);
      state = state.copyWith(withdrawal: WorkshopWithdrawalState(
        phase: WorkshopWithdrawalPhase.succeeded, submissionId: id, submission: item));
    } on Object catch (error) {
      if (_current(session)) {
        // Client failures carry their own uncertainty. A returned result can
        // still fail the id/status/account checks above after a successful POST.
        final failure = workshopTransportError(error, mutation: receivedResponse);
        state = state.copyWith(withdrawal: WorkshopWithdrawalState(
          phase: failure.resultUnknown ? WorkshopWithdrawalPhase.unknown : WorkshopWithdrawalPhase.failed,
          submissionId: id, error: failure));
        workshopForgetRefusedAccount(ref, failure);
      }
    } finally {
      if (_current(session)) {
        state = state.copyWith(operation: WorkshopSubmissionsOperation.idle, operationSubmissionId: null);
      }
    }
    return true;
  }
}
