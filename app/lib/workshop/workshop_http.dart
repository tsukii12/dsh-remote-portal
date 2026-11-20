import 'dart:async';
import 'dart:io';

import '../update/update_http.dart';
import 'workshop_models.dart';

/// Public downloads and authenticated API calls share this no-redirect
/// transport. A test can replace it without opening a network connection.
abstract class WorkshopHttp implements UpdateHttp {
  Future<UpdateHttpResponse> request(String method, Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = const Duration(seconds: 30),
  });
  @override
  Future<UpdateHttpResponse> get(Uri url, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 15)}) =>
      request('GET', url, headers: headers, timeout: timeout);
  void close() {}
}

/// Optional upload transport; existing WorkshopHttp test doubles need not
/// implement it. Progress means bytes accepted by the transport, not approval.
abstract interface class WorkshopUploadHttp {
  Future<UpdateHttpResponse> upload(Uri url, {
    required List<int> body,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
    void Function(int sent, int total)? onProgress,
  });
}

class IoWorkshopHttp extends WorkshopHttp implements WorkshopUploadHttp {
  IoWorkshopHttp(Uri origin, {HttpClient? client}) : origin = workshopOrigin(origin), _client = (client ?? HttpClient())
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 5)
    ..autoUncompress = false
    ..userAgent = 'dsh-app-workshop';

  final Uri origin;
  final HttpClient _client;

  @override
  Future<UpdateHttpResponse> request(String method, Uri url, {Map<String, String> headers = const {}, List<int>? body, Duration timeout = const Duration(seconds: 30)}) =>
      _request(method, url, headers: headers, body: body, timeout: timeout);

  @override
  Future<UpdateHttpResponse> upload(Uri url, {required List<int> body, Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30), void Function(int sent, int total)? onProgress}) =>
      _request('PUT', url, headers: headers, body: body, timeout: timeout, chunkedUpload: true, onProgress: onProgress);

  Future<UpdateHttpResponse> _request(String method, Uri url, {required Map<String, String> headers,
    List<int>? body, required Duration timeout, bool chunkedUpload = false, void Function(int sent, int total)? onProgress}) async {
    if (url.origin != origin.origin || url.userInfo.isNotEmpty || url.hasFragment) workshopInvalid('workshop_untrusted_origin');
    var abandoned = false;
    HttpClientRequest? request;
    try {
      if (chunkedUpload) {
        onProgress?.call(0, body!.length);
      }
      final opened = await _client.openUrl(method, url).then((value) {
        // Future.timeout does not cancel openUrl. A late connection must not
        // keep an abandoned request/socket alive after the caller has failed.
        if (abandoned) value.abort();
        return value;
      }).timeout(timeout, onTimeout: () {
        abandoned = true;
        throw TimeoutException('workshop_timeout');
      });
      request = opened;
      opened.followRedirects = false;
      opened.headers.set('accept-encoding', 'identity');
      headers.forEach(opened.headers.set);
      Future<HttpClientResponse> send() async {
        final payload = body;
        if (payload != null) {
          opened.contentLength = payload.length;
          if (chunkedUpload) {
            const chunkBytes = 64 * 1024;
            for (var offset = 0; offset < payload.length; offset += chunkBytes) {
              if (abandoned) {
                throw TimeoutException('workshop_timeout');
              }
              final end = offset + chunkBytes < payload.length ? offset + chunkBytes : payload.length;
              opened.add(payload.sublist(offset, end));
              await opened.flush();
              if (abandoned) {
                throw TimeoutException('workshop_timeout');
              }
              onProgress?.call(end, payload.length);
            }
          } else {
            opened.add(payload);
          }
        }
        return await opened.close();
      }
      // One budget covers the complete body pump and response headers. A
      // timed-out flush may settle later, but cannot resume writes/progress.
      final response = await send().timeout(timeout, onTimeout: () {
        abandoned = true;
        throw TimeoutException('workshop_timeout');
      });
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) => responseHeaders[name.toLowerCase()] = values.join(', '));
      return UpdateHttpResponse(status: response.statusCode, headers: responseHeaders,
        contentLength: response.contentLength >= 0 ? response.contentLength : null, body: response);
    } on Object {
      abandoned = true;
      request?.abort();
      rethrow;
    }
  }
  @override
  void close() => _client.close(force: true);
}
