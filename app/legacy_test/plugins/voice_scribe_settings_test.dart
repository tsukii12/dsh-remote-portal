import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/voice_scribe_settings.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

Map<String, dynamic> voiceFixture() =>
    (jsonDecode(File('test/plugins/fixtures/voice-scribe-0.5.3-get-settings.json').readAsStringSync()) as Map)
        .cast<String, dynamic>();

class VoiceHttpCarrier extends DshHttpCarrier {
  VoiceHttpCarrier(super.connection);
  FakeMuxLink? link;
  Completer<void>? inventoryGate;
  bool active = true;
  String module = voiceScribeModule;
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => link = FakeMuxLink();
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'pluginInventory/list') {
      await inventoryGate?.future;
      return RpcOk({
        'entries': [
          {
            'entryId': 'include:voice',
            'moduleName': module,
            'enabled': active,
            'fiberPhase': active ? 'active' : 'unloading',
          },
        ],
      });
    }
    return RpcOk({'namespaces': [], 'writable': true});
  }

  void pluginChanged() => link!.push({
    'type': 'emit',
    'event': 'plugin-manager/changed',
    'args': [{}],
  });
}

class VoiceServer {
  VoiceServer._(this.server) {
    server.listen(_handle);
  }
  final HttpServer server;
  final requests = <Map<String, dynamic>>[];
  final cookies = <String?>[];
  final value = (voiceFixture()['value'] as Map).cast<String, dynamic>();
  int writes = 0;
  bool rejectWrites = false;
  bool failReadsAfterWrite = false;
  bool oversized = false;
  String? redirect;
  Completer<void>? writeGate;
  static Future<VoiceServer> start() async => VoiceServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');
  Future<void> _handle(HttpRequest request) async {
    // No other routes (the dsh-go bridge's plugin-config probe): 404, as a Host
    // without them answers.
    if (request.method == 'GET') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
    requests.add(body);
    cookies.add(request.headers.value(HttpHeaders.cookieHeader));
    request.response.headers.contentType = ContentType.json;
    if (redirect != null) {
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, redirect!);
    } else if (body['action'] == 'set-settings') {
      writes++;
      await writeGate?.future;
      if (rejectWrites) {
        request.response.statusCode = 400;
        request.response.write(jsonEncode({'ok': false}));
      } else {
        value.addAll((body['patch'] as Map).cast<String, dynamic>());
        request.response.write(jsonEncode({'ok': true}));
      }
    } else if (failReadsAfterWrite && writes > 0) {
      request.response.statusCode = 503;
      request.response.write('{}');
    } else {
      request.response.write(
        jsonEncode({
          'ok': true,
          'value': value,
          if (oversized) 'padding': 'x' * (VoiceScribeHttpTransport.maxResponseBytes + 1),
        }),
      );
    }
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
  Future<(DshClient, VoiceHttpCarrier)> client({bool ready = true}) async {
    final connection = DshConnection(
      uri,
      cookie: DshCookie(name: 'dsh-auth-fixture', value: 'test-session', authority: uri.authority),
    );
    final carrier = VoiceHttpCarrier(connection);
    final client = DshClient.withCarrier(carrier);
    if (ready) await client.mux.ready();
    return (client, carrier);
  }
}

class MemoryVoiceTransport implements VoiceScribeTransport {
  VoiceScribeSettings value = VoiceScribeSettings.fromJson(voiceFixture()['value']);
  Future<VoiceScribeSettings> Function()? readHook;
  Future<void> Function()? writeHook;
  final writes = <(VoiceScribeField, String)>[];
  @override
  Future<VoiceScribeSettings> read({bool Function()? stillCurrent}) async =>
      readHook == null ? value : await readHook!();
  @override
  Future<void> write(VoiceScribeField field, String text, {bool Function()? stillCurrent}) async {
    writes.add((field, text));
    await writeHook?.call();
    value = value.changed(field, text);
  }
}

void main() {
  test('real get-settings fixture and narrow patches use the existing cookie without key writes', () async {
    final server = await VoiceServer.start();
    addTearDown(server.close);
    final (client, _) = await server.client();
    addTearDown(client.close);
    final api = VoiceScribeHttpTransport(client: client, entryId: 'include:voice', isCurrent: () => true);
    final settings = await api.read();
    expect(settings.providers.single.model, 'whisper-large-v3');
    await api.write(VoiceScribeField.language, ' zh ');
    await api.write(VoiceScribeField.polishPrompt, '');
    expect(server.requests, [
      {'action': 'get-settings'},
      {
        'action': 'set-settings',
        'patch': {'language': 'zh'},
      },
      {
        'action': 'set-settings',
        'patch': {'polishPrompt': ''},
      },
    ]);
    expect(server.cookies, everyElement('dsh-auth-fixture=test-session'));
    expect(server.requests.map(jsonEncode).join(), isNot(contains('asrProviders')));
    expect(server.requests.map(jsonEncode).join(), isNot(contains('ApiKey')));
  });

  for (final condition in ['not-ready', 'no-cookie', 'expired-cookie', 'wrong-plugin', 'inactive-plugin']) {
    test('$condition prevents the REST request', () async {
      final server = await VoiceServer.start();
      addTearDown(server.close);
      final (client, carrier) = await server.client(ready: condition != 'not-ready');
      addTearDown(client.close);
      if (condition == 'no-cookie') client.connection.cookie = null;
      if (condition == 'expired-cookie') {
        client.connection.cookie = DshCookie(
          name: 'test',
          value: 'expired',
          authority: server.uri.authority,
          expiresAt: DateTime(2000),
        );
      }
      if (condition == 'wrong-plugin') carrier.module = 'unrelated-plugin';
      if (condition == 'inactive-plugin') carrier.active = false;
      final api = VoiceScribeHttpTransport(client: client, entryId: 'include:voice', isCurrent: () => true);
      await expectLater(api.read(), throwsStateError);
      expect(server.requests, isEmpty);
    });
  }

  test('plugin generation lost during inventory cannot send the queued write', () async {
    final server = await VoiceServer.start();
    addTearDown(server.close);
    final (client, carrier) = await server.client();
    addTearDown(client.close);
    carrier.inventoryGate = Completer<void>();
    var generationCurrent = true;
    final api = VoiceScribeHttpTransport(client: client, entryId: 'include:voice', isCurrent: () => true);
    final write = api.write(VoiceScribeField.language, 'zh', stillCurrent: () => generationCurrent);
    generationCurrent = false;
    carrier.inventoryGate!.complete();
    await expectLater(write, throwsStateError);
    expect(server.requests, isEmpty);
  });

  test('redirect is refused and response size is bounded', () async {
    final server = await VoiceServer.start();
    addTearDown(server.close);
    final sink = await VoiceServer.start();
    addTearDown(sink.close);
    final (client, _) = await server.client();
    addTearDown(client.close);
    final api = VoiceScribeHttpTransport(client: client, entryId: 'include:voice', isCurrent: () => true);
    server.redirect = '${sink.uri}/voice-input';
    await expectLater(api.read(), throwsStateError);
    expect(sink.requests, isEmpty);
    server.redirect = null;
    server.oversized = true;
    await expectLater(api.read(), throwsA(isA<DshProtocolException>()));
  });

  test('controller preserves confirmed data on failure, then waits for acknowledgement and rereads', () async {
    final transport = MemoryVoiceTransport();
    final controller = VoiceScribeSettingsController(transport, () => true);
    addTearDown(controller.dispose);
    await controller.refresh();
    transport.writeHook = () async => throw StateError('reject');
    expect(await controller.save(controller.generation, VoiceScribeField.language, 'zh'), isFalse);
    expect(controller.data!.language, '');
    final gate = Completer<void>();
    transport.writeHook = () => gate.future;
    final saving = controller.save(controller.generation, VoiceScribeField.language, 'zh');
    expect(controller.saving, isTrue);
    expect(await controller.save(controller.generation, VoiceScribeField.language, 'en'), isFalse);
    gate.complete();
    expect(await saving, isTrue);
    expect(controller.data!.language, 'zh');
    expect(controller.saving, isFalse);
  });

  test('acknowledged save with failed reread remains acknowledged and exposes refresh failure', () async {
    final transport = MemoryVoiceTransport();
    final controller = VoiceScribeSettingsController(transport, () => true);
    addTearDown(controller.dispose);
    await controller.refresh();
    transport.readHook = () async => throw StateError('unavailable');
    expect(await controller.save(controller.generation, VoiceScribeField.language, 'zh'), isTrue);
    expect(controller.data!.language, 'zh');
    expect(controller.error, contains('已保存'));
  });

  test('old refresh and old plugin generation cannot publish or write', () async {
    final transport = MemoryVoiceTransport();
    final controller = VoiceScribeSettingsController(transport, () => true);
    addTearDown(controller.dispose);
    await controller.refresh();
    final oldRead = Completer<VoiceScribeSettings>();
    transport.readHook = () => oldRead.future;
    final refreshing = controller.refresh();
    transport.readHook = null;
    expect(await controller.save(controller.generation, VoiceScribeField.language, 'zh'), isTrue);
    oldRead.complete(transport.value.changed(VoiceScribeField.language, 'obsolete'));
    await refreshing;
    expect(controller.data!.language, 'zh');
    final oldGeneration = controller.generation;
    controller.invalidate();
    await controller.refresh();
    final before = transport.writes.length;
    expect(await controller.save(oldGeneration, VoiceScribeField.language, 'en'), isFalse);
    expect(transport.writes.length, before);
  });
}
