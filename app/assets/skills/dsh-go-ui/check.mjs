#!/usr/bin/env node
// dsh-go ui.json checker — zero dependencies, Node 18+.
//
//   node check.mjs                 checks $DSH_HOME/dsh-go/ui.json
//   node check.mjs path/to/ui.json
//   node check.mjs - < ui.json     reads stdin
//   add --json for machine-readable output
//
// It reports exactly what the dsh-go app reports: the same JSON Pointers and
// the same words, because it is a line-for-line twin of the app's validator
// (lib/ui_config/ui_config_parser.dart and ui_json_reader.dart in the app).
// Value lists and limits come from ../schema.json (or ./schema.json).
//
// Exit codes: 0 everything applies (notes allowed), 1 some items do not
// apply, 2 the whole file does not apply, 3 no file / cannot read it.

import { readFileSync, existsSync, statSync } from 'node:fs';
import { dirname, join, basename, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const schemaPath = [join(here, '..', 'schema.json'), join(here, 'schema.json')].find((p) => existsSync(p));
if (!schemaPath) {
  process.stderr.write('找不到 schema.json（应在 check.mjs 同级或上一级）\n');
  process.exit(3);
}
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
const defs = schema.$defs;
const x = schema['x-dsh-go'];
const L = x.limits;
const S = {
  version: x.version,
  maxBytes: x.maxBytes,
  maxDepth: x.maxDepth,
  headerBuiltins: defs.headerBuiltin.enum,
  icons: defs.icon.enum,
  drawerGroups: defs.drawerGroup.enum,
  drawerSorts: defs.drawerSort.enum,
  drawerFilters: defs.drawerFilter.enum,
  densities: defs.density.enum,
  hideItems: defs.hideItem.enum,
  themeModes: defs.themeMode.enum,
  accentPresets: defs.accentPreset.enum,
  petPositions: defs.petPosition.enum,
  seatModes: defs.seatMode.enum,
  pages: defs.page.enum,
  actionTypes: defs.actionType.enum,
  shortcutKeys: x.shortcutKeys,
  systemModifiers: x.systemModifiers,
  reservedShortcuts: x.reservedShortcuts,
  knownSlots: x.slots.known,
  unseatableSlots: x.slots.unseatable,
};

// ── Messages (same words as the app) ──────────────────────────────────────

const runes = (s) => [...s];
const M = {
  fileTooLarge: '文件超过 64 KiB',
  rootNotObject: '顶层必须是对象',
  versionMissing: '缺少 version',
  versionNotInt: 'version 必须是整数',
  versionTooLow: 'version 从 1 开始',
  versionTooHigh: (v) => `需要更新 App 才能使用版本 ${v}`,
  notObject: '应该是对象',
  notArray: '应该是数组',
  notString: '应该是字符串',
  notBool: '应该是 true 或 false',
  empty: '不能为空',
  unknownKey: '未知的键，已忽略',
  duplicateKey: '重复的键，只认最后一个',
  duplicateItem: '重复了，已忽略',
  missing: (k) => `缺少 ${k}`,
  truncated: (n) => `超过 ${n} 个字，已截断`,
  tooLong: (n) => `超过 ${n} 个字`,
  tooMany: (n) => `最多 ${n} 个，多出的已忽略`,
  badValue: (value, options, noun = '值') => {
    const r = runes(value);
    const shown = r.length <= 32 ? value : `${r.slice(0, 32).join('')}…`;
    const base = `不支持的${noun}「${shown}」`;
    return options.length <= 8 ? `${base}，可选：${options.join('、')}` : base;
  },
  headerItem: '应该是按钮 id 或对象',
  headerId: 'id 只能用字母、数字和 -，以小写字母开头',
  idTaken: 'id 重复',
  commandSlash: '命令名不带 /，已去掉',
  commandName: '命令名只能用字母、数字和 : . _ -',
  noNewline: '不能换行',
  httpsOnly: '只支持 https 链接',
  badUrl: '链接格式不对',
  accentFormat: '颜色要写成 #RRGGBB',
  accentBoth: '和 accentPreset 二选一，已用 accentPreset',
  petId: 'id 只能用小写字母、数字和 -',
  keysFormat: '写法不对，例如 ctrl+k',
  systemKey: '不能用系统键',
  needModifier: '要带 ctrl 或 alt',
  reserved: '被系统或输入法占用',
  duplicateShortcut: (p) => `和 ${p} 重复`,
  slotName: 'slot 名格式不对',
  unknownSlot: '当前 DSH 没有这个 slot，先保留',
  unseatableSlot: '这个位置不放插件',
  packageName: '包名格式不对',
};

// ── Strict JSON reader (twin of ui_json_reader.dart) ──────────────────────

class JNum {
  constructor(value, isInt) {
    this.value = value;
    this.isInt = isInt;
  }
}

class SyntaxErr extends Error {
  constructor(line, column, reason) {
    super(`第 ${line} 行第 ${column} 列：${reason}`);
    this.line = line;
    this.column = column;
    this.reason = reason;
  }
}

const escapeToken = (t) => t.replaceAll('~', '~0').replaceAll('/', '~1');

function readJson(s) {
  let i = 0;
  const duplicates = [];
  const fail = (at, reason) => {
    let line = 1;
    let lineStart = 0;
    for (let k = 0; k < at && k < s.length; k++) {
      if (s.charCodeAt(k) === 0x0a) {
        line++;
        lineStart = k + 1;
      }
    }
    throw new SyntaxErr(line, at - lineStart + 1, reason);
  };
  const end = () => i >= s.length;
  const c = () => s.charCodeAt(i);
  const ws = () => {
    while (!end()) {
      const ch = c();
      if (ch === 0x20 || ch === 0x09 || ch === 0x0a || ch === 0x0d) i++;
      else break;
    }
  };
  const digit = (ch) => ch >= 0x30 && ch <= 0x39;
  const startsValue = (ch) =>
    ch === 0x22 || ch === 0x7b || ch === 0x5b || ch === 0x2d || digit(ch) || ch === 0x74 || ch === 0x66 || ch === 0x6e;
  const identStart = (ch) => (ch >= 0x41 && ch <= 0x5a) || (ch >= 0x61 && ch <= 0x7a) || ch === 0x5f || ch === 0x24;

  function value(pointer, depth) {
    ws();
    if (end()) fail(i, '文件不完整');
    const ch = c();
    if (ch === 0x7b) return object(pointer, depth + 1);
    if (ch === 0x5b) return array(pointer, depth + 1);
    if (ch === 0x22) return string();
    if (ch === 0x2d || digit(ch)) return number();
    if (s.startsWith('true', i)) {
      i += 4;
      return true;
    }
    if (s.startsWith('false', i)) {
      i += 5;
      return false;
    }
    if (s.startsWith('null', i)) {
      i += 4;
      return null;
    }
    if (ch === 0x2f) fail(i, '不支持注释');
    if (ch === 0x27) fail(i, '字符串要用双引号');
    if (ch === 0x7d || ch === 0x5d || ch === 0x2c) fail(i, '这里缺少一个值');
    fail(i, `无法识别的内容「${s[i]}」`);
  }

  function object(pointer, depth) {
    if (depth > S.maxDepth) fail(i, '嵌套太深');
    i++;
    const map = new Map();
    ws();
    if (!end() && c() === 0x7d) {
      i++;
      return map;
    }
    let comma = -1;
    for (;;) {
      ws();
      if (end()) fail(i, '文件不完整');
      const ch = c();
      if (ch !== 0x22) {
        if (ch === 0x7d && comma >= 0) fail(comma, '多余的逗号');
        if (ch === 0x2f) fail(i, '不支持注释');
        if (ch === 0x27) fail(i, '字符串要用双引号');
        if (identStart(ch)) fail(i, '键要用双引号括起来');
        fail(i, '这里应该是一个键');
      }
      const key = string();
      ws();
      if (end()) fail(i, '文件不完整');
      if (c() !== 0x3a) fail(i, '键后面缺少冒号');
      i++;
      const child = `${pointer}/${escapeToken(key)}`;
      const v = value(child, depth);
      if (map.has(key)) duplicates.push(child);
      map.set(key, v);
      ws();
      if (end()) fail(i, '文件不完整');
      const next = c();
      if (next === 0x2c) {
        comma = i;
        i++;
        continue;
      }
      if (next === 0x7d) {
        i++;
        return map;
      }
      if (next === 0x2f) fail(i, '不支持注释');
      if (startsValue(next)) fail(i, '这里缺少逗号');
      fail(i, `这里不应该出现「${s[i]}」`);
    }
  }

  function array(pointer, depth) {
    if (depth > S.maxDepth) fail(i, '嵌套太深');
    i++;
    const list = [];
    ws();
    if (!end() && c() === 0x5d) {
      i++;
      return list;
    }
    let comma = -1;
    for (;;) {
      ws();
      if (!end() && c() === 0x5d && comma >= 0) fail(comma, '多余的逗号');
      list.push(value(`${pointer}/${list.length}`, depth));
      ws();
      if (end()) fail(i, '文件不完整');
      const next = c();
      if (next === 0x2c) {
        comma = i;
        i++;
        continue;
      }
      if (next === 0x5d) {
        i++;
        return list;
      }
      if (next === 0x2f) fail(i, '不支持注释');
      if (startsValue(next)) fail(i, '这里缺少逗号');
      fail(i, `这里不应该出现「${s[i]}」`);
    }
  }

  function string() {
    const start = i;
    i++;
    let out = '';
    for (;;) {
      if (end()) fail(start, '字符串没有结束');
      const ch = c();
      if (ch === 0x22) {
        i++;
        return out;
      }
      if (ch === 0x5c) {
        if (i + 1 >= s.length) fail(start, '字符串没有结束');
        const e = s.charCodeAt(i + 1);
        switch (e) {
          case 0x22:
          case 0x5c:
          case 0x2f:
            out += String.fromCharCode(e);
            break;
          case 0x62:
            out += '\b';
            break;
          case 0x66:
            out += '\f';
            break;
          case 0x6e:
            out += '\n';
            break;
          case 0x72:
            out += '\r';
            break;
          case 0x74:
            out += '\t';
            break;
          case 0x75: {
            const hex = s.substring(i + 2, i + 6);
            if (i + 6 > s.length || !/^[0-9A-Fa-f]{4}$/.test(hex)) fail(i, '字符串里的转义不对');
            out += String.fromCharCode(parseInt(hex, 16));
            i += 4;
            break;
          }
          default:
            fail(i, '字符串里的转义不对');
        }
        i += 2;
        continue;
      }
      if (ch === 0x0a || ch === 0x0d) fail(i, '字符串里不能直接换行');
      if (ch < 0x20) fail(i, '字符串里有控制字符');
      out += s[i];
      i++;
    }
  }

  function number() {
    const start = i;
    if (c() === 0x2d) i++;
    if (end()) fail(i, '数字格式不对');
    if (c() === 0x30) i++;
    else if (digit(c())) while (!end() && digit(c())) i++;
    else fail(i, '数字格式不对');
    let integer = true;
    if (!end() && c() === 0x2e) {
      integer = false;
      i++;
      if (end() || !digit(c())) fail(i, '数字格式不对');
      while (!end() && digit(c())) i++;
    }
    if (!end() && (c() === 0x65 || c() === 0x45)) {
      integer = false;
      i++;
      if (!end() && (c() === 0x2b || c() === 0x2d)) i++;
      if (end() || !digit(c())) fail(i, '数字格式不对');
      while (!end() && digit(c())) i++;
    }
    const literal = s.substring(start, i);
    const digits = literal.startsWith('-') ? literal.length - 1 : literal.length;
    return new JNum(Number(literal), integer && digits <= 9);
  }

  if (!end() && c() === 0xfeff) i++;
  ws();
  if (end()) fail(i, '文件是空的');
  const v = value('', 0);
  ws();
  if (!end()) fail(i, '后面还有多余的内容');
  return { value: v, duplicates };
}

// ── Validator (twin of ui_config_parser.dart) ─────────────────────────────

const isObject = (v) => v instanceof Map;
const isString = (v) => typeof v === 'string';
const controlChars = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g;
const lineBreaks = /\r\n|\r|\n|\t/g;
const trim = (s) => s.replace(/^[\s\u0085]+|[\s\u0085]+$/g, '');
const RX = {
  headerId: /^[a-z][a-zA-Z0-9-]{0,31}$/,
  commandName: /^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$/,
  httpsUrl: /^https:\/\/([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(:[0-9]{1,5})?([/?#][^\s]*)?$/,
  badPercent: /%(?![0-9A-Fa-f]{2})/,
  hexColor: /^#[0-9A-Fa-f]{6}$/,
  petId: /^[a-z0-9][a-z0-9-]{0,63}$/,
  slot: /^[a-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*$/,
  pkg: /^(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/,
};

function validate(root, duplicates) {
  const issues = [];
  const entries = new Map();
  const issue = (pointer, message, kind = 'invalid') => issues.push({ pointer, kind, message });
  const entry = (key, pointer) => entries.set(key, pointer);
  const child = (p, k) => `${p}/${escapeToken(k)}`;
  const unknownKeys = (map, p, known) => {
    for (const k of map.keys()) if (!known.includes(k)) issue(child(p, k), M.unknownKey, 'ignored');
  };
  const object = (v, p) => {
    if (isObject(v)) return v;
    issue(p, M.notObject);
    return null;
  };
  const array = (v, p) => {
    if (Array.isArray(v)) return v;
    issue(p, M.notArray);
    return null;
  };
  const choice = (v, p, options, noun = '值') => {
    if (!isString(v)) {
      issue(p, M.notString);
      return null;
    }
    if (options.includes(v)) return v;
    issue(p, M.badValue(v, options, noun));
    return null;
  };
  const label = (v, p, max) => {
    if (!isString(v)) {
      issue(p, M.notString);
      return null;
    }
    const clean = trim(v.replace(lineBreaks, ' ').replace(controlChars, ''));
    if (clean.length === 0) {
      issue(p, M.empty);
      return null;
    }
    const r = runes(clean);
    if (r.length <= max) return clean;
    issue(p, M.truncated(max), 'adjusted');
    return trim(r.slice(0, max).join(''));
  };
  const requiredLabel = (map, p, key, max) => {
    const kp = child(p, key);
    if (!map.has(key)) {
      issue(kp, M.missing(key));
      return null;
    }
    return label(map.get(key), kp, max);
  };
  const requiredAction = (map, p) => {
    const ap = child(p, 'action');
    if (!map.has('action')) {
      issue(ap, M.missing('action'));
      return null;
    }
    return action(map.get('action'), ap);
  };

  function action(v, p) {
    const map = object(v, p);
    if (!map) return null;
    const tp = child(p, 'type');
    if (!map.has('type')) {
      issue(tp, M.missing('type'));
      return null;
    }
    const type = choice(map.get('type'), tp, S.actionTypes, '动作');
    if (type === null) return null;
    switch (type) {
      case 'send': {
        unknownKeys(map, p, ['type', 'text']);
        const fp = child(p, 'text');
        if (!map.has('text')) {
          issue(fp, M.missing('text'));
          return null;
        }
        const raw = map.get('text');
        if (!isString(raw)) {
          issue(fp, M.notString);
          return null;
        }
        const text = trim(
          raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replace(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/g, ''),
        );
        if (text.length === 0) {
          issue(fp, M.empty);
          return null;
        }
        if (runes(text).length > L.sendTextMax) {
          issue(fp, M.tooLong(L.sendTextMax));
          return null;
        }
        return { type: 'send', text };
      }
      case 'open': {
        unknownKeys(map, p, ['type', 'page']);
        const fp = child(p, 'page');
        if (!map.has('page')) {
          issue(fp, M.missing('page'));
          return null;
        }
        const page = choice(map.get('page'), fp, S.pages, '页面');
        return page === null ? null : { type: 'open', page };
      }
      case 'command': {
        unknownKeys(map, p, ['type', 'name', 'args']);
        const fp = child(p, 'name');
        if (!map.has('name')) {
          issue(fp, M.missing('name'));
          return null;
        }
        const raw = map.get('name');
        if (!isString(raw)) {
          issue(fp, M.notString);
          return null;
        }
        let name = trim(raw);
        if (name.startsWith('/')) {
          name = name.substring(1);
          issue(fp, M.commandSlash, 'adjusted');
        }
        if (!RX.commandName.test(name)) {
          issue(fp, M.commandName);
          return null;
        }
        let args;
        if (map.has('args')) {
          const ap = child(p, 'args');
          const rawArgs = map.get('args');
          if (!isString(rawArgs)) {
            issue(ap, M.notString);
            return null;
          }
          if (rawArgs.includes('\n') || rawArgs.includes('\r')) {
            issue(ap, M.noNewline);
            return null;
          }
          const trimmed = trim(rawArgs.replace(controlChars, ''));
          if (runes(trimmed).length > L.commandArgsMax) {
            issue(ap, M.tooLong(L.commandArgsMax));
            return null;
          }
          if (trimmed.length > 0) args = trimmed;
        }
        return args === undefined ? { type: 'command', name } : { type: 'command', name, args };
      }
      case 'link': {
        unknownKeys(map, p, ['type', 'url']);
        const fp = child(p, 'url');
        if (!map.has('url')) {
          issue(fp, M.missing('url'));
          return null;
        }
        const raw = map.get('url');
        if (!isString(raw)) {
          issue(fp, M.notString);
          return null;
        }
        const url = trim(raw);
        if (!url.toLowerCase().startsWith('https://')) {
          issue(fp, M.httpsOnly);
          return null;
        }
        const normalized = `https://${url.substring(8)}`;
        if (url.length > L.urlMax || !RX.httpsUrl.test(normalized) || RX.badPercent.test(normalized)) {
          issue(fp, M.badUrl);
          return null;
        }
        return { type: 'link', url: normalized };
      }
    }
    return null;
  }

  function header(v, p) {
    const map = object(v, p);
    if (!map) return;
    unknownKeys(map, p, ['actions']);
    if (!map.has('actions')) return;
    const ap = child(p, 'actions');
    const list = array(map.get('actions'), ap);
    if (!list) return;
    const out = [];
    const seen = new Set();
    let custom = 0;
    list.forEach((item, index) => {
      const ip = `${ap}/${index}`;
      if (isString(item)) {
        const id = choice(item, ip, S.headerBuiltins, '按钮');
        if (id === null) return;
        if (seen.has(id)) {
          issue(ip, M.duplicateItem, 'ignored');
          return;
        }
        seen.add(id);
        out.push(id);
      } else if (isObject(item)) {
        const button = customButton(item, ip, seen);
        if (!button) return;
        if (custom >= L.headerCustomMax) {
          issue(ip, M.tooMany(L.headerCustomMax), 'ignored');
          return;
        }
        custom++;
        seen.add(button.id);
        out.push(button);
      } else {
        issue(ip, M.headerItem);
      }
    });
    if (out.length === 0 && list.length > 0) return;
    entry('header.actions', ap);
  }

  function customButton(map, p, taken) {
    unknownKeys(map, p, ['id', 'icon', 'label', 'action']);
    let ok = true;
    let id;
    const idp = child(p, 'id');
    const rawId = map.get('id');
    if (!map.has('id')) {
      issue(idp, M.missing('id'));
      ok = false;
    } else if (!isString(rawId)) {
      issue(idp, M.notString);
      ok = false;
    } else if (!RX.headerId.test(rawId)) {
      issue(idp, M.headerId);
      ok = false;
    } else if (taken.has(rawId) || S.headerBuiltins.includes(rawId)) {
      issue(idp, M.idTaken);
      ok = false;
    } else {
      id = rawId;
    }
    const iconp = child(p, 'icon');
    if (!map.has('icon')) {
      issue(iconp, M.missing('icon'));
      ok = false;
    } else if (choice(map.get('icon'), iconp, S.icons, '图标') === null) {
      ok = false;
    }
    const labelp = child(p, 'label');
    if (!map.has('label')) {
      issue(labelp, M.missing('label'));
      ok = false;
    } else if (label(map.get('label'), labelp, L.headerLabelMax) === null) {
      ok = false;
    }
    const actionp = child(p, 'action');
    if (!map.has('action')) {
      issue(actionp, M.missing('action'));
      ok = false;
    } else if (action(map.get('action'), actionp) === null) {
      ok = false;
    }
    return ok ? { id } : null;
  }

  function quickActions(v, p) {
    const list = array(v, p);
    if (!list) return;
    let count = 0;
    list.forEach((item, index) => {
      const ip = `${p}/${index}`;
      const map = object(item, ip);
      if (!map) return;
      unknownKeys(map, ip, ['label', 'action']);
      const l = requiredLabel(map, ip, 'label', L.quickLabelMax);
      const a = requiredAction(map, ip);
      if (l === null || a === null) return;
      if (count >= L.quickActionsMax) {
        issue(ip, M.tooMany(L.quickActionsMax), 'ignored');
        return;
      }
      count++;
    });
    if (count > 0) entry('composer.quickActions', p);
  }

  function suggestions(v, p) {
    const list = array(v, p);
    if (!list) return;
    let count = 0;
    list.forEach((item, index) => {
      const ip = `${p}/${index}`;
      const map = object(item, ip);
      if (!map) return;
      unknownKeys(map, ip, ['title', 'subtitle', 'action']);
      const title = requiredLabel(map, ip, 'title', L.suggestionTitleMax);
      let ok = true;
      if (map.has('subtitle')) {
        if (label(map.get('subtitle'), child(ip, 'subtitle'), L.suggestionSubtitleMax) === null) ok = false;
      }
      const a = requiredAction(map, ip);
      if (title === null || a === null || !ok) return;
      if (count >= L.suggestionsMax) {
        issue(ip, M.tooMany(L.suggestionsMax), 'ignored');
        return;
      }
      count++;
    });
    if (count > 0) entry('emptyState.suggestions', p);
  }

  function groups(v, p) {
    const list = array(v, p);
    if (!list) return;
    const out = [];
    list.forEach((item, index) => {
      const ip = `${p}/${index}`;
      const name = choice(item, ip, S.drawerGroups);
      if (name === null) return;
      if (out.includes(name)) {
        issue(ip, M.duplicateItem, 'ignored');
        return;
      }
      out.push(name);
    });
    if (out.length === 0 && list.length > 0) return;
    entry('drawer.groups', p);
  }

  function hide(v, p) {
    const list = array(v, p);
    if (!list) return;
    const out = [];
    list.forEach((item, index) => {
      const ip = `${p}/${index}`;
      const name = choice(item, ip, S.hideItems);
      if (name === null) return;
      if (out.includes(name)) {
        issue(ip, M.duplicateItem, 'ignored');
        return;
      }
      out.push(name);
      entry(`hide.${name}`, ip);
    });
  }

  function pet(v, p) {
    const map = object(v, p);
    if (!map) return;
    let any = false;
    for (const [k, field] of map) {
      const fp = child(p, k);
      switch (k) {
        case 'id':
          if (!isString(field)) issue(fp, M.notString);
          else if (!RX.petId.test(field)) issue(fp, M.petId);
          else any = true;
          break;
        case 'position':
          if (choice(field, fp, S.petPositions) !== null) any = true;
          break;
        case 'quiet':
          if (typeof field === 'boolean') any = true;
          else issue(fp, M.notBool);
          break;
        default:
          issue(fp, M.unknownKey, 'ignored');
      }
    }
    if (any) entry('pet', p);
  }

  function shortcutKeys(v, p) {
    if (!isString(v)) {
      issue(p, M.notString);
      return null;
    }
    const parts = v.toLowerCase().split('+').map((s) => trim(s));
    if (parts.some((s) => s.length === 0)) {
      issue(p, M.keysFormat);
      return null;
    }
    if (parts.some((s) => S.systemModifiers.includes(s))) {
      issue(p, M.systemKey);
      return null;
    }
    const key = parts[parts.length - 1];
    const mods = parts.slice(0, -1);
    const modSet = new Set(mods);
    if (!S.shortcutKeys.includes(key) || modSet.size !== mods.length || !mods.every((m) => ['ctrl', 'alt', 'shift'].includes(m))) {
      issue(p, M.keysFormat);
      return null;
    }
    const functionKey = /^f([1-9]|1[0-2])$/.test(key);
    if (!functionKey && !modSet.has('ctrl') && !modSet.has('alt')) {
      issue(p, M.needModifier);
      return null;
    }
    const canonical = [...['ctrl', 'alt', 'shift'].filter((m) => modSet.has(m)), key].join('+');
    if (S.reservedShortcuts.includes(canonical)) {
      issue(p, M.reserved);
      return null;
    }
    return canonical;
  }

  function shortcuts(v, p) {
    const list = array(v, p);
    if (!list) return;
    let count = 0;
    const where = new Map();
    list.forEach((item, index) => {
      const ip = `${p}/${index}`;
      const map = object(item, ip);
      if (!map) return;
      unknownKeys(map, ip, ['keys', 'action']);
      const kp = child(ip, 'keys');
      let keys = null;
      if (!map.has('keys')) {
        issue(kp, M.missing('keys'));
      } else {
        keys = shortcutKeys(map.get('keys'), kp);
        if (keys !== null && where.has(keys)) {
          issue(kp, M.duplicateShortcut(where.get(keys)));
          keys = null;
        }
      }
      const a = requiredAction(map, ip);
      if (keys === null || a === null) return;
      if (count >= L.shortcutsMax) {
        issue(ip, M.tooMany(L.shortcutsMax), 'ignored');
        return;
      }
      where.set(keys, ip);
      count++;
    });
    if (count > 0) entry('shortcuts', p);
  }

  function seats(v, p) {
    const map = object(v, p);
    if (!map) return;
    for (const [slot, packages] of map) {
      const sp = child(p, slot);
      if (!RX.slot.test(slot)) {
        issue(sp, M.slotName);
        continue;
      }
      if (!S.knownSlots.includes(slot)) {
        issue(sp, M.unknownSlot, 'adjusted');
      } else if (S.unseatableSlots.includes(slot)) {
        issue(sp, M.unseatableSlot, 'ignored');
        continue;
      }
      const inner = object(packages, sp);
      if (!inner) continue;
      for (const [pkg, mode] of inner) {
        const pp = child(sp, pkg);
        if (pkg.length > 214 || !RX.pkg.test(pkg)) {
          issue(pp, M.packageName);
          continue;
        }
        if (choice(mode, pp, S.seatModes) === null) continue;
        entry(`plugins.seats|${slot}|${pkg}`, pp);
      }
    }
  }

  for (const d of duplicates) issue(d, M.duplicateKey, 'ignored');

  // theme.accent bookkeeping, as in the app: which pointer holds the accent.
  let accent = null; // { kind: 'preset' | 'color', pointer }
  for (const [key, v] of root) {
    const p = child('', key);
    switch (key) {
      case 'version':
      case '$schema':
        break;
      case 'header':
        header(v, p);
        break;
      case 'composer': {
        const map = object(v, p);
        if (map) {
          unknownKeys(map, p, ['quickActions']);
          if (map.has('quickActions')) quickActions(map.get('quickActions'), child(p, 'quickActions'));
        }
        break;
      }
      case 'emptyState': {
        const map = object(v, p);
        if (map) {
          unknownKeys(map, p, ['suggestions']);
          if (map.has('suggestions')) suggestions(map.get('suggestions'), child(p, 'suggestions'));
        }
        break;
      }
      case 'drawer': {
        const map = object(v, p);
        if (!map) break;
        for (const [k, field] of map) {
          const fp = child(p, k);
          switch (k) {
            case 'groups':
              groups(field, fp);
              break;
            case 'sort':
              if (choice(field, fp, S.drawerSorts) !== null) entry('drawer.sort', fp);
              break;
            case 'filter':
              if (choice(field, fp, S.drawerFilters) !== null) entry('drawer.filter', fp);
              break;
            default:
              issue(fp, M.unknownKey, 'ignored');
          }
        }
        break;
      }
      case 'density':
        if (choice(v, p, S.densities) !== null) entry('density', p);
        break;
      case 'hide':
        hide(v, p);
        break;
      case 'theme': {
        const map = object(v, p);
        if (!map) break;
        for (const [k, field] of map) {
          const fp = child(p, k);
          switch (k) {
            case 'mode':
              if (choice(field, fp, S.themeModes) !== null) entry('theme.mode', fp);
              break;
            case 'accentPreset':
              if (choice(field, fp, S.accentPresets) !== null) {
                if (accent !== null && accent.kind === 'color') issue(accent.pointer, M.accentBoth, 'ignored');
                accent = { kind: 'preset', pointer: fp };
                entry('theme.accent', fp);
              }
              break;
            case 'accent':
              if (!isString(field)) issue(fp, M.notString);
              else if (!RX.hexColor.test(field)) issue(fp, M.accentFormat);
              else if (accent !== null && accent.kind === 'preset') issue(fp, M.accentBoth, 'ignored');
              else {
                accent = { kind: 'color', pointer: fp };
                entry('theme.accent', fp);
              }
              break;
            default:
              issue(fp, M.unknownKey, 'ignored');
          }
        }
        break;
      }
      case 'pet':
        pet(v, p);
        break;
      case 'shortcuts':
        shortcuts(v, p);
        break;
      case 'plugins': {
        const map = object(v, p);
        if (map) {
          unknownKeys(map, p, ['seats']);
          if (map.has('seats')) seats(map.get('seats'), child(p, 'seats'));
        }
        break;
      }
      default:
        issue(p, M.unknownKey, 'ignored');
    }
  }
  return { applied: entries.size, issues };
}

/** Checks ui.json text: { applied, fatal, issues: [{ pointer, kind, message }] }. */
export function checkUiJson(text) {
  const fatal = (pointer, message) => ({ applied: 0, fatal: true, issues: [{ pointer, kind: 'fatal', message }] });
  if (Buffer.byteLength(text, 'utf8') > S.maxBytes) return fatal('', M.fileTooLarge);
  let doc;
  try {
    doc = readJson(text);
  } catch (e) {
    if (e instanceof SyntaxErr) return fatal('', e.message);
    throw e;
  }
  const root = doc.value;
  if (!isObject(root)) return fatal('', M.rootNotObject);
  if (!root.has('version')) return fatal('/version', M.versionMissing);
  const version = root.get('version');
  if (!(version instanceof JNum) || !version.isInt) return fatal('/version', M.versionNotInt);
  if (version.value < 1) return fatal('/version', M.versionTooLow);
  if (version.value > S.version) return fatal('/version', M.versionTooHigh(version.value));
  const { applied, issues } = validate(root, doc.duplicates);
  return { applied, fatal: false, issues };
}

// ── CLI ───────────────────────────────────────────────────────────────────

function defaultPath() {
  if (process.env.DSH_HOME) return join(process.env.DSH_HOME, 'dsh-go', 'ui.json');
  // Installed as <DSH_HOME>/skills/dsh-go-ui/scripts/check.mjs.
  const skill = dirname(here);
  if (basename(here) === 'scripts' && basename(skill) === 'dsh-go-ui' && basename(dirname(skill)) === 'skills') {
    return join(dirname(dirname(skill)), 'dsh-go', 'ui.json');
  }
  return join(homedir(), '.dsh', 'dsh-go', 'ui.json');
}

const kindLabel = { fatal: '错误', invalid: '错误', ignored: '忽略', adjusted: '提示' };

function main(argv) {
  const json = argv.includes('--json');
  const target = argv.find((a) => a !== '--json');
  const path = target === '-' ? '-' : resolve(target ?? defaultPath());
  let text;
  try {
    if (path === '-') {
      text = readFileSync(0, 'utf8');
    } else {
      if (!existsSync(path)) {
        if (json) process.stdout.write(`${JSON.stringify({ file: path, missing: true })}\n`);
        else process.stdout.write(`还没有 ui.json：${path}\n`);
        return 3;
      }
      if (statSync(path).size > S.maxBytes) {
        text = null;
      } else {
        text = readFileSync(path, 'utf8');
      }
    }
  } catch (e) {
    process.stdout.write(`读不了 ${path}：${e.message}\n`);
    return 3;
  }
  const result =
    text === null
      ? { applied: 0, fatal: true, issues: [{ pointer: '', kind: 'fatal', message: M.fileTooLarge }] }
      : checkUiJson(text);
  if (json) {
    process.stdout.write(`${JSON.stringify({ file: path, ...result })}\n`);
  } else {
    const dropped = result.issues.filter((i) => i.kind !== 'adjusted').length;
    if (result.fatal) {
      process.stdout.write(`ui.json 没有生效：${result.issues[0].pointer ? `${result.issues[0].pointer}：` : ''}${result.issues[0].message}\n`);
    } else {
      process.stdout.write(`ui.json：已应用 ${result.applied} 项${dropped > 0 ? `，${dropped} 处没生效` : ''}\n`);
      for (const i of result.issues) {
        process.stdout.write(`${kindLabel[i.kind]} ${i.pointer ? `${i.pointer}：` : ''}${i.message}\n`);
      }
    }
  }
  if (result.fatal) return 2;
  return result.issues.some((i) => i.kind !== 'adjusted') ? 1 : 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // `| head` closing the pipe early is not an error.
  process.stdout.on('error', (e) => {
    if (e.code !== 'EPIPE') throw e;
  });
  process.exitCode = main(process.argv.slice(2));
}
