/**
 * dsh-remote-portal — network facts: which addresses this machine has, which
 * URLs to show, and whether a given bind is safe to perform.
 *
 * The interesting part is address discovery. This machine (and most Windows
 * desktops) has several IPv4 addresses: the real Ethernet NIC plus VMware
 * host-only adapters, Hyper-V's `vEthernet`, and sometimes Docker/WSL/Tailscale
 * adapters. Picking the wrong one hands the user a URL that no phone on the
 * Wi-Fi can reach — which looks exactly like "the portal is broken".
 *
 * Strategy (both signals, cheapest first):
 *  1. Ask the routing table which source address it would use for an off-LAN
 *     destination (UDP `connect` — no packet is sent, the OS just resolves the
 *     route). That is the primary LAN IP by definition.
 *  2. Fall back to an interface scan scored by name: real adapters first,
 *     anything whose name smells of a virtual switch is excluded outright.
 *
 * `assertBindSafe()` is the security half: a non-loopback bind without a
 * password would be an unauthenticated proxy into the user's dsh session, so it
 * refuses instead of "helpfully" starting.
 */
import dgram from "node:dgram";
import os from "node:os";

/**
 * Interface names that are never the LAN address we want.
 * `vethernet` is listed explicitly because it also matches /ethernet/ — the
 * exclusion is checked before any positive score.
 */
const VIRTUAL_NAME_RE =
  /(vmware|virtualbox|vbox|virtual|vethernet|hyper-?v|docker|podman|br-|veth|tailscale|zerotier|hamachi|radmin|loopback|wsl|npcap|tap|tun\d|ppp|bluetooth|utun|awdl|llw|bridge|wintun|clash|meta|vpn|openvpn|wireguard|teredo|isatap)/i;

/** Names that on Windows/macOS/Linux usually mean "the real NIC". */
const PHYSICAL_NAME_RE = /(ethernet|以太网|wlan|wi-?fi|无线|en\d|eth\d|enp\d|wlp\d|eno\d|ens\d|本地连接)/i;

const LOOPBACK_ADDR_RE = /^(127\.|::1$|0:0:0:0:0:0:0:1$)/;
const LINK_LOCAL_RE = /^169\.254\./;

const discoveryCache = { at: 0, list: [], primary: "" };
const CACHE_TTL_MS = 15_000;

/** True for 127.0.0.0/8, ::1, localhost and bracketed IPv6 loopback. */
export function isLoopback(host) {
  const h = String(host ?? "").trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (h === "" ) return false;
  if (h === "localhost" || h === "::1" || h === "0:0:0:0:0:0:0:1") return true;
  return /^127\./.test(h);
}

/** True when the bind literal means "every interface". */
export function isWildcard(host) {
  const h = String(host ?? "").trim();
  return h === "" || h === "*" || h === "0.0.0.0" || h === "::" || h === "[::]" ||
    h.toLowerCase() === "0:0:0:0:0:0:0:0";
}

/** Strip the IPv4-mapped IPv6 prefix Node reports for dual-stack sockets. */
export function normalizeAddress(address) {
  const a = String(address ?? "").trim();
  return a.toLowerCase().startsWith("::ffff:") ? a.slice(7) : a;
}

/**
 * The source address the default route would use.
 * @returns {Promise<string>} address, or "" when there is no usable route.
 */
export function defaultRouteAddress({ timeoutMs = 400, probeHost = "8.8.8.8", probePort = 53 } = {}) {
  return new Promise((resolve) => {
    let settled = false;
    const socket = dgram.createSocket("udp4");
    const finish = (value) => {
      if (settled) return;
      settled = true;
      try { socket.close(); } catch { /* already closed */ }
      resolve(value);
    };
    const timer = setTimeout(() => finish(""), timeoutMs);
    timer.unref?.();
    socket.on("error", () => finish(""));
    try {
      // UDP connect() performs no network I/O; it binds the socket and lets the
      // kernel pick the outgoing interface. Works with no internet at all.
      socket.connect(probePort, probeHost, () => {
        let address = "";
        try {
          const info = socket.address();
          address = info && typeof info === "object" ? info.address : "";
        } catch {
          address = "";
        }
        finish(address && address !== "0.0.0.0" ? address : "");
      });
    } catch {
      finish("");
    }
  });
}

/**
 * Interface scan (synchronous, no routing-table probe).
 * @returns {Array<{address:string, iface:string, family:string, primary:boolean}>}
 */
export function discoverAddressesSync({ primary = "" } = {}) {
  let interfaces;
  try {
    interfaces = os.networkInterfaces();
  } catch {
    return [];
  }
  const scored = [];
  for (const [iface, list] of Object.entries(interfaces)) {
    if (!Array.isArray(list)) continue;
    const virtual = VIRTUAL_NAME_RE.test(iface);
    for (const info of list) {
      if (!info || info.internal) continue;
      const family = typeof info.family === "string" ? info.family : info.family === 4 ? "IPv4" : "IPv6";
      if (family !== "IPv4") continue;
      const address = normalizeAddress(info.address);
      if (!address || address === "0.0.0.0") continue;
      if (LOOPBACK_ADDR_RE.test(address) || LINK_LOCAL_RE.test(address)) continue;
      // Virtual adapters are excluded, not merely penalised: on this machine
      // they are 192.168.x hosts that would otherwise out-score the real NIC
      // whenever the Ethernet cable is unplugged.
      if (virtual) continue;
      const physical = PHYSICAL_NAME_RE.test(iface);
      scored.push({ address, iface, family: "IPv4", physical, order: scored.length });
    }
  }
  scored.sort((a, b) => {
    if (primary) {
      if (a.address === primary) return -1;
      if (b.address === primary) return 1;
    }
    if (a.physical !== b.physical) return a.physical ? -1 : 1;
    return a.order - b.order;
  });
  return scored.map(({ address, iface, family, physical }) => ({
    address, iface, family, primary: primary !== "" ? address === primary : physical,
  }));
}

/**
 * Full discovery (cached for 15 s: `status()` is polled by the panel).
 * @returns {Promise<Array<{address:string, iface:string, family:string, primary:boolean}>>}
 */
export async function discoverAddresses({ fresh = false, now = Date.now() } = {}) {
  if (!fresh && now - discoveryCache.at < CACHE_TTL_MS && discoveryCache.list.length > 0) {
    return discoveryCache.list;
  }
  let primary = "";
  try {
    primary = await defaultRouteAddress();
  } catch {
    primary = "";
  }
  let list = discoverAddressesSync({ primary });
  // No routing-table answer (isolated LAN, no default gateway): fall back to the
  // best-scoring physical interface so "auto" still binds to something usable.
  if (!list.some((entry) => entry.primary) && list.length > 0) {
    list = list.map((entry, index) => ({ ...entry, primary: index === 0 }));
  }
  discoveryCache.at = now;
  discoveryCache.list = list;
  discoveryCache.primary = (list.find((entry) => entry.primary) || list[0] || {}).address || "";
  return list;
}

/** Primary LAN IPv4, or "" when the machine has none. */
export function primaryAddress(addresses = discoveryCache.list) {
  const found = addresses.find((entry) => entry.primary && entry.address);
  return found ? found.address : "";
}

// ───────────────────────────────────────────────────────────────────────────
// URLs
// ───────────────────────────────────────────────────────────────────────────

/** `host:port`, with IPv6 brackets, omitting the scheme's default port. */
export function authorityFor(host, port, protocol = "http:") {
  const bare = String(host ?? "").trim().replace(/^\[|\]$/g, "");
  if (bare === "") return "";
  const bracketed = bare.includes(":") ? `[${bare}]` : bare;
  const scheme = String(protocol || "http:").replace(/:?$/, ":");
  const defaultPort = scheme === "https:" ? 443 : 80;
  const p = Number(port);
  if (!Number.isFinite(p) || p <= 0) return bracketed;
  return p === defaultPort ? bracketed : `${bracketed}:${p}`;
}

export function originFor(protocol, host, port) {
  const scheme = String(protocol || "http:").replace(/:?$/, ":");
  const authority = authorityFor(host, port, scheme);
  return authority === "" ? `${scheme}//` : `${scheme}//${authority}`;
}

/**
 * Every URL this bind actually serves, primary LAN first (§4.1 Status.urls).
 *
 * A wildcard bind serves loopback *and* every LAN address; a specific bind
 * serves exactly itself. `urls` is what the panel offers ("open on this phone"),
 * `lanUrls` is what a QR code may encode (a loopback URL is useless on a phone).
 */
export function urlsFor({ bindHost, port, protocol = "http:", addresses = [] } = {}) {
  const scheme = String(protocol || "http:").replace(/:?$/, ":");
  const portNumber = Number(port);
  const urls = [];
  const lanUrls = [];
  const push = (host) => {
    const url = `${originFor(scheme, host, portNumber)}/`;
    if (!urls.includes(url)) urls.push(url);
    return url;
  };
  if (isWildcard(bindHost)) {
    for (const entry of addresses) {
      if (!entry || !entry.address) continue;
      if (isLoopback(entry.address)) continue;
      const url = `${originFor(scheme, entry.address, portNumber)}/`;
      if (!lanUrls.includes(url)) lanUrls.push(url);
      if (!urls.includes(url)) urls.push(url);
    }
    const loop = `${originFor(scheme, "127.0.0.1", portNumber)}/`;
    if (!urls.includes(loop)) urls.push(loop);
  } else if (isLoopback(bindHost)) {
    push(bindHost);
  } else {
    const url = push(bindHost);
    lanUrls.push(url);
  }
  return { urls, lanUrls };
}

// ───────────────────────────────────────────────────────────────────────────
// bind safety
// ───────────────────────────────────────────────────────────────────────────

/**
 * Refuse a bind that would expose the portal without a gate.
 *
 * The failure mode being prevented: user flips "host" to `0.0.0.0` before
 * setting a password, and every device on the Wi-Fi gets a fully authenticated
 * dsh session (the gateway mints browser cookies server-side). So:
 *
 *   · any non-loopback bind in `password` mode requires a password;
 *   · `open` mode is only ever legal on loopback (it means "no gate at all");
 *   · `pair-only` is allowed on the LAN, because a session can only be created
 *     by redeeming a 32-byte single-use token that exists only in the panel's
 *     QR code — there is no anonymous path in.
 *
 * @throws {Error & {code:"needs-password"|"open-requires-loopback"|"no-lan-address"}}
 */
export function assertBindSafe({ bindHost, passwordSet, authMode = "password" } = {}) {
  const host = String(bindHost ?? "").trim();
  if (host === "") throw errorWith("no-bind-host", "bind host is empty", "no-lan-address");
  const loopback = isLoopback(host);
  const mode = String(authMode || "password");
  if (loopback) return true;
  if (mode === "open") {
    throw errorWith(
      "open-mode-requires-loopback",
      "auth.mode=open is only allowed when the gateway binds to loopback",
      "open-requires-loopback",
    );
  }
  if (mode === "password" && !passwordSet) {
    throw errorWith(
      "needs-password",
      `refusing to bind ${host}: a portal password must be set before exposing the gateway on the network`,
      "needs-password",
    );
  }
  return true;
}

function errorWith(code, message, alias) {
  const error = new Error(message);
  error.code = alias || code;
  error.reason = code;
  return error;
}
