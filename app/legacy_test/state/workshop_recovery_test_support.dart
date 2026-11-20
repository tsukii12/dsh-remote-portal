import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'workshop_auth_test_support.dart';
import 'workshop_publish_test_support.dart';

const recoveryPendingKey = 'workshop.pending.v1';
const recoveryRequestsKey = 'workshop.request_ids.v1';
const recoveryDisclosuresKey = 'workshop.disclosures.v1';

/// The real plugin's in-memory platform, with only its pending-key write and
/// storage read boundaries controlled. All successful calls delegate to it.
class RecoveryPlatformStore extends InMemorySharedPreferencesStore {
  RecoveryPlatformStore(Map<String, Object> values)
    : super.withData({for (final entry in values.entries) 'flutter.${entry.key}': entry.value});

  bool failRead = false, failPendingWrite = false, persistBeforeFailure = false;
  int pendingWrites = 0, pendingRemoves = 0;
  Future<void> Function()? beforePendingWrite;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('Synthetic preference read failure');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key != 'flutter.$recoveryPendingKey') return super.setValue(valueType, key, value);
    pendingWrites++;
    if (beforePendingWrite != null) await beforePendingWrite!();
    if (failPendingWrite) {
      if (persistBeforeFailure) await super.setValue(valueType, key, value);
      return false;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (key != 'flutter.$recoveryPendingKey') return super.remove(key);
    pendingRemoves++;
    if (beforePendingWrite != null) await beforePendingWrite!();
    if (failPendingWrite) {
      if (persistBeforeFailure) await super.remove(key);
      return false;
    }
    return super.remove(key);
  }

  Future<Object?> raw(String key) async => (await getAll())['flutter.$key'];
}

RecoveryPlatformStore recoveryPlatform([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues({});
  final previous = SharedPreferencesStorePlatform.instance;
  final platform = RecoveryPlatformStore(values);
  SharedPreferencesStorePlatform.instance = platform;
  addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
  return platform;
}

/// Reuses the existing publisher harness without weakening the real journal.
/// Disclosure is the existing auth fake; all journal/id operations and both
/// recovery operations use the same real PrefsWorkshopPreferences instance.
class RecoveryPreferences extends PublishPreferences implements WorkshopPendingRecoveryStore {
  RecoveryPreferences(super.events);
  final real = const PrefsWorkshopPreferences();
  int recoveryReads = 0, abandonments = 0;
  Future<void> Function()? afterRecoveryRead;

  @override
  Future<WorkshopPendingSubmission?> pendingSubmission(String scope) {
    reads++;
    events.add('read-pending');
    return real.pendingSubmission(scope);
  }

  @override
  Future<String> reserveSubmissionRequestId(String fingerprint, String proposed) =>
      real.reserveSubmissionRequestId(fingerprint, proposed);

  @override
  Future<void> retireSubmissionRequestId(String fingerprint, String expectedRequestId) =>
      real.retireSubmissionRequestId(fingerprint, expectedRequestId);

  @override
  Future<void> savePendingSubmission(String scope, WorkshopPendingSubmission pending) async {
    await real.savePendingSubmission(scope, pending);
    saved.add(pending);
  }

  @override
  Future<void> clearPendingSubmission(String scope, String expectedRequestId) {
    clears++;
    return real.clearPendingSubmission(scope, expectedRequestId);
  }

  @override
  Future<WorkshopPendingRecoverySnapshot> pendingRecovery(String scope) async {
    recoveryReads++;
    final snapshot = await real.pendingRecovery(scope);
    if (afterRecoveryRead != null) await afterRecoveryRead!();
    return snapshot;
  }

  @override
  Future<void> abandonPendingRecovery(WorkshopPendingRecoverySnapshot snapshot) {
    abandonments++;
    return real.abandonPendingRecovery(snapshot);
  }
}

String recoveryScope({Uri? worker, Uri? account, int userId = 42}) => sha256.convert(utf8.encode(jsonEncode([
  (worker ?? authWorker).toString(), (account ?? authAccount).toString(), userId,
]))).toString();

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

WorkshopPendingSubmission recoveryPending({String? scope, String? requestId, WorkshopMetadata? metadata}) {
  final value = metadata ?? publishInput().publication('pet').withArchive('a' * 64, 4);
  final fingerprint = sha256.convert(utf8.encode(jsonEncode(_canonical([
    scope ?? recoveryScope(), value.toJson(),
  ])))).toString();
  return WorkshopPendingSubmission(requestId: requestId ?? 'a' * 32, fingerprint: fingerprint,
    directoryName: 'draft-recovery', metadata: value, files: ['pack.json', 'idle.png']);
}
