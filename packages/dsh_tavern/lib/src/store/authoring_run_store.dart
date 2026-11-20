part of 'chat_store.dart';

extension AuthoringRunStore on ChatStore {
  /// Called once by the new engine owner. Old requests are evidence only;
  /// neither HTTP nor an unconfirmed tool call is resumed on reopening.
  void interruptAuthoringRuns() => transaction(() {
    final at = _clock().millisecondsSinceEpoch;
    _db.execute(
      "UPDATE authoring_requests SET status = 'interrupted', updated_at = ? "
      "WHERE status IN ('registered', 'running')",
      [at],
    );
    _db.execute("UPDATE authoring_runs SET status = 'interrupted', updated_at = ? WHERE status = 'running'", [at]);
  });

  TavernAuthoringRunSnapshot? readAuthoringRunData(String runId) {
    _ensureOpen();
    final rows = _db.select('SELECT *, char(1) || run_id AS guarded_run_id FROM authoring_runs WHERE run_id = ?', [
      runId,
    ]);
    return rows.isEmpty ? null : _authoringRunRow(rows.single);
  }

  List<TavernAuthoringRunSummary> listAuthoringRunData({String? draftId, required int limit, String? beforeRunId}) {
    _ensureOpen();
    final where = <String>[];
    final args = <Object?>[];
    if (draftId != null) {
      where.add('draft_id = ?');
      args.add(draftId);
    }
    if (beforeRunId != null) {
      final before = _db.select('SELECT created_at FROM authoring_runs WHERE run_id = ?', [beforeRunId]);
      if (before.isEmpty) {
        throw const TavernAuthoringException('not_found', 'The authoring pagination anchor does not exist.');
      }
      where.add('(created_at < ? OR (created_at = ? AND run_id < ?))');
      args.addAll([before.single['created_at'], before.single['created_at'], beforeRunId]);
    }
    args.add(limit);
    return [
      for (final row in _db.select(
        'SELECT char(1) || run_id AS run_id, draft_id, start_revision, '
        'current_revision, status, created_at, updated_at FROM authoring_runs '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} '}ORDER BY created_at DESC, run_id DESC LIMIT ?',
        args,
      ))
        TavernAuthoringRunSummary(
          runId: ChatStore._unguardText(row['run_id'])!,
          draftId: row['draft_id'] as String,
          startRevision: row['start_revision'] as int,
          currentRevision: row['current_revision'] as int,
          status: TavernAuthoringRunStatus.values.byName(row['status'] as String),
          createdAt: ChatStore._date(row['created_at']),
          updatedAt: ChatStore._date(row['updated_at']),
        ),
    ];
  }

  TavernAuthoringRunSnapshot admitAuthoringRunData(
    Map<String, Object?> request,
    Map<String, Object?> model, {
    required void Function(TavernAuthoringRunSnapshot value, bool created) onCommitted,
  }) {
    TavernAuthoringRunSnapshot? adopted;
    var created = false;
    return transaction(() {
      final runId = request['runId']! as String;
      final existing = readAuthoringRunData(runId);
      if (existing != null) {
        if (!_toolEqual(existing.request.toJson(), request)) {
          throw const TavernAuthoringException('run_id_conflict', 'This run id already has different input.');
        }
        return adopted = existing;
      }
      final draftId = request['draftId']! as String;
      final revision = request['draftRevision']! as int;
      _authoringRunDraftRevision(draftId, revision);
      final at = _clock().millisecondsSinceEpoch;
      _db.execute(
        'INSERT INTO authoring_runs '
        '(run_id, draft_id, start_revision, current_revision, status, data_json, created_at, updated_at) '
        "VALUES (?, ?, ?, ?, 'running', ?, ?, ?)",
        [
          runId,
          draftId,
          revision,
          revision,
          jsonEncode({'version': 1, 'request': request, 'model': model, 'answer': '', 'issues': <Object?>[]}),
          at,
          at,
        ],
      );
      created = true;
      return adopted = readAuthoringRunData(runId)!;
    }, onCommitted: () => onCommitted(adopted!, created));
  }

  void checkAuthoringRunDraft(String runId, int revision) {
    final row = _authoringRunningRow(runId);
    if (row['current_revision'] != revision) {
      _authoringRunConflict();
    }
    _authoringRunDraftRevision(row['draft_id'] as String, revision);
  }

  TavernAuthoringRequestSnapshot registerAuthoringRequestData(
    String runId,
    int index,
    Map<String, Object?> body, {
    required void Function(TavernAuthoringRequestSnapshot) onCommitted,
  }) {
    TavernAuthoringRequestSnapshot? adopted;
    return transaction(() {
      final run = _authoringRunningRow(runId);
      _authoringRunDraftRevision(run['draft_id'] as String, run['current_revision'] as int);
      final count =
          _db.select('SELECT count(*) AS n FROM authoring_requests WHERE run_id = ?', [runId]).single['n'] as int;
      if (index != count + 1 || index > 4) {
        throw const TavernAuthoringException('budget_exhausted', 'An author run permits four application requests.');
      }
      final at = _clock().millisecondsSinceEpoch;
      final data = {
        'version': 1,
        'body': body,
        'attempts': <int>[],
        'text': '',
        'reasoning': '',
        'responseComplete': false,
        'finishReason': null,
        'assistant': null,
        'toolBatch': null,
        'usage': emptyToolUsageLedger(),
      };
      _db.execute(
        'INSERT INTO authoring_requests (run_id, request_index, status, data_json, created_at, updated_at) '
        "VALUES (?, ?, 'registered', ?, ?, ?)",
        [runId, index, jsonEncode(data), at, at],
      );
      return adopted = readAuthoringRequestData(runId, index)!;
    }, onCommitted: () => onCommitted(adopted!));
  }

  TavernAuthoringRequestSnapshot? readAuthoringRequestData(String runId, int index) {
    _ensureOpen();
    final rows = _db.select('SELECT * FROM authoring_requests WHERE run_id = ? AND request_index = ?', [runId, index]);
    return rows.isEmpty ? null : _authoringRequestRow(runId, rows.single);
  }

  void recordAuthoringAttemptData(String runId, int index, int attempt, {required void Function() onCommitted}) =>
      transaction(() {
        final request = readAuthoringRequestData(runId, index)!;
        if (request.status != TavernAuthoringRequestStatus.registered &&
            request.status != TavernAuthoringRequestStatus.running) {
          throw StateError('The authoring request is already sealed.');
        }
        final data = request.toJson();
        data['attempts'] = [...request.attempts, if (!request.attempts.contains(attempt)) attempt];
        _db.execute(
          "UPDATE authoring_requests SET status = 'running', data_json = ?, updated_at = ? "
          'WHERE run_id = ? AND request_index = ?',
          [jsonEncode(data), _clock().millisecondsSinceEpoch, runId, index],
        );
      }, onCommitted: onCommitted);

  void finishAuthoringRequestData(
    String runId,
    int index, {
    required TavernAuthoringRequestStatus status,
    required Map<String, Object?> response,
    required String answer,
    required void Function() onCommitted,
  }) => transaction(() {
    final request = readAuthoringRequestData(runId, index)!;
    if (request.status != TavernAuthoringRequestStatus.registered &&
        request.status != TavernAuthoringRequestStatus.running) {
      return;
    }
    final data = request.toJson()..addAll(response);
    final at = _clock().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE authoring_requests SET status = ?, data_json = ?, updated_at = ? '
      'WHERE run_id = ? AND request_index = ?',
      [status.name, jsonEncode(data), at, runId, index],
    );
    final row = _authoringRunningRow(runId);
    final run = _authoringRunPayload(row)..['answer'] = answer;
    _db.execute('UPDATE authoring_runs SET data_json = ?, updated_at = ? WHERE run_id = ?', [
      jsonEncode(run),
      at,
      runId,
    ]);
  }, onCommitted: onCommitted);

  TavernAuthoringToolReceipt? readAuthoringToolReceiptData(String runId, String receiptId) {
    _ensureOpen();
    final rows = _db.select('SELECT data_json FROM authoring_receipts WHERE run_id = ? AND receipt_id = ?', [
      runId,
      receiptId,
    ]);
    return rows.isEmpty ? null : TavernAuthoringToolReceipt.fromJson(ChatStore._map(rows.single['data_json']));
  }

  /// This outer transaction alone announces adoption. updateAuthoringDraftData
  /// joins it through a savepoint; returning from that helper is not COMMIT.
  TavernAuthoringToolReceipt commitAuthoringToolData(
    String runId, {
    required int requestIndex,
    required int callIndex,
    required String callId,
    required String toolName,
    required String arguments,
    required int revision,
    required TavernAuthoringToolStatus status,
    required Map<String, Object?> result,
    List<String> changeIds = const [],
    Map<String, Object?>? draftData,
    required void Function(TavernAuthoringToolReceipt) onCommitted,
  }) {
    TavernAuthoringToolReceipt? adopted;
    return transaction(() {
      final receiptId = '$requestIndex:$callIndex';
      final existing = readAuthoringToolReceiptData(runId, receiptId);
      if (existing != null) {
        if (existing.callId != callId || existing.toolName != toolName || existing.arguments != arguments) {
          throw const TavernAuthoringException(
            'operation_conflict',
            'The authoring call already has different parameters.',
          );
        }
        return adopted = existing;
      }
      final row = _authoringRunningRow(runId);
      if (row['current_revision'] != revision) {
        _authoringRunConflict();
      }
      _authoringRunDraftRevision(row['draft_id'] as String, revision);
      final request = readAuthoringRequestData(runId, requestIndex);
      if (request == null || request.status != TavernAuthoringRequestStatus.completed) {
        throw StateError('A draft tool requires a completed registered response.');
      }
      final after = draftData == null
          ? revision
          : updateAuthoringDraftData(row['draft_id'] as String, revision, draftData).revision;
      final receipt = TavernAuthoringToolReceipt(
        runId: runId,
        receiptId: receiptId,
        requestIndex: requestIndex,
        callIndex: callIndex,
        callId: callId,
        toolName: toolName,
        arguments: arguments,
        status: status,
        beforeRevision: revision,
        afterRevision: after,
        changeIds: changeIds,
        result: result,
      );
      _db.execute(
        'INSERT INTO authoring_receipts (run_id, request_index, call_index, receipt_id, data_json) '
        'VALUES (?, ?, ?, ?, ?)',
        [runId, requestIndex, callIndex, receiptId, jsonEncode(receipt.toJson())],
      );
      _db.execute('UPDATE authoring_runs SET current_revision = ?, updated_at = ? WHERE run_id = ?', [
        after,
        _clock().millisecondsSinceEpoch,
        runId,
      ]);
      return adopted = receipt;
    }, onCommitted: () => onCommitted(adopted!));
  }

  TavernAuthoringRunSnapshot finishAuthoringRunData(
    String runId,
    TavernAuthoringRunStatus status, {
    required String answer,
    required List<TavernAuthoringIssue> issues,
    required void Function(TavernAuthoringRunSnapshot) onCommitted,
  }) {
    TavernAuthoringRunSnapshot? adopted;
    return transaction(() {
      final row = _authoringRunRowData(runId);
      if (row['status'] != 'running') {
        return adopted = _authoringRunRow(row);
      }
      final data = _authoringRunPayload(row)
        ..['answer'] = answer
        ..['issues'] = [
          for (final issue in issues) {'type': issue.type, 'message': issue.message},
        ];
      final at = _clock().millisecondsSinceEpoch;
      _db.execute('UPDATE authoring_runs SET status = ?, data_json = ?, updated_at = ? WHERE run_id = ?', [
        status.name,
        jsonEncode(data),
        at,
        runId,
      ]);
      _db.execute(
        "UPDATE authoring_requests SET status = ?, updated_at = ? WHERE run_id = ? AND status IN ('registered', 'running')",
        [status == TavernAuthoringRunStatus.cancelled ? 'cancelled' : 'failed', at, runId],
      );
      return adopted = readAuthoringRunData(runId)!;
    }, onCommitted: () => onCommitted(adopted!));
  }

  /// One best-effort diagnostic update after a known terminal COMMIT. It does
  /// not reopen the run or change any draft, request or adoption result.
  void noteAuthoringRunIssueData(String runId, TavernAuthoringIssue issue) => transaction(() {
    final row = _authoringRunRowData(runId);
    final data = _authoringRunPayload(row);
    final issues = data['issues']! as List<Object?>;
    if (issues.cast<Map<String, Object?>>().any(
      (saved) => saved['type'] == issue.type && saved['message'] == issue.message,
    )) {
      return;
    }
    issues.add({'type': issue.type, 'message': issue.message});
    _db.execute('UPDATE authoring_runs SET data_json = ?, updated_at = ? WHERE run_id = ?', [
      jsonEncode(data),
      _clock().millisecondsSinceEpoch,
      runId,
    ]);
  });

  Row _authoringRunRowData(String runId) {
    final rows = _db.select('SELECT *, char(1) || run_id AS guarded_run_id FROM authoring_runs WHERE run_id = ?', [
      runId,
    ]);
    if (rows.isEmpty) {
      throw const TavernAuthoringException('not_found', 'The authoring run does not exist.');
    }
    return rows.single;
  }

  Row _authoringRunningRow(String runId) {
    final row = _authoringRunRowData(runId);
    if (row['status'] != 'running') {
      throw const TavernAuthoringException('cancelled', 'The authoring run has ended.');
    }
    return row;
  }

  void _authoringRunDraftRevision(String draftId, int revision) {
    final rows = _db.select('SELECT revision FROM authoring_drafts WHERE id = ?', [draftId]);
    if (rows.isEmpty || rows.single['revision'] != revision) {
      _authoringRunConflict();
    }
  }

  Never _authoringRunConflict() =>
      throw const TavernAuthoringException('revision_conflict', 'The authoring draft changed or was deleted.');

  Map<String, Object?> _authoringRunPayload(Row row) {
    final data = ChatStore._map(row['data_json']);
    if (data['version'] != 1 ||
        data['request'] is! Map<String, Object?> ||
        data['model'] is! Map<String, Object?> ||
        data['answer'] is! String ||
        data['issues'] is! List<Object?>) {
      throw const FormatException('Invalid saved authoring run.');
    }
    return data;
  }

  TavernAuthoringRunSnapshot _authoringRunRow(Row row) {
    final id = ChatStore._unguardText(row['guarded_run_id'])!;
    final data = _authoringRunPayload(row);
    final requests = [
      for (final value in _db.select('SELECT * FROM authoring_requests WHERE run_id = ? ORDER BY request_index', [id]))
        _authoringRequestRow(id, value),
    ];
    return TavernAuthoringRunSnapshot(
      runId: id,
      draftId: row['draft_id'] as String,
      startRevision: row['start_revision'] as int,
      currentRevision: row['current_revision'] as int,
      status: TavernAuthoringRunStatus.values.byName(row['status'] as String),
      answer: data['answer']! as String,
      request: data['request']! as Map<String, Object?>,
      model: data['model']! as Map<String, Object?>,
      requests: requests,
      receipts: [
        for (final value in _db.select(
          'SELECT data_json FROM authoring_receipts '
          'WHERE run_id = ? ORDER BY request_index, call_index',
          [id],
        ))
          TavernAuthoringToolReceipt.fromJson(ChatStore._map(value['data_json'])),
      ],
      usage: summarizeToolUsage([
        for (final request in requests) (requestIndex: request.requestIndex, usage: request.usage),
      ]),
      issues: [
        for (final issue in (data['issues']! as List<Object?>).cast<Map<String, Object?>>())
          TavernAuthoringIssue(type: issue['type']! as String, message: issue['message']! as String),
      ],
      createdAt: ChatStore._date(row['created_at']),
      updatedAt: ChatStore._date(row['updated_at']),
    );
  }

  TavernAuthoringRequestSnapshot _authoringRequestRow(String runId, Row row) {
    final data = ChatStore._map(row['data_json']);
    return TavernAuthoringRequestSnapshot.fromJson({
      ...data,
      'runId': runId,
      'requestIndex': row['request_index'],
      'status': row['status'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
    });
  }
}

const _authoringRunSchema = r'''
CREATE TABLE authoring_runs (
  run_id TEXT PRIMARY KEY,
  draft_id TEXT NOT NULL,
  start_revision INTEGER NOT NULL,
  current_revision INTEGER NOT NULL,
  status TEXT NOT NULL,
  data_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX authoring_runs_draft ON authoring_runs (draft_id, created_at DESC, run_id DESC);
CREATE TABLE authoring_requests (
  run_id TEXT NOT NULL,
  request_index INTEGER NOT NULL,
  status TEXT NOT NULL,
  data_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (run_id, request_index)
);
CREATE TABLE authoring_receipts (
  run_id TEXT NOT NULL,
  request_index INTEGER NOT NULL,
  call_index INTEGER NOT NULL,
  receipt_id TEXT NOT NULL,
  data_json TEXT NOT NULL,
  PRIMARY KEY (run_id, request_index, call_index),
  UNIQUE (run_id, receipt_id)
);
''';
