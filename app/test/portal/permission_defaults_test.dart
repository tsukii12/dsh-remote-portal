import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Rpc extends Fake implements DshRpc {
  final calls = <(String, Map<String, Object?>)>[];
  bool fail = false;
  @override
  Future<Object?> call(String endpoint, [Map<String, Object?> args = const {}, Duration? timeout]) async {
    calls.add((endpoint, args));
    if (fail) throw StateError('offline');
    return {
      'value': {'defaultPreset': 'danger-full-access'},
      'revision': 8,
    };
  }
}

class _Client extends Fake implements DshClient {
  _Client(this.rpc);
  @override
  final DshRpc rpc;
}

void main() {
  test('full access writes the portal host default, not a local auto-approve preference', () async {
    final rpc = _Rpc();
    expect(await writePermissionDefault(_Client(rpc), 'danger-full-access', 7), isNull);
    expect(rpc.calls, hasLength(1));
    expect(rpc.calls.single.$1, 'settings/mutate');
    expect(rpc.calls.single.$2, {
      'ns': 'permission',
      'ops': [
        {
          'op': 'set',
          'path': ['defaultPreset'],
          'value': 'danger-full-access',
        },
      ],
      'expectedRevision': 7,
    });
  });

  test('failed host write returns an error without a local fallback', () async {
    final rpc = _Rpc()..fail = true;
    expect(await writePermissionDefault(_Client(rpc), 'workspace-write', 7), isNotEmpty);
    expect(rpc.calls, hasLength(1));
  });
}
