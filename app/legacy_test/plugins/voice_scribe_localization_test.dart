import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/voice_scribe_settings.dart';
import 'package:dsh_app/ui/plugins/voice_scribe_settings_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_scribe_settings_test.dart' show MemoryVoiceTransport;

void main() {
  test('voice titles, count and failed-read state follow the generated app locale', () async {
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final transport = MemoryVoiceTransport()..readHook = () async => throw StateError('injected read failure');
    final controller = VoiceScribeSettingsController(transport, () => true);
    addTearDown(controller.dispose);
    AppLocale.use(const Locale('en'));
    expect(voiceScribePageTitle, 'Voice settings');
    expect(appL10n.voiceScribeHotwordRules(3), '3 rules');
    await controller.refresh();
    expect(controller.error, 'Could not read voice settings. Retry.');
    AppLocale.use(AppLocale.zhCN);
    expect(voiceScribePageTitle, '语音设置');
    expect(appL10n.voiceScribeHotwordRules(3), '3 条规则');
    await controller.refresh();
    expect(controller.error, '没能读取语音设置，请重试。');
  });
}
