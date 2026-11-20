import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

class _Fake {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Keep the real RPC envelope and HTTP deadline/abort path, but advance model
// latency on fake time instead of holding a socket open for several minutes.
class _SlowHttp extends _Fake implements HttpClient {
  _SlowHttp(this.delay);

  final Duration delay;
  final requests = <_SlowRequest>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = _SlowRequest(delay);
    requests.add(request);
    return request;
  }
}

class _Headers extends _Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  List<String>? operator [](String name) => null;

  @override
  ContentType get contentType => ContentType.json;
}

class _SlowRequest extends _Fake implements HttpClientRequest {
  _SlowRequest(this.delay);

  final Duration delay;
  final bytes = <int>[];
  bool aborted = false;

  @override
  final HttpHeaders headers = _Headers();

  @override
  set followRedirects(bool value) {}

  @override
  set contentLength(int value) {}

  @override
  void add(List<int> data) => bytes.addAll(data);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;

  @override
  Future<HttpClientResponse> close() async {
    await Future<void>.delayed(delay);
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return _Response(
      utf8.encode(
        jsonEncode({
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': {
            'ok': true,
            'value': {
              'commandId': 'cmd-1',
              'result': {'kind': 'success', 'text': 'done'},
            },
          },
        }),
      ),
    );
  }
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.body);

  final List<int> body;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  final HttpHeaders headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(body).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final line in ['/compact', '  /compact  ', '/compact\n']) {
    test('$line survives the ordinary 120 second HTTP deadline', () {
      fakeAsync((async) {
        final http = _SlowHttp(const Duration(seconds: 121));
        final client = DshClient(DshConnection(Uri.parse('http://localhost'), httpClient: http));
        CommandResult? result;
        Object? failure;
        client.executeCommand('s1', line).then<void>((value) => result = value, onError: (Object e) => failure = e);
        async.elapse(const Duration(seconds: 120));
        expect(result, isNull);
        expect(failure, isNull);
        expect(http.requests.single.aborted, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(failure, isNull);
        expect(result?.commandId, 'cmd-1');
        expect(result?.success, isTrue);
        expect(result?.text, 'done');
        expect(http.requests.single.aborted, isFalse);
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });
  }

  for (final line in ['/permission read-only', '/compact-other']) {
    test('$line keeps the ordinary 120 second HTTP deadline', () {
      fakeAsync((async) {
        final http = _SlowHttp(const Duration(seconds: 121));
        final client = DshClient(DshConnection(Uri.parse('http://localhost'), httpClient: http));
        Object? failure;
        client
            .executeCommand('s1', line)
            .then<void>((_) => fail('should time out'), onError: (Object e) => failure = e);
        async.elapse(const Duration(seconds: 120));
        expect(failure, isA<DshTransportException>());
        expect(http.requests.single.aborted, isTrue);
        async.elapse(const Duration(seconds: 1));
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });
  }

  test('compact still has a bounded 30 minute deadline', () {
    fakeAsync((async) {
      final http = _SlowHttp(const Duration(minutes: 31));
      final client = DshClient(DshConnection(Uri.parse('http://localhost'), httpClient: http));
      Object? failure;
      client
          .executeCommand('s1', '/compact')
          .then<void>((_) => fail('should time out'), onError: (Object e) => failure = e);
      async.elapse(const Duration(minutes: 30));
      expect(failure, isA<DshTransportException>());
      expect(http.requests.single.aborted, isTrue);
      async.elapse(const Duration(minutes: 1));
      unawaited(client.close());
      async.flushMicrotasks();
    });
  });
}
