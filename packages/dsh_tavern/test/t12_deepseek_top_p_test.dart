import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

const _key = 'deepseek-top-p-fixture-key';
final _url = Uri.parse('https://deepseek-top-p.invalid/beta/chat/completions');

// Only the HTTP peer is synthetic. Preset import/binding, SQLite, Tavern.send,
// request assembly and the production model client's JSON encoding are real.
void main() {
  test('public imported DeepSeek top_p keeps NaN fallback in final wire through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-deepseek-top-p-');
    TavernEngine? ownedEngine;
    final peers = <_CompletionPeer>[];
    final requests = <_Request>[];
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      expect(peers.every((peer) => peer.closed), isTrue);
      stdout.writeln('DEEPSEEK_TOP_P_CLEANUP');
    });
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return _key;
      },
      baseUrl: 'https://deepseek-top-p.invalid/v1',
      model: 'fixture',
      deepseek: true,
      thinking: false,
    );
    final model = TavernModelClient(
      clientFactory: () {
        if (peers.length == 2) throw StateError('Unexpected additional HTTP client.');
        final peer = _CompletionPeer(requests);
        peers.add(peer);
        return peer;
      },
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(root, config: config, modelClient: model);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    final ordinaryRaw = t24Preset().raw..addAll({'stream_openai': false, 'top_p': 0.5});
    final targetRaw = {..._copy(ordinaryRaw), 'top_p': 'bad'};
    final ordinarySource = '${jsonEncode(ordinaryRaw)}\n';
    final targetSource = '${jsonEncode(targetRaw)}\n';
    final ordinaryImport = await facade.importPreset(ordinarySource, fileName: 'ordinary.json');
    final targetImport = await facade.importPreset(targetSource, fileName: 'bad-top-p.json');
    expect(ordinaryImport.issues, isEmpty);
    expect(targetImport.issues, isEmpty);
    final ordinaryPresetId = ordinaryImport.preset.id;
    final targetPresetId = targetImport.preset.id;
    final character = await facade.importCard(t24Card());
    final ordinaryChat = await facade.createChat(character.id);
    final targetChat = await facade.createChat(character.id);
    await facade.bindPreset(ordinaryChat, ordinaryPresetId);
    await facade.bindPreset(targetChat, targetPresetId);
    final ordinaryGreeting = (await facade.path(ordinaryChat)).single;
    final targetGreeting = (await facade.path(targetChat)).single;
    expect([ordinaryGreeting.text, targetGreeting.text], ['G', 'G']);

    Future<void> checkPreset(String chatId, String presetId, Map<String, Object?> raw, String source) async {
      final saved = (await facade.preset(presetId))!;
      expect(saved.sourceText, source);
      expect(saved.raw, raw);
      expect(jsonDecode(await facade.exportPreset(presetId)), raw);
      final selection = await facade.presetSelection(chatId: chatId);
      expect(selection.source, PresetSelectionSource.chat);
      expect((selection.boundPresetId, selection.effectivePresetId), (presetId, presetId));
      expect((await facade.readSettings(chatId: chatId))['preset'], raw);
    }

    Future<void> checkSaved(String chatId, String greetingId, String replyId, Map<String, Object?> body) async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.role, message.text)).toList(), [
        (TavernRole.character, 'G'),
        (TavernRole.user, 'Q'),
        (TavernRole.character, 'OK'),
      ]);
      expect((path.first.nodeId, path.last.nodeId), (greetingId, replyId));
      final inspection = (await facade.inspectTurn(chatId))!;
      expect(inspection.status, TavernInspectionStatus.completed);
      expect((inspection.contextNodeId, inspection.nodeId), (greetingId, replyId));
      expect(inspection.failure, isNull);
      expect(inspection.prompt!.body, body);
    }

    await checkPreset(ordinaryChat, ordinaryPresetId, ordinaryRaw, ordinarySource);
    await checkPreset(targetChat, targetPresetId, targetRaw, targetSource);
    final ordinary = await facade.send(ordinaryChat, 'Q').toList();
    expect(ordinary.whereType<TavernTurnFailed>(), isEmpty);
    expect(ordinary.whereType<TavernTurnDone>(), hasLength(1));
    final ordinaryDone = ordinary.whereType<TavernTurnDone>().single;
    expect(ordinary.last, same(ordinaryDone));
    expect((ordinaryDone.message.text, ordinaryDone.finishReason), ('OK', 'stop'));
    expect(peers, hasLength(1));
    expect((peers.single.sends, peers.single.closed), (1, true));
    expect(requests, hasLength(1));
    expect((requests.single.method, requests.single.url), ('POST', _url));
    // Independent deep copy: later requests cannot alter the ordinary oracle.
    final ordinaryBody = _copy(requests.single.body);
    expect(ordinaryBody['top_p'], 0.5);
    expect(ordinaryBody['stream'], isFalse);
    expect(ordinaryBody['model'], 'fixture');
    expect(ordinaryBody['thinking'], {'type': 'disabled'});
    expect((ordinaryBody['messages']! as List<Object?>).last, {'role': 'user', 'content': 'Q'});
    expect(keyReads, 1);
    await checkSaved(ordinaryChat, ordinaryGreeting.nodeId, ordinaryDone.message.nodeId, ordinaryBody);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(ordinaryChat, ordinaryGreeting.nodeId, ordinaryDone.message.nodeId, ordinaryBody);
    await checkPreset(ordinaryChat, ordinaryPresetId, ordinaryRaw, ordinarySource);
    await checkPreset(targetChat, targetPresetId, targetRaw, targetSource);
    expect((await facade.path(targetChat)).map((message) => (message.nodeId, message.text)).toList(), [
      (targetGreeting.nodeId, 'G'),
    ]);
    expect((peers.length, requests.length, keyReads), (1, 1, 1));
    stdout.writeln('DEEPSEEK_TOP_P_READY');

    final target = await facade.send(targetChat, 'Q').toList();
    // First target assertion compares all final request bodies. The old
    // product sends null, whereas fixed ST sends the literal epsilon below.
    expect(requests.map((request) => request.body).toList(), [
      ordinaryBody,
      {...ordinaryBody, 'top_p': 2.220446049250313e-16},
    ]);
    expect(target.whereType<TavernTurnFailed>(), isEmpty);
    expect(target.whereType<TavernTurnDone>(), hasLength(1));
    final targetDone = target.whereType<TavernTurnDone>().single;
    expect(target.last, same(targetDone));
    expect((targetDone.message.text, targetDone.finishReason), ('OK', 'stop'));
    expect(peers.map((peer) => peer.sends).toList(), [1, 1]);
    expect(peers.every((peer) => peer.closed), isTrue);
    expect(requests.map((request) => (request.method, request.url)).toList(), [('POST', _url), ('POST', _url)]);
    expect(keyReads, 2);
    final targetBody = {..._copy(ordinaryBody), 'top_p': 2.220446049250313e-16};
    await checkSaved(targetChat, targetGreeting.nodeId, targetDone.message.nodeId, targetBody);
    await checkPreset(targetChat, targetPresetId, targetRaw, targetSource);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(targetChat, targetGreeting.nodeId, targetDone.message.nodeId, targetBody);
    await checkPreset(targetChat, targetPresetId, targetRaw, targetSource);
    await checkPreset(ordinaryChat, ordinaryPresetId, ordinaryRaw, ordinarySource);
    expect((peers.length, requests.length, keyReads), (2, 2, 2));
  });
}

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;

typedef _Request = ({String method, Uri url, Map<String, Object?> body});

class _CompletionPeer extends http.BaseClient {
  _CompletionPeer(this.requests);
  final List<_Request> requests;
  var sends = 0;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode(utf8.decode(await request.finalize().toBytes())) as Map<String, Object?>;
    sends++;
    requests.add((method: request.method, url: request.url, body: body));
    const completion =
        '{"model":"fixture","choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}';
    return http.StreamedResponse(
      Stream.value(utf8.encode(completion)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  void close() {
    closed = true;
  }
}
