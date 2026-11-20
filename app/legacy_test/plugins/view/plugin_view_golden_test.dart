// Gallery of native plugin views: the six new blocks, a bound panel, the
// interactive pieces, the broken and read-only states, and tool cards in the
// chat stream; light and dark, plus an English set. Look at every image after
// regenerating (`--update-goldens`).

import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';
import '../../support/english_preview.dart';
import 'fixtures.dart';

Future<bool> _ok(PluginAction _) async => true;

/// Images decode off the fake clock: give them real time, then draw.
Future<void> settleImages(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _noRespond(ApprovalRequest _, ApprovalDecision _) async {}

Widget framed(String name, Object view, {Object? data, String? icon, Widget? trailing, bool interactive = true}) =>
    PluginFrame(
      pluginName: name,
      icon: icon,
      trailing: trailing,
      child: PluginView(view: view, data: data, onAction: interactive ? _ok : null),
    );

Widget sheet(List<Widget> children) => AppBackdrop(
  child: SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 56, 16, 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 24), children[i]],
      ],
    ),
  ),
);

class _RefreshKey extends StatelessWidget {
  const _RefreshKey();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: Icon(AppIcons.refresh, size: 18, color: DshColors.of(context).textTertiary),
  );
}

ToolChatItem pluginTool(String id, Object? view, {String city = '东京', String result = '{"ok":true}'}) =>
    tool(id, 'weather', {'city': city, 'days': 3}, result: result, meta: {'dsh-go/view': view, 'other': 1});

/// Tool rows the way the chat lays them out (StreamRow insets).
Widget toolRows(List<ToolChatItem> items) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [for (final item in items) ToolRow(key: ValueKey(item.callId), item: item, onRespond: _noRespond)],
);

final _sheets = <String, (double, List<Widget> Function())>{
  'blocks': (
    1720,
    () => [
      framed('日程助手', listView, icon: 'calendar'),
      framed('用量', keyValueView, icon: 'wallet'),
      framed('同步', progressView, icon: 'refresh'),
      framed('账单', tableView),
      framed('订阅', actionsView, icon: 'wallet'),
      framed('相册', imageView, icon: 'image'),
    ],
  ),
  'panel': (
    1420,
    () => [
      framed('用量', usagePanel, data: usageData, icon: 'chart', trailing: const _RefreshKey()),
      framed('报表', choiceView, data: {'range': '30d'}, icon: 'chart'),
      framed('日历', textView, icon: 'calendar'),
    ],
  ),
  'states': (
    1380,
    () => [
      framed('部分有误', partlyBroken, data: const {}),
      framed('用量', usagePanel, data: const {}, icon: 'chart'),
      // Read-only (no invoke channel): no buttons, options ticked only.
      framed('报表', choiceView, data: {'range': '7d'}, interactive: false),
      framed('坏掉的插件', {'type': 'gauge'}),
      PluginFrame(
        pluginName: '状态条',
        surface: false,
        child: PluginView(view: usagePanel, data: usageData, budget: PluginViewBudget.strip),
      ),
    ],
  ),
};

void main() {
  setUpAll(loadTestFonts);

  for (final MapEntry(key: name, value: (height, build)) in _sheets.entries) {
    for (final brightness in Brightness.values) {
      final suffix = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('plugin view $name ($suffix)', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = Size(780, height * 2);
        await tester.pumpWidget(testApp(Scaffold(body: sheet(build())), brightness: brightness));
        await settleImages(tester);
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/plugin_view_${name}_$suffix.png'));
      });
    }
  }

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('tool cards ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 1500 * 2);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: sheet([
              toolRows([
                tool('c0', 'bash', {'command': 'flutter test'}, result: 'All tests passed!'),
                pluginTool('c1', weatherCard),
                pluginTool('c2', {'type': 'gauge'}),
                pluginTool('c3', {
                  'type': 'stack',
                  'children': [tableView, actionsView],
                }),
              ]),
            ]),
          ),
          brightness: brightness,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Cards open by themselves; the broken one opens by hand.
      for (final id in ['c2']) {
        await tester.tap(find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(Row)).first);
        await pumpFrames(tester, 20);
      }
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/plugin_toolcard_$suffix.png'));
    });
  }

  // English (i18n): the app's own words in English; plugin content is the
  // plugin's.
  final enWeather = {
    'type': 'stack',
    'title': 'Tokyo · next 3 days',
    'children': [
      {
        'type': 'row',
        'children': [
          {'type': 'metric', 'label': 'High', 'value': '21°'},
          {'type': 'metric', 'label': 'Low', 'value': '14°', 'tone': 'info'},
          {'type': 'metric', 'label': 'Rain', 'value': '60%', 'tone': 'warn'},
        ],
      },
      {
        'type': 'list',
        'items': [
          {'title': 'Saturday', 'subtitle': 'Light rain', 'trailing': '21° / 15°', 'icon': 'travel'},
          {'title': 'Sunday', 'subtitle': 'Cloudy', 'trailing': '19° / 14°', 'icon': 'travel'},
        ],
      },
      {'type': 'progress', 'label': 'Umbrella odds', 'value': 60, 'tone': 'warn'},
      {
        'type': 'keyValue',
        'items': {'Sunrise': '5:58', 'Sunset': '16:49'},
      },
      {
        'type': 'actions',
        'items': [
          {'label': 'Refresh', 'icon': 'refresh', 'action': 'refresh'},
          {'label': 'Open forecast', 'style': 'primary', 'action': 'open'},
        ],
      },
    ],
  };

  final enUsage = {
    'type': 'stack',
    'children': [
      {
        'type': 'row',
        'children': [
          {
            'type': 'metric',
            'label': 'This chat',
            'value': {r'$': 'data.session'},
          },
          {
            'type': 'metric',
            'label': 'Today',
            'value': {r'$': 'data.today'},
          },
        ],
      },
      {
        'type': 'list',
        'items': {r'$': 'data.recent'},
      },
      {
        'type': 'table',
        'columns': ['Day', 'Cost'],
        'rows': {r'$': 'data.days'},
      },
    ],
  };

  testWidgets('plugin views (en)', (tester) async {
    useEnglish();
    usePhoneView(tester);
    tester.view.physicalSize = const Size(780, 1500 * 2);
    await tester.pumpWidget(
      testApp(
        inEnglish(
          Scaffold(
            body: sheet([
              framed('Weather', enWeather, icon: 'globe'),
              framed('Usage', enUsage, data: const {}, icon: 'chart'),
              framed('Broken plugin', {'type': 'gauge'}),
              framed('Gallery', {
                'type': 'image',
                'src': 'https://tracker.example/p.png',
                'caption': 'Not from the bridge',
              }),
            ]),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/en_plugin_view_light.png'));
  });

  testWidgets('tool card (en)', (tester) async {
    useEnglish();
    usePhoneView(tester);
    tester.view.physicalSize = const Size(780, 1100 * 2);
    await tester.pumpWidget(
      testApp(
        inEnglish(
          Scaffold(
            body: sheet([
              toolRows([
                pluginTool('e1', enWeather, city: 'Tokyo'),
                pluginTool('e2', {'type': 'gauge'}, city: 'Tokyo'),
              ]),
            ]),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    for (final id in ['e2']) {
      await tester.tap(find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(Row)).first);
      await pumpFrames(tester, 20);
    }
    await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/en_plugin_toolcard_light.png'));
  });
}
