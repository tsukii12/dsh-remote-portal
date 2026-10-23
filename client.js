// dsh-remote-portal — browser half.
//
// Hand-written bundle, no build step. The host's @deepseek-ai/dsh-client-modules
// loads this file with a classic <script> and expects exactly one call to
// window.__ModuleLoader__.load({ id, factory }). Only the shell seed module
// "react" may be required.
//
// Ground rules this file obeys (see ARCHITECTURE.md §1 / §4.4):
//   · the factory body is side-effect free — every definition only; all effects
//     live in apply(ctx);
//   · one throwing client plugin blanks the whole Web app, so *every*
//     registration and every async path is wrapped in try/catch and swallowed;
//   · all UI text goes through the tiny t() below (zh + en, keyed by
//     documentElement.lang);
//   · every class is prefixed drp-, every colour comes from a --dsw-alias-*
//     token with a literal fallback, so the panel follows light/dark and any
//     third-party skin automatically;
//   · the only DOM writes outside the React subtree are the two asset tags in
//     mountAssets() (mobile.css / mobile.js), and both are idempotent;
//   · nothing here drives the host's own UI: the sidebar entry opens our own
//     shell.overlay sheet, so no host control is clicked or guessed at.
//
// Surfaces:
//   sidebar.footer.action     — the entry that opens the panel.
//   shell.overlay  (order 95) — the panel and the directory picker, both framed
//                               to the centre column so they read as pages of the
//                               main area rather than full-screen covers.
//
// Host routes used (same-origin control routes registered by index.js):
//   GET  /dsh-remote-portal/status          → Status (ARCHITECTURE §4.1)
//   GET  /dsh-remote-portal/devices         → Device[] | { devices: Device[] }
//   POST /dsh-remote-portal/pair            → { url, expiresAt } | { token, ttlSeconds }
//   POST /dsh-remote-portal/config          → Status | { status: Status }
//   POST /dsh-remote-portal/password        → any 2xx
//   POST /dsh-remote-portal/devices/revoke  → any 2xx
//   GET  /dsh-remote-portal/qr.svg?text=…   → image/svg+xml
//   GET  /dsh-remote-portal/assets/mobile.{css,js}
window.__ModuleLoader__.load({
  id: "dsh-remote-portal",
  factory: function (require) {
    "use strict";

    var React = require("react");
    var h = React.createElement;
    var useState = React.useState;
    var useEffect = React.useEffect;
    var useRef = React.useRef;
    // React 18 API; hosts on an older React get the small fallback in
    // useOverlayOpen() below instead of a hard failure.
    var useSyncExternalStore = typeof React.useSyncExternalStore === "function" ? React.useSyncExternalStore : null;

    // ── constants ────────────────────────────────────────────────────────────
    // Relative on purpose: the app document carries `<base href="./">`, so this
    // resolves to /dsh-remote-portal/… at the root *and* to
    // /__t/<id>/dsh-remote-portal/… when the whole UI is mounted under a relay
    // prefix. An absolute path here would break remote access through a tunnel.
    var BASE = "./dsh-remote-portal";
  // Must match package.json: it is what busts the browser cache for the layer.
  var CLIENT_VERSION = "0.5.1";
    var POLL_MS = 3000;         // status poll while the settings page is visible
    var MIN_PW = 8;             // matches the host's "≥8 recommended" rule (§3)
    var COPY_FEEDBACK_MS = 1600;
    var NOTE_MS = 4000;

    // ── i18n ─────────────────────────────────────────────────────────────────
    // Two locales, inline. Keyed on <html lang>, which the host writes from the
    // profile locale (zh-CN / en-US); unknown or empty falls back to zh, the
    // product's default.
    var DICT = {
      zh: {
        section: "远程访问",
        subtitle: "从其他设备访问此 dsh。需要访问密码或一次性配对码。",
        navLabel: "远程访问",
        navTitle: "打开远程访问设置",
        close: "关闭",
        pillRunning: "运行中",
        pillStopped: "已停止",
        pillError: "出错",
        pillLoading: "连接中",
        statusLabel: "门户状态",
        cardAddr: "手机访问地址",
        chipLan: "局域网",
        copy: "复制",
        copied: "已复制",
        copyFail: "复制失败，请手动选中地址",
        noUrl: "门户未运行，暂无可用地址",
        loopHint: "当前是本机回环地址，手机访问不到。把监听地址改为 0.0.0.0 或 auto 后保存。",
        fwHint: "打不开？请确认手机与电脑在同一网络，并在防火墙放行 TCP {port} 端口。",
        cardQr: "扫码配对",
        qrAlt: "扫码配对二维码",
        qrEmpty: "正在生成配对码…",
        qrNotRunning: "门户未运行：先在下方设置访问密码并启用",
        qrNoteStopped: "门户没有在监听，二维码暂时不可用。设置密码并启用后会自动生成。",
        copyPairLink: "复制配对链接",
        pairLinkCopied: "配对链接已复制，5 分钟内有效",
        qrNotePair: "用手机相机扫描二维码，即可直接在这台手机上打开 dsh。",
        qrNotePlain: "用手机相机扫描二维码，打开后输入访问密码。",
        qrRefresh: "刷新二维码",
        qrRefreshing: "刷新中…",
        qrRefreshed: "二维码已刷新",
        qrExpired: "已过期",
        qrLeft: "剩余 {t}",
        pairFail: "配对码生成失败",
        cardAccess: "访问控制",
        swEnable: "启用远程访问",
        swEnableNote: "关闭后门户立即停止监听，所有手机连接断开。",
        enabledOn: "已启用远程访问",
        enabledOff: "已关闭远程访问",
        host: "监听地址",
        port: "端口",
        save: "保存",
        saving: "保存中…",
        saveOk: "已保存",
        invalidHost: "监听地址不能为空",
        invalidPort: "端口需为 1–65535 之间的整数",
        cfgNote: "0.0.0.0 监听所有网卡；127.0.0.1 仅本机；auto 自动选择主网卡。",
        pwTitle: "访问密码",
        firstRunTitle: "还差一步：设置访问密码",
        firstRunNote: "门户在暴露到局域网之前必须先有密码，设置后会自动开始监听。",
        firstRunCta: "去设置密码",
        pwStateSet: "已设置",
        pwStateUnset: "未设置",
        pwNote: "至少 {n} 位。修改密码后，已登录的设备需要重新验证。",
        pwWarn: "尚未设置密码：门户在非本机地址上不会启动。",
        pwPlaceholder: "输入新密码",
        pwShow: "显示",
        pwHide: "隐藏",
        pwSave: "更新密码",
        pwSaving: "保存中…",
        pwOk: "密码已更新",
        pwShort: "密码至少需要 {n} 位",
        cardDev: "已授权设备",
        cardPublic: "公网访问",
        pickTitle: "选择工作区目录",
        pickUp: "上级",
        pickLoading: "正在读取目录…",
        pickEmpty: "这里没有子目录",
        pickUse: "使用此目录",
        pickHostOld: "宿主未加载该接口：请重启 dsh 后重试。",
        pickNew: "新建文件夹",
        pickNewHint: "文件夹名称",
        pickCreate: "创建",
        pickExists: "同名文件夹已存在。",
        pickMkdirFailed: "创建文件夹失败，请检查名称或权限。",
        cancel: "取消",

        tunnelOnline: "已连接",
        tunnelConnecting: "连接中",
        tunnelRetrying: "重连中",
        tunnelError: "出错",
        tunnelOffline: "离线",
        tunnelOff: "未配置",
        tunnelUrlLabel: "中转服务器",
        tunnelTokenLabel: "隧道令牌",
        tunnelTokenKeep: "留空则沿用已保存的令牌",
        tunnelSave: "连接",
        tunnelDisconnect: "断开",
        tunnelSaved: "已保存，正在连接中转服务器…",
        tunnelCleared: "已断开公网访问",
        tunnelUrlRequired: "请填写中转服务器地址",
        tunnelUrlScheme: "填写地址和端口，例如 203.0.113.10:9443",
        tunnelInsecure: "信任自签名证书（跳过证书校验）",
        tunnelTokenRequired: "首次连接需要填写隧道令牌",
        tunnelNote: "中转服务器运行 tools/relay.mjs，填入代理端口与隧道令牌。",
        cardDiag: "连接诊断",
        cardLog: "最近访问",
        diagOk: "可达",
        diagBad: "不可达",
        diagUnknown: "未探测",
        diagRefresh: "刷新",
        diagBusy: "刷新中",
        diagUnavailable: "暂时读不到诊断信息（宿主未响应）。",
        diagFirewall: "防火墙放行（管理员 PowerShell，仅 Windows 需要）",
        copyCmd: "复制命令",
        logEmpty: "还没有访问记录。手机上打开一次就会出现在这里。",
        devEmpty: "还没有授权的设备，扫码后会出现在这里。",
        devUnnamed: "未命名设备",
        revoke: "移除",
        revoking: "移除中…",
        revokeOk: "已移除该设备",
        never: "从未连接",
        justNow: "刚刚",
        minAgo: "{n} 分钟前",
        hourAgo: "{n} 小时前",
        dayAgo: "{n} 天前",
        statusFail: "无法读取门户状态。",
        statusFailHint: "插件可能尚未加载完成，稍后会自动重试。",
        statusErrorTitle: "门户报告了一个错误",
        errNeedsPassword: "尚未设置访问密码：门户在暴露到局域网之前必须先设置密码，请在下方「访问密码」中设置后再启用。",
        errPortBusy: "端口已被占用：换一个端口，或先关闭占用它的程序。",
        retry: "重试",
        httpError: "请求失败",
        timeout: "请求超时，请重试",
        network: "无法连接本机门户服务"
      },
      en: {
        section: "Remote Portal",
        subtitle: "Open this same dsh Web GUI from a phone or another computer. The portal listens on the LAN and requires a password or a scanned pairing code.",
        navLabel: "Remote access",
        navTitle: "Open remote access settings",
        close: "Close",
        pillRunning: "Running",
        pillStopped: "Stopped",
        pillError: "Error",
        pillLoading: "Connecting",
        statusLabel: "Portal status",
        cardAddr: "Phone address",
        chipLan: "LAN",
        copy: "Copy",
        copied: "Copied",
        copyFail: "Copy failed — select the address manually",
        noUrl: "Portal is not running — no address yet",
        loopHint: "This is a loopback address, a phone cannot reach it. Set the bind address to 0.0.0.0 or auto and save.",
        fwHint: "Not loading? Make sure the phone is on the same network and allow TCP port {port} through the firewall.",
        cardQr: "Pair by QR code",
        qrAlt: "Pairing QR code",
        qrEmpty: "Generating a pairing code…",
        qrNotRunning: "Portal is not running — set a password below and enable it",
        qrNoteStopped: "Nothing is listening yet, so there is no code to scan. Set a password and enable the portal; the code appears automatically.",
        copyPairLink: "Copy pairing link",
        pairLinkCopied: "Pairing link copied — valid for 5 minutes",
        qrNotePair: "Scan with the phone camera to open dsh on that phone right away.",
        qrNotePlain: "Scan with the phone camera, then enter the access password.",
        qrRefresh: "Refresh code",
        qrRefreshing: "Refreshing…",
        qrRefreshed: "QR code refreshed",
        qrExpired: "Expired",
        qrLeft: "{t} left",
        pairFail: "Could not create a pairing code",
        cardAccess: "Access control",
        swEnable: "Enable remote access",
        swEnableNote: "Turning this off stops the listener immediately and drops every phone connection.",
        enabledOn: "Remote access enabled",
        enabledOff: "Remote access disabled",
        host: "Bind address",
        port: "Port",
        save: "Save",
        saving: "Saving…",
        saveOk: "Saved",
        invalidHost: "Bind address cannot be empty",
        invalidPort: "Port must be an integer between 1 and 65535",
        cfgNote: "0.0.0.0 listens on every interface; 127.0.0.1 is this machine only; auto picks the primary LAN adapter.",
        pwTitle: "Access password",
        firstRunTitle: "One step left: set an access password",
        firstRunNote: "The portal refuses to listen on the network until a password exists. It starts by itself once you set one.",
        firstRunCta: "Set the password",
        pwStateSet: "Set",
        pwStateUnset: "Not set",
        pwNote: "At least {n} characters. Existing devices must sign in again after a change.",
        pwWarn: "No password yet — the portal refuses to bind a non-loopback address.",
        pwPlaceholder: "New password",
        pwShow: "Show",
        pwHide: "Hide",
        pwSave: "Update password",
        pwSaving: "Saving…",
        pwOk: "Password updated",
        pwShort: "Password needs at least {n} characters",
        cardDev: "Authorised devices",
        cardPublic: "Public access",
        pickTitle: "Choose a workspace folder",
        pickUp: "Up",
        pickLoading: "Reading directory…",
        pickEmpty: "No subdirectories here",
        pickUse: "Use this folder",
        pickHostOld: "The host has not loaded this endpoint yet — restart dsh and retry.",
        pickNew: "New folder",
        pickNewHint: "Folder name",
        pickCreate: "Create",
        pickExists: "A folder with that name already exists.",
        pickMkdirFailed: "Could not create the folder — check the name or permissions.",
        cancel: "Cancel",

        tunnelOnline: "Online",
        tunnelConnecting: "Connecting",
        tunnelRetrying: "Reconnecting",
        tunnelError: "Error",
        tunnelOffline: "Offline",
        tunnelOff: "Not set up",
        tunnelUrlLabel: "Relay endpoint",
        tunnelTokenLabel: "Tunnel token",
        tunnelTokenKeep: "Leave empty to keep the saved token",
        tunnelSave: "Connect",
        tunnelDisconnect: "Disconnect",
        tunnelSaved: "Saved — dialing the relay…",
        tunnelCleared: "Public access removed",
        tunnelUrlRequired: "Enter the relay endpoint",
        tunnelUrlScheme: "Enter an address and port, for example 203.0.113.10:9443",
        tunnelInsecure: "Trust a self-signed certificate (skip verification)",
        tunnelTokenRequired: "A tunnel token is required the first time",
        tunnelNote: "Run tools/relay.mjs on your server, then enter its agent endpoint and token.",
        cardDiag: "Connectivity",
        cardLog: "Recent access",
        diagOk: "reachable",
        diagBad: "unreachable",
        diagUnknown: "not probed yet",
        diagRefresh: "Refresh",
        diagBusy: "Refreshing",
        diagUnavailable: "Diagnostics unavailable (the host did not answer).",
        diagFirewall: "Firewall rule (admin PowerShell, Windows only)",
        copyCmd: "Copy command",
        logEmpty: "No requests yet. It fills in the first time a phone opens the portal.",
        devEmpty: "No devices yet — they show up here after a scan.",
        devUnnamed: "Unnamed device",
        revoke: "Revoke",
        revoking: "Revoking…",
        revokeOk: "Device revoked",
        never: "Never connected",
        justNow: "just now",
        minAgo: "{n} min ago",
        hourAgo: "{n} h ago",
        dayAgo: "{n} d ago",
        statusFail: "Cannot read portal status.",
        statusFailHint: "The plugin may still be loading; this retries automatically.",
        statusErrorTitle: "The portal reported an error",
        errNeedsPassword: "No password yet: the portal refuses to expose itself to the network until one is set. Set it under “Access password” below, then enable the portal.",
        errPortBusy: "That port is already in use — pick another port, or stop the program holding it.",
        retry: "Retry",
        httpError: "Request failed",
        timeout: "Request timed out, please retry",
        network: "Cannot reach the local portal service"
      }
    };

    function lang() {
      var raw = "";
      try { raw = String(document.documentElement.getAttribute("lang") || ""); } catch (e) { raw = ""; }
      if (!raw) { try { raw = String(navigator.language || ""); } catch (e2) { raw = ""; } }
      if (!raw) return "zh";
      return /^zh/i.test(raw) ? "zh" : "en";
    }

    function t(key, vars) {
      var table = DICT[lang()] || DICT.zh;
      var s = table[key];
      if (typeof s !== "string") s = DICT.zh[key];
      if (typeof s !== "string") return key;
      if (vars) {
        for (var k in vars) {
          if (Object.prototype.hasOwnProperty.call(vars, k)) {
            s = s.split("{" + k + "}").join(String(vars[k]));
          }
        }
      }
      return s;
    }

    /**
     * Turn a host-side error string into something a person can act on.
     *
     * The gateway reports machine facts (`refusing to bind 0.0.0.0: a portal
     * password must be set …`, `listen EADDRINUSE …`) because that is what a log
     * needs. In a panel those sentences are the first thing a new user reads, so
     * the two predictable ones are translated and everything else is shown
     * verbatim — never hidden, because an unexpected failure is exactly the case
     * where the raw text matters.
     */
    function friendlyError(text) {
      var raw = String(text || "");
      if (/password must be set|needs-password/i.test(raw)) return t("errNeedsPassword");
      if (/EADDRINUSE|already in use|已被占用/i.test(raw)) return t("errPortBusy");
      return raw;
    }

    // ── icons ────────────────────────────────────────────────────────────────
    // Inline, currentColor only, 24×24 stroke geometry. No emoji: the host's own
    // settings page is typographic, and emoji render differently per platform.
    var ICON_PATHS = {
      copy: ["M9.5 9.5h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2Z", "M6.5 15.2A2 2 0 0 1 5 13.2v-8a2 2 0 0 1 2-2h8a2 2 0 0 1 2 1.5"],
      check: ["M4.5 12.5 9.5 17.5 19.5 6.5"],
      up: ["M12 19V5", "M5.5 11.5 12 5l6.5 6.5"],
      folder: ["M3.6 7.6a2 2 0 0 1 2-2h3.1l1.8 2h7.9a2 2 0 0 1 2 2v8.2a2 2 0 0 1-2 2H5.6a2 2 0 0 1-2-2z"],
      chevron: ["M9.5 6.5 15 12l-5.5 5.5"],
      plus: ["M12 5.5v13", "M5.5 12h13"],
      alert: ["M12 8.2v5.1", "M12 16.6h.01", "M10.4 3.9 2.7 17.3a1.9 1.9 0 0 0 1.6 2.9h15.4a1.9 1.9 0 0 0 1.6-2.9L13.6 3.9a1.9 1.9 0 0 0-3.2 0Z"],
      refresh: ["M20 12a8 8 0 1 1-2.3-5.7", "M20 4.2v5.4h-5.4"],
      close: ["M6.5 6.5 17.5 17.5", "M17.5 6.5 6.5 17.5"],
      portal: ["M12 10.6a1.4 1.4 0 1 1 0 2.8 1.4 1.4 0 0 1 0-2.8Z", "M8.9 15.6a4.9 4.9 0 0 1 0-7.2", "M15.1 8.4a4.9 4.9 0 0 1 0 7.2", "M6.2 18.2a9 9 0 0 1 0-12.4", "M17.8 5.8a9 9 0 0 1 0 12.4"]
    };

    function Icon(props) {
      var paths = ICON_PATHS[props.name] || [];
      var size = props.size || 16;
      return h("svg", {
        className: "drp-ico" + (props.className ? " " + props.className : ""),
        width: size, height: size, viewBox: "0 0 24 24",
        fill: "none", stroke: "currentColor", strokeWidth: 1.7,
        strokeLinecap: "round", strokeLinejoin: "round",
        "aria-hidden": "true", focusable: "false"
      }, paths.map(function (d, i) { return h("path", { key: i, d: d }); }));
    }

    // ── stylesheet ───────────────────────────────────────────────────────────
    // Rendered inside the panel subtree (never appended to <head>), so it
    // unmounts with the section and cannot leak into the host UI. Only tokens:
    // light/dark and third-party skins are all handled by the cascade.
    var CSS = [
      ".drp-ui,.drp-ui *,.drp-ui *::before,.drp-ui *::after{box-sizing:border-box}",
      // Token scope shared by the inline section and the overlay sheet, so both
      // follow light/dark and any third-party skin automatically.
      ".drp-root,.drp-sheet{",
      "--drp-fg:var(--dsw-alias-label-primary,#0f1115);",
      "--drp-fg2:var(--dsw-alias-label-secondary,#61666b);",
      "--drp-fg3:var(--dsw-alias-label-tertiary,#81858c);",
      "--drp-line:var(--dsw-alias-border-l2,rgba(0,0,0,.10));",
      "--drp-card:var(--dsw-alias-bg-layer-2,#fff);",
      "--drp-soft:var(--dsw-alias-bg-layer-1,#fff);",
      "--drp-link:var(--dsw-alias-link,#4176e6);",
      "--drp-mono:ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,'Liberation Mono',monospace;",
      "--drp-ok:var(--dsw-alias-state-success-primary,#22c55e);",
      "--drp-err:var(--dsw-alias-state-error-primary,#ec1313);",
      "--drp-btn:var(--dsw-alias-button-primary-fill,#0f1115);",
      "--drp-btn-fg:var(--dsw-alias-label-primary-inverted,#fff);",
      "color:var(--drp-fg);font-size:13px;line-height:1.55;font-family:inherit;",
      "-webkit-text-size-adjust:100%}",
      // The section itself: a plain block in the Settings page.
      ".drp-root{",
      "display:flex;flex-direction:column;gap:16px;max-width:1040px;",
      // The host's settings content column is not the viewport, so the two-column
      // split is driven by the panel's own width; the viewport query below stays
      // as the fallback for engines without container queries.
      "container-type:inline-size}",
      ".drp-root h2,.drp-root h3,.drp-root p{margin:0}",
      ".drp-sheet h2,.drp-sheet h3,.drp-sheet p{margin:0}",

      /* header */
      ".drp-head{display:flex;flex-direction:column;gap:6px}",
      ".drp-head-top{display:flex;align-items:center;gap:12px;flex-wrap:wrap;min-width:0}",
      ".drp-title{flex:1 1 auto;min-width:0;font-size:17px;line-height:1.35;font-weight:600;letter-spacing:-.01em;color:var(--drp-fg)}",
      ".drp-sub{font-size:12.5px;line-height:1.5;color:var(--drp-fg2);max-width:74ch}",

      /* status pill */
      ".drp-pill{display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 10px;border-radius:999px;",
      "border:1px solid var(--drp-line);font-size:12px;font-weight:500;white-space:nowrap;color:var(--drp-fg2);flex:none}",
      ".drp-pill-dot{width:6px;height:6px;border-radius:50%;background:currentColor;flex:none}",
      ".drp-pill-running{color:var(--drp-ok)}",
      ".drp-pill-running .drp-pill-dot{box-shadow:0 0 0 3px rgba(34,197,94,.16)}",
      ".drp-pill-error{color:var(--drp-err);border-color:rgba(236,19,19,.35)}",
      ".drp-pill-loading{color:var(--drp-fg3)}",
      ".drp-pill-loading .drp-pill-dot{animation:drp-pulse 1.4s ease-in-out infinite}",
      "@keyframes drp-pulse{0%,100%{opacity:.35}50%{opacity:1}}",

      /* alerts */
      ".drp-alerts{display:flex;flex-direction:column;gap:8px}",
      /* first run: the one required step, made impossible to miss */
      ".drp-firstrun{display:flex;align-items:center;gap:10px;padding:12px 14px;border-radius:10px;",
      "border:1px solid rgba(245,158,11,.38);background:rgba(245,158,11,.10);color:var(--drp-fg2);",
      "font-size:12.5px;line-height:1.5;flex-wrap:wrap}",
      ".drp-firstrun .drp-ico{flex:none;color:var(--dsw-alias-state-warn-primary,#f59e0b)}",
      ".drp-firstrun-text{flex:1 1 220px;min-width:0}",
      ".drp-firstrun-title{font-weight:600;color:var(--drp-fg)}",
      ".drp-firstrun-note{color:var(--drp-fg2);margin-top:1px}",
      ".drp-firstrun .drp-btn{flex:none}",
      ".drp-alert{display:flex;align-items:flex-start;gap:8px;padding:9px 12px;border-radius:10px;",
      "border:1px solid var(--drp-line);background:var(--drp-soft);font-size:12.5px;line-height:1.5;color:var(--drp-fg2)}",
      ".drp-alert .drp-ico{margin-top:2px;flex:none}",
      ".drp-alert-err{color:var(--drp-err);border-color:rgba(236,19,19,.35);background:rgba(236,19,19,.07)}",
      ".drp-alert-ok{color:var(--drp-ok);border-color:rgba(34,197,94,.35);background:rgba(34,197,94,.08)}",
      ".drp-alert-sub{margin-top:2px;color:var(--drp-fg3);font-size:12px}",

      /* layout */
      ".drp-grid{display:grid;grid-template-columns:minmax(0,1fr) 288px;gap:16px;align-items:start}",
      ".drp-col{display:flex;flex-direction:column;gap:16px;min-width:0}",
      ".drp-card{background:var(--drp-card);border:1px solid var(--drp-line);border-radius:12px;padding:16px;min-width:0}",
      ".drp-card-head{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:12px;flex-wrap:wrap}",
      ".drp-card-title{font-size:13.5px;font-weight:600;color:var(--drp-fg);line-height:1.4}",
      ".drp-card-note{font-size:12px;line-height:1.5;color:var(--drp-fg3)}",
      ".drp-sub{margin-top:16px;padding-top:16px;border-top:1px solid var(--drp-line)}",
      ".drp-sub .drp-card-head{margin-bottom:8px}",

      /* url row */
      ".drp-url{display:flex;align-items:stretch;gap:8px;flex-wrap:wrap}",
      ".drp-url-box{flex:1 1 220px;min-width:0;display:flex;align-items:center;height:34px;padding:0 10px;",
      "border:1px solid var(--drp-line);border-radius:8px;background:transparent;overflow-x:auto;white-space:nowrap;",
      "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,\"Liberation Mono\",monospace;font-size:12.5px;color:var(--drp-fg)}",
      ".drp-url .drp-btn{flex:none}",
      ".drp-url-empty{font-family:inherit;font-size:12.5px;color:var(--drp-fg3)}",
      ".drp-hint{margin-top:8px;font-size:12px;line-height:1.5;color:var(--drp-fg3)}",
      ".drp-hint-warn{color:var(--drp-err)}",

      /* buttons */
      ".drp-btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;height:34px;padding:0 14px;",
      "border-radius:8px;border:1px solid transparent;background:var(--drp-btn);color:var(--drp-btn-fg);",
      "font-family:inherit;font-size:13px;font-weight:600;line-height:1;white-space:nowrap;cursor:pointer;",
      "transition:opacity .15s ease,background-color .15s ease}",
      ".drp-btn:hover:not(:disabled){opacity:.86}",
      ".drp-btn:disabled{opacity:.45;cursor:default}",
      ".drp-btn:focus-visible{outline:2px solid var(--drp-link);outline-offset:2px}",
      ".drp-btn-ghost{background:transparent;color:var(--drp-fg);border-color:var(--drp-line)}",
      ".drp-btn-ghost:hover:not(:disabled){background:rgba(127,127,127,.12);opacity:1}",
      ".drp-btn-sm{height:28px;padding:0 10px;font-size:12px;font-weight:500}",

      /* switch */
      ".drp-switch{position:relative;flex:none;width:38px;height:22px;padding:0;border-radius:999px;",
      "border:1px solid var(--drp-line);background:rgba(127,127,127,.35);cursor:pointer;",
      "transition:background-color .16s ease,border-color .16s ease}",
      ".drp-switch.is-on{background:var(--drp-btn);border-color:var(--drp-btn)}",
      ".drp-switch:disabled{opacity:.5;cursor:default}",
      ".drp-switch:focus-visible{outline:2px solid var(--drp-link);outline-offset:2px}",
      ".drp-switch-knob{position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;",
      "background:var(--dsw-alias-bg-base,#fff);box-shadow:0 1px 2px rgba(0,0,0,.25);",
      "transition:transform .16s ease,background-color .16s ease}",
      ".drp-switch:not(.is-on) .drp-switch-knob{background:var(--drp-fg3)}",
      ".drp-switch.is-on .drp-switch-knob{transform:translateX(16px)}",
      ".drp-toggle-row{display:flex;align-items:flex-start;justify-content:space-between;gap:12px}",
      ".drp-toggle-text{min-width:0}",
      ".drp-toggle-title{font-size:13px;font-weight:500;color:var(--drp-fg)}",
      ".drp-toggle-note{margin-top:2px;font-size:12px;line-height:1.45;color:var(--drp-fg3)}",

      /* form */
      ".drp-form{display:flex;align-items:flex-end;gap:8px;flex-wrap:wrap}",
      ".drp-field{display:flex;flex-direction:column;gap:6px;flex:1 1 150px;min-width:0}",
      ".drp-field-sm{flex:0 0 108px}",
      ".drp-label{font-size:12px;font-weight:500;color:var(--drp-fg2)}",
      // A label that owns a whole line (the firewall hint): no fixed column, so a
      // long sentence wraps instead of collapsing to one character per line.
      ".drp-label-wrap{display:block;width:auto;margin-bottom:2px;line-height:1.5}",
      ".drp-input{width:100%;min-width:0;height:34px;padding:0 10px;border-radius:8px;",
      "border:1px solid var(--drp-line);background:transparent;color:var(--drp-fg);",
      "font-family:inherit;font-size:13px;line-height:1}",
      ".drp-input::placeholder{color:var(--drp-fg3)}",
      ".drp-input:focus{outline:none;border-color:var(--drp-link);box-shadow:0 0 0 3px rgba(65,118,230,.18)}",
      ".drp-pw{position:relative;display:flex;flex:1 1 180px;min-width:0}",
      ".drp-pw .drp-input{padding-right:58px}",
      ".drp-pw-eye{position:absolute;top:4px;right:4px;height:26px;padding:0 8px;border:0;border-radius:6px;",
      "background:transparent;color:var(--drp-fg3);font-family:inherit;font-size:11.5px;font-weight:500;cursor:pointer}",
      ".drp-pw-eye:hover{background:rgba(127,127,127,.14);color:var(--drp-fg)}",
      ".drp-pw-eye:focus-visible{outline:2px solid var(--drp-link);outline-offset:1px}",
      ".drp-check{display:inline-flex;align-items:center;gap:7px;margin-top:10px;font-size:12px;",
      "color:var(--drp-fg2);cursor:pointer}",
      ".drp-check input{width:14px;height:14px;margin:0;accent-color:var(--drp-btn)}",

      /* chips */
      ".drp-chip{display:inline-flex;align-items:center;height:22px;padding:0 8px;border-radius:999px;",
      "border:1px solid var(--drp-line);font-size:11.5px;line-height:1;color:var(--drp-fg2);white-space:nowrap;flex:none}",
      ".drp-chip-warn{color:var(--drp-err);border-color:rgba(236,19,19,.35)}",

      /* QR */
      ".drp-qr{display:flex;flex-direction:column;gap:12px}",
      ".drp-qr-frame{position:relative;display:flex;align-items:center;justify-content:center;",
      "width:100%;max-width:216px;margin:0 auto}",
      ".drp-qr-frame:has(.drp-qr-img){background:#fff;border-radius:10px;padding:10px}",
      ".drp-qr-img{display:block;width:100%;max-width:216px;height:auto;aspect-ratio:1/1}",
      ".drp-card .drp-qr{flex-direction:row;align-items:flex-start;gap:16px;flex-wrap:wrap}",
      ".drp-card .drp-qr > .drp-qr-frame,.drp-card .drp-qr > .drp-qr-empty{max-width:150px;margin:0}",
      ".drp-card .drp-qr-note{flex:1 1 160px;min-width:140px;text-align:left;margin:0}",
      ".drp-qr-empty{display:flex;align-items:center;justify-content:center;width:100%;max-width:216px;",
      "aspect-ratio:1/1;padding:16px;border-radius:10px;background:transparent;color:var(--drp-fg3);",
      "border:1px dashed var(--drp-line);font-size:13px;line-height:1.55;text-align:center}",
      ".drp-qr-veil{position:absolute;inset:12px;display:flex;align-items:center;justify-content:center;",
      "border-radius:8px;background:rgba(255,255,255,.9);color:#0f1115;font-size:12.5px;font-weight:500}",
      ".drp-qr-note{font-size:12px;line-height:1.55;color:var(--drp-fg3);max-width:280px;margin:0 auto}",
      ".drp-qr-actions{display:flex;gap:8px;flex-wrap:wrap;max-width:280px;margin:0 auto;width:100%}",
      ".drp-qr-actions .drp-btn{flex:1 1 auto}",

      /* devices */
      ".drp-devs{display:flex;flex-direction:column}",
      ".drp-dev{display:flex;align-items:center;gap:12px;padding:10px 0;border-top:1px solid var(--drp-line)}",
      ".drp-dev:first-child{border-top:0;padding-top:0}",
      ".drp-dev-main{flex:1 1 auto;min-width:0}",
      ".drp-dev-name{font-size:13px;font-weight:500;color:var(--drp-fg);overflow:hidden;",
      "text-overflow:ellipsis;white-space:nowrap}",
      ".drp-dev-meta{margin-top:1px;font-size:12px;color:var(--drp-fg3);overflow:hidden;",
      "text-overflow:ellipsis;white-space:nowrap}",
      ".drp-empty{padding:2px 0;font-size:12.5px;line-height:1.55;color:var(--drp-fg3)}",

      /* diagnostics: a compact key/value table that degrades to two lines on a
         narrow container instead of squeezing the value into an ellipsis */
      ".drp-kv{display:flex;flex-direction:column;gap:6px}",
      ".drp-kv-row{display:flex;gap:10px;align-items:baseline;font-size:12.5px;line-height:1.5}",
      ".drp-kv-k{flex:none;width:52px;color:var(--drp-fg3)}",
      ".drp-kv-v{flex:1 1 auto;min-width:0;color:var(--drp-fg2);font-variant-numeric:tabular-nums;",
      "overflow-wrap:anywhere}",
      ".drp-url-sm{font-family:var(--drp-mono);font-size:11.5px;line-height:1.55;color:var(--drp-fg2);",
      "background:var(--drp-soft);border:1px solid var(--drp-line);border-radius:8px;padding:8px 10px;",
      "overflow-wrap:anywhere;margin-top:4px}",
      ".drp-row-actions{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}",
      ".drp-notes{margin:8px 0 0;padding-left:16px;font-size:12px;line-height:1.6;color:var(--drp-fg3)}",
      ".drp-btn-sm{height:30px;padding:0 10px;font-size:12px;gap:6px}",
      /* public-access card */
      ".drp-url-mono{font-family:var(--drp-mono);font-size:11.5px}",
      ".drp-qr-small{padding:6px}",
      ".drp-qr-small .drp-qr-img{width:150px;height:150px}",
      ".drp-chip-ok{color:var(--drp-ok);border-color:rgba(34,197,94,.38);background:rgba(34,197,94,.10)}",
      ".drp-chip-wait{color:var(--dsw-alias-state-warn-primary,#f59e0b);border-color:rgba(245,158,11,.38);background:rgba(245,158,11,.10)}",
      ".drp-chip-err{color:var(--drp-err);border-color:rgba(236,19,19,.35);background:rgba(236,19,19,.08)}",
      ".drp-chip-muted{color:var(--drp-fg3)}",
      /* access log: fixed columns so rows line up like a tiny table */
      ".drp-log{display:flex;flex-direction:column;gap:2px;margin-top:2px}",
      ".drp-log-row{display:grid;grid-template-columns:40px minmax(0,1fr) auto;gap:10px;align-items:baseline;",
      "font-size:12px;line-height:1.6;padding:3px 0;border-top:1px solid var(--drp-line)}",
      ".drp-log-row:first-child{border-top:0}",
      ".drp-log-time{color:var(--drp-fg3);font-variant-numeric:tabular-nums}",
      ".drp-log-path{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;",
      "font-family:var(--drp-mono);font-size:11.5px;color:var(--drp-fg2)}",
      ".drp-log-meta{color:var(--drp-fg3);font-variant-numeric:tabular-nums;white-space:nowrap;font-size:11.5px}",
      ".drp-log-warn{color:var(--dsw-alias-state-warn-primary,#f59e0b)}",
      ".drp-log-bad{color:var(--drp-err)}",
      

      /* sidebar entry */
      /* Sidebar entry: same rhythm as the app's own footer rows (40 px tall,
         14 px label, 20 px icon box) so it does not look pasted in. */
      ".drp-nav{display:flex;align-items:center;gap:8px;width:calc(100% + 4px);min-height:44px;padding:0 10px 0 6px;margin:0 -2px;",
      "border:0;border-radius:9px;background:transparent;color:var(--drp-fg);font-family:inherit;",
      "font-size:14px;font-weight:500;letter-spacing:.01em;line-height:1.35;text-align:left;cursor:pointer;",
      "transition:background-color .12s ease,color .12s ease}",
      ".drp-nav:hover{background:rgba(127,127,127,.14)}",
      "html[data-drp-overlay-up] .drp-nav{background:rgba(127,127,127,.18);color:var(--drp-fg)}",
      ".drp-nav:focus-visible{outline:2px solid var(--drp-link);outline-offset:1px}",
      ".drp-nav .drp-ico{flex:none;width:24px;height:24px;color:var(--drp-fg3)}",
      ".drp-nav:hover .drp-ico{color:var(--drp-fg2)}",
      ".drp-nav-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}",

      /* overlay sheet (shell.overlay): the host's overlay layer is
         pointer-events:none, so the root re-enables them for our sheet. */
      /* Frame the centre column: the panel occupies the main area, never the
         sidebar. `--drp-main-*` are set by client.js from the live geometry
         (see frameOverlay()), with a full-window fallback. */
      ".drp-overlay{position:fixed;z-index:20;display:flex;align-items:stretch;justify-content:stretch;",
      "top:var(--drp-main-top,0px);left:var(--drp-main-left,0px);right:var(--drp-main-right,0px);",
      "bottom:var(--drp-main-bottom,0px);padding:0;pointer-events:auto}",
      ".drp-scrim{position:absolute;inset:0;background:rgba(0,0,0,.45);animation:drp-fade .16s ease-out}",
      ".drp-sheet{position:relative;display:flex;flex-direction:column;width:min(720px,100%);",
      "max-height:calc(100vh - 32px);background:var(--drp-card);border:1px solid var(--drp-line);",
      "border-radius:14px;box-shadow:0 24px 64px rgba(0,0,0,.32);overflow:hidden;",
      "pointer-events:auto;animation:drp-slide .18s ease-out}",
      ".drp-sheet:focus{outline:none}",
      ".drp-sheet-body{flex:1 1 auto;min-height:0;overflow-y:auto;overscroll-behavior:contain;",
      "padding:20px 20px 24px}",
      "@keyframes drp-fade{from{opacity:0}to{opacity:1}}",
      "@keyframes drp-slide{from{opacity:.5;transform:translateX(16px)}to{opacity:1;transform:none}}",
      ".drp-x{display:inline-flex;align-items:center;justify-content:center;flex:none;width:30px;",
      "height:30px;padding:0;border:1px solid var(--drp-line);border-radius:8px;background:transparent;",
      "color:var(--drp-fg2);cursor:pointer}",
      ".drp-x:hover{background:rgba(127,127,127,.14);color:var(--drp-fg)}",
      ".drp-x:focus-visible{outline:2px solid var(--drp-link);outline-offset:2px}",
      ".drp-sheet-x{position:absolute;top:12px;right:12px;z-index:5;width:36px;height:36px;background:transparent;border:0;display:grid;place-items:center;color:var(--drp-fg2);border-radius:9px}",
      /* main-area page (the panel's home) */
      ".drp-page{height:100%;overflow-y:auto;overscroll-behavior:contain;padding:0 48px 48px}",
      ".drp-page-inner{width:100%;max-width:100%;margin:0}",
      /* The host page header: 20px/500 title, 16px supporting line. */
      ".drp-page-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;padding:28px 0 20px}",
      ".drp-page-title{margin:0;font-size:20px;font-weight:500;line-height:28px;letter-spacing:0}",
      ".drp-page-sub{margin:6px 0 0;font-size:16px;line-height:24px;color:var(--drp-fg2)}",
      /* Groups, not cards: the host uses a divider and a group label. */
      ".drp-page .drp-card{background:transparent;border:0;border-top:0.5px solid var(--drp-line);border-radius:0;padding:20px 0}",
      ".drp-page .drp-card:first-of-type{border-top:0}",
      ".drp-page .drp-card-head{margin:0 0 14px}",
      ".drp-page .drp-card-title{font-size:15px;font-weight:600;line-height:22px;letter-spacing:0}",
      ".drp-page .drp-label{font-size:13.5px;color:var(--drp-fg2);font-weight:400}",
      ".drp-page .drp-hint{font-size:13px;line-height:20px;color:var(--drp-fg3)}",
      ".drp-page .drp-input{height:36px;font-size:14px;border-radius:7px}",
      ".drp-page .drp-btn{height:34px;font-size:13.5px;border-radius:7px;padding:0 14px}",
      ".drp-page .drp-btn-sm{height:28px;font-size:12.5px}",
      ".drp-page .drp-url-box{height:36px;font-size:13px;border-radius:7px}",
      ".drp-page .drp-card-head{margin:0 0 12px;align-items:center}",
      ".drp-page .drp-card{padding:18px 0}",
      ".drp-page .drp-chip{height:22px;font-size:11.5px;padding:0 8px}",
      ".drp-page .drp-sub{font-size:15px;line-height:23px;color:var(--drp-fg2)}",
      /* Two columns when the page is wide enough, one when it is not — the same
         behaviour the host's own pages have. */
      ".drp-page .drp-grid{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:0 44px;align-items:start}",
      ".drp-span-2{grid-column:1/-1}",
      "@media (max-width:1080px){.drp-page .drp-grid{grid-template-columns:minmax(0,1fr);gap:0}}",
      ".drp-page .drp-head{padding:0 0 8px}",
      ".drp-page .drp-head-top{justify-content:flex-end}",
      /* Connection row: address left, pairing right, equal height. A flex column
         per card lets the buttons sit on the baseline instead of leaving a gap. */
      /* Two strips, not two columns: the address on its own line, then the pairing
         block laid out horizontally (code, explanation, buttons). Columns of
         unequal height are what produced the empty space this replaces. */
      ".drp-connect{display:flex;flex-direction:column;border-bottom:0.5px solid var(--drp-line)}",
      ".drp-connect > .drp-card{border-top:0;padding:14px 0}",
      ".drp-connect > .drp-card > .drp-card-head{margin:0 0 8px}",
      ".drp-connect .drp-qr{flex-direction:row;align-items:center;gap:18px;flex-wrap:wrap}",
      ".drp-connect .drp-qr-frame,.drp-connect .drp-qr-empty{max-width:112px;margin:0;flex:0 0 auto}",
      ".drp-connect .drp-qr-empty{aspect-ratio:1/1;padding:8px;font-size:11.5px}",
      ".drp-connect .drp-qr-note{flex:1 1 220px;min-width:160px;text-align:left;margin:0;font-size:12.5px;line-height:1.5}",
      ".drp-connect .drp-qr-actions{flex:0 0 auto;flex-direction:row;gap:8px;margin:0;max-width:none}",
      ".drp-connect .drp-qr-actions .drp-btn{height:32px;padding:0 12px;font-size:12.5px;flex:0 0 auto;white-space:nowrap}",
      "@media (max-width:760px){.drp-connect .drp-qr-note{flex:1 1 100%}}",
      "@media (max-width:900px){.drp-page{padding:0 20px 32px}.drp-page-head{padding:18px 0 14px}}",
      /* directory picker */
      ".drp-picker-body{display:flex;flex-direction:column;min-height:0;overflow:hidden}",
      ".drp-picker{flex:1 1 auto;min-height:0;width:100%;max-width:880px;margin:0 auto;display:flex;flex-direction:column;gap:10px}",
      ".drp-sheet-body > .drp-root{width:100%;max-width:1120px;margin:0 auto}",
      ".drp-picker-head{display:flex;align-items:center;justify-content:space-between;position:relative;min-height:40px;flex:0 0 auto}",
      ".drp-picker-title{margin:0;font-size:18px;font-weight:600;letter-spacing:-.01em}",
      ".drp-picker-path{display:flex;align-items:center;gap:8px;min-width:0;flex:0 0 auto}",
      ".drp-picker-cwd{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;",
      "font-family:var(--drp-mono);font-size:12px;color:var(--drp-fg2);background:var(--drp-soft);",
      "padding:8px 10px;border-radius:8px}",
      ".drp-picker-roots{display:flex;gap:6px;overflow-x:auto;padding-bottom:2px;flex:0 0 auto}",
      ".drp-chip-root{flex:0 0 auto;font-size:12px}",
      ".drp-picker-list{flex:1 1 auto;min-height:120px;overflow-y:auto;-webkit-overflow-scrolling:touch;flex-shrink:1;",
      "border:1px solid var(--drp-line);border-radius:10px;background:var(--drp-card)}",
      ".drp-picker-row{display:flex;align-items:center;gap:10px;width:100%;min-height:44px;padding:0 12px;",
      "background:transparent;border:0;border-bottom:1px solid var(--drp-line);color:var(--drp-fg);",
      "font-family:inherit;font-size:14px;text-align:left;cursor:pointer}",
      ".drp-picker-row:last-child{border-bottom:0}",
      ".drp-picker-row:hover{background:var(--drp-soft)}",
      ".drp-picker-row.is-hidden{opacity:.55}",
      ".drp-picker-name{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}",
      ".drp-picker-empty{padding:28px 12px;text-align:center;color:var(--drp-fg3);font-size:13px}",
      ".drp-picker-error{display:flex;align-items:center;gap:8px;color:var(--drp-err);font-size:12.5px}",
      ".drp-picker-foot{display:flex;gap:8px;align-items:center;padding-top:2px;flex:0 0 auto}",
      ".drp-picker-new{display:flex;gap:8px;align-items:center;flex:0 0 auto}",
      ".drp-picker-new-input{flex:1 1 auto;min-width:0;height:40px;font-size:16px}",
      ".drp-spacer{flex:1 1 auto}",
      /* Page, not a card: the panel replaces the view (no floating frame, no
         transparent scrim showing the chat behind it). */
      ".drp-overlay{padding:0}",
      ".drp-overlay{align-items:stretch;justify-content:flex-start}",
      ".drp-sheet{position:relative;flex:1 1 auto;width:100%;max-width:none;height:100%;max-height:none;margin:0;border-radius:0;border:0;box-shadow:none;background:var(--dsw-alias-bg-base,var(--drp-card))}",
      ".drp-sheet-x{top:8px;right:8px}",
      ".drp-sheet-x:hover{background:var(--drp-soft);color:var(--drp-fg)}",
      ".drp-sheet-x:focus{outline:none}",
      ".drp-sheet-x:focus-visible{outline:2px solid var(--drp-link);outline-offset:2px}",
      ".drp-sheet .drp-head-top{padding-right:44px}",

      /* Single column when the *panel* is narrow (container query), because the
         host's settings content column is not the viewport. display:contents
         dissolves the two wrappers so the cards can be re-ordered: address →
         QR → access → devices, which is the order a phone user needs. */
      "@container (max-width:640px){",
      ".drp-grid{display:flex;flex-direction:column;align-items:stretch;gap:12px}",
      ".drp-col{display:contents}",
      ".drp-card[data-drp='address']{order:1}",
      ".drp-card[data-drp='qr']{order:2}",
      ".drp-card[data-drp='access']{order:3}",
      ".drp-card[data-drp='devices']{order:4}",
      "}",
      "@supports not (container-type:inline-size){",
      "@media (max-width:900px){",
      ".drp-grid{display:flex;flex-direction:column;align-items:stretch;gap:12px}",
      ".drp-col{display:contents}",
      ".drp-card[data-drp='address']{order:1}",
      ".drp-card[data-drp='qr']{order:2}",
      ".drp-card[data-drp='access']{order:3}",
      ".drp-card[data-drp='devices']{order:4}",
      "}}",
      "@media (max-width:900px){",
      /* The panel is a page at every width: a settings surface, not a card
         floating over the conversation. */
      ".drp-overlay{padding:0}",
      ".drp-sheet{width:100%;max-height:100vh;max-height:100dvh;border-radius:0;border:0}",
      ".drp-sheet-body{padding:16px 14px calc(24px + env(safe-area-inset-bottom))}",
      ".drp-sheet-x{top:10px;right:10px;width:40px;height:40px}",
      ".drp-sheet .drp-head-top{padding-right:48px}",
      "}",
      "@media (max-width:640px){",
      ".drp-root{gap:12px}",
      ".drp-grid,.drp-col{gap:12px}",
      ".drp-card{padding:12px;border-radius:10px}",
      ".drp-head{gap:8px}",
      ".drp-title{font-size:16px}",
      ".drp-sub{font-size:12.5px}",
      ".drp-pill{height:24px;padding:0 9px}",
      ".drp-form{gap:10px}",
      ".drp-field{flex:1 1 100%}",
      ".drp-field-sm{flex:0 0 96px}",
      ".drp-input{height:40px;font-size:16px}",
      ".drp-btn{height:40px}",
      ".drp-btn-sm{height:32px;font-size:12px}",
      ".drp-url-box{height:40px;font-size:13px}",
      ".drp-pw-eye{height:32px;top:4px}",
      ".drp-switch{width:46px;height:26px}",
      ".drp-switch-knob{width:20px;height:20px}",
      ".drp-switch.is-on .drp-switch-knob{transform:translateX(20px)}",
      ".drp-qr-img{max-width:240px}",
      ".drp-overlay{padding:0}",
      ".drp-sheet{width:100%;max-height:100vh;max-height:100dvh;border-radius:0;border:0}",
      ".drp-sheet-body{padding:16px 14px calc(24px + env(safe-area-inset-bottom))}",
      ".drp-sheet-x{top:10px;right:10px;width:40px;height:40px}",
      ".drp-sheet .drp-head-top{padding-right:48px}",
      "}",
      "@media (prefers-reduced-motion:reduce){",
      ".drp-btn,.drp-switch,.drp-switch-knob,.drp-pill-dot{transition:none;animation:none}",
      ".drp-scrim,.drp-sheet{animation:none}",
      "}"
    ].join("");

    // ── small helpers ────────────────────────────────────────────────────────
    function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

    function merge(prev, patch) {
      var out = {};
      for (var k in prev) if (has(prev, k)) out[k] = prev[k];
      for (var k2 in patch) if (has(patch, k2)) out[k2] = patch[k2];
      return out;
    }

    /**
     * One request helper for every host route.
     * Never throws and never rejects: a failed request becomes
     * { ok:false, status, data, error } with a human-readable `error`, because an
     * unhandled rejection inside a client plugin is a hard failure for the host.
     */
    function api(path, opts) {
      opts = opts || {};
      var init = { method: opts.method || "GET", credentials: "same-origin", headers: {} };
      if (opts.body !== undefined) {
        init.headers["content-type"] = "application/json";
        try { init.body = JSON.stringify(opts.body); } catch (e) { init.body = "{}"; }
      }
      var timer = 0;
      var ctrl = null;
      try {
        if (typeof AbortController === "function") {
          ctrl = new AbortController();
          init.signal = ctrl.signal;
          timer = setTimeout(function () { try { ctrl.abort(); } catch (e) { /* ignore */ } }, opts.timeout || 12000);
        }
      } catch (e2) { ctrl = null; }

      var done = function (r) {
        if (timer) { try { clearTimeout(timer); } catch (e) { /* ignore */ } }
        return r;
      };

      var fetched;
      try {
        if (typeof fetch !== "function") throw new Error("no fetch");
        fetched = fetch(path, init);
      } catch (e3) {
        return Promise.resolve(done({ ok: false, status: 0, data: null, error: t("network") }));
      }

      return fetched.then(function (res) {
        return res.text().then(function (text) {
          var data = null;
          if (text) { try { data = JSON.parse(text); } catch (e4) { data = null; } }
          if (!res.ok) {
            var msg = (data && (data.error || data.message)) || (t("httpError") + " (" + res.status + ")");
            return { ok: false, status: res.status, data: data, error: String(msg) };
          }
          return { ok: true, status: res.status, data: data, error: null };
        });
      }, function (err) {
        var aborted = !!(err && (err.name === "AbortError" || /abort/i.test(String(err.message || ""))));
        return { ok: false, status: 0, data: null, error: aborted ? t("timeout") : t("network") };
      }).then(done, function () {
        return done({ ok: false, status: 0, data: null, error: t("network") });
      });
    }

    function isLoopbackUrl(u) {
      return /^https?:\/\/(127\.|localhost([:/]|$)|\[::1\])/i.test(String(u || ""));
    }

    /** First non-loopback URL the host reports; loopback only as a last resort. */
    function portalUrl(status) {
      if (!status) return "";
      var all = [];
      if (Array.isArray(status.lanUrls)) all = all.concat(status.lanUrls);
      if (Array.isArray(status.urls)) all = all.concat(status.urls);
      all = all.filter(function (u) { return typeof u === "string" && u.length > 0; });
      var lan = all.filter(function (u) { return !isLoopbackUrl(u); });
      return lan[0] || all[0] || "";
    }

    function toMs(v) {
      if (typeof v === "number" && isFinite(v)) return v < 1e12 ? Math.round(v * 1000) : v;
      if (typeof v === "string" && v) {
        var n = Date.parse(v);
        if (isFinite(n)) return n;
        var num = Number(v);
        if (isFinite(num) && num > 0) return num < 1e12 ? num * 1000 : num;
      }
      return 0;
    }

    function timeAgo(v) {
      var ms = toMs(v);
      if (!ms) return t("never");
      var d = Date.now() - ms;
      if (d < 0) d = 0;
      var mins = Math.floor(d / 60000);
      if (mins < 1) return t("justNow");
      if (mins < 60) return t("minAgo", { n: mins });
      var hours = Math.floor(mins / 60);
      if (hours < 24) return t("hourAgo", { n: hours });
      var days = Math.floor(hours / 24);
      if (days < 30) return t("dayAgo", { n: days });
      try { return new Date(ms).toLocaleDateString(); } catch (e) { return t("dayAgo", { n: days }); }
    }

    function mmss(sec) {
      var s = Math.max(0, Math.floor(sec));
      var m = Math.floor(s / 60);
      var r = s % 60;
      return m + ":" + (r < 10 ? "0" + r : String(r));
    }

    /** Accept both a bare Status and { status: Status } (POST /config reply). */
    function normalizeStatus(data) {
      if (!data || typeof data !== "object") return null;
      var s = (data.status && typeof data.status === "object") ? data.status : data;
      if (!("running" in s) && !("enabled" in s) && !("port" in s)) return null;
      return s;
    }

    /** Pairing replies are not fully pinned down yet: accept every plausible shape. */
    function normalizePair(data) {
      if (!data || typeof data !== "object") return null;
      var p = (data.pairing && typeof data.pairing === "object") ? data.pairing
        : (data.pair && typeof data.pair === "object") ? data.pair : data;
      var url = "";
      if (typeof p.url === "string" && p.url) url = p.url;
      else if (typeof p.pairUrl === "string" && p.pairUrl) url = p.pairUrl;
      else if (typeof p.token === "string" && p.token) {
        // ARCHITECTURE §3: the gateway redeems a pairing token at
        // GET /__portal/pair?t=… — build that link when only the token came back.
        var origin = "";
        try { origin = String(location.origin || ""); } catch (e) { origin = ""; }
        url = origin + "/__portal/pair?t=" + encodeURIComponent(p.token);
      }
      if (!url) return null;
      var exp = toMs(p.expiresAt !== undefined ? p.expiresAt : p.exp);
      if (!exp) {
        var ttl = Number(p.ttlSeconds);
        if (!isFinite(ttl) || ttl <= 0) ttl = 180;
        exp = Date.now() + ttl * 1000;
      }
      return { url: url, expiresAt: exp, label: typeof p.label === "string" ? p.label : "" };
    }

    function deviceId(d) { return d && (d.id || d.deviceId || d.key || d.fingerprint) || ""; }
    function deviceLabel(d) {
      var v = d && (d.label || d.name || d.deviceLabel || d.title);
      if (typeof v === "string" && v && v !== "device") return v;
      // Older records (or a UA the host could not classify) have no useful label;
      // derive one from the stored UA rather than showing a bare "device".
      var ua = String((d && (d.ua || d.userAgent)) || "");
      var os = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android"
        : /Windows/.test(ua) ? "Windows" : /Macintosh|Mac OS X/.test(ua) ? "macOS"
          : /Linux/.test(ua) ? "Linux" : "";
      var br = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
        : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari"
          : /curl|Wget|PowerShell|python-requests/i.test(ua) ? "CLI" : "";
      if (os && br) return os + " · " + br;
      if (os || br) return os || br;
      return typeof v === "string" && v ? v : t("devUnnamed");
    }
    function deviceIp(d) {
      var v = d && (d.ip || d.address || d.remoteAddress || d.lastIp);
      return typeof v === "string" && v ? v : "—";
    }
    function deviceSeen(d) {
      var v = d && (d.lastSeenAt || d.lastSeen || d.seenAt || d.updatedAt || d.createdAt);
      return timeAgo(v);
    }

    function copyText(text, onDone) {
      var finish = function (ok) { try { onDone(!!ok); } catch (e) { /* ignore */ } };
      try {
        if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
          navigator.clipboard.writeText(text).then(function () { finish(true); }, function () { finish(legacyCopy(text)); });
          return;
        }
      } catch (e) { /* fall through to the legacy path */ }
      finish(legacyCopy(text));
    }

    // document.execCommand is deprecated but is the only path when the page is
    // not a secure context (http://10.x.x.x is *not* secure → no async clipboard).
    function legacyCopy(text) {
      try {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.top = "-1000px";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try { ta.setSelectionRange(0, text.length); } catch (e) { /* ignore */ }
        var ok = document.execCommand("copy");
        document.body.removeChild(ta);
        return !!ok;
      } catch (e2) {
        return false;
      }
    }

    // ── overlay store ────────────────────────────────────────────────────────
    // The sidebar entry (writer) and the shell.overlay sheet (reader) live in
    // different slots, so the open/closed bit has to live at module scope.
    // No DOM heuristics: the entry opens *our own* sheet, nothing else.
    var overlayState = { open: false, listeners: [] };

    function subscribeOverlay(listener) {
      overlayState.listeners.push(listener);
      return function () {
        var i = overlayState.listeners.indexOf(listener);
        if (i >= 0) overlayState.listeners.splice(i, 1);
      };
    }

    function getOverlayOpen() { return overlayState.open; }

    function setOverlayOpen(open) {
      var next = !!open;
      if (overlayState.open === next) return;
      overlayState.open = next;
      var list = overlayState.listeners.slice();
      for (var i = 0; i < list.length; i++) {
        try { list[i](); } catch (e) { /* a listener must never break the app */ }
      }
    }

    function useOverlayOpen() {
      if (useSyncExternalStore) return useSyncExternalStore(subscribeOverlay, getOverlayOpen, getOverlayOpen);
      // React < 18 fallback: same contract, one render later.
      var pair = useState(getOverlayOpen);
      useEffect(function () {
        return subscribeOverlay(function () { pair[1](getOverlayOpen()); });
      }, []);
      return pair[0];
    }

    /**
     * Publish the centre column's box as `--drp-main-*`, so the overlay can sit
     * exactly where a main-area page would. Re-measured on resize and whenever
     * the panel opens; a hidden column falls back to the full window.
     */
    /**
     * Publish the centre column's box as `--drp-main-*`, so the overlay sits
     * exactly where a main-area page would (插件 / 自动化任务), leaving the sidebar
     * reachable. Re-measured on open and on resize; a missing column or a narrow
     * window falls back to the whole viewport.
     */
    var frameOverlay = function () {
      try {
        var root = document.documentElement;
        // The column's local class name first: a descendant `:has()` also matches
        // the outer frame, which spans the window and would defeat the framing.
        var col = document.querySelector('div[class*="centerCol"]');
        if (!col || !col.getBoundingClientRect().width) {
          col = document.querySelector('div:has(> [data-slot="main"])');
        }
        var box = col ? col.getBoundingClientRect() : null;
        var wide = window.innerWidth > 900;
        if (!box || !wide || box.width < 240) {
          root.style.removeProperty("--drp-main-top");
          root.style.removeProperty("--drp-main-left");
          root.style.removeProperty("--drp-main-right");
          root.style.removeProperty("--drp-main-bottom");
          return;
        }
        root.style.setProperty("--drp-main-top", Math.round(box.top) + "px");
        root.style.setProperty("--drp-main-left", Math.round(box.left) + "px");
        root.style.setProperty("--drp-main-right", Math.round(window.innerWidth - box.right) + "px");
        root.style.setProperty("--drp-main-bottom", Math.round(window.innerHeight - box.bottom) + "px");
      } catch (e) { /* layout is a nicety: never break the panel over it */ }
    };

    /**
     * Turn a gateway status string into a sentence.
     *
     * The gateway is language-neutral on purpose (it also feeds logs and the JSON
     * API), so the translations live here, next to the strings they replace.
     */
    function friendlyGateway(message) {
      const text = String(message || "").trim();
      if (text === "") return "";
      const upstream = /^upstream (\S+) did not answer$/i.exec(text);
      if (upstream) {
        return lang() === "zh"
          ? `连不上本机 dsh（${upstream[1]}）。它可能没在运行，或端口变了。`
          : `Cannot reach dsh at ${upstream[1]} — it may not be running, or the port changed.`;
      }
      if (/^the local listener is not running$/i.test(text)) {
        return lang() === "zh" ? "门户未在监听：先设置访问密码并启用。" : "The portal is not listening — set a password and enable it.";
      }
      return text;
    }

    // ── directory picker store ───────────────────────────────────────────────
    // The app's "add workspace" flow asks for a path. Its native picker resolves
    // paths on the *client* device, which a phone cannot use, so this plugin
    // takes the pick over (see __DSH_DIRECTORY_PICKER__ below) and answers with
    // a path on the host.
    var pickerState = { open: false, listeners: [], resolve: null, start: "" };

    function subscribePicker(listener) {
      pickerState.listeners.push(listener);
      return function () {
        var i = pickerState.listeners.indexOf(listener);
        if (i >= 0) pickerState.listeners.splice(i, 1);
      };
    }

    function getPickerOpen() { return pickerState.open; }

    function notifyPicker() {
      var list = pickerState.listeners.slice();
      for (var i = 0; i < list.length; i++) {
        try { list[i](); } catch (e) { /* a listener must never break the app */ }
      }
    }

    function finishPicker(value) {
      var resolve = pickerState.resolve;
      pickerState.resolve = null;
      pickerState.open = false;
      notifyPicker();
      if (typeof resolve === "function") {
        try { resolve(value); } catch (e) { /* ignore */ }
      }
    }

    /** @returns {Promise<string|null>} an absolute path on this host, or null. */
    function openPicker() {
      if (pickerState.open) return Promise.resolve(null);
      return new Promise(function (resolve) {
        pickerState.resolve = resolve;
        pickerState.open = true;
        notifyPicker();
      });
    }

    function usePickerOpen() {
      if (useSyncExternalStore) return useSyncExternalStore(subscribePicker, getPickerOpen, getPickerOpen);
      var pair = useState(getPickerOpen);
      useEffect(function () {
        return subscribePicker(function () { pair[1](getPickerOpen()); });
      }, []);
      return pair[0];
    }

    // ── tiny presentational pieces ───────────────────────────────────────────

    function StatusPill(props) {
      var labels = {
        running: t("pillRunning"), stopped: t("pillStopped"),
        error: t("pillError"), loading: t("pillLoading")
      };
      var tone = props.tone || "loading";
      return h("span", {
        className: "drp-pill drp-pill-" + tone,
        role: "status",
        title: t("statusLabel"),
        "aria-label": t("statusLabel") + ": " + labels[tone]
      },
        h("span", { className: "drp-pill-dot", "aria-hidden": "true" }),
        h("span", null, labels[tone]));
    }

    function Toggle(props) {
      return h("button", {
        type: "button",
        role: "switch",
        "aria-checked": props.checked ? "true" : "false",
        "aria-label": props.label,
        className: "drp-switch" + (props.checked ? " is-on" : ""),
        disabled: !!props.disabled,
        onClick: props.onClick
      }, h("span", { className: "drp-switch-knob", "aria-hidden": "true" }));
    }

    function Countdown(props) {
      var tick = useState(0);
      var setTick = tick[1];
      useEffect(function () {
        var id = setInterval(function () {
          setTick(function (n) { return n + 1; });
        }, 1000);
        return function () { try { clearInterval(id); } catch (e) { /* ignore */ } };
      }, []);
      var left = Math.max(0, Math.ceil((props.expiresAt - Date.now()) / 1000));
      return h("span", { className: "drp-chip" + (left === 0 ? " drp-chip-warn" : "") },
        left === 0 ? t("qrExpired") : t("qrLeft", { t: mmss(left) }));
    }

    // ── the settings section ─────────────────────────────────────────────────

    var INITIAL = {
      status: null,
      pollErr: null,
      loaded: false,
      busy: "",
      notice: null,
      devices: null,
      pair: null,
      nonce: 0,
      qrBroken: false,
      host: "",
      port: "",
      dirty: false,
      pwd: "",
      showPwd: false,
        copied: false,
      // Diagnostics and the access log are loaded on demand (and once on mount):
      // they change only when something actually happens, so polling them with
      // the status would be pure noise on the loopback.
      diag: null,
      log: null,
      diagBusy: false,
      // Public relay form. The token is write-only: the host never sends it back.
      tunnelUrl: "",
      tunnelToken: "",
      // Trust a self-signed relay certificate; seeded from status on first poll.
      tunnelInsecure: false,
      tunnelBusy: ""
    };

    function RemotePortalSection(props) {
      // The same component renders in two surfaces: inline in Settings, and
      // inside the shell.overlay sheet (props.sheet + props.onClose).
      var inSheet = !!(props && props.sheet);
      var isPage = !!(props && props.page);
      var stateRef = useState(INITIAL);
      var st = stateRef[0];
      var setSt = stateRef[1];

      var pairOnce = useRef(false);
      var seeded = useRef("");
      var noticeTimer = useRef(0);
      var copyTimer = useRef(0);
      // The polling effect runs once (empty deps), so it cannot close over the
      // current state. This ref is the bridge: it always points at the latest
      // state object, which is what lets applyStatus skip no-op updates.
      var stRef = useRef(st);
      stRef.current = st;

      function patch(p) { setSt(function (prev) { return merge(prev, p); }); }

      function flash(kind, text) {
        patch({ notice: { kind: kind, text: String(text == null ? "" : text) } });
        try {
          if (noticeTimer.current) clearTimeout(noticeTimer.current);
          noticeTimer.current = setTimeout(function () {
            patch({ notice: null });
          }, kind === "err" ? NOTE_MS * 2 : NOTE_MS);
        } catch (e) { /* ignore */ }
      }

      // Every mutation returns a promise that always resolves, so callers never
      // produce an unhandled rejection.
      function mintPair(silent) {
        return api(BASE + "/pair", { method: "POST", body: { ttlSeconds: 180 }, timeout: 12000 }).then(function (r) {
          if (!r.ok) {
            if (!silent) flash("err", t("pairFail") + " — " + r.error);
            return null;
          }
          var p = normalizePair(r.data);
          if (!p) {
            if (!silent) flash("err", t("pairFail"));
            return null;
          }
          patch({ pair: p, nonce: Date.now(), qrBroken: false });
          if (!silent) flash("ok", t("qrRefreshed"));
          return p;
        });
      }

      function applyStatus(data) {
        var next = normalizeStatus(data);
        if (!next) return;
        // A 3 s poll mostly reports "nothing changed". Replacing the status object
        // every tick re-renders the whole panel (twice, when the sheet and the
        // settings section are both mounted), so compare first and keep the
        // previous reference when the payload is identical.
        var sameStatus = false;
        try { sameStatus = JSON.stringify(next) === JSON.stringify(stRef.current.status); } catch (e) { sameStatus = false; }
        if (sameStatus && !stRef.current.pollErr && stRef.current.loaded) return;
        patch({ status: next, pollErr: null, loaded: true });
        // The QR card is only useful once the gateway listens; mint the first
        // pairing code without asking (the card otherwise has nothing to show).
        if (!pairOnce.current && next.running) {
          pairOnce.current = true;
          mintPair(true);
        }
      }

      function refreshStatus() {
        return api(BASE + "/status", { timeout: 8000 }).then(function (r) {
          if (!r.ok) { patch({ pollErr: r.error, loaded: true }); return; }
          applyStatus(r.data);
        });
      }

      function reloadDevices() {
        return api(BASE + "/devices", { timeout: 8000 }).then(function (r) {
          if (!r.ok) return;   // 404 here just means "status carries the list"
          var list = Array.isArray(r.data) ? r.data
            : (r.data && Array.isArray(r.data.devices)) ? r.data.devices : null;
          if (list) patch({ devices: list });
        });
      }

      // Diagnostics: one snapshot of what the gateway thinks the network looks
      // like. Loaded on mount and on demand — never polled.

      /** The last N requests that actually reached the gate. */

      // ── polling: every 3 s, paused while the tab is hidden ────────────────
      useEffect(function () {
        var alive = true;
        var timer = 0;

        function tick() {
          if (!alive) return;
          try {
            if (document.visibilityState === "hidden") return;
          } catch (e) { /* non-browser host: just poll */ }
          api(BASE + "/status", { timeout: 8000 }).then(function (r) {
            if (!alive) return;
            if (r.ok) { applyStatus(r.data); return; }
            patch({ pollErr: r.error, loaded: true });
          });
        }

        tick();
        timer = setInterval(tick, POLL_MS);

        var onVisible = function () {
          try { if (document.visibilityState === "visible") tick(); } catch (e) { /* ignore */ }
        };
        try { document.addEventListener("visibilitychange", onVisible); } catch (e2) { /* ignore */ }

        return function () {
          alive = false;
          try { clearInterval(timer); } catch (e3) { /* ignore */ }
          try { document.removeEventListener("visibilitychange", onVisible); } catch (e4) { /* ignore */ }
        };
      }, []);

      // Devices: fetch on mount and whenever the host reports a different count.
      var devCount = null;
      if (st.status) {
        if (st.status.stats && typeof st.status.stats.devices === "number") devCount = st.status.stats.devices;
        else if (Array.isArray(st.status.devices)) devCount = st.status.devices.length;
      }
      useEffect(function () { reloadDevices(); }, [devCount]);

      // Seed the bind/port inputs from the host, without ever overwriting what
      // the user is currently typing.
      useEffect(function () {
        var s = st.status;
        if (!s) return;
        if (st.dirty) return;
        var endpoint = (s.public && s.public.endpoint) || "";
        var key = String(s.bindHost || "") + "|" + String(s.port || "") + "|" + endpoint;
        if (seeded.current === key) return;
        seeded.current = key;
        patch({
          host: s.bindHost || "0.0.0.0",
          port: String(s.port || 3081),
          // The endpoint is derived from the stored URL, so it is safe (and
          // useful) to show; the token never comes back from the host.
          tunnelUrl: endpoint || st.tunnelUrl,
          tunnelInsecure: pub.insecure === undefined ? st.tunnelInsecure : !!pub.insecure
        });
      }, [st.status && st.status.bindHost, st.status && st.status.port]);

      // A fresh URL means the previous <img> failure no longer applies.
      var qrUrl = (st.pair && st.pair.url) || portalUrl(st.status) || "";
      var qrSrc = qrUrl
        ? BASE + "/qr.svg?text=" + encodeURIComponent(qrUrl) + (st.nonce ? "&v=" + st.nonce : "")
        : "";
      useEffect(function () { patch({ qrBroken: false }); }, [qrSrc]);

      useEffect(function () {
        return function () {
          try { if (noticeTimer.current) clearTimeout(noticeTimer.current); } catch (e) { /* ignore */ }
          try { if (copyTimer.current) clearTimeout(copyTimer.current); } catch (e2) { /* ignore */ }
        };
      }, []);

      // ── actions ───────────────────────────────────────────────────────────
      function onCopy() {
        var url = portalUrl(st.status);
        if (!url) return;
        copyText(url, function (ok) {
          patch({ copied: ok });
          if (!ok) { flash("err", t("copyFail")); return; }
          try {
            if (copyTimer.current) clearTimeout(copyTimer.current);
            copyTimer.current = setTimeout(function () { patch({ copied: false }); }, COPY_FEEDBACK_MS);
          } catch (e) { /* ignore */ }
        });
      }

      /** Connect to a public relay (or update the endpoint), then re-read status. */
      function onSaveTunnel() {
        var url = String(st.tunnelUrl || "").trim();
        var token = String(st.tunnelToken || "").trim();
        if (url === "") { flash("err", t("tunnelUrlRequired")); return; }
        // Accept a bare address:port — the transport is detected on connect.
    if (!/^([a-z][a-z0-9+.-]*:\/\/)?(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._~-]+)(:\d{1,5})?$/i.test(url)) {
      flash("err", t("tunnelUrlScheme"));
      return;
    }
        if (token === "" && !(st.status && st.status.public && st.status.public.configured)) {
          flash("err", t("tunnelTokenRequired"));
          return;
        }
        patch({ tunnelBusy: "save" });
        // `insecure` matches what the user ticked: a self-signed certificate cannot be
    // verified by name, so the choice travels with the endpoint.
    var tunnel = token ? { url: url, token: token } : { url: url };
    if (st.tunnelInsecure) tunnel.insecure = true;
    var body = { tunnel: tunnel };
        api(BASE + "/config", { method: "POST", body: body }).then(function (r) {
          patch({ tunnelBusy: "", tunnelToken: "" });
          if (!r.ok) { flash("err", r.error); return; }
          var n = normalizeStatus(r.data);
          if (n) applyStatus(n); else refreshStatus();
          flash("ok", t("tunnelSaved"));
        });
      }

      function onDisconnectTunnel() {
        patch({ tunnelBusy: "clear" });
        api(BASE + "/config", { method: "POST", body: { tunnel: null } }).then(function (r) {
          patch({ tunnelBusy: "", tunnelToken: "" });
          if (!r.ok) { flash("err", r.error); return; }
          var n = normalizeStatus(r.data);
          if (n) applyStatus(n); else refreshStatus();
          flash("ok", t("tunnelCleared"));
        });
      }

      function onToggleEnabled() {
        var s = st.status;
        if (!s || st.busy) return;
        var next = !s.enabled;
        patch({ busy: "cfg" });
        api(BASE + "/config", { method: "POST", body: { enabled: next } }).then(function (r) {
          patch({ busy: "" });
          if (!r.ok) { flash("err", r.error); return; }
          var n = normalizeStatus(r.data);
          if (n) applyStatus(n); else refreshStatus();
          flash("ok", next ? t("enabledOn") : t("enabledOff"));
        });
      }

      function onSaveConfig() {
        var host = String(st.host || "").trim();
        var rawPort = String(st.port || "").trim();
        if (!host) { flash("err", t("invalidHost")); return; }
        if (!/^[0-9]{1,5}$/.test(rawPort)) { flash("err", t("invalidPort")); return; }
        var port = parseInt(rawPort, 10);
        if (!(port >= 1 && port <= 65535)) { flash("err", t("invalidPort")); return; }
        patch({ busy: "cfg" });
        api(BASE + "/config", { method: "POST", body: { host: host, port: port } }).then(function (r) {
          patch({ busy: "" });
          if (!r.ok) { flash("err", r.error); return; }
          patch({ dirty: false });
          seeded.current = "";
          var n = normalizeStatus(r.data);
          if (n) applyStatus(n); else refreshStatus();
          flash("ok", t("saveOk"));
        });
      }

      function onSavePassword() {
        var pw = String(st.pwd || "");
        if (pw.length < MIN_PW) { flash("err", t("pwShort", { n: MIN_PW })); return; }
        if (st.busy) return;
        patch({ busy: "pw" });
        api(BASE + "/password", { method: "POST", body: { password: pw } }).then(function (r) {
          patch({ busy: "" });
          if (!r.ok) { flash("err", r.error); return; }
          patch({ pwd: "", showPwd: false });
          flash("ok", t("pwOk"));
          refreshStatus();
          reloadDevices();
        });
      }

      function onRevoke(id) {
        if (!id || st.busy) return;
        patch({ busy: "rev:" + id });
        api(BASE + "/devices/revoke", { method: "POST", body: { id: id } }).then(function (r) {
          patch({ busy: "" });
          if (!r.ok) { flash("err", r.error); return; }
          patch({
            devices: (st.devices || []).filter(function (d) { return deviceId(d) !== id; })
          });
          flash("ok", t("revokeOk"));
          refreshStatus();
        });
      }

      function onRefreshQr() {
        if (st.busy === "pair") return;
        patch({ busy: "pair", qrBroken: false });
        mintPair(false).then(function () { patch({ busy: "" }); });
      }

      // ── derived ───────────────────────────────────────────────────────────
      var status = st.status;
      var tone = "loading";
      if (st.pollErr && !status) tone = "error";
      else if (!st.loaded) tone = "loading";
      else if (!status) tone = "error";
      else if (status.lastError) tone = "error";
      else if (status.running || status.state === "listening") tone = "running";
      else if (status.state === "error") tone = "error";
      else tone = "stopped";

      var url = portalUrl(status);
      var loop = isLoopbackUrl(url);
      var port = (status && status.port) || 3081;
      var passwordSet = !!(status && status.passwordSet);
      var busy = st.busy;
      var devices = Array.isArray(status && status.devices) ? status.devices
        : Array.isArray(st.devices) ? st.devices : [];
      var notice = st.notice;
      var pair = st.pair;
      var expired = !!(pair && pair.expiresAt <= Date.now());

      // Notice/error stack, in priority order: "cannot reach the plugin" beats
      // "the plugin reports a bind error" beats the last action's feedback.
      var alerts = [];
      if (st.pollErr && !status) {
        alerts.push(h("div", { className: "drp-alert drp-alert-err", role: "alert", key: "poll" },
          h(Icon, { name: "alert", size: 14 }),
          h("div", null,
            h("div", null, t("statusFail")),
            h("div", { className: "drp-alert-sub" }, t("statusFailHint") + " (" + st.pollErr + ")"))));
      } else if (status && status.lastError) {
        alerts.push(h("div", { className: "drp-alert drp-alert-err", role: "alert", key: "lastError" },
          h(Icon, { name: "alert", size: 14 }),
          h("div", null,
            h("div", null, t("statusErrorTitle")),
            h("div", { className: "drp-alert-sub" }, friendlyGateway(status.lastError)))));
      }
      if (notice) {
        alerts.push(h("div", {
          className: "drp-alert " + (notice.kind === "err" ? "drp-alert-err" : "drp-alert-ok"),
          role: "alert",
          key: "notice"
        },
          h(Icon, { name: notice.kind === "err" ? "alert" : "check", size: 14 }),
          h("div", null, notice.text)));
      }

      // ── cards ─────────────────────────────────────────────────────────────
      var addrCard = h("section", { className: "drp-card", "data-drp": "address", key: "addr" },
        h("div", { className: "drp-card-head" },
          h("h3", { className: "drp-card-title" }, t("cardAddr")),
          url ? h("span", { className: "drp-chip" }, t("chipLan")) : null),
        h("div", { className: "drp-url" },
          h("div", { className: "drp-url-box", title: url || undefined },
            url ? h("span", null, url) : h("span", { className: "drp-url-empty" }, t("noUrl"))),
          h("button", {
            type: "button",
            className: "drp-btn drp-btn-ghost",
            disabled: !url,
            onClick: onCopy
          },
            h(Icon, { name: st.copied ? "check" : "copy", size: 14 }),
            h("span", null, st.copied ? t("copied") : t("copy")))),
        loop ? h("p", { className: "drp-hint drp-hint-warn" }, t("loopHint")) : null);

      // A pairing code is only meaningful while the gateway is listening: a phone
      // that scans one before that gets a dead address. Gating the card on
      // `running` (rather than presenting a code that cannot work) is the
      // difference between "the product is broken" and "set a password first".
      var canPair = !!(status && status.running);
      var pairUrl = pair && typeof pair.url === "string" ? pair.url : "";

      var qrCard = h("section", { className: "drp-card drp-qr", "data-drp": "qr", key: "qr" },
        h("div", { className: "drp-card-head" },
          h("h3", { className: "drp-card-title" }, t("cardQr")),
          canPair && pair && pair.expiresAt ? h(Countdown, { expiresAt: pair.expiresAt }) : null),
        h("div", { className: "drp-qr-frame" },
          !canPair
            ? h("div", { className: "drp-qr-empty" }, t("qrNotRunning"))
            : qrSrc && !st.qrBroken
              ? h("img", {
                  className: "drp-qr-img",
                  src: qrSrc,
                  alt: t("qrAlt"),
                  width: 216,
                  height: 216,
                  onError: function () { patch({ qrBroken: true }); }
                })
              : h("div", { className: "drp-qr-empty" }, t("qrEmpty")),
          canPair && expired ? h("div", { className: "drp-qr-veil" }, t("qrExpired")) : null),
        h("p", { className: "drp-qr-note" },
          !canPair ? t("qrNoteStopped") : (pair ? t("qrNotePair") : t("qrNotePlain"))),
        h("div", { className: "drp-qr-actions" },
          h("button", {
            type: "button",
            className: "drp-btn drp-btn-ghost",
            disabled: busy === "pair" || !canPair,
            onClick: onRefreshQr
          },
            h(Icon, { name: "refresh", size: 14 }),
            h("span", null, busy === "pair" ? t("qrRefreshing") : t("qrRefresh"))),
          // Same code, as text: for the "send it to my other laptop" path where a
          // camera is not in the loop.
          h("button", {
            type: "button",
            className: "drp-btn drp-btn-ghost",
            disabled: !canPair || !pairUrl,
            onClick: function () {
              if (!pairUrl) return;
              copyText(pairUrl, function (ok) {
                flash(ok ? "ok" : "err", ok ? t("pairLinkCopied") : t("copyFail"));
              });
            }
          },
            h(Icon, { name: "copy", size: 14 }),
            h("span", null, t("copyPairLink")))));

      var accessCard = h("section", { className: "drp-card", "data-drp": "access", key: "access" },
        h("div", { className: "drp-card-head" },
          h("h3", { className: "drp-card-title" }, t("cardAccess"))),
        h("div", { className: "drp-toggle-row" },
          h("div", { className: "drp-toggle-text" },
            h("div", { className: "drp-toggle-title" }, t("swEnable")),
            h("div", { className: "drp-toggle-note" }, t("swEnableNote"))),
          h(Toggle, {
            checked: !!(status && status.enabled),
            disabled: !!busy,
            label: t("swEnable"),
            onClick: onToggleEnabled
          })),
        h("div", { className: "drp-sub" },
          h("div", { className: "drp-form" },
            h("label", { className: "drp-field" },
              h("span", { className: "drp-label" }, t("host")),
              h("input", {
                className: "drp-input",
                type: "text",
                value: st.host,
                spellCheck: false,
                autoComplete: "off",
                inputMode: "url",
                "aria-label": t("host"),
                onChange: function (e) { patch({ host: e.target.value, dirty: true }); }
              })),
            h("label", { className: "drp-field drp-field-sm" },
              h("span", { className: "drp-label" }, t("port")),
              h("input", {
                className: "drp-input",
                type: "text",
                value: st.port,
                inputMode: "numeric",
                maxLength: 5,
                autoComplete: "off",
                "aria-label": t("port"),
                onChange: function (e) {
                  patch({ port: String(e.target.value).replace(/[^0-9]/g, "").slice(0, 5), dirty: true });
                }
              })),
            h("button", {
              type: "button",
              className: "drp-btn",
              disabled: !!busy || !st.dirty,
              onClick: onSaveConfig
            }, busy === "cfg" ? t("saving") : t("save"))),
          h("p", { className: "drp-hint" }, t("cfgNote"))),

        // password block
        h("div", { className: "drp-sub" },
          h("div", { className: "drp-card-head" },
            h("h3", { className: "drp-card-title" }, t("pwTitle")),
            h("span", { className: "drp-chip" + (passwordSet ? "" : " drp-chip-warn") },
              passwordSet ? t("pwStateSet") : t("pwStateUnset"))),
          h("p", { className: "drp-card-note" }, t("pwNote", { n: MIN_PW })),
          passwordSet ? null : h("p", { className: "drp-hint drp-hint-warn" }, t("pwWarn")),
          h("div", { className: "drp-form" },
            h("div", { className: "drp-pw" },
              h("input", {
                className: "drp-input",
                id: "drp-pw-input",
                type: st.showPwd ? "text" : "password",
                value: st.pwd,
                placeholder: t("pwPlaceholder"),
                autoComplete: "new-password",
                "aria-label": t("pwTitle"),
                onChange: function (e) { patch({ pwd: e.target.value }); }
              }),
              h("button", {
                type: "button",
                className: "drp-pw-eye",
                "aria-pressed": st.showPwd ? "true" : "false",
                "aria-label": st.showPwd ? t("pwHide") : t("pwShow"),
                onClick: function () { patch({ showPwd: !st.showPwd }); }
              }, st.showPwd ? t("pwHide") : t("pwShow"))),
            h("button", {
              type: "button",
              className: "drp-btn",
              disabled: !!busy || String(st.pwd).length < MIN_PW,
              onClick: onSavePassword
            }, busy === "pw" ? t("pwSaving") : t("pwSave"))),
          st.pwd && String(st.pwd).length < MIN_PW
            ? h("p", { className: "drp-hint drp-hint-warn" }, t("pwShort", { n: MIN_PW }))
            : null));

      var deviceRows = devices.map(function (d, i) {
        var id = deviceId(d) || ("idx-" + i);
        var revoking = busy === "rev:" + id;
        return h("div", { className: "drp-dev", key: id },
          h("div", { className: "drp-dev-main" },
            h("div", { className: "drp-dev-name", title: deviceLabel(d) }, deviceLabel(d)),
            h("div", { className: "drp-dev-meta" }, deviceIp(d) + " · " + deviceSeen(d))),
          h("button", {
            type: "button",
            className: "drp-btn drp-btn-ghost drp-btn-sm",
            disabled: !!busy,
            onClick: function () { onRevoke(deviceId(d)); }
          }, revoking ? t("revoking") : t("revoke")));
      });

      var devicesCard = h("section", { className: "drp-card", "data-drp": "devices", key: "devices" },
        h("div", { className: "drp-card-head" },
          h("h3", { className: "drp-card-title" }, t("cardDev")),
          h("span", { className: "drp-chip" }, String(devices.length))),
        devices.length === 0
          ? h("p", { className: "drp-empty" }, t("devEmpty"))
          : h("div", { className: "drp-devs" }, deviceRows));

      // ── public access through a relay ─────────────────────────────────────
      // `status.public` is the host's view: configured?, connected?, and the URL
      // visitors should use. The token is never round-tripped, so the input stays
      // empty until the user types a new one.
      var pub = (status && status.public) || { configured: false, state: "off" };
      var pubOnline = pub.state === "online" && !!pub.url;
      var pubTone = pub.state === "online" ? "ok"
        : pub.state === "connecting" || pub.state === "retrying" ? "wait"
          : pub.state === "error" ? "err" : "muted";
      var pubLabel = pub.state === "online" ? t("tunnelOnline")
        : pub.state === "connecting" ? t("tunnelConnecting")
          : pub.state === "retrying" ? t("tunnelRetrying")
            : pub.state === "error" ? t("tunnelError")
              : pub.configured ? t("tunnelOffline") : t("tunnelOff");
      var pubQr = pubOnline
        ? BASE + "/qr.svg?text=" + encodeURIComponent(pub.url) + "&size=180" + (st.nonce ? "&v=" + st.nonce : "")
        : "";

      var publicCard = h("section", { className: "drp-card", "data-drp": "public", key: "public" },
        h("div", { className: "drp-card-head" },
          h("h3", { className: "drp-card-title" }, t("cardPublic")),
          h("span", { className: "drp-chip drp-chip-" + pubTone }, pubLabel)),
        pubOnline
          ? h("div", { className: "drp-url" },
              h("div", { className: "drp-url-box drp-url-mono", title: pub.url }, pub.url),
              h("button", {
                type: "button",
                className: "drp-btn drp-btn-ghost",
                onClick: function () {
                  copyText(pub.url, function (ok) { flash(ok ? "ok" : "err", ok ? t("copied") : t("copyFail")); });
                }
              },
                h(Icon, { name: "copy", size: 14 }),
                h("span", null, t("copy"))))
          : null,
        pubOnline && pubQr
          ? h("div", { className: "drp-qr-frame drp-qr-small" },
              h("img", {
                className: "drp-qr-img",
                src: pubQr,
                alt: t("qrAlt"),
                width: 180,
                height: 180,
                onError: function () { patch({ qrBroken: true }); }
              }))
          : null,
        pub.lastError
          ? h("p", { className: "drp-hint drp-hint-warn" }, friendlyGateway(pub.lastError))
          : null,
        h("div", { className: "drp-sub" },
          h("div", { className: "drp-form" },
            h("label", { className: "drp-field" },
              h("span", { className: "drp-label" }, t("tunnelUrlLabel")),
              h("input", {
                className: "drp-input",
                type: "text",
                value: st.tunnelUrl,
                spellCheck: false,
                autoComplete: "off",
                inputMode: "url",
                placeholder: "203.0.113.10:9443",
                "aria-label": t("tunnelUrlLabel"),
                onChange: function (e) { patch({ tunnelUrl: e.target.value }); }
              })),
            h("label", { className: "drp-field" },
              h("span", { className: "drp-label" }, t("tunnelTokenLabel")),
              h("input", {
                className: "drp-input",
                type: "password",
                value: st.tunnelToken,
                autoComplete: "off",
                placeholder: pub.configured ? t("tunnelTokenKeep") : "",
                "aria-label": t("tunnelTokenLabel"),
                onChange: function (e) { patch({ tunnelToken: e.target.value }); }
              })),
            h("label", { className: "drp-check" },
              h("input", {
                type: "checkbox",
                checked: !!st.tunnelInsecure,
                onChange: function (e) { patch({ tunnelInsecure: !!e.target.checked }); }
              }),
              h("span", null, t("tunnelInsecure"))),
            h("div", { className: "drp-row-actions" },
              h("button", {
                type: "button",
                className: "drp-btn",
                disabled: !!st.tunnelBusy,
                onClick: onSaveTunnel
              }, st.tunnelBusy === "save" ? t("saving") : t("tunnelSave")),
              pub.configured
                ? h("button", {
                    type: "button",
                    className: "drp-btn drp-btn-ghost",
                    disabled: !!st.tunnelBusy,
                    onClick: onDisconnectTunnel
                  }, st.tunnelBusy === "clear" ? t("saving") : t("tunnelDisconnect"))
                : null)),
          h("p", { className: "drp-hint" }, t("tunnelNote"))));

      // ── diagnostics ───────────────────────────────────────────────────────
      // The first support question for a product like this is "why can my phone
      // not reach it", and every answer (which interface was picked, is the
      // upstream alive, is the firewall in the way) is already known to the
      // host. Showing it beats telling the user to read a log file.
      var diag = st.diag;
      var diagRows = [];
      if (diag && !diag.unreachable) {
        diagRows.push(["监听", (diag.bindHost || "?") + ":" + String(diag.port || "?")]);
        if (diag.upstream) {
          var up = diag.upstream;
          // Three states, not two: a host that has not probed its own upstream
          // yet must not be reported as broken.
          var upState = up.reachable ? " · " + t("diagOk")
            : up.reachableKnown === false ? " · " + t("diagBad")
              : " · " + t("diagUnknown");
          diagRows.push([
            "上游",
            (up.protocol || "http:") + "//" + (up.host || "?") + ":" + String(up.port || "?") + upState,
          ]);
        }
        var addrs = Array.isArray(diag.addresses) ? diag.addresses : [];
        if (addrs.length) {
          var primary = addrs.filter(function (a) { return a && a.primary; })[0];
          diagRows.push(["地址", (primary ? primary.address : addrs[0].address) + (primary && primary.iface ? " (" + primary.iface + ")" : "")]);
        }
      }

    // Diagnostics and the recent-access list were removed from the panel: the
    // page shows what a user acts on, and both cards were read-only noise.

      // ── frame ─────────────────────────────────────────────────────────────
      return h("div", {
        className: "drp-ui drp-root",
        "data-drp": "panel",
        "data-drp-sheet": inSheet ? "1" : undefined,
        "data-plugin": "dsh-remote-portal"
      },
        // No <style> child here: the stylesheet is mounted once into <head> by
        // apply() (mountBaseCss). Rendering it only inside the panel root left
        // the sidebar entry unstyled whenever the panel was closed — the entry
        // lives outside this subtree, so it saw no rules at all until a panel
        // happened to mount (which is exactly what shipped in the first build).
        h("div", { className: "drp-head" },
          // Title and status share a row (status right-aligned); the subtitle
          // owns the full width underneath, so a long sentence never pushes the
          // pill onto a line of its own on a phone.
          h("div", { className: "drp-head-top" },
            // In page mode the page header owns the title; the section keeps the pill.
            isPage ? null : h("h2", {
              className: "drp-title",
              // Only the sheet instance claims the dialog's label id, so the
              // inline section can never collide with it.
              id: inSheet ? "drp-sheet-title" : undefined
            }, t("section"))),
          isPage ? null : h("p", { className: "drp-sub" }, t("subtitle"))),

        alerts.length ? h("div", { className: "drp-alerts" }, alerts) : null,

        // First-run path: with no password the gateway deliberately refuses to
        // listen, which looks like "it is broken" unless the one required step is
        // the most visible thing on the panel. One button takes the user straight
        // to the field instead of leaving them to hunt for it.
        !passwordSet && status
          ? h("div", { className: "drp-firstrun", "data-drp": "firstrun" },
              h(Icon, { name: "alert", size: 15 }),
              h("div", { className: "drp-firstrun-text" },
                h("div", { className: "drp-firstrun-title" }, t("firstRunTitle")),
                h("div", { className: "drp-firstrun-note" }, t("firstRunNote"))),
              h("button", {
                type: "button",
                className: "drp-btn",
                onClick: function () {
                  try {
                    var el = document.getElementById("drp-pw-input");
                    if (!el) return;
                    el.scrollIntoView({ block: "center", behavior: "smooth" });
                    el.focus({ preventScroll: true });
                  } catch (e) { /* ignore */ }
                }
              }, t("firstRunCta")))
          : null,

        h("div", { className: "drp-connect" }, addrCard, qrCard),
        h("div", { className: "drp-grid" },
          accessCard,
          publicCard,
          h("div", { className: "drp-span-2" }, devicesCard)));
    }

    /** One place that turns a failed response into a sentence. */
    function pickError(r, fallbackKey) {
      var message = r && typeof r.error === "string" && r.error !== "" ? r.error : "";
      if (!message && r && r.data && typeof r.data.error === "string") message = r.data.error;
      if (r && r.data && r.data.code === "exists") return t("pickExists");
      if (!message && r && r.status === 404) message = t("pickHostOld");
      if (!message) message = t(fallbackKey || "network");
      return friendlyError(message);
    }

    // ── directory picker ─────────────────────────────────────────────────────
    // A full-screen page in the same visual language as the panel: parent chip,
    // current path, the roots, then one directory level at a time.
    function DirPicker() {
      var pair = useState({ loading: true, path: "", listing: null, error: null });
      var view = pair[0];
      var setView = pair[1];
      var createPair = useState(false);
      var creating = createPair[0];
      var setCreating = createPair[1];
      var draftPair = useState("");
      var draft = draftPair[0];
      var setDraft = draftPair[1];

      var load = function (path) {
        setView(function (prev) {
          return { loading: true, path: path || prev.path, listing: prev.listing, error: null };
        });
        var url = BASE + "/fs" + (path ? "?path=" + encodeURIComponent(path) : "");
        api(url, { timeout: 15000 }).then(function (r) {
          if (!r.ok) {
            setView(function (prev) {
              return { loading: false, path: prev.path, listing: prev.listing, error: pickError(r) };
            });
            return;
          }
          var listing = (r.data && r.data.listing) || null;
          if (listing) pickerState.start = listing.path;
          setView({ loading: false, path: listing ? listing.path : path, listing: listing, error: null });
        });
      };

      useEffect(function () { load(pickerState.start || ""); }, []);

      var create = function (rawName) {
        var name = String(rawName || "").trim();
        if (name === "") return;
        api(BASE + "/fs/mkdir", { method: "POST", body: { parent: path, name: name } }).then(function (r) {
          var folder = r.ok && r.data && r.data.created ? r.data.created : null;
          setCreating(false);
          setDraft("");
          if (!folder) {
            setView(function (prev) {
              return { loading: false, path: prev.path, listing: prev.listing, error: pickError(r, "pickMkdirFailed") };
            });
            return;
          }
          load(folder.path);
        });
      };

      useEffect(function () {
        var onKey = function (e) {
          if (!e) return;
          var key = e.key || "";
          if (key !== "Escape" && key !== "Esc" && e.keyCode !== 27) return;
          try { e.preventDefault(); e.stopPropagation(); } catch (e2) { /* ignore */ }
          finishPicker(null);
        };
        try { document.addEventListener("keydown", onKey, true); } catch (e3) { /* ignore */ }
        return function () {
          try { document.removeEventListener("keydown", onKey, true); } catch (e4) { /* ignore */ }
        };
      }, []);

      var listing = view.listing;
      var path = view.path || (listing && listing.path) || "";
      var roots = (listing && listing.roots) || [];
      var entries = (listing && listing.entries) || [];

      return h("div", { className: "drp-overlay", "data-drp-overlay": "1", "data-drp": "picker" },
        h("div", { className: "drp-ui drp-sheet", role: "dialog", "aria-modal": "true", "aria-label": t("pickTitle") },
          h("div", { className: "drp-sheet-body drp-picker-body" },
          h("div", { className: "drp-picker" },
            h("header", { className: "drp-picker-head" },
              h("h2", { className: "drp-picker-title" }, t("pickTitle")),
              h("button", {
                type: "button", className: "drp-sheet-x", "aria-label": t("close"),
                onClick: function () { finishPicker(null); }
              }, h(Icon, { name: "close", size: 16 }))),

            h("div", { className: "drp-picker-path" },
              h("button", {
                type: "button",
                className: "drp-btn drp-btn-ghost drp-btn-sm",
                disabled: !listing || !listing.parent,
                onClick: function () { if (listing && listing.parent) load(listing.parent); }
              }, h(Icon, { name: "up", size: 14 }), h("span", null, t("pickUp"))),
              h("code", { className: "drp-picker-cwd", title: path }, path || "…")),

            roots.length > 0
              ? h("div", { className: "drp-picker-roots" }, roots.map(function (root) {
                  return h("button", {
                    key: root.path,
                    type: "button",
                    className: "drp-chip drp-chip-root" + (root.path === path ? " is-on" : ""),
                    onClick: function () { load(root.path); }
                  }, root.name);
                }))
              : null,

            view.error
              ? h("div", { className: "drp-picker-error" },
                  h(Icon, { name: "alert", size: 14 }),
                  h("span", null, view.error),
                  h("button", { type: "button", className: "drp-btn drp-btn-sm", onClick: function () { load(path); } },
                    t("retry")))
              : null,

            h("div", { className: "drp-picker-list", role: "listbox", "aria-label": t("pickTitle") },
              view.loading && entries.length === 0
                ? h("div", { className: "drp-picker-empty" }, t("pickLoading"))
                : entries.length === 0 && !view.error
                  ? h("div", { className: "drp-picker-empty" }, t("pickEmpty"))
                  : entries.map(function (entry) {
                      return h("button", {
                        key: entry.path,
                        type: "button",
                        role: "option",
                        "aria-selected": false,
                        className: "drp-picker-row" + (entry.hidden ? " is-hidden" : ""),
                        title: entry.path,
                        onClick: function () { load(entry.path); }
                      },
                        h(Icon, { name: "folder", size: 16 }),
                        h("span", { className: "drp-picker-name" }, entry.name),
                        h(Icon, { name: "chevron", size: 14 }));
                    })),

            creating
              ? h("form", {
                  className: "drp-picker-new",
                  onSubmit: function (e) {
                    try { e.preventDefault(); } catch (e2) { /* ignore */ }
                    create(draft);
                  }
                },
                  h("input", {
                    className: "drp-input drp-picker-new-input",
                    type: "text",
                    value: draft,
                    autoFocus: true,
                    placeholder: t("pickNewHint"),
                    "aria-label": t("pickNew"),
                    onChange: function (e) { setDraft(e.target.value); },
                    onKeyDown: function (e) {
                      if (e && (e.key === "Escape" || e.key === "Esc")) { setCreating(false); setDraft(""); }
                    }
                  }),
                  h("button", { type: "submit", className: "drp-btn drp-btn-primary", disabled: draft.trim() === "" }, t("pickCreate")),
                  h("button", { type: "button", className: "drp-btn drp-btn-ghost", onClick: function () { setCreating(false); setDraft(""); } }, t("cancel")))
              : null,

            h("footer", { className: "drp-picker-foot" },
              h("button", {
                type: "button",
                className: "drp-btn drp-btn-ghost",
                disabled: !listing || creating,
                onClick: function () { setCreating(true); setDraft(""); }
              }, h(Icon, { name: "plus", size: 14 }), h("span", null, t("pickNew"))),
              h("span", { className: "drp-spacer" }),
              h("button", { type: "button", className: "drp-btn drp-btn-ghost", onClick: function () { finishPicker(null); } },
                t("cancel")),
              h("button", {
                type: "button",
                className: "drp-btn drp-btn-primary",
                disabled: !path || view.loading,
                onClick: function () { finishPicker(path); }
              }, t("pickUse")))))));
    }

    // ── overlay sheet (shell.overlay) ────────────────────────────────────────
    // The sidebar entry opens *our own* sheet rather than trying to drive the
    // host's Settings navigation: no DOM guessing, nothing to break on a host
    // update, and the panel is one click away from anywhere in the app.
    /** One overlay slot, two surfaces: the directory picker wins when it is up. */
    function PortalOverlayRouter() {
      var pickerOpen = usePickerOpen();
      var sheetOpen = useOverlayOpen();
      var open = pickerOpen || sheetOpen;
      useEffect(function () {
        try {
          frameOverlay();
          if (open) document.documentElement.setAttribute("data-drp-overlay-up", "");
          else document.documentElement.removeAttribute("data-drp-overlay-up");
          window.addEventListener("resize", frameOverlay);
        } catch (e) { /* ignore */ }
        return function () {
          try {
            window.removeEventListener("resize", frameOverlay);
            document.documentElement.removeAttribute("data-drp-overlay-up");
          } catch (e2) { /* ignore */ }
        };
      }, [open]);
      if (pickerOpen) return h(DirPicker, { key: "picker" });
      return h(PortalOverlay, { key: "sheet" });
    }

    function PortalSheet() {
      var sheetRef = useRef(null);
      var closeRef = useRef(null);

      useEffect(function () {
        var previous = null;
        try { previous = document.activeElement; } catch (e) { previous = null; }

        // Move focus into the sheet once it is in the DOM.
        var focusTimer = 0;
        try {
          focusTimer = setTimeout(function () {
            try {
              var target = closeRef.current || sheetRef.current;
              if (target && typeof target.focus === "function") target.focus();
            } catch (e2) { /* ignore */ }
          }, 0);
        } catch (e3) { focusTimer = 0; }

        var onKey = function (e) {
          if (!e) return;
          var key = e.key || "";
          if (key !== "Escape" && key !== "Esc" && e.keyCode !== 27) return;
          try { e.preventDefault(); e.stopPropagation(); } catch (e4) { /* ignore */ }
          setOverlayOpen(false);
        };
        try { document.addEventListener("keydown", onKey, true); } catch (e5) { /* ignore */ }

        // Freeze the page behind the sheet; restore whatever was there before.
        var prevOverflow = null;
        try {
          prevOverflow = document.body.style.overflow;
          document.body.style.overflow = "hidden";
        } catch (e6) { prevOverflow = null; }

        return function () {
          try { if (focusTimer) clearTimeout(focusTimer); } catch (e7) { /* ignore */ }
          try { document.removeEventListener("keydown", onKey, true); } catch (e8) { /* ignore */ }
          try { if (prevOverflow !== null) document.body.style.overflow = prevOverflow; } catch (e9) { /* ignore */ }
          try { if (previous && typeof previous.focus === "function") previous.focus(); } catch (e10) { /* ignore */ }
        };
      }, []);

      return h("div", { className: "drp-overlay", "data-drp-overlay": "1" },
        h("div", {
          className: "drp-scrim",
          "aria-hidden": "true",
          onClick: function () { setOverlayOpen(false); }
        }),
        h("div", {
          className: "drp-ui drp-sheet",
          role: "dialog",
          "aria-modal": "true",
          "aria-labelledby": "drp-sheet-title",
          tabIndex: -1,
          ref: sheetRef,
          "data-drp": "panel",
          "data-drp-sheet": "1"
        },
          // Outside the scroll container on purpose: on a 390 px phone the sheet
          // is full-screen, so a close button that scrolls with the content would
          // be unreachable at the bottom of a long panel.
          h("button", {
            type: "button",
            className: "drp-x drp-sheet-x",
            ref: closeRef,
            title: t("close"),
            "aria-label": t("close"),
            onClick: function () { setOverlayOpen(false); }
          }, h(Icon, { name: "close", size: 15 })),
          h("div", { className: "drp-sheet-body" },
            h(RemotePortalSection, { sheet: true }))));
    }

    function PortalOverlay() {
      var open = useOverlayOpen();
      if (!open) return null;
      return h(PortalSheet, null);
    }

    // ── sidebar footer entry ─────────────────────────────────────────────────
    // Registered in the official `sidebar.footer.action` list slot; if the host
    // has no such slot the inject() below is a no-op and the Settings section
    // remains the entry point.
    function NavEntry(props) {
      var wide = !(props && props.wide === false);
      return h("button", {
        type: "button",
        className: "drp-nav",
        "data-drp-nav": "1",
        "data-plugin": "dsh-remote-portal",
        title: t("navTitle"),
        "aria-label": t("navLabel"),
        "aria-haspopup": "dialog",
        onClick: function (e) {
          try { e.preventDefault(); } catch (err) { /* ignore */ }
          setOverlayOpen(true);
        }
      },
        h(Icon, { name: "portal", size: 16 }),
        wide ? h("span", { className: "drp-nav-label" }, t("navLabel")) : null);
    }

    // The app asks for a directory through this global when it exists (see
    // @deepseek-ai/dsh-client-ui-directory-picker-native). Registering it is the
    // supported way to replace the native picker — the paths have to resolve on
    // the host, not on whatever device opened the page.
    try {
      globalThis.__DSH_DIRECTORY_PICKER__ = {
        pick: function () { return openPicker(); }
      };
    } catch (e0) { /* ignore */ }

    // ── asset injection ──────────────────────────────────────────────────────
    // The mobile layer (assets/mobile.css + mobile.js) belongs to the whole app,
    // not to this panel, so it has to be fetched from the host route and mounted
    // once. Both tags are idempotent by data-drp, both failures are silent (404
    // when the package is installed without assets/), and both are removed by the
    // ctx.effect disposer when the plugin unloads.
    var assetsStarted = false;

    function mountAssets(ctx) {
      if (assetsStarted) return;
      assetsStarted = true;

      var tags = [];

      function mountCss() {
        try {
          if (document.querySelector('[data-drp="mobile-css"]')) return;
        } catch (e) { /* ignore */ }
        fetch(BASE + "/assets/mobile.css?v=" + CLIENT_VERSION, { credentials: "same-origin" }).then(function (res) {
          if (!res.ok) return null;
          return res.text();
        }).then(function (css) {
          if (!css || !css.length) return;
          if (document.querySelector('[data-drp="mobile-css"]')) return;
          var style = document.createElement("style");
          style.setAttribute("data-plugin", "dsh-remote-portal");
          style.setAttribute("data-drp", "mobile-css");
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
          tags.push(style);
        }).catch(function () { /* route missing or offline: stay silent */ });
      }

      function mountJs() {
        try {
          if (document.querySelector('[data-drp="mobile-js"]')) return;
        } catch (e) { /* ignore */ }
        fetch(BASE + "/assets/mobile.js?v=" + CLIENT_VERSION, { credentials: "same-origin" }).then(function (res) {
          if (!res.ok) return null;
          return res.text();
        }).then(function (js) {
          if (!js || !js.length) return;
          if (document.querySelector('[data-drp="mobile-js"]')) return;
          var script = document.createElement("script");
          script.setAttribute("data-plugin", "dsh-remote-portal");
          script.setAttribute("data-drp", "mobile-js");
          // Kept for debugging: the code is inlined so a single guarded fetch is
          // enough (the host has no CSP that would block an inline script).
          script.setAttribute("data-drp-src", BASE + "/assets/mobile.js");
          script.textContent = js;
          (document.head || document.documentElement).appendChild(script);
          tags.push(script);
        }).catch(function () { /* route missing or offline: stay silent */ });
      }

      mountCss();
      mountJs();

      var dispose = function () {
        assetsStarted = false;
        for (var i = 0; i < tags.length; i++) {
          try {
            var el = tags[i];
            if (el && el.parentNode) el.parentNode.removeChild(el);
          } catch (e) { /* ignore */ }
        }
        tags.length = 0;
      };

      try {
        if (ctx && typeof ctx.effect === "function") ctx.effect(function () { return dispose; });
      } catch (e) { /* ignore: the tags are harmless if they outlive us */ }
    }

    // ── plugin entry ─────────────────────────────────────────────────────────
    /**
     * Mount the panel stylesheet once, globally.
     *
     * The sheet and the inline section are two independent React trees, and the
     * sidebar entry is a third — a <style> rendered inside any one of them
     * disappears with that tree. One head-level element styled by every surface
     * is the only arrangement where the entry looks right before the panel has
     * ever been opened. Idempotent by marker, removed by the ctx effect.
     */
    function mountBaseCss(ctx) {
      var mount = function () {
        try {
          if (document.querySelector('[data-drp="base-css"]')) return;
          var el = document.createElement("style");
          el.setAttribute("data-plugin", "dsh-remote-portal");
          el.setAttribute("data-drp", "base-css");
          el.textContent = CSS;
          (document.head || document.documentElement).appendChild(el);
        } catch (e) { /* no document: nothing to style */ }
      };
      mount();
      try {
        if (ctx && typeof ctx.effect === "function") {
          ctx.effect(function () {
            return function () {
              try {
                var el = document.querySelector('[data-drp="base-css"]');
                if (el && el.parentNode) el.parentNode.removeChild(el);
              } catch (e) { /* ignore */ }
            };
          });
        }
      } catch (e) { /* the stylesheet is harmless if it outlives us */ }
    }

    function apply(ctx) {
      // 0) Global stylesheet first: every surface below depends on it.
      try { mountBaseCss(ctx); } catch (e) { /* never fatal */ }

      // 1) A real page in the main column, exactly like 插件 / 自动化任务.
      //
      //    The host dispatches `main` by the sidebar entry's id: registering the
      //    same id in `sidebar.panellist` (the button) and `main` (the page) is
      //    what makes it a page switch rather than an overlay — the sidebar keeps
      //    working and selecting a session or another panel closes it by itself.
      var PANEL_ID = "dsh-remote-portal";
      try {
        if (ctx && ctx.slots && typeof ctx.slots.inject === "function") {
          // The sidebar entry (the button) …
          ctx.slots.inject("sidebar.panellist", function () {
            return ctx.slots.register({
              name: "sidebar.panellist",
              id: PANEL_ID,
              order: 90,
              label: function () { return t("navLabel"); }
            }, function PanelIcon(props) {
              return h(Icon, { name: "portal", size: (props && props.size) || 18 });
            });
          });

          // … and the page it switches to.
          ctx.slots.inject("main", function () {
            return ctx.slots.register({ name: "main", key: PANEL_ID }, function PanelPage() {
              return h("div", { className: "drp-ui drp-page" },
                h("div", { className: "drp-page-inner" },
                  h("header", { className: "drp-page-head" },
                    h("div", null,
                      h("h1", { className: "drp-page-title" }, t("navLabel")),
                      h("p", { className: "drp-page-sub" }, t("subtitle")))),
                  h(RemotePortalSection, { page: true })));
            });
          });

          // The directory picker needs a surface of its own: the panel lives in
          // `main`, so the picker renders through the shell overlay slot. Without
          // this registration __DSH_DIRECTORY_PICKER__.pick() has no receiver and
          // "Add workspace" silently does nothing.
          ctx.slots.inject("shell.overlay", function () {
            return ctx.slots.register(
              { name: "shell.overlay", id: "dsh-remote-portal-picker", order: 95 },
              PortalOverlayRouter,
            );
          });
        }
      } catch (e) { /* slot absent: nothing to attach to */ }

      // 4) App-wide mobile layer.
      try { mountAssets(ctx); } catch (e) { /* never fatal */ }

      // 5) Deep link: `?panel=1` selects the panel, the same way a click would.
      //
      //    A query parameter, not a hash: the shell routes on the hash and an
      //    unknown value there stops the client tree from mounting. Selecting the
      //    sidebar entry (rather than forcing a view) keeps one navigation path:
      //    switching to 插件 or a session afterwards behaves exactly like a click.
      try {
        var params = new URLSearchParams(String(location.search || ""));
        if (params.get("panel") === "1") {
          var selectEntry = function () {
            var nav = doc().querySelectorAll("nav button, nav [role=button]");
            for (var i = 0; i < nav.length; i++) {
              if (String(nav[i].textContent || "").trim() === t("navLabel")) { nav[i].click(); return true; }
            }
            return false;
          };
          if (!selectEntry()) setTimeout(selectEntry, 900);
        }
      } catch (e) { /* no window: ignore */ }
    }

    return { inject: ["slots"], apply: apply };
  }
});
























































