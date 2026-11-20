// A plugin that declares capabilities shows its `requires` buttons as soon as
// the app has asked the platform what it supports — without waiting for the
// next resume.

import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_platform.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _Platform implements NativeMediaPlatform {
  int probes = 0;
  @override
  Future<Set<String>> capabilities() async {
    probes++;
    return {'audio', 'voice', 'overlay'};
  }

  @override
  Future<Object?> call(String method, Map<String, Object?> arguments) async => null;

  @override
  Stream<Object?> get events => const Stream.empty();
}

/// The bridge's answer depends on the features asked with (as the real one).
class _FeatureBridge extends FakeBridge {
  final asked = <List<String>>[];

  @override
  Future<DshGoContributions?> contributions(DshGoCaps caps, {DshGoContributions? previous}) async {
    asked.add(caps.features);
    final ready = caps.features.contains('audio');
    return contributions_([
      {
        ...plugin(
          'voice',
          menu: [
            {
              'id': 'read',
              'label': '朗读',
              'requires': ['audio'],
              'ready': ready,
            },
          ],
        ),
        'capabilities': ['audio', 'voice', 'micro', 'overlay'],
      },
    ], rev: ready ? 'r2' : 'r1');
  }
}

DshGoContributions contributions_(List<Map<String, Object?>> plugins, {required String rev}) =>
    contributions(plugins, rev: rev);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('features found → contributions read again → the button shows', () async {
    final platform = _Platform();
    final bridge = _FeatureBridge();
    final container = ProviderContainer(
      overrides: [
        ...nativeOverrides(bridge),
        nativeMediaPlatformProvider.overrideWithValue(platform),
        nativeLocaleProvider.overrideWithValue('zh-CN'),
      ],
    );
    addTearDown(container.dispose);
    final discovery = container.listen(nativeCapabilityDiscoveryProvider, (_, _) {});
    final menu = container.listen(nativeContributionsProvider, (_, _) {});
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(platform.probes, 1);
    expect(container.read(nativeFeatureStateProvider), ['audio', 'micro', 'overlay', 'voice']);
    expect(bridge.asked.last, ['audio', 'micro', 'overlay', 'voice']);
    expect(container.read(nativeContributionsProvider).plugin('voice')!.messageActions.map((a) => a.id), ['read']);
    menu.close();
    discovery.close();
  });
}
