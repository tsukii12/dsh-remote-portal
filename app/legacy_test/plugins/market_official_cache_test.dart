// The official market's copy on the phone (docs/design/plugin-market.md §6):
// read from the public bucket first, then the Worker; kept six hours without
// asking, then revalidated with its ETags (304); a pull or 重试 always asks;
// offline uses the copy. And over real HTTP: a 304, and the 302 that sends
// released apps from go.dshtui.com to the bucket.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_plugin_host.dart';

const _dl = 'https://dl.dshtui.com/market/';
const _go = 'https://go.dshtui.com/market/';

/// Both bases with the fixtures; a file missing for a base is 404. ETags are
/// the body's hash; [down] bases throw like an unreachable host.
class _Server {
  _Server() {
    for (final base in [_dl, _go]) {
      files['${base}index.json'] = jsonEncode(officialIndexJson());
      files['${base}dsh-go.json'] = jsonEncode(officialSidecarJson());
    }
  }

  final files = <String, String>{};
  final down = <String>{};

  /// Every GET: `<url>`, or `<url> <etag>` when one was sent.
  final requests = <String>[];

  Future<MarketFile> get(Uri url, {String? etag}) async {
    requests.add(etag == null ? '$url' : '$url $etag');
    if (down.any('$url'.startsWith)) throw const MarketFetchException('offline');
    final body = files['$url'];
    if (body == null) throw const MarketFetchException('HTTP 404', statusCode: 404);
    final tag = '"${body.hashCode}"';
    return (text: tag == etag ? null : body, etag: tag);
  }

  /// [url]'s sidecar with [name] pinned at another version than the index.
  void bump(String url, String name) {
    final sidecar = jsonDecode(files[url]!) as Map<String, Object?>;
    ((sidecar['plugins']! as Map)[name] as Map)['version'] = '9.9.9';
    files[url] = jsonEncode(sidecar);
  }
}

/// Moves the copy's fetch time [age] into the past.
Future<void> _age(Duration age) async {
  final prefs = await SharedPreferences.getInstance();
  final copy = jsonDecode(prefs.getString('market.official')!) as Map<String, Object?>;
  copy['at'] = DateTime.parse(copy['at']! as String).subtract(age).toIso8601String();
  await prefs.setString('market.official', jsonEncode(copy));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the copy on the phone', () {
    test('comes from the public bucket and answers for six hours without a request', () async {
      final server = _Server();
      final first = await fetchOfficialMarket(get: server.get);
      expect(server.requests, ['${_dl}dsh-go.json', '${_dl}index.json']);
      expect(first.byName['@dsh-go/media']!.section, MarketSection.official);

      server.requests.clear();
      await _age(const Duration(hours: 5, minutes: 59));
      final again = await fetchOfficialMarket(get: server.get);
      expect(server.requests, isEmpty);
      expect(again.entries.map((e) => e.name), first.entries.map((e) => e.name));
      expect(again.byName['@dsh-go/media']!.listing!.integrity, first.byName['@dsh-go/media']!.listing!.integrity);
    });

    test('is revalidated with its ETags once stale: 304 keeps it, 200 replaces it', () async {
      final server = _Server();
      await fetchOfficialMarket(get: server.get);
      final tags = {for (final f in ['index.json', 'dsh-go.json']) f: '"${server.files['$_dl$f'].hashCode}"'};

      await _age(const Duration(hours: 6));
      server.requests.clear();
      final unchanged = await fetchOfficialMarket(get: server.get);
      expect(server.requests, ['${_dl}dsh-go.json ${tags['dsh-go.json']}', '${_dl}index.json ${tags['index.json']}']);
      expect(unchanged.byName['@dsh-go/media']!.section, MarketSection.official);
      // The 304s renewed it.
      server.requests.clear();
      await fetchOfficialMarket(get: server.get);
      expect(server.requests, isEmpty);

      await _age(const Duration(hours: 7));
      final index = officialIndexJson();
      (index['plugins']! as List).removeLast();
      server.files['${_dl}index.json'] = jsonEncode(index);
      final changed = await fetchOfficialMarket(get: server.get);
      expect(changed.entries, hasLength(4));
      server.requests.clear();
      expect((await fetchOfficialMarket(get: server.get)).entries, hasLength(4));
      expect(server.requests, isEmpty);
    });

    test('a pull or 重试 always asks, with the ETags', () async {
      final server = _Server();
      await fetchOfficialMarket(get: server.get);
      server.requests.clear();
      await fetchOfficialMarket(get: server.get, refresh: true);
      expect(server.requests, hasLength(2));
      expect(server.requests.every((r) => r.startsWith(_dl) && r.contains(' "')), isTrue);
    });

    test('the Worker when the bucket fails; offline, the copy at any age', () async {
      final server = _Server()..files.remove('${_dl}index.json');
      final viaWorker = await fetchOfficialMarket(get: server.get);
      expect(viaWorker.entries, hasLength(5));
      expect(server.requests.where((r) => r.startsWith(_go)), hasLength(2));

      await _age(const Duration(days: 30));
      server.down.addAll([_dl, _go]);
      final offline = await fetchOfficialMarket(get: server.get);
      expect(offline.byName['@dsh-go/media']!.section, MarketSection.official);

      SharedPreferences.setMockInitialValues({});
      await expectLater(fetchOfficialMarket(get: server.get), throwsA(isA<MarketFetchException>()));
    });

    test('keeps only a pair that agrees on every pinned version', () async {
      // The edge can serve a new index.json beside an old dsh-go.json for a few minutes.
      final server = _Server()..bump('${_dl}dsh-go.json', '@dsh-go/media');
      final mixed = await fetchOfficialMarket(get: server.get);
      expect(mixed.byName['@dsh-go/media']!.listing, isNull);
      expect((await SharedPreferences.getInstance()).getString('market.official'), isNull);
      server
        ..files['${_dl}dsh-go.json'] = jsonEncode(officialSidecarJson())
        ..requests.clear();
      expect((await fetchOfficialMarket(get: server.get)).byName['@dsh-go/media']!.listing, isNotNull);
      expect(server.requests, hasLength(2));
    });

    test('the provider: the first read may use the copy, a re-read (pull, 重试) asks', () async {
      final server = _Server();
      await fetchOfficialMarket(get: server.get);
      server.requests.clear();
      final container = ProviderContainer(overrides: [marketFileFetcherProvider.overrideWithValue(server.get)]);
      addTearDown(container.dispose);
      await container.read(officialMarketProvider.future);
      expect(server.requests, isEmpty);
      container.invalidate(officialMarketProvider);
      await container.read(officialMarketProvider.future);
      expect(server.requests, hasLength(2));
    });
  });

  group('over HTTP', () {
    /// A local server: [handle] answers each request.
    Future<HttpServer> serve(void Function(HttpRequest request) handle) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen(handle);
      return server;
    }

    test('sends If-None-Match and reads 304 as unchanged', () async {
      final seen = <String?>[];
      final server = await serve((request) {
        final tag = request.headers.value(HttpHeaders.ifNoneMatchHeader);
        seen.add(tag);
        request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
        if (tag == '"v1"') request.response.statusCode = HttpStatus.notModified;
        if (tag != '"v1"') request.response.write('{"format":1}');
        request.response.close();
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/market/index.json');
      final fresh = await fetchMarketFile(url);
      expect(fresh, (text: '{"format":1}', etag: '"v1"'));
      expect(await fetchMarketFile(url, etag: '"v1"'), (text: null, etag: '"v1"'));
      expect(seen, [null, '"v1"']);
    });

    test('follows the 302 released apps get from go.dshtui.com to the bucket', () async {
      final bucket = await serve((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"path":"${request.uri.path}","agent":"${request.headers.value(HttpHeaders.userAgentHeader)}"}')
          ..close();
      });
      final worker = await serve((request) {
        request.response.redirect(Uri.parse('http://127.0.0.1:${bucket.port}${request.uri}'), status: HttpStatus.found);
      });
      final file = await fetchMarketFile(Uri.parse('http://127.0.0.1:${worker.port}/market/dsh-go.json'));
      expect(jsonDecode(file.text!), {'path': '/market/dsh-go.json', 'agent': 'dsh-app'});
    });
  });
}
