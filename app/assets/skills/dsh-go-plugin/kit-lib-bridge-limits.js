// Protocol v1 limits (docs/design/native-plugins-protocol.md §7). Served as `contributions.limits`
// so the app and the SDK check read one table.
export const PROTOCOL = 1;

export const LIMITS = Object.freeze({
  manifestBytes: 16384,
  perPlugin: Object.freeze({ "composer.actions": 2, "message.actions": 2, "composer.strip": 1, panels: 4, "composer.tools": 2, "session.actions": 2, "turn.note": 1 }),
  textChars: Object.freeze({ composerTool: 8, sessionAction: 12, turnNote: 16, pluginTitle: 24, composerAction: 10, messageAction: 12, panelTitle: 16, stripText: 24, toast: 40 }),
  viewBytes: 32768,
  viewNodes: 120,
  viewDepth: 8,
  toolCardBytes: 8192,
  toolCardNodes: 40,
  dataBytes: 32768,
  patchBytes: 16384,
  dataHz: 4,
  invokeBytes: 65536,
  invokeValueBytes: 4096,
  contextFieldBytes: 16384,
  invokeBurst: 8,
  invokePerSecond: 4,
  invokeConcurrent: 4,
  effectsPerInvoke: 4,
  insertChars: 2000,
  copyChars: 8000,
  commandArgsChars: 500,
  linkChars: 2048,
  handlerTimeoutMs: 3000,
  viewTimeoutMs: 3000,
  firstDataWaitMs: 1000,
  effectWindowMs: 3000,
  streamConnections: 8,
  streamSubscriptions: 32,
  streamInboundFrameBytes: 4096,
  streamOutboundFrameBytes: 49152,
  streamBacklogBytes: 1048576,
  heartbeatSeconds: 25,
  idleTimeoutSeconds: 60,
  feedLingerMs: 30000,
  feeds: 64,
  assetBytes: 1048576,
  violationsToDegrade: 5,
  pendingPerPlugin: 2,
  pendingDefaultMs: 30000,
  pendingMinMs: 1000,
  pendingMaxMs: 60000,
  pendingLabelChars: 16,
  pendingEarlyResultMs: 5000,
  turnNotesPerFeed: 64,
});

/** Timing knobs a test harness may shorten through the bridge config `native: {...}`. */
export const TUNABLE = ["handlerTimeoutMs", "viewTimeoutMs", "firstDataWaitMs", "heartbeatSeconds", "idleTimeoutSeconds", "feedLingerMs"];

export function effectiveLimits(overrides) {
  if (overrides === null || typeof overrides !== "object") return LIMITS;
  const out = { ...LIMITS };
  for (const key of TUNABLE) {
    const v = overrides[key];
    if (typeof v === "number" && Number.isFinite(v) && v > 0) out[key] = v;
  }
  return Object.freeze(out);
}

export const SURFACES = ["composer.actions", "message.actions", "composer.strip", "panels", "composer.tools", "session.actions", "turn.note"];
export const PLACEMENT_PLUGIN = "plugin";
export const PLACEMENTS = ["session.tab", "features", "chat.panel", PLACEMENT_PLUGIN];
/** Only where the app says it draws them (`surfaces`): see placementFor in manifest.js. */
export const NEGOTIATED_PLACEMENTS = [PLACEMENT_PLUGIN];
export const PRESENTATIONS = ["page", "sheet"];
export const WANTS = ["draft", "clipboard", "message"];
export const TONES = ["good", "warn", "bad", "info", "muted"];
export const SCOPE_KEYS = ["sessionId", "turnId", "messageId", "callId"];
export const ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/;
export const ICON = /^[a-z][a-z0-9-]{0,31}$/;
export const PKG = /^(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/;
export const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;
