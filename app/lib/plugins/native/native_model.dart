// What the native UI shows of each plugin's native contributions
// (docs/design/native-plugins-protocol.md §1, §4.1), after the app's own
// guards. Pure: the bridge's answer in, the app's view out. The bridge already
// validated and trimmed; the app keeps a second line of limits, drops entries
// that aren't ready, and turns issue codes into its own words.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show immutable, listEquals, setEquals;
import 'package:flutter/widgets.dart' show IconData;

import '../../l10n/l10n.dart';
import 'native_icons.dart';

/// The four places of protocol v1 a plugin can show up in.
enum NativeSurface {
  composerActions(DshGoSurfaces.composerActions, DshGoSurfaces.composerActions),
  messageActions(DshGoSurfaces.messageActions, DshGoSurfaces.messageActions),
  composerStrip(DshGoSurfaces.composerStrip, DshGoSurfaces.composerStrip),
  panel(DshGoSurfaces.panels, DshGoSurfaces.panel),
  composerTools(DshGoSurfaces.composerTools, DshGoSurfaces.composerTools),
  sessionActions(DshGoSurfaces.sessionActions, DshGoSurfaces.sessionActions),
  turnNote(DshGoSurfaces.turnNote, DshGoSurfaces.turnNote);

  const NativeSurface(this.wire, this.invoke);

  /// The `contributes` key (`panels` for panels).
  final String wire;

  /// The invoke `surface` (`panel` for a tap inside a panel).
  final String invoke;

  String get label => switch (this) {
    composerActions => appL10n.plugslotsSurfaceComposerActions,
    messageActions => appL10n.plugslotsSurfaceMessageActions,
    composerStrip => appL10n.plugslotsSurfaceComposerStrip,
    panel => appL10n.plugslotsSurfacePanel,
    composerTools => appL10n.plugslotsSurfaceComposerTools,
    sessionActions => appL10n.plugslotsSurfaceSessionActions,
    turnNote => appL10n.plugslotsSurfaceTurnNote,
  };

  static NativeSurface? byWire(String wire) => values.where((s) => s.wire == wire).firstOrNull;
}

/// One plugin's word on a turn (`turn.note`), in the tone it asked for.
typedef NativeTurnNote = ({String text, String? tone});

/// The notes on one turn. Compares by content, so a push that changes nothing here redraws nothing.
@immutable
class NativeTurnNotes {
  const NativeTurnNotes(this.notes);

  final List<NativeTurnNote> notes;

  String get text => notes.map((note) => note.text).join(' · ');

  @override
  bool operator ==(Object other) => other is NativeTurnNotes && listEquals(other.notes, notes);

  @override
  int get hashCode => Object.hashAll(notes);
}

/// The app's limits (protocol §7; the bridge enforces them first).
abstract final class NativeLimits {
  /// Composer buttons and message-menu items, per plugin.
  static const actionsPerPlugin = 2;

  /// Capsules above the composer, ui.json's included.
  static const capsulesTotal = 8;

  /// A capsule's label.
  static const capsuleLabelMax = 10;

  /// A message-menu item's label.
  static const menuLabelMax = 12;

  /// A panel's title.
  static const panelTitleMax = 16;

  /// A ＋ panel tool's name, under its tile.
  static const toolLabelMax = 8;

  /// ＋ panel tools on the panel, every plugin's.
  static const toolsTotal = 8;

  /// Plugins whose note follows one turn's footnote.
  static const turnNotesShown = 2;

  /// Note plugins one conversation follows. The stream allows 32 subscriptions a connection, and
  /// panels and strips must still get theirs however many note plugins are installed.
  static const turnNoteFeeds = 8;

  /// Panels per plugin.
  static const panelsPerPlugin = 4;

  /// The status line's text.
  static const stripTextMax = 24;

  /// A toast.
  static const toastMax = 40;

  /// Effects run only this soon after the tap.
  static const tapWindow = Duration(seconds: 3);
}

/// Something wrong with a plugin's native part, where it is.
@immutable
class NativeIssue {
  const NativeIssue(this.pointer, this.message, {this.code = '', this.error = false, this.at});

  /// From the bridge: [DshGoIssue.path], its code put in the app's words.
  factory NativeIssue.fromBridge(DshGoIssue issue, {DateTime? at}) => NativeIssue(
    issue.path,
    nativeIssueText(issue.code, count: issue.count),
    code: issue.code,
    error: issue.isError,
    at: at,
  );

  /// JSON Pointer (`/dshGo/contributes/composer.actions/2/label`,
  /// `/runtime/translate`).
  final String pointer;

  /// In the app's language.
  final String message;

  /// The protocol's code (`too-long`); empty for the app's own findings.
  final String code;

  /// The entry or field was dropped (else kept, maybe cut).
  final bool error;

  /// When it happened (runtime problems: taps, data, effects).
  final DateTime? at;

  @override
  bool operator ==(Object other) =>
      other is NativeIssue && other.pointer == pointer && other.message == message && other.code == code;

  @override
  int get hashCode => Object.hash(pointer, message, code);

  @override
  String toString() => pointer.isEmpty ? message : '$pointer：$message';
}

/// The app's words for a protocol issue or error [code] (§3.2, §3.3).
String nativeIssueText(String code, {int? count}) {
  final l10n = appL10n;
  return switch (code) {
    'invalid-manifest' => l10n.plugslotsCodeInvalidManifest,
    'unsupported-version' || 'needs-app' => l10n.plugslotsIssueNewerProtocol,
    'missing-field' => l10n.plugslotsIssueMissing,
    'invalid-field' || 'bad-request' => l10n.plugslotsCodeInvalidField,
    'duplicate-id' => l10n.plugslotsIssueDuplicate,
    'unknown-field' => l10n.plugslotsCodeUnknownField,
    'unknown-surface' => l10n.plugslotsCodeUnknownSurface,
    'too-many' => l10n.plugslotsCodeTooMany,
    'too-long' || 'too-large' => l10n.plugslotsCodeTooLong,
    'no-handler' => l10n.plugslotsCodeNoHandler,
    'undeclared' => l10n.plugslotsCodeUndeclared,
    'view-file' => l10n.plugslotsCodeViewFile,
    'bad-effect' => l10n.plugslotsCodeBadEffect,
    'unknown-effect' => l10n.plugslotsCodeUnknownEffect,
    'violation' => l10n.plugslotsCodeViolation(count ?? 1),
    'degraded' || 'not-native' => l10n.plugslotsCodeDegraded,
    'timeout' => l10n.plugslotsCodeTimeout,
    'rate-limited' => l10n.plugslotsCodeRateLimited,
    'not-found' => l10n.plugslotsCodeNotFound,
    'plugin-error' || 'error' => l10n.plugslotsCodePluginError,
    'invalid-view' => l10n.plugslotsCodeInvalidView,
    'limit' => l10n.plugslotsCodeLimit,
    'too-many-pending' => l10n.plugslotsCodeTooManyPending,
    'no-stream' || 'disconnected' => l10n.plugslotsCodeNoStream,
    _ => l10n.plugslotsCodeOther,
  };
}

/// A button (a capsule above the composer, an item in a message menu).
@immutable
class NativeAction {
  const NativeAction({
    required this.package,
    required this.surface,
    required this.id,
    required this.label,
    this.icon,
    this.effects = const [],
  });

  final String package;
  final NativeSurface surface;
  final String id;
  final String label;

  /// Null: no icon (a capsule) or the generic plugin glyph (a menu item).
  final IconData? icon;

  /// Static effects: the app runs them on a tap and never invokes.
  final List<Map<String, Object?>> effects;

  @override
  bool operator ==(Object other) =>
      other is NativeAction &&
      other.package == package &&
      other.surface == surface &&
      other.id == id &&
      other.label == label &&
      other.icon == icon &&
      listEquals(other.effects.map((e) => '$e').toList(), effects.map((e) => '$e').toList());

  @override
  int get hashCode => Object.hash(package, surface, id, label, icon);
}

/// A status line a plugin keeps above the composer.
@immutable
class NativeStrip {
  const NativeStrip({
    required this.package,
    required this.id,
    this.icon,
    this.text,
    this.panel,
    this.tappable = false,
    this.live = false,
  });

  final String package;
  final String id;

  /// IconName; the plugin's data may name another.
  final String? icon;

  /// Shown until the plugin pushes data.
  final String? text;

  /// The plugin's panel a tap opens.
  final String? panel;

  /// A tap does something: opens [panel], else goes to the plugin.
  final bool tappable;

  /// The plugin pushes data: subscribe.
  final bool live;

  @override
  bool operator ==(Object other) =>
      other is NativeStrip &&
      other.package == package &&
      other.id == id &&
      other.icon == icon &&
      other.text == text &&
      other.panel == panel &&
      other.tappable == tappable &&
      other.live == live;

  @override
  int get hashCode => Object.hash(package, id, icon, text, panel, tappable, live);
}

/// A native panel and where it may appear.
@immutable
class NativePanel {
  const NativePanel({
    required this.package,
    required this.id,
    required this.title,
    this.icon,
    this.placement = const {},
    this.live = false,
    this.micro,
    this.sheet = false,
  });

  final String package;
  final String id;
  final String title;

  /// Opens as a sheet instead of a pushed page.
  final bool sheet;

  /// IconName.
  final String? icon;

  /// [DshGoPanel.sessionTab], [DshGoPanel.features].
  final Set<String> placement;

  /// The plugin pushes data after the view.
  final bool live;

  /// v1.2: the plugin's micro channel drawn as one caption line under the view.
  final String? micro;

  @override
  bool operator ==(Object other) =>
      other is NativePanel &&
      other.package == package &&
      other.id == id &&
      other.title == title &&
      other.icon == icon &&
      other.live == live &&
      other.micro == micro &&
      other.sheet == sheet &&
      setEquals(other.placement, placement);

  @override
  int get hashCode => Object.hash(package, id, title, icon, live, micro, Object.hashAllUnordered(placement));
}

/// One plugin's native part as the app shows it.
@immutable
class NativePlugin {
  const NativePlugin({
    required this.package,
    this.title,
    this.icon,
    this.version,
    this.state = 'ok',
    this.wants = const {},
    this.composerActions = const [],
    this.messageActions = const [],
    this.strips = const [],
    this.panels = const [],
    this.composerTools = const [],
    this.sessionActions = const [],
    this.turnNotes = const [],
    this.issues = const [],
    this.declared = const {},
    this.capabilities = const {},
    this.media = const [],
    this.micro = const [],
    this.overlays = const [],
  });

  final String package;

  /// The plugin's display name (already in the app's language).
  final String? title;

  /// IconName.
  final String? icon;
  final String? version;

  /// `ok`, `degraded`, `unsupported`, `needs-app`, `invalid`.
  final String state;

  /// `draft`, `clipboard`, `message`.
  final Set<String> wants;
  final List<NativeAction> composerActions;
  final List<NativeAction> messageActions;
  final List<NativeStrip> strips;
  final List<NativePanel> panels;
  final List<NativeAction> composerTools;
  final List<NativeAction> sessionActions;

  /// Ids of its per-turn notes.
  final List<String> turnNotes;

  /// The bridge's and the app's findings.
  final List<NativeIssue> issues;

  /// Surfaces it shows something on (the switches in 设置).
  final Set<NativeSurface> declared;

  /// v1.2 capabilities it declares (`audio`, `voice`, `micro`, `overlay`),
  /// and its media, micro channel and overlay declarations. Empty for a
  /// v1.1 plugin, which then never reaches the capability code.
  final Set<String> capabilities;
  final List<String> media;
  final List<String> micro;
  final List<DshGoOverlay> overlays;

  /// The native part shows ([state] is `ok`).
  bool get native => state == 'ok';

  bool get wantsDraft => wants.contains('draft');
  bool get wantsClipboard => wants.contains('clipboard');
  bool get wantsMessage => wants.contains('message');

  bool get isEmpty =>
      composerTools.isEmpty &&
      sessionActions.isEmpty &&
      turnNotes.isEmpty &&
      composerActions.isEmpty &&
      messageActions.isEmpty &&
      strips.isEmpty &&
      panels.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is NativePlugin &&
      other.package == package &&
      other.title == title &&
      other.icon == icon &&
      other.version == version &&
      other.state == state &&
      setEquals(other.wants, wants) &&
      listEquals(other.composerActions, composerActions) &&
      listEquals(other.messageActions, messageActions) &&
      listEquals(other.strips, strips) &&
      listEquals(other.panels, panels) &&
      listEquals(other.composerTools, composerTools) &&
      listEquals(other.sessionActions, sessionActions) &&
      listEquals(other.turnNotes, turnNotes) &&
      listEquals(other.issues, issues) &&
      setEquals(other.declared, declared) &&
      setEquals(other.capabilities, capabilities) &&
      listEquals(other.media, media) &&
      listEquals(other.micro, micro) &&
      listEquals(other.overlays, overlays);

  @override
  int get hashCode => Object.hash(
    package,
    title,
    state,
    Object.hashAll(composerActions),
    Object.hashAll(messageActions),
    Object.hashAll(strips),
    Object.hashAll(panels),
    Object.hashAll(issues),
  );
}

/// Every plugin's native part on one host, in the bridge's order.
@immutable
class NativeContributions {
  const NativeContributions({this.rev, this.plugins = const []});

  static const empty = NativeContributions();

  /// The bridge's content hash.
  final String? rev;
  final List<NativePlugin> plugins;

  NativePlugin? plugin(String package) => plugins.where((p) => p.package == package).firstOrNull;

  bool get isEmpty => plugins.every((p) => p.isEmpty);

  @override
  bool operator ==(Object other) =>
      other is NativeContributions && other.rev == rev && listEquals(other.plugins, plugins);

  @override
  int get hashCode => Object.hash(rev, Object.hashAll(plugins));
}

/// [raw] as the app shows it.
///
/// - A plugin whose state isn't `ok` shows nothing (its issues stay).
/// - Entries that aren't `ready` are left out.
/// - Second line of limits: 2 buttons a plugin, labels 10 / 12, 4 panels,
///   panel titles 16, only the 对话详情 and 全部功能 placements.
/// - v1.2: a button that `requires` a capability shows only when [features]
///   (what this app supports now) has it.
NativeContributions nativeContributionsFrom(DshGoContributions raw, {Set<String> features = const {}}) {
  final seen = <String>{};
  return NativeContributions(
    rev: raw.rev,
    plugins: [
      for (final p in raw.plugins)
        if (seen.add(p.pkg)) _plugin(p, features),
    ],
  );
}

NativePlugin _plugin(DshGoPlugin p, Set<String> features) {
  final issues = [for (final i in p.issues) NativeIssue.fromBridge(i)];
  if (!p.native) {
    return NativePlugin(
      package: p.pkg,
      title: p.title,
      icon: p.icon,
      version: p.version,
      state: p.state == 'ok' ? 'invalid' : p.state,
      issues: issues,
    );
  }

  String cut(String text, int max) {
    final clean = text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').trim();
    final runes = clean.runes.toList();
    return runes.length <= max ? clean : String.fromCharCodes(runes.take(max));
  }

  List<NativeAction> actions(NativeSurface surface, List<DshGoAction> declared, int labelMax) => [
    for (final a
        in declared.where((a) => a.ready && a.requires.every(features.contains)).take(NativeLimits.actionsPerPlugin))
      if (cut(a.label, labelMax) case final label when label.isNotEmpty)
        NativeAction(
          package: p.pkg,
          surface: surface,
          id: a.id,
          label: label,
          icon: nativeIcon(a.icon),
          effects: a.effects,
        ),
  ];

  final strips = [
    for (final s in p.strips.where((s) => s.ready).take(1))
      NativeStrip(
        package: p.pkg,
        id: s.id,
        icon: s.icon,
        text: s.text,
        panel: s.panel,
        tappable: s.tappable || s.panel != null,
        live: s.live,
      ),
  ];

  final panels = [
    for (final panel in p.panels.where((x) => x.ready).take(NativeLimits.panelsPerPlugin))
      if ({
            for (final where in panel.placement)
              if (where == DshGoPanel.sessionTab ||
                  where == DshGoPanel.features ||
                  where == DshGoPanel.chatPanel ||
                  where == DshGoPanel.pluginPage)
                where,
          }
          case final placement when placement.isNotEmpty)
        NativePanel(
          package: p.pkg,
          id: panel.id,
          title: cut(panel.title, NativeLimits.panelTitleMax),
          icon: panel.icon,
          placement: placement,
          live: panel.live,
          micro: p.capabilities.contains('micro') && p.micro.contains(panel.micro) ? panel.micro : null,
          sheet: panel.presentation == DshGoPanel.sheet,
        ),
  ];

  final composer = actions(NativeSurface.composerActions, p.composerActions, NativeLimits.capsuleLabelMax);
  final menu = actions(NativeSurface.messageActions, p.messageActions, NativeLimits.menuLabelMax);
  final tools = actions(NativeSurface.composerTools, p.composerTools, NativeLimits.toolLabelMax);
  final sessionActions = actions(NativeSurface.sessionActions, p.sessionActions, NativeLimits.menuLabelMax);
  final turnNotes = p.turnNotes.take(1).toList();
  return NativePlugin(
    package: p.pkg,
    title: p.title,
    icon: p.icon,
    version: p.version,
    wants: {
      for (final w in p.wants)
        if (w == 'draft' || w == 'clipboard' || w == 'message') w,
    },
    composerActions: List.unmodifiable(composer),
    messageActions: List.unmodifiable(menu),
    strips: List.unmodifiable(strips),
    panels: List.unmodifiable(panels),
    composerTools: List.unmodifiable(tools),
    sessionActions: List.unmodifiable(sessionActions),
    turnNotes: List.unmodifiable(turnNotes),
    issues: List.unmodifiable(issues),
    declared: {
      if (composer.isNotEmpty) NativeSurface.composerActions,
      if (menu.isNotEmpty) NativeSurface.messageActions,
      if (strips.isNotEmpty) NativeSurface.composerStrip,
      if (panels.isNotEmpty) NativeSurface.panel,
      if (tools.isNotEmpty) NativeSurface.composerTools,
      if (sessionActions.isNotEmpty) NativeSurface.sessionActions,
      if (turnNotes.isNotEmpty) NativeSurface.turnNote,
    },
    capabilities: p.capabilities,
    media: p.capabilities.contains('audio') ? p.media : const [],
    micro: p.capabilities.contains('micro') ? p.micro : const [],
    overlays: p.capabilities.contains('overlay') ? p.overlays : const [],
  );
}
