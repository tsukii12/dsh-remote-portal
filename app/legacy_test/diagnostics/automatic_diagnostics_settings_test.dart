import 'dart:async';

import 'package:dsh_app/diagnostics/automatic_diagnostics.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'automatic_diagnostics_test.dart' show sample;

enum _WriteReply { success, refused, exception }

/// Only persistence is replaced; SettingsController and its load/setter remain
/// real, including the SharedPreferences cache and asynchronous acknowledgement.
class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();

  _WriteReply reply = _WriteReply.success;
  bool failRead = false;
  Completer<void>? writeGate;
  Completer<void>? writeEntered;

  @override
  Future<Map<String, Object>> getAll() {
    if (failRead) throw PlatformException(code: 'synthetic_read_failure');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.automatic_diagnostics') {
      writeEntered?.complete();
      await writeGate?.future;
      switch (reply) {
        case _WriteReply.refused:
          return false;
        case _WriteReply.exception:
          throw PlatformException(code: 'synthetic_write_failure');
        case _WriteReply.success:
          break;
      }
    }
    return super.setValue(type, key, value);
  }
}

Future<ProviderContainer> _loadedSettings(_Preferences store) async {
  SharedPreferences.setMockInitialValues({});
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferencesStorePlatform.instance = store;
  addTearDown(() {
    if (store.writeGate case final gate? when !gate.isCompleted) gate.complete();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previous;
  });
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final loaded = Completer<void>();
  final subscription = container.listen(settingsProvider, (_, next) {
    if (next.loaded && !loaded.isCompleted) loaded.complete();
  }, fireImmediately: true);
  addTearDown(subscription.close);
  await loaded.future;
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('paid analysis cannot start before the opt-in write is acknowledged', () async {
    final store = _Preferences();
    final container = await _loadedSettings(store);
    var sends = 0;
    final sent = Completer<void>();
    final automatic = AutomaticDiagnostics(collect: () async => sample(), load: () async => {}, store: (_) async {});
    addTearDown(automatic.dispose);
    final owner = Object();
    final enabled = container.listen(settingsProvider.select((s) => s.automaticDiagnostics), (_, next) {
      automatic.configure(
        next ? owner : null,
        next
            ? (_, _, _) async {
                sends++;
                sent.complete();
              }
            : null,
      );
      unawaited(automatic.check());
    });
    addTearDown(enabled.close);
    store.writeEntered = Completer<void>();
    store.writeGate = Completer<void>();
    final saving = container.read(settingsProvider.notifier).setAutomaticDiagnostics(true);
    await store.writeEntered!.future;
    expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
    await automatic.check();
    expect(sends, 0, reason: 'persistence is still pending');
    store.writeGate!.complete();
    await saving;
    await sent.future;
    expect(container.read(settingsProvider).automaticDiagnostics, isTrue);
    expect(sends, 1);
  });

  for (final reply in [_WriteReply.refused, _WriteReply.exception]) {
    test('a $reply opt-in write fails closed without an enabled transition', () async {
      final store = _Preferences()..reply = reply;
      final container = await _loadedSettings(store);
      final transitions = <bool>[];
      final subscription = container.listen(settingsProvider.select((s) => s.automaticDiagnostics), (_, next) {
        transitions.add(next);
      });
      addTearDown(subscription.close);
      await expectLater(container.read(settingsProvider.notifier).setAutomaticDiagnostics(true), throwsA(anything));
      expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
      expect(transitions, isNot(contains(true)));
      expect((await store.getAll())['flutter.automatic_diagnostics'], isNot(true));
    });
  }

  test('getInstance failure while enabling leaves the in-memory opt-in off', () async {
    final store = _Preferences();
    final container = await _loadedSettings(store);
    store.failRead = true;
    SharedPreferences.resetStatic();
    final transitions = <bool>[];
    final subscription = container.listen(settingsProvider.select((s) => s.automaticDiagnostics), (_, next) {
      transitions.add(next);
    });
    addTearDown(subscription.close);
    await expectLater(container.read(settingsProvider.notifier).setAutomaticDiagnostics(true), throwsA(anything));
    expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
    expect(transitions, isNot(contains(true)));
  });

  test('disabling revokes immediately even when its persistence later fails', () async {
    final store = _Preferences();
    final container = await _loadedSettings(store);
    final settings = container.read(settingsProvider.notifier);
    await settings.setAutomaticDiagnostics(true);
    expect(container.read(settingsProvider).automaticDiagnostics, isTrue);
    store.reply = _WriteReply.exception;
    store.writeEntered = Completer<void>();
    store.writeGate = Completer<void>();
    final saving = settings.setAutomaticDiagnostics(false);
    final failed = expectLater(saving, throwsA(isA<PlatformException>()));
    await store.writeEntered!.future;
    expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
    store.writeGate!.complete();
    await failed;
    expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
  });
}
