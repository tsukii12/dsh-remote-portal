// 设置 › 界面 › 左滑快捷入口: the switch, and the sheet that picks and orders
// the destinations. What's stored is the destinations' names, in order.
//
//   flutter test test/settings/quick_panel_settings_test.dart

import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/ui/settings/interface_page.dart';
import 'package:dsh_app/ui/settings/quick_panel_items_sheet.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart' show DrawerDestination;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart' as engine;
import '../support/english_preview.dart';

const _swipeRow = ValueKey('quick-panel-swipe');
const _itemsRow = ValueKey('quick-panel-items');

Future<void> _pump(WidgetTester tester) => engine.pumpPage(
  tester,
  const InterfacePage(),
  overrides: engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
  height: 1600,
);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(InterfacePage)));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(_itemsRow));
  await _settle(tester);
  expect(find.byType(QuickPanelItemsSheet), findsOneWidget);
}

Finder _inSheet(Finder finder) => find.descendant(of: find.byType(QuickPanelItemsSheet), matching: finder);

Finder _sheetRow(DrawerDestination destination) => _inSheet(find.byKey(ValueKey(destination)));

/// The rows from top to bottom.
List<DrawerDestination> _rows(WidgetTester tester) {
  final rows = [...DrawerDestination.values]
    ..sort((a, b) => tester.getTopLeft(_sheetRow(a)).dy.compareTo(tester.getTopLeft(_sheetRow(b)).dy));
  return rows;
}

Future<List<String>?> _stored() async =>
    (await SharedPreferences.getInstance()).getStringList(QuickPanelController.itemsKey);

/// Lifts [destination] by its handle and drops it [rows] rows down (up when
/// negative), in small steps.
Future<void> _drag(WidgetTester tester, DrawerDestination destination, int rows) async {
  final handle = find.descendant(of: _sheetRow(destination), matching: find.byIcon(AppIcons.dragHandle));
  final finger = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  final height = tester.getSize(_sheetRow(destination)).height;
  for (var i = 0; i < 12; i++) {
    await finger.moveBy(Offset(0, height * rows / 12));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await finger.up();
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an install that never chose anything: on, 插件、本机引擎、设置, nothing stored', (tester) async {
    await _pump(tester);
    expect(
      tester.widget<Switch>(find.descendant(of: find.byKey(_swipeRow), matching: find.byType(Switch))).value,
      isTrue,
    );
    expect(find.descendant(of: find.byKey(_itemsRow), matching: find.text('插件、本机引擎、设置')), findsOneWidget);
    expect(await _stored(), isNull);
    expect((await SharedPreferences.getInstance()).getBool(QuickPanelController.swipeKey), isNull);
  });

  testWidgets('the switch turns the swipe off and on, and is remembered', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(_swipeRow));
    await _settle(tester);
    expect(_container(tester).read(quickPanelProvider).swipe, isFalse);
    expect(_container(tester).read(quickPanelProvider).available, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(QuickPanelController.swipeKey), isFalse);

    await tester.tap(find.byKey(_swipeRow));
    await _settle(tester);
    expect(_container(tester).read(quickPanelProvider).available, isTrue);
    expect((await SharedPreferences.getInstance()).getBool(QuickPanelController.swipeKey), isTrue);
  });

  testWidgets('the sheet: what shows first, in order, then the rest', (tester) async {
    await _pump(tester);
    await _openSheet(tester);
    expect(_rows(tester), [
      DrawerDestination.plugins,
      DrawerDestination.engine,
      DrawerDestination.settings,
      DrawerDestination.web,
      DrawerDestination.remote,
      DrawerDestination.settingsSearch,
      DrawerDestination.features,
    ]);
  });

  testWidgets('ticking adds, unticking removes; only names go into storage', (tester) async {
    await _pump(tester);
    await _openSheet(tester);

    await tester.tap(_sheetRow(DrawerDestination.remote));
    await _settle(tester);
    expect(await _stored(), ['plugins', 'engine', 'settings', 'remote']);

    await tester.tap(_sheetRow(DrawerDestination.engine));
    await _settle(tester);
    expect(await _stored(), ['plugins', 'settings', 'remote']);
    expect(_container(tester).read(quickPanelProvider).items, [
      DrawerDestination.plugins,
      DrawerDestination.settings,
      DrawerDestination.remote,
    ]);

    // Unticked, a row stays where it is until the sheet is opened again.
    expect(_rows(tester).take(2), [DrawerDestination.plugins, DrawerDestination.engine]);
    await tester.tap(_sheetRow(DrawerDestination.engine));
    await _settle(tester);
    expect(await _stored(), ['plugins', 'engine', 'settings', 'remote']);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.descendant(of: find.byKey(_itemsRow), matching: find.text('插件、本机引擎、设置、远程主机')), findsOneWidget);
  });

  testWidgets('the handle reorders; what is ticked is stored in the rows\' order', (tester) async {
    await _pump(tester);
    await _openSheet(tester);

    await _drag(tester, DrawerDestination.settings, -2);
    expect(_rows(tester).take(3), [DrawerDestination.settings, DrawerDestination.plugins, DrawerDestination.engine]);
    expect(await _stored(), ['settings', 'plugins', 'engine']);

    // An unticked row moved up, then ticked, takes the place it was put in.
    await _drag(tester, DrawerDestination.features, -5);
    expect(_rows(tester).take(3), [DrawerDestination.settings, DrawerDestination.features, DrawerDestination.plugins]);
    expect(await _stored(), ['settings', 'plugins', 'engine']);
    await tester.tap(_sheetRow(DrawerDestination.features));
    await _settle(tester);
    expect(await _stored(), ['settings', 'features', 'plugins', 'engine']);
    expect(_container(tester).read(quickPanelProvider).items.first, DrawerDestination.settings);
  });

  testWidgets('nothing ticked: the row says so and there is no panel; ticking brings it back', (tester) async {
    await _pump(tester);
    await _openSheet(tester);
    for (final d in [DrawerDestination.plugins, DrawerDestination.engine, DrawerDestination.settings]) {
      await tester.tap(_sheetRow(d));
      await _settle(tester);
    }
    expect(await _stored(), isEmpty);
    expect(_container(tester).read(quickPanelProvider).available, isFalse);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.descendant(of: find.byKey(_itemsRow), matching: find.text('没有选择，左滑不会打开')), findsOneWidget);

    await _openSheet(tester);
    await tester.tap(_sheetRow(DrawerDestination.web));
    await _settle(tester);
    expect(await _stored(), ['web']);
    expect(_container(tester).read(quickPanelProvider).available, isTrue);
  });

  for (final english in [false, true]) {
    testWidgets('320 dp at 1.3× text fits (${english ? 'en' : 'zh'})', (tester) async {
      if (english) useEnglish();
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester);
      tester.view.physicalSize = const Size(320 * 2, 1800 * 2);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _openSheet(tester);
      expect(tester.takeException(), isNull);
    });
  }

  group('stored', () {
    ProviderContainer container() {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return container;
    }

    Future<QuickPanelPrefs> load(ProviderContainer container) async {
      container.read(quickPanelProvider);
      await pumpEventQueue();
      return container.read(quickPanelProvider);
    }

    test('nothing yet: the defaults', () async {
      final prefs = await load(container());
      expect(prefs.swipe, isTrue);
      expect(prefs.items, QuickPanelPrefs.defaultItems);
    });

    test('an id nothing answers to is dropped, a repeat too, the order kept', () async {
      SharedPreferences.setMockInitialValues({
        QuickPanelController.itemsKey: ['features', 'gone', 'web', 'features', ''],
      });
      expect((await load(container())).items, [DrawerDestination.features, DrawerDestination.web]);
    });

    test('nothing left is nothing, not the defaults: the person chose those', () async {
      SharedPreferences.setMockInitialValues({QuickPanelController.itemsKey: <String>[]});
      final prefs = await load(container());
      expect(prefs.items, isEmpty);
      expect(prefs.available, isFalse);
    });

    test('a change made while the stored values load is not undone by them', () async {
      SharedPreferences.setMockInitialValues({
        QuickPanelController.swipeKey: true,
        QuickPanelController.itemsKey: ['web'],
      });
      final c = container();
      c.read(quickPanelProvider);
      await c.read(quickPanelProvider.notifier).setSwipe(false);
      expect(c.read(quickPanelProvider).swipe, isFalse);
      expect(c.read(quickPanelProvider).items, [DrawerDestination.web]);
    });
  });

  test('every destination has a stable id and they stay what storage holds', () {
    expect(DrawerDestination.values.map((d) => d.name), [
      'web',
      'remote',
      'plugins',
      'engine',
      'settings',
      'settingsSearch',
      'features',
    ]);
  });
}
