import 'dart:async';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late ProviderContainer container;
  late List<Object?> inventory;

  Future<InstalledPluginsController> ready(WidgetTester tester) async {
    container.read(installedPluginsProvider);
    await tester.pump();
    expect(container.read(installedPluginsProvider).hasValue, isTrue);
    return container.read(installedPluginsProvider.notifier);
  }

  List<String> visible() => container.read(installedPluginsProvider).value!.map((b) => b.name).toList();
  PluginBundle bundle(String name) =>
      PluginBundle.fromJson(inventory.cast<Map<String, Object?>>().firstWhere((b) => b['name'] == name));
  List<Map<String, Object?>> getCalls() => carrier.argsOf('pluginManager/removeBundle');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    inventory = [bundleJson('first'), bundleJson('second')];
    carrier.handlers['pluginManager/listBundles'] = (_) => inventory;
    carrier.handlers['pluginManager/removeBundle'] = (args) {
      inventory = inventory.where((b) => (b as Map)['name'] != args['name']).toList();
      return {'stage': 'remove', 'target': args['name'], 'changed': true, 'application': 'applied'};
    };
    container = ProviderContainer(overrides: pluginOverrides(fakeHost(client)));
  });
  tearDown(() async {
    container.dispose();
    await client.close();
  });

  testWidgets('waiting hides across refresh; undo sends no Host remove', (tester) async {
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    expect(visible(), ['second']);
    await controller.refresh();
    expect(visible(), ['second']);
    await tester.pump(const Duration(seconds: 3));
    expect(getCalls(), isEmpty);
    expect(first.cancel(), isTrue);
    expect(await first.done, isNull);
    expect(visible(), ['first', 'second']);
    await tester.pump(const Duration(seconds: 5));
    expect(getCalls(), isEmpty);
  });

  testWidgets('expiry dispatches once; committing has no undo', (tester) async {
    final controller = await ready(tester);
    final response = Completer<Object?>();
    carrier.handlers['pluginManager/removeBundle'] = (_) => response.future;
    final first = controller.scheduleRemoval(bundle('first'));
    expect(identical(controller.scheduleRemoval(bundle('first')), first), isTrue);
    await tester.pump(InstalledPluginsController.removalUndoWindow);
    expect(getCalls(), hasLength(1));
    expect(first.canUndo, isFalse);
    expect(first.cancel(), isFalse);
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(first.canUndo, isFalse);
    expect(getCalls(), hasLength(1));
    expect(visible(), ['second']);
    inventory = [bundleJson('second')];
    response.complete({'stage': 'remove', 'target': 'first', 'changed': true, 'application': 'applied'});
    await tester.pump();
    expect((await first.done)!.succeeded, isTrue);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(visible(), ['second']);
    await tester.pump(const Duration(seconds: 5));
    expect(getCalls(), hasLength(1));
  });

  testWidgets('Host failure restores row and settles result', (tester) async {
    final controller = await ready(tester);
    carrier.handlers['pluginManager/removeBundle'] = (_) => {
      'stage': 'remove',
      'target': 'first',
      'application': 'failed',
    };
    final first = controller.scheduleRemoval(bundle('first'));
    await tester.pump(InstalledPluginsController.removalUndoWindow);
    expect((await first.done)!.succeeded, isFalse);
    expect(visible(), ['first', 'second']);
  });

  testWidgets('commitNow sends at once and once; a sent handle cannot undo or cancel a newer plan', (tester) async {
    final controller = await ready(tester);
    final old = controller.scheduleRemoval(bundle('first'));
    expect(old.commitNow(), isTrue);
    expect(old.commitNow(), isFalse);
    expect((await old.done)!.succeeded, isTrue);
    expect(old.sent, isTrue);
    expect(getCalls(), hasLength(1));
    expect(visible(), ['second']);
    final second = controller.scheduleRemoval(bundle('second'));
    expect(old.cancel(), isFalse);
    expect(old.undo(), isFalse);
    expect(second.canUndo, isTrue);
    expect(second.undo(), isTrue);
    expect(second.undone, isTrue);
    expect(await second.done, isNull);
    await tester.pump(const Duration(seconds: 5));
    expect(getCalls(), hasLength(1));
  });

  testWidgets('fresh same-name different version cancels before dispatch', (tester) async {
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    inventory = [bundleJson('first', version: '9.0.0'), bundleJson('second')];
    await tester.pump(InstalledPluginsController.removalUndoWindow);
    expect(await first.done, isNull);
    expect(getCalls(), isEmpty);
    expect(visible(), ['first', 'second']);
  });

  testWidgets('Host replacement cancels without sending either Host a remove', (tester) async {
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    final other = FakePluginCarrier();
    other.handlers['pluginManager/listBundles'] = (_) => [bundleJson('first')];
    final otherClient = DshClient.withCarrier(other);
    addTearDown(otherClient.close);
    container.updateOverrides(pluginOverrides(fakeHost(otherClient)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(await first.done, isNull);
    expect(getCalls(), isEmpty);
    expect(other.argsOf('pluginManager/removeBundle'), isEmpty);
  });

  testWidgets('leaving the screen sends waiting work at once, and only once', (tester) async {
    // The notice said 已卸载 and its 撤销 leaves with the screen; the process
    // may be killed from recents before the window would have ended.
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect((await first.done)!.succeeded, isTrue);
    expect(getCalls(), hasLength(1));
    expect(visible(), ['second']);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 5));
    expect(getCalls(), hasLength(1));
  });

  testWidgets('leave and return before a frame cancels the old Host lease', (tester) async {
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    final selection = container.read(activeHostProvider.notifier);
    selection.select(HostRef.portal('other'));
    selection.select(HostRef.none);
    await tester.pump(const Duration(seconds: 5));
    expect(await first.done, isNull);
    expect(getCalls(), isEmpty);
  });

  testWidgets('same client reconnect retires waiting removal', (tester) async {
    final controller = await ready(tester);
    client.mux.start();
    await tester.pump();
    final first = controller.scheduleRemoval(bundle('first'));
    client.mux.reconnect();
    await tester.pump(const Duration(seconds: 5));
    expect(await first.done, isNull);
    expect(getCalls(), isEmpty);
  });

  testWidgets('Host exception restores row and propagates failure', (tester) async {
    final controller = await ready(tester);
    carrier.handlers['pluginManager/removeBundle'] = (_) => throw const DshRemoteException('DENIED', 'denied');
    final first = controller.scheduleRemoval(bundle('first'));
    final failure = expectLater(first.done, throwsA(isA<DshRemoteException>()));
    await tester.pump(InstalledPluginsController.removalUndoWindow);
    await failure;
    expect(visible(), ['first', 'second']);
  });

  testWidgets('owner changes during expiry inventory read never dispatch old removal', (tester) async {
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    final snapshot = Completer<Object?>();
    carrier.handlers['pluginManager/listBundles'] = (_) => snapshot.future;
    await tester.pump(InstalledPluginsController.removalUndoWindow);
    expect(getCalls(), isEmpty);
    final selection = container.read(activeHostProvider.notifier);
    selection.select(HostRef.portal('other'));
    snapshot.complete(inventory);
    await tester.pump(const Duration(milliseconds: 1));
    expect(await first.done, isNull);
    expect(getCalls(), isEmpty);
  });

  testWidgets('late inventory from cancelled timer cannot cancel a new same-name handle', (tester) async {
    final controller = await ready(tester);
    final old = controller.scheduleRemoval(bundle('first'));
    final snapshot = Completer<Object?>();
    carrier.handlers['pluginManager/listBundles'] = (_) => snapshot.future;
    await tester.pump(InstalledPluginsController.removalUndoWindow);
    expect(old.cancel(), isTrue);
    final replacement = controller.scheduleRemoval(bundle('first'));
    snapshot.complete(inventory);
    await tester.pump(const Duration(milliseconds: 1));
    expect(replacement.canUndo, isTrue);
    expect(visible(), ['second']);
    expect(getCalls(), isEmpty);
    replacement.cancel();
  });

  testWidgets('provider disposal cancels waiting timer', (tester) async {
    final controller = await ready(tester);
    final first = controller.scheduleRemoval(bundle('first'));
    container.invalidate(installedPluginsProvider);
    await tester.pump(const Duration(seconds: 5));
    expect(await first.done, isNull);
    expect(getCalls(), isEmpty);
  });
}
