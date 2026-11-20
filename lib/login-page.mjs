/**
 * yuremote — lib/login-page.mjs
 *
 * The gate a phone sees before it may reach the dsh Web GUI.
 *
 * The gate uses system fonts and same-origin brand assets, with no framework,
 * third-party requests or build step.
 *
 * Structure
 *   • a centred 400 px card on a calm token-tinted canvas; below 480 px the card
 *     becomes a full-height sheet with safe-area padding for notched phones
 *   • product mark and localized wordmark
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
      password: "登录",
      pair: "确认登录",
      locked: "暂时锁定",
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
    pairRetry: "请在桌面端重新生成二维码后再扫码。",
    submitPairMissing: "等待配对码",
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
      password: "Sign in",
      pair: "Confirm sign-in",
      locked: "Sign-in paused",
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
    pairRetry: "Generate a new QR code on the desktop app and scan it again.",
    submitPairMissing: "Waiting for a pairing code",
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
    --yuremote-canvas: #151517;
    --yuremote-field: var(--dsw-alias-bg-layer-2);
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
  --yuremote-canvas: #151517;
  --yuremote-field: var(--dsw-alias-bg-layer-2);
}

/* Semantic aliases. Every colour below resolves to a token above; the only
   literal values are the two page canvases, which are exactly
   color-mix(bg-base 95%, label-primary) and kept as a no-color-mix fallback. */
:root {
  --yuremote-canvas: #f3f3f3;
  /* color-mix(label-primary 4%, bg-base) — a 4 % ink tint of the paper surface,
     written out because a custom property cannot carry a parse-time fallback. */
  --yuremote-field: #f5f6f6;
  --yuremote-surface: var(--dsw-alias-bg-layer-1);
  --yuremote-ink: var(--dsw-alias-label-primary);
  --yuremote-ink-2: var(--dsw-alias-label-secondary);
  --yuremote-ink-3: var(--dsw-alias-label-tertiary);
  --yuremote-hairline: var(--dsw-alias-border-l2);
  --yuremote-primary-bg: var(--dsw-alias-button-primary-fill);
  --yuremote-primary-ink: var(--dsw-alias-label-primary-inverted);
  --yuremote-link: var(--dsw-alias-link);
  --yuremote-danger: var(--dsw-alias-state-error-primary);
  --yuremote-ok: var(--dsw-alias-state-success-primary);
  --yuremote-radius-card: 14px;
  --yuremote-radius-control: 10px;
  --yuremote-shadow: 0 1px 2px rgba(15, 17, 21, 0.05), 0 16px 40px -16px rgba(15, 17, 21, 0.18);
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
  background: var(--yuremote-canvas);
  background: color-mix(in srgb, var(--dsw-alias-bg-base) 95%, var(--dsw-alias-label-primary));
  color: var(--yuremote-ink);
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
    --yuremote-shadow: 0 1px 2px rgba(0, 0, 0, 0.4), 0 24px 48px -20px rgba(0, 0, 0, 0.7);
  }
}
:root[data-theme="dark"] body {
  --yuremote-shadow: 0 1px 2px rgba(0, 0, 0, 0.4), 0 24px 48px -20px rgba(0, 0, 0, 0.7);
}

::selection {
  background: color-mix(in srgb, var(--yuremote-link) 26%, transparent);
}

/* --- card ---------------------------------------------------------------- */

.yuremote-card {
  width: 100%;
  max-width: 400px;
  display: flex;
  flex-direction: column;
  padding: 32px 32px 24px;
  background: var(--yuremote-surface);
  border: 1px solid var(--yuremote-hairline);
  border-radius: var(--yuremote-radius-card);
  box-shadow: var(--yuremote-shadow);
}

/* --- brand row ----------------------------------------------------------- */

.yuremote-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: 36px;
}
.yuremote-brand {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}
.yuremote-mark {
  display: block;
  flex: none;
  width: 30px;
  height: 30px;
}
.yuremote-wordmark {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  font-size: 14.5px;
  font-weight: 600;
  letter-spacing: -0.01em;
  color: var(--yuremote-ink);
  white-space: nowrap;
}
.yuremote-badge {
  padding: 2px 4px 1px;
  border: 1px solid var(--yuremote-hairline);
  border-radius: 4px;
  font-size: 8.5px;
  font-weight: 600;
  line-height: 1.25;
  letter-spacing: 0.13em;
  color: var(--yuremote-ink-2);
}

/* JS-only affordances stay hidden until the head script has run. */
.yuremote-theme {
  display: none;
  place-items: center;
  width: 44px;
  height: 44px;
  margin: -5px -9px -5px 0;
  border: 0;
  border-radius: var(--yuremote-radius-control);
  background: transparent;
  color: var(--yuremote-ink-3);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
html.js .yuremote-theme { display: grid; }
.yuremote-theme:hover { color: var(--yuremote-ink); background: color-mix(in srgb, var(--yuremote-ink) 6%, transparent); }
.yuremote-theme svg { width: 17px; height: 17px; }
.yuremote-theme .yuremote-icon { display: none; }
html[data-theme="auto"] .yuremote-theme .yuremote-icon-auto,
html[data-theme="light"] .yuremote-theme .yuremote-icon-light,
html[data-theme="dark"] .yuremote-theme .yuremote-icon-dark { display: block; }

/* --- copy ---------------------------------------------------------------- */

.yuremote-body { display: flex; flex-direction: column; }

.yuremote-eyebrow {
  display: flex;
  align-items: center;
  gap: 7px;
  margin: 26px 0 0;
  font-size: 10.5px;
  font-weight: 600;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--yuremote-ink-3);
}
.yuremote-eyebrow-alt {
  font-weight: 500;
  letter-spacing: 0.02em;
  text-transform: none;
}
.yuremote-dot {
  width: 3px;
  height: 3px;
  border-radius: 50%;
  background: currentColor;
  opacity: 0.55;
}

.yuremote-title {
  margin: 9px 0 0;
  font-size: 24px;
  line-height: 1.24;
  font-weight: 600;
  letter-spacing: -0.021em;
  color: var(--yuremote-ink);
  text-wrap: balance;
}
.yuremote-sub {
  margin: 9px 0 0;
  font-size: 14px;
  line-height: 1.62;
  color: var(--yuremote-ink-2);
  text-wrap: pretty;
}

/* --- messages ------------------------------------------------------------ */

.yuremote-alert,
.yuremote-note {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  margin-top: 18px;
  padding: 11px 12px;
  border-radius: var(--yuremote-radius-control);
  border: 1px solid var(--yuremote-hairline);
  background: color-mix(in srgb, var(--yuremote-ink) 3%, transparent);
  font-size: 13px;
  line-height: 1.5;
  color: var(--yuremote-ink-2);
}
.yuremote-alert {
  border-color: color-mix(in srgb, var(--yuremote-danger) 30%, transparent);
  background: color-mix(in srgb, var(--yuremote-danger) 6%, var(--yuremote-surface));
  color: var(--yuremote-ink);
}
.yuremote-alert svg,
.yuremote-note svg {
  flex: none;
  width: 16px;
  height: 16px;
  margin-top: 1px;
}
.yuremote-alert svg { color: var(--yuremote-danger); }
.yuremote-note svg { color: var(--yuremote-ink-3); }
.yuremote-alert strong {
  font-weight: 600;
}

/* --- form ---------------------------------------------------------------- */

.yuremote-form {
  display: flex;
  flex-direction: column;
  gap: 14px;
  margin: 22px 0 0;
}
.yuremote-label {
  display: block;
  margin: 0 0 7px;
  font-size: 12.5px;
  font-weight: 600;
  letter-spacing: 0.005em;
  color: var(--yuremote-ink);
}
.yuremote-field { position: relative; }

.yuremote-input {
  display: block;
  width: 100%;
  min-height: 48px;
  padding: 12px 14px;
  font-family: inherit;
  font-size: 16px; /* 16px keeps iOS from zooming the viewport on focus */
  line-height: 1.4;
  color: var(--yuremote-ink);
  background: var(--yuremote-field);
  border: 1px solid var(--yuremote-hairline);
  border-radius: var(--yuremote-radius-control);
  -webkit-appearance: none;
  appearance: none;
  transition: border-color 0.15s ease, background-color 0.15s ease;
}
.yuremote-input::placeholder { color: var(--yuremote-ink-3); opacity: 1; }
.yuremote-input:focus {
  outline: 2px solid var(--yuremote-link);
  outline-offset: 2px;
  border-color: var(--yuremote-link);
  background: var(--yuremote-surface);
}
.yuremote-input[aria-invalid="true"] { border-color: color-mix(in srgb, var(--yuremote-danger) 55%, transparent); }
.yuremote-input:disabled {
  color: var(--yuremote-ink-3);
  background: var(--yuremote-surface);
  cursor: not-allowed;
}
.yuremote-field .yuremote-input { padding-inline-end: 54px; }
.yuremote-field--plain .yuremote-input { padding-inline-end: 14px; }

.yuremote-reveal {
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
  color: var(--yuremote-ink-3);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
html.js .yuremote-reveal { display: grid; }
.yuremote-reveal:hover { color: var(--yuremote-ink); }
.yuremote-reveal svg { width: 18px; height: 18px; }
.yuremote-reveal .yuremote-icon { display: none; }
.yuremote-reveal[aria-pressed="false"] .yuremote-icon-show,
.yuremote-reveal[aria-pressed="true"] .yuremote-icon-hide { display: block; }

.yuremote-submit {
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
  color: var(--yuremote-primary-ink);
  background: var(--yuremote-primary-bg);
  border: 1px solid transparent;
  border-radius: var(--yuremote-radius-control);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background-color 0.15s ease, opacity 0.15s ease;
}
.yuremote-submit:hover { background: color-mix(in srgb, var(--yuremote-primary-bg) 88%, var(--dsw-alias-bg-base)); }
.yuremote-submit:active { background: color-mix(in srgb, var(--yuremote-primary-bg) 82%, var(--dsw-alias-bg-base)); }
.yuremote-submit:disabled {
  color: var(--yuremote-ink-3);
  background: var(--yuremote-field);
  border-color: transparent;
  cursor: not-allowed;
}
.yuremote-submit:disabled:hover,
.yuremote-submit:disabled:active { background: var(--yuremote-field); }
.yuremote-submit svg { width: 17px; height: 17px; }
.yuremote-submit--pair { min-height: 52px; font-size: 15.5px; }

:where(a, button, input, [tabindex]):focus-visible {
  outline: 2px solid var(--yuremote-link);
  outline-offset: 2px;
}
.yuremote-submit:focus-visible { outline-offset: 3px; }

/* --- secondary links + hint --------------------------------------------- */

.yuremote-switch {
  margin: 14px 0 0;
  text-align: center;
}
.yuremote-switch a {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 44px;
  padding: 0 10px;
  border-radius: 8px;
  font-size: 13px;
  font-weight: 500;
  color: var(--yuremote-link);
  text-decoration: none;
}
.yuremote-switch a:hover { text-decoration: underline; text-underline-offset: 3px; }

.yuremote-hint {
  margin: 14px 0 0;
  font-size: 12.5px;
  line-height: 1.55;
  /* Secondary ink, not tertiary: this is actionable guidance, and 5.8:1 clears
     WCAG AA for small text where the tertiary 3.7:1 would not. */
  color: var(--yuremote-ink-2);
}

.yuremote-lock {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 14px 0 0;
  font-size: 13px;
  line-height: 1.5;
  color: var(--yuremote-ink-2);
}
.yuremote-lock svg { flex: none; width: 16px; height: 16px; color: var(--yuremote-ink-3); }
.yuremote-lock b { font-weight: 600; color: var(--yuremote-ink); font-variant-numeric: tabular-nums; }

.yuremote-noscript { margin: 16px 0 0; }

/* --- footer -------------------------------------------------------------- */

.yuremote-foot {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 4px 8px;
  margin: 26px 0 0;
  padding-top: 14px;
  border-top: 1px solid var(--yuremote-hairline);
  font-size: 11.5px;
  line-height: 1.4;
  color: var(--yuremote-ink-3);
}
.yuremote-foot-label {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.yuremote-mono { font-variant-numeric: tabular-nums; letter-spacing: 0.01em; }
.yuremote-sep { opacity: 0.5; }

.yuremote-sr {
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
    background: var(--yuremote-surface);
  }
  .yuremote-card {
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
  .yuremote-top { min-height: 40px; }
  .yuremote-mark { width: 32px; height: 32px; }
  .yuremote-wordmark { font-size: 15px; }
  .yuremote-body {
    flex: 1;
    justify-content: center;
    padding: 8px 0;
  }
  .yuremote-eyebrow { margin-top: 20px; }
  .yuremote-title { font-size: 25px; }
  .yuremote-sub { font-size: 14.5px; }
  .yuremote-foot { margin-top: 22px; }
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

function brandMarkup(brand, root) {
  const { name, badge } = splitBrand(brand);
  return (
    `<div class="yuremote-brand"><img class="yuremote-mark" src="${root}yuremote/assets/brand/yuremote-favicon.png" alt="" width="30" height="30">` +
    `<span class="yuremote-wordmark"><span>${escapeHtml(name)}</span>` +
    (badge ? `<span class="yuremote-badge" aria-hidden="true">${escapeHtml(badge)}</span>` : "") +
    `</span></div>`
  );
}

function themeButton(copy) {
  const label = copy.theme;
  return (
    `<button class="yuremote-theme" id="yuremote-theme-btn" type="button" aria-label="${escapeHtml(
      label.change.replace("{t}", label.auto),
    )}">` +
    `<span class="yuremote-icon yuremote-icon-auto">${ICONS.auto}</span>` +
    `<span class="yuremote-icon yuremote-icon-light">${ICONS.sun}</span>` +
    `<span class="yuremote-icon yuremote-icon-dark">${ICONS.moon}</span>` +
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
      `<div class="yuremote-alert" id="yuremote-error" role="alert">${ICONS.alert}` +
      `<div><span class="yuremote-sr">${escapeHtml(copy.alertSr)}</span>${escapeHtml(errorText(copy, error))}</div></div>`;
  }
  if (info) {
    html +=
      `<div class="yuremote-note" id="yuremote-info">${ICONS.info}` +
      `<div><span class="yuremote-sr">${escapeHtml(copy.infoSr)}</span>${escapeHtml(info)}</div></div>`;
  }
  return html;
}

function passwordForm(copy, { root, next, error, disabled, retryAfter }) {
  const describedBy = [error ? "yuremote-error" : "", "yuremote-hint"].filter(Boolean).join(" ");
  const countdown = retryAfter
    ? copy.countdown(`<b data-count>${retryAfter}</b>`)
    : escapeHtml(copy.countdownNone);
  return (
    `<form class="yuremote-form" method="post" action="${root}__portal/login" autocomplete="on">` +
    (next ? `<input type="hidden" name="next" value="${escapeHtml(next)}">` : "") +
    `<div>` +
    `<label class="yuremote-label" for="yuremote-password">${escapeHtml(copy.label)}</label>` +
    `<div class="yuremote-field${disabled ? " yuremote-field--plain" : ""}">` +
    `<input class="yuremote-input" id="yuremote-password" name="password" type="password"` +
    ` autocomplete="current-password" placeholder="${escapeHtml(copy.placeholder)}"` +
    ` required${disabled ? " disabled" : " autofocus"} spellcheck="false"` +
    ` autocapitalize="off" autocorrect="off" aria-describedby="${describedBy}"` +
    (error ? ` aria-invalid="true"` : "") +
    `>` +
    (disabled
      ? ""
      : `<button class="yuremote-reveal" id="yuremote-reveal" type="button" aria-label="${escapeHtml(
          copy.theme.show,
        )}" aria-pressed="false">` +
        `<span class="yuremote-icon yuremote-icon-show">${ICONS.eye}</span>` +
        `<span class="yuremote-icon yuremote-icon-hide">${ICONS.eyeOff}</span>` +
        `</button>`) +
    `</div></div>` +
    `<button class="yuremote-submit" type="submit"${disabled ? " disabled" : ""}>` +
    `${escapeHtml(disabled ? copy.submitLocked : copy.submit)}` +
    (disabled ? "" : ICONS.arrow) +
    `</button>` +
    `</form>` +
    (disabled
      ? `<p class="yuremote-lock"${retryAfter ? ` id="yuremote-countdown" data-seconds="${retryAfter}"` : ""}>${ICONS.clock}` +
        `<span>${countdown}</span></p>` +
        `<p class="yuremote-hint yuremote-sr" id="yuremote-hint">${escapeHtml(copy.countdownNone)}</p>`
      : `<p class="yuremote-hint" id="yuremote-hint">${escapeHtml(copy.hint)}</p>`)
  );
}

function pairForm(copy, { root, pairToken, next, error }) {
  const token = typeof pairToken === "string" ? pairToken : "";
  const ready = token.length > 0;
  return (
    `<form class="yuremote-form" method="post" action="${root}__portal/login">` +
    (next ? `<input type="hidden" name="next" value="${escapeHtml(next)}">` : "") +
    // The gateway accepts either name for the pairing secret; sending both keeps
    // the page working against either parser revision.
    (ready ? `<input type="hidden" name="token" value="${escapeHtml(token)}">` : "") +
    (ready ? `<input type="hidden" name="pairToken" value="${escapeHtml(token)}">` : "") +
    `<button class="yuremote-submit yuremote-submit--pair" type="submit"${ready ? "" : " disabled"}>` +
    `${escapeHtml(ready ? copy.submitPair : copy.submitPairMissing)}` +
    (ready ? ICONS.arrow : ICONS.clock) +
    `</button>` +
    `</form>` +
    `<p class="yuremote-switch"><a href="${root}__portal/login?mode=password">${escapeHtml(
      copy.switchToPassword,
    )}</a></p>` +
    // After a refused code the error already says why; "no code was supplied"
    // would contradict it.
    (ready ? "" : `<p class="yuremote-hint">${escapeHtml(error ? copy.pairRetry : copy.pairMissing)}</p>`)
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
 * @param {string} [options.root]        "../" repeated: from the served path back to the app root
 * @param {string} [options.lanHint]     e.g. "10.0.0.5:3081"
 * @param {string} [options.version]     portal version shown in the footer
 * @param {number} [options.retryAfter]  seconds, for locked mode
 * @returns {string} a complete HTML document
 */
export function renderLoginPage(options = {}) {
  const opts = options || {};
  const lang = opts.lang === "en" ? "en" : "zh";
  const copy = { ...COPY[lang], alertSr: lang === "zh" ? "错误：" : "Error: ", infoSr: "" };
  const mode = opts.mode === "pair" || opts.mode === "locked" ? opts.mode : "password";

  const brand = opts.brand || (lang === "zh" ? "鱼鱼远程" : "YuRemote");
  const title = opts.title || copy.title[mode];
  const subtitle = opts.subtitle || copy.subtitle[mode];
  const error = typeof opts.error === "string" && opts.error.trim() ? opts.error.trim() : "";
  const info = typeof opts.info === "string" && opts.info.trim() ? opts.info.trim() : "";
  const next = safeNext(opts.next);
  const retryAfter = mode === "locked" ? safeRetryAfter(opts.retryAfter) : 0;
  const lanHint = typeof opts.lanHint === "string" ? opts.lanHint.trim() : "";
  const version = typeof opts.version === "string" ? opts.version.trim() : "";
  const root = typeof opts.root === "string" && /^(?:\.\.\/)*$/.test(opts.root) ? opts.root : "";

  const form =
    mode === "pair"
      ? pairForm(copy, { root, pairToken: opts.pairToken, next, error })
      : passwordForm(copy, { root, next, error, disabled: mode === "locked", retryAfter });

  const footer = [
    lanHint
      ? `<span class="yuremote-foot-label">${escapeHtml(copy.lan)}</span><span class="yuremote-mono">${escapeHtml(
          lanHint,
        )}</span>`
      : "",
    version ? `<span class="yuremote-mono">v${escapeHtml(version.replace(/^v/i, ""))}</span>` : "",
  ]
    .filter(Boolean)
    .join(`<span class="yuremote-sep" aria-hidden="true">·</span>`);

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
<title>${escapeHtml(`${opts.title || copy.docTitle[mode]} · ${brand}`)}</title>
<meta name="robots" content="noindex, nofollow, noarchive, nosnippet">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate, max-age=0">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#f3f3f3" id="yuremote-meta-light">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#151517" id="yuremote-meta-dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="${escapeHtml(brand)}">
<meta name="mobile-web-app-capable" content="yes">
<meta name="format-detection" content="telephone=no">
<link rel="manifest" href="${root}__portal/manifest.webmanifest">
<link rel="icon" type="image/png" sizes="48x48" href="${root}yuremote/assets/brand/yuremote-favicon.png">
<link rel="apple-touch-icon" sizes="180x180" href="${root}yuremote/assets/brand/yuremote-apple-touch.png">
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
<main class="yuremote-card">
  <header class="yuremote-top">
    ${brandMarkup(brand, root)}
    ${themeButton(copy)}
  </header>
  <div class="yuremote-body">
    <p class="yuremote-eyebrow"><span>${escapeHtml(copy.eyebrow)}</span></p>
    <h1 class="yuremote-title">${escapeHtml(title)}</h1>
    <p class="yuremote-sub">${escapeHtml(subtitle)}</p>
    ${messages(copy, { error, info })}
    ${form}
    <noscript><p class="yuremote-hint yuremote-noscript">${escapeHtml(
      mode === "locked" ? `${copy.noscript} ${copy.noscriptLocked}` : copy.noscript,
    )}</p></noscript>
  </div>
  <footer class="yuremote-foot">${footer}</footer>
</main>
<script>
(function () {
  var root = document.documentElement;
  var KEY = "yuremote-theme";
  var ORDER = ["auto", "light", "dark"];
  var LABELS = ${scriptLabels};
  var metaLight = document.getElementById("yuremote-meta-light");
  var metaDark = document.getElementById("yuremote-meta-dark");
  var button = document.getElementById("yuremote-theme-btn");

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
  var reveal = document.getElementById("yuremote-reveal");
  var field = document.getElementById("yuremote-password");
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
  var lock = document.getElementById("yuremote-countdown");
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


