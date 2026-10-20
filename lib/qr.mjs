/**
 * dsh-remote-portal — lib/qr.mjs
 *
 * A small, dependency-free QR Code encoder used to pair a phone with the desktop
 * (the Settings panel shows the code, the phone scans it and lands on
 * `/__portal/pair?t=…`).
 *
 * Scope, deliberately narrow so the whole thing fits in one auditable file:
 *   • byte mode only (UTF-8)          — pairing URLs and short notes only need this
 *   • error-correction level M        — 15 % recovery, the right trade-off for a
 *                                       phone camera held at arm's length
 *   • versions 1–10 auto-selected     — up to 213 bytes, far beyond any URL we mint
 *   • all eight data masks with the four penalty rules (ISO/IEC 18004 §8.8)
 *   • format information with its BCH(15,5) code, version information with
 *     BCH(18,6) for v≥7, finder separators, timing, alignment, dark module
 *   • one self-contained <svg> built from horizontal run-length paths
 *
 * The matrix is a plain Uint8Array (row-major, one byte per module, 1 = dark) so a
 * test can decode it back with an independent decoder instead of trusting this file.
 */

/* -------------------------------------------------------------------------- */
/* Tables                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Level-M block structure, indexed by version:
 *   totalCodewords, ecCodewordsPerBlock, [[blockCount, dataCodewordsPerBlock], …]
 *
 * These are the ISO/IEC 18004 Table 9 values. The self-check in `encodeBlocks`
 * (final codeword count === totalCodewords) guards against a table typo.
 */
const ECC_M = {
  1: [26, 10, [[1, 16]]],
  2: [44, 16, [[1, 28]]],
  3: [70, 26, [[1, 44]]],
  4: [100, 18, [[2, 32]]],
  5: [134, 24, [[2, 43]]],
  6: [172, 16, [[4, 27]]],
  7: [196, 18, [[4, 31]]],
  8: [242, 22, [[2, 38], [2, 39]]],
  9: [292, 22, [[3, 36], [2, 37]]],
  10: [346, 26, [[4, 43], [1, 44]]],
};

const MIN_VERSION = 1;
const MAX_VERSION = 10;

/** ECC level M is encoded as 0b00 in the format information. */
const ECC_FORMAT_BITS = 0b00;

/** Format info: BCH(15,5) generator 0x537, then XOR-masked with 0x5412. */
const FORMAT_GENERATOR = 0x537;
const FORMAT_MASK = 0x5412;

/** Version info: BCH(18,6) generator 0x1f25. */
const VERSION_GENERATOR = 0x1f25;

const sizeOf = (version) => version * 4 + 17;

/* -------------------------------------------------------------------------- */
/* GF(256) arithmetic                                                         */
/* -------------------------------------------------------------------------- */

/**
 * GF(256) with the QR primitive polynomial x^8 + x^4 + x^3 + x^2 + 1 = 0x11d and
 * generator α = 2. Log/antilog tables make multiplication two lookups, which keeps
 * the Reed–Solomon hot loop short (it runs ~2·n² times per symbol).
 */
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
}

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

/**
 * Reed–Solomon generator polynomial ∏(x − α^i) for i = 0…degree−1, stored
 * highest-degree coefficient first (the leading 1 is implicit and dropped, which is
 * why `remainder` only ever touches `divisor.length` bytes).
 */
function rsDivisor(degree) {
  const result = new Uint8Array(degree);
  result[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      result[j] = gfMul(result[j], root);
      if (j + 1 < degree) result[j] ^= result[j + 1];
    }
    root = gfMul(root, 0x02); // next power of α
  }
  return result;
}

/** Polynomial remainder of `data·x^degree` divided by the divisor. */
function rsRemainder(data, divisor) {
  const result = new Uint8Array(divisor.length);
  for (let d = 0; d < data.length; d++) {
    const factor = data[d] ^ result[0];
    result.copyWithin(0, 1);
    result[result.length - 1] = 0;
    if (factor !== 0) {
      for (let i = 0; i < divisor.length; i++) result[i] ^= gfMul(divisor[i], factor);
    }
  }
  return result;
}

/* -------------------------------------------------------------------------- */
/* Bit stream + data codewords                                                */
/* -------------------------------------------------------------------------- */

/** Append `value` as `length` bits, most significant first. */
function pushBits(bits, value, length) {
  for (let i = length - 1; i >= 0; i--) bits.push((value >>> i) & 1);
}

function dataCodewordCount(version) {
  const groups = ECC_M[version][2];
  let n = 0;
  for (const [count, dataLen] of groups) n += count * dataLen;
  return n;
}

/** Byte-mode character count indicator: 8 bits for v1–9, 16 bits for v10+. */
const countBits = (version) => (version >= 10 ? 16 : 8);

/** Payload bytes that fit in a version at level M (header included). */
export function capacity(version) {
  return dataCodewordCount(version) - (countBits(version) + 4) / 8;
}

function pickVersion(byteLength) {
  for (let v = MIN_VERSION; v <= MAX_VERSION; v++) {
    if (byteLength <= capacity(v)) return v;
  }
  throw new RangeError(
    `qr: ${byteLength} UTF-8 bytes do not fit in a version ${MAX_VERSION}-M symbol ` +
      `(max ${capacity(MAX_VERSION)}); shorten the text or raise MAX_VERSION`,
  );
}

function utf8(text) {
  return new TextEncoder().encode(text);
}

/**
 * Byte-mode segment → data codewords:
 * mode 0100, character count, payload, terminator ≤4 bits, zero pad to a byte
 * boundary, then alternating 0xec / 0x11 pad codewords up to capacity.
 */
function buildDataCodewords(bytes, version) {
  const capacityBits = dataCodewordCount(version) * 8;
  const bits = [];
  pushBits(bits, 0b0100, 4);
  pushBits(bits, bytes.length, countBits(version));
  for (const b of bytes) pushBits(bits, b, 8);

  pushBits(bits, 0, Math.min(4, capacityBits - bits.length)); // terminator
  pushBits(bits, 0, (8 - (bits.length % 8)) % 8); // align to byte boundary

  const out = [];
  for (let i = 0; i < bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
    out.push(b);
  }

  // 0xec / 0x11 alternating are the two pad codewords mandated by the spec.
  for (let pad = 0xec; out.length < dataCodewordCount(version); pad ^= 0xec ^ 0x11) {
    out.push(pad);
  }
  return Uint8Array.from(out);
}

/**
 * Split data codewords into blocks, append Reed–Solomon codewords to each, then
 * interleave: data codewords column-wise, then ECC codewords column-wise. This
 * interleaving is what makes burst damage (a thumb over the middle of the code)
 * survive as one damaged codeword per block instead of destroying a single block.
 */
function encodeBlocks(dataCodewords, version) {
  const [totalCodewords, ecLen, groups] = ECC_M[version];
  const divisor = rsDivisor(ecLen);

  const blocks = [];
  let offset = 0;
  for (const [count, dataLen] of groups) {
    for (let i = 0; i < count; i++) {
      const dat = dataCodewords.subarray(offset, offset + dataLen);
      offset += dataLen;
      blocks.push({ dat, ecc: rsRemainder(dat, divisor) });
    }
  }

  const out = [];
  const maxData = Math.max(...blocks.map((b) => b.dat.length));
  for (let i = 0; i < maxData; i++) {
    for (const b of blocks) if (i < b.dat.length) out.push(b.dat[i]);
  }
  for (let i = 0; i < ecLen; i++) {
    for (const b of blocks) out.push(b.ecc[i]);
  }

  if (offset !== dataCodewords.length || out.length !== totalCodewords) {
    throw new Error("qr: block table inconsistency (data/total codeword mismatch)");
  }
  return Uint8Array.from(out);
}

/* -------------------------------------------------------------------------- */
/* Function patterns                                                          */
/* -------------------------------------------------------------------------- */

/** Alignment-pattern centre coordinates for a version (ISO/IEC 18004 Annex E). */
function alignmentPositions(version) {
  if (version === 1) return [];
  const count = Math.floor(version / 7) + 2;
  const step = Math.ceil((version * 4 + 4) / (count * 2 - 2)) * 2;
  const positions = [6];
  for (let pos = version * 4 + 10; positions.length < count; pos -= step) {
    positions.splice(1, 0, pos);
  }
  return positions;
}

/** 15-bit format information word (ECC level + mask) including its BCH code. */
export function formatWord(mask) {
  const data = (ECC_FORMAT_BITS << 3) | mask;
  // BCH(15,5): multiply by x^10 and reduce modulo the generator.
  let rem = data << 10;
  for (let i = 14; i >= 10; i--) {
    if ((rem >>> i) & 1) rem ^= FORMAT_GENERATOR << (i - 10);
  }
  return ((data << 10) | (rem & 0x3ff)) ^ FORMAT_MASK;
}

/** 18-bit version information word for v≥7, including its BCH(18,6) code. */
export function versionWord(version) {
  let rem = version;
  for (let i = 0; i < 12; i++) {
    rem = (rem << 1) ^ ((rem >>> 11) * VERSION_GENERATOR);
  }
  return (version << 12) | (rem & 0xfff);
}

/**
 * Every module occupied by format information (both copies) plus the always-dark
 * module at (8, n−8). Kept in one place because the decoder in the test needs to
 * know exactly which cells those are.
 */
function formatPositions(n) {
  const positions = [];
  for (let i = 0; i <= 5; i++) positions.push([8, i]);
  positions.push([8, 7], [8, 8], [7, 8]);
  for (let i = 9; i < 15; i++) positions.push([14 - i, 8]);
  for (let i = 0; i < 8; i++) positions.push([n - 1 - i, 8]);
  for (let i = 8; i < 15; i++) positions.push([8, n - 15 + i]);
  positions.push([8, n - 8]); // dark module
  return positions;
}

/** The 36 cells of the two version-information copies (v≥7 only). */
function versionPositions(n) {
  const positions = [];
  for (let i = 0; i < 18; i++) {
    const a = n - 11 + (i % 3);
    const b = Math.floor(i / 3);
    positions.push([a, b], [b, a]);
  }
  return positions;
}

/**
 * Build the symbol with all function patterns drawn and the data bits laid down
 * (unmasked). `isFunction` marks cells that masking must not touch and that the
 * zig-zag data walk must skip.
 */
function buildBase(version, codewords) {
  const n = sizeOf(version);
  const modules = new Uint8Array(n * n);
  const isFunction = new Uint8Array(n * n);

  const set = (x, y, dark) => {
    const i = y * n + x;
    modules[i] = dark ? 1 : 0;
    isFunction[i] = 1;
  };

  // Timing patterns first: row 6 and column 6, alternating dark/light starting dark.
  // They are drawn across the whole symbol and then partly overwritten, which is the
  // order the spec describes (finders and alignment patterns win over timing).
  for (let i = 0; i < n; i++) {
    set(6, i, i % 2 === 0);
    set(i, 6, i % 2 === 0);
  }

  // Finder patterns grow outwards from their centres; distance 4 is the separator
  // (light), 3 the outer ring (dark), 2 the gap (light), 0–1 the core (dark).
  const drawFinder = (cx, cy) => {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx;
        const y = cy + dy;
        if (x < 0 || x >= n || y < 0 || y >= n) continue;
        const dist = Math.max(Math.abs(dx), Math.abs(dy));
        set(x, y, dist !== 2 && dist !== 4);
      }
    }
  };
  drawFinder(3, 3);
  drawFinder(n - 4, 3);
  drawFinder(3, n - 4);

  // Alignment patterns: 5×5 target, skipped where a finder already sits.
  const align = alignmentPositions(version);
  const last = align.length - 1;
  for (let i = 0; i <= last; i++) {
    for (let j = 0; j <= last; j++) {
      if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) continue;
      const cx = align[i];
      const cy = align[j];
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) {
          set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
        }
      }
    }
  }

  // Reserve format cells (values are written per mask later) and version cells.
  for (const [x, y] of formatPositions(n)) set(x, y, false);
  if (version >= 7) for (const [x, y] of versionPositions(n)) set(x, y, false);

  // Data placement: two-module-wide columns, right to left, boustrophedon; column 6
  // is skipped because the vertical timing pattern lives there.
  let bitIndex = 0;
  const totalBits = codewords.length * 8;
  for (let right = n - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5; // skip the timing column, stay on an even pair
    for (let vert = 0; vert < n; vert++) {
      for (let column = 0; column < 2; column++) {
        const x = right - column;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? n - 1 - vert : vert;
        const i = y * n + x;
        if (isFunction[i]) continue;
        // Any cells left over after the codewords are the spec's remainder bits (0).
        modules[i] =
          bitIndex < totalBits ? (codewords[bitIndex >>> 3] >>> (7 - (bitIndex & 7))) & 1 : 0;
        bitIndex++;
      }
    }
  }

  return { n, modules, isFunction };
}

/** Write both format-information copies and the dark module. */
function writeFormat(modules, n, mask) {
  const bits = formatWord(mask);
  const bit = (i) => (bits >>> i) & 1;

  // Copy 1: down column 8 (rows 0–5), through the middle, then left along row 8.
  for (let i = 0; i <= 5; i++) modules[i * n + 8] = bit(i);
  modules[7 * n + 8] = bit(6);
  modules[8 * n + 8] = bit(7);
  modules[8 * n + 7] = bit(8);
  for (let i = 9; i < 15; i++) modules[8 * n + (14 - i)] = bit(i);

  // Copy 2: row 8 on the right edge, then up column 8 on the bottom edge.
  for (let i = 0; i < 8; i++) modules[8 * n + (n - 1 - i)] = bit(i);
  for (let i = 8; i < 15; i++) modules[(n - 15 + i) * n + 8] = bit(i);

  modules[(n - 8) * n + 8] = 1; // dark module, always set
}

function writeVersion(modules, n, version) {
  const bits = versionWord(version);
  for (let i = 0; i < 18; i++) {
    const bit = (bits >>> i) & 1;
    const a = n - 11 + (i % 3);
    const b = Math.floor(i / 3);
    modules[b * n + a] = bit;
    modules[a * n + b] = bit;
  }
}

/* -------------------------------------------------------------------------- */
/* Masking                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * The eight data-mask predicates (x = column, y = row). They are compared by the
 * penalty rules below; the winner is whichever mask makes the symbol look least
 * like structured noise, which is what cameras handle best.
 */
function maskBit(mask, x, y) {
  switch (mask) {
    case 0: return (x + y) % 2 === 0;
    case 1: return y % 2 === 0;
    case 2: return x % 3 === 0;
    case 3: return (x + y) % 3 === 0;
    case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
    case 5: return ((x * y) % 2) + ((x * y) % 3) === 0;
    case 6: return (((x * y) % 2) + ((x * y) % 3)) % 2 === 0;
    case 7: return (((x + y) % 2) + ((x * y) % 3)) % 2 === 0;
    default: throw new RangeError(`qr: mask ${mask} is out of range 0–7`);
  }
}

/**
 * ISO/IEC 18004 §8.8.2 penalty score. Lower is better.
 *
 * Four rules, summed:
 *   1. runs of ≥5 same-coloured modules in a row/column: 3 + (length − 5)
 *   2. every 2×2 block of one colour:                     3
 *   3. the 1:1:3:1:1 finder-shaped pattern with 4 light   40
 *      modules on either side (rows and columns; the area
 *      outside the symbol counts as light)
 *   4. deviation of the dark-module ratio from 50 %:      10 per 5 % step
 */
export function penalty(modules, n) {
  let score = 0;

  // Rule 1 — horizontal and vertical runs.
  const runScore = (get) => {
    let run = 1;
    for (let i = 1; i < n; i++) {
      if (get(i) === get(i - 1)) {
        run++;
      } else {
        if (run >= 5) score += run - 2;
        run = 1;
      }
    }
    if (run >= 5) score += run - 2;
  };
  for (let y = 0; y < n; y++) runScore((x) => modules[y * n + x]);
  for (let x = 0; x < n; x++) runScore((y) => modules[y * n + x]);

  // Rule 2 — 2×2 blocks (overlapping, so n−1 by n−1 windows).
  for (let y = 0; y < n - 1; y++) {
    for (let x = 0; x < n - 1; x++) {
      const c = modules[y * n + x];
      if (
        c === modules[y * n + x + 1] &&
        c === modules[(y + 1) * n + x] &&
        c === modules[(y + 1) * n + x + 1]
      ) {
        score += 3;
      }
    }
  }

  // Rule 3 — finder-like 1:1:3:1:1 patterns with a light margin.
  const P1 = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
  const P2 = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
  const scanLine = (get) => {
    // Pad with four light modules so a pattern touching the edge is still counted.
    const line = [0, 0, 0, 0];
    for (let i = 0; i < n; i++) line.push(get(i));
    line.push(0, 0, 0, 0);
    for (let i = 0; i + 11 <= line.length; i++) {
      let p1 = true;
      let p2 = true;
      for (let k = 0; k < 11; k++) {
        if (line[i + k] !== P1[k]) p1 = false;
        if (line[i + k] !== P2[k]) p2 = false;
      }
      if (p1) score += 40;
      if (p2) score += 40;
    }
  };
  for (let y = 0; y < n; y++) scanLine((x) => modules[y * n + x]);
  for (let x = 0; x < n; x++) scanLine((y) => modules[y * n + x]);

  // Rule 4 — dark/light balance.
  let dark = 0;
  for (let i = 0; i < n * n; i++) dark += modules[i];
  const total = n * n;
  score += Math.floor(Math.abs(dark * 20 - total * 10) / total) * 10;

  return score;
}

/* -------------------------------------------------------------------------- */
/* Public API                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Encode `text` to a QR matrix.
 *
 * @param {string} text
 * @param {{ mask?: number|null }} [options]  mask 0–7 forces a mask (tests, debugging);
 *        null picks the lowest-penalty mask, ties going to the lower index.
 * @returns {{ version: number, size: number, mask: number, modules: Uint8Array }}
 */
export function qrMatrix(text, options = {}) {
  if (typeof text !== "string") throw new TypeError("qr: text must be a string");
  const bytes = utf8(text);
  const version = pickVersion(bytes.length);
  const n = sizeOf(version);
  const base = buildBase(version, encodeBlocks(buildDataCodewords(bytes, version), version));

  const forced = options.mask;
  if (forced !== undefined && forced !== null) {
    if (!Number.isInteger(forced) || forced < 0 || forced > 7) {
      throw new RangeError("qr: mask must be an integer 0–7 (or omitted)");
    }
  }

  let bestMask = 0;
  let bestPenalty = Infinity;
  let bestModules = null;
  for (let mask = 0; mask < 8; mask++) {
    if (forced !== undefined && forced !== null && mask !== forced) continue;

    const modules = base.modules.slice();
    for (let y = 0; y < n; y++) {
      for (let x = 0; x < n; x++) {
        const i = y * n + x;
        if (!base.isFunction[i] && maskBit(mask, x, y)) modules[i] ^= 1;
      }
    }
    writeFormat(modules, n, mask);
    if (version >= 7) writeVersion(modules, n, version);

    const score = penalty(modules, n);
    // "<" (not "≤") on purpose: ties resolve to the lowest mask index, which makes
    // mask selection deterministic for a given payload.
    if (score < bestPenalty) {
      bestPenalty = score;
      bestMask = mask;
      bestModules = modules;
    }
  }

  return { version, size: n, mask: bestMask, modules: bestModules };
}

const escapeText = (value) =>
  String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const escapeAttr = (value) => escapeText(value).replace(/"/g, "&quot;");

/**
 * Render `text` as one self-contained SVG QR code.
 *
 * The symbol is drawn in a `viewBox` measured in modules, so the browser scales it
 * with no fractional module edges; `shape-rendering="crispEdges"` turns off
 * anti-aliasing so a phone camera sees hard black/white boundaries.
 *
 * Dark modules are emitted as horizontal run-length subpaths (`M x y h len v1 h-len
 * z`) instead of one <rect> per module: roughly a fifth of the bytes, and a single
 * path paints in one pass.
 *
 * @param {string} text
 * @param {object} [options]
 * @param {number} [options.size=220]    rendered width/height in CSS px
 * @param {number} [options.margin=4]    quiet zone in modules
 * @param {string} [options.dark="#0f1115"] dark module colour (any CSS colour)
 * @param {string} [options.light="none"] background colour; "none" keeps the quiet
 *        zone transparent (callers put it on a light surface)
 * @param {number|null} [options.mask=null] force a mask (0–7); default auto
 * @param {string} [options.label="QR code"] accessible name
 * @returns {string}
 */
export function qrSvg(text, options = {}) {
  const {
    size = 220,
    margin = 4,
    dark = "#0f1115",
    light = "none",
    mask = null,
    label = "QR code",
  } = options || {};

  if (!Number.isFinite(size) || size <= 0) throw new RangeError("qr: size must be > 0");
  if (!Number.isInteger(margin) || margin < 0) throw new RangeError("qr: margin must be an integer ≥ 0");

  const { version, size: n, modules } = qrMatrix(text, { mask });
  const total = n + margin * 2;

  let path = "";
  for (let y = 0; y < n; y++) {
    let x = 0;
    while (x < n) {
      if (!modules[y * n + x]) {
        x++;
        continue;
      }
      let len = 1;
      while (x + len < n && modules[y * n + x + len]) len++;
      path += `M${x + margin} ${y + margin}h${len}v1h-${len}z`;
      x += len;
    }
  }

  const background =
    light === "none" ? "" : `<rect width="${total}" height="${total}" fill="${escapeAttr(light)}"/>`;
  const accessible = escapeAttr(label);

  return (
    `<svg xmlns="http://www.w3.org/2000/svg" role="img" width="${size}" height="${size}"` +
    ` viewBox="0 0 ${total} ${total}" shape-rendering="crispEdges" aria-label="${accessible}">` +
    `<title>${escapeText(label)}</title>${background}` +
    `<path d="${path}" fill="${escapeAttr(dark)}"/></svg>`
  );
}

export const QR_VERSION_RANGE = Object.freeze([MIN_VERSION, MAX_VERSION]);
