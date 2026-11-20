import 'dart:async';

import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Future<void> loaded(ProviderContainer container) async {
  container.read(settingsProvider);
  container.read(petPrefsProvider);
  for (var i = 0; i < 40; i++) {
    if (container.read(settingsProvider).loaded && container.read(petPrefsProvider).loaded) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Preferences did not finish loading');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('documented defaults', () {
    for (final tier in DeviceTier.values) {
      test('${tier.name} selects the expected automatic defaults', () {
        final policy = PerformanceDefaults.resolve(snapshot(tier), const PerformancePrefs());
        final full = tier != DeviceTier.low;
        expect(policy.blur, full);
        expect(policy.reduceMotion, !full);
        expect(policy.fluidMotion, full);
        expect(policy.petEnabled, full);
        expect(policy.autoStartLocal, full);
        expect(policy.recommendRemote, !full);
        expect(policy.keepEngineInBackground, isFalse);
      });
    }

    test('full and light choices override the device default', () {
      final full = PerformanceDefaults.resolve(
        snapshot(DeviceTier.low),
        const PerformancePrefs(mode: PerformanceMode.full),
      );
      expect(full.blur, isTrue);
      expect(full.reduceMotion, isFalse);
      final light = PerformanceDefaults.resolve(
        snapshot(DeviceTier.high),
        const PerformancePrefs(mode: PerformanceMode.light),
      );
      expect(light.blur, isFalse);
      expect(light.autoStartLocal, isFalse);
    });

    test('a temporary thermal profile does not rewrite explicit effect choices', () {
      final policy = PerformanceDefaults.resolve(
        snapshot(DeviceTier.high, hot: true),
        const PerformancePrefs(mode: PerformanceMode.full, blur: true, animations: true),
      );
      expect(policy.lightweight, isTrue);
      expect(policy.blur, isTrue);
      expect(policy.reduceMotion, isFalse);
      expect(policy.autoStartLocal, isFalse);
    });

    test('unknown or absent platform facts preserve the neutral profile', () {
      final policy = PerformanceDefaults.resolve(const PerformanceSnapshot(loaded: true), const PerformancePrefs());
      expect(policy.lightweight, isFalse);
      expect(policy.autoStartLocal, isTrue);
      expect(
        PerformanceSnapshot.fromMap({
          'device': {'tier': 'future'},
        }).tier,
        DeviceTier.medium,
      );
    });
  });

  group('persistent choices and live defaults', () {
    late FakePerformanceChannel channel;
    late ProviderContainer container;

    void start({DeviceTier tier = DeviceTier.low, Future<PerformanceSnapshot>? initial}) {
      channel = FakePerformanceChannel(initial ?? Future.value(snapshot(tier)));
      container = ProviderContainer(overrides: [performanceChannelProvider.overrideWithValue(channel)]);
      addTearDown(() async {
        container.dispose();
        await channel.events.close();
      });
    }

    test('hardware Enter preference defaults off, persists, and reloads', () async {
      start();
      await loaded(container);
      expect(container.read(settingsProvider).hardwareEnterSends, isFalse);
      await container.read(settingsProvider.notifier).setHardwareEnterSends(true);
      expect(container.read(settingsProvider).hardwareEnterSends, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('hardware_enter_sends'), isTrue);
      container.invalidate(settingsProvider);
      await loaded(container);
      expect(container.read(settingsProvider).hardwareEnterSends, isTrue);
    });

    test('low device defaults do not create user preference keys', () async {
      start();
      await loaded(container);
      expect(container.read(settingsProvider).autoStartLocal, isFalse);
      expect(container.read(settingsProvider).autoStartLocalExplicit, isFalse);
      expect(container.read(petPrefsProvider).packId, noPetId);
      expect(container.read(petPrefsProvider).packExplicit, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('auto_start_local'), isFalse);
      expect(prefs.containsKey(PetPrefsController.keys.pack), isFalse);
    });

    test('existing explicit on choices survive a low device and thermal changes', () async {
      SharedPreferences.setMockInitialValues({'auto_start_local': true, 'pet.pack': 'whale-girl'});
      start();
      await loaded(container);
      channel.events.add(snapshot(DeviceTier.low, hot: true, sequence: 2));
      expect(container.read(settingsProvider).autoStartLocal, isTrue);
      expect(container.read(petPrefsProvider).packId, 'whale-girl');
      expect(container.read(settingsProvider).autoStartLocalExplicit, isTrue);
      expect(container.read(petPrefsProvider).packExplicit, isTrue);
    });

    test('existing explicit off choices survive the full mode on a high device', () async {
      SharedPreferences.setMockInitialValues({
        'auto_start_local': false,
        'pet.pack': 'none',
        'performance.mode': 'full',
      });
      start(tier: DeviceTier.high);
      await loaded(container);
      expect(container.read(settingsProvider).autoStartLocal, isFalse);
      expect(container.read(petPrefsProvider).enabled, isFalse);
      expect(container.read(performanceDefaultsProvider).blur, isTrue);
    });

    test('heat and recovery derive current defaults without persisting them', () async {
      start(tier: DeviceTier.high);
      await loaded(container);
      expect(container.read(settingsProvider).autoStartLocal, isTrue);
      channel.events.add(snapshot(DeviceTier.high, hot: true, sequence: 2));
      expect(container.read(settingsProvider).autoStartLocal, isFalse);
      expect(container.read(petPrefsProvider).packId, noPetId);
      channel.events.add(snapshot(DeviceTier.high, sequence: 3));
      expect(container.read(settingsProvider).autoStartLocal, isTrue);
      expect(container.read(petPrefsProvider).packId, defaultPetId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('auto_start_local'), isFalse);
      expect(prefs.containsKey('pet.pack'), isFalse);
    });

    test('a manual change while hot survives recovery and later mode changes', () async {
      start(tier: DeviceTier.high);
      await loaded(container);
      channel.events.add(snapshot(DeviceTier.high, hot: true, sequence: 2));
      await container.read(settingsProvider.notifier).setAutoStartLocal(true);
      await container.read(petPrefsProvider.notifier).setPack('whale-girl');
      await container.read(performancePrefsProvider.notifier).setMode(PerformanceMode.light);
      channel.events.add(snapshot(DeviceTier.high, sequence: 3));
      expect(container.read(settingsProvider).autoStartLocal, isTrue);
      expect(container.read(petPrefsProvider).packId, 'whale-girl');
      expect(container.read(performanceDefaultsProvider).lightweight, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auto_start_local'), isTrue);
      expect(prefs.getString('pet.pack'), 'whale-girl');
    });

    test('startup settings remain loading while device facts are pending', () async {
      final pending = Completer<PerformanceSnapshot>();
      start(initial: pending.future);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).loaded, isFalse);
      pending.complete(snapshot(DeviceTier.low));
      await loaded(container);
      expect(container.read(settingsProvider).autoStartLocal, isFalse);
    });

    test('a late method reply cannot overwrite a newer thermal event', () async {
      final pending = Completer<PerformanceSnapshot>();
      start(initial: pending.future);
      container.read(performanceProvider);
      channel.events.add(snapshot(DeviceTier.high, hot: true, sequence: 4));
      pending.complete(snapshot(DeviceTier.high, sequence: 1));
      await container.read(performanceProvider.notifier).ready;
      expect(container.read(performanceProvider).thermalLightweight, isTrue);
      expect(container.read(performanceProvider).sequence, 4);
    });

    for (final failed in [false, true]) {
      test('a partial thermal event survives a ${failed ? 'failed' : 'missing'} facts reply', () async {
        final pending = Completer<PerformanceSnapshot>();
        start(initial: pending.future);
        container.read(performanceProvider);
        channel.events.add(
          const PerformanceSnapshot(sequence: 3, thermal: {'lightweight': true, 'status': 2}, available: true),
        );
        if (failed) {
          pending.completeError(StateError('Native endpoint unavailable'));
        } else {
          pending.complete(const PerformanceSnapshot(loaded: true));
        }
        await loaded(container);
        final result = container.read(performanceProvider);
        expect(result.loaded, isTrue);
        expect(result.thermalLightweight, isTrue);
        expect(result.sequence, 3);
        expect(container.read(settingsProvider).autoStartLocal, isFalse);
      });
    }

    test('disposing while the device snapshot is pending does not read a disposed ref', () async {
      final pending = Completer<PerformanceSnapshot>();
      final native = FakePerformanceChannel(pending.future);
      final disposable = ProviderContainer(overrides: [performanceChannelProvider.overrideWithValue(native)]);
      disposable.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      disposable.dispose();
      pending.complete(snapshot(DeviceTier.low));
      await Future<void>.delayed(Duration.zero);
      await native.events.close();
    });

    test('a mode choice issued during preference loading wins over the old stored value', () async {
      SharedPreferences.setMockInitialValues({'performance.mode': 'full'});
      start();
      await container.read(performancePrefsProvider.notifier).setMode(PerformanceMode.light);
      expect(container.read(performancePrefsProvider).mode, PerformanceMode.light);
      expect((await SharedPreferences.getInstance()).getString('performance.mode'), 'light');
    });

    test('resetting effects removes only their overrides', () async {
      SharedPreferences.setMockInitialValues({
        'performance.mode': 'light',
        'performance.blur': true,
        'performance.animations': true,
        'auto_start_local': true,
        'pet.pack': 'whale-girl',
      });
      start();
      await loaded(container);
      expect(container.read(performanceDefaultsProvider).blur, isTrue);
      await container.read(performancePrefsProvider.notifier).resetEffects();
      expect(container.read(performanceDefaultsProvider).blur, isFalse);
      expect(container.read(performanceDefaultsProvider).reduceMotion, isTrue);
      expect(container.read(settingsProvider).autoStartLocal, isTrue);
      expect(container.read(petPrefsProvider).packId, 'whale-girl');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('performance.blur'), isFalse);
      expect(prefs.containsKey('performance.animations'), isFalse);
    });

    test('fluid motion: a choice sticks, resets, and always gives way to no animations', () async {
      SharedPreferences.setMockInitialValues({'performance.fluid': true});
      start();
      await loaded(container);
      final prefs = container.read(performancePrefsProvider.notifier);
      await prefs.ready;
      await container.read(performanceProvider.notifier).ready;
      PerformanceDefaults defaults() => container.read(performanceDefaultsProvider);
      // A low device keeps animations off by default, and fluid needs them.
      expect(defaults().reduceMotion, isTrue);
      expect(defaults().fluidMotion, isFalse);
      await prefs.setAnimations(true);
      expect(defaults().fluidMotion, isTrue);
      await prefs.setFluid(false);
      expect(defaults().fluidMotion, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('performance.fluid'), isFalse);
      await prefs.resetEffects();
      expect(container.read(performancePrefsProvider).fluid, isNull);
      expect((await SharedPreferences.getInstance()).containsKey('performance.fluid'), isFalse);
      expect(defaults().fluidMotion, isFalse);
    });
  });
}
