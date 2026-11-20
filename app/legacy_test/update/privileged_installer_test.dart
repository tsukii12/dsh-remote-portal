import 'package:dsh_app/update/privileged_installer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/update');
  const installer = ChannelPrivilegedInstaller();
  final calls = <MethodCall>[];
  Object? Function(MethodCall)? answer;

  setUp(() {
    calls.clear();
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer!(call);
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('status is passive and preserves root identity for explicit rejection', () async {
    answer = (_) => {
      'v': 1,
      'shizuku': {'installed': true, 'running': true, 'granted': true, 'uid': 0},
      'adb': {'paired': true},
      'pending': {'state': 'none'},
    };
    final status = await installer.status();
    expect(status.supported, isTrue);
    expect(status.shizukuUid, 0);
    expect(status.adbPaired, isTrue);
    expect(calls.map((call) => call.method), ['privilegedInstallStatus']);
  });

  test('permission is a separate explicit RPC, not install confirmation', () async {
    answer = (_) => true;
    expect(await installer.requestShizukuPermission(), isTrue);
    expect(calls.single.method, 'requestUpdateShizukuPermission');
  });

  test('full APK binding and selected route are passed without shell configuration', () async {
    answer = (_) => {'status': 'unknown', 'submitted': true, 'outcomeUnknown': true, 'errorCode': 'outcomeUnknown'};
    final result = await installer.install(
      path: '/private/cache/updates/dsh.apk', sha256: 'a' * 64, versionCode: 2,
      backend: UpdateInstallRoute.adb, port: 37123,
    );
    expect(result.status, PrivilegedInstallOutcome.unknown);
    expect(result.submitted, isTrue);
    expect(result.outcomeUnknown, isTrue);
    expect(calls.single.method, 'installPrivileged');
    expect(calls.single.arguments, {
      'path': '/private/cache/updates/dsh.apk', 'sha256': 'a' * 64, 'versionCode': 2, 'backend': 'adb', 'port': 37123,
    });
  });

  test('invalid arguments do not reach native code', () async {
    final result = await installer.install(
      path: '/private/cache/updates/dsh.apk', sha256: 'a' * 64, versionCode: 2,
      backend: UpdateInstallRoute.system,
    );
    expect(result.status, PrivilegedInstallOutcome.invalid);
    expect(result.outcomeUnknown, isFalse);
    expect(calls, isEmpty);
  });

  test('transport exceptions never become a definite failure or expose native messages', () async {
    answer = (_) => throw PlatformException(code: 'transportLost', message: 'sensitive native detail');
    final result = await installer.install(
      path: '/private/cache/updates/dsh.apk', sha256: 'a' * 64, versionCode: 2, backend: UpdateInstallRoute.shizuku,
    );
    expect(result.status, PrivilegedInstallOutcome.unknown);
    expect(result.outcomeUnknown, isTrue);
    expect(result.errorCode, 'transportLost');
    expect(calls, hasLength(1));
  });

  test('malformed results and missing acknowledge capability fail closed', () {
    final result = PrivilegedInstallResult.fromMap({'status': 'futureStatus'});
    expect(result.status, PrivilegedInstallOutcome.unknown);
    expect(result.outcomeUnknown, isTrue);
    final pending = SelfUpdatePending.fromMap({'state': 'unknown', 'errorCode': 'contains secret detail'});
    expect(pending.unresolved, isTrue);
    expect(pending.canAcknowledge, isFalse);
    expect(pending.errorCode, isNull);
    expect(SelfUpdatePending.fromMap({}).state, SelfUpdatePendingState.unknown);
  });

  for (final nativeStatus in ['failure', 'signature', 'downgrade', 'conflict']) {
    test('definite native $nativeStatus is not an unknown installation', () {
      final result = PrivilegedInstallResult.fromMap({
        'status': nativeStatus, 'outcomeUnknown': false, 'submitted': false,
      });
      expect(result.status, PrivilegedInstallOutcome.failed);
      expect(result.outcomeUnknown, isFalse);
    });
  }

  test('older native module without reconciliation cannot lock the normal route', () async {
    answer = (_) => null;
    await expectLater(installer.reconcile(), throwsA(isA<PlatformException>()));
    expect((await installer.status()).supported, isFalse);
    expect(PrivilegedInstallStatus.fromMap({'v': 1}).pending.state, SelfUpdatePendingState.none);
  });

  test('reconcile and acknowledge use distinct read and native-confirmed RPCs', () async {
    answer = (call) => call.method == 'reconcileSelfUpdate'
      ? {'state': 'unknown', 'backend': 'adb', 'versionCode': 2, 'canAcknowledge': true}
      : {'state': 'none'};
    final pending = await installer.reconcile();
    expect(pending.canAcknowledge, isTrue);
    expect(pending.backend, UpdateInstallRoute.adb);
    expect((await installer.acknowledgeUnknown()).state, SelfUpdatePendingState.none);
    expect(calls.map((call) => call.method), ['reconcileSelfUpdate', 'acknowledgeUnknownSelfUpdate']);
  });
}
