import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _WorkspaceCarrier extends DshCarrier implements WorkspaceUploadCarrier {
  @override
  String get kind => 'workspace-test';
  @override
  DshTracer? get tracer => null;
  @override
  bool allowsEndpoint(String endpoint) => endpoint != 'fileUploads/upload';
  @override
  bool supportsWorkspaceUpload = false;
  @override
  int get maxWorkspaceUploadBytes => 1024 * 1024 * 1024;

  final calls = <(String, List<int>, String)>[];

  @override
  Future<WorkspaceUploadedFile> uploadWorkspaceFile(String sessionId, List<int> bytes, {required String name}) async {
    calls.add((sessionId, bytes, name));
    return WorkspaceUploadedFile(name: name, path: './$name', bytes: bytes.length);
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) => throw UnimplementedError();
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();
  @override
  Future<void> close() async {}
}

void main() {
  test('workspace upload is distinct from receipt staging and follows live capability', () async {
    final carrier = _WorkspaceCarrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);

    expect(client.supportsEndpoint('fileUploads/upload'), isFalse);
    expect(client.supportsFileUpload, isFalse);
    await expectLater(
      Future.sync(() => client.uploadWorkspaceFile('s1', [1], name: 'notes.txt')),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'WORKSPACE_UPLOAD_UNSUPPORTED')),
    );
    expect(carrier.calls, isEmpty);

    carrier.supportsWorkspaceUpload = true;
    expect(client.supportsFileUpload, isTrue);
    final uploaded = await client.uploadWorkspaceFile('s1', [1, 2], name: 'notes.txt');
    expect(carrier.calls.single.$1, 's1');
    expect(carrier.calls.single.$2, [1, 2]);
    expect(carrier.calls.single.$3, 'notes.txt');
    expect(uploaded.path, './notes.txt');
    expect(uploaded.bytes, 2);

    carrier.supportsWorkspaceUpload = false;
    expect(client.supportsFileUpload, isFalse);
  });

  test('HTTP clients keep receipt uploads and do not claim a workspace protocol', () async {
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
    addTearDown(client.close);
    expect(client.supportsFileUpload, isTrue);
    await expectLater(
      Future.sync(() => client.uploadWorkspaceFile('s1', [1], name: 'notes.txt')),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'WORKSPACE_UPLOAD_UNSUPPORTED')),
    );
  });
}
