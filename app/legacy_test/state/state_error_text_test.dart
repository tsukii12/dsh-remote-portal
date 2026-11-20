import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/session_export.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final error in <Object>[
    const DshRemoteException('foo/bar', 'English text'),
    const DshHttpException(500, 'boom'),
    StateError('private failure'),
  ]) {
    test('state error text does not expose $error', () {
      final plugin = describePluginError(error);
      for (final text in [
        describeProviderError(error),
        describeSettingsError(error),
        plugin.title,
        plugin.message,
        sessionExportErrorText(error),
        artifactErrorText(error),
      ]) {
        expect(text, isNot(matches(RegExp(r'[A-Za-z]+(?:Exception|Error)'))));
        expect(text, isNot(contains('English text')));
        expect(text, isNot(contains('boom')));
        expect(text, isNot(contains('private failure')));
      }
    });
  }
  test('offline copy is consistent', () {
    const error = DshTransportException('private timeout');
    expect(describeProviderError(error), '没能连上引擎');
    expect(describeSettingsError(error), '没能连上引擎');
    expect(describePluginError(error).message, '没能连上引擎');
    expect(sessionExportErrorText(error), '没能连上引擎');
    expect(artifactErrorText(error), '没能连上引擎');
  });
}
