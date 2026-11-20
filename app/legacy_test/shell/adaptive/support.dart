// The home screen (HomeShell + the real ChatScreen) on tablet and foldable
// windows, with every provider it reads faked: the synthetic timed
// conversation of test/chat/support/run_info_fixture.dart as 's1', a list of
// conversations for the sidebar, the layout choices fixed.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/bots_state.dart' show dsBotApiFactoryProvider;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart' show drawerClockProvider;
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/widgets/live_clock.dart' show runClock;
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';
import '../../chat/support/run_info_fixture.dart';
import '../../notify/support.dart';
import '../golden_harness.dart' show sampleNow;

const statusBar = 24.0;
const gestureBar = 16.0;

/// A window [size] logical pixels at DPR 2, status bar and gesture bar in,
/// [left] / [right] for a cutout or a side navigation bar.
void useWindow(WidgetTester tester, Size size, {double left = 0, double right = 0}) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  final padding = FakeViewPadding(left: left * 2, top: statusBar * 2, right: right * 2, bottom: gestureBar * 2);
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
}

/// Fixed choices; toggles change them for the test's run only.
class FixedLayoutPrefs extends LayoutPrefsController {
  FixedLayoutPrefs(this.initial);

  final LayoutPrefs initial;

  @override
  LayoutPrefs build() => initial;

  @override
  Future<void> setPanelOpen(bool open) async => state = state.copyWith(panelOpen: open);

  @override
  Future<void> setSidebarOpen(bool open) async => state = state.copyWith(sidebarOpen: open);

  @override
  Future<void> togglePanel() => setPanelOpen(!state.panelOpen);
}

/// The drawer's workspace switcher would open a socket on the fake host.
class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState();
}

class _Panels extends SessionPanelsController {
  _Panels(super.sessionId);

  @override
  SessionPanels build() => SessionPanels.empty;
}

class _Sessions extends SessionsController {
  _Sessions(this.sessions);

  final List<SessionSummary> sessions;

  @override
  Future<List<SessionSummary>> build() async => sessions;

  @override
  Future<void> refresh() async {}
}

SessionSummary _session(String id, String title, DateTime at, {bool running = false}) => SessionSummary(
  sessionId: id,
  updatedAt: at,
  running: running,
  blank: false,
  agentAvailable: running,
  cwd: '/root/workspace',
  projections: SessionProjections(1, {'title': title}),
);

/// Today / yesterday / earlier, anchored to the drawer's pinned day
/// ([sampleNow]).
List<SessionSummary> sampleSessions() {
  final midnight = DateTime(sampleNow.year, sampleNow.month, sampleNow.day);
  return [
    _session('s1', '修复登录重复提交', midnight.add(const Duration(seconds: 3)), running: true),
    _session('s2', '给设置页加深色模式', midnight.add(const Duration(seconds: 2))),
    _session('s3', '解释 proot 的 link2symlink', midnight.add(const Duration(seconds: 1))),
    _session('s4', '重构 sessions_state 的刷新逻辑', midnight.subtract(const Duration(hours: 3))),
    _session('s5', '写一个解析 tar.xz 的 Kotlin 工具', midnight.subtract(const Duration(hours: 9))),
    _session('s6', 'DeepSeek API 计费怎么算', midnight.subtract(const Duration(days: 3))),
    _session('s7', '把 README 翻译成英文', midnight.subtract(const Duration(days: 6))),
  ];
}

const sampleUsage = SessionUsage(
  uncachedInput: 10446,
  cacheRead: 126208,
  output: 2532,
  pressureTokens: 21800,
  contextWindow: 1000000,
  systemTokens: 1467,
  toolsTokens: 5157,
  messageTokens: 15176,
  turns: 2,
);

List<Override> homeOverrides({
  String? session = 's1',
  LayoutPrefs prefs = const LayoutPrefs(loaded: true),
  ChatState Function(String id)? chat,
}) => [
  activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
  localConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
  localRuntimeProvider.overrideWith(StaticRuntime.new),
  modelCatalogProvider.overrideWith((ref) async => testCatalog),
  attachmentPickerProvider.overrideWithValue(FakePicker()),
  settingsProvider.overrideWith(() => TestSettings()),
  balanceFetcherProvider.overrideWithValue((key) async => healthyBalance),
  hostCommandsProvider.overrideWith((ref, id) async => testHostCommands),
  sessionUsageProvider.overrideWith2((id) => FakeUsage(id, sampleUsage)),
  sessionsProvider.overrideWith(() => _Sessions(sampleSessions())),
  drawerClockProvider.overrideWithValue(() => sampleNow),
  currentSessionProvider.overrideWith(() => FixedSession(session)),
  chatProvider.overrideWith2(
    (id) => FakeChatController(id, chat?.call(id) ?? (id == 's1' ? runInfoState() : const ChatState(loading: false))),
  ),
  sessionPanelsProvider.overrideWith2(_Panels.new),
  layoutPrefsProvider.overrideWith(() => FixedLayoutPrefs(prefs)),
  // The shell's hosts: no sockets, no native side.
  workspacesProvider.overrideWith(_Workspaces.new),
  dsBotApiFactoryProvider.overrideWithValue((_) => null),
  notifyChannelProvider.overrideWithValue(FakeNotifyChannel()),
  alertSourceFactoryProvider.overrideWithValue((_) => FakeAlertSource()),
];

/// The home screen with the real chat.
Widget homeApp({
  Brightness brightness = Brightness.light,
  String? session = 's1',
  LayoutPrefs prefs = const LayoutPrefs(loaded: true),
  ChatState Function(String id)? chat,
}) => testApp(
  HomeShell(chatBuilder: (openDrawer) => ChatScreen(onOpenDrawer: openDrawer, backdrop: false)),
  brightness: brightness,
  overrides: homeOverrides(session: session, prefs: prefs, chat: chat),
);

/// Fixed clocks, as the session detail goldens use.
void freezeClocks() {
  chatClock = () => DateTime(2026, 10, 23, 15, 20);
  runClock = () => runInfoTestDispatched.add(const Duration(milliseconds: 12300));
}

void thawClocks() {
  chatClock = DateTime.now;
  runClock = DateTime.now;
}
