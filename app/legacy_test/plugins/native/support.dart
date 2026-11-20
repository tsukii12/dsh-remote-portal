// Test bed for the native plugin slots: a fake bridge (contributions, views,
// taps, a stream over a fake socket that says `welcome`), and the overrides
// every slot test shares.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// A socket that answers `hello` with `welcome` (conn `c1`) and records
/// what the app sent.
class FakeSocket implements DshGoSocket {
  FakeSocket({this.conn = 'c1'});

  final String? conn;
  final _in = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];
  int? closedWith;

  @override
  Stream<Object?> get messages => _in.stream;

  @override
  void send(String text) {
    final message = jsonDecode(text) as Map<String, Object?>;
    sent.add(message);
    if (message['t'] == 'hello') push({'t': 'welcome', 'v': 1, 'bridge': '0.3.0', 'hb': 25, 'conn': ?conn});
  }

  @override
  Future<void> close([int? code]) async {
    closedWith = code;
    if (!_in.isClosed) await _in.close();
  }

  void push(Map<String, Object?> message) {
    if (!_in.isClosed) _in.add(jsonEncode(message));
  }

  /// The last `sub` frame for [id], if any.
  Map<String, Object?>? subOf(String id) => sent.where((m) => m['t'] == 'sub' && m['id'] == id).lastOrNull;
}

/// The host's dsh-go bridge, scripted.
class FakeBridge implements NativeBridge {
  FakeBridge([this.raw]);

  DshGoContributions? raw;
  final views = <String, DshGoView>{};
  final invocations = <DshGoInvocation>[];
  final sockets = <FakeSocket>[];
  int contributionReads = 0;

  /// What a tap answers; nothing by default.
  FutureOr<DshGoInvokeResult> Function(DshGoInvocation invocation)? answer;

  FakeSocket get socket => sockets.last;

  @override
  Future<DshGoContributions?> contributions(DshGoCaps caps, {DshGoContributions? previous}) async {
    contributionReads++;
    return raw;
  }

  @override
  Future<DshGoView> view(String pkg, String id, {DshGoScope scope = DshGoScope.none, required DshGoCaps caps}) async {
    final view = views['$pkg/$id'];
    if (view == null) throw const DshRemoteException('dsh-go/not-found', 'unknown panel');
    return view;
  }

  @override
  Future<DshGoInvokeResult> invoke(DshGoInvocation invocation) async {
    invocations.add(invocation);
    return await answer?.call(invocation) ?? const DshGoInvokeResult();
  }

  @override
  DshGoStream openStream({String? locale}) => DshGoStream(() async {
    final s = FakeSocket();
    sockets.add(s);
    return s;
  }, locale: locale);

  @override
  ImageProvider? asset(String pkg, String path) => null;
}

class FixedBundles extends InstalledPluginsController {
  FixedBundles(this.bundles);
  final List<PluginBundle>? bundles;

  @override
  Future<List<PluginBundle>?> build() async => bundles;
}

class LocalHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
}

/// Contributions from protocol-shaped JSON plugins.
DshGoContributions contributions(List<Map<String, Object?>> plugins, {String rev = 'r1'}) =>
    DshGoContributions.fromJson({'v': 1, 'bridge': '0.3.0', 'rev': rev, 'limits': {}, 'plugins': plugins})!;

/// One plugin as the bridge lists it.
Map<String, Object?> plugin(
  String pkg, {
  String? title,
  String? icon,
  List<String> wants = const [],
  String state = 'ok',
  List<Map<String, Object?>> composer = const [],
  List<Map<String, Object?>> menu = const [],
  List<Map<String, Object?>> strip = const [],
  List<Map<String, Object?>> panels = const [],
  List<Map<String, Object?>> issues = const [],
}) => {
  'pkg': pkg,
  'version': '1.0.0',
  'title': title ?? pkg,
  'icon': ?icon,
  'wants': wants,
  'state': state,
  'native': state == 'ok',
  'contributes': {
    'composer.actions': [
      for (final a in composer) {'ready': true, ...a},
    ],
    'message.actions': [
      for (final a in menu) {'ready': true, ...a},
    ],
    'composer.strip': [
      for (final s in strip) {'ready': true, ...s},
    ],
    'panels': [
      for (final p in panels)
        {
          'ready': true,
          'live': false,
          'placement': ['session.tab'],
          ...p,
        },
    ],
  },
  'issues': issues,
};

/// The quick-actions plugin of the examples: two capsules, two menu items.
Map<String, Object?> quickPlugin({List<String> wants = const []}) => plugin(
  'dsh-go-example-quick',
  title: '快捷指令',
  icon: 'bolt',
  wants: wants,
  composer: [
    {'id': 'translate', 'label': '译成英文', 'icon': 'translate'},
    {
      'id': 'hello',
      'label': '打招呼',
      'effect': [
        {'type': 'insert', 'text': '你好'},
      ],
    },
  ],
  menu: [
    {'id': 'speak', 'label': '朗读', 'icon': 'speaker'},
    {'id': 'summary', 'label': '要点', 'icon': 'summary'},
  ],
);

/// The usage plugin of the examples: a status line and a panel.
Map<String, Object?> usagePlugin({List<String> placement = const ['session.tab', 'features']}) => plugin(
  'dsh-go-example-usage',
  title: '用量',
  icon: 'chart',
  strip: [
    {'id': 'cost', 'icon': 'coin', 'panel': 'usage', 'tappable': true, 'live': true},
  ],
  panels: [
    {'id': 'usage', 'title': '用量', 'icon': 'chart', 'placement': placement, 'live': true},
  ],
);

/// The overrides a slot test needs.
List<Override> nativeOverrides(
  FakeBridge bridge, {
  List<UiQuickAction>? quick,
  List<PluginBundle>? bundles = const [],
  DateTime Function()? clock,
}) => [
  nativeBridgeProvider.overrideWithValue(bridge),
  activeHostProvider.overrideWith(LocalHost.new),
  installedPluginsProvider.overrideWith(() => FixedBundles(bundles)),
  uiOverridesProvider.overrideWithValue(
    UiOverrides(
      host: HostRef.none,
      config: UiConfig(quickActions: quick),
    ),
  ),
  if (clock != null) nativeClockProvider.overrideWithValue(clock),
];

/// A composer the controls can write into.
class FakeComposer implements NativeComposerHost {
  FakeComposer({this.sessionId = 's1', this.draft = ''});

  @override
  final String? sessionId;
  @override
  final Object draftOwner = Object();
  @override
  String draft;
  final inserted = <String>[];
  BuildContext? hostContext;

  @override
  void insert(String text) => inserted.add(text);

  @override
  BuildContext? get context => hostContext;
}

/// [child] under a [NativeComposerScope] lending [composer].
Widget withComposer(FakeComposer composer, Widget child) => Consumer(
  builder: (context, ref, _) {
    composer.hostContext = context;
    return NativeComposerScope(host: composer, ref: ref, child: child);
  },
);

/// Lets a widget subtree build [child] with a [WidgetRef].
Widget withRef(Widget Function(WidgetRef ref) child) => Consumer(builder: (context, ref, _) => child(ref));
