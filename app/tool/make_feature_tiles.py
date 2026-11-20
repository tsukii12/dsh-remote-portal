#!/usr/bin/env python3
"""Generates lib/ui/common/feature_tile_shapes.g.dart from the tile masters in assets/tiles/.

Run from app/:

    python3 tool/make_feature_tiles.py

One master per style and feature: assets/tiles/<style>/<kind>.svg, for the two vector
styles (duotone, geometric) and the nine features. Every master is plain SVG in a 96 grid
(`viewBox="0 0 96 96"`), drawn with a small subset:

    <rect x y width height rx [transform="rotate(a cx cy)"]>
    <circle cx cy r>
    <path d>               absolute M L H V C Q A Z only
    <g mask="url(#id)">    a layer; the mask's black shapes are cut out of it (a gap
                           between overlapping shapes, a notch)
    <mask id>              in <defs>: a full white rect, then the cut shapes

Each shape carries a class: its tone (`wash`, `mid`, `ink`, `on`, or `cut` inside a mask),
plus `line` for a stroke (round caps and joins, `stroke-width`) or `fat` for a fill with a
stroke of the same tone round it (a triangle with rounded corners). The tones are roles,
not colours: `FeatureTile` resolves them from the theme (the accent and its tones), so the
<style> in each master only colours previews.

Writes the shapes as `Path` builders, in drawing order. Pure Python, no dependencies.

The third style, glass gradient, is painted, not drawn: assets/tiles/glassy/<kind>.webp.
To redo them (or add a feature), generate the set again with GLASSY_PROMPT below and the
app icon as the only reference image, cut it into transparent 512px PNGs named
`<n>-<kind>.png` (n = 1..9 in KINDS order), then

    python3 tool/make_feature_tiles.py --glassy DIR

which fits each picture's ink to the vector sets' keyline (80 of 96) on a 288px canvas
(96dp at 3x) and writes the WebP files. Needs ImageMagick (`magick`).
"""
import math
import os
import re
import sys

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(APP, 'assets', 'tiles')
OUT = os.path.join(APP, 'lib', 'ui', 'common', 'feature_tile_shapes.g.dart')

STYLES = ['duotone', 'geometric']
KINDS = ['terminal', 'files', 'workspace', 'subagents', 'plugins', 'automation', 'models', 'phone', 'community']
TONES = ['wash', 'mid', 'ink', 'on']
NUM = r'-?\d+(?:\.\d+)?'


def f(v):
    s = f'{v:.4f}'.rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def attrs(tag):
    return dict(re.findall(r'([\w:-]+)="([^"]*)"', tag))


def parse_d(d):
    """Dart builder calls for an absolute M L H V C Q A Z path."""
    toks = re.findall(r'[MLHVCQAZ]|' + NUM, d)
    if re.search(r'[mlhvcqaztsTS]', d):
        sys.exit(f'only absolute M L H V C Q A Z: {d}')
    out, i, cmd = [], 0, None
    x = y = 0.0

    def nums(k):
        nonlocal i
        v = [float(t) for t in toks[i:i + k]]
        i += k
        return v

    while i < len(toks):
        t = toks[i]
        if t in 'MLHVCQAZ':
            cmd = t
            i += 1
            if cmd == 'Z':
                out.append('..close()')
                continue
        elif cmd is None:
            sys.exit(f'path must start with a command: {d}')
        if cmd == 'M':
            x, y = nums(2)
            out.append(f'..moveTo({f(x)}, {f(y)})')
            cmd = 'L'  # implicit lineto after a moveto
        elif cmd == 'L':
            x, y = nums(2)
            out.append(f'..lineTo({f(x)}, {f(y)})')
        elif cmd == 'H':
            (x,) = nums(1)
            out.append(f'..lineTo({f(x)}, {f(y)})')
        elif cmd == 'V':
            (y,) = nums(1)
            out.append(f'..lineTo({f(x)}, {f(y)})')
        elif cmd == 'C':
            a, b, c, e, x, y = nums(6)
            out.append(f'..cubicTo({f(a)}, {f(b)}, {f(c)}, {f(e)}, {f(x)}, {f(y)})')
        elif cmd == 'Q':
            a, b, x, y = nums(4)
            out.append(f'..quadraticBezierTo({f(a)}, {f(b)}, {f(x)}, {f(y)})')
        elif cmd == 'A':
            rx, ry, rot, large, sweep, x, y = nums(7)
            # SVG's sweep flag 1 runs clockwise on screen (y down), as `clockwise` does.
            radius = f'const Radius.circular({f(rx)})' if rx == ry else f'const Radius.elliptical({f(rx)}, {f(ry)})'
            rotation = '' if rot == 0 else f', rotation: {f(rot)}'
            out.append(f'..arcToPoint(const Offset({f(x)}, {f(y)}), radius: {radius}{rotation}, '
                       f'largeArc: {str(bool(large)).lower()}, clockwise: {str(bool(sweep)).lower()})')
    return out


def shape(tag, name, a):
    """(tone, dart path expression, stroke width, fill) for one element."""
    cls = a.get('class', '').split()
    tone = [c for c in cls if c in TONES + ['cut']]
    if len(tone) != 1:
        sys.exit(f'{name}: <{tag}> needs exactly one tone class, got {cls}')
    tone = tone[0]
    line, fat = 'line' in cls, 'fat' in cls
    width = float(a.get('stroke-width', '0'))
    if (line or fat) and width <= 0:
        sys.exit(f'{name}: a line / fat shape needs stroke-width')
    for k in ('stroke-linecap', 'stroke-linejoin'):
        if a.get(k, 'round') != 'round':
            sys.exit(f'{name}: only round caps and joins')
    if tag == 'rect':
        x, y, w, h = (float(a[k]) for k in ('x', 'y', 'width', 'height'))
        r = float(a.get('rx', '0'))
        expr = f'Path()..addRRect(RRect.fromLTRBR({f(x)}, {f(y)}, {f(x + w)}, {f(y + h)}, const Radius.circular({f(r)})))'
        if 'transform' in a:
            m = re.fullmatch(r'rotate\((' + NUM + r') (' + NUM + r') (' + NUM + r')\)', a['transform'])
            if not m:
                sys.exit(f'{name}: only rotate(a cx cy) transforms')
            deg, cx, cy = (float(v) for v in m.groups())
            c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
            tx, ty = cx - c * cx + s * cy, cy - s * cx - c * cy
            expr = f'_rotate({expr}, {f(c)}, {f(s)}, {f(tx)}, {f(ty)})'
    elif tag == 'circle':
        cx, cy, r = (float(a[k]) for k in ('cx', 'cy', 'r'))
        expr = f'Path()..addOval(Rect.fromCircle(center: const Offset({f(cx)}, {f(cy)}), radius: {f(r)}))'
    elif tag == 'path':
        calls = parse_d(a['d'])
        expr = 'Path()\n' + '\n'.join('          ' + c for c in calls)
    else:
        sys.exit(f'{name}: unsupported element <{tag}>')
    return tone, expr, width if (line or fat) else 0.0, not line


def dart_shape(tone, expr, width, fill):
    args = [f'TileTone.{tone}' if tone != 'cut' else 'null', expr]
    if width:
        args.append(f'stroke: {f(width)}')
    if not fill:
        args.append('fill: false')
    return 'TileShape(' + ', '.join(args) + ')'


def read_master(style, kind):
    path = os.path.join(SRC, style, f'{kind}.svg')
    svg = open(path, encoding='utf-8').read()
    name = os.path.relpath(path, APP)
    if not re.search(r'viewBox="0 0 96 96"', svg):
        sys.exit(f'{name}: viewBox must be "0 0 96 96"')
    body = re.sub(r'<style>.*?</style>|<!--.*?-->', '', svg, flags=re.S)
    masks = {}
    for m in re.finditer(r'<mask id="([^"]+)">(.*?)</mask>', body, flags=re.S):
        cuts = []
        inner = m.group(2)
        first = True
        for el in re.finditer(r'<(rect|circle|path)\b([^>]*?)/>', inner):
            a = attrs(el.group(2))
            if first:
                first = False
                if el.group(1) == 'rect' and a.get('fill') == '#fff' and 'class' not in a:
                    continue
                sys.exit(f'{name}: a mask starts with its full white rect')
            tone, expr, width, fill = shape(el.group(1), name, a)
            if tone != 'cut':
                sys.exit(f'{name}: mask shapes are class "cut"')
            cuts.append(dart_shape(tone, expr, width, fill))
        masks[m.group(1)] = cuts
    body = re.sub(r'<defs>.*?</defs>', '', body, flags=re.S)

    layers = []  # (shapes, cuts)
    loose = []
    pos = 0
    for m in re.finditer(r'<g mask="url\(#([^)]+)\)">(.*?)</g>|<(rect|circle|path)\b([^>]*?)/>', body, flags=re.S):
        if m.group(1):
            if loose:
                layers.append((loose, []))
                loose = []
            shapes = []
            for el in re.finditer(r'<(rect|circle|path)\b([^>]*?)/>', m.group(2)):
                tone, expr, width, fill = shape(el.group(1), name, attrs(el.group(2)))
                if tone == 'cut':
                    sys.exit(f'{name}: "cut" only inside a mask')
                shapes.append(dart_shape(tone, expr, width, fill))
            if m.group(1) not in masks:
                sys.exit(f'{name}: no mask "{m.group(1)}"')
            layers.append((shapes, masks[m.group(1)]))
        else:
            tone, expr, width, fill = shape(m.group(3), name, attrs(m.group(4)))
            if tone == 'cut':
                sys.exit(f'{name}: "cut" only inside a mask')
            loose.append(dart_shape(tone, expr, width, fill))
        pos = m.end()
    if loose:
        layers.append((loose, []))
    used = sorted({t for shapes, _ in layers for s in shapes for t in TONES if f'TileTone.{t},' in s})
    return layers, used


def dart_layers(layers):
    out = []
    for shapes, cuts in layers:
        inner = ',\n'.join('        ' + s for s in shapes)
        if cuts:
            cut = ',\n'.join('        ' + s for s in cuts)
            out.append(f'    TileLayer([\n{inner},\n      ], cuts: [\n{cut},\n      ])')
        else:
            out.append(f'    TileLayer([\n{inner},\n      ])')
    return ',\n'.join(out)


GLASSY_PROMPT = """\
A set of app feature icons, one per cell of a 3x3 grid on flat chroma green, no plates
behind them. Style: GLASSY GRADIENT, the same material as the reference icon's fish tail
and bubble: smooth soft shapes with gentle gradients from periwinkle blue (#6F86D6)
through soft blue (#9DB7F5) to ice blue (#DCE8FF) and white highlights, a soft inner
glow, a faint lavender-pink rim light (#E9DDFF) on one edge, painted frosted-glass look.
Every icon also contains some deeper periwinkle (#5B73C8) so it reads on a white card.
Shapes are fully opaque paint. No hard outlines, no strokes, no text, no shadows.
Light from the top left; one family: same palette, corner rounding and detail."""

GLASSY_KEYLINE = 80 / 96  # the ink's longer side, as a share of the canvas
GLASSY_PIXELS = 288


def glassy(src):
    import subprocess
    out_dir = os.path.join(SRC, 'glassy')
    os.makedirs(out_dir, exist_ok=True)
    target = round(GLASSY_PIXELS * GLASSY_KEYLINE)
    for n, kind in enumerate(KINDS, 1):
        png = os.path.join(src, f'{n}-{kind}.png')
        box = subprocess.run(['magick', png, '-alpha', 'extract', '-threshold', '3%', '-trim',
                              '-format', '%w %h %X %Y', 'info:'], capture_output=True, text=True, check=True)
        w, h, x, y = (int(v) for v in box.stdout.replace('+', '').split())
        pad = 8  # keep the soft glow just outside the threshold
        scale = target / max(w, h)
        out = os.path.join(out_dir, f'{kind}.webp')
        subprocess.run(['magick', png, '-crop', f'{w + 2 * pad}x{h + 2 * pad}+{x - pad}+{y - pad}', '+repage',
                        '-filter', 'Lanczos', '-resize', f'{round((w + 2 * pad) * scale)}x{round((h + 2 * pad) * scale)}!',
                        '-background', 'none', '-gravity', 'center', '-extent', f'{GLASSY_PIXELS}x{GLASSY_PIXELS}',
                        '-quality', '92', '-define', 'webp:alpha-quality=100', '-define', 'webp:method=6', out],
                       check=True)
        print(f'wrote {os.path.relpath(out, APP)}')


def main():
    blocks = []
    report = []
    for style in STYLES:
        fields = []
        for kind in KINDS:
            layers, used = read_master(style, kind)
            report.append(f'{style}/{kind}: {sum(len(s) for s, _ in layers)} shapes, '
                          f'{sum(1 for _, c in layers if c)} cut layer(s), tones {", ".join(used)}')
            fields.append(f'  static final {kind} = TileArt([\n{dart_layers(layers)},\n  ]);')
        cls = {'duotone': 'DuotoneTiles', 'geometric': 'GeometricTiles'}[style]
        cases = '\n'.join(f'    FeatureKind.{k} => {k},' for k in KINDS)
        fields.append(f'  static TileArt of(FeatureKind kind) => switch (kind) {{\n{cases}\n  }};')
        doc = {
            'duotone': 'Flat duotone: big `wash` shapes, `ink` details.',
            'geometric': 'Minimal geometric: solid primitives in `ink`, `mid` and `wash`, `on` details on `ink`.',
        }[style]
        blocks.append(f'/// {doc}\nabstract final class {cls} {{\n' + '\n\n'.join(fields) + '\n}')

    kinds = '\n'.join(f'  {k},' for k in KINDS)
    out = f'''// GENERATED by tool/make_feature_tiles.py from assets/tiles/duotone/*.svg and
// assets/tiles/geometric/*.svg. Do not edit; change the masters and run the tool.
//
// The vector feature tiles in a 96 grid. `FeatureTile` (feature_tile.dart) draws them
// and resolves each tone from the theme.

// dart format off
import 'dart:typed_data';
import 'dart:ui';

/// The features with a tile, in the masters' order.
enum FeatureKind {{
{kinds}
}}

/// A colour role of a tile, resolved from the theme by `TilePalette`.
enum TileTone {{
  /// The lightest shape that still reads on a card (back sheets, the duotone body).
  wash,

  /// Between [wash] and [ink].
  mid,

  /// The strongest shape: the front body, the details.
  ink,

  /// Details drawn on [ink].
  on,
}}

/// One shape: filled, stroked (round caps and joins), or both. A null [tone] cuts
/// the shape out of its layer.
final class TileShape {{
  const TileShape(this.tone, this.path, {{this.stroke = 0, this.fill = true}});

  final TileTone? tone;
  final Path path;

  /// Stroke width in the 96 grid; 0 draws no stroke.
  final double stroke;

  /// Whether the inside is filled (false for a line).
  final bool fill;
}}

/// Shapes drawn together; [cuts] are erased from them (and only them) afterwards.
final class TileLayer {{
  const TileLayer(this.shapes, {{this.cuts = const []}});

  final List<TileShape> shapes;
  final List<TileShape> cuts;
}}

/// A tile: its layers, bottom first.
final class TileArt {{
  const TileArt(this.layers);

  final List<TileLayer> layers;

  /// The grid every tile is drawn in.
  static const grid = 96.0;
}}

Path _rotate(Path path, double c, double s, double tx, double ty) =>
    path.transform(Float64List.fromList([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]));

''' + '\n\n'.join(blocks) + '\n'
    open(OUT, 'w', encoding='utf-8').write(out)
    print(f'wrote {os.path.relpath(OUT, APP)}')
    for line in report:
        print('  ' + line)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--glassy':
        glassy(sys.argv[2])
    else:
        main()
