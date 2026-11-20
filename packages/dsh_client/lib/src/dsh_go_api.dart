/// dsh-go native plugins: the app's end of the bridge's `dshGo` service
/// (docs/design/native-plugins-protocol.md, protocol v1).
///
/// * `GET  /dsh-go/v1/contributions`: every enabled plugin's native
///   contributions ([DshGoContributions]), asked with the app's capabilities
///   ([DshGoCaps]); `ETag` / `If-None-Match` make a re-read cheap.
/// * `GET  /dsh-go/v1/capabilities`: protocol major and implemented route
///   families ([DshGoBridgeCapabilities]), independent of resource availability.
/// * `GET  /dsh-go/v1/views/<pkg>/<id>`: one panel's view, initial data and
///   data revision ([DshGoView]).
/// * `WS   /dsh-go/v1/stream`: one socket per Host, subscriptions by
///   `{pkg, id, scope}` ([DshGoStream]). The stream keeps each subscription's
///   data model (JSON Merge Patch on `base` → `rev`), so a subscriber only
///   ever sees whole snapshots. It closes 60 s after the app goes to the
///   background and comes back with every subscription's `rev` (catch-up).
/// * `POST /dsh-go/v1/invoke`: a tap → the plugin's effects
///   ([DshGoInvokeResult]). Effects are data here; the app keeps its own
///   whitelist and runs them only within 3 s of the tap.
///
/// v1.2 adds optional capabilities (§11): `features` in the caps and in
/// `hello`, declared media / micro / overlays per plugin, a small `micro`
/// channel on the stream and `cap.event` upward. Nothing of it is sent unless
/// the app lists features.
///
/// Within a supported protocol major, unknown fields are ignored and malformed
/// contribution entries dropped. The routes are HTTP pages, so over the relay
/// tunnel none of this exists ([DshGoApi.canReachDshGo]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

/// Protocol major version the app speaks.
const dshGoProtocol = 1;

const dshGoCapabilitiesPath = '/dsh-go/v1/capabilities';
const dshGoContributionsPath = '/dsh-go/v1/contributions';
const dshGoViewsPath = '/dsh-go/v1/views';
const dshGoStreamPath = '/dsh-go/v1/stream';
const dshGoInvokePath = '/dsh-go/v1/invoke';

String _pickedFilePath(String request, String operation) {
  if (!RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(request)) throw ArgumentError('invalid file request');
  return '/dsh-go/v1/files/$request/$operation';
}

/// Surface names: the keys of `contributes`, and (for invoke) `panel`.
abstract final class DshGoSurfaces {
  static const composerActions = 'composer.actions';
  static const messageActions = 'message.actions';
  static const composerStrip = 'composer.strip';

  /// The `contributes` key and the `surfaces` capability.
  static const panels = 'panels';

  /// The invoke `surface` of a tap inside a panel.
  static const panel = 'panel';

  static const v1 = [composerActions, messageActions, composerStrip, panels];

  static const composerTools = 'composer.tools';
  static const sessionActions = 'session.actions';
  static const turnNote = 'turn.note';

  /// What an app that draws the newer places says in [DshGoCaps.surfaces]. A bridge moves a panel
  /// that asked only for [DshGoPanel.pluginPage] somewhere else for an app that doesn't list it.
  static const all = [...v1, composerTools, sessionActions, turnNote, DshGoPanel.pluginPage];
}

// -----------------------------------------------------------------------------
// Capabilities and scope
// -----------------------------------------------------------------------------

/// Implemented route families, not permission to act on a resource. Session
/// deletion, recall and signals still require their own fresh capability checks.
class DshGoBridgeCapabilities {
  const DshGoBridgeCapabilities({required this.v, required this.bridge, required this.capabilities});

  final int v;

  /// Implementation version for diagnostics; [v] determines protocol support.
  final String bridge;
  final Set<String> capabilities;
}

/// What the app can draw (§3.1 能力参数): sent as query parameters with every
/// read so a plugin can leave out what this app would only draw as a
/// placeholder.
class DshGoCaps {
  const DshGoCaps({
    this.versions = const [dshGoProtocol],
    this.app,
    this.locale,
    this.surfaces = DshGoSurfaces.v1,
    this.components = const [],
    this.features = const [],
  });

  final List<int> versions;

  /// App version `x.y.z`, compared with a plugin's `minApp`.
  final String? app;

  /// BCP 47 (`zh-CN`, `en`): the bridge picks plugin texts with it.
  final String? locale;
  final List<String> surfaces;
  final List<String> components;

  /// v1.2 capabilities this app supports right now ([dshGoFeatures]); empty
  /// sends nothing, which is the v1.1 request.
  final List<String> features;

  Map<String, String> get query => {
    'v': versions.join(','),
    'app': ?app,
    'locale': ?locale,
    if (surfaces.isNotEmpty) 'surfaces': surfaces.join(','),
    if (components.isNotEmpty) 'components': components.join(','),
    if (features.isNotEmpty) 'features': features.join(','),
  };

  @override
  bool operator ==(Object other) =>
      other is DshGoCaps &&
      other.app == app &&
      other.locale == locale &&
      other.versions.join(',') == versions.join(',') &&
      other.surfaces.join(',') == surfaces.join(',') &&
      other.components.join(',') == components.join(',') &&
      other.features.join(',') == features.join(',');

  @override
  int get hashCode =>
      Object.hash(app, locale, versions.join(','), surfaces.join(','), components.join(','), features.join(','));
}

/// Where a tap or a subscription belongs (§3.1): ids only.
class DshGoScope {
  const DshGoScope({this.sessionId, this.turnId, this.messageId, this.callId});

  static const none = DshGoScope();

  final String? sessionId;
  final String? turnId;
  final String? messageId;
  final String? callId;

  /// Normalised: empty values dropped, keys in name order.
  Map<String, String> toJson() => {
    if (callId case final v? when v.isNotEmpty) 'callId': v,
    if (messageId case final v? when v.isNotEmpty) 'messageId': v,
    if (sessionId case final v? when v.isNotEmpty) 'sessionId': v,
    if (turnId case final v? when v.isNotEmpty) 'turnId': v,
  };

  @override
  bool operator ==(Object other) =>
      other is DshGoScope &&
      other.sessionId == sessionId &&
      other.turnId == turnId &&
      other.messageId == messageId &&
      other.callId == callId;

  @override
  int get hashCode => Object.hash(sessionId, turnId, messageId, callId);

  @override
  String toString() => 'DshGoScope(${jsonEncode(toJson())})';
}

// -----------------------------------------------------------------------------
// Contributions
// -----------------------------------------------------------------------------

/// A problem the bridge found (§3.3): `path` is a JSON Pointer from the
/// plugin's `package.json` root (`/runtime/<id>` for runtime problems).
class DshGoIssue {
  const DshGoIssue({required this.path, required this.code, this.severity = 'warn', this.message = '', this.count});

  static DshGoIssue? fromJson(Object? json) {
    final map = asMap(json);
    final code = asString(map?['code']);
    if (map == null || code == null || code.isEmpty) return null;
    return DshGoIssue(
      path: asString(map['path']) ?? '',
      code: code,
      severity: asString(map['severity']) ?? 'warn',
      message: asString(map['message']) ?? '',
      count: asInt(map['count']),
    );
  }

  final String path;

  /// `too-long`, `no-handler`, `violation` … (§3.3).
  final String code;

  /// `error` (dropped) or `warn` (kept).
  final String severity;

  /// For developers, in English; the app shows its own text for [code].
  final String message;

  /// Violations so far (`violation`).
  final int? count;

  bool get isError => severity == 'error';

  @override
  bool operator ==(Object other) =>
      other is DshGoIssue && other.path == path && other.code == code && other.severity == severity;

  @override
  int get hashCode => Object.hash(path, code, severity);

  @override
  String toString() => '$path $code';
}

List<JsonMap> _effects(Object? value) => [
  if (asMap(value) case final one?) one else for (final item in asListOrEmpty(value)) ?asMap(item),
];

/// A button a plugin adds (`composer.actions`, `message.actions`).
class DshGoAction {
  const DshGoAction({
    required this.id,
    required this.label,
    this.icon,
    this.effects = const [],
    this.ready = true,
    this.requires = const [],
  });

  static DshGoAction? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    final label = asString(map?['label']);
    if (map == null || id == null || id.isEmpty || label == null || label.isEmpty) return null;
    return DshGoAction(
      id: id,
      label: label,
      icon: asString(map['icon']),
      effects: _effects(map['effect']),
      ready: asBool(map['ready']) ?? true,
      requires: asStringList(map['requires']),
    );
  }

  final String id;
  final String label;
  final String? icon;

  /// Static effects: the app runs these itself and never invokes.
  final List<JsonMap> effects;

  /// v1.2: capabilities the app must support for this button to show.
  final List<String> requires;

  /// Has a static effect or a handler on the Host.
  final bool ready;
}

/// A status line above the composer (`composer.strip`).
class DshGoStrip {
  const DshGoStrip({
    required this.id,
    this.icon,
    this.text,
    this.panel,
    this.ready = true,
    this.tappable = false,
    this.live = false,
  });

  static DshGoStrip? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    final panel = asString(map['panel']);
    return DshGoStrip(
      id: id,
      icon: asString(map['icon']),
      text: asString(map['text']),
      panel: panel,
      ready: asBool(map['ready']) ?? true,
      tappable: asBool(map['tappable']) ?? panel != null,
      live: asBool(map['live']) ?? false,
    );
  }

  final String id;
  final String? icon;

  /// Shown until the plugin pushes data.
  final String? text;

  /// The plugin's panel a tap opens.
  final String? panel;
  final bool ready;

  /// A tap does something (opens [panel], or invokes).
  final bool tappable;

  /// The plugin pushes data: subscribe.
  final bool live;
}

/// A native panel (`panels`).
class DshGoPanel {
  const DshGoPanel({
    required this.id,
    required this.title,
    this.icon,
    this.placement = const [sessionTab],
    this.ready = true,
    this.live = false,
    this.micro,
    this.presentation = page,
  });

  static DshGoPanel? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    final placement = map['placement'];
    return DshGoPanel(
      id: id,
      title: asString(map['title']) ?? id,
      icon: asString(map['icon']),
      placement: placement == null
          ? const [sessionTab]
          : placement is String
          ? [placement]
          : asStringList(placement),
      ready: asBool(map['ready']) ?? true,
      live: asBool(map['live']) ?? false,
      micro: asString(map['micro']),
      presentation: asString(map['presentation']) == sheet ? sheet : page,
    );
  }

  static const sessionTab = 'session.tab';
  static const features = 'features';
  static const chatPanel = 'chat.panel';

  /// The plugin's own detail page, under its settings.
  static const pluginPage = 'plugin';

  /// How it opens: a pushed page, or a sheet over what the person was doing.
  static const page = 'page';
  static const sheet = 'sheet';

  final String presentation;

  final String id;
  final String title;
  final String? icon;
  final List<String> placement;
  final bool ready;

  /// The plugin pushes data: subscribe after the view.
  final bool live;

  /// v1.2: the plugin's micro channel shown as one caption line under the view.
  final String? micro;
}

/// One plugin's native part as the bridge read it.
class DshGoPlugin {
  const DshGoPlugin({
    required this.pkg,
    this.version,
    this.title,
    this.icon,
    this.wants = const {},
    this.state = 'ok',
    this.native = true,
    this.composerActions = const [],
    this.messageActions = const [],
    this.strips = const [],
    this.panels = const [],
    this.composerTools = const [],
    this.sessionActions = const [],
    this.turnNotes = const [],
    this.issues = const [],
    this.capabilities = const {},
    this.media = const [],
    this.micro = const [],
    this.overlays = const [],
  });

  static DshGoPlugin? fromJson(Object? json) {
    final map = asMap(json);
    final pkg = asString(map?['pkg']);
    if (map == null || pkg == null || pkg.isEmpty) return null;
    final contributes = asMapOrEmpty(map['contributes']);
    List<T> list<T>(String key, T? Function(Object?) parse) => [
      for (final item in asListOrEmpty(contributes[key])) ?parse(item),
    ];
    final state = asString(map['state']) ?? 'ok';
    return DshGoPlugin(
      pkg: pkg,
      version: asString(map['version']),
      title: asString(map['title']),
      icon: asString(map['icon']),
      wants: asStringList(map['wants']).toSet(),
      state: state,
      native: asBool(map['native']) ?? state == 'ok',
      composerActions: list(DshGoSurfaces.composerActions, DshGoAction.fromJson),
      messageActions: list(DshGoSurfaces.messageActions, DshGoAction.fromJson),
      strips: list(DshGoSurfaces.composerStrip, DshGoStrip.fromJson),
      panels: list(DshGoSurfaces.panels, DshGoPanel.fromJson),
      composerTools: list(DshGoSurfaces.composerTools, DshGoAction.fromJson),
      sessionActions: list(DshGoSurfaces.sessionActions, DshGoAction.fromJson),
      turnNotes: [
        for (final item in asListOrEmpty(contributes[DshGoSurfaces.turnNote]))
          if (asMap(item) case final note? when asBool(note['ready']) ?? false) ?asString(note['id']),
      ],
      issues: [for (final item in asListOrEmpty(map['issues'])) ?DshGoIssue.fromJson(item)],
      capabilities: asStringList(map['capabilities']).where(dshGoFeatures.contains).toSet(),
      media: list('media', dshGoResourceId).take(2).toList(),
      micro: list('micro', dshGoResourceId).take(2).toList(),
      overlays: list('overlays', DshGoOverlay.fromJson).take(2).toList(),
    );
  }

  final String pkg;
  final String? version;

  /// Display name in the app's locale; the package name when null.
  final String? title;
  final String? icon;

  /// `draft`, `clipboard`, `message` (§1.4).
  final Set<String> wants;

  /// `ok`, `degraded`, `unsupported`, `needs-app`, `invalid`.
  final String state;

  /// The ＋ panel's tools, the conversation's actions, and the ready per-turn notes' ids.
  final List<DshGoAction> composerTools;
  final List<DshGoAction> sessionActions;
  final List<String> turnNotes;

  /// [state] is `ok`: the native part shows. Otherwise the contributions are
  /// empty and the app falls back to the web.
  final bool native;
  final List<DshGoAction> composerActions;
  final List<DshGoAction> messageActions;
  final List<DshGoStrip> strips;
  final List<DshGoPanel> panels;
  final List<DshGoIssue> issues;

  /// v1.2 declarations (empty for v1.1 plugins): the capabilities, and the
  /// ids of its media, micro channels and overlays.
  final Set<String> capabilities;
  final List<String> media;
  final List<String> micro;
  final List<DshGoOverlay> overlays;
}

/// The Host's native contributions.
class DshGoContributions {
  const DshGoContributions({
    this.v = dshGoProtocol,
    this.bridge,
    this.rev,
    this.bootRev,
    this.limits = const {},
    this.plugins = const [],
  });

  static DshGoContributions? fromJson(Object? json) {
    final map = asMap(json);
    final plugins = map?['plugins'];
    if (map == null || plugins is! List) return null;
    return DshGoContributions(
      v: asInt(map['v']) ?? dshGoProtocol,
      bridge: asString(map['bridge']),
      rev: asString(map['rev']),
      bootRev: asString(map['bootRev']),
      limits: asMapOrEmpty(map['limits']),
      plugins: [for (final item in plugins) ?DshGoPlugin.fromJson(item)],
    );
  }

  final int v;

  /// The bridge implementation version, for diagnostics rather than protocol comparison.
  final String? bridge;

  /// Content hash: the `ETag`. Unchanged for the same answer.
  final String? rev;
  final String? bootRev;

  /// The limits table (§7), machine-readable.
  final JsonMap limits;
  final List<DshGoPlugin> plugins;
}

// -----------------------------------------------------------------------------
// Views and taps
// -----------------------------------------------------------------------------

/// A panel's view tree, initial data and data revision (§4.2).
class DshGoView {
  const DshGoView({
    required this.pkg,
    required this.id,
    this.title,
    this.view,
    this.data,
    this.rev,
    this.live = false,
    this.issues = const [],
    this.bytes = 0,
  });

  static DshGoView fromJson(Object? json, {required String pkg, required String id, int bytes = 0}) {
    final map = asMapOrEmpty(json);
    return DshGoView(
      pkg: asString(map['pkg']) ?? pkg,
      id: asString(map['id']) ?? id,
      title: asString(map['title']),
      view: map['view'],
      data: map['data'],
      rev: asString(map['rev']),
      live: asBool(map['live']) ?? false,
      issues: [for (final item in asListOrEmpty(map['issues'])) ?DshGoIssue.fromJson(item)],
      bytes: asInt(asMap(map['stats'])?['bytes']) ?? bytes,
    );
  }

  final String pkg;
  final String id;
  final String? title;
  final Object? view;
  final Object? data;

  /// Version of [data]; null while there is none.
  final String? rev;

  /// More data follows on the stream: subscribe with [rev].
  final bool live;
  final List<DshGoIssue> issues;

  /// The view's size (the bridge's count, else the body's).
  final int bytes;
}

/// One tap sent to a plugin (§4.4).
class DshGoInvocation {
  const DshGoInvocation({
    required this.pkg,
    required this.id,
    required this.surface,
    this.action,
    this.value,
    this.scope = DshGoScope.none,
    this.draft,
    this.clipboard,
    this.message,
    this.locale,
    this.stream,
    this.userGesture,
  });

  final String pkg;

  /// The contribution's id (the panel's id for a tap inside a panel).
  final String id;

  /// `composer.actions`, `message.actions`, `composer.strip`, `panel`.
  final String surface;

  /// A panel control's action name.
  final String? action;

  /// A panel control's value (a choice, `{confirmed}`, the button's args).
  final Object? value;
  final DshGoScope scope;

  /// `context.draft` (`wants: draft`, composer taps only).
  final String? draft;

  /// `context.clipboard` (`wants: clipboard`, composer taps only).
  final String? clipboard;

  /// `context.message` (`wants: message`, message-menu taps only).
  final String? message;
  final String? locale;

  /// The stream connection (`welcome.conn`) a deferred result comes back on
  /// (v1.1).
  final String? stream;

  /// v1.3: direct tap/submit only, never throttled changes or callbacks.
  final bool? userGesture;

  Map<String, Object?> toJson() {
    final context = {'draft': ?draft, 'clipboard': ?clipboard, 'message': ?message};
    return {
      'v': dshGoProtocol,
      'pkg': pkg,
      'id': id,
      'surface': surface,
      'action': ?action,
      'value': ?value,
      'scope': scope.toJson(),
      if (context.isNotEmpty) 'context': context,
      'locale': ?locale,
      'stream': ?stream,
      'userGesture': ?userGesture,
    };
  }
}

/// A deferred result (v1.1, §4.7): the plugin will answer on the stream.
class DshGoPending {
  const DshGoPending({required this.id, this.label, this.timeout = const Duration(seconds: 30)});

  static DshGoPending? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    final ms = asInt(map['timeoutMs']) ?? 30000;
    return DshGoPending(
      id: id,
      label: asString(map['label']),
      timeout: Duration(milliseconds: ms.clamp(1000, 60000)),
    );
  }

  final String id;

  /// What the plugin is doing (≤ 16 characters), for the control.
  final String? label;
  final Duration timeout;
}

/// What a tap asks the app to do: effect objects, to be filtered by the
/// app's whitelist — or, from a v1.1 bridge, a [pending] result to wait for.
class DshGoInvokeResult {
  const DshGoInvokeResult({
    this.effects = const [],
    this.issues = const [],
    this.pending,
    this.elapsed = Duration.zero,
  });

  static DshGoInvokeResult fromJson(Object? json, {Duration elapsed = Duration.zero}) {
    final map = asMap(json);
    return DshGoInvokeResult(
      effects: _effects(map?['effects']),
      issues: [for (final item in asListOrEmpty(map?['issues'])) ?DshGoIssue.fromJson(item)],
      pending: DshGoPending.fromJson(map?['pending']),
      elapsed: elapsed,
    );
  }

  final List<JsonMap> effects;

  /// The plugin answers later, on the stream (v1.1).
  final DshGoPending? pending;

  /// Effects the bridge dropped.
  final List<DshGoIssue> issues;

  /// Round trip of the call.
  final Duration elapsed;
}

// -----------------------------------------------------------------------------
// Calls
// -----------------------------------------------------------------------------

extension DshGoApi on DshClient {
  /// The bridge's routes are reachable over this carrier (HTTP, SSH tunnel).
  bool get canReachDshGo => carrier is DshHttpCarrier;

  /// Null means the Host has no negotiation endpoint (legacy/unknown), not
  /// that every bridge route is absent. An empty capabilities set is an
  /// explicit declaration. No result is cached across bridge reloads.
  Future<DshGoBridgeCapabilities?> readDshGoBridgeCapabilities({Duration timeout = const Duration(seconds: 8)}) async {
    final response = await _dshGoConnection(dshGoCapabilitiesPath).get(dshGoCapabilitiesPath, timeout: timeout);
    if (response.statusCode == 404) {
      final code = asString(_dshGoErrorBody(response)?['code']);
      if (code == null || code == 'route-not-found') return null;
    }
    if (response.statusCode != 200) throw _dshGoHttpError(dshGoCapabilitiesPath, response);
    final body = asMap(tryDecodeJson(response.text));
    final version = _dshGoVersion(dshGoCapabilitiesPath, body?['v']);
    final bridge = asString(body?['bridge']);
    final capabilities = asList(body?['capabilities']);
    if (bridge == null || capabilities == null || capabilities.any((value) => value is! String)) {
      throw const DshProtocolException('$dshGoCapabilitiesPath: not a capabilities object');
    }
    return DshGoBridgeCapabilities(
      v: version,
      bridge: bridge,
      capabilities: Set<String>.unmodifiable(capabilities.cast<String>()),
    );
  }

  /// `GET /dsh-go/v1/contributions`. Null for an explicitly missing route or
  /// a legacy 404 with no advertised native-ui capability. Resource errors
  /// propagate. Only an ambiguous 404 triggers negotiation; a successful read
  /// does not add a round trip. With [previous] from an earlier successful read, asks
  /// `If-None-Match` and returns [previous] itself when nothing changed (304).
  Future<DshGoContributions?> readDshGoContributions({
    DshGoCaps caps = const DshGoCaps(),
    DshGoContributions? previous,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final rev = previous?.rev;
    final response = await _dshGoConnection(dshGoContributionsPath).get(
      dshGoContributionsPath,
      query: caps.query,
      headers: rev == null ? null : {'if-none-match': '"$rev"'},
      timeout: timeout,
    );
    if (response.statusCode == 304 && previous != null) return previous;
    if (response.statusCode == 404) {
      final code = asString(_dshGoErrorBody(response)?['code']);
      if (code == 'route-not-found') return null;
      if (code == null) {
        final bridge = await readDshGoBridgeCapabilities(timeout: timeout);
        if (bridge == null || !bridge.capabilities.contains('native-ui')) return null;
      }
    }
    if (response.statusCode != 200) throw _dshGoHttpError(dshGoContributionsPath, response);
    final body = tryDecodeJson(response.text);
    _dshGoVersion(dshGoContributionsPath, asMap(body)?['v']);
    final contributions = DshGoContributions.fromJson(body);
    if (contributions == null) {
      throw const DshProtocolException('$dshGoContributionsPath: not a contributions object');
    }
    return contributions;
  }

  /// `GET /dsh-go/v1/views/<pkg>/<id>`: a panel's view and initial data.
  Future<DshGoView> readDshGoView(
    String pkg,
    String id, {
    DshGoScope scope = DshGoScope.none,
    DshGoCaps caps = const DshGoCaps(),
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final path = dshGoViewPath(pkg, id);
    final response = await _dshGoConnection(
      path,
    ).get(path, query: {...caps.query, ...scope.toJson()}, timeout: timeout);
    if (response.statusCode != 200) throw _dshGoHttpError(path, response);
    final json = tryDecodeJson(response.text);
    if (asMap(json) == null) throw DshProtocolException('$path: not a view object');
    return DshGoView.fromJson(json, pkg: pkg, id: id, bytes: response.body.length);
  }

  /// `POST /dsh-go/v1/invoke`. Throws [DshRemoteException] with the bridge's
  /// code (`dsh-go/timeout`, `dsh-go/no-handler` …) when it refuses.
  Future<DshGoInvokeResult> invokeDshGo(
    DshGoInvocation invocation, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final watch = Stopwatch()..start();
    final response = await _dshGoConnection(
      dshGoInvokePath,
    ).postJson(dshGoInvokePath, invocation.toJson(), timeout: timeout);
    watch.stop();
    if (response.statusCode != 200) throw _dshGoHttpError(dshGoInvokePath, response);
    final json = tryDecodeJson(response.text);
    if (json != null && asMap(json) == null) throw const DshProtocolException('$dshGoInvokePath: not an object');
    return DshGoInvokeResult.fromJson(json, elapsed: watch.elapsed);
  }

  /// v1.3 selected-file snapshot. Reuses this Host's authenticated HTTP
  /// carrier (including an SSH tunnel), with no redirects and a bounded reply.
  Future<void> uploadDshGoPickedFile(
    String request,
    Uint8List bytes, {
    required String stream,
    required String name,
    String mediaType = 'application/octet-stream',
  }) async {
    final path = _pickedFilePath(request, 'upload');
    if (bytes.length > 8 * 1024 * 1024) throw ArgumentError('picked file exceeds 8 MiB');
    final response = await _dshGoConnection(path).postBytes(
      path,
      bytes,
      query: {'stream': stream, 'name': name, 'mediaType': mediaType},
      followRedirects: false,
      maxResponseBytes: 4096,
      timeout: const Duration(seconds: 30),
    );
    if (response.statusCode != 200) throw _dshGoHttpError(path, response);
    final body = asMap(tryDecodeJson(response.text));
    if (body?['v'] != 1 || asMap(body?['file']) == null) throw DshProtocolException('$path: invalid file receipt');
  }

  /// Completes once; handles belong to the bridge and are never accepted
  /// from the client as callback arguments. The reply only carries data/toast effects.
  Future<DshGoInvokeResult> completeDshGoFileSelection(
    String request, {
    required String stream,
    required String status,
  }) async {
    if (!{'selected', 'cancelled', 'error'}.contains(status)) throw ArgumentError.value(status, 'status');
    final path = _pickedFilePath(request, 'complete');
    final watch = Stopwatch()..start();
    final response = await _dshGoConnection(path).postBytes(
      path,
      utf8.encode(jsonEncode({'status': status})),
      query: {'stream': stream},
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: 96 * 1024,
      timeout: const Duration(seconds: 8),
    );
    watch.stop();
    if (response.statusCode != 200) throw _dshGoHttpError(path, response);
    final json = tryDecodeJson(response.text);
    if (asMap(json) == null) throw DshProtocolException('$path: invalid callback response');
    return DshGoInvokeResult.fromJson(json, elapsed: watch.elapsed);
  }

  /// The stream of this Host (not connected until something subscribes).
  /// [locale] goes in `hello`: the same one the view reads use, so a
  /// subscription joins the data source a view read started.
  /// [features] (v1.2) go in `hello` too; the bridge answers with the ones
  /// it shares ([DshGoStream.negotiatedFeatures]).
  DshGoStream openDshGoStream({String? locale, List<String> features = const []}) {
    final connection = _dshGoConnection(dshGoStreamPath);
    return DshGoStream(
      () async => DshGoSocket.io(await connection.connectWebSocket(dshGoStreamPath)),
      locale: locale,
      features: features,
    );
  }

  /// v1.2 `GET /dsh-go/v1/media/<pkg>/<id>?lease=…&key=…`: a finite audio
  /// clip the plugin made on the Host, read whole with a byte cap, no
  /// redirects and one deadline ([DshConnection.getBounded]). Throws
  /// [DshRemoteException] (`dsh-go/<code>`) for an error answer and
  /// [DshProtocolException] for anything but a supported audio type.
  Future<DshGoMedia> readDshGoMedia(
    String pkg,
    String id, {
    required String lease,
    String? key,
    int maxBytes = dshGoMediaMaxBytes,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    if (!dshGoValidId(id) || lease.isEmpty || lease.length > 256) {
      throw ArgumentError('invalid media reference');
    }
    String segments(String s) => s.split('/').map((p) => Uri.encodeComponent(p).replaceAll('%40', '@')).join('/');
    final path = '/dsh-go/v1/media/${segments(pkg)}/${Uri.encodeComponent(id)}';
    final response = await _dshGoConnection(
      path,
    ).getBounded(path, query: {'lease': lease, 'key': ?key}, maxBytes: maxBytes, timeout: timeout);
    if (response.statusCode != 200) throw _dshGoHttpError(path, response);
    final type = response.contentType;
    if (response.body.isEmpty || !dshGoAudioTypes.contains(type)) {
      throw DshProtocolException('$path: not a supported audio clip');
    }
    return DshGoMedia(response.body, type);
  }

  DshConnection _dshGoConnection(String path) {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) {
      throw DshRemoteException('dsh-go/unsupported', 'This connection cannot reach the dsh-go bridge', {'path': path});
    }
    return carrier.connection;
  }
}

/// `/dsh-go/v1/views/<pkg>/<id>`: a scoped package takes two segments
/// (`/views/@acme/usage-meter/usage`).
String dshGoViewPath(String pkg, String id) {
  String segment(String s) => Uri.encodeComponent(s).replaceAll('%40', '@');
  return '$dshGoViewsPath/${pkg.split('/').map(segment).join('/')}/${segment(id)}';
}

int _dshGoVersion(String path, Object? value) {
  final version = asInt(value);
  if (version == null) throw DshProtocolException('$path: missing or invalid protocol version');
  if (version != dshGoProtocol) {
    throw DshRemoteException('dsh-go/unsupported-version', '$path: unsupported protocol version $version', {
      'path': path,
      'v': version,
    });
  }
  return version;
}

Map<String, Object?>? _dshGoErrorBody(DshHttpResponse response) {
  final body = asMap(tryDecodeJson(response.text));
  return asMap(body?['error']) ?? body;
}

DshRemoteException _dshGoHttpError(String path, DshHttpResponse response) {
  final error = _dshGoErrorBody(response);
  final code = asString(error?['code']);
  return DshRemoteException(
    code == null ? 'dsh-go/http-${response.statusCode}' : 'dsh-go/$code',
    asString(error?['message']) ?? '$path: HTTP ${response.statusCode}',
    {'path': path, 'status': response.statusCode},
  );
}

// -----------------------------------------------------------------------------
// Stream
// -----------------------------------------------------------------------------

/// What one subscription sees.
sealed class DshGoEvent {
  const DshGoEvent();
}

/// The whole data model now ([data] may be null: nothing yet), at [rev].
final class DshGoData extends DshGoEvent {
  const DshGoData(this.data, this.rev, {this.bytes = 0});

  final Object? data;
  final String? rev;

  /// Size of the frame that brought it.
  final int bytes;
}

/// The plugin's view changed: read it again (the subscription stays).
final class DshGoStale extends DshGoEvent {
  const DshGoStale();
}

/// The bridge ended the subscription: `not-found` (plugin turned off),
/// `degraded`, `not-native`, `limit`, `error`.
final class DshGoEnded extends DshGoEvent {
  const DshGoEnded(this.reason, {this.code});

  final String reason;
  final String? code;
}

/// How a deferred result ended (v1.1).
sealed class DshGoOutcome {
  const DshGoOutcome();
}

/// The plugin's effects (only `insert`, `copy`, `toast`, `patch`).
final class DshGoDone extends DshGoOutcome {
  const DshGoDone(this.effects, {this.issues = const []});

  final List<JsonMap> effects;
  final List<DshGoIssue> issues;
}

/// No result will come: `timeout`, `error`, `cancelled`, or (the app's own)
/// `disconnected`.
final class DshGoVoid extends DshGoOutcome {
  const DshGoVoid(this.reason);

  final String reason;
}

/// The socket under a [DshGoStream] (a `dart:io` WebSocket in the app; a
/// fake in tests).
abstract interface class DshGoSocket {
  factory DshGoSocket.io(WebSocket socket) = _IoSocket;

  /// Text frames (other frames are ignored).
  Stream<Object?> get messages;
  void send(String text);

  /// Closes with [code] (1000: going away on purpose).
  Future<void> close([int? code]);
}

class _IoSocket implements DshGoSocket {
  _IoSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get messages => _socket;

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close([int? code]) => _socket.close(code).catchError((Object _) => null);
}

// -----------------------------------------------------------------------------
// v1.2 capabilities (§11): optional, only with features
// -----------------------------------------------------------------------------

/// The v1.2 capabilities: `audio` (a finite clip the plugin makes on the
/// Host), `voice` (speech activity, detected in the app), `micro` (a small
/// caption channel), `overlay` (one floating caption line).
/// v1.3 adds `files` (a user-selected read-only content snapshot).
const dshGoFeatures = {'audio', 'voice', 'micro', 'overlay', 'files'};

/// Media types a clip may have.
const dshGoAudioTypes = {'audio/mpeg', 'audio/wav', 'audio/ogg', 'audio/mp4', 'audio/aac'};

/// The largest clip (16 MiB).
const dshGoMediaMaxBytes = 16 * 1024 * 1024;

/// Upward capability events (`cap.event`).
const dshGoCapabilityEvents = {
  'audio.ended',
  'audio.stopped',
  'audio.error',
  'voice.speechStart',
  'voice.speechEnd',
  'voice.stopped',
  'voice.error',
  'overlay.closed',
};

final _dshGoId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$');

/// A contribution or instance id (§1.1 Id).
bool dshGoValidId(String value) => _dshGoId.hasMatch(value);

/// `{id}` of a media or micro declaration, or null.
String? dshGoResourceId(Object? value) {
  final id = asString(asMap(value)?['id']);
  return id != null && dshGoValidId(id) ? id : null;
}

/// A declared caption overlay: its micro [channel] and/or static [text].
class DshGoOverlay {
  const DshGoOverlay(this.id, {this.channel, this.text});

  static DshGoOverlay? fromJson(Object? value) {
    final map = asMap(value);
    final id = dshGoResourceId(value);
    final channel = asString(map?['channel']);
    final text = asString(map?['text']);
    if (id == null || (channel != null && !dshGoValidId(channel))) return null;
    if (text != null && (text.runes.length > 240 || utf8.encode(text).length > 1024)) return null;
    if (channel == null && text == null) return null;
    return DshGoOverlay(id, channel: channel, text: text);
  }

  final String id;
  final String? channel;
  final String? text;

  @override
  bool operator ==(Object other) =>
      other is DshGoOverlay && other.id == id && other.channel == channel && other.text == text;

  @override
  int get hashCode => Object.hash(id, channel, text);
}

/// A clip read from the media route.
class DshGoMedia {
  const DshGoMedia(this.bytes, this.contentType);

  final Uint8List bytes;
  final String contentType;
}

/// A micro value checked: the complete small model `{text?, progress?}`
/// (text ≤ 240 code points, progress 0..1 or null, ≤ 1 KiB), or null.
JsonMap? dshGoMicroData(Object? value) {
  final map = asMap(value);
  if (map == null || map.isEmpty || map.keys.any((k) => k != 'text' && k != 'progress')) return null;
  final text = map['text'];
  if (map.containsKey('text') && (text is! String || text.runes.length > 240)) return null;
  final progress = map['progress'];
  if (progress != null && (progress is! num || !progress.isFinite || progress < 0 || progress > 1)) return null;
  if (utf8.encode(jsonEncode(map)).length > 1024) return null;
  return Map.unmodifiable(map);
}

final _microRev = RegExp(r'^([0-9a-f]{16})\.([1-9][0-9]{0,15})$');

/// One micro subscription: newest value only, at most 10 a second, never a
/// queue. Its revisions are `<epoch>.<seq>`; a lower seq or another epoch on
/// the same subscription is stale.
class _MicroSubscription {
  _MicroSubscription(this.sid, this.pkg, this.id, this.scope, this.controller);

  final String sid;
  final String pkg;
  final String id;
  final DshGoScope scope;
  final StreamController<DshGoEvent> controller;

  /// The socket epoch the `micro.sub` went out on (-1: not sent).
  int sentEpoch = -1;
  String? _epoch;
  int _seq = 0;
  String? _delivered;
  DateTime? _last;
  DshGoData? _pending;
  Timer? _timer;

  void reset() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _epoch = null;
    _seq = 0;
    _delivered = null;
    _last = null;
    sentEpoch = -1;
  }

  void accept(DshGoData event) {
    final match = _microRev.firstMatch(event.rev ?? '');
    final seq = match == null ? null : int.tryParse(match.group(2)!);
    if (match == null || seq == null || seq > 9007199254740991) return;
    if ((_epoch != null && _epoch != match.group(1)) || seq <= _seq) return;
    _epoch = match.group(1);
    _seq = seq;
    _pending = event;
    final last = _last;
    final wait = last == null ? Duration.zero : const Duration(milliseconds: 100) - DateTime.now().difference(last);
    if (wait <= Duration.zero) {
      _flush();
    } else {
      _timer ??= Timer(wait, _flush);
    }
  }

  void _flush() {
    _timer = null;
    final event = _pending;
    _pending = null;
    if (event == null || controller.isClosed) return;
    final encoded = jsonEncode(event.data);
    if (encoded == _delivered) return;
    _delivered = encoded;
    _last = DateTime.now();
    controller.add(event);
  }
}

/// What the connection under a [DshGoStream] is doing.
enum DshGoLink { idle, connecting, open, backoff, background, closed }

/// The Host's news: contributions changed (a plugin turned on or off).
class DshGoChanged {
  const DshGoChanged();
}

class _Subscription {
  _Subscription(this.sid, this.pkg, this.id, this.scope, this.controller, {this.data, this.rev});

  final String sid;
  final String pkg;
  final String id;
  final DshGoScope scope;
  final StreamController<DshGoEvent> controller;

  /// The data model as last delivered, and its version.
  Object? data;
  String? rev;

  Map<String, Object?> get message => {
    't': 'sub',
    'sub': sid,
    'pkg': pkg,
    'id': id,
    if (scope.toJson().isNotEmpty) 'scope': scope.toJson(),
    'rev': ?rev,
  };
}

/// One WebSocket to the Host's `/dsh-go/v1/stream` (§4.3), subscriptions
/// multiplexed by `sub`.
///
/// - Connects (`hello`) on the first subscription; closes when the last one
///   is cancelled.
/// - [background]: the socket closes (1000) after [backgroundGrace] (60 s)
///   unless [foreground] comes first. [foreground] reconnects and subscribes
///   again with each subscription's `rev`: the bridge answers `sync` or a
///   whole `data`, which is the catch-up.
/// - A dropped or silent socket (no frame for [silence], 60 s) reconnects
///   with backoff 1, 2, 4, 8, 16, 30 … s while anything is subscribed.
/// - A `patch` on a base the app doesn't hold re-sends `sub` with the app's
///   `rev`, which brings the whole data.
class DshGoStream {
  DshGoStream(
    this._connect, {
    this.locale,
    this.features = const [],
    this.backgroundGrace = const Duration(seconds: 60),
    this.silence = const Duration(seconds: 60),
    Duration Function(int attempt)? backoff,
  }) : _backoff = backoff ?? _defaultBackoff;

  final Future<DshGoSocket> Function() _connect;

  /// Sent in `hello` (BCP 47); the plugin's data speaks it.
  final String? locale;

  /// v1.2 features offered in `hello` (empty: a v1.1 `hello`).
  final List<String> features;

  /// What `welcome` agreed to of [features]; empty without a socket.
  Set<String> negotiatedFeatures = const {};
  final Duration backgroundGrace;
  final Duration silence;
  final Duration Function(int attempt) _backoff;

  static Duration _defaultBackoff(int attempt) => Duration(seconds: attempt >= 5 ? 30 : 1 << attempt);

  final _subs = <String, _Subscription>{};
  final _microSubs = <String, _MicroSubscription>{};
  final _changes = StreamController<DshGoChanged>.broadcast();
  final _links = StreamController<DshGoLink>.broadcast();
  DshGoSocket? _socket;
  StreamSubscription<Object?>? _socketSub;
  Timer? _graceTimer;
  Timer? _retryTimer;
  Timer? _silenceTimer;
  Timer? _probeTimer;
  int _attempt = 0;
  int _nextSid = 0;
  int _epoch = 0;
  bool _inBackground = false;
  bool _closed = false;
  bool _welcomed = false;
  DshGoLink _link = DshGoLink.idle;

  /// The bridge's version from `welcome`.
  String? bridge;

  /// This connection's id from `welcome` (bridge ≥ 0.3.0): what an invoke
  /// names to get a deferred result back. Null before `welcome`, after a
  /// drop, and on older bridges.
  String? conn;

  /// Taps waiting on the socket (deferred results, or a connection for an
  /// invoke): the socket stays while there are any.
  int _holds = 0;
  final _welcome = <Completer<String?>>[];
  final _pendings = <String, Completer<DshGoOutcome>>{};

  /// Results that came before their invoke's answer (kept 5 s, §4.7 乱序).
  final _early = <String, (DshGoOutcome, DateTime)>{};

  DshGoLink get link => _link;
  Stream<DshGoLink> get links => _links.stream;

  /// Contributions changed on the Host (`changed`).
  Stream<DshGoChanged> get changes => _changes.stream;

  int get subscriptionCount => _subs.length;

  /// Data of one panel or strip (`{pkg, id, scope}`). [rev] and [data] are
  /// what the app already holds (from a view read): the bridge answers
  /// `sync` when they are current. Cancelling unsubscribes.
  Stream<DshGoEvent> subscribe({
    required String pkg,
    required String id,
    DshGoScope scope = DshGoScope.none,
    String? rev,
    Object? data,
  }) {
    if (_closed) return const Stream.empty();
    final sid = 's${++_nextSid}';
    late final StreamController<DshGoEvent> controller;
    controller = StreamController<DshGoEvent>(
      onListen: () {
        final sub = _Subscription(sid, pkg, id, scope, controller, data: data, rev: rev);
        _subs[sid] = sub;
        if (_link == DshGoLink.open) {
          _send(sub.message);
        } else {
          _ensureConnected();
        }
      },
      onCancel: () {
        if (_subs.remove(sid) == null) return;
        if (_link == DshGoLink.open) _send({'t': 'unsub', 'sub': sid});
        if (_subs.isEmpty && _holds == 0) _disconnect(DshGoLink.idle);
      },
    );
    return controller.stream;
  }

  /// v1.2: one micro channel (`{pkg, id, scope}`), a stream of [DshGoData]
  /// with the small model, ending with [DshGoEnded]. Independent of
  /// [subscribe]: it never touches a panel's data. Holds the socket while
  /// listened to; at most 8 per connection and 2 per plugin.
  Stream<DshGoEvent> subscribeMicro({required String pkg, required String id, DshGoScope scope = DshGoScope.none}) {
    if (_closed || !features.contains('micro') || !dshGoValidId(id)) {
      return Stream.value(const DshGoEnded('unsupported'));
    }
    final sid = 'm${++_nextSid}';
    late final StreamController<DshGoEvent> controller;
    controller = StreamController<DshGoEvent>(
      onListen: () {
        if (_microSubs.length >= 8 || _microSubs.values.where((s) => s.pkg == pkg).length >= 2) {
          controller.add(const DshGoEnded('limit'));
          unawaited(controller.close());
          return;
        }
        final sub = _MicroSubscription(sid, pkg, id, scope, controller);
        _microSubs[sid] = sub;
        unawaited(
          hold().then((_) {
            if (_microSubs[sid] == sub) _sendMicro(sub);
          }),
        );
      },
      onCancel: () {
        final sub = _microSubs.remove(sid);
        if (sub == null) return;
        sub.reset();
        if (_link == DshGoLink.open) _send({'t': 'micro.unsub', 'sub': sid});
        release();
      },
    );
    return controller.stream;
  }

  void _sendMicro(_MicroSubscription sub) {
    if (conn == null || sub.sentEpoch == _epoch) return;
    if (!negotiatedFeatures.contains('micro')) {
      _endMicro(sub, const DshGoEnded('unsupported'));
      return;
    }
    sub.sentEpoch = _epoch;
    _send({
      't': 'micro.sub',
      'sub': sub.sid,
      'pkg': sub.pkg,
      'id': sub.id,
      if (sub.scope.toJson().isNotEmpty) 'scope': sub.scope.toJson(),
    });
  }

  void _endMicro(_MicroSubscription sub, DshGoEnded event) {
    if (_microSubs.remove(sub.sid) == null) return;
    sub.reset();
    if (!sub.controller.isClosed) sub.controller.add(event);
    unawaited(sub.controller.close());
    release();
  }

  void _onMicro(JsonMap map, int bytes) {
    if (bytes > 4096 || !negotiatedFeatures.contains('micro')) return;
    final sub = _microSubs[asString(map['sub'])];
    if (sub == null || sub.sentEpoch != _epoch) return;
    if (map['t'] == 'micro.end') {
      _endMicro(sub, DshGoEnded(asString(map['reason']) ?? 'error'));
      return;
    }
    final data = dshGoMicroData(map['data']);
    final rev = asString(map['rev']);
    if (data == null || rev == null) return;
    sub.accept(DshGoData(data, rev, bytes: bytes));
  }

  /// v1.2: tells the plugin what happened to a capability lease (`cap.event`).
  /// False when there is no socket or the event is not one this connection
  /// negotiated; nothing is queued for a later socket.
  bool capabilityEvent(String lease, int seq, String event, {String? reason}) {
    if (_link != DshGoLink.open ||
        conn == null ||
        lease.isEmpty ||
        lease.length > 256 ||
        seq < 1 ||
        !dshGoCapabilityEvents.contains(event) ||
        !negotiatedFeatures.contains(event.split('.').first)) {
      return false;
    }
    final short = reason == null ? null : String.fromCharCodes(reason.runes.take(120));
    _send({'t': 'cap.event', 'lease': lease, 'seq': seq, 'event': event, 'reason': ?short});
    return true;
  }

  /// Holds the socket open and returns its connection id once `welcome`
  /// says it (null: no connection within [timeout], or an older bridge).
  /// Every call needs a [release].
  Future<String?> hold({Duration timeout = const Duration(seconds: 2)}) {
    if (_closed) return Future.value();
    _holds++;
    if (_link == DshGoLink.open && conn != null) return Future.value(conn);
    final waiter = Completer<String?>();
    _welcome.add(waiter);
    _ensureConnected();
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        _welcome.remove(waiter);
        return null;
      },
    );
  }

  /// Lets go of a [hold].
  void release() {
    if (_holds == 0) return;
    _holds--;
    if (_holds == 0 && _subs.isEmpty && !_closed) _disconnect(DshGoLink.idle);
  }

  /// Waits for deferred result [id] (from an invoke's `pending`): `done`,
  /// `void`, `disconnected` when the socket drops (the bridge voids it too,
  /// and never re-sends), or `timeout` after [timeout].
  Future<DshGoOutcome> outcome(String id, {required Duration timeout}) {
    final early = _early.remove(id);
    if (early != null) return Future.value(early.$1);
    final completer = _pendings[id] ??= Completer<DshGoOutcome>();
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendings.remove(id);
        return const DshGoVoid('timeout');
      },
    );
  }

  /// Asks the bridge to drop deferred result [id] (`void cancelled` follows).
  void cancel(String id) {
    if (_link == DshGoLink.open) _send({'t': 'cancel', 'pending': id});
  }

  void _settle(String id, DshGoOutcome outcome) {
    final waiter = _pendings.remove(id);
    if (waiter != null) {
      if (!waiter.isCompleted) waiter.complete(outcome);
      return;
    }
    final now = DateTime.now();
    _early.removeWhere((_, v) => now.difference(v.$2) > const Duration(seconds: 5));
    _early[id] = (outcome, now);
  }

  /// The socket went: every result it was to bring is void.
  void _voidAll() {
    conn = null;
    _welcomed = false;
    negotiatedFeatures = const {};
    for (final sub in _microSubs.values) {
      sub.reset();
    }
    final waiting = [..._pendings.values];
    _pendings.clear();
    _early.clear();
    for (final w in waiting) {
      if (!w.isCompleted) w.complete(const DshGoVoid('disconnected'));
    }
  }

  /// The app went to the background: drop the socket after [backgroundGrace].
  void background() {
    if (_closed || _inBackground) return;
    _inBackground = true;
    _backgroundAt = DateTime.now();
    _scheduleBackgroundClose();
  }

  DateTime? _backgroundAt;
  DateTime? _systemSelectionUntil;

  /// The system chooser covers the app. Keep only this connection alive for
  /// its bounded selection, without resetting ordinary background lifetimes.
  /// The caller must release it in finally; the five-minute ceiling also works
  /// if the chooser or caller never returns.
  void Function() holdSystemSelection({Duration timeout = const Duration(minutes: 5)}) {
    final bounded = timeout > const Duration(minutes: 5) ? const Duration(minutes: 5) : timeout;
    final deadline = DateTime.now().add(bounded);
    if (_systemSelectionUntil != null || _closed) return () {};
    _systemSelectionUntil = deadline;
    if (_inBackground) _scheduleBackgroundClose();
    return () {
      if (_systemSelectionUntil != deadline) return;
      _systemSelectionUntil = null;
      if (_inBackground) _scheduleBackgroundClose();
    };
  }

  void _scheduleBackgroundClose() {
    _graceTimer?.cancel();
    if (_closed || !_inBackground || _backgroundAt == null) return;
    var deadline = _backgroundAt!.add(backgroundGrace);
    if (_systemSelectionUntil case final until? when until.isAfter(deadline)) deadline = until;
    final remaining = deadline.difference(DateTime.now());
    _graceTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _graceTimer = null;
      if (_inBackground) _disconnect(DshGoLink.background);
    });
  }

  /// Back in the foreground: reconnect (and so catch up) if the socket went.
  void foreground() {
    if (_closed) return;
    _inBackground = false;
    _backgroundAt = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    if (_subs.isEmpty && _holds == 0) {
      if (_link == DshGoLink.background) _setLink(DshGoLink.idle);
    } else if (_link != DshGoLink.open && _link != DshGoLink.connecting) {
      _retryTimer?.cancel();
      _attempt = 0;
      _setLink(DshGoLink.idle);
      _ensureConnected();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _graceTimer?.cancel();
    _retryTimer?.cancel();
    for (final sub in _microSubs.values.toList()) {
      sub.reset();
      unawaited(sub.controller.close());
    }
    _microSubs.clear();
    final subs = [..._subs.values];
    _subs.clear();
    _disconnect(DshGoLink.closed);
    for (final w in _welcome) {
      if (!w.isCompleted) w.complete(null);
    }
    _welcome.clear();
    for (final sub in subs) {
      await sub.controller.close();
    }
    await _changes.close();
    await _links.close();
  }

  void _setLink(DshGoLink link) {
    if (_link == link) return;
    _link = link;
    if (!_links.isClosed) _links.add(link);
  }

  void _ensureConnected() {
    if (_closed || _inBackground && _graceTimer == null) return;
    if (_link == DshGoLink.open || _link == DshGoLink.connecting) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setLink(DshGoLink.connecting);
    final epoch = ++_epoch;
    _connect().then(
      (socket) {
        if (epoch != _epoch || _closed || _subs.isEmpty && _holds == 0) {
          unawaited(socket.close(1000));
          if (epoch == _epoch && !_closed) _setLink(DshGoLink.idle);
          return;
        }
        _socket = socket;
        _attempt = 0;
        _setLink(DshGoLink.open);
        _socketSub = socket.messages.listen(
          (raw) => _onMessage(raw, epoch),
          onDone: () => _onDropped(epoch),
          onError: (Object _) => _onDropped(epoch),
          cancelOnError: true,
        );
        _send({
          't': 'hello',
          'v': [dshGoProtocol],
          'locale': ?locale,
          if (features.isNotEmpty) 'features': features,
        });
        for (final sub in _subs.values) {
          _send(sub.message);
        }
        _armSilence(epoch);
      },
      onError: (Object _) {
        if (epoch == _epoch) _scheduleRetry();
      },
    );
  }

  void _armSilence(int epoch) {
    _silenceTimer?.cancel();
    _probeTimer?.cancel();
    // dart:io consumes control ping/pong internally. Ask for a text reply
    // without moving the existing deadline or prolonging an unused socket.
    _probeTimer = Timer(silence ~/ 2, () {
      if (epoch != _epoch || _link != DshGoLink.open || !_welcomed || _subs.isEmpty && _holds == 0) return;
      _send({'t': 'ping'});
    });
    _silenceTimer = Timer(silence, () {
      if (epoch != _epoch || _link != DshGoLink.open) return;
      // No text (including a probe reply) arrived within the original window.
      _disconnect(DshGoLink.idle);
      _scheduleRetry();
    });
  }

  void _onDropped(int epoch) {
    if (epoch != _epoch) return;
    _voidAll();
    _silenceTimer?.cancel();
    _probeTimer?.cancel();
    _socketSub = null;
    _socket = null;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed) return;
    if (_subs.isEmpty && _holds == 0) {
      _setLink(DshGoLink.idle);
      return;
    }
    if (_inBackground && _graceTimer == null) {
      _setLink(DshGoLink.background);
      return;
    }
    _setLink(DshGoLink.backoff);
    final delay = _backoff(_attempt++);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_link == DshGoLink.backoff) {
        _setLink(DshGoLink.idle);
        _ensureConnected();
      }
    });
  }

  void _disconnect(DshGoLink to) {
    _epoch++;
    _voidAll();
    _retryTimer?.cancel();
    _retryTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _probeTimer?.cancel();
    _probeTimer = null;
    unawaited(_socketSub?.cancel());
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close(1000));
    _setLink(to);
  }

  void _send(Map<String, Object?> message) {
    try {
      _socket?.send(jsonEncode(message));
    } catch (_) {
      // The drop arrives as onDone.
    }
  }

  void _emit(_Subscription sub, DshGoEvent event) {
    if (!sub.controller.isClosed) sub.controller.add(event);
  }

  void _onMessage(Object? raw, int epoch) {
    if (raw is! String || epoch != _epoch) return;
    _armSilence(epoch);
    final map = asMap(tryDecodeJson(raw));
    if (map == null) return;
    final type = asString(map['t']);
    switch (type) {
      case 'welcome':
        _welcomed = map['v'] == dshGoProtocol;
        bridge = asString(map['bridge']);
        conn = asString(map['conn']);
        negotiatedFeatures = asStringList(map['features']).where(features.contains).toSet();
        for (final sub in _microSubs.values.toList()) {
          _sendMicro(sub);
        }
        final waiting = [..._welcome];
        _welcome.clear();
        for (final w in waiting) {
          if (!w.isCompleted) w.complete(conn);
        }
        return;
      case 'done':
        if (asString(map['pending']) case final id?) {
          _settle(
            id,
            DshGoDone(
              _effects(map['effects']),
              issues: [for (final item in asListOrEmpty(map['issues'])) ?DshGoIssue.fromJson(item)],
            ),
          );
        }
        return;
      case 'void':
        if (asString(map['pending']) case final id?) _settle(id, DshGoVoid(asString(map['reason']) ?? 'error'));
        return;
      case 'changed':
        if (!_changes.isClosed) _changes.add(const DshGoChanged());
        return;
      case 'ping':
        _send({'t': 'pong', 'at': ?map['at']});
        return;
      case 'micro.data' || 'micro.end':
        _onMicro(map, utf8.encode(raw).length);
        return;
      case 'data' || 'patch' || 'sync' || 'stale' || 'end':
        break;
      default:
        // pong, error and anything newer.
        return;
    }
    final sub = _subs[asString(map['sub'])];
    if (sub == null) return;
    switch (type) {
      case 'data':
        sub
          ..data = map['data']
          ..rev = asString(map['rev']);
        _emit(sub, DshGoData(sub.data, sub.rev, bytes: utf8.encode(raw).length));
      case 'patch':
        final base = asString(map['base']);
        if (base == null || base != sub.rev) {
          // Not the version this patch builds on: ask for the whole data.
          _send(sub.message);
          return;
        }
        sub
          ..data = mergePatch(sub.data, map['merge'])
          ..rev = asString(map['rev']);
        _emit(sub, DshGoData(sub.data, sub.rev, bytes: utf8.encode(raw).length));
      case 'stale':
        _emit(sub, const DshGoStale());
      case 'end':
        _subs.remove(sub.sid);
        _emit(sub, DshGoEnded(asString(map['reason']) ?? 'error', code: asString(map['code'])));
        unawaited(sub.controller.close());
        if (_subs.isEmpty && _holds == 0) _disconnect(DshGoLink.idle);
      default:
        // sync: already current, nothing to deliver.
        break;
    }
  }
}

/// RFC 7386 JSON Merge Patch: objects merge key by key, `null` deletes a
/// key, anything else (arrays included) replaces.
Object? mergePatch(Object? target, Object? patch) {
  final p = asMap(patch);
  if (p == null) return patch;
  final out = <String, Object?>{...?asMap(target)};
  for (final MapEntry(:key, :value) in p.entries) {
    if (value == null) {
      out.remove(key);
    } else {
      out[key] = mergePatch(out[key], value);
    }
  }
  return out;
}
