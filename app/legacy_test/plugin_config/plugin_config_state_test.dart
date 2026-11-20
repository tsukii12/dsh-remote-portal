// The plugin configuration controller over the in-memory Host interface:
// live fields at once, the rest held until 保存 and applied with a reload,
// progress, a failed reload retried, put back or dropped, write-only secrets,
// conflicts, and 全部恢复默认. Then the live-only adapter over DSH 0.2.1's
// settings/describe and settings/mutate.

import 'dart:async';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'fake_bridge.dart' show bridgeBundles;
import 'support.dart';

void main() {
  test('a complete form tells live fields from the rest', () async {
    final api = sampleConfigApi();
    final c = await configContainer(api);
    final state = c.read(pluginConfigProvider).value!;
    expect(state.complete, isTrue);
    final form = state['speech-to-text-sensevoice']!;
    expect(form.isLive(['language']), isTrue);
    expect(form.isLive(['precision']), isFalse);
    expect(form.isLive(['vad', 'threshold']), isFalse);
    expect(form.hasReloadFields, isTrue);
    expect(state['weather']!.prefersOwnPage, isTrue);
  });

  test('a live field goes at once; nothing is held', () async {
    final api = sampleConfigApi();
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    expect(await controller.set(voice(['language']), 'zh'), isTrue);
    expect(api.calls.where((call) => call.$1 == 'apply'), hasLength(1));
    final state = c.read(pluginConfigProvider).value!;
    expect(state.hasDraft('speech-to-text-sensevoice'), isFalse);
    expect(state.settingsFor('speech-to-text-sensevoice').valueOf(voice(['language'])), 'zh');
    expect(api.entries['speech-to-text-sensevoice']!.user, {'language': 'zh'});
  });

  test('a reload field is held, shown, and taken back by setting it back', () async {
    final api = sampleConfigApi();
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    await controller.set(voice(['precision']), 'fp32');
    await controller.set(voice(['vad', 'threshold']), 0.7);
    expect(api.calls.where((call) => call.$1 == 'apply'), isEmpty);
    var state = c.read(pluginConfigProvider).value!;
    expect(state.draftOf('speech-to-text-sensevoice'), hasLength(2));
    final shown = state.settingsFor('speech-to-text-sensevoice');
    expect(shown.valueOf(voice(['precision'])), 'fp32');
    expect(shown.isStaged(voice(['precision'])), isTrue);
    expect(shown.layerOf(voice(['vad', 'threshold'])), FieldLayer.user, reason: 'a partial group is not a home patch');
    // Back to what the Host has: no longer an edit.
    await controller.set(voice(['precision']), 'int8');
    state = c.read(pluginConfigProvider).value!;
    expect(state.draftOf('speech-to-text-sensevoice').map((op) => op.path), [
      ['vad', 'threshold'],
    ]);
  });

  test('保存 applies the held edits together with a reload, step by step', () async {
    final api = sampleConfigApi()..gate = Completer<void>();
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    await controller.set(voice(['precision']), 'fp32');
    await controller.set(voice(['threads']), 4);
    final steps = <PluginConfigStep?>[];
    c.listen(pluginConfigProvider, (_, next) {
      final step = next.value?.jobOf('speech-to-text-sensevoice')?.step;
      if (steps.lastOrNull != step) steps.add(step);
    });
    final saved = controller.save('speech-to-text-sensevoice');
    await pumpEventQueue();
    var state = c.read(pluginConfigProvider).value!;
    expect(state.isApplying('speech-to-text-sensevoice'), isTrue);
    expect(state.settingsFor('speech-to-text-sensevoice').canWrite('speech-to-text-sensevoice'), isFalse);
    api.gate!.complete();
    expect(await saved, isTrue);
    expect(steps, containsAllInOrder([PluginConfigStep.saving, PluginConfigStep.reloading]));
    state = c.read(pluginConfigProvider).value!;
    expect(state.hasDraft('speech-to-text-sensevoice'), isFalse);
    expect(state.jobOf('speech-to-text-sensevoice')!.done, isTrue);
    expect(api.entries['speech-to-text-sensevoice']!.user, {'precision': 'fp32', 'threads': 4});
    expect(api.calls.where((call) => call.$1 == 'apply'), hasLength(1), reason: 'one apply, one reload');
    expect(state.settingsFor('speech-to-text-sensevoice').valueOf(voice(['threads'])), 4);
  });

  test('a failed reload the Host undid keeps the edits for 重试', () async {
    final api = sampleConfigApi()..failNextReload = 'model missing';
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    await controller.set(voice(['precision']), 'fp32');
    expect(await controller.save('speech-to-text-sensevoice'), isFalse);
    await pumpEventQueue();
    var state = c.read(pluginConfigProvider).value!;
    final failure = state.jobOf('speech-to-text-sensevoice')!.failure!;
    expect(failure.kind, PluginConfigFailureKind.reloadFailed);
    expect(failure.rolledBack, isTrue);
    expect(failure.settled, isTrue);
    expect(api.entries['speech-to-text-sensevoice']!.user, isEmpty, reason: 'the Host put the old values back');
    expect(state.draftOf('speech-to-text-sensevoice'), hasLength(1), reason: 'the edit waits for 重试');
    expect(await controller.retry('speech-to-text-sensevoice'), isTrue);
    state = c.read(pluginConfigProvider).value!;
    expect(state.hasDraft('speech-to-text-sensevoice'), isFalse);
    expect(api.entries['speech-to-text-sensevoice']!.user, {'precision': 'fp32'});
  });

  test('a failed reload the Host could not undo is put back by 恢复原设置', () async {
    final api = sampleConfigApi()
      ..failNextReload = 'crashed'
      ..undoFails = true;
    api.entries['speech-to-text-sensevoice']!.user = {'threads': 3};
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    await controller.set(voice(['threads']), 8);
    await controller.set(voice(['precision']), 'fp32');
    await controller.save('speech-to-text-sensevoice');
    await pumpEventQueue();
    var state = c.read(pluginConfigProvider).value!;
    final job = state.jobOf('speech-to-text-sensevoice')!;
    expect(job.failure!.settled, isFalse);
    expect(state['speech-to-text-sensevoice']!.failed, isTrue);
    expect(job.undo.map(_op), ['set threads 3', 'unset precision']);
    expect(await controller.rollback('speech-to-text-sensevoice'), isTrue);
    state = c.read(pluginConfigProvider).value!;
    expect(api.entries['speech-to-text-sensevoice']!.user, {'threads': 3});
    expect(state.hasDraft('speech-to-text-sensevoice'), isFalse);
    expect(state.jobOf('speech-to-text-sensevoice')?.failure, isNull);
  });

  test('放弃 drops the held edits; a refused save keeps them with the reason', () async {
    final api = sampleConfigApi()..rejectNext = 'expected number <= 1 but got 3';
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    await controller.set(voice(['vad', 'threshold']), 0.9);
    expect(await controller.save('speech-to-text-sensevoice'), isFalse);
    var state = c.read(pluginConfigProvider).value!;
    expect(state.jobOf('speech-to-text-sensevoice')!.failure!.kind, PluginConfigFailureKind.rejected);
    expect(state.hasDraft('speech-to-text-sensevoice'), isTrue);
    controller.discard('speech-to-text-sensevoice');
    state = c.read(pluginConfigProvider).value!;
    expect(state.hasDraft('speech-to-text-sensevoice'), isFalse);
    expect(state.jobOf('speech-to-text-sensevoice'), isNull);
    expect(state.settingsFor('speech-to-text-sensevoice').valueOf(voice(['vad', 'threshold'])), 0.5);
  });

  test('a key with the plugin values is held write-only and never read back', () async {
    final api = sampleConfigApi();
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    final key = translator(['apiKey']);
    expect(c.read(pluginConfigProvider).value!.settingsFor('translator').secretConfigured(key), isFalse);
    await controller.setSecret(key, 'sk-secret');
    var shown = c.read(pluginConfigProvider).value!.settingsFor('translator');
    expect(shown.secretConfigured(key), isTrue);
    expect(shown.isStaged(key), isTrue);
    expect(shown['translator']!.value.containsKey('apiKey'), isFalse);
    expect(await controller.save('translator'), isTrue);
    expect(api.entries['translator']!.secrets, {'apiKey': 'sk-secret'});
    shown = c.read(pluginConfigProvider).value!.settingsFor('translator');
    expect(shown.secretConfigured(key), isTrue);
    expect(shown['translator']!.value.containsKey('apiKey'), isFalse);
    expect(shown['translator']!.user?.containsKey('apiKey') ?? false, isFalse);
  });

  test('someone else changed the plugin: the save fails, the form re-reads', () async {
    final api = sampleConfigApi();
    final c = await configContainer(api);
    final controller = c.read(pluginConfigProvider.notifier);
    await controller.set(voice(['precision']), 'fp32');
    api.entries['speech-to-text-sensevoice']!
      ..user = {'threads': 6}
      ..revision += 1;
    expect(await controller.save('speech-to-text-sensevoice'), isFalse);
    await pumpEventQueue();
    final state = c.read(pluginConfigProvider).value!;
    expect(state.jobOf('speech-to-text-sensevoice')!.failure!.kind, PluginConfigFailureKind.conflict);
    expect(state.settingsFor('speech-to-text-sensevoice').valueOf(voice(['threads'])), 6);
    expect(await controller.retry('speech-to-text-sensevoice'), isTrue);
    expect(api.entries['speech-to-text-sensevoice']!.user, {'threads': 6, 'precision': 'fp32'});
  });

  test('全部恢复默认: live fields at once, the rest held; keys stay', () async {
    final api = sampleConfigApi();
    api.entries['translator']!
      ..user = {'provider': 'google', 'timeoutMs': 5000}
      ..secrets['apiKey'] = 'sk';
    final c = await configContainer(api);
    await c.read(pluginConfigProvider.notifier).resetAll('translator');
    final state = c.read(pluginConfigProvider).value!;
    expect(api.entries['translator']!.user, {'timeoutMs': 5000}, reason: 'the live service went at once');
    expect(state.draftOf('translator').map(_op), ['unset timeoutMs']);
    expect(state.settingsFor('translator').valueOf(translator(['timeoutMs'])), 10000);
    expect(api.entries['translator']!.secrets, {'apiKey': 'sk'});
  });

  test('DSH 0.2.1: the engine settings serve live fields only, written through settings/mutate', () async {
    // Thinking translation switched on: its rows are a plugin's.
    final host = FakeSettingsHost()..bundles = bridgeBundles();
    final c = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
    addTearDown(c.dispose);
    final sub = c.listen(pluginConfigProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(pluginConfigProvider.future);
    await c.read(installedPluginsProvider.future);
    await pumpEventQueue();
    final state = c.read(pluginConfigProvider).value!;
    expect(state.complete, isFalse);
    expect(state['agent-loop'], isNull, reason: 'DSH\'s own, served with live fields too');
    final form = state['cot-translation']!;
    expect(form.allLive, isTrue);
    expect(form.isLive(['anything']), isTrue);
    final field = const FieldRef('cot-translation', ['targetLanguage']);
    expect(await c.read(pluginConfigProvider.notifier).set(field, 'en'), isTrue);
    expect(host.mutates().single['ns'], 'cot-translation');
    expect(c.read(engineSettingsProvider).value!.valueOf(field), 'en', reason: 'one state with the engine pages');
    await pumpEventQueue();
    expect(c.read(pluginConfigProvider).value!.settingsFor('cot-translation').valueOf(field), 'en');
    expect(c.read(pluginConfigProvider).value!.hasDraft('cot-translation'), isFalse);
    // A refusal is in words, nothing written.
    host.writable = false;
    expect(await c.read(pluginConfigProvider.notifier).set(field, 'ja'), isFalse);
    expect(c.read(pluginConfigProvider).value!.errors[field.key], isNotNull);
  });
}

String _op(SettingsOp op) => [op.op, op.path.join('.'), if (op.op == 'set') '${op.value}'].join(' ');
