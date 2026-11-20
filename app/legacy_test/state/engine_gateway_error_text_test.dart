import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/chat_error_text.dart';
import 'package:dsh_app/state/engine_error_text.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const serviceReason = '所需的引擎服务未就绪，请查看引擎日志或导出诊断包';
  const operationReason = '引擎当前无法执行此操作，请查看引擎日志';
  const privateMessage = 'expected number >= private-key read-only no longer /private/profile';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.zhCN);
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  // The main45 real Host probe with duplicate workspace paths returned this
  // error for session/create. HTTP login had succeeded. No credentials or
  // workspace paths are needed to preserve this response's error semantics.
  test('real unavailable session controller is not a version failure', () {
    final error = DshRemoteException.fromJson({
      'code': 'gateway/service-unavailable',
      'message': 'typert gateway: session/create: active Service "sessionController" is unavailable',
      'details': {'endpoint': 'session/create'},
    });
    expect(engineErrorReason(error), serviceReason);
    expect(chatErrorText(error, action: '新建对话失败'), '新建对话失败：$serviceReason');
    expect(describeSettingsError(error), serviceReason);
  });

  for (final code in const [
    'gateway/service-unavailable',
    'gateway/context-unavailable',
    'gateway/lookup-unavailable',
  ]) {
    test('$code takes precedence over private settings message guesses', () {
      final error = DshRemoteException(code, privateMessage, {'token': 'test-secret'});
      expect(engineErrorReason(error), serviceReason);
      expect(chatErrorText(error, action: '提交失败'), '提交失败：$serviceReason');
      expect(describeSettingsError(error), serviceReason);
      expect(describeSettingsError(error), isNot(contains('private-key')));
      expect(describeSettingsError(error), isNot(contains('test-secret')));
    });
  }

  for (final code in const [
    'gateway/definition-unavailable',
    'gateway/invocation-unavailable',
    'gateway/method-unavailable',
  ]) {
    test('$code does not guess the engine version or a transient network failure', () {
      final error = DshRemoteException(code, privateMessage);
      expect(engineErrorReason(error), operationReason);
      expect(chatErrorText(error, action: '提交失败'), '提交失败：$operationReason');
      expect(describeSettingsError(error), operationReason);
    });
  }

  for (final code in const ['gateway/method-not-found', 'gateway/not-found']) {
    test('$code retains the explicit legacy unsupported response', () {
      final error = DshRemoteException(code, 'no such method');
      expect(engineErrorReason(error), appL10n.stateEngineUnsupported);
      expect(describeSettingsError(error), appL10n.stateEngineUnsupported);
    });
  }

  test('cancelled and disposed requests never become version failures', () {
    const cancelled = DshRemoteException('gateway/cancelled', privateMessage);
    const disposed = DshRemoteException('gateway/peer-disposed', privateMessage);
    expect(engineErrorReason(cancelled), appL10n.commonCancelled);
    expect(describeSettingsError(cancelled), appL10n.commonCancelled);
    expect(engineErrorReason(disposed), appL10n.commonEngineUnreachable);
    expect(describeSettingsError(disposed), appL10n.commonEngineUnreachable);
  });

  for (final code in const [
    'gateway/lookup-not-found',
    'gateway/context-not-found',
    'gateway/interactions-forbidden',
    'gateway/arguments-invalid',
    'gateway/input-invalid',
    'gateway/protocol',
    'gateway/future-code',
    'gateway/internal',
  ]) {
    test('$code keeps the neutral page fallback without exposing raw details', () {
      final error = DshRemoteException(code, 'unclassified private-value');
      expect(engineErrorReason(error), isNull);
      expect(chatErrorText(error, action: '提交失败'), '提交失败');
      expect(describeSettingsError(error), appL10n.stateSettingsRejected);
    });
  }

  test('existing settings and credential validation remains useful', () {
    expect(
      describeSettingsError(const DshRemoteException('settings/conflict', privateMessage)),
      appL10n.stateSettingsRefreshed,
    );
    expect(
      describeSettingsError(const DshRemoteException('credential/rejected', privateMessage)),
      appL10n.stateCredentialFromEnvironment,
    );
    expect(
      describeSettingsError(const DshRemoteException('gateway/internal', 'expected number >= 2')),
      appL10n.stateSettingsMinimum('2'),
    );
    // A bound that is not a number is never copied into the sentence.
    expect(
      describeSettingsError(const DshRemoteException('gateway/internal', privateMessage)),
      isNot(contains('private-key')),
    );
    expect(
      describeSettingsError(const DshRemoteException('settings/rejected', 'read-only')),
      appL10n.stateSettingsReadOnly,
    );
  });

  test('authentication and explicit missing conversation retain their own copy', () {
    for (final status in [401, 403]) {
      expect(engineErrorReason(DshHttpException(status, 'private-value')), appL10n.stateEngineAuthFailed);
    }
    expect(
      engineErrorReason(const DshCarrierRefusedException('AUTH_DENIED', 'private-value')),
      appL10n.stateEngineAuthFailed,
    );
    expect(engineErrorReason(const DshRemoteException('session/not-found', 'private-value')), appL10n.stateChatMissing);
  });

  test('the two new reasons have matching English copy', () {
    AppLocale.use(AppLocale.en);
    expect(
      engineErrorReason(const DshRemoteException('gateway/service-unavailable', privateMessage)),
      'The required engine service is not ready. Check the engine logs or export diagnostics.',
    );
    expect(
      describeSettingsError(const DshRemoteException('gateway/invocation-unavailable', privateMessage)),
      'The engine cannot run this operation right now. Check the engine logs.',
    );
  });
}
