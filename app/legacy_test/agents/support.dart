// Shared fixtures for the multi-agent tests: a host session list shaped like
// DSH 0.2.1-rc.2's `session/list` (checked against a throwaway `dsh web`
// running a scripted model), a team, and fakes for the team panel.

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// Frozen "now" for live timers.
final agentsNow = DateTime(2026, 10, 24, 14, 30);

const parentId = 'session-parent';
const reviewerId = 'child-review';
const testsId = 'child-tests';
const brokenId = 'child-broken';
const nestedId = 'child-nested';

SessionSummary _summary(
  String id, {
  String? parent,
  bool running = false,
  Map<String, Object?> values = const {},
  DateTime? updatedAt,
}) => SessionSummary(
  sessionId: id,
  updatedAt: updatedAt ?? agentsNow,
  running: running,
  blank: false,
  agentAvailable: running,
  parentSessionId: parent,
  origin: parent == null ? null : 'subagent',
  projections: SessionProjections(10, values),
);

Map<String, Object?> _identity(String label) => {'mode': 'continuable', 'label': label, 'seq': 0};

int _ms(DateTime t) => t.millisecondsSinceEpoch;

/// A parent with three children (finished, running, failed), one of which
/// delegated once more.
Map<String, SessionSummary> sampleAgentSessions({bool withTeam = false}) {
  final rows = [
    _summary(
      parentId,
      values: {
        'title': '修复登录重复提交',
        'subagentCatalog': [
          {
            'id': reviewerId,
            'mode': 'continuable',
            'label': '审查改动',
            'createdAt': _ms(agentsNow.subtract(const Duration(minutes: 9))),
          },
          {
            'id': testsId,
            'mode': 'continuable',
            'label': '补连点的测试',
            'createdAt': _ms(agentsNow.subtract(const Duration(minutes: 6))),
          },
          {
            'id': brokenId,
            'mode': 'one-shot',
            'label': '查 CI 日志',
            'createdAt': _ms(agentsNow.subtract(const Duration(minutes: 4))),
          },
        ],
        if (withTeam)
          'agentTeam': {
            'members': [
              {'id': parentId, 'name': 'lead', 'role': 'lead', 'phase': 'active'},
              {'id': reviewerId, 'name': 'reviewer', 'role': 'teammate', 'phase': 'active'},
              {'id': testsId, 'name': 'tester', 'role': 'teammate', 'phase': 'active'},
            ],
            'tasks': sampleTasks,
          },
      },
    ),
    _summary(
      reviewerId,
      parent: parentId,
      values: {
        'title': 'Review the login fix',
        'subagent': _identity('审查改动'),
        'subagentTiming': {'settledMs': 83000, 'lastTurnCompleted': true},
        'subagentCatalog': [
          {
            'id': nestedId,
            'mode': 'continuable',
            'label': '对照官方文档',
            'createdAt': _ms(agentsNow.subtract(const Duration(minutes: 8))),
          },
        ],
        'modelSelection': {
          'next': {'provider': 'deepseek-official', 'model': 'deepseek-flash'},
        },
      },
    ),
    _summary(
      testsId,
      parent: parentId,
      running: true,
      values: {
        'subagent': _identity('补连点的测试'),
        'subagentTiming': {
          'settledMs': 0,
          'active': {
            'since': _ms(agentsNow.subtract(const Duration(seconds: 47))),
            'through': _ms(agentsNow.subtract(const Duration(seconds: 2))),
          },
        },
      },
    ),
    _summary(
      brokenId,
      parent: parentId,
      values: {
        'subagent': {'mode': 'one-shot', 'label': '查 CI 日志', 'seq': 0},
        'subagentTiming': {'settledMs': 12000, 'lastTurnCompleted': false},
      },
    ),
    _summary(
      nestedId,
      parent: reviewerId,
      values: {
        'subagent': _identity('对照官方文档'),
        'subagentTiming': {'settledMs': 21000, 'lastTurnCompleted': true},
      },
    ),
  ];
  return {for (final s in rows) s.sessionId: s};
}

const sampleTasks = [
  {
    'id': 'task-1',
    'revision': 2,
    'subject': '复现连点重复提交',
    'description': '在登录页连点两次提交按钮，确认会发出两次请求。',
    'status': 'completed',
    'ownerName': 'reviewer',
    'blockedBy': [],
    'writeScopes': [],
    'ready': false,
    'writeScopeWarnings': [],
  },
  {
    'id': 'task-2',
    'revision': 1,
    'subject': '给提交按钮加防抖',
    'description': '提交中禁用按钮，请求结束再恢复。',
    'status': 'in_progress',
    'ownerName': 'lead',
    'blockedBy': ['task-1'],
    'writeScopes': ['lib/auth/'],
    'ready': false,
    'writeScopeWarnings': [],
  },
  {
    'id': 'task-3',
    'revision': 1,
    'subject': '补连点的组件测试',
    'description': '',
    'status': 'pending',
    'ownerName': 'tester',
    'blockedBy': ['task-2'],
    'writeScopes': ['test/auth/'],
    'ready': false,
    'writeScopeWarnings': [],
  },
  {
    'id': 'task-4',
    'revision': 1,
    'subject': '更新变更说明',
    'description': '',
    'status': 'pending',
    'blockedBy': [],
    'writeScopes': [],
    'ready': true,
    'writeScopeWarnings': [],
  },
];

TeamSnapshot sampleTeam() => sampleAgentSessions(withTeam: true)[parentId]!.projections.agentTeam!;

List<TeamMessage> sampleMessages() => [
  TeamMessage(
    recipientId: parentId,
    senderId: reviewerId,
    senderName: 'reviewer',
    text: '复现了：连点两次会发出两个登录请求，第二个返回 409。',
    time: agentsNow.subtract(const Duration(minutes: 3)),
    seq: 41,
  ),
  TeamMessage(
    recipientId: testsId,
    senderId: parentId,
    senderName: 'lead',
    text: '防抖改好后补一个连点的组件测试，放在 test/auth/ 下。',
    time: agentsNow.subtract(const Duration(minutes: 5)),
    seq: 12,
  ),
];

/// Serves a fixed team instead of watching the Host.
class FakeTeam extends TeamController {
  FakeTeam(super.leadId, this.team);

  final TeamSnapshot? team;

  @override
  AsyncValue<TeamSnapshot?> build() => AsyncData(team);

  @override
  Future<void> refresh() async {}
}

/// The installed bundles, recording switches.
class FakeInstalled extends InstalledPluginsController {
  FakeInstalled(this.bundles);

  final List<PluginBundle> bundles;
  final switched = <(String, bool)>[];

  @override
  Future<List<PluginBundle>?> build() async => bundles;

  @override
  Future<void> refresh() async {}

  @override
  Future<PluginOperationResult> setEnabled(PluginBundle bundle, bool enabled) async {
    switched.add((bundle.name, enabled));
    return PluginOperationResult.fromJson({'kind': 'bundle', 'application': 'applied'});
  }
}

const teamBundleOff = PluginBundle(name: agentTeamBundle, official: true, optional: true, availability: 'installation');

/// Overrides for a page that reads the agents state of [sessions].
List<Override> agentsOverrides(
  Map<String, SessionSummary> sessions, {
  TeamSnapshot? team,
  List<TeamMessage> messages = const [],
  FakeInstalled? installed,
}) => [
  hostSessionsProvider.overrideWithValue(sessions),
  teamProvider.overrideWith2((leadId) => FakeTeam(leadId, team)),
  teamMessagesProvider.overrideWith((ref, leadId) async => TeamMessagesSnapshot(messages: messages)),
  installedPluginsProvider.overrideWith(() => installed ?? FakeInstalled(const [])),
];
