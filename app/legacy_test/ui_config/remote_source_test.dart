// The remote source against a fake host: DSH home from the skill or $HOME,
// reads, paging, `workspaceFiles/changes`, the polling fallback, refusals.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class FakeRemoteHost implements UiRemoteHost {
  FakeRemoteHost({this.endpoints = const {'workspaceFiles/read', 'workspaceFiles/changes'}});

  Set<String> endpoints;
  String? session = 's1';
  String? skillPath = '/home/u/.dsh-custom/skills/dsh-go-ui/SKILL.md';
  @override
  String? userHome = '/home/u';

  /// path → text (absent paths are not found).
  final files = <String, String>{};
  final versions = <String, int>{};
  int pageLines = 5000;
  int reads = 0;
  int probes = 0;
  DshRemoteException? refuse;

  /// Older hosts refuse to watch a file that does not exist; DSH 0.2.1
  /// watches it and reports the creation.
  bool watchMissingFails = false;
  final watchers = <String, StreamController<DshWorkspaceWatchFrame>>{};
  final watchRequests = <String>[];
  final changesController = StreamController<void>.broadcast();

  void write(String path, String text) {
    files[path] = text;
    versions[path] = (versions[path] ?? 0) + 1;
    watchers[path]?.add(DshWorkspaceWatchChange(absolutePath: path, version: '${versions[path]}'));
  }

  void delete(String path) {
    files.remove(path);
    watchers[path]?.add(DshWorkspaceWatchChange(absolutePath: path, absent: true));
  }

  @override
  bool supports(String endpoint) => endpoints.contains(endpoint);

  @override
  Future<String?> recentSessionId() async => session;

  @override
  Future<String?> skillFile(String sessionId) async => skillPath;

  @override
  Future<DshWorkspaceText> read(String sessionId, String path, {int offset = 1, int limit = 5000}) async {
    expect(sessionId, session);
    if (limit == 1) {
      probes++;
    } else {
      reads++;
    }
    if (refuse case final e?) throw e;
    final text = files[path];
    if (text == null) throw DshRemoteException('workspace-file/not-found', 'no such file');
    final lines = text.split('\n');
    final take = limit.clamp(1, pageLines);
    final page = lines.skip(offset - 1).take(take).toList();
    return DshWorkspaceText(
      text: page.join('\n'),
      lines: page.length,
      eof: offset - 1 + page.length >= lines.length,
      offset: offset,
      absolutePath: path,
      version: '${versions[path]}',
      bytes: text.length,
    );
  }

  @override
  Stream<DshWorkspaceWatchFrame> watch(String sessionId, String path) {
    watchRequests.add(path);
    final controller = StreamController<DshWorkspaceWatchFrame>();
    if (!files.containsKey(path) && watchMissingFails) {
      scheduleMicrotask(() {
        controller.addError(DshRemoteException('workspace-file/not-found', 'no such file'));
        controller.close();
      });
    } else {
      watchers[path] = controller;
      scheduleMicrotask(() => controller.add(const DshWorkspaceWatchReady()));
    }
    return controller.stream;
  }

  @override
  Stream<void> get changes => changesController.stream;
}

void main() {
  const customPath = '/home/u/.dsh-custom/dsh-go/ui.json';
  const guessedPath = '/home/u/.dsh/dsh-go/ui.json';

  late FakeRemoteHost host;
  late List<UiConfigRead> reads;
  late StreamController<void> kicks;
  late RemoteUiConfigSource source;
  StreamSubscription<UiConfigRead>? sub;
  var foreground = true;

  void start({Duration poll = const Duration(milliseconds: 100)}) {
    source = RemoteUiConfigSource(
      host: host,
      kicks: kicks.stream,
      debounce: const Duration(milliseconds: 20),
      pollEvery: poll,
      isForeground: () => foreground,
    );
    sub = source.watch().listen(reads.add);
  }

  String? lastText() => switch (reads.lastOrNull) {
    UiConfigText(:final text) => text,
    _ => null,
  };

  setUp(() {
    host = FakeRemoteHost();
    reads = [];
    kicks = StreamController<void>.broadcast();
    foreground = true;
  });

  tearDown(() async {
    await sub?.cancel();
    sub = null;
    await kicks.close();
  });

  test('DSH home from the skill path', () {
    expect(dshHomeFromSkillPath('/srv/dsh/skills/dsh-go-ui/SKILL.md'), '/srv/dsh');
    expect(dshHomeFromSkillPath('/srv/dsh/skills/dsh-go-ui/'), '/srv/dsh');
    expect(dshHomeFromSkillPath('/srv/dsh/skills/other/SKILL.md'), isNull);
    expect(dshHomeFromSkillPath('skills/dsh-go-ui/SKILL.md'), isNull);
  });

  test('reads the file under the skill\'s DSH home and follows its changes', () async {
    host.write(customPath, '{"version": 1, "density": "compact"}');
    start();
    await until(() => lastText() != null);
    expect(source.path, customPath);
    expect(lastText(), '{"version": 1, "density": "compact"}');
    await until(() => host.watchRequests.contains(customPath));

    host.write(customPath, '{"version": 1, "density": "comfortable"}');
    await until(() => lastText()?.contains('comfortable') ?? false);
  });

  test('no skill: guesses ~/.dsh from \$HOME and says the skill is missing', () async {
    host.skillPath = null;
    start();
    await until(() => reads.isNotEmpty);
    expect(source.path, guessedPath);
    expect(reads.last, isA<UiConfigAbsent>().having((a) => a.skillMissing, 'skillMissing', isTrue));
  });

  test('neither skill nor \$HOME: noSkill', () async {
    host
      ..skillPath = null
      ..userHome = null;
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigUnavailable>().having((u) => u.reason, 'reason', UiConfigUnavailableReason.noSkill));
  });

  test('no conversation yet: noSession, then a new conversation starts the read', () async {
    host.session = null;
    host.write(customPath, '{"version": 1}');
    start();
    await until(() => reads.isNotEmpty);
    expect(
      reads.last,
      isA<UiConfigUnavailable>().having((u) => u.reason, 'reason', UiConfigUnavailableReason.noSession),
    );
    host.session = 's1';
    host.changesController.add(null);
    await until(() => lastText() != null);
  });

  test('a host without workspaceFiles/read is unsupported', () async {
    host.endpoints = {};
    start();
    await until(() => reads.isNotEmpty);
    expect(
      reads.last,
      isA<UiConfigUnavailable>().having((u) => u.reason, 'reason', UiConfigUnavailableReason.unsupported),
    );
  });

  test('a missing file is watched: creating it reads it, deleting it reports absent', () async {
    start(poll: const Duration(hours: 1));
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigAbsent>());
    await until(() => host.watchRequests.contains(customPath));
    host.write(customPath, '{"version": 1, "hide": ["whaleTail"]}');
    await until(() => lastText() != null);
    host.delete(customPath);
    await until(() => reads.last is UiConfigAbsent);
    expect(host.probes, 0, reason: 'no polling while watching');
  });

  test('a host that refuses to watch a missing file is polled, then watched once it appears', () async {
    host.watchMissingFails = true;
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigAbsent>());
    host.write(customPath, '{"version": 1, "hide": ["whaleTail"]}');
    await until(() => lastText() != null);
    await until(() => host.watchRequests.contains(customPath));
    host.write(customPath, '{"version": 1, "hide": ["goalBar"]}');
    await until(() => lastText()?.contains('goalBar') ?? false);
  });

  test('without workspaceFiles/changes it polls, only while the app is in front', () async {
    host.endpoints = {'workspaceFiles/read'};
    host.write(customPath, '{"version": 1}');
    start();
    await until(() => lastText() != null);
    foreground = false;
    host.write(customPath, '{"version": 1, "density": "compact"}');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(lastText(), '{"version": 1}');
    foreground = true;
    await until(() => lastText()?.contains('compact') ?? false);
    expect(host.watchRequests, isEmpty);
  });

  test('resumes read again', () async {
    host.endpoints = {'workspaceFiles/read'};
    host.write(customPath, '{"version": 1}');
    start(poll: const Duration(hours: 1));
    await until(() => lastText() != null);
    host.files[customPath] = '{"version": 1, "density": "compact"}';
    kicks.add(null);
    await until(() => lastText()?.contains('compact') ?? false);
  });

  test('long files come in pages', () async {
    host
      ..endpoints = {'workspaceFiles/read'}
      ..pageLines = 3;
    final text = ['{', '"version": 1,', '"hide": [', '"whaleTail",', '"goalBar"', ']', '}'].join('\n');
    host.write(customPath, text);
    start(poll: const Duration(hours: 1));
    await until(() => lastText() != null);
    expect(lastText(), text);
    expect(host.reads, 3);
  });

  test('too large: broken', () async {
    host.write(customPath, '{"version": 1, "x": "${'a' * (65 * 1024)}"}');
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigBroken>());
  });

  test('DshUiRemoteHost: newest top-level conversation, the skill path, pages, \$HOME', () async {
    final carrier = _Carrier();
    carrier.handlers['session/list'] = (_) => {
      'items': [
        {'sessionId': 'old', 'updatedAt': 1000},
        {'sessionId': 'sub', 'updatedAt': 9000, 'origin': 'subagent'},
        {'sessionId': 'new', 'updatedAt': 5000},
        {'sessionId': 'blank', 'updatedAt': 8000, 'blank': true},
      ],
    };
    carrier.handlers['skills/list'] = (args) {
      expect((args['request']! as Map)['sessionId'], 'new');
      return {
        'skills': [
          {'name': 'other', 'description': '', 'path': '/x/skills/other/SKILL.md'},
          {'name': 'dsh-go-ui', 'description': '', 'path': '/srv/dsh/skills/dsh-go-ui/SKILL.md'},
        ],
      };
    };
    carrier.handlers['workspaceFiles/read'] = (args) {
      expect(args['workspaceFileScopeId'], 'new');
      expect(args['path'], '/srv/dsh/dsh-go/ui.json');
      return {'text': '{"version": 1}', 'lines': 1, 'eof': true, 'offset': 1, 'version': 'v1', 'bytes': 14};
    };
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    final remote = DshUiRemoteHost(client);
    expect(remote.supports('workspaceFiles/read'), isTrue);
    expect(remote.supports('workspaceFiles/changes'), isFalse);
    expect(await remote.recentSessionId(), 'new');
    final skill = await remote.skillFile('new');
    expect(skill, '/srv/dsh/skills/dsh-go-ui/SKILL.md');
    expect(dshHomeFromSkillPath(skill!), '/srv/dsh');
    final page = await remote.read('new', '/srv/dsh/dsh-go/ui.json');
    expect(page.text, '{"version": 1}');
    expect(page.version, 'v1');
    await client.mux.ready();
    expect(remote.userHome, '/home/remote');
  });

  test('a refusal is denied', () async {
    host.write(customPath, '{"version": 1}');
    host.refuse = DshRemoteException('workspace-file/outside-workspace', 'outside');
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigUnavailable>().having((u) => u.reason, 'reason', UiConfigUnavailableReason.denied));
  });
}

/// RPC answers for [DshUiRemoteHost], plus a mux link whose handshake reports
/// the host's $HOME.
class _Carrier extends DshCarrier {
  final calls = <String>[];
  final handlers = <String, Object? Function(Map<String, Object?> args)>{};

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => endpoint != 'workspaceFiles/changes';

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    final handler = handlers[endpoint];
    if (handler == null) return RpcError(DshRemoteException('gateway/method-not-found', endpoint));
    try {
      return RpcOk(handler(args));
    } on DshRemoteException catch (e) {
      return RpcError(e);
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => _Link();

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  DshMuxFrameHandler? _onFrame;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => _onFrame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint != r'$events') return;
    scheduleMicrotask(
      () => _onFrame?.call({
        'type': 'item',
        'streamId': streamId,
        'value': {
          'type': 'ready',
          'clientId': 'c1',
          'host': {'home': '/home/remote'},
        },
      }),
    );
  }

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) {}

  @override
  Future<void> close(int code, String reason) async {}
}
