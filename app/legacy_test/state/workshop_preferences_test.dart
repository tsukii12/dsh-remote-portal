import 'dart:convert';

import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../workshop/support.dart' show workshopMeta;

final _worker = Uri.parse('https://workshop.example');
final _account = Uri.parse('https://github.com');
final _scope = '1' * 64, _otherScope = '2' * 64;
final _fingerprint = 'a' * 64;
final _firstId = 'a' * 32, _secondId = 'b' * 32;

Matcher _error(String code) => throwsA(isA<WorkshopException>().having((error) => error.code, 'code', code));

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore() : super.empty();
  bool fail = true;
  @override
  Future<bool> setValue(String type, String key, Object value) =>
    fail ? Future.value(false) : super.setValue(type, key, value);
}

_FailingStore _failingStore() {
  final previous = SharedPreferencesStorePlatform.instance;
  final store = _FailingStore();
  SharedPreferencesStorePlatform.instance = store;
  addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
  return store;
}

WorkshopPendingSubmission _pending({String? requestId, String version = '1.0.0'}) => WorkshopPendingSubmission(
  requestId: requestId ?? _firstId, fingerprint: _fingerprint, directoryName: 'draft-test-one',
  metadata: WorkshopMetadata.fromJson(workshopMeta(version: version)), files: ['pack.json', 'idle.png'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('disclosure defaults off and persists only for the normalized source pair', () async {
    final preferences = PrefsWorkshopPreferences();
    expect(await preferences.disclosureAccepted(_worker, _account), isFalse);
    await preferences.acceptDisclosure(Uri.parse('https://workshop.example/'), _account);
    expect(await PrefsWorkshopPreferences().disclosureAccepted(_worker, _account), isTrue);
    expect(await preferences.disclosureAccepted(Uri.parse('https://elsewhere.example'), _account), isFalse);
    expect(await preferences.disclosureAccepted(_worker, Uri.parse('https://another-account.example')), isFalse);
    final stored = await SharedPreferences.getInstance();
    final pairs = stored.getStringList('workshop.disclosures.v1')!;
    expect(pairs.map(jsonDecode), [[_worker.toString(), _account.toString()]]);
  });

  test('a failed disclosure setter cannot survive reload in the same or a new instance', () async {
    final store = _failingStore();
    final preferences = PrefsWorkshopPreferences();
    await expectLater(preferences.acceptDisclosure(_worker, _account), _error('workshop_preferences'));
    expect(await preferences.disclosureAccepted(_worker, _account), isFalse);
    expect(await PrefsWorkshopPreferences().disclosureAccepted(_worker, _account), isFalse);
    store.fail = false;
    await preferences.acceptDisclosure(_worker, _account);
    expect(await PrefsWorkshopPreferences().disclosureAccepted(_worker, _account), isTrue);
  });

  test('concurrent instances reserve one first identifier for identical metadata bytes', () async {
    final one = PrefsWorkshopPreferences(), two = PrefsWorkshopPreferences();
    final ids = await Future.wait([
      one.reserveSubmissionRequestId(_fingerprint, _firstId),
      two.reserveSubmissionRequestId(_fingerprint, _secondId),
    ]);
    expect(ids, [_firstId, _firstId]);
    expect(await two.reserveSubmissionRequestId('b' * 64, _secondId), _secondId);
    expect(await PrefsWorkshopPreferences().reserveSubmissionRequestId(_fingerprint, _secondId), _firstId);
  });

  test('a failed reservation leaves no cached identifier for a later retry', () async {
    final store = _failingStore();
    final preferences = PrefsWorkshopPreferences();
    await expectLater(preferences.reserveSubmissionRequestId(_fingerprint, _firstId), _error('workshop_preferences'));
    store.fail = false;
    expect(await preferences.reserveSubmissionRequestId(_fingerprint, _secondId), _secondId);
    expect(await PrefsWorkshopPreferences().reserveSubmissionRequestId(_fingerprint, _firstId), _secondId);
  });

  test('retirement requires the expected identifier and permits an explicit new request', () async {
    final preferences = PrefsWorkshopPreferences();
    await preferences.reserveSubmissionRequestId(_fingerprint, _firstId);
    await preferences.retireSubmissionRequestId(_fingerprint, _secondId);
    expect(await preferences.reserveSubmissionRequestId(_fingerprint, _secondId), _firstId);
    await preferences.retireSubmissionRequestId(_fingerprint, _firstId);
    expect(await preferences.reserveSubmissionRequestId(_fingerprint, _secondId), _secondId);
  });

  test('a failed retirement reloads the old durable identifier', () async {
    final store = _failingStore()..fail = false;
    final preferences = PrefsWorkshopPreferences();
    await preferences.reserveSubmissionRequestId(_fingerprint, _firstId);
    store.fail = true;
    await expectLater(preferences.retireSubmissionRequestId(_fingerprint, _firstId), _error('workshop_preferences'));
    store.fail = false;
    expect(await PrefsWorkshopPreferences().reserveSubmissionRequestId(_fingerprint, _secondId), _firstId);
    await preferences.retireSubmissionRequestId(_fingerprint, _firstId);
    expect(await preferences.reserveSubmissionRequestId(_fingerprint, _secondId), _secondId);
  });

  test('pending submission round-trips exact metadata and clears only its expected request', () async {
    final preferences = PrefsWorkshopPreferences(), pending = _pending();
    expect(await preferences.pendingSubmission(_scope), isNull);
    await preferences.savePendingSubmission(_scope, pending);
    final restored = (await PrefsWorkshopPreferences().pendingSubmission(_scope))!;
    expect(restored.toJson(), pending.toJson());
    expect(restored.files, ['pack.json', 'idle.png']);
    await preferences.clearPendingSubmission(_scope, _secondId);
    expect((await preferences.pendingSubmission(_scope))!.requestId, _firstId);
    await preferences.clearPendingSubmission(_scope, _firstId);
    expect(await PrefsWorkshopPreferences().pendingSubmission(_scope), isNull);
  });

  test('a pending request cannot be replaced by another request or changed metadata', () async {
    final preferences = PrefsWorkshopPreferences(), pending = _pending();
    await preferences.savePendingSubmission(_scope, pending);
    await expectLater(preferences.savePendingSubmission(_scope, _pending(requestId: _secondId)),
      _error('workshop_pending_submission'));
    await expectLater(preferences.savePendingSubmission(_scope, _pending(version: '2.0.0')),
      _error('workshop_request_id_reused'));
    expect((await preferences.pendingSubmission(_scope))!.toJson(), pending.toJson());
  });

  test('a failed pending write is not mistaken for a durable recovery record', () async {
    final store = _failingStore();
    final preferences = PrefsWorkshopPreferences(), pending = _pending();
    await expectLater(preferences.savePendingSubmission(_scope, pending), _error('workshop_preferences'));
    expect(await preferences.pendingSubmission(_scope), isNull);
    expect(await PrefsWorkshopPreferences().pendingSubmission(_scope), isNull);
    store.fail = false;
    await preferences.savePendingSubmission(_scope, pending);
    expect((await PrefsWorkshopPreferences().pendingSubmission(_scope))!.toJson(), pending.toJson());
  });

  test('a failed pending clear retains the durable recovery record', () async {
    final store = _failingStore()..fail = false;
    final preferences = PrefsWorkshopPreferences(), pending = _pending();
    await preferences.savePendingSubmission(_scope, pending);
    store.fail = true;
    await expectLater(preferences.clearPendingSubmission(_scope, _firstId), _error('workshop_preferences'));
    expect((await PrefsWorkshopPreferences().pendingSubmission(_scope))!.toJson(), pending.toJson());
    store.fail = false;
    await preferences.clearPendingSubmission(_scope, _firstId);
    expect(await preferences.pendingSubmission(_scope), isNull);
  });

  test('pending records in distinct account scopes do not overwrite each other', () async {
    final preferences = PrefsWorkshopPreferences();
    await Future.wait([
      preferences.savePendingSubmission(_scope, _pending()),
      PrefsWorkshopPreferences().savePendingSubmission(_otherScope, _pending(requestId: _secondId)),
    ]);
    expect((await preferences.pendingSubmission(_scope))!.requestId, _firstId);
    expect((await preferences.pendingSubmission(_otherScope))!.requestId, _secondId);
    await preferences.clearPendingSubmission(_scope, _firstId);
    expect((await preferences.pendingSubmission(_otherScope))!.requestId, _secondId);
  });

  test('an unreadable local journal reports a stable preference error', () async {
    for (final raw in ['{', jsonEncode({_scope: null}), jsonEncode({_scope: <String, Object?>{}})]) {
      SharedPreferences.setMockInitialValues({'workshop.pending.v1': raw});
      final preferences = PrefsWorkshopPreferences();
      await expectLater(preferences.pendingSubmission(_scope), _error('workshop_preferences'));
      await expectLater(preferences.savePendingSubmission(_scope, _pending()), _error('workshop_preferences'));
      await expectLater(preferences.clearPendingSubmission(_scope, _firstId), _error('workshop_preferences'));
    }
  });
}
