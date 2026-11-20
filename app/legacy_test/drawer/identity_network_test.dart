import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/network_details_sheet.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

const _host = HostRef.portal('workstation');
const _name = 'Workstation';
const _detailsKey = ValueKey('identity-host-details');
const _switcherKey = ValueKey('identity-host-switcher');

class _ActiveHost extends ActiveHostController {
  _ActiveHost(this.initial);

  final HostRef initial;

  @override
  HostRef build() => initial;

  void emit(HostRef host) => state = host;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  HostRef host = _host,
  HostLinkStatus status = const HostLinkStatus(HostLinkPhase.connected),
  Stream<HostLinkStatus> changes = const Stream.empty(),
  VoidCallback? onHost,
  VoidCallback? onLocalDetails,
  VoidCallback? onWatchLink,
  double scale = 1,
}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      overrides: [
        activeHostProvider.overrideWith(() => _ActiveHost(host)),
        hostNameProvider.overrideWith((ref, host) => host.isLocal ? '本机' : _name),
        hostLinkStatusProvider.overrideWith((ref, host) async* {
          onWatchLink?.call();
          yield status;
          yield* changes;
        }),
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: 320,
                child: IdentityBar(
                  onHost: onHost ?? () {},
                  onLocalDetails: onLocalDetails,
                  onFeatures: () {},
                  onSettings: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(IdentityBar)));
}

void main() {
  setUp(() => AppLocale.use(AppLocale.zhCN));

  for (final path in RelayPath.values) {
    testWidgets('host icon opens confirmed ${path.name} details; name still switches hosts', (tester) async {
      var switches = 0;
      await _pump(
        tester,
        status: HostLinkStatus(
          HostLinkPhase.connected,
          path: RelayPath.direct,
          network: RemoteNetworkStatus(
            path: path,
            connectDuration: const Duration(milliseconds: 315),
            roundTripTime: const Duration(milliseconds: 47),
            fallbackReason: path == RelayPath.relay ? 'turnTimeout' : null,
          ),
        ),
        onHost: () => switches++,
      );
      final footer = find.byType(IdentityBar);
      expect(find.descendant(of: footer, matching: find.text(path.label)), findsOneWidget);
      await tester.tap(find.byKey(_switcherKey));
      await _frames(tester);
      expect(switches, 1);
      expect(find.byType(RemoteNetworkDetailsSheet), findsNothing);

      final button = find.byKey(_detailsKey);
      expect(tester.getSize(button), const Size.square(44));
      expect(tester.getRect(button).right, lessThanOrEqualTo(tester.getRect(find.byKey(_switcherKey)).left));
      await tester.tap(button);
      await _frames(tester);
      expect(switches, 1, reason: 'the icon must not also invoke the host switcher');
      final sheet = find.byType(RemoteNetworkDetailsSheet);
      expect(tester.widget<RemoteNetworkDetailsSheet>(sheet).host, _host);
      expect(find.descendant(of: sheet, matching: find.text(_name)), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('DSH Remote')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text(path.label)), findsOneWidget);
      expect(find.text('315 毫秒'), findsOneWidget);
      expect(find.text('47 毫秒'), findsOneWidget);
      if (path == RelayPath.relay) expect(find.text('TURN 连接超时，已使用 Relay 中继'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a connected but unconfirmed route is never called P2P', (tester) async {
    await _pump(tester);
    final footer = find.byType(IdentityBar);
    expect(find.descendant(of: footer, matching: find.text('已连接')), findsOneWidget);
    expect(find.descendant(of: footer, matching: find.text(RelayPath.p2p.label)), findsNothing);
    await tester.tap(find.byKey(_detailsKey));
    await _frames(tester);
    expect(find.text('尚未确认'), findsOneWidget);
    expect(find.text(RelayPath.p2p.label), findsNothing);
    expect(find.text('未测量'), findsNWidgets(2));
  });

  testWidgets('reconnecting retires the old route and measured timings', (tester) async {
    final changes = StreamController<HostLinkStatus>.broadcast(sync: true);
    addTearDown(changes.close);
    await _pump(
      tester,
      status: const HostLinkStatus(HostLinkPhase.connected, path: RelayPath.p2p),
      changes: changes.stream,
    );
    changes.add(
      const HostLinkStatus(
        HostLinkPhase.reconnecting,
        path: RelayPath.p2p,
        network: RemoteNetworkStatus(path: RelayPath.p2p, roundTripTime: Duration(milliseconds: 47)),
      ),
    );
    await _frames(tester);
    final footer = find.byType(IdentityBar);
    expect(find.descendant(of: footer, matching: find.text('重新连接中')), findsOneWidget);
    expect(find.descendant(of: footer, matching: find.text(RelayPath.p2p.label)), findsNothing);
    await tester.tap(find.byKey(_detailsKey));
    await _frames(tester);
    expect(find.text('尚未确认'), findsOneWidget);
    expect(find.text('47 毫秒'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('local icon opens engine details without consulting a remote link', (tester) async {
    var localDetails = 0;
    var switches = 0;
    var linkWatches = 0;
    await _pump(
      tester,
      host: HostRef.none,
      onHost: () => switches++,
      onLocalDetails: () => localDetails++,
      onWatchLink: () => linkWatches++,
    );
    expect(find.byTooltip('本机引擎'), findsOneWidget);
    expect(find.byTooltip('网络详情'), findsNothing);
    await tester.tap(find.byKey(_detailsKey));
    await _frames(tester);
    expect(localDetails, 1);
    expect(switches, 0);
    expect(linkWatches, 0);
    expect(find.byType(RemoteNetworkDetailsSheet), findsNothing);
    await tester.tap(find.byKey(_switcherKey));
    expect(switches, 1);
  });

  testWidgets('SSH details do not claim automatic routing or expose a synthetic P2P measurement', (tester) async {
    await _pump(
      tester,
      host: const HostRef.portal('ssh-workstation'),
      status: const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.p2p,
        network: RemoteNetworkStatus(path: RelayPath.p2p, roundTripTime: Duration(milliseconds: 47)),
      ),
    );
    await tester.tap(find.byKey(_detailsKey));
    await _frames(tester);
    final sheet = find.byType(RemoteNetworkDetailsSheet);
    expect(find.descendant(of: sheet, matching: find.text(_name)), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('SSH')), findsNWidgets(2));
    expect(find.text(appL10n.hostDetailsSshNetworkHint), findsOneWidget);
    expect(find.text(appL10n.remoteNetworkAutomatic), findsNothing);
    expect(find.text(RelayPath.p2p.label), findsNothing);
    expect(find.text('47 毫秒'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('an open sheet keeps the host whose icon was tapped', (tester) async {
    final container = await _pump(tester, status: const HostLinkStatus(HostLinkPhase.connected, path: RelayPath.lan));
    await tester.tap(find.byKey(_detailsKey));
    await _frames(tester);
    (container.read(activeHostProvider.notifier) as _ActiveHost).emit(HostRef.none);
    await _frames(tester);
    expect(tester.widget<RemoteNetworkDetailsSheet>(find.byType(RemoteNetworkDetailsSheet)).host, _host);
    expect(find.text(RelayPath.lan.label), findsOneWidget);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('details and host-switch targets stay separate at 320dp and ${scale}x text', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, scale: scale);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(_detailsKey)), const Size.square(44));
      expect(find.byTooltip('网络详情'), findsOneWidget);
      expect(tester.getSemantics(find.byKey(_detailsKey)).getSemanticsData().tooltip, '网络详情');
      expect(
        tester.getSemantics(find.byKey(_switcherKey)),
        isSemantics(isButton: true, hasTapAction: true, label: appL10n.shellCurrentHostLabel(_name, '已连接')),
      );
      semantics.dispose();
    });
  }
}
