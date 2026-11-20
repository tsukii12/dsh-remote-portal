// The lineage, header facts and team roster derived from the host session
// list (support.dart mirrors DSH 0.2.1-rc.2's `session/list`).

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show fakeConnection;
import 'support.dart';

ProviderContainer _container(Map<String, SessionSummary> sessions) {
  final container = ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
      hostSessionsProvider.overrideWithValue(sessions),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('lineage', () {
    test('catalog order, states, modes and the nested child', () {
      final nodes = buildLineage(parentId, sampleAgentSessions());
      expect(nodes.map((n) => n.label), ['审查改动', '补连点的测试', '查 CI 日志']);
      expect(nodes.map((n) => n.state), [AgentRunState.completed, AgentRunState.running, AgentRunState.failed]);
      expect(nodes[2].mode, SubagentMode.oneShot);
      expect(nodes.first.title, 'Review the login fix');
      expect(nodes.first.timing!.total, const Duration(seconds: 83));
      expect(nodes.first.children.single.label, '对照官方文档');
      expect(nodes.first.children.single.parentId, reviewerId);
      expect(nodes.first.flattened.length, 2);
      expect(nodes[1].children, isEmpty);
      expect(nodes[1].address.toJson(), {
        'kind': 'subagent',
        'parentSessionId': parentId,
        'childSessionId': testsId,
        'mode': 'continuable',
      });
    });

    test('listed children the catalog does not name yet still show', () {
      final sessions = sampleAgentSessions();
      sessions['late'] = SessionSummary(
        sessionId: 'late',
        updatedAt: agentsNow,
        running: true,
        blank: false,
        agentAvailable: true,
        parentSessionId: parentId,
        origin: 'subagent',
        projections: const SessionProjections(1, {
          'subagent': {'mode': 'continuable', 'label': '刚派出去', 'seq': 0},
        }),
      );
      final nodes = buildLineage(parentId, sessions);
      expect(nodes.last.label, '刚派出去');
      expect(nodes.last.running, isTrue);
      // No catalog and no identity: a generic name, never an empty row.
      expect(
        buildLineage('nobody', {
          'x': SessionSummary(
            sessionId: 'x',
            updatedAt: agentsNow,
            running: false,
            blank: false,
            agentAvailable: false,
            parentSessionId: 'nobody',
            origin: 'subagent',
          ),
        }).single.label,
        '子代理',
      );
    });

    test('a cycle in the data never loops', () {
      final sessions = sampleAgentSessions();
      sessions[nestedId] = SessionSummary(
        sessionId: nestedId,
        updatedAt: agentsNow,
        running: false,
        blank: false,
        agentAvailable: false,
        parentSessionId: reviewerId,
        origin: 'subagent',
        projections: const SessionProjections(1, {
          'subagentCatalog': [
            {'id': parentId, 'mode': 'continuable', 'label': 'loop'},
          ],
        }),
      );
      final nodes = buildLineage(parentId, sessions);
      expect(nodes.first.children.single.children, isEmpty);
    });
  });

  group('header', () {
    test('a root conversation: children and how many run', () {
      final container = _container(sampleAgentSessions());
      final agents = container.read(headerAgentsProvider(parentId));
      expect(agents.isChild, isFalse);
      expect(agents.children, 3);
      expect(agents.running, 1);
      expect(agents.hasTeam, isFalse);
      expect(agents.isEmpty, isFalse);
    });

    test('a child: breadcrumb to its parent, its own children', () {
      final container = _container(sampleAgentSessions());
      final agents = container.read(headerAgentsProvider(reviewerId));
      expect(agents.isChild, isTrue);
      expect(agents.parent!.label, '审查改动');
      expect(agents.parent!.parentTitle, '修复登录重复提交');
      expect(agents.parent!.address.mode, SubagentMode.continuable);
      expect(agents.children, 1);
    });

    test('a team: the Lead owns it, a teammate sees the same', () {
      final container = _container(sampleAgentSessions(withTeam: true));
      final lead = container.read(headerAgentsProvider(parentId));
      expect(lead.hasTeam, isTrue);
      expect(lead.leadId, parentId);
      expect(lead.team!.teammates, hasLength(2));
      final mate = container.read(headerAgentsProvider(testsId));
      expect(mate.leadId, parentId);
    });

    test('nothing to show for an unknown or lonely conversation', () {
      final container = _container(sampleAgentSessions());
      expect(container.read(headerAgentsProvider('other')).isEmpty, isTrue);
      expect(_container(const {}).read(headerAgentsProvider(parentId)).isEmpty, isTrue);
    });
  });

  group('team', () {
    test('roster with activity, model and state labels', () {
      final members = teamMembers(sampleTeam(), sampleAgentSessions(withTeam: true));
      expect(members.map((m) => m.member.name), ['lead', 'reviewer', 'tester']);
      expect(members[2].running, isTrue);
      expect(members[2].stateLabel, '运行中');
      expect(members[1].state, AgentRunState.idle);
      expect(members[1].model!.model, 'deepseek-flash');
      const failed = TeamMemberView(
        member: TeamMember(id: 'f', name: 'f', lead: false, phase: 'failed', error: 'no model'),
        running: false,
      );
      expect(failed.state, AgentRunState.failed);
      expect(failed.stateLabel, '失败');
      const provisioning = TeamMemberView(
        member: TeamMember(id: 'p', name: 'p', lead: false, phase: 'provisioning'),
        running: false,
      );
      expect(provisioning.stateLabel, '准备中');
    });

    test('tasks parse with readiness and owners', () {
      final tasks = sampleTeam().tasks;
      expect(tasks.map((t) => t.status), ['completed', 'in_progress', 'pending', 'pending']);
      expect(tasks[2].ready, isFalse);
      expect(tasks[2].blockedBy, ['task-2']);
      expect(tasks[3].ready, isTrue);
      expect(tasks[3].ownerName, isNull);
    });
  });
}
