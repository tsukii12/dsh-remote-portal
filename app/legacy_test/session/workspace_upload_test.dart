import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/session/workspace_upload.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

/// A Remote connection: workspace uploads on or off, each upload recorded and
/// held until [release] completes when set.
class _RemoteClient extends DshClient {
  _RemoteClient({this.uploads = true}) : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final bool uploads;
  final sent = <(String sessionId, String name, int bytes)>[];
  Completer<void>? release;
  Object? error;

  @override
  bool get supportsWorkspaceUpload => uploads;

  @override
  Future<WorkspaceUploadedFile> uploadWorkspaceFile(String sessionId, List<int> bytes, {required String name}) async {
    sent.add((sessionId, name, bytes.length));
    await release?.future;
    if (error case final e?) throw e;
    // The Host renames on a clash.
    final stored = name == 'a.txt' ? 'a (1).txt' : name;
    return WorkspaceUploadedFile(name: stored, path: './$stored', bytes: bytes.length);
  }
}

/// The active connection, switchable mid-test (another Host taking over).
class _Active extends Notifier<AsyncValue<HostConnection?>> {
  static late HostConnection initial;

  @override
  AsyncValue<HostConnection?> build() => AsyncData(initial);

  void use(HostConnection connection) => state = AsyncData(connection);
}

final _active = NotifierProvider<_Active, AsyncValue<HostConnection?>>(_Active.new);

DraftAttachment _file(String name, int size) => DraftAttachment(name: name, bytes: Uint8List(size));

Widget _app(_RemoteClient client, FakePicker picker) => testApp(
  const Scaffold(body: WorkspaceUploadRow(sessionId: 's1')),
  overrides: [
    activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: false))),
    attachmentPickerProvider.overrideWithValue(picker),
  ],
);

void main() {
  testWidgets('hidden when the connection has no workspace upload', (tester) async {
    await tester.pumpWidget(_app(_RemoteClient(uploads: false), FakePicker()));
    expect(find.text('传文件到电脑'), findsNothing);
  });

  testWidgets('picked files go to the conversation workspace one by one, original bytes', (tester) async {
    usePhoneView(tester);
    final client = _RemoteClient()..release = Completer<void>();
    final picker = FakePicker()..files = [_file('a.txt', 3), _file('photo.heic', 5000)];
    await tester.pumpWidget(_app(client, picker));
    expect(find.text('传文件到电脑'), findsOneWidget);

    await tester.tap(find.text('传文件到电脑'));
    await tester.pump();
    expect(picker.calls, ['files'], reason: 'the file picker keeps originals; the gallery downscales');
    expect(find.text('正在传 1/2：a.txt'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    client.release!.complete();
    await tester.pumpAndSettle();
    expect(client.sent, [('s1', 'a.txt', 3), ('s1', 'photo.heic', 5000)]);
    expect(find.text('已传到电脑：a (1).txt、photo.heic'), findsOneWidget, reason: 'the Host-chosen names');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another Host taking over mid-batch stops it; nothing is sent there or announced', (tester) async {
    usePhoneView(tester);
    final first = _RemoteClient()..release = Completer<void>();
    final second = _RemoteClient();
    _Active.initial = HostConnection(hostId: '', client: first, isLocal: false);
    final picker = FakePicker()..files = [_file('one.txt', 1), _file('two.txt', 2)];
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: WorkspaceUploadRow(sessionId: 's1')),
        overrides: [
          activeConnectionProvider.overrideWith((ref) => ref.watch(_active)),
          attachmentPickerProvider.overrideWithValue(picker),
        ],
      ),
    );
    await tester.tap(find.text('传文件到电脑'));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(WorkspaceUploadRow)));
    container.read(_active.notifier).use(HostConnection(hostId: '', client: second, isLocal: false));
    first.release!.complete();
    await tester.pumpAndSettle();
    expect(first.sent.map((s) => s.$2), ['one.txt']);
    expect(second.sent, isEmpty);
    expect(find.textContaining('已传到电脑'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused upload stops the batch and says why', (tester) async {
    usePhoneView(tester);
    final client = _RemoteClient()..error = const DshRemoteException('UPLOAD_LIMIT', 'too large', {'remote': true});
    final picker = FakePicker()..files = [_file('big.zip', 10), _file('next.txt', 1)];
    await tester.pumpWidget(_app(client, picker));
    await tester.tap(find.text('传文件到电脑'));
    await tester.pumpAndSettle();
    expect(client.sent.map((s) => s.$2), ['big.zip'], reason: 'nothing after a refusal');
    expect(find.textContaining('没能传到电脑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
