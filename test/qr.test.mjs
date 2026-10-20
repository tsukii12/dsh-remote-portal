/**
 * dsh-remote-portal — test/qr.test.mjs
 *
 * The encoder in lib/qr.mjs is only useful if a real scanner can read what it
 * draws, so this test does not compare the SVG to itself. It reads the emitted SVG
 * back into a module matrix and decodes it with an independent implementation:
 * find the finders, derive the version, read and BCH-verify the format information,
 * check timing / alignment / separators in the rendered symbol, unmask, walk the
 * zig-zag, de-interleave the blocks, verify every Reed–Solomon syndrome is zero,
 * strip the ECC, and parse the byte-mode segment back to the original UTF-8 bytes.
 *
 * Anything the encoder gets wrong structurally (a misplaced finder, a bad format
 * word, a wrong mask, a mis-interleaved block) makes the decode fail here.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { qrSvg, qrMatrix, capacity, formatWord, versionWord, QR_VERSION_RANGE } from "../lib/qr.mjs";

/* ========================================================================== */
/* Reverse direction: SVG → matrix                                            */
/* ========================================================================== */

const RUN_PATTERN = /M(\d+) (\d+)h(\d+)v1h-(\d+)z/g;

/** Rasterise the run-length path back into a dense grid of 0/1 cells. */
function rasterize(svg) {
  const viewBox = /viewBox="0 0 (\d+) (\d+)"/.exec(svg);
  assert.ok(viewBox, "svg exposes an integer module viewBox");
  const total = Number(viewBox[1]);
  assert.equal(Number(viewBox[2]), total, "viewBox is square");

  const path = /<path d="([^"]*)"/.exec(svg);
  assert.ok(path, "svg contains the module path");

  const grid = Array.from({ length: total }, () => new Uint8Array(total));
  RUN_PATTERN.lastIndex = 0;
  let match;
  let consumed = 0;
  let runs = 0;
  while ((match = RUN_PATTERN.exec(path[1])) !== null) {
    const x = Number(match[1]);
    const y = Number(match[2]);
    const len = Number(match[3]);
    assert.equal(Number(match[4]), len, "run is a 1-module-tall rectangle");
    assert.ok(y < total && x + len <= total, "run stays inside the viewBox");
    for (let i = 0; i < len; i++) {
      assert.equal(grid[y][x + i], 0, "dark runs never overlap");
      grid[y][x + i] = 1;
    }
    runs++;
    consumed += match[0].length;
  }
  assert.equal(consumed, path[1].length, "the path contains only run-length subpaths");
  assert.ok(runs > 0, "the symbol has dark modules");
  return { total, grid };
}

function isFinderAt(grid, x0, y0) {
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
      // ring 0–1: dark core, ring 2: light gap, ring 3: dark border
      if (grid[y0 + dy][x0 + dx] !== (ring === 2 ? 0 : 1)) return false;
    }
  }
  return true;
}

/** Locate the three finder patterns and sort them into TL / TR / BL. */
function locateFinders(grid, total) {
  const found = [];
  for (let y0 = 0; y0 + 7 <= total; y0++) {
    for (let x0 = 0; x0 + 7 <= total; x0++) {
      if (isFinderAt(grid, x0, y0)) found.push({ x0, y0, x: x0 + 3, y: y0 + 3 });
    }
  }
  assert.equal(found.length, 3, `expected exactly 3 finder patterns, found ${found.length}`);
  const bySum = [...found].sort((a, b) => a.x + a.y - (b.x + b.y));
  const tl = bySum[0];
  const [a, b] = bySum.slice(1);
  const tr = a.x > b.x ? a : b;
  const bl = a.y > b.y ? a : b;
  return { tl, tr, bl };
}

/* ========================================================================== */
/* Spec tables, written independently of the encoder                          */
/* ========================================================================== */

/** Level M: total codewords, EC codewords per block, [[blocks, dataCodewords], …] */
const SPEC_M = {
  1: { total: 26, ec: 10, blocks: [[1, 16]] },
  2: { total: 44, ec: 16, blocks: [[1, 28]] },
  3: { total: 70, ec: 26, blocks: [[1, 44]] },
  4: { total: 100, ec: 18, blocks: [[2, 32]] },
  5: { total: 134, ec: 24, blocks: [[2, 43]] },
  6: { total: 172, ec: 16, blocks: [[4, 27]] },
  7: { total: 196, ec: 18, blocks: [[4, 31]] },
  8: { total: 242, ec: 22, blocks: [[2, 38], [2, 39]] },
  9: { total: 292, ec: 22, blocks: [[3, 36], [2, 37]] },
  10: { total: 346, ec: 26, blocks: [[4, 43], [1, 44]] },
};

/** Bytes a version-M symbol can carry in byte mode (character count overhead included). */
function specCapacity(version) {
  const data = SPEC_M[version].blocks.reduce((n, [count, len]) => n + count * len, 0);
  return data - (version >= 10 ? 3 : 2);
}

/** Remainder bits per version (ISO/IEC 18004 Table 1). */
const REMAINDER_BITS = { 1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0 };

/** Known format-information words for level M, masks 0–7 (ISO/IEC 18004 Table C.1). */
const FORMAT_M_WORDS = [0x5412, 0x5125, 0x5e7c, 0x5b4b, 0x45f9, 0x40ce, 0x4f97, 0x4aa0];

/** Known version-information words for versions 7–10 (ISO/IEC 18004 Table D.1). */
const VERSION_WORDS = { 7: 0x07c94, 8: 0x085bc, 9: 0x09a99, 10: 0x0a4d3 };

function bchFormat(mask) {
  const data = mask; // level M contributes 0b00 in the top two bits
  let rem = data << 10;
  for (let i = 14; i >= 10; i--) if ((rem >>> i) & 1) rem ^= 0x537 << (i - 10);
  return ((data << 10) | (rem & 0x3ff)) ^ 0x5412;
}

function bchVersion(version) {
  let rem = version;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
  return (version << 12) | (rem & 0xfff);
}

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
    default: throw new Error(`bad mask ${mask}`);
  }
}

/**
 * Which cells are function patterns, derived from the version with plain
 * rectangles + the spec's coordinate lists. Deliberately a different shape of code
 * from the encoder's `set()`-as-you-draw approach.
 */
function functionMap(n, version) {
  const fn = Array.from({ length: n }, () => new Uint8Array(n));
  const mark = (x, y) => { fn[y][x] = 1; };

  // Three 8×8 finder + separator blocks.
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      mark(x, y);
      mark(n - 1 - x, y);
      mark(x, n - 1 - y);
    }
  }
  // Timing row/column.
  for (let i = 0; i < n; i++) { mark(i, 6); mark(6, i); }

  // Alignment patterns (all pairs except the three finder corners).
  const pos = alignmentPositions(version);
  const last = pos.length - 1;
  for (let i = 0; i <= last; i++) {
    for (let j = 0; j <= last; j++) {
      if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) continue;
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) mark(pos[i] + dx, pos[j] + dy);
    }
  }

  // Format information (both copies) + the always-dark module.
  const formatCells = [];
  for (let i = 0; i <= 5; i++) formatCells.push([8, i]);
  formatCells.push([8, 7], [8, 8], [7, 8]);
  for (let i = 9; i < 15; i++) formatCells.push([14 - i, 8]);
  for (let i = 0; i < 8; i++) formatCells.push([n - 1 - i, 8]);
  for (let i = 8; i < 15; i++) formatCells.push([8, n - 15 + i]);
  formatCells.push([8, n - 8]);
  assert.equal(new Set(formatCells.map(String)).size, 31, "31 format cells");
  for (const [x, y] of formatCells) mark(x, y);

  // Version information (v≥7): 18 bits, twice.
  if (version >= 7) {
    for (let i = 0; i < 18; i++) {
      const a = n - 11 + (i % 3);
      const b = Math.floor(i / 3);
      mark(a, b);
      mark(b, a);
    }
  }
  return fn;
}

/* ========================================================================== */
/* GF(256) + Reed–Solomon verification                                        */
/* ========================================================================== */

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
 * A QR Reed–Solomon codeword is a multiple of ∏(x − αⁱ), so evaluating the
 * codeword polynomial at α⁰…α^(ecLen−1) must give zero. This checks the ECC bytes
 * without reproducing the encoder's remainder code.
 */
function syndromesAreZero(data, ecc) {
  const words = [...data, ...ecc];
  for (let i = 0; i < ecc.length; i++) {
    const alpha = GF_EXP[i];
    let acc = 0;
    for (const word of words) acc = gfMul(acc, alpha) ^ word;
    if (acc !== 0) return false;
  }
  return true;
}

/* ========================================================================== */
/* The decoder                                                                */
/* ========================================================================== */

function decodeSvg(svg) {
  const { total, grid } = rasterize(svg);
  const { tl, tr, bl } = locateFinders(grid, total);

  // Geometry: centres are 3 modules in from each edge, so the symbol is
  // (distance between centres) + 7 modules wide.
  assert.equal(tl.y, tr.y, "top-left and top-right finders share a row");
  assert.equal(tl.x, bl.x, "top-left and bottom-left finders share a column");
  const n = tr.x - tl.x + 7;
  assert.equal(bl.y - tl.y + 7, n, "symbol is square");
  assert.equal((n - 17) % 4, 0, `module count ${n} is not 17+4v`);
  const version = (n - 17) / 4;
  assert.ok(
    version >= QR_VERSION_RANGE[0] && version <= QR_VERSION_RANGE[1],
    `version ${version} outside the supported range`,
  );

  // Quiet zone: every cell outside the symbol must be light, and the symbol must be
  // centred, i.e. the margin is the same on all four sides.
  const margin = (total - n) / 2;
  assert.ok(Number.isInteger(margin) && margin >= 0, "symbol is centred with an integer margin");
  assert.deepEqual(
    tl,
    { x0: margin, y0: margin, x: margin + 3, y: margin + 3 },
    "TL finder sits in the top-left corner of the symbol",
  );
  assert.deepEqual(
    tr,
    { x0: margin + n - 7, y0: margin, x: margin + n - 4, y: margin + 3 },
    "TR finder sits in the top-right corner",
  );
  assert.deepEqual(
    bl,
    { x0: margin, y0: margin + n - 7, x: margin + 3, y: margin + n - 4 },
    "BL finder sits in the bottom-left corner",
  );
  for (let y = 0; y < total; y++) {
    for (let x = 0; x < total; x++) {
      if (x < margin || x >= margin + n || y < margin || y >= margin + n) {
        assert.equal(grid[y][x], 0, `quiet-zone cell (${x},${y}) must be light`);
      }
    }
  }
  const m = Array.from({ length: n }, (_, y) => grid[y + margin].slice(margin, margin + n));

  // Separators, straight off the rendered matrix.
  for (let i = 0; i < 8; i++) {
    assert.equal(m[7][i], 0, "TL separator row");
    assert.equal(m[i][7], 0, "TL separator column");
    assert.equal(m[7][n - 1 - i], 0, "TR separator row");
    assert.equal(m[i][n - 8], 0, "TR separator column");
    assert.equal(m[n - 8][i], 0, "BL separator row");
    assert.equal(m[n - 1 - i][7], 0, "BL separator column");
  }

  // Timing patterns: alternate dark/light, dark on even coordinates.
  for (let i = 8; i <= n - 9; i++) {
    assert.equal(m[6][i], i % 2 === 0 ? 1 : 0, `horizontal timing at ${i}`);
    assert.equal(m[i][6], i % 2 === 0 ? 1 : 0, `vertical timing at ${i}`);
  }

  // Alignment patterns (v≥2), all pairs except the finder corners.
  const align = alignmentPositions(version);
  for (let i = 0; i < align.length; i++) {
    for (let j = 0; j < align.length; j++) {
      const corner =
        (i === 0 && j === 0) || (i === 0 && j === align.length - 1) || (i === align.length - 1 && j === 0);
      if (corner) continue;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) {
          const ring = Math.max(Math.abs(dx), Math.abs(dy));
          assert.equal(
            m[align[j] + dy][align[i] + dx],
            ring === 1 ? 0 : 1,
            `alignment pattern at (${align[i]},${align[j]})`,
          );
        }
      }
    }
  }

  // ---- format information, both copies ----
  const readBit = (x, y) => m[y][x];
  let formatA = 0;
  const copyOne = [];
  for (let i = 0; i <= 5; i++) copyOne.push([8, i]);
  copyOne.push([8, 7], [8, 8], [7, 8]);
  for (let i = 9; i < 15; i++) copyOne.push([14 - i, 8]);
  assert.equal(copyOne.length, 15, "15 format bits in copy 1");
  copyOne.forEach(([x, y], i) => { formatA |= readBit(x, y) << i; });

  let formatB = 0;
  const copyTwo = [];
  for (let i = 0; i < 8; i++) copyTwo.push([n - 1 - i, 8]);
  for (let i = 8; i < 15; i++) copyTwo.push([8, n - 15 + i]);
  assert.equal(copyTwo.length, 15, "15 format bits in copy 2");
  copyTwo.forEach(([x, y], i) => { formatB |= readBit(x, y) << i; });

  assert.equal(formatA, formatB, "both format-information copies agree");
  assert.equal(m[n - 8][8], 1, "the dark module is set");

  // BCH(15,5) cross-check against both a fresh computation and the published table.
  const dataBits = (formatA ^ 0x5412) >>> 10;
  const mask = dataBits & 0b111;
  const eccLevel = dataBits >>> 3;
  assert.equal(eccLevel, 0b00, "format info says error-correction level M");
  assert.equal(bchFormat(mask), formatA, "format word passes its own BCH check");
  assert.equal(FORMAT_M_WORDS[mask], formatA, "format word matches the published M table");
  assert.equal(formatA, formatWord(mask), "format word agrees with the encoder helper");

  // ---- version information (v≥7) ----
  let versionA = 0;
  let versionB = 0;
  for (let i = 0; i < 18; i++) {
    const a = n - 11 + (i % 3);
    const b = Math.floor(i / 3);
    versionA |= readBit(a, b) << i;
    versionB |= readBit(b, a) << i;
  }
  if (version >= 7) {
    assert.equal(versionA, versionB, "both version-information copies agree");
    assert.equal(versionA, VERSION_WORDS[version], "version word matches the published table");
    assert.equal(versionA, bchVersion(version), "version word passes its BCH check");
    assert.equal(versionA, versionWord(version), "version word agrees with the encoder helper");
  }

  // ---- unmask the data area and read the zig-zag ----
  const fn = functionMap(n, version);
  const bits = [];
  for (let right = n - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < n; vert++) {
      for (let column = 0; column < 2; column++) {
        const x = right - column;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? n - 1 - vert : vert;
        if (fn[y][x]) continue;
        bits.push(m[y][x] ^ (maskBit(mask, x, y) ? 1 : 0));
      }
    }
  }

  const spec = SPEC_M[version];
  const remainder = REMAINDER_BITS[version];
  assert.equal(
    bits.length,
    spec.total * 8 + remainder,
    `version ${version} data area holds ${spec.total} codewords + ${remainder} remainder bits`,
  );
  for (let i = bits.length - remainder; i < bits.length; i++) {
    assert.equal(bits[i], 0, "remainder bits are zero");
  }

  const codewords = new Uint8Array(spec.total);
  for (let i = 0; i < spec.total; i++) {
    let byte = 0;
    for (let j = 0; j < 8; j++) byte = (byte << 1) | bits[i * 8 + j];
    codewords[i] = byte;
  }

  // ---- de-interleave and verify Reed–Solomon ----
  const lengths = [];
  for (const [count, dataLen] of spec.blocks) for (let i = 0; i < count; i++) lengths.push(dataLen);
  const blocks = lengths.map((len) => ({ data: new Array(len).fill(null), ecc: new Array(spec.ec).fill(null) }));
  let cursor = 0;
  const maxData = Math.max(...lengths);
  for (let i = 0; i < maxData; i++) {
    for (const block of blocks) if (i < block.data.length) block.data[i] = codewords[cursor++];
  }
  for (let i = 0; i < spec.ec; i++) {
    for (const block of blocks) block.ecc[i] = codewords[cursor++];
  }
  assert.equal(cursor, spec.total, "every codeword was consumed by exactly one block");
  blocks.forEach((block, index) => {
    assert.ok(
      syndromesAreZero(block.data, block.ecc),
      `block ${index} Reed–Solomon syndromes are all zero`,
    );
  });

  // ---- byte-mode payload ----
  const dataBytes = blocks.flatMap((block) => block.data);
  const bitAt = (position) => (dataBytes[position >>> 3] >>> (7 - (position & 7))) & 1;
  let position = 0;
  let mode = 0;
  for (let i = 0; i < 4; i++) mode = (mode << 1) | bitAt(position++);
  assert.equal(mode, 0b0100, "first segment uses byte mode");

  const countLength = version >= 10 ? 16 : 8;
  let count = 0;
  for (let i = 0; i < countLength; i++) count = (count << 1) | bitAt(position++);
  assert.ok(count <= specCapacity(version), "declared payload length fits the symbol");

  const payload = new Uint8Array(count);
  for (let i = 0; i < count; i++) {
    let byte = 0;
    for (let j = 0; j < 8; j++) byte = (byte << 1) | bitAt(position++);
    payload[i] = byte;
  }

  // Terminator, byte-alignment zeros and the 0xEC/0x11 pad pattern.
  const totalBits = dataBytes.length * 8;
  const terminator = Math.min(4, totalBits - position);
  for (let i = 0; i < terminator; i++) assert.equal(bitAt(position++), 0, "terminator is zero");
  while (position % 8 !== 0) assert.equal(bitAt(position++), 0, "padding to a byte boundary is zero");
  let pad = 0xec;
  while (position < totalBits) {
    let byte = 0;
    for (let i = 0; i < 8; i++) byte = (byte << 1) | bitAt(position++);
    assert.equal(byte, pad, "pad codewords alternate 0xEC / 0x11");
    pad = pad === 0xec ? 0x11 : 0xec;
  }

  return { version, mask, bytes: payload };
}

function decode(svg) {
  const { version, mask, bytes } = decodeSvg(svg);
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return { version, mask, text, bytes };
}

/** Encode + decode and assert the payload survived (UTF-8 included). */
function roundTrip(text, options) {
  const svg = qrSvg(text, options);
  const result = decode(svg);
  const expectedBytes = new TextEncoder().encode(text);
  assert.deepEqual(
    [...result.bytes],
    [...expectedBytes],
    `payload bytes for ${JSON.stringify(text).slice(0, 80)}`,
  );
  assert.equal(result.text, text, "decoded UTF-8 text matches the input");
  return { ...result, svg };
}

/* ========================================================================== */
/* Tests                                                                      */
/* ========================================================================== */

test("round-trips fixed cases: long URL, Chinese text, single characters", () => {
  const token = "CmPflmqoBKfSkgEow-JA9HlkKkK3Gsm0czjEqnR97iE";
  const cases = [
    "A",
    "7",
    "中",
    "😀",
    "https://10.150.23.97:3081/__portal/pair?t=" + token,
    `http://10.150.23.97:3081/__portal/pair?t=${token}&v=0.2.1-rc.2&label=${encodeURIComponent("我的手机")}`,
    "远程访问网关：请在这台设备上确认登录。",
    "DeepSeek Harness — 远程访问 / Remote access",
    "0123456789".repeat(12), // 120 ASCII bytes → version 7
    "0000000000".repeat(21) + "012", // 213 bytes → version 10, the largest we encode
  ];
  for (const text of cases) {
    const { svg } = roundTrip(text);
    assert.match(svg, /^<svg /);
  }
});

test("round-trips 40 deterministic random payloads of 1–120 bytes", () => {
  // Deterministic LCG so a failure is reproducible from the seed alone.
  let state = 0x5eed1234;
  const random = () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
  const alphabets = [
    Array.from({ length: 95 }, (_, i) => String.fromCharCode(32 + i)),
    Array.from("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~:/?&=%#+"),
    Array.from("的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严龙飞"),
    Array.from("日本語のテキストと絵文字😀🚀🔗✓★"),
  ];
  const encoder = new TextEncoder();
  for (let iteration = 0; iteration < 40; iteration++) {
    const alphabet = alphabets[iteration % alphabets.length];
    const budget = 1 + Math.floor(random() * 120); // target UTF-8 byte length 1–120
    let text = "";
    let byteLength = 0;
    while (byteLength < budget) {
      const char = alphabet[Math.floor(random() * alphabet.length)];
      const charBytes = encoder.encode(char).length;
      if (byteLength + charBytes > budget) break;
      text += char;
      byteLength += charBytes;
    }
    if (text === "") text = alphabet[0]; // never send an empty payload here
    const expectedVersion = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].find(
      (v) => encoder.encode(text).length <= specCapacity(v),
    );
    const { version, mask } = roundTrip(text);
    assert.equal(version, expectedVersion, `version for ${encoder.encode(text).length} bytes`);
    assert.ok(mask >= 0 && mask <= 7);
  }
});

test("selects the smallest version that fits, up to version 10", () => {
  const boundaries = [
    [1, 1], [14, 1], [15, 2], [26, 2], [27, 3], [42, 3], [43, 4], [62, 4],
    [63, 5], [84, 5], [85, 6], [106, 6], [107, 7], [122, 7], [123, 8], [152, 8],
    [153, 9], [180, 9], [181, 10], [213, 10],
  ];
  for (const [length, version] of boundaries) {
    assert.equal(capacity(version) >= length, true, `capacity(${version}) covers ${length}`);
    const { version: actual, bytes } = decode(qrSvg("x".repeat(length)));
    assert.equal(bytes.length, length, "payload length survives");
    assert.equal(actual, version, `${length} bytes → version ${version}`);
  }
  const sizes = [1, 14, 15, 26, 27, 42, 43, 62, 63, 84, 85, 106, 107, 122, 123, 152, 153, 180, 181, 213];
  for (const length of sizes) {
    const matrix = qrMatrix("x".repeat(length));
    assert.equal(matrix.size, 17 + 4 * matrix.version, "module count is 17 + 4·version");
    assert.equal(matrix.modules.length, matrix.size * matrix.size);
  }
  assert.throws(() => qrSvg("x".repeat(214)), RangeError, "214 bytes exceeds version 10-M");
});

test("every mask produces a decodable symbol, and only the format word changes", () => {
  const text = "https://10.150.23.97:3081/__portal/pair?t=CmPflmqoBKfSkgEow";
  const seen = new Set();
  for (let mask = 0; mask < 8; mask++) {
    const { mask: decodedMask, text: decodedText, svg } = roundTrip(text, { mask });
    assert.equal(decodedMask, mask, `format info records mask ${mask}`);
    assert.equal(decodedText, text);
    assert.equal(decode(svg).version, decode(qrSvg(text)).version);
    seen.add(svg);
  }
  assert.equal(seen.size, 8, "each mask renders a different symbol");
  assert.throws(() => qrSvg(text, { mask: 8 }), RangeError);
  assert.throws(() => qrSvg(text, { mask: 1.5 }), RangeError);
});

/** ISO/IEC 18004 §8.8.2, implemented here so the selection can be checked. */
function specPenalty(modules, n) {
  let score = 0;
  const lineScore = (get) => {
    let run = 1;
    for (let i = 1; i < n; i++) {
      if (get(i) === get(i - 1)) run++;
      else { if (run >= 5) score += run - 2; run = 1; }
    }
    if (run >= 5) score += run - 2;
  };
  for (let y = 0; y < n; y++) lineScore((x) => modules[y * n + x]);
  for (let x = 0; x < n; x++) lineScore((y) => modules[y * n + x]);

  for (let y = 0; y < n - 1; y++) {
    for (let x = 0; x < n - 1; x++) {
      const c = modules[y * n + x];
      if (c === modules[y * n + x + 1] && c === modules[(y + 1) * n + x] && c === modules[(y + 1) * n + x + 1]) {
        score += 3;
      }
    }
  }

  const before = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
  const after = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
  const scan = (get) => {
    const line = [0, 0, 0, 0];
    for (let i = 0; i < n; i++) line.push(get(i));
    line.push(0, 0, 0, 0);
    for (let i = 0; i + 11 <= line.length; i++) {
      let isBefore = true;
      let isAfter = true;
      for (let k = 0; k < 11; k++) {
        if (line[i + k] !== before[k]) isBefore = false;
        if (line[i + k] !== after[k]) isAfter = false;
      }
      if (isBefore) score += 40;
      if (isAfter) score += 40;
    }
  };
  for (let y = 0; y < n; y++) scan((x) => modules[y * n + x]);
  for (let x = 0; x < n; x++) scan((y) => modules[y * n + x]);

  let dark = 0;
  for (let i = 0; i < n * n; i++) dark += modules[i];
  return score + Math.floor(Math.abs(dark * 20 - n * n * 10) / (n * n)) * 10;
}

test("mask selection is deterministic and picks the lowest-penalty mask", () => {
  const payloads = [
    "A",
    "https://10.150.23.97:3081/__portal/pair?t=CmPflmqoBKfSkgEow-JA9HlkKkK3Gsm0czjEqnR97iE",
    "远程访问：请确认这台设备的登录请求。",
    "x".repeat(120),
    "x".repeat(213),
  ];
  for (const text of payloads) {
    const first = qrSvg(text);
    for (let i = 0; i < 3; i++) assert.equal(qrSvg(text), first, "same input → byte-identical SVG");

    const scores = [];
    for (let mask = 0; mask < 8; mask++) {
      const matrix = qrMatrix(text, { mask });
      scores.push(specPenalty(matrix.modules, matrix.size));
    }
    const best = scores.indexOf(Math.min(...scores));
    assert.equal(decode(first).mask, best, `auto mask is the minimum-penalty mask (${best})`);
  }
});

test("default margin is a 4-module quiet zone and the viewBox is in modules", () => {
  const text = "https://10.150.23.97:3081/__portal/pair?t=abc";
  const svg = qrSvg(text);
  const { version } = decode(svg);
  const n = 17 + 4 * version;
  assert.match(svg, new RegExp(`viewBox="0 0 ${n + 8} ${n + 8}"`), "4 modules on every side");
  assert.match(svg, /width="220"/);
  assert.match(svg, /height="220"/);
  assert.match(svg, /shape-rendering="crispEdges"/);

  // Explicit margins are honoured, including zero.
  for (const margin of [0, 1, 2, 7]) {
    const custom = qrSvg(text, { margin });
    assert.match(custom, new RegExp(`viewBox="0 0 ${n + margin * 2} ${n + margin * 2}"`));
    assert.equal(decodeSvg(custom).version, version, "margin does not change the symbol");
  }
  assert.throws(() => qrSvg(text, { margin: -1 }), RangeError);
  assert.throws(() => qrSvg(text, { margin: 1.5 }), RangeError);
});

test("emits one self-contained accessible SVG and no network references", () => {
  const svg = qrSvg("https://10.150.23.97:3081/", { size: 180, light: "#fff", dark: "#0f1115" });
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" role="img"/);
  assert.match(svg, /aria-label="QR code"/);
  assert.match(svg, /<title>QR code<\/title>/);
  assert.match(svg, /<rect width="\d+" height="\d+" fill="#fff"\/>/, "opaque background when light is set");
  assert.match(svg, /<path d="M\d+ \d+h\d+v1h-\d+z/);
  assert.equal((svg.match(/<path /g) || []).length, 1, "exactly one module path");
  assert.doesNotMatch(svg, /<image|href=|url\(|<script|@import|<foreignObject/i);
  assert.doesNotMatch(qrSvg("x"), /<rect /, "default background is transparent");

  const escaped = qrSvg("x", { label: 'Pair "this" <device> & phone' });
  assert.match(escaped, /aria-label="Pair &quot;this&quot; &lt;device&gt; &amp; phone"/);
  assert.match(escaped, /<title>Pair "this" &lt;device&gt; &amp; phone<\/title>/);

  assert.throws(() => qrSvg("x", { size: 0 }), RangeError);
  assert.throws(() => qrSvg(42), TypeError);
});

test("compactness: run-length paths stay small", () => {
  const text = "https://10.150.23.97:3081/__portal/pair?t=CmPflmqoBKfSkgEow-JA9HlkKkK3Gsm0czjEqnR97iE";
  const svg = qrSvg(text);
  const perModuleEstimate = svg.length / (17 + 4 * decode(svg).version) ** 2;
  assert.ok(perModuleEstimate < 4, `svg is ${svg.length} bytes (${perModuleEstimate.toFixed(2)}/module)`);
});
