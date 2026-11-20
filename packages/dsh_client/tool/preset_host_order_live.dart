import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';

Future<void> main() async {
  final launch = DshLaunchUrl.tryParse(Platform.environment['OWN_LAUNCH']!)!;
  final client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token);
  try {
    final raw = await client.rpc.call('agentPresets/list');
    final decoded = await client.listAgentPresets();
    final rows = (raw as Map)['presets'] as List;
    final host = rows.where((row) => (row as Map)['id'].toString().startsWith('own-')).toList();
    final sdk = decoded.where((row) => row.id.startsWith('own-')).map((row) => {
      'id': row.id, 'order': row.order, 'broken': row.broken,
    }).toList();
    final hostIds = host.map((row) => (row as Map)['id']).toList();
    final sdkIds = sdk.map((row) => row['id']).toList();
    final wireDefaults = rows.where((row) => (row as Map)['isDefault'] == true).map((row) => (row as Map)['id']).toList();
    final sdkDefaults = decoded.where((row) => row.isDefault).map((row) => row.id).toList();
    print(jsonEncode({'host': host, 'sdk': sdk, 'hostDefaults': wireDefaults, 'sdkDefaults': sdkDefaults}));
    if (host.any((row) => (row as Map)['broken'] != null)) throw StateError('Own preset activation failed');
    if (jsonEncode(hostIds) != jsonEncode(['own-fraction', 'own-low', 'own-tie-a', 'own-tie-b', 'own-high', 'own-unspecified'])) {
      throw StateError('Unexpected official Host order');
    }
    if (jsonEncode(hostIds) != jsonEncode(sdkIds)) throw StateError('SDK changed actual Host preset order');
    if (wireDefaults.length != 1 || jsonEncode(wireDefaults) != jsonEncode(sdkDefaults)) throw StateError('Default selection changed');
  } finally {
    await client.close();
  }
}
