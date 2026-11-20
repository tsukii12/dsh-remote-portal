// The feedback widgets: 「来自 ui.json」 + 「恢复默认」, the quiet 「界面配置」
// row and its sheet, the remote skill install entry. Goldens in light and
// dark for the row pair and both sheets.

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show goldenApp, goldenBoth, usePhoneSurface;
import 'support.dart';

const _ssh = HostRef.portal('pc');

const _sample = '''
{
  "version": 1,
  "theme": { "mode": "dark", "accentPreset": "daiqing" },
  "density": "cozy",
  "hide": ["turnFooter", "everything"],
  "composer": { "quickActions": [
    { "label": "总结", "action": { "type": "send", "text": "总结上面的对话" } },
    { "label": "链接", "action": { "type": "link", "url": "http://example.com" } },
    { "label": "超过十个字的标签啊啊啊", "action": { "type": "send", "text": "x" } }
  ] }
}
''';

/// A settings card the way a settings page uses the pieces: a switch row greyed out
/// with the tag before its control, and the status row.
class _Page extends ConsumerWidget {
  const _Page();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(uiSettingEntryProvider(UiSettingKey.themeMode)) != null;
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.only(top: 80),
        children: [
          SettingsSection(
            title: '外观',
            children: [
              SettingsTile(
                title: '深色模式',
                tinted: false,
                value: const FromUiJsonBadge(UiSettingKey.themeMode),
                trailing: Switch(value: true, onChanged: locked ? null : (_) {}),
              ),
              const SettingsTile(title: '紧凑排列', tinted: false, value: FromUiJsonBadge(UiSettingKey.density)),
              const UiConfigStatusTile(),
            ],
          ),
        ],
      ),
    );
  }
}

class _Installer implements UiSkillRemoteInstaller {
  final installs = <(HostRef, UiSkillBundle)>[];

  @override
  Future<bool> install(BuildContext context, HostRef host, UiSkillBundle bundle) async {
    installs.add((host, bundle));
    return true;
  }
}

List<Override> _overrides(FakeUiSource source, {HostRef host = HostRef.none, List<Override> extra = const []}) => [
  ...sourceOverrides({host: source}, active: host),
  ...extra,
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpPage(
    WidgetTester tester,
    FakeUiSource source, {
    HostRef host = HostRef.none,
    List<Override> extra = const [],
  }) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const _Page(),
        brightness: Brightness.light,
        overrides: _overrides(source, host: host, extra: extra),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no ui.json: no tags, no row', (tester) async {
    final source = FakeUiSource()..push(const UiConfigAbsent());
    await pumpPage(tester, source);
    expect(find.text(fromUiJsonLabel), findsNothing);
    expect(find.byKey(const ValueKey('ui-config-status')), findsNothing);
  });

  testWidgets('the tag marks what ui.json sets; 恢复默认 sets it aside', (tester) async {
    final source = FakeUiSource()..text('{"version": 1, "theme": {"mode": "dark"}, "density": "compact"}');
    await pumpPage(tester, source);
    expect(find.text(fromUiJsonLabel), findsNWidgets(2));
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull, reason: 'greyed out while ui.json decides');
    expect(find.widgetWithText(SettingsTile, '已应用 2 项'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('from-ui-json-theme.mode')));
    await tester.pumpAndSettle();
    expect(find.text('/theme/mode'), findsOneWidget);
    expect(find.text('外观模式'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ui-json-restore-default')));
    await tester.pumpAndSettle();

    expect(find.byType(UiOverrideSheet), findsNothing);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsNothing);
    expect(find.byKey(const ValueKey('from-ui-json-density')), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UiIgnoresController.prefsKey), contains('theme.mode'));
  });

  testWidgets('the row counts what did not apply; its sheet lists each with its pointer', (tester) async {
    final source = FakeUiSource()..text(_sample);
    await pumpPage(tester, source);
    expect(find.widgetWithText(SettingsTile, '3 处没生效'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ui-config-status')));
    await tester.pumpAndSettle();
    expect(find.byType(UiConfigIssuesSheet), findsOneWidget);
    expect(find.text('ui.json · 已应用 4 项 · 3 处没生效'), findsOneWidget);
    expect(find.text('没生效'), findsOneWidget);
    expect(find.text('提示'), findsOneWidget);
    expect(find.text('/composer/quickActions/1/action/url'), findsOneWidget);
    expect(find.text('只支持 https 链接'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.tap(find.byTooltip('复制'));
    await tester.pumpAndSettle();
    expect(copied, contains('/density：不支持的值「cozy」'));
    expect(copied!.split('\n'), hasLength(4));
  });

  testWidgets('a broken file: 没有生效, and the sheet says the previous config is kept', (tester) async {
    final source = FakeUiSource()..text('{"version": 1, "density": "compact"}');
    await pumpPage(tester, source);
    source.text('{"version": 1, "density": "compact",}');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SettingsTile, '没有生效'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ui-config-status')));
    await tester.pumpAndSettle();
    expect(find.text('ui.json · 没有生效，仍在用上一次的配置'), findsOneWidget);
    expect(find.text('第 1 行第 36 列：多余的逗号'), findsOneWidget);
  });

  testWidgets('a remote host without the skill offers to install it, after a confirmation', (tester) async {
    final installer = _Installer();
    final source = FakeUiSource()..push(const UiConfigAbsent(skillMissing: true));
    await pumpPage(
      tester,
      source,
      host: _ssh,
      extra: [
        uiSkillRemoteInstallerProvider.overrideWithValue(installer),
        uiSkillBundleLoaderProvider.overrideWithValue(
          () async => UiSkillBundle({'SKILL.md': '---\nname: dsh-go-ui\n---\n'}),
        ),
      ],
    );
    expect(find.widgetWithText(SettingsTile, '未安装技能'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ui-config-status')));
    await tester.pumpAndSettle();
    expect(find.text('安装界面技能'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ui-skill-install')));
    await tester.pumpAndSettle();
    expect(installer.installs.single.$1, _ssh);
    expect(installer.installs.single.$2.files.keys, ['SKILL.md']);
  });

  testWidgets('without an installer the remote row stays hidden', (tester) async {
    final source = FakeUiSource()..push(const UiConfigAbsent(skillMissing: true));
    await pumpPage(tester, source, host: _ssh);
    expect(find.byKey(const ValueKey('ui-config-status')), findsNothing);
  });

  goldenBoth('ui_config_rows', () => const _Page(), overrides: () => _overrides(FakeUiSource()..text(_sample)));

  goldenBoth(
    'ui_config_issues_sheet',
    () => const _Page(),
    overrides: () => _overrides(FakeUiSource()..text(_sample)),
    before: (tester) async {
      await tester.tap(find.byKey(const ValueKey('ui-config-status')));
      await tester.pumpAndSettle();
    },
  );

  goldenBoth(
    'ui_config_override_sheet',
    () => const _Page(),
    overrides: () => _overrides(FakeUiSource()..text(_sample)),
    before: (tester) async {
      await tester.tap(find.byKey(const ValueKey('from-ui-json-theme.mode')));
      await tester.pumpAndSettle();
    },
  );
}
