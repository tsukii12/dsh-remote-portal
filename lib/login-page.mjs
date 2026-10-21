/**
 * dsh-remote-portal — lib/login-page.mjs
 *
 * The gate a phone sees before it may reach the dsh Web GUI.
 *
 * Design intent: this is the first surface a remote user meets, so it has to read
 * as a first-party DeepSeek Harness screen, not as a router admin page. Everything
 * is one self-contained document: system fonts only, inline SVG only, zero network
 * requests (even the favicon is a data: URI), no framework, no build step.
 *
 * Structure
 *   • a centred 400 px card on a calm token-tinted canvas; below 480 px the card
 *     becomes a full-height sheet with safe-area padding for notched phones
 *   • product mark + split wordmark ("DeepSeek" + HARNESS badge) echoing the shell
 *   • eyebrow, title, one line of explanation, messages, form, hint, meta footer
 *   • light / dark from the §1 token table, defined twice (`:root` and the two dark
 *     selectors) and switchable by a 3-state control (auto → light → dark) that
 *     lasts for the visit only (never stored: the desktop app has its own theme)
 *
 * Behaviour is plain HTML: the form POSTs `application/x-www-form-urlencoded` to
 * `/__portal/login`, so the gate still works with JavaScript disabled. The inline
 * script only adds the theme switch, the password reveal and the lock countdown.
 *
 * Wire contract (agreed with the gateway):
 *   fields  password | token + pairToken (same value) | next (hidden, optional)
 *   opts    { lang, brand, title, subtitle, error, info, mode, pairToken, next,
 *             lanHint, version, retryAfter }
 */

const COPY = {
  zh: {
    lang: "zh-Hans",
    altLang: "en",
    docTitle: {
      password: "登录 · DeepSeek Harness",
      pair: "确认登录 · DeepSeek Harness",
      locked: "暂时锁定 · DeepSeek Harness",
    },
    eyebrow: "远程访问",
    title: {
      password: "验证这台设备",
      pair: "确认这次登录",
      locked: "暂时无法登录",
    },
    subtitle: {
      password: "这台设备正在访问你电脑上的 DeepSeek Harness。输入访问密码即可进入工作区。",
      pair: "这条配对链接用于把新设备接入 DeepSeek Harness。确认后，这台设备将保持登录 30 天。",
      locked: "连续尝试次数过多。为保护你的工作区，这台设备已被暂时锁定。",
    },
    label: "访问密码",
    placeholder: "输入密码",
    submit: "继续",
    submitPair: "在这台设备上确认登录",
    submitLocked: "已暂时锁定",
    switchToPassword: "改用密码登录",
    errors: {
      "session-unauthorized": "登录状态已失效，请重新输入访问密码。",
      "session-expired": "登录已过期，请重新输入访问密码。",
      "pair-token": "配对码无效或已过期，请在电脑端重新生成。",
      "password-mode-disabled": "此门户只接受配对码登录。",
      "too-many-attempts": "尝试次数过多，请稍后再试。",
      generic: "登录失败，请重试。",
    },
    hint: "",
    noscript:
      "你的浏览器禁用了 JavaScript：密码登录仍可正常使用，主题切换、显示密码与倒计时不可用。",
    countdown: (n) => `请在 ${n} 秒后重试`,
    countdownNone: "请稍后重新加载此页面。",
    noscriptLocked: "锁定结束后页面会自动刷新；若浏览器禁用了 JavaScript，请稍后手动刷新。",
    pairMissing: "还没有可用的配对码，请在桌面端重新生成二维码。",
    lan: "局域网",
    theme: {
      auto: "跟随系统",
      light: "浅色",
      dark: "深色",
      change: "主题：{t}，点击切换",
      show: "显示密码",
      hide: "隐藏密码",
    },
  },
  en: {
    lang: "en",
    altLang: "zh-Hans",
    docTitle: {
      password: "Sign in · DeepSeek Harness",
      pair: "Confirm sign-in · DeepSeek Harness",
      locked: "Sign-in paused · DeepSeek Harness",
    },
    eyebrow: "Remote access",
    title: {
      password: "Verify this device",
      pair: "Confirm this sign-in",
      locked: "Sign-in paused",
    },
    subtitle: {
      password:
        "This device is reaching DeepSeek Harness on your computer. Enter the access password to continue.",
      pair: "This pairing link adds a new device to DeepSeek Harness. Approving it keeps the device signed in for 30 days.",
      locked: "Too many attempts in a row. This device is locked for a moment to protect your workspace.",
    },
    label: "Access password",
    placeholder: "Enter password",
    submit: "Continue",
    submitPair: "Authorise this device",
    submitLocked: "Temporarily locked",
    switchToPassword: "Use a password instead",
    errors: {
      "session-unauthorized": "Your session is no longer valid. Enter the access password again.",
      "session-expired": "Your session expired. Enter the access password again.",
      "pair-token": "That pairing code is invalid or expired. Generate a new one on the host.",
      "password-mode-disabled": "This portal only accepts pairing codes.",
      "too-many-attempts": "Too many attempts. Try again in a moment.",
      generic: "Sign-in failed. Try again.",
    },
    hint: "",
    noscript:
      "JavaScript is off: password sign-in still works, but the theme switch, password reveal and countdown are unavailable.",
    countdown: (n) => `Try again in ${n} s`,
    countdownNone: "Reload this page in a moment.",
    noscriptLocked: "This page reloads itself when the lock ends; with JavaScript off, reload it manually.",
    pairMissing: "No pairing code was supplied. Generate a new QR code on the desktop app.",
    lan: "LAN",
    theme: {
      auto: "Auto",
      light: "Light",
      dark: "Dark",
      change: "Theme: {t}. Click to change",
      show: "Show password",
      hide: "Hide password",
    },
  },
};

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

const escapeHtml = (value) =>
  String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");

/**
 * Only ever echo a same-origin relative path into the hidden `next` field. The
 * gateway sanitises this again server-side; this is defence in depth so a crafted
 * post-login page can never carry an off-site redirect target.
 */
function safeNext(next) {
  if (typeof next !== "string" || next.length === 0 || next.length > 2048) return "";
  if (!next.startsWith("/") || next.startsWith("//")) return "";
  if (next.includes("\\") || next.includes("://")) return "";
  if (next === "/__portal" || next.startsWith("/__portal/")) return "";
  return next;
}

/** Seconds are clamped so a hostile value cannot produce an endless countdown. */
function safeRetryAfter(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(Math.round(n), 24 * 60 * 60);
}

/**
 * "DeepSeek Harness" → name "DeepSeek" + badge "HARNESS", the same lock-up the
 * desktop sidebar uses. A brand without a space stays a single wordmark.
 */
function splitBrand(brand) {
  const text = String(brand || "DeepSeek Harness").trim();
  const cut = text.lastIndexOf(" ");
  if (cut <= 0) return { name: text, badge: "" };
  const badge = text.slice(cut + 1);
  if (!/^[A-Za-z][A-Za-z0-9.+-]{0,15}$/.test(badge)) return { name: text, badge: "" };
  return { name: text.slice(0, cut), badge: badge.toUpperCase() };
}

/* -------------------------------------------------------------------------- */
/* Icons — stroke-only, currentColor, 24×24, inline (no requests)             */
/* -------------------------------------------------------------------------- */

const ICON_ATTRS =
  'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" ' +
  'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"';

const ICONS = {
  sun: `<svg ${ICON_ATTRS}><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M18.7 5.3l-1.4 1.4M6.7 17.3l-1.4 1.4"/></svg>`,
  moon: `<svg ${ICON_ATTRS}><path d="M20 14.2A8.2 8.2 0 0 1 9.8 4a8.5 8.5 0 1 0 10.2 10.2Z"/></svg>`,
  auto: `<svg ${ICON_ATTRS}><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5a8.5 8.5 0 0 0 0 17Z" fill="currentColor" stroke="none"/></svg>`,
  eye: `<svg ${ICON_ATTRS}><path d="M2.5 12S6 6.2 12 6.2 21.5 12 21.5 12 18 17.8 12 17.8 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.9"/></svg>`,
  eyeOff: `<svg ${ICON_ATTRS}><path d="M4 4.5 20 20"/><path d="M9.6 5.1A9.6 9.6 0 0 1 12 4.9c6 0 9.5 7.1 9.5 7.1a17 17 0 0 1-3.1 4"/><path d="M6.2 7.4A16.6 16.6 0 0 0 2.5 12s3.5 7.1 9.5 7.1a9.4 9.4 0 0 0 4-.9"/><path d="M10.3 10.4a2.4 2.4 0 0 0 3.3 3.3"/></svg>`,
  alert: `<svg ${ICON_ATTRS}><circle cx="12" cy="12" r="8.75"/><path d="M12 7.6v5.1"/><path d="M12 16.2h.01"/></svg>`,
  info: `<svg ${ICON_ATTRS}><circle cx="12" cy="12" r="8.75"/><path d="M12 11v5"/><path d="M12 7.9h.01"/></svg>`,
  clock: `<svg ${ICON_ATTRS}><circle cx="12" cy="12" r="8.75"/><path d="M12 7.5V12l3 1.9"/></svg>`,
  arrow: `<svg ${ICON_ATTRS}><path d="M5 12h13"/><path d="m12.5 5.8 6.2 6.2-6.2 6.2"/></svg>`,
};

/* -------------------------------------------------------------------------- */
/* Styles                                                                     */
/* -------------------------------------------------------------------------- */

const STYLE = `
:root {
  color-scheme: light;
  /* --- §1 verified DSH tokens, light ------------------------------------- */
  --dsw-alias-bg-base: #fff;
  --dsw-alias-bg-layer-1: #fff;
  --dsw-alias-bg-layer-2: #fff;
  --dsw-alias-label-primary: #0f1115;
  --dsw-alias-label-secondary: #61666b;
  --dsw-alias-label-tertiary: #81858c;
  --dsw-alias-border-l2: #0000001a;
  --dsw-alias-button-primary-fill: #0f1115;
  --dsw-alias-label-primary-inverted: #fff;
  --dsw-alias-link: #4176e6;
  --dsw-alias-state-error-primary: #ec1313;
  --dsw-alias-state-success-primary: #22c55e;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --dsw-alias-bg-base: #151517;
    --dsw-alias-bg-layer-1: #232324;
    --dsw-alias-bg-layer-2: #2c2c2e;
    --dsw-alias-label-primary: #f9fafb;
    --dsw-alias-label-secondary: #cfd3d6;
    --dsw-alias-label-tertiary: #adb2b8;
    --dsw-alias-border-l2: #ffffff1f;
    --dsw-alias-button-primary-fill: #f9fafb;
    --dsw-alias-label-primary-inverted: #353638;
    --dsw-alias-link: #7aaaff;
    --dsw-alias-state-error-primary: #f25a5a;
    --dsw-alias-state-success-primary: #22c55e;
    --drp-canvas: #151517;
    --drp-field: var(--dsw-alias-bg-layer-2);
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --dsw-alias-bg-base: #151517;
  --dsw-alias-bg-layer-1: #232324;
  --dsw-alias-bg-layer-2: #2c2c2e;
  --dsw-alias-label-primary: #f9fafb;
  --dsw-alias-label-secondary: #cfd3d6;
  --dsw-alias-label-tertiary: #adb2b8;
  --dsw-alias-border-l2: #ffffff1f;
  --dsw-alias-button-primary-fill: #f9fafb;
  --dsw-alias-label-primary-inverted: #353638;
  --dsw-alias-link: #7aaaff;
  --dsw-alias-state-error-primary: #f25a5a;
  --dsw-alias-state-success-primary: #22c55e;
  --drp-canvas: #151517;
  --drp-field: var(--dsw-alias-bg-layer-2);
}

/* Semantic aliases. Every colour below resolves to a token above; the only
   literal values are the two page canvases, which are exactly
   color-mix(bg-base 95%, label-primary) and kept as a no-color-mix fallback. */
:root {
  --drp-canvas: #f3f3f3;
  /* color-mix(label-primary 4%, bg-base) — a 4 % ink tint of the paper surface,
     written out because a custom property cannot carry a parse-time fallback. */
  --drp-field: #f5f6f6;
  --drp-surface: var(--dsw-alias-bg-layer-1);
  --drp-ink: var(--dsw-alias-label-primary);
  --drp-ink-2: var(--dsw-alias-label-secondary);
  --drp-ink-3: var(--dsw-alias-label-tertiary);
  --drp-hairline: var(--dsw-alias-border-l2);
  --drp-primary-bg: var(--dsw-alias-button-primary-fill);
  --drp-primary-ink: var(--dsw-alias-label-primary-inverted);
  --drp-link: var(--dsw-alias-link);
  --drp-danger: var(--dsw-alias-state-error-primary);
  --drp-ok: var(--dsw-alias-state-success-primary);
  --drp-radius-card: 14px;
  --drp-radius-control: 10px;
  --drp-shadow: 0 1px 2px rgba(15, 17, 21, 0.05), 0 16px 40px -16px rgba(15, 17, 21, 0.18);
}

*, *::before, *::after { box-sizing: border-box; }

html {
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
}

body {
  margin: 0;
  min-height: 100vh;
  min-height: 100dvh;
  display: flex;
  align-items: center;
  align-items: safe center;
  justify-content: center;
  padding: max(24px, env(safe-area-inset-top)) max(20px, env(safe-area-inset-right))
    max(24px, env(safe-area-inset-bottom)) max(20px, env(safe-area-inset-left));
  background: var(--drp-canvas);
  background: color-mix(in srgb, var(--dsw-alias-bg-base) 95%, var(--dsw-alias-label-primary));
  color: var(--drp-ink);
  font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI Variable Text",
    "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans SC",
    system-ui, sans-serif;
  font-size: 15px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) body {
    --drp-shadow: 0 1px 2px rgba(0, 0, 0, 0.4), 0 24px 48px -20px rgba(0, 0, 0, 0.7);
  }
}
:root[data-theme="dark"] body {
  --drp-shadow: 0 1px 2px rgba(0, 0, 0, 0.4), 0 24px 48px -20px rgba(0, 0, 0, 0.7);
}

::selection {
  background: color-mix(in srgb, var(--drp-link) 26%, transparent);
}

/* --- card ---------------------------------------------------------------- */

.drp-card {
  width: 100%;
  max-width: 400px;
  display: flex;
  flex-direction: column;
  padding: 32px 32px 24px;
  background: var(--drp-surface);
  border: 1px solid var(--drp-hairline);
  border-radius: var(--drp-radius-card);
  box-shadow: var(--drp-shadow);
}

/* --- brand row ----------------------------------------------------------- */

.drp-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: 36px;
}
.drp-brand {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}
.drp-mark {
  display: block;
  flex: none;
  width: 30px;
  height: 30px;
}
.drp-wordmark {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  font-size: 14.5px;
  font-weight: 600;
  letter-spacing: -0.01em;
  color: var(--drp-ink);
  white-space: nowrap;
}
.drp-badge {
  padding: 2px 4px 1px;
  border: 1px solid var(--drp-hairline);
  border-radius: 4px;
  font-size: 8.5px;
  font-weight: 600;
  line-height: 1.25;
  letter-spacing: 0.13em;
  color: var(--drp-ink-2);
}

/* JS-only affordances stay hidden until the head script has run. */
.drp-theme {
  display: none;
  place-items: center;
  width: 44px;
  height: 44px;
  margin: -5px -9px -5px 0;
  border: 0;
  border-radius: var(--drp-radius-control);
  background: transparent;
  color: var(--drp-ink-3);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
html.js .drp-theme { display: grid; }
.drp-theme:hover { color: var(--drp-ink); background: color-mix(in srgb, var(--drp-ink) 6%, transparent); }
.drp-theme svg { width: 17px; height: 17px; }
.drp-theme .drp-icon { display: none; }
html[data-theme="auto"] .drp-theme .drp-icon-auto,
html[data-theme="light"] .drp-theme .drp-icon-light,
html[data-theme="dark"] .drp-theme .drp-icon-dark { display: block; }

/* --- copy ---------------------------------------------------------------- */

.drp-body { display: flex; flex-direction: column; }

.drp-eyebrow {
  display: flex;
  align-items: center;
  gap: 7px;
  margin: 26px 0 0;
  font-size: 10.5px;
  font-weight: 600;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--drp-ink-3);
}
.drp-eyebrow-alt {
  font-weight: 500;
  letter-spacing: 0.02em;
  text-transform: none;
}
.drp-dot {
  width: 3px;
  height: 3px;
  border-radius: 50%;
  background: currentColor;
  opacity: 0.55;
}

.drp-title {
  margin: 9px 0 0;
  font-size: 24px;
  line-height: 1.24;
  font-weight: 600;
  letter-spacing: -0.021em;
  color: var(--drp-ink);
  text-wrap: balance;
}
.drp-sub {
  margin: 9px 0 0;
  font-size: 14px;
  line-height: 1.62;
  color: var(--drp-ink-2);
  text-wrap: pretty;
}

/* --- messages ------------------------------------------------------------ */

.drp-alert,
.drp-note {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  margin-top: 18px;
  padding: 11px 12px;
  border-radius: var(--drp-radius-control);
  border: 1px solid var(--drp-hairline);
  background: color-mix(in srgb, var(--drp-ink) 3%, transparent);
  font-size: 13px;
  line-height: 1.5;
  color: var(--drp-ink-2);
}
.drp-alert {
  border-color: color-mix(in srgb, var(--drp-danger) 30%, transparent);
  background: color-mix(in srgb, var(--drp-danger) 6%, var(--drp-surface));
  color: var(--drp-ink);
}
.drp-alert svg,
.drp-note svg {
  flex: none;
  width: 16px;
  height: 16px;
  margin-top: 1px;
}
.drp-alert svg { color: var(--drp-danger); }
.drp-note svg { color: var(--drp-ink-3); }
.drp-alert strong {
  font-weight: 600;
}

/* --- form ---------------------------------------------------------------- */

.drp-form {
  display: flex;
  flex-direction: column;
  gap: 14px;
  margin: 22px 0 0;
}
.drp-label {
  display: block;
  margin: 0 0 7px;
  font-size: 12.5px;
  font-weight: 600;
  letter-spacing: 0.005em;
  color: var(--drp-ink);
}
.drp-field { position: relative; }

.drp-input {
  display: block;
  width: 100%;
  min-height: 48px;
  padding: 12px 14px;
  font-family: inherit;
  font-size: 16px; /* 16px keeps iOS from zooming the viewport on focus */
  line-height: 1.4;
  color: var(--drp-ink);
  background: var(--drp-field);
  border: 1px solid var(--drp-hairline);
  border-radius: var(--drp-radius-control);
  -webkit-appearance: none;
  appearance: none;
  transition: border-color 0.15s ease, background-color 0.15s ease;
}
.drp-input::placeholder { color: var(--drp-ink-3); opacity: 1; }
.drp-input:focus {
  outline: 2px solid var(--drp-link);
  outline-offset: 2px;
  border-color: var(--drp-link);
  background: var(--drp-surface);
}
.drp-input[aria-invalid="true"] { border-color: color-mix(in srgb, var(--drp-danger) 55%, transparent); }
.drp-input:disabled {
  color: var(--drp-ink-3);
  background: var(--drp-surface);
  cursor: not-allowed;
}
.drp-field .drp-input { padding-inline-end: 54px; }
.drp-field--plain .drp-input { padding-inline-end: 14px; }

.drp-reveal {
  position: absolute;
  top: 50%;
  inset-inline-end: 2px;
  transform: translateY(-50%);
  display: none;
  place-items: center;
  width: 44px;
  height: 44px;
  padding: 0;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--drp-ink-3);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
html.js .drp-reveal { display: grid; }
.drp-reveal:hover { color: var(--drp-ink); }
.drp-reveal svg { width: 18px; height: 18px; }
.drp-reveal .drp-icon { display: none; }
.drp-reveal[aria-pressed="false"] .drp-icon-show,
.drp-reveal[aria-pressed="true"] .drp-icon-hide { display: block; }

.drp-submit {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  width: 100%;
  min-height: 48px;
  padding: 12px 16px;
  font-family: inherit;
  font-size: 15px;
  font-weight: 600;
  letter-spacing: 0.005em;
  color: var(--drp-primary-ink);
  background: var(--drp-primary-bg);
  border: 1px solid transparent;
  border-radius: var(--drp-radius-control);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background-color 0.15s ease, opacity 0.15s ease;
}
.drp-submit:hover { background: color-mix(in srgb, var(--drp-primary-bg) 88%, var(--dsw-alias-bg-base)); }
.drp-submit:active { background: color-mix(in srgb, var(--drp-primary-bg) 82%, var(--dsw-alias-bg-base)); }
.drp-submit:disabled {
  color: var(--drp-ink-3);
  background: var(--drp-field);
  border-color: transparent;
  cursor: not-allowed;
}
.drp-submit:disabled:hover,
.drp-submit:disabled:active { background: var(--drp-field); }
.drp-submit svg { width: 17px; height: 17px; }
.drp-submit--pair { min-height: 52px; font-size: 15.5px; }

:where(a, button, input, [tabindex]):focus-visible {
  outline: 2px solid var(--drp-link);
  outline-offset: 2px;
}
.drp-submit:focus-visible { outline-offset: 3px; }

/* --- secondary links + hint --------------------------------------------- */

.drp-switch {
  margin: 14px 0 0;
  text-align: center;
}
.drp-switch a {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 44px;
  padding: 0 10px;
  border-radius: 8px;
  font-size: 13px;
  font-weight: 500;
  color: var(--drp-link);
  text-decoration: none;
}
.drp-switch a:hover { text-decoration: underline; text-underline-offset: 3px; }

.drp-hint {
  margin: 14px 0 0;
  font-size: 12.5px;
  line-height: 1.55;
  /* Secondary ink, not tertiary: this is actionable guidance, and 5.8:1 clears
     WCAG AA for small text where the tertiary 3.7:1 would not. */
  color: var(--drp-ink-2);
}

.drp-lock {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 14px 0 0;
  font-size: 13px;
  line-height: 1.5;
  color: var(--drp-ink-2);
}
.drp-lock svg { flex: none; width: 16px; height: 16px; color: var(--drp-ink-3); }
.drp-lock b { font-weight: 600; color: var(--drp-ink); font-variant-numeric: tabular-nums; }

.drp-noscript { margin: 16px 0 0; }

/* --- footer -------------------------------------------------------------- */

.drp-foot {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 4px 8px;
  margin: 26px 0 0;
  padding-top: 14px;
  border-top: 1px solid var(--drp-hairline);
  font-size: 11.5px;
  line-height: 1.4;
  color: var(--drp-ink-3);
}
.drp-foot-label {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.drp-mono { font-variant-numeric: tabular-nums; letter-spacing: 0.01em; }
.drp-sep { opacity: 0.5; }

.drp-sr {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0 0 0 0);
  clip-path: inset(50%);
  white-space: nowrap;
  border: 0;
}

/* --- phone: the card becomes a full-height sheet ------------------------- */

@media (max-width: 480px) {
  body {
    display: block;
    padding: 0;
    background: var(--drp-surface);
  }
  .drp-card {
    max-width: none;
    min-height: 100vh;
    min-height: 100dvh;
    padding: max(22px, calc(env(safe-area-inset-top) + 10px))
      max(22px, env(safe-area-inset-right))
      max(22px, calc(env(safe-area-inset-bottom) + 10px))
      max(22px, env(safe-area-inset-left));
    border: 0;
    border-radius: 0;
    box-shadow: none;
  }
  .drp-top { min-height: 40px; }
  .drp-mark { width: 32px; height: 32px; }
  .drp-wordmark { font-size: 15px; }
  .drp-body {
    flex: 1;
    justify-content: center;
    padding: 8px 0;
  }
  .drp-eyebrow { margin-top: 20px; }
  .drp-title { font-size: 25px; }
  .drp-sub { font-size: 14.5px; }
  .drp-foot { margin-top: 22px; }
}

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.001ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.001ms !important;
  }
}
`;

/* -------------------------------------------------------------------------- */
/* Markup pieces                                                              */
/* -------------------------------------------------------------------------- */

/** Product mark: ink tile + paper spark, matching the primary button colours. */
const WHALE_PATH = "M48.8354 10.0479C48.3232 9.79199 48.1025 10.2798 47.8032 10.5278C47.7007 10.6079 47.6143 10.7119 47.5273 10.8076C46.7793 11.624 45.9048 12.1597 44.7622 12.0957C43.0923 12 41.666 12.5356 40.4058 13.8398C40.1377 12.2319 39.2476 11.272 37.8926 10.6558C37.1836 10.3359 36.4668 10.0156 35.9702 9.31982C35.6235 8.82373 35.5293 8.27197 35.356 7.72754C35.2456 7.3999 35.1353 7.06396 34.7651 7.00781C34.3633 6.94385 34.2056 7.2876 34.0479 7.57568C33.418 8.75195 33.1733 10.0479 33.1973 11.3599C33.2524 14.312 34.4736 16.6641 36.8999 18.3359C37.1758 18.5278 37.2466 18.7197 37.1597 19C36.9946 19.5757 36.7974 20.1357 36.624 20.7119C36.5137 21.0801 36.3486 21.1597 35.9624 21C34.6309 20.4321 33.481 19.5918 32.4644 18.5757C30.7393 16.8721 29.1792 14.9917 27.2334 13.52C26.7764 13.1758 26.3193 12.856 25.8467 12.5518C23.8618 10.584 26.1069 8.96777 26.627 8.77588C27.1704 8.57568 26.8159 7.8877 25.0591 7.896C23.3022 7.90381 21.6953 8.50391 19.647 9.30371C19.3477 9.42383 19.0322 9.51172 18.7095 9.58398C16.8501 9.22363 14.9199 9.14355 12.9033 9.37598C9.10596 9.80762 6.07275 11.6396 3.84326 14.7681C1.16455 18.5278 0.53418 22.7998 1.30664 27.2559C2.11768 31.9521 4.46582 35.8398 8.07373 38.8799C11.8159 42.0322 16.1255 43.5762 21.041 43.2803C24.0269 43.104 27.3516 42.6963 31.1016 39.4561C32.0469 39.936 33.0396 40.1279 34.686 40.272C35.9546 40.3921 37.1758 40.208 38.1211 40.0078C39.6021 39.688 39.4995 38.2881 38.9639 38.0322C34.623 35.9678 35.5762 36.8081 34.71 36.1279C36.9155 33.4639 40.2402 30.6958 41.54 21.728C41.6426 21.0161 41.5557 20.5679 41.54 19.9917C41.5322 19.6396 41.6108 19.5039 42.0049 19.4639C43.0923 19.3359 44.1479 19.0317 45.1167 18.4878C47.9292 16.9199 49.064 14.3438 49.3315 11.2559C49.3711 10.7837 49.3237 10.2959 48.8354 10.0479ZM24.3262 37.8398C20.1196 34.4639 18.0791 33.3521 17.2358 33.3999C16.4482 33.4482 16.5898 34.3682 16.7632 34.9678C16.9443 35.5601 17.1812 35.9683 17.5117 36.4878C17.7402 36.832 17.8979 37.3442 17.2832 37.728C15.9282 38.584 13.5728 37.4399 13.4624 37.3838C10.7207 35.7358 8.42822 33.5601 6.81348 30.584C5.25342 27.7197 4.34766 24.6479 4.19775 21.3677C4.1582 20.5757 4.38672 20.2959 5.15869 20.1519C6.17529 19.96 7.22314 19.9199 8.23926 20.0718C12.5327 20.7119 16.1885 22.6719 19.2529 25.7759C21.002 27.5439 22.3252 29.6558 23.6885 31.7202C25.1377 33.9121 26.6978 36 28.6831 37.7119C29.3843 38.312 29.9434 38.7681 30.479 39.104C28.8643 39.2881 26.1699 39.3281 24.3262 37.8398ZM26.3433 24.6001C26.3433 24.248 26.6191 23.9678 26.9658 23.9678C27.0444 23.9678 27.1152 23.9839 27.1782 24.0078C27.2651 24.04 27.3438 24.0879 27.4067 24.1602C27.5171 24.272 27.5801 24.4321 27.5801 24.6001C27.5801 24.9521 27.3042 25.2319 26.9575 25.2319C26.6108 25.2319 26.3433 24.9521 26.3433 24.6001ZM32.6064 27.8799C32.2046 28.0479 31.8027 28.1919 31.4165 28.208C30.8179 28.2397 30.1641 27.9922 29.8096 27.688C29.2583 27.2158 28.8643 26.9521 28.6987 26.1279C28.6279 25.7759 28.6675 25.2319 28.7305 24.9199C28.8721 24.248 28.7144 23.8159 28.2495 23.4238C27.8716 23.104 27.3911 23.0161 26.8633 23.0161C26.666 23.0161 26.4849 22.9277 26.3511 22.856C26.1304 22.7441 25.9492 22.4639 26.1226 22.1201C26.1777 22.0078 26.4458 21.7358 26.5088 21.688C27.2256 21.272 28.0527 21.4077 28.8169 21.7197C29.5259 22.0161 30.0615 22.5601 30.834 23.3281C31.6216 24.2559 31.7632 24.5117 32.2124 25.208C32.5669 25.752 32.8901 26.312 33.1104 26.9521C33.2446 27.3521 33.0713 27.6802 32.6064 27.8799Z";

function markSvg() {
  // The Harness wordmark's own glyph (the favicon the app serves), inlined so the
  // login page needs no extra request and inherits the theme colour.
  return (
    `<svg class="drp-mark" viewBox="0 0 50 50" aria-hidden="true" focusable="false">` +
    `<path d="${WHALE_PATH}" fill="currentColor" fill-rule="nonzero"/></svg>`
  );
}

function brandMarkup(brand) {
  const { name, badge } = splitBrand(brand);
  return (
    `<div class="drp-brand">${markSvg()}` +
    `<span class="drp-wordmark"><span>${escapeHtml(name)}</span>` +
    (badge ? `<span class="drp-badge" aria-hidden="true">${escapeHtml(badge)}</span>` : "") +
    `</span></div>`
  );
}

function themeButton(copy) {
  const label = copy.theme;
  return (
    `<button class="drp-theme" id="drp-theme-btn" type="button" aria-label="${escapeHtml(
      label.change.replace("{t}", label.auto),
    )}">` +
    `<span class="drp-icon drp-icon-auto">${ICONS.auto}</span>` +
    `<span class="drp-icon drp-icon-light">${ICONS.sun}</span>` +
    `<span class="drp-icon drp-icon-dark">${ICONS.moon}</span>` +
    `</button>`
  );
}

/**
 * Turn a gateway error code into a sentence. The gateway speaks in codes
 * (`session-unauthorized`, `pair-token-expired`, …) because it has no locale;
 * the page is the only place that knows which language to use.
 */
function errorText(copy, error) {
  const raw = String(error || "").trim();
  if (raw === "") return "";
  const key = raw.toLowerCase().replace(/[^a-z-]/g, "");
  const table = copy.errors || {};
  if (table[key]) return table[key];
  if (/^pair-token-/.test(key)) return table["pair-token"] || raw;
  // A sentence from the gateway is already human text: leave it alone.
  if (/[\s。，]/.test(raw)) return raw;
  return table.generic || raw;
}

function messages(copy, { error, info }) {
  let html = "";
  if (error) {
    html +=
      `<div class="drp-alert" id="drp-error" role="alert">${ICONS.alert}` +
      `<div><span class="drp-sr">${escapeHtml(copy.alertSr)}</span>${escapeHtml(errorText(copy, error))}</div></div>`;
  }
  if (info) {
    html +=
      `<div class="drp-note" id="drp-info">${ICONS.info}` +
      `<div><span class="drp-sr">${escapeHtml(copy.infoSr)}</span>${escapeHtml(info)}</div></div>`;
  }
  return html;
}

function passwordForm(copy, { next, error, disabled, retryAfter }) {
  const describedBy = [error ? "drp-error" : "", "drp-hint"].filter(Boolean).join(" ");
  const countdown = retryAfter
    ? copy.countdown(`<b data-count>${retryAfter}</b>`)
    : escapeHtml(copy.countdownNone);
  return (
    `<form class="drp-form" method="post" action="__portal/login" autocomplete="on">` +
    (next ? `<input type="hidden" name="next" value="${escapeHtml(next)}">` : "") +
    `<div>` +
    `<label class="drp-label" for="drp-password">${escapeHtml(copy.label)}</label>` +
    `<div class="drp-field${disabled ? " drp-field--plain" : ""}">` +
    `<input class="drp-input" id="drp-password" name="password" type="password"` +
    ` autocomplete="current-password" placeholder="${escapeHtml(copy.placeholder)}"` +
    ` required${disabled ? " disabled" : " autofocus"} spellcheck="false"` +
    ` autocapitalize="off" autocorrect="off" aria-describedby="${describedBy}"` +
    (error ? ` aria-invalid="true"` : "") +
    `>` +
    (disabled
      ? ""
      : `<button class="drp-reveal" id="drp-reveal" type="button" aria-label="${escapeHtml(
          copy.theme.show,
        )}" aria-pressed="false">` +
        `<span class="drp-icon drp-icon-show">${ICONS.eye}</span>` +
        `<span class="drp-icon drp-icon-hide">${ICONS.eyeOff}</span>` +
        `</button>`) +
    `</div></div>` +
    `<button class="drp-submit" type="submit"${disabled ? " disabled" : ""}>` +
    `${escapeHtml(disabled ? copy.submitLocked : copy.submit)}` +
    (disabled ? "" : ICONS.arrow) +
    `</button>` +
    `</form>` +
    (disabled
      ? `<p class="drp-lock"${retryAfter ? ` id="drp-countdown" data-seconds="${retryAfter}"` : ""}>${ICONS.clock}` +
        `<span>${countdown}</span></p>` +
        `<p class="drp-hint drp-sr" id="drp-hint">${escapeHtml(copy.countdownNone)}</p>`
      : `<p class="drp-hint" id="drp-hint">${escapeHtml(copy.hint)}</p>`)
  );
}

function pairForm(copy, { pairToken, next }) {
  const token = typeof pairToken === "string" ? pairToken : "";
  const ready = token.length > 0;
  return (
    `<form class="drp-form" method="post" action="__portal/login">` +
    (next ? `<input type="hidden" name="next" value="${escapeHtml(next)}">` : "") +
    // The gateway accepts either name for the pairing secret; sending both keeps
    // the page working against either parser revision.
    (ready ? `<input type="hidden" name="token" value="${escapeHtml(token)}">` : "") +
    (ready ? `<input type="hidden" name="pairToken" value="${escapeHtml(token)}">` : "") +
    `<button class="drp-submit drp-submit--pair" type="submit"${ready ? "" : " disabled"}>` +
    `${escapeHtml(ready ? copy.submitPair : copy.submitLocked)}` +
    (ready ? ICONS.arrow : ICONS.clock) +
    `</button>` +
    `</form>` +
    `<p class="drp-switch"><a href="__portal/login?mode=password">${escapeHtml(
      copy.switchToPassword,
    )}</a></p>` +
    (ready ? "" : `<p class="drp-hint">${escapeHtml(copy.pairMissing)}</p>`)
  );
}

/* -------------------------------------------------------------------------- */
/* Document                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * @param {object} [options]
 * @param {"zh"|"en"} [options.lang]
 * @param {string} [options.brand="DeepSeek Harness"]
 * @param {string} [options.title]
 * @param {string} [options.subtitle]
 * @param {string} [options.error]       rendered in a role="alert" box
 * @param {string} [options.info]        rendered in a calm note
 * @param {"password"|"pair"|"locked"} [options.mode="password"]
 * @param {string} [options.pairToken]   enables the one-tap pairing button
 * @param {string} [options.next]        preserved POST target (same-origin only)
 * @param {string} [options.lanHint]     e.g. "10.150.23.97:3081"
 * @param {string} [options.version]     portal version shown in the footer
 * @param {number} [options.retryAfter]  seconds, for locked mode
 * @returns {string} a complete HTML document
 */
export function renderLoginPage(options = {}) {
  const opts = options || {};
  const lang = opts.lang === "en" ? "en" : "zh";
  const copy = { ...COPY[lang], alertSr: lang === "zh" ? "错误：" : "Error: ", infoSr: "" };
  const mode = opts.mode === "pair" || opts.mode === "locked" ? opts.mode : "password";

  const brand = opts.brand || "DeepSeek Harness";
  const title = opts.title || copy.title[mode];
  const subtitle = opts.subtitle || copy.subtitle[mode];
  const error = typeof opts.error === "string" && opts.error.trim() ? opts.error.trim() : "";
  const info = typeof opts.info === "string" && opts.info.trim() ? opts.info.trim() : "";
  const next = safeNext(opts.next);
  const retryAfter = mode === "locked" ? safeRetryAfter(opts.retryAfter) : 0;
  const lanHint = typeof opts.lanHint === "string" ? opts.lanHint.trim() : "";
  const version = typeof opts.version === "string" ? opts.version.trim() : "";

  const form =
    mode === "pair"
      ? pairForm(copy, { pairToken: opts.pairToken, next })
      : passwordForm(copy, { next, error, disabled: mode === "locked", retryAfter });

  const footer = [
    lanHint
      ? `<span class="drp-foot-label">${escapeHtml(copy.lan)}</span><span class="drp-mono">${escapeHtml(
          lanHint,
        )}</span>`
      : "",
    version ? `<span class="drp-mono">v${escapeHtml(version.replace(/^v/i, ""))}</span>` : "",
  ]
    .filter(Boolean)
    .join(`<span class="drp-sep" aria-hidden="true">·</span>`);

  const themeLabels = copy.theme;
  const scriptLabels = JSON.stringify({
    auto: themeLabels.auto,
    light: themeLabels.light,
    dark: themeLabels.dark,
    change: themeLabels.change,
    show: themeLabels.show,
    hide: themeLabels.hide,
  });

  return `<!doctype html>
<html lang="${copy.lang}" class="no-js" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${escapeHtml(opts.title ? `${title} · ${brand}` : copy.docTitle[mode])}</title>
<meta name="robots" content="noindex, nofollow, noarchive, nosnippet">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate, max-age=0">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#f3f3f3" id="drp-meta-light">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#151517" id="drp-meta-dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="${escapeHtml(brand)}">
<meta name="mobile-web-app-capable" content="yes">
<meta name="format-detection" content="telephone=no">
<link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20viewBox%3D%220%200%2050%2050%22%3E%3Cpath%20d%3D%22M48.8354%2010.0479C48.3232%209.79199%2048.1025%2010.2798%2047.8032%2010.5278C47.7007%2010.6079%2047.6143%2010.7119%2047.5273%2010.8076C46.7793%2011.624%2045.9048%2012.1597%2044.7622%2012.0957C43.0923%2012%2041.666%2012.5356%2040.4058%2013.8398C40.1377%2012.2319%2039.2476%2011.272%2037.8926%2010.6558C37.1836%2010.3359%2036.4668%2010.0156%2035.9702%209.31982C35.6235%208.82373%2035.5293%208.27197%2035.356%207.72754C35.2456%207.3999%2035.1353%207.06396%2034.7651%207.00781C34.3633%206.94385%2034.2056%207.2876%2034.0479%207.57568C33.418%208.75195%2033.1733%2010.0479%2033.1973%2011.3599C33.2524%2014.312%2034.4736%2016.6641%2036.8999%2018.3359C37.1758%2018.5278%2037.2466%2018.7197%2037.1597%2019C36.9946%2019.5757%2036.7974%2020.1357%2036.624%2020.7119C36.5137%2021.0801%2036.3486%2021.1597%2035.9624%2021C34.6309%2020.4321%2033.481%2019.5918%2032.4644%2018.5757C30.7393%2016.8721%2029.1792%2014.9917%2027.2334%2013.52C26.7764%2013.1758%2026.3193%2012.856%2025.8467%2012.5518C23.8618%2010.584%2026.1069%208.96777%2026.627%208.77588C27.1704%208.57568%2026.8159%207.8877%2025.0591%207.896C23.3022%207.90381%2021.6953%208.50391%2019.647%209.30371C19.3477%209.42383%2019.0322%209.51172%2018.7095%209.58398C16.8501%209.22363%2014.9199%209.14355%2012.9033%209.37598C9.10596%209.80762%206.07275%2011.6396%203.84326%2014.7681C1.16455%2018.5278%200.53418%2022.7998%201.30664%2027.2559C2.11768%2031.9521%204.46582%2035.8398%208.07373%2038.8799C11.8159%2042.0322%2016.1255%2043.5762%2021.041%2043.2803C24.0269%2043.104%2027.3516%2042.6963%2031.1016%2039.4561C32.0469%2039.936%2033.0396%2040.1279%2034.686%2040.272C35.9546%2040.3921%2037.1758%2040.208%2038.1211%2040.0078C39.6021%2039.688%2039.4995%2038.2881%2038.9639%2038.0322C34.623%2035.9678%2035.5762%2036.8081%2034.71%2036.1279C36.9155%2033.4639%2040.2402%2030.6958%2041.54%2021.728C41.6426%2021.0161%2041.5557%2020.5679%2041.54%2019.9917C41.5322%2019.6396%2041.6108%2019.5039%2042.0049%2019.4639C43.0923%2019.3359%2044.1479%2019.0317%2045.1167%2018.4878C47.9292%2016.9199%2049.064%2014.3438%2049.3315%2011.2559C49.3711%2010.7837%2049.3237%2010.2959%2048.8354%2010.0479ZM24.3262%2037.8398C20.1196%2034.4639%2018.0791%2033.3521%2017.2358%2033.3999C16.4482%2033.4482%2016.5898%2034.3682%2016.7632%2034.9678C16.9443%2035.5601%2017.1812%2035.9683%2017.5117%2036.4878C17.7402%2036.832%2017.8979%2037.3442%2017.2832%2037.728C15.9282%2038.584%2013.5728%2037.4399%2013.4624%2037.3838C10.7207%2035.7358%208.42822%2033.5601%206.81348%2030.584C5.25342%2027.7197%204.34766%2024.6479%204.19775%2021.3677C4.1582%2020.5757%204.38672%2020.2959%205.15869%2020.1519C6.17529%2019.96%207.22314%2019.9199%208.23926%2020.0718C12.5327%2020.7119%2016.1885%2022.6719%2019.2529%2025.7759C21.002%2027.5439%2022.3252%2029.6558%2023.6885%2031.7202C25.1377%2033.9121%2026.6978%2036%2028.6831%2037.7119C29.3843%2038.312%2029.9434%2038.7681%2030.479%2039.104C28.8643%2039.2881%2026.1699%2039.3281%2024.3262%2037.8398ZM26.3433%2024.6001C26.3433%2024.248%2026.6191%2023.9678%2026.9658%2023.9678C27.0444%2023.9678%2027.1152%2023.9839%2027.1782%2024.0078C27.2651%2024.04%2027.3438%2024.0879%2027.4067%2024.1602C27.5171%2024.272%2027.5801%2024.4321%2027.5801%2024.6001C27.5801%2024.9521%2027.3042%2025.2319%2026.9575%2025.2319C26.6108%2025.2319%2026.3433%2024.9521%2026.3433%2024.6001ZM32.6064%2027.8799C32.2046%2028.0479%2031.8027%2028.1919%2031.4165%2028.208C30.8179%2028.2397%2030.1641%2027.9922%2029.8096%2027.688C29.2583%2027.2158%2028.8643%2026.9521%2028.6987%2026.1279C28.6279%2025.7759%2028.6675%2025.2319%2028.7305%2024.9199C28.8721%2024.248%2028.7144%2023.8159%2028.2495%2023.4238C27.8716%2023.104%2027.3911%2023.0161%2026.8633%2023.0161C26.666%2023.0161%2026.4849%2022.9277%2026.3511%2022.856C26.1304%2022.7441%2025.9492%2022.4639%2026.1226%2022.1201C26.1777%2022.0078%2026.4458%2021.7358%2026.5088%2021.688C27.2256%2021.272%2028.0527%2021.4077%2028.8169%2021.7197C29.5259%2022.0161%2030.0615%2022.5601%2030.834%2023.3281C31.6216%2024.2559%2031.7632%2024.5117%2032.2124%2025.208C32.5669%2025.752%2032.8901%2026.312%2033.1104%2026.9521C33.2446%2027.3521%2033.0713%2027.6802%2032.6064%2027.8799Z%22%20fill%3D%22%230f1115%22%2F%3E%3C%2Fsvg%3E">
<style>${STYLE}</style>
<script>
(function () {
  var root = document.documentElement;
  var theme = "auto"; // no stored preference: follow the system
  if (theme !== "light" && theme !== "dark") theme = "auto";
  root.setAttribute("data-theme", theme);
  root.classList.remove("no-js");
  root.classList.add("js");
})();
</script>
</head>
<body>
<main class="drp-card">
  <header class="drp-top">
    ${brandMarkup(brand)}
    ${themeButton(copy)}
  </header>
  <div class="drp-body">
    <p class="drp-eyebrow"><span>${escapeHtml(copy.eyebrow)}</span></p>
    <h1 class="drp-title">${escapeHtml(title)}</h1>
    <p class="drp-sub">${escapeHtml(subtitle)}</p>
    ${messages(copy, { error, info })}
    ${form}
    <noscript><p class="drp-hint drp-noscript">${escapeHtml(
      mode === "locked" ? `${copy.noscript} ${copy.noscriptLocked}` : copy.noscript,
    )}</p></noscript>
  </div>
  <footer class="drp-foot">${footer}</footer>
</main>
<script>
(function () {
  var root = document.documentElement;
  var KEY = "drp-theme";
  var ORDER = ["auto", "light", "dark"];
  var LABELS = ${scriptLabels};
  var metaLight = document.getElementById("drp-meta-light");
  var metaDark = document.getElementById("drp-meta-dark");
  var button = document.getElementById("drp-theme-btn");

  function applyMeta(theme) {
    if (!metaLight || !metaDark) return;
    metaLight.setAttribute("media", theme === "dark" ? "not all" : theme === "light" ? "all" : "(prefers-color-scheme: light)");
    metaDark.setAttribute("media", theme === "dark" ? "all" : theme === "light" ? "not all" : "(prefers-color-scheme: dark)");
  }

  function describe(theme) {
    return LABELS.change.replace("{t}", LABELS[theme] || LABELS.auto);
  }

  function apply(theme, persist) {
    root.setAttribute("data-theme", theme);
    applyMeta(theme);
    if (button) {
      button.setAttribute("aria-label", describe(theme));
      button.setAttribute("title", LABELS[theme] || LABELS.auto);
    }
    // Intentionally not persisted: this page follows the system theme and any
    // toggle lasts only for the visit. Nothing here may change the desktop app's
    // appearance, which lives on a different origin.
  }

  apply(root.getAttribute("data-theme") || "auto", false);
  if (button) {
    button.addEventListener("click", function () {
      var current = root.getAttribute("data-theme") || "auto";
      var next = ORDER[(ORDER.indexOf(current) + 1) % ORDER.length];
      apply(next, false);
    });
  }

  // Password reveal: pure enhancement, the field is a normal password input.
  var reveal = document.getElementById("drp-reveal");
  var field = document.getElementById("drp-password");
  if (reveal && field) {
    reveal.addEventListener("click", function () {
      var show = field.type === "password";
      field.type = show ? "text" : "password";
      reveal.setAttribute("aria-pressed", show ? "true" : "false");
      reveal.setAttribute("aria-label", show ? LABELS.hide : LABELS.show);
      try { field.focus({ preventScroll: true }); } catch (e) { field.focus(); }
    });
  }

  // Lock countdown. When it expires the page reloads itself so the gateway can
  // answer with the real state instead of us guessing that the lock is over.
  var lock = document.getElementById("drp-countdown");
  if (lock) {
    var left = parseInt(lock.getAttribute("data-seconds") || "0", 10) || 0;
    var number = lock.querySelector("[data-count]");
    (function tick() {
      if (number) number.textContent = String(Math.max(0, left));
      if (left <= 0) {
        lock.setAttribute("data-expired", "true");
        window.setTimeout(function () { window.location.reload(); }, 800);
        return;
      }
      left -= 1;
      window.setTimeout(tick, 1000);
    })();
  }
})();
</script>
</body>
</html>`;
}



