import 'dart:async';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/support/fake_plugin_host.dart';

class _Active extends ActiveHostController {
  @override
  HostRef build() => const HostRef.portal('a');
  @override
  void select(HostRef host) => state = host;
}

class _Connection extends Notifier<HostConnection?> {
  @override
  HostConnection? build() => null;
  void set(HostConnection? connection) => state = connection;
}

final _connection = NotifierProvider<_Connection, HostConnection?>(_Connection.new);

class _Client extends DshClient {
  _Client(this.fake) : super.withCarrier(fake);
  final FakePluginCarrier fake;
  final hosts = StreamController<HostEvent>.broadcast();
  final workspaces = StreamController<WorkspaceUpdate>.broadcast();
  final controls = StreamController<SessionControlUpdate>.broadcast();
  final lists = <Completer<List<SessionSummary>>>[];
  Completer<SessionProjections?>? seed;
  List<SessionSummary> rows = [];
  int listCalls = 0;
  int modelCalls = 0;

  @override
  Stream<HostEvent> get hostEvents => hosts.stream;
  @override
  Stream<WorkspaceUpdate> watchWorkspaces() => workspaces.stream;
  @override
  Stream<SessionControlUpdate> watchSessionControl() => controls.stream;
  @override
  Future<List<SessionSummary>> listSessions() {
    listCalls++;
    return lists.isEmpty ? Future.value(rows) : lists.removeAt(0).future;
  }

  @override
  Future<ModelCatalog> listModels() async {
    modelCalls++;
    return ModelCatalog.fromJson(const {});
  }

  @override
  Future<SessionProjections?> projections(String sessionId) => seed?.future ?? Future.value(SessionProjections.empty);

  Future<void> release() async {
    await hosts.close();
    await workspaces.close();
    await controls.close();
    await close();
  }
}

SessionSummary _row(String id) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24),
  running: false,
  blank: false,
  agentAvailable: true,
  projections: SessionProjections(1, {'title': id}),
);

HostConnection _host(_Client client, String id) =>
    HostConnection(client: client, label: id, isLocal: false, kind: HostKind.portal, hostId: id);

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late ProviderContainer container;
  late _Client a;
  late _Client b;
  setUp(() {
    a = _Client(FakePluginCarrier());
    b = _Client(FakePluginCarrier());
    container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_Active.new),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_connection))),
        hostSessionsProvider.overrideWithValue(const {}),
        agentTeamBundleProvider.overrideWithValue(const AsyncData(null)),
      ],
    );
    container.read(_connection.notifier).set(_host(a, 'a'));
  });
  tearDown(() async {
    container.dispose();
    await a.release();
    await b.release();
  });

  void switchTo(_Client client, String id) {
    container.read(activeHostProvider.notifier).select(HostRef.portal(id));
    container.read(_connection.notifier).set(_host(client, id));
  }

  test('late A list cannot overwrite B, including B workspace-before-list', () async {
    a.rows = [_row('a1')];
    container.listen(sessionsProvider, (_, _) {});
    await container.read(sessionsProvider.future);
    final lateA = Completer<List<SessionSummary>>();
    a.lists.add(lateA);
    final refreshingA = container.read(sessionsProvider.notifier).refresh();
    final firstB = Completer<List<SessionSummary>>();
    b.lists.add(firstB);
    switchTo(b, 'b');
    await _tick();
    b.workspaces.add(const WorkspaceBaseline([], ['b-archived'], []));
    await _tick();
    final notifier = container.read(sessionsProvider.notifier);
    expect(notifier.allSessions, isEmpty);
    // Nothing is published for B before its list. Riverpod 3 keeps A's rows
    // as the reload's previous value meanwhile; a set AsyncLoading can't clear it.
    expect(container.read(sessionsProvider).isReloading, isTrue);
    firstB.complete([_row('b1'), _row('b-archived')]);
    await container.read(sessionsProvider.future);
    lateA.complete([_row('a-late')]);
    await refreshingA;
    expect(container.read(sessionsProvider).requireValue.map((s) => s.sessionId), ['b1']);
    expect(notifier.allSessions.map((s) => s.sessionId), ['b1', 'b-archived']);
    expect(notifier.archivedSessions.map((s) => s.sessionId), ['b-archived']);
  });

  test('same host changing clients retains rows and ignores old closed error', () async {
    a.rows = [_row('a1')];
    container.listen(sessionsProvider, (_, _) {});
    await container.read(sessionsProvider.future);
    final old = Completer<List<SessionSummary>>();
    a.lists.add(old);
    final refresh = container.read(sessionsProvider.notifier).refresh();
    final next = Completer<List<SessionSummary>>();
    b.lists.add(next);
    switchTo(b, 'a');
    await _tick();
    expect(container.read(sessionsProvider.notifier).allSessions.single.sessionId, 'a1');
    old.completeError(const DshClosedException('old client'));
    await refresh;
    expect(container.read(sessionsProvider).hasError, isFalse);
    next.complete([_row('a2')]);
    await container.read(sessionsProvider.future);
    expect(container.read(sessionsProvider).requireValue.single.sessionId, 'a2');
  });

  test('newest refresh wins; a failed silent refresh retains the list', () async {
    a.rows = [_row('initial')];
    container.listen(sessionsProvider, (_, _) {});
    await container.read(sessionsProvider.future);
    final first = Completer<List<SessionSummary>>();
    final second = Completer<List<SessionSummary>>();
    a.lists.addAll([first, second]);
    final notifier = container.read(sessionsProvider.notifier);
    final one = notifier.refresh();
    final two = notifier.refresh();
    second.complete([_row('new')]);
    await two;
    first.complete([_row('old')]);
    await one;
    expect(container.read(sessionsProvider).requireValue.single.sessionId, 'new');
    final fail = Completer<List<SessionSummary>>();
    a.lists.add(fail);
    final failing = notifier.refresh();
    fail.completeError(const DshTransportException('offline'));
    await failing;
    expect(container.read(sessionsProvider).requireValue.single.sessionId, 'new');
  });

  test('ready before subscriptions is not replayed; reconnect refreshes each cache once', () async {
    a.fake.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
    a.hosts.add(const HostReadyEvent('initial', '/root'));
    await _tick();
    container.listen(sessionsProvider, (_, _) {});
    container.listen(modelCatalogProvider, (_, _) {});
    container.listen(installedPluginsProvider, (_, _) {});
    await container.read(sessionsProvider.future);
    await container.read(modelCatalogProvider.future);
    await container.read(installedPluginsProvider.future);
    expect(a.listCalls, 1);
    expect(a.modelCalls, 1);
    expect(a.fake.argsOf('pluginManager/listBundles'), hasLength(1));
    a.hosts.add(const HostReadyEvent('reconnected', '/root'));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(a.listCalls, 2);
    expect(a.modelCalls, 2);
    expect(a.fake.argsOf('pluginManager/listBundles'), hasLength(2));
    expect(container.read(sessionsProvider).isLoading, isFalse);
  });

  test('panels merge seed per key: newer todos survive while goal is filled', () async {
    a.seed = Completer<SessionProjections?>();
    final p = sessionPanelsProvider('s');
    container.listen(p, (_, _) {});
    a.controls.add(
      const SessionControlProjection('s', 'todos', [
        {'content': 'new', 'status': 'pending'},
      ], 10),
    );
    await _tick();
    a.seed!.complete(
      const SessionProjections(8, {
        'todos': [
          {'content': 'old', 'status': 'pending'},
        ],
        'goal': {
          'goal': {'objective': 'keep goal', 'phase': 'active'},
        },
      }),
    );
    await _tick();
    expect(container.read(p).todos!.single.content, 'new');
    expect(container.read(p).goal!.objective, 'keep goal');
    a.controls.add(
      const SessionControlProjection('s', 'todos', [
        {'content': 'stale'},
      ], 9),
    );
    await _tick();
    expect(container.read(p).todos!.single.content, 'new');
  });

  test('usage merges seed per key without losing context pressure', () async {
    a.seed = Completer<SessionProjections?>();
    final p = sessionUsageProvider('s');
    container.listen(p, (_, _) {});
    a.controls.add(const SessionControlProjection('s', 'tokenUsage', {'outputTokens': 20}, 10));
    await _tick();
    a.seed!.complete(
      const SessionProjections(8, {
        'tokenUsage': {'outputTokens': 1},
        'contextPressure': {'pressureTokens': 40, 'contextWindow': 100},
      }),
    );
    await _tick();
    expect(container.read(p).output, 20);
    expect(container.read(p).pressureTokens, 40);
    a.controls.add(
      const SessionControlBaseline({
        's': SessionProjections(12, {
          'tokenUsage': {'outputTokens': 30},
        }),
      }),
    );
    await _tick();
    expect(container.read(p).output, 30);
    expect(container.read(p).pressureTokens, isNull);
  });

  test('team ignores an older seed and older projection frame', () async {
    a.seed = Completer<SessionProjections?>();
    final p = teamProvider('s');
    container.listen(p, (_, _) {});
    a.controls.add(const SessionControlProjection('s', 'agentTeam', {'failure': 'new'}, 10));
    await _tick();
    a.seed!.complete(
      const SessionProjections(8, {
        'agentTeam': {'failure': 'old'},
      }),
    );
    await _tick();
    expect(container.read(p).requireValue!.failure, 'new');
    a.controls.add(const SessionControlProjection('s', 'agentTeam', {'failure': 'stale'}, 9));
    await _tick();
    expect(container.read(p).requireValue!.failure, 'new');
  });

  test('retired slash refresh cannot replace the new-chat catalog', () async {
    switchTo(a, 'slash-refresh-owner');
    final old = Completer<Object?>();
    var calls = 0;
    a.fake.handlers['commands/list'] = (_) => ++calls == 1
        ? old.future
        : [
            {'name': 'current', 'description': 'after reconnect'},
          ];
    final session = hostCommandsProvider('commands-session');
    container.listen(session, (_, _) {});
    await _tick();
    expect(calls, 1);

    a.hosts.add(const HostReadyEvent('reconnected', '/root'));
    await _tick();
    expect((await container.read(session.future)).single.name, 'current');
    expect(calls, 2);
    old.complete([
      {'name': 'retired', 'description': 'before reconnect'},
    ]);
    await _tick();
    expect(container.read(session).requireValue.single.name, 'current');

    final newChat = hostCommandsProvider(null);
    container.listen(newChat, (_, _) {});
    expect((await container.read(newChat.future)).single.name, 'current');
  });

  test('retired slash client cannot replace the same-host new-chat catalog', () async {
    switchTo(a, 'slash-client-owner');
    final old = Completer<Object?>();
    a.fake.handlers['commands/list'] = (_) => old.future;
    b.fake.handlers['commands/list'] = (_) => [
      {'name': 'replacement', 'description': 'new connection'},
    ];
    final session = hostCommandsProvider('commands-session');
    container.listen(session, (_, _) {});
    await _tick();
    expect(a.fake.argsOf('commands/list'), hasLength(1));

    switchTo(b, 'slash-client-owner');
    expect((await container.read(session.future)).single.name, 'replacement');
    expect(b.fake.argsOf('commands/list'), hasLength(1));
    old.complete([
      {'name': 'disconnected', 'description': 'old connection'},
    ]);
    await _tick();
    expect(container.read(session).requireValue.single.name, 'replacement');

    final newChat = hostCommandsProvider(null);
    container.listen(newChat, (_, _) {});
    expect((await container.read(newChat.future)).single.name, 'replacement');
  });

  test('slash cache stays with its host and is empty while disconnected', () async {
    a.fake.handlers['commands/list'] = (_) => [
      {'name': 'foo', 'description': 'only A'},
    ];
    container.listen(hostCommandsProvider('s'), (_, _) {});
    expect((await container.read(hostCommandsProvider('s').future)).single.name, 'foo');
    switchTo(b, 'b');
    final newChat = hostCommandsProvider(null);
    container.listen(newChat, (_, _) {});
    expect(await container.read(newChat.future), isEmpty);
    expect(container.read(slashCommandsProvider(null)).any((c) => c.name == 'foo'), isFalse);
    switchTo(a, 'a');
    expect((await container.read(newChat.future)).single.name, 'foo');
    expect(container.read(slashCommandsProvider(null)).any((c) => c.name == 'foo'), isTrue);
    container.read(_connection.notifier).set(null);
    expect(await container.read(newChat.future), isEmpty);
  });
}
