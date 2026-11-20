import 'dart:async';

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/plugins/native/native_surface.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _panel = NativePanel(package: 'controls', id: 'editor', title: 'Editor', placement: {'features'});
const _form = {
  'v': 2,
  'type': 'form',
  'submit': 'save',
  'children': [
    {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
  ],
};

DshGoView _view(String name, {String id = 'editor'}) =>
    DshGoView(pkg: 'controls', id: id, view: _form, data: {'name': name}, rev: name);

DshGoContributions _contributions() => contributions([
  plugin(
    'controls',
    panels: [
      {'id': 'editor', 'title': 'Editor'},
      {'id': 'other', 'title': 'Other'},
    ],
  ),
]);

FakeBridge _bridge(String value) => FakeBridge(_contributions())
  ..views['controls/editor'] = _view(value)
  ..views['controls/other'] = _view(value, id: 'other');

class _Connection extends Notifier<NativeBridge?> {
  _Connection(this.initial);
  final NativeBridge initial;
  @override
  NativeBridge? build() => initial;
  void set(NativeBridge? bridge) => state = bridge;
}

class _DelayedBridge extends FakeBridge {
  _DelayedBridge() : super(_contributions());
  final result = Completer<DshGoView>();
  @override
  Future<DshGoView> view(String pkg, String id, {DshGoScope scope = DshGoScope.none, required DshGoCaps caps}) =>
      result.future;
}

class _Installed extends InstalledPluginsController {
  @override
  Future<List<PluginBundle>?> build() async => [const PluginBundle(name: 'controls', enabled: true)];
  void enabled(bool value) => state = AsyncData([PluginBundle(name: 'controls', enabled: value)]);
}

List<Override> _overrides(FakeBridge bridge, NotifierProvider<_Connection, NativeBridge?> link) {
  final overrides = nativeOverrides(bridge);
  overrides[0] = nativeBridgeProvider.overrideWith((ref) => ref.watch(link));
  overrides[2] = installedPluginsProvider.overrideWith(_Installed.new);
  return overrides;
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(NativePanelView)));
String _text(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('same-host bridge loss preserves drafts and disables invoke until a fresh view returns', (tester) async {
    usePhoneView(tester);
    final first = _bridge('first');
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(first));
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: NativePanelView(panel: _panel, sessionId: 'one'),
        ),
        overrides: _overrides(first, link),
      ),
    );
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'local draft');
    final container = _container(tester);
    container.read(link.notifier).set(null);
    await pumpFrames(tester);
    expect(_text(tester), 'local draft');
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(find.byKey(const ValueKey('submit:view')), findsNothing);
    expect(first.invocations, isEmpty);
    await tester.tap(find.text('重试'));
    await pumpFrames(tester);
    expect(_text(tester), 'local draft');
    expect(find.text('重试'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(
      container.read(nativeSurfaceProvider(nativePanelKey(_panel, const DshGoScope(sessionId: 'one')))).offline,
      isTrue,
    );

    final second = _bridge('new remote');
    container.read(link.notifier).set(second);
    await pumpFrames(tester);
    expect(_text(tester), 'local draft');
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    expect(second.invocations, isEmpty, reason: 'Reconnect never replays draft actions');
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    expect(second.invocations.single.value, {
      'values': {'data.name': 'local draft'},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching host clears the retained view and draft', (tester) async {
    usePhoneView(tester);
    final first = _bridge('first host');
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(first));
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: _overrides(first, link),
      ),
    );
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'private to first host');
    final container = _container(tester);
    container.read(activeHostProvider.notifier).select(const HostRef.portal('another'));
    container.read(link.notifier).set(_bridge('second host'));
    await pumpFrames(tester);
    expect(_text(tester), 'second host');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late view from an obsolete bridge cannot overwrite its replacement', (tester) async {
    usePhoneView(tester);
    final old = _DelayedBridge();
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(old));
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: _overrides(old, link),
      ),
    );
    await pumpFrames(tester);
    final container = _container(tester);
    container.read(link.notifier).set(_bridge('current'));
    await pumpFrames(tester);
    expect(_text(tester), 'current');
    old.result.complete(_view('obsolete'));
    await pumpFrames(tester);
    expect(_text(tester), 'current');
    expect(tester.takeException(), isNull);
  });

  for (final unavailable in ['removed', 'disabled', 'degraded']) {
    testWidgets('$unavailable plugin discards draft before it is made available again', (tester) async {
      usePhoneView(tester);
      final bridge = _bridge('remote');
      final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
      await tester.pumpWidget(
        testApp(
          const Scaffold(body: NativePanelView(panel: _panel)),
          overrides: _overrides(bridge, link),
        ),
      );
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField), 'discard this');
      final container = _container(tester);
      bridge.raw = unavailable == 'removed'
          ? contributions([])
          : unavailable == 'degraded'
          ? contributions([plugin('controls', state: 'degraded')])
          : _contributions();
      if (unavailable == 'disabled') (container.read(installedPluginsProvider.notifier) as _Installed).enabled(false);
      container.invalidate(nativeRawContributionsProvider);
      await pumpFrames(tester);
      expect(find.byType(TextField), findsNothing);
      bridge.raw = _contributions();
      if (unavailable == 'disabled') (container.read(installedPluginsProvider.notifier) as _Installed).enabled(true);
      container.invalidate(nativeRawContributionsProvider);
      await pumpFrames(tester);
      expect(_text(tester), 'remote');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('session and panel identity changes discard drafts', (tester) async {
    usePhoneView(tester);
    final bridge = _bridge('remote');
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
    var session = 'one';
    var panel = _panel;
    late StateSetter change;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return NativePanelView(panel: panel, sessionId: session);
            },
          ),
        ),
        overrides: _overrides(bridge, link),
      ),
    );
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'session one');
    change(() => session = 'two');
    await pumpFrames(tester);
    expect(_text(tester), 'remote');
    await tester.enterText(find.byType(TextField), 'editor draft');
    change(() => panel = const NativePanel(package: 'controls', id: 'other', title: 'Other', placement: {'features'}));
    await pumpFrames(tester);
    expect(_text(tester), 'remote');
    expect(tester.takeException(), isNull);
  });

  for (final replacement in ['bridge', 'host']) {
    testWidgets('late immediate effects from an old $replacement cannot patch its successor', (tester) async {
      usePhoneView(tester);
      final answer = Completer<DshGoInvokeResult>();
      final first = _bridge('first')..answer = (_) => answer.future;
      final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(first));
      await tester.pumpWidget(
        testApp(
          const Scaffold(body: NativePanelView(panel: _panel)),
          overrides: _overrides(first, link),
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('submit:view')));
      await pumpFrames(tester);
      expect(first.invocations, hasLength(1));
      final container = _container(tester);
      if (replacement == 'host') container.read(activeHostProvider.notifier).select(const HostRef.portal('second'));
      container.read(link.notifier).set(_bridge('current'));
      await pumpFrames(tester);
      answer.complete(
        const DshGoInvokeResult(
          effects: [
            {
              'type': 'patch',
              'data': {'name': 'obsolete'},
            },
            {'type': 'toast', 'text': 'Obsolete answer'},
          ],
        ),
      );
      await pumpFrames(tester);
      expect(_text(tester), 'current');
      expect(find.text('Obsolete answer'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('old work finishing cannot clear a new host invocation with the same control key', (tester) async {
    usePhoneView(tester);
    final oldAnswer = Completer<DshGoInvokeResult>(), newAnswer = Completer<DshGoInvokeResult>();
    final first = _bridge('first')..answer = (_) => oldAnswer.future;
    final second = _bridge('second')..answer = (_) => newAnswer.future;
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(first));
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: _overrides(first, link),
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    final container = _container(tester);
    container.read(activeHostProvider.notifier).select(const HostRef.portal('second'));
    container.read(link.notifier).set(second);
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    expect(second.invocations, hasLength(1));
    oldAnswer.complete(const DshGoInvokeResult());
    await pumpFrames(tester);
    final control = nativeControlKey('controls', NativeSurface.panel, 'save');
    expect(container.read(nativeWorkProvider.notifier).busy(control), isTrue);
    newAnswer.complete(
      const DshGoInvokeResult(
        effects: [
          {
            'type': 'patch',
            'data': {'name': 'accepted'},
          },
        ],
      ),
    );
    await pumpFrames(tester);
    expect(container.read(nativeWorkProvider.notifier).busy(control), isFalse);
    expect(_text(tester), 'accepted');
    expect(tester.takeException(), isNull);
  });

  for (final deferred in [false, true]) {
    testWidgets('${deferred ? 'deferred' : 'immediate'} answer after a same-client refresh is ignored', (tester) async {
      usePhoneView(tester);
      final answer = Completer<DshGoInvokeResult>();
      final bridge = _bridge('before')
        ..answer = (_) => deferred
            ? DshGoInvokeResult.fromJson({
                'pending': {'id': 'late', 'timeoutMs': 30000},
              })
            : answer.future;
      final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
      await tester.pumpWidget(
        testApp(
          const Scaffold(body: NativePanelView(panel: _panel)),
          overrides: _overrides(bridge, link),
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('submit:view')));
      await pumpFrames(tester);
      expect(bridge.invocations, hasLength(1));
      final container = _container(tester);
      bridge.views['controls/editor'] = _view('refreshed');
      container.read(nativeSurfaceProvider(nativePanelKey(_panel, DshGoScope.none)).notifier).refresh();
      await pumpFrames(tester);
      const effects = <Map<String, Object?>>[
        {
          'type': 'patch',
          'data': {'name': 'obsolete'},
        },
      ];
      if (deferred) {
        bridge.socket.push({'t': 'done', 'pending': 'late', 'effects': effects});
      } else {
        answer.complete(const DshGoInvokeResult(effects: effects));
      }
      await pumpFrames(tester);
      expect(_text(tester), 'refreshed');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a valid response may refresh its own surface and continue with its next effect', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer();
    final bridge = _bridge('before');
    bridge.answer = (_) {
      bridge.views['controls/editor'] = _view('refreshed');
      return const DshGoInvokeResult(
        effects: [
          {'type': 'refresh'},
          {'type': 'insert', 'text': 'after refresh'},
        ],
      );
    };
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
    await tester.pumpWidget(
      testApp(
        Scaffold(body: withComposer(composer, const NativePanelView(panel: _panel))),
        overrides: _overrides(bridge, link),
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    expect(_text(tester), 'refreshed');
    expect(composer.inserted, ['after refresh']);
    expect(tester.takeException(), isNull);
  });

  for (final identity in ['session', 'panel', 'removed', 'disabled']) {
    testWidgets('a late invoke cannot act after $identity changes', (tester) async {
      usePhoneView(tester);
      final answer = Completer<DshGoInvokeResult>();
      final bridge = _bridge('current')..answer = (_) => answer.future;
      final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
      var session = 'one';
      var panel = _panel;
      late StateSetter change;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return NativePanelView(panel: panel, sessionId: session);
              },
            ),
          ),
          overrides: _overrides(bridge, link),
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('submit:view')));
      await pumpFrames(tester);
      final container = _container(tester);
      switch (identity) {
        case 'session':
          change(() => session = 'two');
        case 'panel':
          change(
            () => panel = const NativePanel(package: 'controls', id: 'other', title: 'Other', placement: {'features'}),
          );
        case 'removed':
          bridge.raw = contributions([]);
          container.invalidate(nativeRawContributionsProvider);
        case 'disabled':
          (container.read(installedPluginsProvider.notifier) as _Installed).enabled(false);
      }
      await pumpFrames(tester);
      answer.complete(
        DshGoInvokeResult(
          effects: [
            {
              'type': 'patch',
              if (identity == 'panel') 'panel': 'other',
              'data': {'name': 'obsolete'},
            },
            {'type': 'toast', 'text': 'Wrong owner'},
          ],
        ),
      );
      await pumpFrames(tester);
      if (identity == 'removed' || identity == 'disabled') {
        bridge.raw = _contributions();
        (container.read(installedPluginsProvider.notifier) as _Installed).enabled(true);
        container.invalidate(nativeRawContributionsProvider);
        await pumpFrames(tester);
      }
      expect(_text(tester), 'current');
      expect(find.text('Wrong owner'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disposing the panel and provider container before an invoke resolves is harmless', (tester) async {
    usePhoneView(tester);
    final answer = Completer<DshGoInvokeResult>();
    final bridge = _bridge('before')..answer = (_) => answer.future;
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: _overrides(bridge, link),
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    answer.complete(
      const DshGoInvokeResult(
        effects: [
          {
            'type': 'patch',
            'data': {'name': 'obsolete'},
          },
        ],
      ),
    );
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deferred result may be voided after its scaffold and container are disposed', (tester) async {
    usePhoneView(tester);
    final bridge = _bridge('before')
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'pending': {'id': 'closed', 'timeoutMs': 30000},
      });
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: _overrides(bridge, link),
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    expect(bridge.invocations, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onChange is explicitly not a user gesture while form submit is', (tester) async {
    usePhoneView(tester);
    final bridge = _bridge('before');
    bridge.views['controls/editor'] = const DshGoView(
      pkg: 'controls',
      id: 'editor',
      view: {
        'v': 2,
        'type': 'form',
        'submit': 'save',
        'children': [
          {'type': 'textField', 'label': 'Name', 'bind': 'data.name', 'onChange': 'changed'},
        ],
      },
      data: {'name': 'before'},
    );
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: _overrides(bridge, link),
      ),
    );
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'typed');
    await pumpFrames(tester);
    expect(bridge.invocations.single.action, 'changed');
    expect(bridge.invocations.single.userGesture, isFalse);
    expect(bridge.invocations.single.value, {'bind': 'data.name', 'value': 'typed'});
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await pumpFrames(tester);
    expect(bridge.invocations.last.action, 'save');
    expect(bridge.invocations.last.userGesture, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('disposing before the queued initial read never uses a disposed provider ref', () async {
    final bridge = _bridge('unused');
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(bridge));
    final container = ProviderContainer(overrides: _overrides(bridge, link));
    container.listen(nativeSurfaceProvider(nativePanelKey(_panel, DshGoScope.none)), (_, _) {});
    container.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('surface generation advances when a connection is replaced', () async {
    final first = _bridge('one');
    final link = NotifierProvider<_Connection, NativeBridge?>(() => _Connection(first));
    final container = ProviderContainer(overrides: _overrides(first, link));
    addTearDown(container.dispose);
    const key = NativeSurfaceKey(package: 'controls', surface: NativeSurface.panel, id: 'editor', live: false);
    final listener = container.listen(nativeSurfaceProvider(key), (_, _) {});
    addTearDown(listener.close);
    await container.read(nativeRawContributionsProvider.future);
    await Future<void>.delayed(Duration.zero);
    final surface = container.read(nativeSurfaceProvider(key).notifier);
    final before = surface.generation;
    container.read(link.notifier).set(null);
    container.read(nativeSurfaceProvider(key));
    expect(surface.generation, greaterThan(before));
  });
}
