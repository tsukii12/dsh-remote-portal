import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  late FakeDsh host;
  late DshClient client;

  setUp(() async {
    host = await FakeDsh.start();
    client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
  });
  tearDown(() async {
    await client.close();
    await host.close();
  });

  test('the normalized session selection and saved default are independent', () async {
    host.handlers['session/selectModel'] = (args) {
      expect(args, {
        'request': {'sessionId': 's', 'provider': 'p', 'model': 'm', 'reasoningEffort': 'high'},
      });
      return {
        'ok': true,
        'value': {
          'selected': {'provider': 'p', 'model': 'normalized', 'reasoningEffort': 'medium'},
          'defaultSave': {'status': 'saved'},
        },
      };
    };

    final result = await client.setModelResult('s', provider: 'p', model: 'm', reasoningEffort: 'high');
    expect(result.selected.toJson(), {'provider': 'p', 'model': 'normalized', 'reasoningEffort': 'medium'});
    expect(result.defaultSave!.status, ModelDefaultSaveStatus.saved);
    expect(result.defaultSave!.code, isNull);
    expect(host.rpcCalls, hasLength(1));
  });

  for (final entry in [
    (wire: 'failed', status: ModelDefaultSaveStatus.failed, code: 'settings/default-save-failed'),
    (wire: 'skipped', status: ModelDefaultSaveStatus.skipped, code: 'settings/fixed-default'),
  ]) {
    test('${entry.wire} persistence keeps the accepted session selection', () async {
      host.handlers['session/selectModel'] = (_) => {
        'ok': true,
        'value': {
          'selected': {'provider': 'p', 'model': 'accepted'},
          'defaultSave': {'status': entry.wire, 'code': entry.code},
        },
      };

      final result = await client.setModelResult('s', provider: 'p', model: 'm');
      expect(result.selected.model, 'accepted');
      expect(result.defaultSave!.status, entry.status);
      expect(result.defaultSave!.code, entry.code);
      // Existing callers still receive the accepted model, not a save failure.
      expect((await client.setModel('s', provider: 'p', model: 'm')).model, 'accepted');
    });
  }

  test('old hosts cannot be mistaken for a persistence acknowledgement', () async {
    host.handlers['session/selectModel'] = (_) => {
      'ok': true,
      'value': {
        'selected': {'provider': 'p', 'model': 'legacy', 'reasoningEffort': 'high'},
      },
    };

    final result = await client.setModelResult('s', provider: 'p', model: 'm');
    expect(result.selected.model, 'legacy');
    expect(result.selected.reasoningEffort, 'high');
    expect(result.defaultSave, isNull);
    expect((await client.setModel('s', provider: 'p', model: 'm')).model, 'legacy');
  });

  test('unknown or malformed acknowledgements never mean saved', () async {
    for (final acknowledgement in [
      {'status': 'future-state'},
      {'status': true},
      <String, Object?>{},
    ]) {
      host.handlers['session/selectModel'] = (_) => {
        'ok': true,
        'value': {
          'selected': {'provider': 'p', 'model': 'accepted'},
          'defaultSave': acknowledgement,
        },
      };
      final result = await client.setModelResult('s', provider: 'p', model: 'm');
      expect(result.selected.model, 'accepted');
      expect(result.defaultSave!.status, ModelDefaultSaveStatus.unknown);
    }
    expect(ModelDefaultSave.fromJson('invalid'), isNull);
  });

  test('model rejection remains a remote failure, not a default-save warning', () async {
    host.handlers['session/selectModel'] = (_) => {
      'ok': false,
      'error': {'code': 'session/model-unavailable', 'message': 'Unavailable', 'details': <String, Object?>{}},
    };

    await expectLater(
      client.setModelResult('s', provider: 'p', model: 'm'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session/model-unavailable')),
    );
  });
}
