#!/usr/bin/env python3
"""Builds the app's icon font, assets/fonts/DshIcons.ttf, and its code-point table.

Run from app/:

    python3 tool/make_icon_font.py [--phosphor PATH]

Needs fonttools and skia-pathops (`pip install fonttools skia-pathops`, a venv is fine).

The glyph list comes from lib/ui/theme/app_icons.dart: every `DshGlyphs.<name>` it
mentions goes into the font, nothing else. Names map to sources by convention:

    fooBar         Phosphor Regular  tool/icons/phosphor/regular/foo-bar.svg
    fooBarFill     Phosphor Fill     tool/icons/phosphor/fill/foo-bar-fill.svg
    a CUSTOM name  drawn below on Phosphor's grid from Phosphor parts

Phosphor sources (@phosphor-icons/core, MIT) are vendored per glyph. A name that is not
vendored yet is copied in from --phosphor, the root of an unpacked @phosphor-icons/core
package (the folder holding assets/).

Every glyph is scaled up 10 % about the centre of Phosphor's 256 grid: Phosphor leaves
more air inside the grid than Material did, so at the same `size:` it read about 10 %
smaller. The em box is the icon box (ascent = em, descent = 0, as in MaterialIcons), so
`Icon` places a glyph exactly where it places a Material one.

Writes
    assets/fonts/DshIcons.ttf          the font
    lib/ui/theme/dsh_glyphs.dart       one const IconData per glyph
    tool/icons/codepoints.json         name -> code point; a glyph keeps its code point
                                       across runs, new names take the next free one
"""
import argparse
import json
import math
import os
import re
import shutil
import sys

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.misc.timeTools import timestampFromString
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(APP, 'tool', 'icons')
VENDOR = os.path.join(ICONS, 'phosphor')
CODEPOINTS = os.path.join(ICONS, 'codepoints.json')
TOKENS = os.path.join(APP, 'lib', 'ui', 'theme', 'app_icons.dart')
OUT_FONT = os.path.join(APP, 'assets', 'fonts', 'DshIcons.ttf')
OUT_DART = os.path.join(APP, 'lib', 'ui', 'theme', 'dsh_glyphs.dart')

FAMILY = 'DshIcons'
PHOSPHOR_VERSION = '2.1.1'
GRID = 256  # Phosphor's design grid
STROKE = 16  # Phosphor Regular's stroke in that grid
EM = 1024
OPTICAL = 1.10  # see the docstring
FIRST_CODEPOINT = 0xE000

# Glyphs whose meaning follows reading direction: mirrored under RTL, as their Material
# counterparts were (arrow_back, chevron_right, reply, open_in_new, send, short_text…).
# Per-glyph optical corrections on top of OPTICAL, where one Phosphor glyph sits in a
# place its grid size doesn't suit. stopFill is the square inside the composer's round
# send/stop key: at Phosphor's 75 % of the em it fills the key; 55 % matches the
# arrow it replaces in weight.
OPTICAL_BY_GLYPH = {'stopFill': 0.80}

MIRRORED = {
    'arrowLeft', 'arrowRight', 'caretRight', 'arrowSquareOut', 'arrowBendUpLeft',
    'paperPlaneRight', 'textAlignLeft', 'textWrap',
}


# ── Geometry on Phosphor's grid (y down) ─────────────────────────────────────────────

def path_from_d(d):
    path = pathops.Path()
    parse_path(d, path.getPen())
    return path


def phosphor(name, weight='regular'):
    """A vendored Phosphor glyph as one filled path."""
    svg = open(vendored(name, weight), encoding='utf-8').read()
    path = pathops.Path()
    for d in re.findall(r'<path[^>]*\sd="([^"]+)"', svg):
        path.addPath(path_from_d(d))
    return simplify(path)


def stroked(d, width=STROKE):
    """An open centre line drawn the way Phosphor draws: round caps, round joins."""
    path = path_from_d(d)
    path.stroke(width, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    path.convertConicsToQuads()
    return simplify(path)


def disk(c, r):
    k = 0.5522847498 * r
    x, y = c
    path = pathops.Path()
    path.moveTo(x + r, y)
    path.cubicTo(x + r, y + k, x + k, y + r, x, y + r)
    path.cubicTo(x - k, y + r, x - r, y + k, x - r, y)
    path.cubicTo(x - r, y - k, x - k, y - r, x, y - r)
    path.cubicTo(x + k, y - r, x + r, y - k, x + r, y)
    path.close()
    return path


def polygon(points):
    path = pathops.Path()
    path.moveTo(*points[0])
    for p in points[1:]:
        path.lineTo(*p)
    path.close()
    return path


def simplify(path):
    return pathops.simplify(path, fix_winding=True, keep_starting_points=False)


def union(*paths):
    out = paths[0]
    for p in paths[1:]:
        out = pathops.op(out, p, pathops.PathOp.UNION, keep_starting_points=False)
    return out


def minus(a, b):
    return pathops.op(a, b, pathops.PathOp.DIFFERENCE, keep_starting_points=False)


def meet(a, b):
    return pathops.op(a, b, pathops.PathOp.INTERSECTION, keep_starting_points=False)


def add(a, b, s=1.0):
    return (a[0] + b[0] * s, a[1] + b[1] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def unit(v):
    n = math.hypot(*v)
    return (v[0] / n, v[1] / n)


# Phosphor's slash runs from (48, 40) to (208, 216) in every *-slash glyph.
SLASH_FROM, SLASH_TO = (48.0, 40.0), (208.0, 216.0)
SLASH_D = unit((SLASH_TO[0] - SLASH_FROM[0], SLASH_TO[1] - SLASH_FROM[1]))
SLASH_N = (SLASH_D[1], -SLASH_D[0])  # points to the upper-right side
# The parts above the slash stop short of it: their centre line ends 32 from the slash's
# centre line, i.e. a clear gap of one stroke between the slash and the round cap.
SLASH_END = 32.0


def band(offset_from, offset_to, normal=SLASH_N, origin=SLASH_FROM):
    """The strip offset_from <= normal·(p - origin) <= offset_to, long enough for the grid."""
    t = (normal[1], -normal[0])
    o = origin
    return polygon([
        add(add(o, normal, offset_from), t, -1000), add(add(o, normal, offset_from), t, 1000),
        add(add(o, normal, offset_to), t, 1000), add(add(o, normal, offset_to), t, -1000),
    ])


def crossings(path, offset):
    """Midpoints of the runs where `path` crosses the line SLASH_N·(p - SLASH_FROM) = offset."""
    cut = meet(path, band(offset - 0.25, offset + 0.25))
    out = []
    for contour in cut.contours:
        pts = [p for _, ps in contour.segments for p in ps if p is not None]
        if not pts:
            continue
        along = [dot((p[0] - SLASH_FROM[0], p[1] - SLASH_FROM[1]), SLASH_D) for p in pts]
        mid = (min(along) + max(along)) / 2
        out.append(add(add(SLASH_FROM, SLASH_N, offset), SLASH_D, mid))
    return out


def stroke_ends(base):
    """(centre, direction away from the slash) of each stroke `base` takes across the cut line.

    Works for strokes that cross the line cleanly; a stroke running nearly along it, or two
    strokes that merge on it, needs its part above the slash drawn (`slash(above_d=…)`).
    """
    ends = []
    for m in crossings(base, SLASH_END):
        near = [p for p in crossings(base, SLASH_END - 4) if math.dist(p, m) < 12]
        far = [p for p in crossings(base, SLASH_END + 4) if math.dist(p, m) < 12]
        a = min(near, key=lambda p: math.dist(p, m)) if near else m
        b = min(far, key=lambda p: math.dist(p, m)) if far else m
        t = unit((b[0] - a[0], b[1] - a[1])) if a != b else SLASH_N
        ends.append((m, t))
    return ends


def offset_of(p):
    return dot((p[0] - SLASH_FROM[0], p[1] - SLASH_FROM[1]), SLASH_N)


def end_on_line(a, b):
    """Where the straight centre line a→b reaches the cap position, heading away."""
    oa, ob = offset_of(a), offset_of(b)
    k = (SLASH_END - oa) / (ob - oa)
    p = (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k)
    t = unit((b[0] - a[0], b[1] - a[1]))
    return p, (t if dot(t, SLASH_N) > 0 else (-t[0], -t[1]))


def end_on_circle(c, r, side):
    """Where the centre-line circle (c, r) reaches the cap position; side ±1 picks which."""
    k = (SLASH_END - offset_of(c)) / r
    s = math.sqrt(1 - k * k) * side
    u = (SLASH_N[0] * k + SLASH_D[0] * s, SLASH_N[1] * k + SLASH_D[1] * s)
    t = (u[1], -u[0])
    return add(c, u, r), (t if dot(t, SLASH_N) > 0 else (-t[0], -t[1]))


def slash(base, above_d=None):
    """Phosphor's *-slash treatment of `base`.

    Below the slash the glyph runs into it and merges; above it, each stroke the slash cuts
    stops with a round cap whose centre sits 32 from the slash's centre line, a clear gap of
    one stroke width. Checked against Phosphor's own cloud-, bell-, chat-circle-, push-pin-,
    shield- and pencil-simple-slash: the outlines differ by under 0.3 % of their area.

    Where strokes run along the cut or meet near it, the automatic cut leaves debris; pass
    the part above the slash as its centre line instead (`above_d`, cap to cap), and it is
    drawn with Phosphor's stroke, which is how Phosphor's outlines were made.
    """
    below = meet(base, band(-1000, 0))
    line = stroked(f'M{SLASH_FROM[0]},{SLASH_FROM[1]}L{SLASH_TO[0]},{SLASH_TO[1]}')
    if above_d is not None:
        return union(below, line, stroked(above_d))
    above = meet(base, band(SLASH_END - STROKE / 2, 1000))
    for m, t in stroke_ends(base):
        # Square the stroke off across itself at m, then round it.
        behind = meet(disk(m, 2 * STROKE), band(-1000, 0, normal=t, origin=m))
        above = union(minus(above, behind), disk(m, STROKE / 2))
    # What is left inside the gap without reaching out of it is debris of strokes that run
    # along the cut; it goes, with any hole inside it.
    clear = band(SLASH_END + STROKE / 2 + 2, 1000)
    contours = sorted(above.contours, key=lambda c: -abs(c.area))
    outer_turn = contours[0].clockwise if contours else True
    outers = [c for c in contours if c.clockwise == outer_turn and abs(meet(c, clear).area) > 1]
    kept = pathops.Path()
    for c in contours:
        if c in outers or (c.clockwise != outer_turn
                           and any(o.contains(c.firstPoints[0]) for o in outers)):
            kept.addPath(c)
    return union(below, line, kept)


def folder_slash_above():
    """folder's centre lines above the slash: top edge (y 80) from its cap, down the right side."""
    (x0, y0), _ = end_on_line((32, 80), (224, 80))
    (x1, y1), _ = end_on_line((224, 208), (224, 80))
    return f'M{x0:.3f},{y0}H216A8,8,0,0,1,224,88V{y1:.3f}'


def puzzle_slash_above():
    """puzzle-piece's centre lines above the slash, cap to cap."""
    (kx, ky), _ = end_on_circle((136, 52), 28, -1)
    (nx, ny), _ = end_on_circle((204, 140), 28, -1)
    joint = 140 - math.sqrt(28 ** 2 - 12 ** 2)  # where the notch leaves the right side
    knob = 136 + math.sqrt(28 ** 2 - 12 ** 2)  # where the knob lands on the top edge
    return (f'M{kx:.3f},{ky:.3f}A28,28,0,1,1,{knob:.3f},64H208A8,8,0,0,1,216,72'
            f'V{joint:.3f}A28,28,0,0,0,{nx:.3f},{ny:.3f}')


def folder_body_mark(mark_d):
    """`folder` with a mark centred in its body, as folder-plus / folder-minus place theirs."""
    return union(phosphor('folder'), stroked(mark_d))


# Drawn glyphs. Each is built from Phosphor's own outlines and its 16-unit round stroke,
# following an existing Phosphor family (*-slash, magnifying-glass-plus, folder-plus).
CUSTOM = {
    # *-slash: key_off, folder_off, extension_off
    'keySlash': lambda: slash(phosphor('key')),
    # The tab's slope runs along the cut, so folder's part above it is given as a centre
    # line: the body's top edge (y 80) from its cap, round the corner, down the right side.
    'folderSlash': lambda: slash(phosphor('folder'), above_d=folder_slash_above()),
    # The top knob (centre line r 28 about (136, 52)) meets the top edge right at the cut.
    # Above the slash: knob, top edge, right side, notch (r 28 about (204, 140)) to its cap;
    # the notch's lower lip would be a lone hook between two gaps, so it goes.
    'puzzlePieceSlash': lambda: slash(phosphor('puzzle-piece'), above_d=puzzle_slash_above()),
    # search_off. The slash would run along the handle, so the mark goes inside the lens,
    # where magnifying-glass-plus / -minus put theirs.
    'magnifyingGlassX': lambda: union(
        phosphor('magnifying-glass'), stroked('M88,88L136,136M136,88L88,136')),
    # drive_file_move: folder-plus with an arrow (file-arrow-up's proportions) for the plus.
    'folderArrowRight': lambda: folder_body_mark('M96,144H160M136,120L160,144L136,168'),
    # The detail panel opens on the right; sidebar-simple has its bar on the left.
    'sidebarSimpleRight': lambda: phosphor('sidebar-simple').transform(-1, 0, 0, 1, GRID, 0),
    # wrap_text: text-align-left's lines, the middle one turning back under itself.
    'textWrap': lambda: union(
        stroked('M40,64H216'),
        stroked('M40,128H176A32,32,0,0,1,176,192H136M160,168L136,192L160,216'),
        stroked('M40,192H96')),
}


# ── Sources ──────────────────────────────────────────────────────────────────────────

def kebab(name):
    return re.sub(r'([A-Z])', lambda m: '-' + m.group(1).lower(), name)


def source_of(name):
    """(weight, phosphor file stem) for a non-custom glyph name."""
    if name.endswith('Fill'):
        return 'fill', kebab(name[:-4]) + '-fill'
    return 'regular', kebab(name)


def vendored(stem, weight):
    return os.path.join(VENDOR, weight, stem + '.svg')


def vendor(names, package):
    """Copies missing Phosphor sources in from the package; fails on what it cannot find."""
    stems = {source_of(n) for n in names if n not in CUSTOM}
    # The drawn glyphs are built from these.
    stems |= {('regular', s) for s in ('key', 'folder', 'puzzle-piece', 'magnifying-glass', 'sidebar-simple')}
    missing = []
    for weight, stem in sorted(stems):
        dst = vendored(stem, weight)
        if os.path.exists(dst):
            continue
        src = os.path.join(package or '', 'assets', weight, stem + '.svg')
        if package and os.path.exists(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        else:
            missing.append(f'{weight}/{stem}.svg')
    if missing:
        sys.exit('Not vendored (pass --phosphor PATH to copy them in): ' + ', '.join(missing))
    if package:
        shutil.copyfile(os.path.join(package, 'LICENSE'), os.path.join(VENDOR, 'LICENSE'))


def glyph_names():
    """Every DshGlyphs.<name> app_icons.dart uses, in first-use order."""
    seen = []
    for line in open(TOKENS, encoding='utf-8'):
        if line.lstrip().startswith('//'):
            continue  # doc examples
        for name in re.findall(r'DshGlyphs\.(\w+)', line):
            if name not in seen:
                seen.append(name)
    return seen


def outline(name):
    if name in CUSTOM:
        return simplify(CUSTOM[name]())
    weight, stem = source_of(name)
    return phosphor(stem, weight)


# ── Font ─────────────────────────────────────────────────────────────────────────────

def ttglyph(path, optical=OPTICAL):
    """`path` from the 256 grid (y down) into the em (y up), scaled by `optical` about the centre."""
    s = EM / GRID * optical
    c = GRID / 2
    pen = TTGlyphPen(None)
    # The y flip reverses every contour; reversing again keeps TrueType's clockwise outers.
    flip = TransformPen(Cu2QuPen(pen, max_err=0.5, reverse_direction=True),
                        (s, 0, 0, -s, EM / 2 - c * s, EM / 2 + c * s))
    path.draw(flip)
    return pen.glyph()


def assign_codepoints(names):
    table = json.load(open(CODEPOINTS)) if os.path.exists(CODEPOINTS) else {}
    nxt = max(table.values(), default=FIRST_CODEPOINT - 1) + 1
    for name in names:
        if name not in table:
            table[name] = nxt
            nxt += 1
    with open(CODEPOINTS, 'w') as f:
        json.dump(dict(sorted(table.items(), key=lambda kv: kv[1])), f, indent=1)
        f.write('\n')
    return {n: table[n] for n in names}


def build_font(names, codepoints):
    names = sorted(names, key=lambda n: codepoints[n])  # bytes depend on the set, not token order
    order = ['.notdef'] + names
    glyphs = {'.notdef': TTGlyphPen(None).glyph()}
    for name in names:
        glyphs[name] = ttglyph(outline(name), OPTICAL_BY_GLYPH.get(name, OPTICAL))
    fb = FontBuilder(EM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({codepoints[n]: n for n in names})
    fb.setupGlyf(glyphs)
    metrics = {}
    for name in order:
        g = glyphs[name]
        g.recalcBounds(fb.font['glyf'])
        metrics[name] = (EM, getattr(g, 'xMin', 0))
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=EM, descent=0, lineGap=0)
    fb.setupNameTable({
        'familyName': FAMILY,
        'styleName': 'Regular',
        'uniqueFontIdentifier': f'{FAMILY}-Regular',
        'fullName': f'{FAMILY} Regular',
        'psName': f'{FAMILY}-Regular',
        'version': 'Version 1.000',
        'copyright': 'Glyphs from Phosphor Icons, Copyright (c) 2023 Phosphor Icons, MIT License.',
        'description': f'dsh-go icon subset of Phosphor Icons {PHOSPHOR_VERSION} Regular and Fill, '
                       'made by tool/make_icon_font.py.',
    })
    fb.setupOS2(version=4, sTypoAscender=EM, sTypoDescender=0, sTypoLineGap=0,
                usWinAscent=EM, usWinDescent=0, fsSelection=0x80 | 0x40,  # USE_TYPO_METRICS | REGULAR
                achVendID='DSH ', fsType=0)
    fb.setupPost(keepGlyphNames=True)
    fb.setupMaxp()
    # Fixed dates keep the bytes reproducible.
    fb.font['head'].created = fb.font['head'].modified = timestampFromString('Sat Oct 24 00:00:00 2026')
    os.makedirs(os.path.dirname(OUT_FONT), exist_ok=True)
    fb.save(OUT_FONT)


# ── Dart ─────────────────────────────────────────────────────────────────────────────

def write_dart(names, codepoints):
    lines = [
        '// GENERATED by tool/make_icon_font.py from lib/ui/theme/app_icons.dart. Do not edit.',
        '//',
        f'// Glyphs: Phosphor Icons {PHOSPHOR_VERSION} (https://phosphoricons.com), MIT, Copyright (c) 2023',
        '// Phosphor Icons; the drawn ones are built from its outlines. See THIRD_PARTY_NOTICES.md.',
        '',
        "import 'package:flutter/widgets.dart';",
        '',
        '/// The glyphs of `assets/fonts/DshIcons.ttf`, named after their Phosphor source',
        '/// (`…Fill` is the Fill weight). Widgets use [AppIcons] roles, never these.',
        '///',
        '/// The font is declared in this app\'s own pubspec, so no `fontPackage`.',
        'abstract final class DshGlyphs {',
        f"  static const family = '{FAMILY}';",
        '',
    ]
    for name in sorted(names):
        mirror = ', matchTextDirection: true' if name in MIRRORED else ''
        tag = '  // drawn' if name in CUSTOM else ''
        lines.append(f'  static const {name} = IconData(0x{codepoints[name]:x}, fontFamily: family{mirror});{tag}')
    lines += ['', '  /// Every glyph by name, for the icon sheet test.',
              '  static const all = <String, IconData>{']
    lines += [f"    '{name}': {name}," for name in sorted(names)]
    lines += ['  };', '}', '']
    with open(OUT_DART, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--phosphor', help='root of an unpacked @phosphor-icons/core package')
    args = ap.parse_args()
    names = glyph_names()
    if not names:
        sys.exit(f'No DshGlyphs.<name> in {TOKENS}')
    vendor(names, args.phosphor)
    codepoints = assign_codepoints(names)
    build_font(names, codepoints)
    write_dart(names, codepoints)
    custom = sum(1 for n in names if n in CUSTOM)
    print(f'{len(names)} glyphs ({custom} drawn), {os.path.getsize(OUT_FONT)} bytes -> '
          f'{os.path.relpath(OUT_FONT, APP)}, {os.path.relpath(OUT_DART, APP)}')


if __name__ == '__main__':
    main()
