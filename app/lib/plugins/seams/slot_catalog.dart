// The official web client's slots (DSH 0.2.2-rc.1) and what the app does
// with each (docs/design/plugin-seams.md §3). Regenerate the table after a
// DSH upgrade as the spec's appendix A describes; a slot the table does not
// know is planned as [SeatPolicy.other].

import 'package:flutter/foundation.dart';

/// DSH release the table was extracted from.
const slotCatalogRelease = '0.2.2-rc.1';

/// How many occupants a slot holds (`slots.zh.md`, Cardinality).
enum SlotKind { single, list, keyed, chain }

/// What a slot's components receive (`root`: global; `session`: always a
/// conversation; `sessionMaybe`: a conversation when one is open).
enum SlotScope { root, session, sessionMaybe }

/// The three shapes a web island takes (§6.2), plus the hidden probe that
/// refreshes the bridge's occupancy table (§5.2).
enum IslandForm { page, panel, overlay, probe }

/// §3 priority bands.
enum SeatPriority {
  p0,
  p1,
  p2,

  /// Message-level slots: one platform view per message would sink scrolling
  /// and memory, so only an "open in DSH Web" entry.
  message,

  /// A slot §3 does not plan for: an "open in DSH Web" entry at most.
  other,

  /// Replacement points of the app's own UI: no seat at all.
  never,
}

/// How a Tier A host (no occupancy table) can still guess an occupant.
enum SlotInference {
  none,

  /// `plugins.bundle.config`, keyed by the bundle's package name.
  bundleConfig,

  /// `plugins.row.config`, keyed by `<package>#<row id>`.
  rowConfig,
}

/// What the planner may do with a slot's third-party occupants.
@immutable
class SeatPolicy {
  const SeatPolicy({
    required this.priority,
    this.islands = const {},
    this.needsOccupancy = false,
    this.masks = true,
    this.optIn = false,
    this.webLink = true,
    this.inference = SlotInference.none,
  });

  final SeatPriority priority;

  /// Island forms this slot can be shown in.
  final Set<IslandForm> islands;

  /// The island has to hide the official entries of a list slot, which only
  /// the bridge can do in island mode (§6.1): Tier B occupants only.
  final bool needsOccupancy;

  /// With [needsOccupancy]: the island hides the slot's official entries.
  /// Not for a slot DSH Web draws one entry of at a time (a conversation
  /// view): there the occupancy is only how the island finds its entry.
  final bool masks;

  bool get masksOfficial => needsOccupancy && masks;

  /// Islands only when the person (or ui.json) asked for one.
  final bool optIn;

  /// An "open in DSH Web" entry is a meaningful fallback.
  final bool webLink;
  final SlotInference inference;

  bool get seatable => priority != SeatPriority.never;

  static const p0Page = SeatPolicy(priority: SeatPriority.p0, islands: {IslandForm.page});
  static const p0BundleConfig = SeatPolicy(
    priority: SeatPriority.p0,
    islands: {IslandForm.page},
    inference: SlotInference.bundleConfig,
  );
  static const p0RowConfig = SeatPolicy(
    priority: SeatPriority.p0,
    islands: {IslandForm.page},
    inference: SlotInference.rowConfig,
  );

  /// An entry (icon, label) whose page lives in another slot (`main`).
  static const p0Entry = SeatPolicy(priority: SeatPriority.p0);
  static const p1Panel = SeatPolicy(priority: SeatPriority.p1, islands: {IslandForm.panel}, needsOccupancy: true);
  static const p1MaskedPage = SeatPolicy(priority: SeatPriority.p1, islands: {IslandForm.page}, needsOccupancy: true);

  /// A conversation view (docs/design/plugin-ui-v3.md §3.3): a page island,
  /// found by the name the occupancy reports; DSH Web shows one view at a
  /// time, so nothing official is hidden.
  static const p1ViewPage = SeatPolicy(
    priority: SeatPriority.p1,
    islands: {IslandForm.page},
    needsOccupancy: true,
    masks: false,
  );
  static const p2Overlay = SeatPolicy(
    priority: SeatPriority.p2,
    islands: {IslandForm.overlay},
    needsOccupancy: true,
    optIn: true,
  );

  /// Native only (declarative panels): nothing in DSH Web to fall back to.
  static const p2Native = SeatPolicy(priority: SeatPriority.p2, webLink: false);
  static const message = SeatPolicy(priority: SeatPriority.message);
  static const other = SeatPolicy(priority: SeatPriority.other);
  static const never = SeatPolicy(priority: SeatPriority.never, webLink: false);
}

/// One slot of the official client.
@immutable
class SlotInfo {
  const SlotInfo(
    this.key,
    this.kind,
    this.scope, {
    this.replacesShippedUi = false,
    this.policy = SeatPolicy.other,
    this.synthetic = false,
  });

  final String key;
  final SlotKind kind;
  final SlotScope scope;

  /// `replaceRisk: shadows-shipped-ui` in the catalog.
  final bool replacesShippedUi;
  final SeatPolicy policy;

  /// A surface of the app's own (not a DSH slot).
  final bool synthetic;

  bool get seatable => policy.seatable;

  /// Components need a conversation: no seat without a session id.
  bool get needsSession => scope == SlotScope.session;
}

/// Slot keys the app's seats use.
abstract final class Slots {
  static const settingsSection = 'settings.section';
  static const bundleConfig = 'plugins.bundle.config';
  static const rowConfig = 'plugins.row.config';
  static const rightPaneTab = 'sidebar.right.pane.tab';
  static const rightPaneTabTitle = 'sidebar.right.pane.tab.title';
  static const main = 'main';
  static const panelList = 'sidebar.panellist';
  static const cordisView = 'tool.view.cordis';
  static const inputDock = 'conversation.input.dock';
  static const inputLeft = 'conversation.input.left';
  static const inputRight = 'conversation.input.right';
  static const inputOverlay = 'conversation.input.overlay';
  static const composerDock = 'conversation.composer.dock';
  static const headerActions = 'conversation.session.header.actions';
  static const headerUtilities = 'conversation.session.header.utilities';

  /// A plugin's View of a conversation, beside Chat and Trajectory.
  static const conversationView = 'conversation.view';

  /// rc.4's three 「更多」 menus (more conversation views, more panels, more
  /// tools): rows of a web menu, nothing the app can seat.
  static const headerViewsActions = 'conversation.session.header.views.actions';
  static const panelListActions = 'sidebar.panellist.actions';
  static const guideActions = 'sidebar.right.tab.guide.actions';
  static const generalItem = 'settings.general.item';
  static const shellOverlay = 'shell.overlay';
  static const sidebarFooter = 'sidebar.footer.action';
  static const settingsPluginsTab = 'settings.plugins.tab';
  static const pluginDetailSection = 'plugins.detail.section';

  /// Declarative panels (§4.3): the app's own surface, served by the bridge.
  static const dshGoPanel = 'dsh-go.panel';

  /// Where the app has a seat today (docs/design/plugin-ui-v3.md §1.2, A):
  /// a plugin's web part anywhere else is listed under 「网页版界面」 in its
  /// details instead.
  static const seated = {
    settingsSection,
    generalItem,
    bundleConfig,
    rowConfig,
    main,
    panelList,
    rightPaneTab,
    rightPaneTabTitle,
    cordisView,
    dshGoPanel,
    conversationView,
    sidebarFooter,
    settingsPluginsTab,
    pluginDetailSection,
    ...chatPanel,
  };

  /// The chat page's 「插件」 sheet: one panel island of the app's own
  /// showing all of [chatPanel] (docs/design/plugin-ui-v3.md §3.4). Not a
  /// DSH slot: only `recipes.json` knows it.
  static const chatSheet = 'dsh-go.chat';

  /// The slots one chat-page panel island shows stacked (§3).
  static const chatPanel = [
    inputDock,
    inputLeft,
    inputRight,
    inputOverlay,
    composerDock,
    headerActions,
    headerUtilities,
  ];
}

/// The slot, or null for one this table does not know (a newer DSH).
SlotInfo? slotInfo(String key) => slotCatalog[key];

/// The policy for [key]; unknown slots get [SeatPolicy.other].
SeatPolicy seatPolicyOf(String key) => slotCatalog[key]?.policy ?? SeatPolicy.other;

/// Every slot of [slotCatalogRelease] plus the app's own surfaces.
const Map<String, SlotInfo> slotCatalog = {
  'contextMenu.content': SlotInfo('contextMenu.content', SlotKind.keyed, SlotScope.root, replacesShippedUi: true),
  'contextMenu.icon': SlotInfo('contextMenu.icon', SlotKind.keyed, SlotScope.root, replacesShippedUi: true),
  'conversation.approval.detail': SlotInfo(
    'conversation.approval.detail',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.chat.assistant-actions': SlotInfo(
    'conversation.chat.assistant-actions',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.message,
  ),
  'conversation.chat.commandview': SlotInfo('conversation.chat.commandview', SlotKind.keyed, SlotScope.session),
  'conversation.chat.flow': SlotInfo(
    'conversation.chat.flow',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.chat.message.images': SlotInfo(
    'conversation.chat.message.images',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.chat.node': SlotInfo(
    'conversation.chat.node',
    SlotKind.keyed,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.message,
  ),
  'conversation.chat.reasoning.body': SlotInfo(
    'conversation.chat.reasoning.body',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.chat.text-interaction': SlotInfo(
    'conversation.chat.text-interaction',
    SlotKind.keyed,
    SlotScope.session,
    replacesShippedUi: true,
  ),
  'conversation.chat.turnTail': SlotInfo(
    'conversation.chat.turnTail',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.message,
  ),
  'conversation.chat.user.before': SlotInfo('conversation.chat.user.before', SlotKind.chain, SlotScope.session),
  'conversation.chat.user.images': SlotInfo(
    'conversation.chat.user.images',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.composer': SlotInfo('conversation.composer', SlotKind.chain, SlotScope.session),
  'conversation.composer.bar': SlotInfo(
    'conversation.composer.bar',
    SlotKind.single,
    SlotScope.sessionMaybe,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.composer.dock': SlotInfo(
    'conversation.composer.dock',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.header': SlotInfo(
    'conversation.header',
    SlotKind.single,
    SlotScope.sessionMaybe,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.header.leading': SlotInfo('conversation.header.leading', SlotKind.single, SlotScope.root),
  'conversation.hero.agentPreset': SlotInfo(
    'conversation.hero.agentPreset',
    SlotKind.single,
    SlotScope.sessionMaybe,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.hero.brand.mark': SlotInfo('conversation.hero.brand.mark', SlotKind.single, SlotScope.root),
  'conversation.hero.options': SlotInfo('conversation.hero.options', SlotKind.list, SlotScope.session),
  'conversation.hero.workspace': SlotInfo(
    'conversation.hero.workspace',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.hero.workspace.directoryFlow': SlotInfo(
    'conversation.hero.workspace.directoryFlow',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.input.activity': SlotInfo(
    'conversation.input.activity',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.input.attachments': SlotInfo(
    'conversation.input.attachments',
    SlotKind.single,
    SlotScope.sessionMaybe,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.input.dock': SlotInfo(
    'conversation.input.dock',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.input.left': SlotInfo(
    'conversation.input.left',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.input.model': SlotInfo(
    'conversation.input.model',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.input.model.label': SlotInfo(
    'conversation.input.model.label',
    SlotKind.single,
    SlotScope.session,
    policy: SeatPolicy.never,
  ),
  'conversation.input.overlay': SlotInfo(
    'conversation.input.overlay',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.input.permission': SlotInfo(
    'conversation.input.permission',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.input.plan': SlotInfo(
    'conversation.input.plan',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.input.right': SlotInfo(
    'conversation.input.right',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.plan-review.actions': SlotInfo('conversation.plan-review.actions', SlotKind.list, SlotScope.session),
  'conversation.session': SlotInfo(
    'conversation.session',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.session.header': SlotInfo(
    'conversation.session.header',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.session.header.actions': SlotInfo(
    'conversation.session.header.actions',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.session.header.corner': SlotInfo(
    'conversation.session.header.corner',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.session.header.lineage': SlotInfo(
    'conversation.session.header.lineage',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.session.header.utilities': SlotInfo(
    'conversation.session.header.utilities',
    SlotKind.list,
    SlotScope.session,
    policy: SeatPolicy.p1Panel,
  ),
  'conversation.session.header.views.actions': SlotInfo(
    'conversation.session.header.views.actions',
    SlotKind.list,
    SlotScope.root,
  ),
  'conversation.trajectory.images': SlotInfo(
    'conversation.trajectory.images',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'conversation.user.text.node': SlotInfo(
    'conversation.user.text.node',
    SlotKind.keyed,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.message,
  ),
  'conversation.view': SlotInfo('conversation.view', SlotKind.list, SlotScope.session, policy: SeatPolicy.p1ViewPage),
  'deliverables.file.actions': SlotInfo('deliverables.file.actions', SlotKind.list, SlotScope.session),
  'deliverables.review.file.actions': SlotInfo('deliverables.review.file.actions', SlotKind.list, SlotScope.session),
  'main': SlotInfo('main', SlotKind.keyed, SlotScope.root, replacesShippedUi: true, policy: SeatPolicy.p0Page),
  'main.conversation': SlotInfo(
    'main.conversation',
    SlotKind.single,
    SlotScope.sessionMaybe,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'plugins.add.actions': SlotInfo('plugins.add.actions', SlotKind.list, SlotScope.root),
  'plugins.bundle.activation': SlotInfo(
    'plugins.bundle.activation',
    SlotKind.keyed,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'plugins.bundle.config': SlotInfo(
    'plugins.bundle.config',
    SlotKind.keyed,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.p0BundleConfig,
  ),
  'plugins.detail.actions': SlotInfo('plugins.detail.actions', SlotKind.list, SlotScope.root),
  'plugins.detail.badge': SlotInfo('plugins.detail.badge', SlotKind.list, SlotScope.root),
  'plugins.detail.section': SlotInfo(
    'plugins.detail.section',
    SlotKind.list,
    SlotScope.root,
    policy: SeatPolicy.p1MaskedPage,
  ),
  'plugins.item': SlotInfo('plugins.item', SlotKind.list, SlotScope.root),
  'plugins.row.config': SlotInfo('plugins.row.config', SlotKind.keyed, SlotScope.root, policy: SeatPolicy.p0RowConfig),
  'plugins.tab': SlotInfo('plugins.tab', SlotKind.list, SlotScope.root),
  'rightbar': SlotInfo('rightbar', SlotKind.single, SlotScope.root, replacesShippedUi: true, policy: SeatPolicy.never),
  'rightbar.session': SlotInfo(
    'rightbar.session',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'root': SlotInfo('root', SlotKind.single, SlotScope.root, replacesShippedUi: true, policy: SeatPolicy.never),
  'settings.action': SlotInfo('settings.action', SlotKind.list, SlotScope.root),
  'settings.close': SlotInfo(
    'settings.close',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'settings.general.item': SlotInfo(
    'settings.general.item',
    SlotKind.list,
    SlotScope.root,
    policy: SeatPolicy.p1MaskedPage,
  ),
  'settings.header': SlotInfo(
    'settings.header',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'settings.launcher': SlotInfo(
    'settings.launcher',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'settings.models.footer': SlotInfo('settings.models.footer', SlotKind.list, SlotScope.root),
  'settings.models.provider-card': SlotInfo('settings.models.provider-card', SlotKind.keyed, SlotScope.root),
  'settings.models.sign-in': SlotInfo(
    'settings.models.sign-in',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'settings.onboarding': SlotInfo('settings.onboarding', SlotKind.list, SlotScope.root),
  'settings.plugins.tab': SlotInfo(
    'settings.plugins.tab',
    SlotKind.list,
    SlotScope.root,
    policy: SeatPolicy.p1MaskedPage,
  ),
  'settings.section': SlotInfo('settings.section', SlotKind.list, SlotScope.root, policy: SeatPolicy.p0Page),
  'settings.section.icon': SlotInfo('settings.section.icon', SlotKind.list, SlotScope.root),
  'settings.trigger': SlotInfo(
    'settings.trigger',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'shell.bottom': SlotInfo(
    'shell.bottom',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'shell.leading': SlotInfo(
    'shell.leading',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'shell.overlay': SlotInfo('shell.overlay', SlotKind.list, SlotScope.root, policy: SeatPolicy.p2Overlay),
  'shell.quota-notice': SlotInfo('shell.quota-notice', SlotKind.chain, SlotScope.root),
  'sidebar': SlotInfo('sidebar', SlotKind.single, SlotScope.root, replacesShippedUi: true, policy: SeatPolicy.never),
  'sidebar.brand.mark': SlotInfo(
    'sidebar.brand.mark',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.brand.name': SlotInfo(
    'sidebar.brand.name',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.chat.conversation': SlotInfo(
    'sidebar.chat.conversation',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.footer.action': SlotInfo(
    'sidebar.footer.action',
    SlotKind.list,
    SlotScope.root,
    policy: SeatPolicy.p1MaskedPage,
  ),
  'sidebar.panellist': SlotInfo('sidebar.panellist', SlotKind.list, SlotScope.root, policy: SeatPolicy.p0Entry),
  'sidebar.panellist.actions': SlotInfo('sidebar.panellist.actions', SlotKind.list, SlotScope.root),
  'sidebar.right.pane.tab': SlotInfo(
    'sidebar.right.pane.tab',
    SlotKind.keyed,
    SlotScope.session,
    policy: SeatPolicy.p0Page,
  ),
  'sidebar.right.pane.tab.title': SlotInfo(
    'sidebar.right.pane.tab.title',
    SlotKind.keyed,
    SlotScope.session,
    policy: SeatPolicy.never,
  ),
  'sidebar.right.tab.document': SlotInfo('sidebar.right.tab.document', SlotKind.keyed, SlotScope.session),
  'sidebar.right.tab.document.action': SlotInfo('sidebar.right.tab.document.action', SlotKind.keyed, SlotScope.session),
  'sidebar.right.tab.document.actions': SlotInfo(
    'sidebar.right.tab.document.actions',
    SlotKind.list,
    SlotScope.session,
  ),
  'sidebar.right.tab.document.office.pdf': SlotInfo(
    'sidebar.right.tab.document.office.pdf',
    SlotKind.keyed,
    SlotScope.session,
  ),
  'sidebar.right.tab.document.unpreviewable': SlotInfo(
    'sidebar.right.tab.document.unpreviewable',
    SlotKind.list,
    SlotScope.session,
  ),
  'sidebar.right.tab.files.actions': SlotInfo('sidebar.right.tab.files.actions', SlotKind.list, SlotScope.session),
  'sidebar.right.tab.guide': SlotInfo('sidebar.right.tab.guide', SlotKind.chain, SlotScope.session),
  'sidebar.right.tab.guide.actions': SlotInfo('sidebar.right.tab.guide.actions', SlotKind.list, SlotScope.root),
  'sidebar.right.tab.guide.entry': SlotInfo('sidebar.right.tab.guide.entry', SlotKind.keyed, SlotScope.session),
  'sidebar.right.tab.menu.item': SlotInfo('sidebar.right.tab.menu.item', SlotKind.list, SlotScope.session),
  'sidebar.session.row.hover': SlotInfo('sidebar.session.row.hover', SlotKind.list, SlotScope.root),
  'sidebar.session.row.leading': SlotInfo('sidebar.session.row.leading', SlotKind.list, SlotScope.root),
  'sidebar.session.row.trailing': SlotInfo('sidebar.session.row.trailing', SlotKind.list, SlotScope.root),
  'sidebar.settings': SlotInfo(
    'sidebar.settings',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.toggle.badge': SlotInfo(
    'sidebar.toggle.badge',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.workspaces': SlotInfo(
    'sidebar.workspaces',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.workspaces.directoryFlow': SlotInfo(
    'sidebar.workspaces.directoryFlow',
    SlotKind.single,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'sidebar.workspaces.session.menu.item': SlotInfo(
    'sidebar.workspaces.session.menu.item',
    SlotKind.list,
    SlotScope.root,
  ),
  'sidebar.workspaces.session.row.action': SlotInfo(
    'sidebar.workspaces.session.row.action',
    SlotKind.list,
    SlotScope.root,
  ),
  'tool.call.images': SlotInfo(
    'tool.call.images',
    SlotKind.single,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.message,
  ),
  'tool.call.toolview': SlotInfo(
    'tool.call.toolview',
    SlotKind.keyed,
    SlotScope.session,
    replacesShippedUi: true,
    policy: SeatPolicy.message,
  ),
  'tool.view.cordis': SlotInfo('tool.view.cordis', SlotKind.keyed, SlotScope.session, policy: SeatPolicy.p0Page),
  'workspace.toast': SlotInfo(
    'workspace.toast',
    SlotKind.keyed,
    SlotScope.root,
    replacesShippedUi: true,
    policy: SeatPolicy.never,
  ),
  'dsh-go.panel': SlotInfo(
    'dsh-go.panel',
    SlotKind.keyed,
    SlotScope.sessionMaybe,
    policy: SeatPolicy.p2Native,
    synthetic: true,
  ),
};
