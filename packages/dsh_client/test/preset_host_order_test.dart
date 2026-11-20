import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  late FakeDsh host;
  late DshClient client;
  setUp(() async {
    host = await FakeDsh.start();
    client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
  });
  tearDown(() async {
    await client.close();
    await host.close();
  });

  Future<List<AgentPresetInfo>> read(List<Map<String, Object?>> rows) {
    host.handlers['agentPresets/list'] = (_) => {
      'ok': true,
      'value': {'presets': rows},
    };
    return client.listAgentPresets();
  }

  test('keeps Host order when an explicit order exceeds the old fallback', () async {
    final items = await read([
      {'id': 'large-order', 'order': 1048577},
      {'id': 'unspecified'},
    ]);
    expect(items.map((item) => item.id), ['large-order', 'unspecified']);
  });

  test('keeps fractional Host order without changing the integer DTO contract', () async {
    final items = await read([
      {'id': 'fraction', 'order': 0.5},
      {'id': 'integer', 'order': 1},
    ]);
    expect(items.map((item) => item.id), ['fraction', 'integer']);
    expect(items.first.order, isNull);
    expect(items.last.order, 1);
  });

  test('preserves Host tie order, default and diagnostic fields', () async {
    final items = await read([
      {'id': 'a', 'order': 2, 'isDefault': true, 'name': '默认', 'description': '说明'},
      {'id': 'b', 'order': 2, 'broken': 'diagnostic'},
      {'id': 'z'},
    ]);
    expect(items.map((item) => item.id), ['a', 'b', 'z']);
    expect(items.first.isDefault, isTrue);
    expect(items.first.name, '默认');
    expect(items.first.description, '说明');
    expect(items[1].broken, 'diagnostic');
    expect(items.last.order, isNull);
  });

  test('an empty Host roster stays empty', () async {
    expect(await read([]), isEmpty);
  });
}
