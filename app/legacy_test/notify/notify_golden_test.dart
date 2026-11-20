// Golden screenshots of the notification UI, light and dark: the in-app
// banner (every kind, and in place over a page) and 设置 → 通知.
//
//   flutter test --update-goldens test/notify/notify_golden_test.dart

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/notify/chat_alert_host.dart';
import 'package:dsh_app/ui/settings/notification_settings.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

class _FixedAlerts extends ChatAlertsController {
  _FixedAlerts(this.alert);

  final ChatAlert? alert;

  @override
  ChatAlert? build() => alert;
}

class _FixedPrefs extends NotifyPrefsController {
  _FixedPrefs(this.prefs);

  final NotifyPrefs prefs;

  @override
  NotifyPrefs build() => prefs;
}

const _approval = ChatAlert(
  host: HostRef.none,
  sessionId: 's1',
  kind: AlertKind.approval,
  key: 'e1',
  title: '修复登录按钮重复提交',
  text: '等你确认：运行命令 · flutter test test/auth --reporter compact',
  eventId: 'e1',
);

const _gallery = [
  ChatAlert(
    host: HostRef.none,
    sessionId: 's2',
    kind: AlertKind.done,
    key: turnKey,
    title: '给设置页加深色模式',
    text: '已完成 · 深色模式已经接上系统设置，切换时不会闪白。改了 theme.dart 和 settings_screen.dart 两个文件，测试都过了。',
  ),
  _approval,
  ChatAlert(
    host: HostRef.none,
    sessionId: 's3',
    kind: AlertKind.question,
    key: 'q1',
    title: '数据库选型',
    text: '问你：用 SQLite 还是 Postgres？（共 2 个）',
  ),
  ChatAlert(
    host: HostRef.none,
    sessionId: 's4',
    kind: AlertKind.failed,
    key: turnKey,
    title: '整理 Flutter 3.47 的新特性',
    text: '出错了 · 还没有配置 DeepSeek API Key',
  ),
  ChatAlert(
    host: HostRef.none,
    sessionId: 's5',
    kind: AlertKind.stopped,
    key: turnKey,
    title: '把 README 翻译成英文',
    text: '已停止',
  ),
];

void _golden(String name, Widget Function() home, {List<Override> Function()? overrides}) {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(loadTestFonts);
      usePhoneView(tester);
      await tester.pumpWidget(testApp(home(), brightness: brightness, overrides: overrides?.call() ?? const []));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}

List<Override> _settings({NotifySystemStatus system = const NotifySystemStatus(), NotifyPrefs? prefs}) => [
  notifySystemStatusProvider.overrideWith((ref) async => system),
  notifyPrefsProvider.overrideWith(() => _FixedPrefs(prefs ?? const NotifyPrefs(loaded: true))),
];

/// Every kind of banner on a busy backdrop (so the glass has something to blur).
class _Gallery extends StatelessWidget {
  const _Gallery();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBackdrop(
      child: Stack(
        children: [
          // Lines behind the glass.
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 80, 24, 0),
              child: Text(
                '这里是对话内容。' * 60,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
              children: [
                for (final alert in _gallery) ...[AlertBanner(alert: alert, onTap: () {}), const SizedBox(height: 12)],
                AlertBanner(
                  alert: const ChatAlert(
                    host: HostRef.portal('lab'),
                    sessionId: 'r1',
                    kind: AlertKind.done,
                    key: turnKey,
                    title: '服务器上跑回归测试',
                    text: '已完成 · 312 个用例全部通过',
                  ),
                  hostName: hostLabel(HostKind.portal, '实验室'),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置 → 对话 → 通知 in its three states, each in its own scope.
class _TileGallery extends StatelessWidget {
  const _TileGallery();

  @override
  Widget build(BuildContext context) {
    Widget tile(String label, List<Override> overrides) => SheetGroup(
      margin: kSettingsGroupMargin,
      title: label,
      children: [ProviderScope(overrides: overrides, child: const NotificationSettingsTile())],
    );
    return AppBackdrop(
      child: SafeArea(
        child: ListView(
          children: [
            tile('开启', _settings()),
            tile('系统关闭了通知', _settings(system: const NotifySystemStatus(enabled: false))),
            tile('在 App 里关闭', _settings(prefs: const NotifyPrefs(enabled: false, loaded: true))),
          ],
        ),
      ),
    );
  }
}

void main() {
  _golden('notify_banners', () => const _Gallery());

  _golden('notify_tile', () => const _TileGallery());

  // The real slot: under the status bar, over whatever page is open.
  _golden(
    'notify_banner_over_page',
    () => const Stack(children: [NotificationSettingsPage(), AlertBannerLayer()]),
    overrides: () => [..._settings(), chatAlertsProvider.overrideWith(() => _FixedAlerts(_approval))],
  );

  _golden('notify_settings', () => const NotificationSettingsPage(), overrides: _settings);

  _golden(
    'notify_settings_blocked',
    () => const NotificationSettingsPage(),
    overrides: () => _settings(system: const NotifySystemStatus(enabled: false)),
  );

  _golden(
    'notify_settings_off',
    () => const NotificationSettingsPage(),
    overrides: () => _settings(prefs: const NotifyPrefs(enabled: false, loaded: true)),
  );
}
