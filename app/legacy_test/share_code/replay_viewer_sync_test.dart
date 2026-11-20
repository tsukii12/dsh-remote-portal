// The viewer page inside the app (replay_viewer.g.dart) is built from
// site/share/viewer.{js,css,html} by app/tool/make_replay_viewer.py; this
// fails when the sources changed and the tool wasn't run.
//
//   flutter test test/share_code/replay_viewer_sync_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/share_code/conversation_html.dart';
import 'package:dsh_app/share_code/replay_viewer.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the inlined viewer matches site/share', () {
    final out = AccumulatorSink();
    final hash = sha256.startChunkedConversion(out);
    for (final name in ['viewer.js', 'viewer.css', 'viewer.html']) {
      hash.add(utf8.encode(name));
      hash.add([0]);
      hash.add(utf8.encode(File('../site/share/$name').readAsStringSync()));
      hash.add([0]);
    }
    hash.close();
    expect(replayViewerSourceHash, out.digest.toString(), reason: 'run python3 app/tool/make_replay_viewer.py');
  });

  test('the inline script is pinned by its hash; nothing loads from outside', () {
    final script = RegExp(r'<script>(.*?)</script>', dotAll: true).firstMatch(replayViewerPage)!.group(1)!;
    final pinned = base64.encode(sha256.convert(utf8.encode(script)).bytes);
    expect(replayViewerPage, contains("script-src 'sha256-$pinned'"));
    expect(replayViewerPage, contains("connect-src 'none'"));
    expect(replayViewerPage, isNot(contains('src="http')));
    expect(replayViewerPage, isNot(contains('href="http')));
  });

  test('a filled page keeps its data inside the data block', () {
    const file = '{"dshgo":2,"kind":"conversation","name":"</script><script>alert(1)</script>","code":"x.y"}';
    final html = conversationHtml(file, title: '<b>标题</b>');
    expect(html, contains('<title>&lt;b&gt;标题&lt;/b&gt; · DSH Go</title>'));
    final block = RegExp(
      r'<script type="application/json" id="dshgo-data">(.*?)</script>',
      dotAll: true,
    ).firstMatch(html)!;
    expect(block.group(1), isNot(contains('<')));
    expect(jsonDecode(block.group(1)!), jsonDecode(file));
    // The script after it is the same one the hash pins.
    expect('<script>'.allMatches(html).length, 1);
  });
}

class AccumulatorSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
