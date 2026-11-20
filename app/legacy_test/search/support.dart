// Fakes and sample data for the session search tests.

import 'dart:async';

import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_client/dsh_client.dart';

import '../shell/golden_harness.dart';

/// Fixed clock for date labels: Saturday 24 Oct 2026, 16:20.
final searchNow = DateTime(2026, 10, 24, 16, 20);

SessionSummary searchSession(String id, String? title, DateTime at, {bool running = false, String? cwd}) =>
    SessionSummary(
      sessionId: id,
      updatedAt: at,
      running: running,
      blank: false,
      agentAvailable: running,
      cwd: cwd ?? '/root/workspace',
      projections: title == null ? SessionProjections.empty : SessionProjections(1, {'title': title}),
    );

/// Newest first, like [sessionsProvider].
List<SessionSummary> sampleSearchSessions() => [
  searchSession('s1', '修复登录按钮重复提交', DateTime(2026, 10, 24, 14, 5), running: true),
  searchSession('s2', '登录页加上记住密码', DateTime(2026, 10, 23, 21, 40)),
  searchSession('s3', '给设置页加深色模式', DateTime(2026, 10, 20, 10, 12)),
  searchSession('s4', 'Retrofit 拦截器加 token 刷新', DateTime(2026, 10, 3, 9, 30)),
  searchSession('s5', '解释 proot 的 link2symlink', DateTime(2026, 9, 12, 19, 2)),
  searchSession('s6', '把 README 翻译成英文', DateTime(2025, 12, 30, 8, 45)),
];

List<SessionSummary> sampleArchivedSessions() => [searchSession('a1', '旧版登录接口迁移笔记', DateTime(2026, 8, 2, 11, 0))];

/// What a Host with content search returns for 登录: whole CJK runs only
/// (FTS5 unicode61), so the hits are where 登录 stands between punctuation.
const loginHits = <ContentHit>[
  (
    sessionId: 's4',
    snippet:
        '…401 的时候拦截器先用 refresh token 换一次，换成功就重放原请求，'
        '刷新失败就跳回「登录」页，并清空本地缓存的用户信息，避免下次启动还带着过期的 token。',
  ),
  (sessionId: 's1', snippet: '用户双击「登录」会发两次请求，按钮在请求结束前要禁用，我在 LoginButton 里加了 isSubmitting 状态。'),
  (sessionId: 'sub', snippet: '子代理的会话不该出现在结果里'),
];

class SearchSessions extends FakeSessions {
  SearchSessions(super.sessions, [this.archived = const []]);

  final List<SessionSummary> archived;

  @override
  List<SessionSummary> get archivedSessions => archived;
}

/// Scripted Host content search. [results] maps a query to its page; an
/// unknown query finds nothing. [error] is thrown instead when set.
class FakeContentSearch implements SessionContentSearch {
  FakeContentSearch({this.results = const {}, this.error, this.delay = Duration.zero});

  final Map<String, ({List<ContentHit> items, bool hasMore})> results;
  Object? error;
  Duration delay;
  final List<String> calls = [];
  bool _unsupported = false;

  /// Completes the next call when set (holds it open until then).
  Completer<void>? gate;

  @override
  bool get knownUnsupported => _unsupported;

  @override
  void markUnsupported() => _unsupported = true;

  @override
  Future<({List<ContentHit> items, bool hasMore})> search(String query) async {
    calls.add(query);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (gate case final g?) await g.future;
    if (error case final e?) throw e;
    return results[query] ?? (items: const <ContentHit>[], hasMore: false);
  }
}

/// The Host's answer when its content index is off (stock `dsh web` profile).
const searchDisabled = DshRemoteException(
  'gateway/internal',
  'session search failed: SessionQueryError: session search is disabled: '
      'this deployment configures the session-query index with openAt "never"',
);
