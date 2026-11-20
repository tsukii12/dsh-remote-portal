// A scripted DS Bot for the Bot pages' tests: the channel's answers by
// endpoint, a feed the test drives, and a sample team.

import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/bots/bot_format.dart' show botClock;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show fakeConnection;

class FakeDsBotTransport implements DsBotTransport {
  FakeDsBotTransport({Map<String, Object?>? team}) {
    final data = team ?? sampleTeam();
    handlers.addAll({
      'hello': (_) => helloAnswer(),
      'state': (payload) => payload['since'] == data['revision'] ? {...liveOf(data), 'unchanged': true} : data,
      'chat': (payload) => {'sessionId': '${payload['botId']}-c', 'items': chatItems, 'cursor': null},
      'room-chat': (payload) => {
        'roomId': payload['roomId'],
        'items': roomItems,
        'cursor': null,
        'running': roomRunning,
        'speaking': roomSpeaking,
      },
      'send': (_) => true,
      'notices': (payload) => {'boot': 'boot-1', 'seq': 0, 'reset': false, 'notices': <Object?>[]},
      'memory-view': (_) => memory,
      'memory-edit': (_) => memory,
      'memory-add': (_) => memory,
      'memory-forget': (_) => memory,
      'usage-summary': (_) => usage,
      'avatar': (payload) => {'botId': payload['botId'], 'ref': 'abc123', 'image': tinyPhoto},
    });
  }

  final Map<String, Object? Function(Map<String, Object?> payload)> handlers = {};
  final List<(String, Map<String, Object?>)> calls = [];

  List<Object?> chatItems = sampleChat();
  List<Object?> roomItems = sampleRoomItems();
  bool roomRunning = false;
  String? roomSpeaking;
  Map<String, Object?> memory = sampleMemory();
  Map<String, Object?> usage = sampleUsage();

  StreamController<DsBotSseEvent>? _feed;
  int feedOpens = 0;

  /// Feed connections say hello unless this is false.
  bool helloOnFeed = true;

  Map<String, Object?> helloAnswer() => {
    'api': 1,
    'apiMin': 1,
    'apiMax': 1,
    'plugin': {'name': 'ds-bot', 'version': '0.2.0'},
    'capabilities': [
      'state',
      'avatar',
      'chat',
      'room-chat',
      'send',
      'feed',
      'feed-room',
      'notices',
      'memory',
      'memory-edit',
      'usage-summary',
    ],
    'boot': 'boot-1',
    'seq': 0,
    'revision': 7,
    'readOnly': null,
    'memory': true,
  };

  List<String> get endpoints => [for (final c in calls) c.$1];

  @override
  Future<Object?> call(String endpoint, Map<String, Object?> payload, {Duration? timeout}) async {
    calls.add((endpoint, payload));
    final handler = handlers[endpoint];
    if (handler == null) throw DshRemoteException('bot/not-found', 'Unknown endpoint $endpoint');
    return handler(payload);
  }

  @override
  Stream<DsBotSseEvent> openFeed() {
    feedOpens += 1;
    final controller = StreamController<DsBotSseEvent>();
    _feed = controller;
    if (helloOnFeed) {
      controller.add(const DsBotSseEvent('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 0}));
    }
    return controller.stream;
  }

  void emit(String event, Map<String, Object?> data) => _feed?.add(DsBotSseEvent(event, data));

  Future<void> dropFeed() async => _feed?.close();

  @override
  Future<void> close() async => _feed?.close();
}

/// Records what would reach the system tray.
class RecordingNotifyChannel extends NotifyChannel {
  final List<NotifyPost> shown = [];
  final List<String> cancelledGroups = [];

  @override
  Future<void> show(NotifyPost post) async => shown.add(post);

  @override
  Future<void> cancelGroup(String group) async => cancelledGroups.add(group);

  @override
  Future<void> cancel(String group, String key) async {}
}

/// DS Bot on 本机 through [transport].
List<Override> dsBotOverrides(FakeDsBotTransport transport, {NotifyChannel? notify, HostConnection? connection}) => [
  activeConnectionProvider.overrideWithValue(AsyncData(connection ?? fakeConnection)),
  dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(transport)),
  localSafeModeProvider.overrideWithValue(false),
  if (notify != null) notifyChannelProvider.overrideWithValue(notify),
];

const tinyPhoto =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAB20lEQVR4nA3LoRGGIBiA4X8FVzDZdQADkeqdA3hkmoUBvgEoNLLHANxRDW8gOACu4Ar+Pv35/Qa6gX5gHFADy4AZ2AdkIAwcA2WgDtwDz8A78PtNdBP9xDihJpYJM7FPyESYOCbKRJ24J56Jd/rCTDfTz4wzamaZMTP7jMyEmWOmzNSZe+aZeecvaDpNrxk1SrNojGbXiCZoDk3RVM2teTSv/sJKt9KvjCtqZVkxK/uKrISVY6Ws1JV75Vl51y9sdBv9xrihNpYNs7FvyEbYODbKRt24N56Nd/uCpbP0ltGiLIvFWHaLWILlsBRLtdyWx/LaLzg6R+8YHcqxOIxjd4gjOA5HcVTH7Xgcr/uC0Am9MApKWAQj7IIIQTiEIlThFh7hlS94Ok/vGT3Ks3iMZ/eIJ3gOT/FUz+15PK//QqSL9JExoiJLxET2iERC5IiUSI3ckSfyxi8kukSfGBMqsSRMYk9IIiSOREnUxJ14Em/6QqbL9JkxozJLxmT2jGRC5siUTM3cmSfz5i+cdCf9yXiiTpYTc7KfyEk4OU7KST25T56T9/zCRXfRX4wX6mK5MBf7hVyEi+OiXNSL++K5eK8vNLpG3xgbqrE0TGNvSCM0jkZp1MbdeBpv4w9hucmQU0mAqQAAAABJRU5ErkJggg==';

/// Chief (Main, working), Writer, Coder with a photo, and one group.
Map<String, Object?> sampleTeam({bool working = true, Map<String, Object?> questions = const {}}) {
  // Before any of today's messages whatever the clock says, so the list order
  // (newest activity first) does not depend on when the test runs.
  final now = todayAt(0, 0).millisecondsSinceEpoch;
  return {
    'revision': 7,
    'mainBotIds': ['m1'],
    'bots': [
      {
        'id': 'm1',
        'name': 'Chief',
        'role': '总管',
        'color': 'deepseek',
        'sessionId': 'm1c',
        'parts': ['m1'],
        'model': 'deepseek/deepseek-v4-pro',
        'effort': 'high',
        'createdAt': now - 86400000,
      },
      {
        'id': 'b2',
        'name': 'Writer',
        'role': '写手',
        'color': 'violet',
        'sessionId': 'b2',
        'model': 'deepseek/deepseek-v4-flash',
        'createdAt': now - 3600000,
      },
      {
        'id': 'b3',
        'name': 'Coder',
        'role': '程序员',
        'avatar': {'imageRef': 'abc123'},
        'sessionId': 'b3',
        'model': 'deepseek/deepseek-v4-pro',
        'createdAt': now - 7200000,
      },
    ],
    'rooms': [
      {
        'id': 'r1',
        'name': '发布会',
        'members': ['m1', 'b2', 'b3'],
        'admin': 'm1',
        'mode': 'admin',
        'notice': '周五前交初稿',
        'preview': 'Writer：初稿写好了，放在 docs/launch.md',
        'parts': ['g1', 'g2', 'g3'],
        'createdAt': now - 1800000,
      },
    ],
    'questions': questions,
    'views': <String, Object?>{},
    'models': [
      {'ref': 'deepseek/deepseek-v4-pro', 'name': 'DeepSeek-V4-Pro', 'providerName': 'DeepSeek'},
      {'ref': 'deepseek/deepseek-v4-flash', 'name': 'DeepSeek-V4-Flash', 'providerName': 'DeepSeek'},
    ],
    'defaultModel': 'deepseek/deepseek-v4-flash',
    'modelsKey': 'k1',
    'memory': true,
    'readOnly': null,
    // Kept so the live-only answer to a later read says the same.
    'working': working,
    ...liveOf({'working': working}),
  };
}

Map<String, Object?> liveOf(Map<String, Object?> data, {List<Object?> approvals = const []}) {
  final working = data['working'] != false;
  final now = botClock().millisecondsSinceEpoch;
  return {
    'revision': data['revision'] ?? 7,
    'activity': working ? {'m1': 'tool'} : <String, Object?>{},
    'work': {
      'bots': working
          ? {
              'm1': {'since': now - 40000, 'tool': 'bash', 'note': '运行测试'},
            }
          : <String, Object?>{},
      'rooms': <String, Object?>{},
      'approvals': approvals,
    },
  };
}

List<Object?> sampleChat() {
  final base = todayAt(14, 2).millisecondsSinceEpoch;
  return [
    {'kind': 'user', 'text': '帮我看看发布会的准备进度', 'time': base},
    {
      'kind': 'bot',
      'text': '好的。我刚问过 Writer，初稿已经写好了，放在 `docs/launch.md`。\n\n还差两件事：\n\n1. 海报的文案\n2. 现场演示的脚本',
      'time': base + 60000,
    },
    {'kind': 'event', 'role': 'reply', 'botId': 'b2', 'name': 'Writer', 'time': base + 90000},
    {'kind': 'bot', 'text': 'Writer 说海报文案今晚能给出。要我先把演示脚本交给 Coder 吗？', 'time': base + 120000},
  ];
}

List<Object?> sampleRoomItems() {
  final base = todayAt(15, 10).millisecondsSinceEpoch;
  return [
    {'id': '1', 'kind': 'user', 'text': '周五的发布会，大家分一下工', 'time': base},
    {
      'id': 'c1:0',
      'kind': 'bot',
      'botId': 'm1',
      'name': 'Chief',
      'text': '@Writer 写初稿，@Coder 准备演示环境。',
      'time': base + 30000,
    },
    {'id': 'c1:1', 'kind': 'event', 'event': 'working', 'botId': 'b2', 'name': 'Writer', 'time': base + 40000},
    {'id': 'c1:2', 'kind': 'bot', 'botId': 'b2', 'name': 'Writer', 'text': '收到，我先列个提纲。', 'time': base + 50000},
    {
      'id': 'c1:3',
      'kind': 'bot',
      'botId': 'b2',
      'name': 'Writer',
      'text': '初稿写好了，放在 `docs/launch.md`。',
      'time': base + 60000,
    },
    {'id': 'c1:4', 'kind': 'event', 'event': 'done', 'botId': 'b2', 'name': 'Writer', 'time': base + 70000},
  ];
}

Map<String, Object?> sampleMemory() => {
  'entries': [
    {'scope': 'own', 'topic': null, 'text': '回复尽量简短，先说结论', 'added': '2026-10-20', 'by': 'user'},
    {'scope': 'own', 'topic': null, 'text': '发布会定在周五下午三点', 'added': '2026-10-22'},
    {'scope': 'team', 'topic': null, 'text': '代码放在 ~/work/launch', 'added': '2026-10-23'},
  ],
  'summary': {'text': '喜欢简短的回复；发布会在周五下午。', 'at': 1},
};

Map<String, Object?> sampleUsage() => {
  'day': {'input': 120000, 'cacheRead': 300000, 'cacheWrite': 0, 'output': 8000, 'calls': 12},
  'week': {'input': 820000, 'cacheRead': 2100000, 'cacheWrite': 0, 'output': 51000, 'calls': 88},
  'month': {'input': 2400000, 'cacheRead': 6100000, 'cacheWrite': 0, 'output': 160000, 'calls': 260},
  'models': [
    {'key': 'deepseek/deepseek-v4-pro', 'name': 'DeepSeek-V4-Pro', 'input': 2400000, 'output': 160000, 'calls': 260},
  ],
};

/// A container with DS Bot over [transport]; read [dsBotProvider] to start it.
ProviderContainer dsBotContainer(FakeDsBotTransport transport, {NotifyChannel? notify}) {
  final container = ProviderContainer(overrides: dsBotOverrides(transport, notify: notify));
  return container;
}

/// Lets the fake's futures and the feed's events run.
Future<void> settle([int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pins both the displayed time and sample dates, away from their "just now" windows.
void useBotGoldenClock() {
  final previous = botClock;
  botClock = () => DateTime(2026, 10, 24, 18);
  addTearDown(() => botClock = previous);
}

/// A time on the same calendar day as the Bot timestamp formatter.
DateTime todayAt(int hour, int minute) {
  final now = botClock();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

const sampleApprovals = <Object?>[
  {
    'id': 'a1',
    'sessionId': 'member-session',
    'botId': 'b2',
    'roomId': 'r1',
    'tool': 'bash',
    'reason': '运行测试',
    'answerable': true,
  },
  {
    'id': 'a2',
    'sessionId': 'other-session',
    'botId': 'b3',
    'roomId': 'r1',
    'tool': 'bash',
    'reason': '其他审批',
    'answerable': false,
  },
];

FakeDsBotTransport approvalTransport({bool readOnly = false}) {
  final data = sampleTeam(working: false);
  data.addAll(liveOf(data, approvals: sampleApprovals));
  if (readOnly) data['readOnly'] = '另一个 DSH 正在使用这个团队';
  final transport = FakeDsBotTransport(team: data);
  transport.handlers['state'] = (_) => data;
  transport.handlers['approval-answer'] = (_) => true;
  return transport;
}
