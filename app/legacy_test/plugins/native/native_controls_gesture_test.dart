// The elapsed gesture time belongs to the click before the F2 queue, not to
// runNativeTap's eventual dispatch. Uses the real NativePanel and effect path.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/plugins/native/native_effects.dart';
import 'package:dsh_app/plugins/native/native_file_platform.dart';
import 'package:dsh_app/plugins/native/native_files.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/plugins/native/native_surface.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart' show nativePanelKey;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _panel = NativePanel(package: 'queue', id: 'editor', title: 'Queue', placement: {'features'});
const _picker = <String, Object?>{
  'type': 'pickFile',
  'request': '12345678901234567890123456789012',
  'action': 'selected',
  'maxFiles': 1,
  'maxBytes': 8,
  'maxTotalBytes': 8,
};

class _FileSocket extends FakeSocket {
  @override
  void send(String text) {
    final frame = jsonDecode(text) as Map<String, Object?>;
    sent.add(frame);
    if (frame['t'] == 'hello') {
      push({
        't': 'welcome',
        'v': 1,
        'conn': 'c1',
        'features': ['files'],
      });
    }
  }
}

class _QueueBridge extends FakeBridge {
  _QueueBridge(String source)
    : super(
        contributions([
          {
            ...plugin(
              'queue',
              panels: [
                {'id': 'editor', 'title': 'Queue'},
              ],
            ),
            'capabilities': ['files'],
          },
        ]),
      ) {
    views['queue/editor'] = DshGoView(
      pkg: 'queue',
      id: 'editor',
      view: {
        'v': 2,
        'type': 'stack',
        'children': [
          {
            'type': 'actions',
            'items': [
              {'label': 'Start slow', 'action': 'slow'},
            ],
          },
          if (source == 'button')
            {
              'type': 'actions',
              'items': [
                {'label': 'Second action', 'action': 'second'},
              ],
            },
          if (source == 'submit')
            {
              'type': 'form',
              'submit': 'second',
              'submitLabel': 'Second action',
              'children': [
                {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
              ],
            },
          if (source == 'change') {'type': 'textField', 'label': 'Name', 'bind': 'data.name', 'onChange': 'second'},
          {
            'type': 'text',
            'text': {r'$': 'data.result'},
          },
        ],
      },
      data: {'name': 'before', 'result': 'before'},
    );
  }

  @override
  DshGoStream openStream({String? locale}) => DshGoStream(
    () async {
      final socket = _FileSocket();
      sockets.add(socket);
      return socket;
    },
    locale: locale,
    features: const ['files'],
  );
}

class _FilePlatform implements NativeFilePlatform {
  int picks = 0, probes = 0;
  @override
  Future<bool> supported() async {
    probes++;
    return true;
  }

  @override
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect) async {
    picks++;
    return const []; // The chooser opens; the controlled user cancels it.
  }

  @override
  Future<void> cancel(String owner) async {}
}

class _FileTransport implements NativeFileTransport {
  int uploads = 0;
  final statuses = <String>[];
  @override
  Future<void> upload(String request, String stream, NativeSelectedFile file, Uint8List bytes) async {
    uploads++;
  }

  @override
  Future<DshGoInvokeResult> complete(String request, String stream, String status) async {
    statuses.add(status);
    return const DshGoInvokeResult(
      effects: [
        {
          'type': 'patch',
          'data': {'result': 'completed'},
        },
      ],
    );
  }
}

List<String> _clipboard() {
  final copied = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
    call,
  ) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Object? _data(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(NativePanelView)))
        .read(nativeSurfaceProvider(nativePanelKey(_panel, DshGoScope.none)))
        .data;

Future<void> _enqueue(WidgetTester tester, _QueueBridge bridge, String source) async {
  await tester.tap(find.text('Start slow'));
  await pumpFrames(tester);
  expect(bridge.invocations, hasLength(1));
  if (source == 'change') {
    await tester.enterText(find.byType(TextField), 'typed');
    await tester.pump(const Duration(milliseconds: 250));
  } else {
    await tester.tap(find.text('Second action'));
    await tester.pump();
  }
  expect(bridge.invocations, hasLength(1), reason: 'The second action must actually wait in the F2 lane');
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('late initial pending acknowledgement cannot renew a queued gesture', (tester) async {
    usePhoneView(tester);
    final copied = _clipboard();
    var now = DateTime.utc(2026, 10, 27);
    final second = Completer<DshGoInvokeResult>();
    final bridge = _QueueBridge('button');
    bridge.answer = (call) => call.action == 'slow'
        ? DshGoInvokeResult.fromJson({
            'pending': {'id': 'slow-result', 'timeoutMs': 30000},
          })
        : second.future;
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: NativePanelView(panel: _panel)),
        overrides: nativeOverrides(
          bridge,
          bundles: const [PluginBundle(name: 'queue', enabled: true)],
          clock: () => now,
        ),
      ),
    );
    await pumpFrames(tester);
    await _enqueue(tester, bridge, 'button');
    now = now.add(const Duration(seconds: 1));
    bridge.socket.push({'t': 'done', 'pending': 'slow-result', 'effects': <Object>[]});
    await pumpFrames(tester);
    expect(bridge.invocations.last.userGesture, isTrue, reason: 'Dispatch itself was still within the tap window');
    now = now.add(const Duration(seconds: 3));
    second.complete(
      DshGoInvokeResult.fromJson({
        'pending': {'id': 'second-result', 'timeoutMs': 30000},
      }),
    );
    await pumpFrames(tester);
    bridge.socket.push({
      't': 'done',
      'pending': 'second-result',
      'effects': [
        {'type': 'copy', 'text': 'too late'},
        {
          'type': 'patch',
          'data': {'result': 'updated'},
        },
      ],
    });
    await pumpFrames(tester, 20);
    expect(copied, isEmpty);
    expect((_data(tester) as Map)['result'], 'updated');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final source in ['button', 'submit', 'change']) {
    for (final seconds in [1, 4]) {
      for (final deferred in [false, true]) {
        testWidgets('$source queued ${seconds}s ${deferred ? 'deferred' : 'immediate'} copy obeys its original gesture', (
          tester,
        ) async {
          usePhoneView(tester);
          final copied = _clipboard();
          var now = DateTime.utc(2026, 10, 27);
          final bridge = _QueueBridge(source);
          const effects = <Map<String, Object?>>[
            {'type': 'copy', 'text': 'allowed copy'},
            {
              'type': 'patch',
              'data': {'result': 'updated'},
            },
          ];
          bridge.answer = (call) => call.action == 'slow'
              ? DshGoInvokeResult.fromJson({
                  'pending': {'id': 'slow-result', 'timeoutMs': 30000},
                })
              : deferred
              ? DshGoInvokeResult.fromJson({
                  'pending': {'id': 'second-result', 'timeoutMs': 30000},
                })
              : const DshGoInvokeResult(effects: effects);
          await tester.pumpWidget(
            testApp(
              const Scaffold(body: NativePanelView(panel: _panel)),
              overrides: nativeOverrides(
                bridge,
                bundles: const [PluginBundle(name: 'queue', enabled: true)],
                clock: () => now,
              ),
            ),
          );
          await pumpFrames(tester);
          await _enqueue(tester, bridge, source);
          now = now.add(Duration(seconds: seconds));
          await tester.pump(Duration(seconds: seconds));
          bridge.socket.push({'t': 'done', 'pending': 'slow-result', 'effects': <Object>[]});
          await pumpFrames(tester, 20);
          expect(bridge.invocations.map((i) => i.action), ['slow', 'second']);
          final allowed = source != 'change' && seconds <= 3;
          expect(bridge.invocations.last.userGesture, allowed);
          if (source == 'submit') {
            expect(bridge.invocations.last.value, {
              'values': {'data.name': 'before'},
            });
          }
          if (deferred) {
            now = now.add(const Duration(seconds: 10));
            await tester.pump(const Duration(seconds: 10));
            bridge.socket.push({'t': 'done', 'pending': 'second-result', 'effects': effects});
            await pumpFrames(tester, 20);
          }
          expect(copied, allowed ? ['allowed copy'] : isEmpty);
          expect(
            (_data(tester) as Map)['result'],
            'updated',
            reason: 'Gesture expiration cannot suppress valid data updates',
          );
          debugPrint(
            'F2_REPAIR_GESTURE source=$source queued=${seconds}s deferred=$deferred wireGesture=${bridge.invocations.last.userGesture} copied=$copied data=${_data(tester)}',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }

      testWidgets('$source queued ${seconds}s picker reaches the platform only with fresh authority', (tester) async {
        usePhoneView(tester);
        var now = DateTime.utc(2026, 10, 27);
        final bridge = _QueueBridge(source);
        final platform = _FilePlatform(), transport = _FileTransport();
        final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
        bridge.answer = (call) => call.action == 'slow'
            ? DshGoInvokeResult.fromJson({
                'pending': {'id': 'slow-result', 'timeoutMs': 30000},
              })
            : const DshGoInvokeResult(
                effects: [
                  _picker,
                  {
                    'type': 'patch',
                    'data': {'result': 'updated'},
                  },
                ],
              );
        await tester.pumpWidget(
          testApp(
            const Scaffold(body: NativePanelView(panel: _panel)),
            overrides: [
              ...nativeOverrides(
                bridge,
                bundles: const [PluginBundle(name: 'queue', enabled: true)],
                clock: () => now,
              ),
              nativeFileCoordinatorProvider.overrideWithValue(runtime),
            ],
          ),
        );
        await pumpFrames(tester);
        await _enqueue(tester, bridge, source);
        now = now.add(Duration(seconds: seconds));
        await tester.pump(Duration(seconds: seconds));
        bridge.socket.push({'t': 'done', 'pending': 'slow-result', 'effects': <Object>[]});
        await pumpFrames(tester, 25);
        final allowed = source != 'change' && seconds <= 3;
        final container = ProviderScope.containerOf(tester.element(find.byType(NativePanelView)));
        debugPrint(
          'F2_REPAIR_PICKER_PRE source=$source queued=${seconds}s gesture=${bridge.invocations.last.userGesture} stream=${bridge.invocations.last.stream} features=${container.read(nativeStreamProvider)?.negotiatedFeatures} capability=${container.read(nativeContributionsProvider).plugin("queue")?.capabilities} probes=${platform.probes} picks=${platform.picks} status=${transport.statuses}',
        );
        expect(bridge.invocations.map((i) => i.action), ['slow', 'second']);
        expect(bridge.invocations.last.userGesture, allowed);
        expect(platform.picks, allowed ? 1 : 0);
        expect(platform.probes, allowed ? 1 : 0, reason: 'Rejected gestures cannot even probe the platform');
        expect(transport.uploads, 0, reason: 'The controlled chooser cancels without a selected file');
        expect(transport.statuses, ['cancelled']);
        expect((_data(tester) as Map)['result'], allowed ? 'completed' : 'updated');
        debugPrint(
          'F2_REPAIR_PICKER source=$source queued=${seconds}s picks=${platform.picks} statuses=${transport.statuses}',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
