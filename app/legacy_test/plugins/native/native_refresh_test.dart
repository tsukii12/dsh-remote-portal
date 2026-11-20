// Plugins added while the app looks on (the agent, the terminal): with no
// stream open nothing says so, so a reply ending reads the contributions
// again (a 304 when nothing changed), and when they come back changed the
// installed list (设置 › 插件) reads again too.

import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/native/composer_capsules.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

/// An installed list that counts how often it is read again.
class _CountingBundles extends InstalledPluginsController {
  int refreshes = 0;

  @override
  Future<List<PluginBundle>?> build() async => const [];

  @override
  Future<void> refresh() async => refreshes++;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a reply ending reads the contributions again; changed ones read the list again', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(contributions([], rev: 'r1'));
    final bundles = _CountingBundles();
    final visible = ValueNotifier<bool>(true);
    final composer = FakeComposer();
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: withComposer(
            composer,
            Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (context, v, _) => NativeComposerBar(sessionId: 's1', visible: v),
              ),
            ),
          ),
        ),
        overrides: [
          nativeBridgeProvider.overrideWithValue(bridge),
          activeHostProvider.overrideWith(LocalHost.new),
          installedPluginsProvider.overrideWith(() => bundles),
          uiOverridesProvider.overrideWithValue(const UiOverrides(host: HostRef.none, config: UiConfig())),
        ],
      ),
    );
    await pumpFrames(tester);
    final reads = bridge.contributionReads;
    expect(find.byType(ComposerCapsule), findsNothing);

    // A reply runs; meanwhile the agent installs a plugin with a capsule.
    visible.value = false;
    await pumpFrames(tester);
    expect(bridge.contributionReads, reads, reason: 'nothing read while it runs');
    bridge.raw = contributions([quickPlugin()], rev: 'r2');

    visible.value = true;
    await pumpFrames(tester);
    expect(bridge.contributionReads, reads + 1);
    expect(find.byType(ComposerCapsule), findsNWidgets(2), reason: 'its capsules show without leaving the chat');
    expect(bundles.refreshes, 1, reason: 'the contributions changed: the installed list reads again');

    // Another reply, nothing changed: read again, the list left alone.
    visible.value = false;
    await pumpFrames(tester);
    visible.value = true;
    await pumpFrames(tester);
    expect(bridge.contributionReads, reads + 2);
    expect(bundles.refreshes, 1);
  });
}
