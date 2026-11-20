// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: the ink table (`src/client/inks.js`) and `fnv1a` / `defaultColor`
// (`src/client/characters.js`) translated to Dart.

/// DS Bot client: the channel of the `ds-bot` DSH plugin on a `dsh web` Host.
///
/// Wire (ds-bot `src/host/channel.js`, `feed.js`, `mobile.js`; the contract
/// is `docs/plans/2026-10-24-mobile-api.md` in that repository):
/// ```text
/// POST /api/bot   {"endpoint": "<name>", "payload": {...}}
/// 200 {"ok": true, "value": ...}
/// 200 {"ok": false, "error": {"code": "bot/...", "message": "..."}}
///
/// GET /api/bot/feed   text/event-stream
/// event: hello | revision | live | message | stream | notice | room
/// ```
/// Both are plain Fetch routes behind the Host's session cookie, reached on
/// the HTTP carrier (the device's own engine, an SSH tunnel). The same calls
/// and feed are DSH Remote methods too, `dsBot/call` and the `dsBot/feed`
/// stream, for a carrier that forwards Remote methods but not Fetch routes:
/// the ds-harness-remote relay, once its allow-list names them.
///
/// Versioning: [DsBotApi.hello] names the API version both sides speak. Fields,
/// item kinds, notice kinds and feed events this client does not know are
/// skipped, never an error; a host without `hello` is a DS Bot from before the
/// mobile API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'mux.dart';
import 'session_api.dart';

// ── Transport ────────────────────────────────────────────────────────────────

/// One Server-Sent Event of the feed.
class DsBotSseEvent {
  const DsBotSseEvent(this.event, this.data);

  final String event;

  /// Decoded JSON of the `data:` lines; null when they were not JSON.
  final Object? data;
}

/// How [DsBotApi] reaches the plugin. Tests swap in a fake.
abstract class DsBotTransport {
  /// One call. Returns `value`; throws [DshRemoteException] (`bot/...` codes)
  /// for `ok: false`, [DshHttpException] when the route is missing (404: the
  /// plugin is not installed or not enabled) or refused, and
  /// [DshTransportException] / [DshProtocolException] for the pipe.
  Future<Object?> call(String endpoint, Map<String, Object?> payload, {Duration? timeout});

  /// One feed connection: its events until it drops, then the stream ends
  /// (with an error when it failed).
  Stream<DsBotSseEvent> openFeed();

  Future<void> close();
}

/// [DsBotTransport] over the Host's HTTP carrier: same address, `Host` header
/// and session cookie as [DshConnection], its own sockets for the feed.
class DsBotHttpTransport implements DsBotTransport {
  DsBotHttpTransport(this.connection, {HttpClient? httpClient, this.feedIdle = const Duration(seconds: 50)})
    : _http = httpClient ?? (HttpClient()..connectionTimeout = connection.connectTimeout),
      _ownsClient = httpClient == null;

  final DshConnection connection;

  /// The host sends a keepalive every 20 s; this long without a byte means the
  /// link is gone even if the socket never said so.
  final Duration feedIdle;
  final HttpClient _http;
  final bool _ownsClient;

  static const route = '/api/bot';
  static const feedRoute = '/api/bot/feed';

  @override
  Future<Object?> call(String endpoint, Map<String, Object?> payload, {Duration? timeout}) async {
    final response = await connection.postJson(route, {'endpoint': endpoint, 'payload': payload}, timeout: timeout);
    if (response.statusCode != 200) {
      throw DshHttpException(
        response.statusCode,
        response.statusCode == 404 ? 'DS Bot is not installed on this host' : 'HTTP ${response.statusCode} from $route',
        body: response.text,
      );
    }
    final decoded = asMap(tryDecodeJson(response.text));
    if (decoded == null || decoded['ok'] is! bool) {
      throw DshProtocolException('$route $endpoint: not a DS Bot answer');
    }
    if (decoded['ok'] == true) return decoded['value'];
    throw DshRemoteException.fromJson(decoded['error']);
  }

  @override
  Stream<DsBotSseEvent> openFeed() {
    late final StreamController<DsBotSseEvent> controller;
    HttpClientRequest? request;
    StreamSubscription<String>? lines;
    var cancelled = false;
    controller = StreamController<DsBotSseEvent>(
      onListen: () async {
        try {
          final req = request = await _http.openUrl('GET', connection.resolve(feedRoute));
          if (cancelled) {
            // Cancellation may have finished before openUrl supplied a request.
            req.done.ignore();
            req.abort();
            return;
          }
          _applyHost(req.headers);
          if (connection.cookie case final cookie?) req.headers.set(HttpHeaders.cookieHeader, cookie.header);
          req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          req.followRedirects = false;
          final response = await req.close().timeout(connection.connectTimeout);
          if (cancelled) {
            await response.listen(null).cancel();
            return;
          }
          if (response.statusCode != 200) {
            await response.listen(null).cancel().catchError((_) {});
            throw DshHttpException(response.statusCode, 'HTTP ${response.statusCode} from $feedRoute');
          }
          final parser = SseParser();
          lines = response
              .timeout(feedIdle)
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  final event = parser.add(line);
                  if (event != null && !controller.isClosed) controller.add(event);
                },
                onError: (Object error) {
                  if (controller.isClosed) return;
                  controller.addError(
                    error is TimeoutException ? DshTransportException('feed went quiet', error) : error,
                  );
                  unawaited(controller.close());
                },
                onDone: () => unawaited(controller.close()),
                cancelOnError: true,
              );
        } on DshException catch (error) {
          if (!controller.isClosed) {
            controller.addError(error);
            unawaited(controller.close());
          }
        } on Object catch (error) {
          if (!controller.isClosed) {
            controller.addError(DshTransportException('feed failed: $error', error));
            unawaited(controller.close());
          }
        }
      },
      onCancel: () async {
        cancelled = true;
        request?.abort();
        await lines?.cancel();
      },
    );
    return controller.stream;
  }

  void _applyHost(HttpHeaders headers) {
    final override = connection.hostHeader;
    if (override == null) return;
    final parsed = Uri.tryParse('http://$override');
    if (parsed == null || parsed.host.isEmpty) return;
    headers.host = parsed.host;
    headers.port = parsed.hasPort ? parsed.port : 80;
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _http.close(force: true);
  }
}

/// [DsBotTransport] over the Host's Remote methods `dsBot/call` and the
/// `dsBot/feed` stream (DS Bot `src/host/remote.js`), for carriers that
/// forward Remote methods but not Fetch routes (the relay). Answers and
/// errors are the same as over HTTP.
class DsBotRpcTransport implements DsBotTransport {
  DsBotRpcTransport(this.client);

  final DshClient client;

  static const callEndpoint = 'dsBot/call';
  static const feedEndpoint = 'dsBot/feed';

  /// Whether [client]'s carrier lets both methods through.
  static bool reachable(DshClient client) =>
      client.supportsEndpoint(callEndpoint) && client.supportsEndpoint(feedEndpoint);

  @override
  Future<Object?> call(String endpoint, Map<String, Object?> payload, {Duration? timeout}) async {
    final Object? answer;
    try {
      answer = await client.rpc.call(callEndpoint, {'endpoint': endpoint, 'payload': payload}, timeout);
    } on DshRemoteException catch (error) {
      // A host whose DS Bot has no Remote methods (missing or older): as over HTTP.
      // A relay that refuses the method (`METHOD_NOT_ALLOWED`) stays as it is.
      if (error.code == 'gateway/invocation-unavailable') {
        throw DshHttpException(404, 'DS Bot is not reachable on this host: ${error.message}');
      }
      rethrow;
    }
    final decoded = asMap(answer);
    if (decoded == null || decoded['ok'] is! bool) {
      throw DshProtocolException('$callEndpoint $endpoint: not a DS Bot answer');
    }
    if (decoded['ok'] == true) return decoded['value'];
    throw DshRemoteException.fromJson(decoded['error']);
  }

  @override
  Stream<DsBotSseEvent> openFeed() {
    late final StreamController<DsBotSseEvent> controller;
    MuxStream? stream;
    StreamSubscription<Object?>? sub;
    controller = StreamController<DsBotSseEvent>(
      onListen: () {
        try {
          stream = client.mux.open(feedEndpoint, const {});
        } on Object catch (error) {
          controller.addError(error);
          unawaited(controller.close());
          return;
        }
        sub = stream!.items.listen(
          (item) {
            final map = asMap(item);
            final event = asString(map?['event']);
            if (event != null && !controller.isClosed) controller.add(DsBotSseEvent(event, map!['data']));
          },
          onError: (Object error) {
            if (controller.isClosed) return;
            controller.addError(error);
            unawaited(controller.close());
          },
          onDone: () => unawaited(controller.close()),
        );
      },
      onCancel: () async {
        await sub?.cancel();
        await stream?.cancel();
      },
    );
    return controller.stream;
  }

  /// The client belongs to the connection, not to this transport.
  @override
  Future<void> close() async {}
}

/// Server-Sent Events, one line at a time (the `LineSplitter` output).
class SseParser {
  String _event = 'message';
  final List<String> _data = [];

  /// The event a blank line completes, else null.
  DsBotSseEvent? add(String line) {
    if (line.isEmpty) {
      if (_data.isEmpty) {
        _event = 'message';
        return null;
      }
      final text = _data.join('\n');
      final event = DsBotSseEvent(_event, tryDecodeJson(text));
      _event = 'message';
      _data.clear();
      return event;
    }
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') _event = value;
    if (field == 'data') _data.add(value);
    return null;
  }
}

// ── Models ───────────────────────────────────────────────────────────────────

/// The answer to `hello`.
class DsBotHello {
  const DsBotHello({
    required this.api,
    required this.apiMin,
    required this.apiMax,
    required this.pluginVersion,
    required this.capabilities,
    required this.boot,
    required this.seq,
    required this.revision,
    this.readOnly,
    this.memory = true,
  });

  factory DsBotHello.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final plugin = asMapOrEmpty(map['plugin']);
    return DsBotHello(
      api: asInt(map['api']),
      apiMin: asInt(map['apiMin']) ?? 1,
      apiMax: asInt(map['apiMax']) ?? 1,
      pluginVersion: asString(plugin['version']) ?? '',
      capabilities: asStringList(map['capabilities']).toSet(),
      boot: asString(map['boot']) ?? '',
      seq: asInt(map['seq']) ?? 0,
      revision: asInt(map['revision']) ?? 0,
      readOnly: asString(map['readOnly']),
      memory: asBool(map['memory']) ?? true,
    );
  }

  /// The version both sides speak; null when there is none.
  final int? api;
  final int apiMin;
  final int apiMax;
  final String pluginVersion;
  final Set<String> capabilities;

  /// Changes on every start of the host; notices are numbered within it.
  final String boot;
  final int seq;
  final int revision;

  /// Why this host cannot change the team (another DSH holds it).
  final String? readOnly;
  final bool memory;

  bool get compatible => api != null;
  bool supports(String capability) => capabilities.contains(capability);
}

/// A Bot as `state` lists it.
class DsBot {
  const DsBot({
    required this.id,
    required this.name,
    this.role = '',
    this.instructions = '',
    this.color,
    this.shape,
    this.imageRef,
    this.model,
    this.appliedModel,
    this.effort,
    String? sessionId,
    this.parts = const [],
    this.waiting = false,
    this.createdAt,
    this.createdBy,
    this.workDir,
  }) : sessionId = sessionId ?? id;

  factory DsBot.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final avatar = asMapOrEmpty(map['avatar']);
    final id = asString(map['id']) ?? '';
    final image = asString(avatar['image']);
    return DsBot(
      id: id,
      name: asString(map['name']) ?? '',
      role: asString(map['role']) ?? '',
      instructions: asString(map['instructions']) ?? '',
      color: asString(map['color']),
      shape: asString(avatar['shape']),
      // A host without photo references sends the photo itself.
      imageRef: asString(avatar['imageRef']) ?? (image == null ? null : 'inline:${image.hashCode}'),
      model: asString(map['model']),
      appliedModel: asString(map['appliedModel']),
      effort: asString(map['effort']),
      sessionId: asString(map['sessionId']),
      parts: asStringList(map['parts']),
      waiting: asBool(map['waiting']) ?? false,
      createdAt: asEpochMs(map['createdAt']),
      createdBy: asString(map['createdBy']),
      workDir: asString(map['workDir']),
    );
  }

  final String id;
  final String name;

  /// Short label under the name (「写手」).
  final String role;
  final String instructions;

  /// The color the user picked (an ink id or `#rrggbb`); [ink] resolves it.
  final String? color;

  /// The character the web client draws; this client draws a monogram.
  final String? shape;

  /// Key of the profile photo, fetched with [DsBotApi.avatar].
  final String? imageRef;

  /// `provider/model` the Bot runs on; null until the user picks one.
  final String? model;
  final String? appliedModel;
  final String? effort;

  /// The current part of the Bot's own chat.
  final String sessionId;
  final List<String> parts;

  /// The Bot holds its greeting until the user picks its model.
  final bool waiting;
  final DateTime? createdAt;
  final String? createdBy;
  final String? workDir;

  /// The color it shows in: the picked one, else the one its id picks.
  String get ink => dsBotIsColor(color) ? dsBotCurrentColor(color!) : dsBotDefaultColor(id);

  /// The model it runs on: picked, else the one it last ran on.
  String? get modelRef => model ?? appliedModel;
}

/// A group chat.
class DsBotRoom {
  const DsBotRoom({
    required this.id,
    required this.name,
    this.members = const [],
    this.admin,
    this.mode = 'admin',
    this.relayLimit,
    this.relayLimitDefault,
    this.pausedCallIds = const [],
    this.notice = '',
    this.preview,
    this.createdAt,
    this.workDir,
    this.parts = const [],
  });

  factory DsBotRoom.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotRoom(
      id: asString(map['id']) ?? '',
      name: asString(map['name']) ?? '',
      members: asStringList(map['members']),
      admin: asString(map['admin']),
      mode: asString(map['mode']) ?? 'admin',
      relayLimit: asInt(map['relayLimit']),
      relayLimitDefault: asInt(map['relayLimitDefault']),
      pausedCallIds: [
        for (final entry in asListOrEmpty(map['paused']))
          if (asString(asMapOrEmpty(entry)['id']) case final id? when id.isNotEmpty) id,
      ],
      notice: asString(map['notice']) ?? '',
      preview: asString(map['preview']),
      createdAt: asEpochMs(map['createdAt']),
      workDir: asString(map['workDir']),
      parts: asStringList(map['parts']),
    );
  }

  final String id;
  final String name;
  final List<String> members;
  final String? admin;

  /// `admin`: plain messages go to the admin first; `everyone`: each member in
  /// turn, admin first.
  final String mode;

  /// User override, or null for the server-computed per-member default.
  final int? relayLimit;
  final int? relayLimitDefault;

  /// Calls parked at the group relay limit, until the user continues or writes.
  final List<String> pausedCallIds;
  bool get paused => pausedCallIds.isNotEmpty;

  final String notice;

  /// The last line: `User`'s words, or `Name：text`.
  final String? preview;
  final DateTime? createdAt;
  final String? workDir;

  /// The members' hidden Sessions in this group (and their earlier parts).
  final List<String> parts;

  bool get adminFirst => mode != 'everyone';
}

/// One option of a question card.
class DsBotOption {
  const DsBotOption(this.label, [this.description]);
  final String label;
  final String? description;
}

/// An `ask_user` card waiting in a Bot's own chat.
class DsBotQuestion {
  const DsBotQuestion({
    required this.id,
    required this.question,
    this.detail,
    this.options = const [],
    this.multiSelect = false,
    this.allowCustom = false,
    this.askedAt,
  });

  factory DsBotQuestion.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotQuestion(
      id: asString(map['id']) ?? '',
      question: asString(map['question']) ?? '',
      detail: asString(map['detail']),
      options: [
        for (final option in asListOrEmpty(map['options']))
          if (asString(asMapOrEmpty(option)['label']) case final label?)
            DsBotOption(label, asString(asMapOrEmpty(option)['description'])),
      ],
      multiSelect: asBool(map['multiSelect']) ?? false,
      allowCustom: asBool(map['allowCustom']) ?? false,
      askedAt: asEpochMs(map['askedAt']),
    );
  }

  final String id;
  final String question;
  final String? detail;
  final List<DsBotOption> options;
  final bool multiSelect;
  final bool allowCustom;
  final DateTime? askedAt;
}

/// A `show_view` card waiting for an answer: [view] is its JSON blueprint.
class DsBotViewCard {
  const DsBotViewCard({required this.id, required this.title, required this.view, this.askedAt});

  factory DsBotViewCard.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotViewCard(
      id: asString(map['id']) ?? '',
      title: asString(map['title']) ?? '',
      view: asMapOrEmpty(map['view']),
      askedAt: asEpochMs(map['askedAt']),
    );
  }

  final String id;
  final String title;
  final JsonMap view;
  final DateTime? askedAt;
}

/// A model the host serves.
class DsBotModel {
  const DsBotModel({required this.ref, required this.name, this.providerName = '', this.needsKey = false});

  factory DsBotModel.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotModel(
      ref: asString(map['ref']) ?? '',
      name: asString(map['name']) ?? asString(map['id']) ?? '',
      providerName: asString(map['providerName']) ?? '',
      needsKey: asBool(map['needsKey']) ?? false,
    );
  }

  final String ref;
  final String name;
  final String providerName;
  final bool needsKey;
}

/// What a Bot is doing: a turn (in its own chat or a group), with its
/// current tool.
class DsBotWork {
  const DsBotWork({
    this.botId,
    this.since,
    this.tool,
    this.note,
    this.target,
    this.roomId,
    this.switching = false,
    this.speaking = false,
  });

  factory DsBotWork.fromJson(Object? json, {String? botId}) {
    final map = asMapOrEmpty(json);
    return DsBotWork(
      botId: asString(map['botId']) ?? botId,
      since: asEpochMs(map['since']),
      tool: asString(map['tool']),
      note: asString(map['note']),
      target: asString(map['target']),
      roomId: asString(map['roomId']),
      switching: asBool(map['switching']) ?? false,
      speaking: asBool(map['speaking']) ?? false,
    );
  }

  final String? botId;
  final DateTime? since;
  final String? tool;

  /// The tool call's own description, when it has one.
  final String? note;

  /// A file name, query or site the tool works on.
  final String? target;
  final String? roomId;

  /// Writing its handoff note before a fresh part.
  final bool switching;

  /// The member speaking in its group right now.
  final bool speaking;
}

/// A Bot waiting for the user's approval. [answerable]: a member's request in
/// a group, answered here; a Bot's own chat keeps DSH's own approval card.
class DsBotApproval {
  const DsBotApproval({
    required this.id,
    required this.sessionId,
    required this.botId,
    this.roomId,
    this.tool = '',
    this.reason = '',
    this.at,
    this.answerable = false,
  });

  factory DsBotApproval.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotApproval(
      id: asString(map['id']) ?? '',
      sessionId: asString(map['sessionId']) ?? '',
      botId: asString(map['botId']) ?? '',
      roomId: asString(map['roomId']),
      tool: asString(map['tool']) ?? '',
      reason: asString(map['reason']) ?? '',
      at: asEpochMs(map['at']),
      answerable: asBool(map['answerable']) ?? false,
    );
  }

  final String id;
  final String sessionId;
  final String botId;
  final String? roomId;
  final String tool;
  final String reason;
  final DateTime? at;
  final bool answerable;
}

/// What changes without a new revision.
class DsBotLive {
  const DsBotLive({
    this.activity = const {},
    this.bots = const {},
    this.rooms = const {},
    this.approvals = const [],
    this.memoryReviews = 0,
  });

  factory DsBotLive.fromJson(JsonMap map) {
    final work = asMapOrEmpty(map['work']);
    return DsBotLive(
      activity: {
        for (final entry in asMapOrEmpty(map['activity']).entries)
          if (entry.value is String) entry.key: entry.value! as String,
      },
      bots: {
        for (final entry in asMapOrEmpty(work['bots']).entries)
          entry.key: DsBotWork.fromJson(entry.value, botId: entry.key),
      },
      rooms: {
        for (final entry in asMapOrEmpty(work['rooms']).entries)
          entry.key: [for (final item in asListOrEmpty(entry.value)) DsBotWork.fromJson(item)],
      },
      approvals: [for (final item in asListOrEmpty(work['approvals'])) DsBotApproval.fromJson(item)],
      memoryReviews: asInt(map['memoryReviews']) ?? 0,
    );
  }

  /// Per Bot: `thinking`, or the kind of thing it is doing.
  final Map<String, String> activity;

  /// Per Bot: the turn it runs (its own chat wins over a group).
  final Map<String, DsBotWork> bots;

  /// Per group: the members whose turn there runs.
  final Map<String, List<DsBotWork>> rooms;
  final List<DsBotApproval> approvals;
  final int memoryReviews;

  bool isWorking(String botId) => bots.containsKey(botId);
}

/// The team as `state` answers it.
class DsBotTeam {
  const DsBotTeam({
    required this.revision,
    this.mainBotIds = const [],
    this.bots = const [],
    this.rooms = const [],
    this.questions = const {},
    this.views = const {},
    this.models = const [],
    this.defaultModel,
    this.modelsKey,
    this.memory = true,
    this.readOnly,
  });

  factory DsBotTeam.fromJson(JsonMap map) => DsBotTeam(
    revision: asInt(map['revision']) ?? 0,
    mainBotIds: asStringList(map['mainBotIds']),
    bots: [for (final bot in asListOrEmpty(map['bots'])) DsBot.fromJson(bot)],
    rooms: [for (final room in asListOrEmpty(map['rooms'])) DsBotRoom.fromJson(room)],
    questions: {
      for (final entry in asMapOrEmpty(map['questions']).entries) entry.key: DsBotQuestion.fromJson(entry.value),
    },
    views: {for (final entry in asMapOrEmpty(map['views']).entries) entry.key: DsBotViewCard.fromJson(entry.value)},
    models: [for (final model in asListOrEmpty(map['models'])) DsBotModel.fromJson(model)],
    defaultModel: asString(map['defaultModel']),
    modelsKey: asString(map['modelsKey']),
    memory: asBool(map['memory']) ?? true,
    readOnly: asString(map['readOnly']),
  );

  final int revision;
  final List<String> mainBotIds;
  final List<DsBot> bots;
  final List<DsBotRoom> rooms;

  /// Question cards by the Session they wait in (a Bot's current part).
  final Map<String, DsBotQuestion> questions;
  final Map<String, DsBotViewCard> views;
  final List<DsBotModel> models;
  final String? defaultModel;
  final String? modelsKey;
  final bool memory;
  final String? readOnly;

  DsBot? bot(String? id) {
    if (id == null) return null;
    for (final bot in bots) {
      if (bot.id == id) return bot;
    }
    return null;
  }

  DsBotRoom? room(String? id) {
    if (id == null) return null;
    for (final room in rooms) {
      if (room.id == id) return room;
    }
    return null;
  }

  bool isMain(String id) => mainBotIds.contains(id);

  /// The Bot whose chat Session (any part) is [sessionId].
  DsBot? botOfSession(String sessionId) {
    for (final bot in bots) {
      if (bot.id == sessionId || bot.sessionId == sessionId || bot.parts.contains(sessionId)) return bot;
    }
    return null;
  }

  /// Every DSH Session the team uses: Bots' chats (all parts), groups' own
  /// Sessions and members' hidden group Sessions.
  Set<String> get sessionIds => {
    for (final bot in bots) ...[bot.id, bot.sessionId, ...bot.parts],
    for (final room in rooms) ...[room.id, ...room.parts],
  };

  DsBotQuestion? questionOf(DsBot bot) => questions[bot.sessionId] ?? questions[bot.id];
  DsBotViewCard? viewOf(DsBot bot) => views[bot.sessionId] ?? views[bot.id];
}

/// The answer to `state`: the whole team, or only the live part when the
/// revision is the one the client has.
class DsBotState {
  const DsBotState({required this.revision, required this.live, this.team});

  factory DsBotState.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final unchanged = asBool(map['unchanged']) ?? false;
    return DsBotState(
      revision: asInt(map['revision']) ?? 0,
      live: DsBotLive.fromJson(map),
      team: unchanged ? null : DsBotTeam.fromJson(map),
    );
  }

  final int revision;
  final DsBotLive live;

  /// Null when unchanged.
  final DsBotTeam? team;
}

/// A long post stored as a DSH file. Reads can be limited by the Host.
class DsBotLongText {
  const DsBotLongText(this.length, this.file);
  final int length;
  final JsonMap file;
}

/// A bounded `file-text` response. Null [whole] means completeness is unknown.
class DsBotFileText {
  const DsBotFileText(this.text, {this.whole});

  factory DsBotFileText.fromJson(Object? value) {
    if (value is String) return DsBotFileText(value);
    final map = asMapOrEmpty(value);
    final text = map['text'];
    if (text is! String) throw const FormatException('DS Bot file-text response has no text');
    return DsBotFileText(text, whole: asBool(map['whole']));
  }

  final String text;
  final bool? whole;
}

enum DsBotItemKind { user, bot, event, answer, divider, unknown }

/// One entry of a chat or a group chat, ready to draw.
class DsBotItem {
  const DsBotItem({
    required this.kind,
    this.id,
    this.text = '',
    this.time,
    this.botId,
    this.name,
    this.color,
    this.event,
    this.code,
    this.role,
    this.roomId,
    this.images = 0,
    this.duration,
    this.live = false,
    this.whole,
  });

  factory DsBotItem.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final whole = asMap(map['whole']);
    return DsBotItem(
      kind: switch (asString(map['kind'])) {
        'user' => DsBotItemKind.user,
        'bot' => DsBotItemKind.bot,
        'event' => DsBotItemKind.event,
        'answer' => DsBotItemKind.answer,
        'divider' => DsBotItemKind.divider,
        _ => DsBotItemKind.unknown,
      },
      id: asString(map['id']),
      text: asString(map['text']) ?? '',
      time: asEpochMs(map['time']),
      botId: asString(map['botId']),
      name: asString(map['name']),
      color: asString(map['color']),
      event: asString(map['event']),
      code: asString(map['code']),
      role: asString(map['role']),
      roomId: asString(map['roomId']),
      images: asInt(map['images']) ?? 0,
      duration: asInt(map['duration']) == null ? null : Duration(milliseconds: asInt(map['duration'])!),
      live: asBool(map['live']) ?? false,
      whole: whole == null ? null : DsBotLongText(asInt(whole['length']) ?? 0, asMapOrEmpty(whole['file'])),
    );
  }

  final DsBotItemKind kind;

  /// Stable within a group chat (`<seq>` or `<callId>:<index>`); a Bot's own
  /// chat has none.
  final String? id;
  final String text;
  final DateTime? time;
  final String? botId;
  final String? name;
  final String? color;

  /// For [DsBotItemKind.event]: `working`, `approval`, `done`, `stopped`,
  /// `failed`, `missed`, `lookup`, `resumed`, `cut`, `schedule` in a group;
  /// in a Bot's own chat [role] says what came from another Bot.
  final String? event;
  final String? code;

  /// In a Bot's own chat: `request`, `reply`, `report` or `stopped`.
  final String? role;
  final String? roomId;
  final int images;
  final Duration? duration;

  /// Said in the round still running; replaced by the logged one later.
  final bool live;
  final DsBotLongText? whole;

  /// Same entry (dedupe of a page and the feed).
  bool sameAs(DsBotItem other) =>
      id != null && other.id != null ? id == other.id : kind == other.kind && time == other.time && text == other.text;
}

/// A page of a Bot's own chat, newest page first, oldest first within it.
class DsBotChatPage {
  const DsBotChatPage({required this.sessionId, required this.items, this.cursor});

  factory DsBotChatPage.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotChatPage(
      sessionId: asString(map['sessionId']) ?? '',
      items: [for (final item in asListOrEmpty(map['items'])) DsBotItem.fromJson(item)],
      cursor: map['cursor'],
    );
  }

  /// The current part, which the feed's `message` events name.
  final String sessionId;
  final List<DsBotItem> items;

  /// Pass back for the page before; null at the start.
  final Object? cursor;
}

/// A page of a group chat.
class DsBotRoomPage {
  const DsBotRoomPage({required this.roomId, required this.items, this.cursor, this.running = false, this.speaking});

  factory DsBotRoomPage.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotRoomPage(
      roomId: asString(map['roomId']) ?? '',
      items: [for (final item in asListOrEmpty(map['items'])) DsBotItem.fromJson(item)],
      cursor: map['cursor'],
      running: asBool(map['running']) ?? false,
      speaking: asString(map['speaking']),
    );
  }

  final String roomId;
  final List<DsBotItem> items;
  final Object? cursor;

  /// A round is under way.
  final bool running;

  /// The member speaking now.
  final String? speaking;
}

/// Kinds of [DsBotNotice].
abstract final class DsBotNoticeKind {
  static const message = 'message';
  static const group = 'group';
  static const done = 'done';
  static const question = 'question';
  static const view = 'view';
  static const approval = 'approval';

  /// Needs the person: a card or an approval.
  static bool attention(String kind) => kind == question || kind == view || kind == approval;
}

/// Something a client that is not looking should hear about.
class DsBotNotice {
  const DsBotNotice({
    required this.seq,
    required this.kind,
    required this.botId,
    this.name = '',
    this.roomId,
    this.title,
    this.sessionId,
    this.text = '',
    this.time,
  });

  factory DsBotNotice.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotNotice(
      seq: asInt(map['seq']) ?? 0,
      kind: asString(map['kind']) ?? '',
      botId: asString(map['botId']) ?? '',
      name: asString(map['name']) ?? '',
      roomId: asString(map['roomId']),
      title: asString(map['title']),
      sessionId: asString(map['sessionId']),
      text: asString(map['text']) ?? '',
      time: asEpochMs(map['time']),
    );
  }

  final int seq;
  final String kind;
  final String botId;

  /// The Bot's name now.
  final String name;
  final String? roomId;

  /// The group's name, for a notice from a group.
  final String? title;
  final String? sessionId;
  final String text;
  final DateTime? time;

  /// The conversation it belongs to: the group, else the Bot.
  String get conversationId => roomId ?? botId;
}

/// The answer to `notices`.
class DsBotNotices {
  const DsBotNotices({required this.boot, required this.seq, required this.reset, required this.notices});

  factory DsBotNotices.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotNotices(
      boot: asString(map['boot']) ?? '',
      seq: asInt(map['seq']) ?? 0,
      reset: asBool(map['reset']) ?? false,
      notices: [for (final notice in asListOrEmpty(map['notices'])) DsBotNotice.fromJson(notice)],
    );
  }

  final String boot;
  final int seq;

  /// Notices were lost (a restart, or more than the host keeps): read the
  /// team again.
  final bool reset;
  final List<DsBotNotice> notices;
}

/// One memory entry.
class DsBotMemoryEntry {
  const DsBotMemoryEntry({required this.scope, required this.text, this.topic, this.added, this.by, this.source});

  factory DsBotMemoryEntry.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotMemoryEntry(
      scope: asString(map['scope']) ?? 'own',
      text: asString(map['text']) ?? '',
      topic: asString(map['topic']),
      added: asString(map['added']),
      by: asString(map['by']),
      source: asString(map['source']),
    );
  }

  /// `own` (the Bot's), `team` or `group`.
  final String scope;
  final String text;
  final String? topic;

  /// `YYYY-MM-DD`.
  final String? added;

  /// Who wrote it, when not the Bot itself (`user`, another Bot).
  final String? by;
  final String? source;
}

/// A Bot's or a group's memory, as the memory panel shows it.
class DsBotMemoryView {
  const DsBotMemoryView({required this.entries, this.summary, this.summarizing = false, this.error});

  factory DsBotMemoryView.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotMemoryView(
      entries: [for (final entry in asListOrEmpty(map['entries'])) DsBotMemoryEntry.fromJson(entry)],
      summary: asString(asMapOrEmpty(map['summary'])['text']),
      summarizing: asBool(map['summarizing']) ?? false,
      error: asString(map['error']),
    );
  }

  final List<DsBotMemoryEntry> entries;
  final String? summary;
  final bool summarizing;
  final String? error;
}

/// Token counts.
class DsBotUsageTotals {
  const DsBotUsageTotals({this.input = 0, this.cacheRead = 0, this.cacheWrite = 0, this.output = 0, this.calls = 0});

  factory DsBotUsageTotals.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    int read(String key) => asNum(map[key])?.toInt() ?? 0;
    return DsBotUsageTotals(
      input: read('input'),
      cacheRead: read('cacheRead'),
      cacheWrite: read('cacheWrite'),
      output: read('output'),
      calls: read('calls'),
    );
  }

  final int input;
  final int cacheRead;
  final int cacheWrite;
  final int output;
  final int calls;

  int get total => input + cacheRead + cacheWrite + output;
}

/// The answer to `usage-summary`.
class DsBotUsageSummary {
  const DsBotUsageSummary({
    this.day = const DsBotUsageTotals(),
    this.week = const DsBotUsageTotals(),
    this.month = const DsBotUsageTotals(),
    this.models = const [],
    this.scanning = false,
  });

  factory DsBotUsageSummary.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DsBotUsageSummary(
      scanning: asBool(map['scanning']) ?? false,
      day: DsBotUsageTotals.fromJson(map['day']),
      week: DsBotUsageTotals.fromJson(map['week']),
      month: DsBotUsageTotals.fromJson(map['month']),
      models: [
        for (final model in asListOrEmpty(map['models']))
          (
            key: asString(asMapOrEmpty(model)['key']) ?? '',
            name: asString(asMapOrEmpty(model)['name']) ?? '',
            totals: DsBotUsageTotals.fromJson(model),
          ),
      ],
    );
  }

  /// Older sessions are still being scanned; totals are incomplete.
  final bool scanning;

  /// Rolling 24 hourly buckets, not the local calendar day.
  final DsBotUsageTotals day;
  final DsBotUsageTotals week;
  final DsBotUsageTotals month;

  /// The last 30 days by model.
  final List<({String key, String name, DsBotUsageTotals totals})> models;
}

// ── Feed events ──────────────────────────────────────────────────────────────

sealed class DsBotFeedEvent {
  const DsBotFeedEvent();

  static DsBotFeedEvent parse(DsBotSseEvent raw) {
    final data = asMapOrEmpty(raw.data);
    switch (raw.event) {
      case 'hello':
        return DsBotFeedHello(
          revision: asInt(data['revision']) ?? 0,
          api: asInt(data['api']),
          boot: asString(data['boot']),
          seq: asInt(data['seq']),
        );
      case 'revision':
        return DsBotFeedRevision(asInt(data['revision']) ?? 0);
      case 'live':
        return const DsBotFeedLive();
      case 'message':
        return DsBotFeedMessage(
          botId: asString(data['botId']) ?? '',
          sessionId: asString(data['sessionId']) ?? '',
          item: DsBotItem.fromJson(data['item']),
        );
      case 'stream':
        return DsBotFeedStream(
          botId: asString(data['botId']) ?? '',
          sessionId: asString(data['sessionId']) ?? '',
          attemptId: asString(data['attemptId']) ?? '',
          phase: asString(data['phase']),
          text: asString(data['text']),
        );
      case 'notice':
        return DsBotFeedNotice(DsBotNotice.fromJson(data));
      case 'room':
        return DsBotFeedRoom(asString(data['roomId']) ?? '');
      default:
        return DsBotFeedOther(raw.event, raw.data);
    }
  }
}

/// First event of every connection.
final class DsBotFeedHello extends DsBotFeedEvent {
  const DsBotFeedHello({required this.revision, this.api, this.boot, this.seq});
  final int revision;

  /// Null on a DS Bot from before the mobile API.
  final int? api;
  final String? boot;
  final int? seq;
}

/// The team was saved: read `state` again.
final class DsBotFeedRevision extends DsBotFeedEvent {
  const DsBotFeedRevision(this.revision);
  final int revision;
}

/// Work changed without a new revision: read `state` again.
final class DsBotFeedLive extends DsBotFeedEvent {
  const DsBotFeedLive();
}

/// A new entry of a Bot's own chat.
final class DsBotFeedMessage extends DsBotFeedEvent {
  const DsBotFeedMessage({required this.botId, required this.sessionId, required this.item});
  final String botId;
  final String sessionId;
  final DsBotItem item;
}

/// The reply a Bot is writing: `phase: start`, then text pieces, then
/// `phase: end`.
final class DsBotFeedStream extends DsBotFeedEvent {
  const DsBotFeedStream({required this.botId, required this.sessionId, required this.attemptId, this.phase, this.text});
  final String botId;
  final String sessionId;
  final String attemptId;
  final String? phase;
  final String? text;
}

final class DsBotFeedNotice extends DsBotFeedEvent {
  const DsBotFeedNotice(this.notice);
  final DsBotNotice notice;
}

/// A group chat changed: read its first page again.
final class DsBotFeedRoom extends DsBotFeedEvent {
  const DsBotFeedRoom(this.roomId);
  final String roomId;
}

/// The connection dropped; [DsBotFeed] reconnects by itself.
final class DsBotFeedLost extends DsBotFeedEvent {
  const DsBotFeedLost(this.error);
  final Object? error;
}

/// An event this client does not know.
final class DsBotFeedOther extends DsBotFeedEvent {
  const DsBotFeedOther(this.event, this.data);
  final String event;
  final Object? data;
}

/// The live feed, reconnecting with backoff. Every connection starts with a
/// [DsBotFeedHello]; a drop is a [DsBotFeedLost].
class DsBotFeed {
  DsBotFeed(this._transport, {this.backoff = defaultBackoff});

  static const defaultBackoff = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  final DsBotTransport _transport;
  final List<Duration> backoff;
  final _events = StreamController<DsBotFeedEvent>.broadcast();
  StreamSubscription<DsBotSseEvent>? _link;
  Timer? _retry;
  int _failures = 0;
  bool _running = false;
  bool _connected = false;

  Stream<DsBotFeedEvent> get events => _events.stream;

  /// A connection is open and has said hello.
  bool get connected => _connected;

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  /// Connects again now (the app came back, the network changed), unless a
  /// connection is open.
  void kick() {
    if (!_running || _link != null) return;
    _retry?.cancel();
    _failures = 0;
    _connect();
  }

  void _connect() {
    if (!_running) return;
    _retry?.cancel();
    _link = _transport.openFeed().listen(
      (raw) {
        final event = DsBotFeedEvent.parse(raw);
        if (event is DsBotFeedHello) {
          _failures = 0;
          _connected = true;
        }
        _events.add(event);
      },
      onError: (Object error) => _lost(error),
      onDone: () => _lost(null),
      cancelOnError: true,
    );
  }

  void _lost(Object? error) {
    _link = null;
    final was = _connected;
    _connected = false;
    if (!_running) return;
    if (was || error != null) _events.add(DsBotFeedLost(error));
    final delay = backoff[math.min(_failures, backoff.length - 1)];
    _failures += 1;
    _retry = Timer(delay, _connect);
  }

  Future<void> close() async {
    _running = false;
    _connected = false;
    _retry?.cancel();
    await _link?.cancel();
    _link = null;
    await _events.close();
  }
}

// ── API ──────────────────────────────────────────────────────────────────────

/// Existing directories reported by the host, not paths on the phone.
class DsBotFolders {
  DsBotFolders.fromJson(Object? value) {
    final map = asMapOrEmpty(value);
    team = asString(map['team']);
    final items = map['folders'];
    folders = [
      if (items is List)
        for (final item in items)
          if (asString(asMapOrEmpty(item)['path']) case final String path when path.isNotEmpty)
            (path: path, title: asString(asMapOrEmpty(item)['title']) ?? path),
    ];
  }

  late final String? team;
  late final List<({String path, String title})> folders;
}

/// Calls of the DS Bot channel. Failures: [DshRemoteException] with a `bot/...`
/// code for the plugin's refusals (`message` is meant for the user, in
/// English), [DshHttpException] 404 when the plugin is missing.
class DsBotApi {
  DsBotApi(this.transport);

  /// The API on [client]'s host: the HTTP route on the HTTP carrier (the
  /// device's own engine, an SSH tunnel), else the Remote methods when the
  /// carrier forwards them (a relay that lists `dsBot/call` and
  /// `dsBot/feed`); null when neither reaches DS Bot.
  static DsBotApi? of(DshClient client) {
    final carrier = client.carrier;
    if (carrier is DshHttpCarrier) return DsBotApi(DsBotHttpTransport(carrier.connection));
    if (DsBotRpcTransport.reachable(client)) return DsBotApi(DsBotRpcTransport(client));
    return null;
  }

  /// Versions of the mobile API this client speaks.
  static const supportedApi = [1];

  final DsBotTransport transport;

  Future<Object?> call(String endpoint, [Map<String, Object?> payload = const {}, Duration? timeout]) =>
      transport.call(endpoint, payload, timeout: timeout);

  /// A new feed on this host; [DsBotFeed.start] connects it.
  DsBotFeed feed({List<Duration> backoff = DsBotFeed.defaultBackoff}) => DsBotFeed(transport, backoff: backoff);

  Future<DsBotHello> hello({String client = 'dsh-go', String? version, String platform = 'android'}) async =>
      DsBotHello.fromJson(
        await call('hello', {
          'client': {'name': client, 'version': ?version, 'platform': platform},
          'api': supportedApi,
        }),
      );

  /// The team; with [since] the host answers only the live part when nothing
  /// was saved since. Photos come as references ([DsBot.imageRef]).
  Future<DsBotState> state({int? since, String? modelsKey, String locale = 'zh-CN'}) async => DsBotState.fromJson(
    await call('state', {'since': ?since, 'models': ?modelsKey, 'locale': locale, 'avatars': 'ref'}),
  );

  /// A Bot's photo as a `data:` URL; null when it has none.
  Future<({String? ref, String? image})> avatar(String botId) async {
    final map = asMapOrEmpty(await call('avatar', {'botId': botId}));
    return (ref: asString(map['ref']), image: asString(map['image']));
  }

  Future<DsBotChatPage> chat(String botId, {Object? cursor}) async =>
      DsBotChatPage.fromJson(await call('chat', {'botId': botId, 'cursor': ?cursor}));

  Future<DsBotRoomPage> roomChat(String roomId, {Object? cursor}) async =>
      DsBotRoomPage.fromJson(await call('room-chat', {'roomId': roomId, 'cursor': ?cursor}));

  /// Sends [text] to a Bot (its id) or a group (its id).
  Future<void> send(String conversationId, String text) =>
      call('send', {'sessionId': conversationId, 'text': text}, const Duration(seconds: 40));

  /// Reads the Host's bounded preview, retaining its completeness metadata.
  Future<DsBotFileText> readFileText(DsBotLongText long) async =>
      DsBotFileText.fromJson(await call('file-text', {'file': long.file}));

  /// Text-only compatibility helper. Use [readFileText] when displaying the read.
  Future<String> fileText(DsBotLongText long) async {
    final value = await call('file-text', {'file': long.file});
    return asString(asMapOrEmpty(value)['text']) ?? asString(value) ?? '';
  }

  /// Copies the Bot's settings into a new Session; history and personal memory are fresh.
  Future<DsBot> duplicateBot(String id) async => DsBot.fromJson(await call('duplicate-bot', {'id': id}));

  Future<DsBot> createBot({
    required String name,
    String? role,
    String? instructions,
    String? color,
    String? model,
    String? effort,
    String? brief,
  }) async => DsBot.fromJson(
    await call('create-bot', {
      'name': name,
      'role': ?role,
      'instructions': ?instructions,
      'color': ?color,
      'model': ?model,
      'effort': ?effort,
      'brief': ?brief,
    }),
  );

  /// Changes only what is given; an empty [model] or [effort] clears it.
  Future<void> updateBot(
    String id, {
    String? name,
    String? role,
    String? instructions,
    String? color,
    String? model,
    String? effort,
  }) => call('update-bot', {
    'id': id,
    'name': ?name,
    'role': ?role,
    'instructions': ?instructions,
    'color': ?color,
    'model': ?model,
    'effort': ?effort,
  });

  Future<DsBotFolders> folders() async => DsBotFolders.fromJson(await call('folders'));

  /// The host validates the path. Empty string restores the team workspace.
  Future<void> setBotWorkDir(String id, String path) => call('update-bot', {'id': id, 'workDir': path});

  /// Empty string lets each group member use its own working directory again.
  Future<void> setRoomWorkDir(String id, String path) => call('update-room', {'id': id, 'workDir': path});

  Future<void> deleteBot(String id) => call('delete-bot', {'id': id});

  Future<void> setMain(String id, {required bool main}) => call('set-main', {'id': id, 'main': main});

  Future<DsBotRoom> createRoom({required List<String> members, String? name, String? admin, bool greet = true}) async =>
      DsBotRoom.fromJson(
        await call('create-room', {'members': members, 'name': ?name, 'admin': ?admin, 'greet': greet}),
      );

  Future<void> updateRoom(
    String id, {
    String? name,
    String? notice,
    String? mode,
    String? admin,
    List<String>? add,
    List<String>? remove,
  }) => call('update-room', {
    'id': id,
    'name': ?name,
    'notice': ?notice,
    'mode': ?mode,
    'admin': ?admin,
    'add': ?add,
    'remove': ?remove,
  });

  /// Explicit null restores the server default; omission would keep the old limit.
  Future<void> setRoomRelayLimit(String roomId, int? limit) {
    if (limit != null && (limit < 1 || limit > 200)) {
      throw RangeError.range(limit, 1, 200, 'limit');
    }
    return call('update-room', {'id': roomId, 'relayLimit': limit});
  }

  Future<void> deleteRoom(String id) => call('delete-room', {'id': id});

  /// Resumes calls parked at the group relay limit (DS Bot 0.2.3).
  Future<void> continueRoom(String roomId) => call('room-continue', {'roomId': roomId});

  /// Stops what a member works on in a group; false when it was not working.
  Future<bool> stopMemberWork(String roomId, String botId) async =>
      asBool(await call('stop-member-work', {'roomId': roomId, 'botId': botId})) ?? false;

  Future<void> answerApproval(String id, {required bool allow}) =>
      call('approval-answer', {'id': id, 'choice': allow ? 'allow' : 'reject'});

  Future<void> answerQuestion(DsBot bot, DsBotQuestion question, {List<String> selected = const [], String? custom}) =>
      call('answer-question', {
        'sessionId': bot.sessionId,
        'questionId': question.id,
        'answer': {'selected': selected, 'custom': ?custom},
      });

  Future<void> dismissQuestion(DsBot bot) => call('dismiss-question', {'sessionId': bot.sessionId});

  /// [action] is the id of the card's options / confirm / form component;
  /// [values] `{selected: [...]}`, `{confirmed: bool}` or `{fields: {...}}`.
  Future<void> answerView(DsBot bot, DsBotViewCard view, String action, Map<String, Object?> values) =>
      call('view-reply', {'sessionId': bot.sessionId, 'viewId': view.id, 'action': action, 'values': values});

  Future<void> dismissView(DsBot bot) => call('dismiss-view', {'sessionId': bot.sessionId});

  Future<DsBotMemoryView> memory({String? botId, String? roomId}) async =>
      DsBotMemoryView.fromJson(await call('memory-view', _target(botId, roomId)));

  Future<DsBotMemoryView> forgetMemory(DsBotMemoryEntry entry, {String? botId, String? roomId}) async =>
      DsBotMemoryView.fromJson(
        await call('memory-forget', {
          ..._target(botId, roomId),
          'scope': entry.scope,
          'topic': entry.topic,
          'text': entry.text,
        }),
      );

  /// Needs the `memory-edit` capability.
  Future<DsBotMemoryView> editMemory(DsBotMemoryEntry entry, String next, {String? botId, String? roomId}) async =>
      DsBotMemoryView.fromJson(
        await call('memory-edit', {
          ..._target(botId, roomId),
          'scope': entry.scope,
          'topic': entry.topic,
          'text': entry.text,
          'next': next,
        }),
      );

  Future<DsBotMemoryView> addMemory(String text, {String? botId, String? roomId, String? scope}) async =>
      DsBotMemoryView.fromJson(await call('memory-add', {..._target(botId, roomId), 'scope': ?scope, 'text': text}));

  Future<DsBotUsageSummary> usageSummary(String botId, {String? timeZone}) async =>
      DsBotUsageSummary.fromJson(await call('usage-summary', {'botId': botId, 'timeZone': ?timeZone}));

  Future<DsBotNotices> notices({String? boot, int? since}) async =>
      DsBotNotices.fromJson(await call('notices', {'boot': ?boot, 'since': ?since}));

  Map<String, Object?> _target(String? botId, String? roomId) =>
      roomId != null ? {'roomId': roomId} : {'botId': botId ?? ''};

  Future<void> close() => transport.close();
}

// ── Colors ───────────────────────────────────────────────────────────────────

/// Bot colors by ink id: (light, dark), as DS Bot's `src/client/inks.js` draws
/// them.
const Map<String, (int, int)> dsBotInks = {
  'deepseek': (0xFF4D6BFE, 0xFF6A84FF),
  'charcoal': (0xFF141416, 0xFFF1F2F4),
  'graphite': (0xFF2D2D2D, 0xFFD6D6DA),
  'rose': (0xFFEC2F6B, 0xFFFF5A7A),
  'sky': (0xFF0AA8D6, 0xFF2EE6E0),
  'tangerine': (0xFFFF6900, 0xFFFF8A2E),
  'cobalt': (0xFF082DFF, 0xFF5C78FF),
  'black': (0xFF000000, 0xFFFFFFFF),
  'brown': (0xFFA27952, 0xFF855C36),
  'red': (0xFFFF3E51, 0xFFE02135),
  'orange': (0xFFFF781C, 0xFFFF6700),
  'yellow': (0xFFFFAF38, 0xFFFF9800),
  'green': (0xFF00C972, 0xFF009957),
  'cyan': (0xFF1CC3B0, 0xFF00A592),
  'blue': (0xFF2A92FE, 0xFF0E74E0),
  'violet': (0xFFA97EFE, 0xFF804EE0),
  'magenta': (0xFFFF5EB1, 0xFFE02A88),
  'gray': (0xFF959595, 0xFF777777),
  'aurora': (0xFF00B8D4, 0xFF2EE6E0),
};

/// Colors offered when making a Bot, in DS Bot's picker order.
const dsBotPickerColors = ['red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'violet', 'magenta', 'gray', 'deepseek'];

const _legacyInks = {
  'kimi': 'charcoal',
  'zai': 'graphite',
  'minimax': 'rose',
  'stepfun': 'sky',
  'mimo': 'tangerine',
  'qwen': 'cobalt',
};
const _defaultColors = ['red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'violet', 'magenta'];
final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

String dsBotCurrentColor(String color) => _legacyInks[color] ?? color;

bool dsBotIsColor(String? color) =>
    color != null && (_hex.hasMatch(color) || dsBotInks.containsKey(dsBotCurrentColor(color)));

/// ARGB of [color] (an ink id or `#rrggbb`) for the light or dark theme.
int dsBotInkArgb(String color, {required bool dark}) {
  if (_hex.hasMatch(color)) return 0xFF000000 | int.parse(color.substring(1), radix: 16);
  final ink = dsBotInks[dsBotCurrentColor(color)] ?? dsBotInks['gray']!;
  return dark ? ink.$2 : ink.$1;
}

int _u32(int value) => value & 0xFFFFFFFF;

/// `Math.imul`, kept to the low 32 bits without relying on 64-bit wrapping.
int _imul(int a, int b) {
  final ah = (a >> 16) & 0xFFFF, al = a & 0xFFFF;
  final bh = (b >> 16) & 0xFFFF, bl = b & 0xFFFF;
  return _u32(al * bl + _u32((ah * bl + al * bh) << 16));
}

/// FNV-1a over UTF-16 code units, as `characters.js` computes it.
int dsBotFnv1a(String text) {
  var value = 2166136261;
  for (final unit in text.codeUnits) {
    value = _imul(_u32(value ^ unit), 16777619);
  }
  return value;
}

/// The color a Bot without a picked one shows in: the same on every device,
/// from its id (DS Bot `defaultColor`).
String dsBotDefaultColor(String id) {
  final t = _u32(dsBotFnv1a(id) + 1831565813);
  var n = _imul(t ^ (t >> 15), 1 | t);
  n = _u32(_u32(n + _imul(n ^ (n >> 7), 61 | n)) ^ n);
  final unit = _u32(n ^ (n >> 14)) / 4294967296;
  return _defaultColors[(unit * _defaultColors.length).floor()];
}
