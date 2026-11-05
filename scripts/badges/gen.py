import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
import logo
D = pathlib.Path(__file__).parent
OUT = pathlib.Path(sys.argv[1]); OUT.mkdir(exist_ok=True)

class Face:
    def __init__(self, path):
        self.tt = TTFont(path); self.gs = self.tt.getGlyphSet(); self.order = self.tt.getGlyphOrder()
        blob = hb.Blob.from_file_path(str(path)); self.font = hb.Font(hb.Face(blob)); self.upem = self.tt['head'].unitsPerEm
    def shape(self, text):
        buf = hb.Buffer(); buf.add_str(text); buf.guess_segment_properties()
        hb.shape(self.font, buf, {'kern': True, 'liga': False})
        return list(zip(buf.glyph_infos, buf.glyph_positions))
    def width(self, text, size, ls=0.0):
        s = size / self.upem
        g = self.shape(text)
        return sum(p.x_advance for _, p in g) * s + ls * len(g)
    def path(self, text, size, x, base, ls=0.0):
        s = size / self.upem; pen = SVGPathPen(self.gs); cx = x
        for info, pos in self.shape(text):
            name = self.order[info.codepoint]
            tp = TransformPen(pen, (s, 0, 0, -s, cx + pos.x_offset * s, base - pos.y_offset * s))
            self.gs[name].draw(tp)
            cx += pos.x_advance * s + ls
        return pen.getCommands()
M = Face(D / 'roboto-500.ttf'); B = Face(D / 'roboto-700.ttf')

RED, INK, BORDER = '#FF444F', '#3D444D', '#D6D9DE'
STYLES = {
  'white':   dict(bg='#FFFFFF', border=BORDER, bw=1.0, w1=INK, w2=RED, icon='colour'),
  'red':     dict(bg=RED, border=RED, bw=1.0, w1='#FFFFFF', w2='#FFFFFF', icon='white'),
  'outline': dict(bg=None, border='#FFFFFF', bw=1.5, w1='#FFFFFF', w2='#FFFFFF', icon='white'),
}
VB = logo.VB

def icon(x, y, size, style, pid):
    body = logo.colour_icon(pid) if style == 'colour' else logo.white_icon(pid)
    return f'<svg x="{x:.2f}" y="{y:.2f}" width="{size}" height="{size}" viewBox="{VB[0]:.3f} {VB[1]:.3f} {VB[2]:.3f} {VB[3]:.3f}">{body}</svg>'

def tick(x, y, size, style, pid):
    chk = 'M7 12.4l3.2 3.1L17 8.8'
    if style == 'colour':
        inner = (f'<circle cx="12" cy="12" r="10.8" fill="{RED}" stroke="#fff" stroke-width="2.4"/>'
                 f'<path d="{chk}" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>')
    else:
        inner = (f'<defs><mask id="{pid}m"><rect width="24" height="24" fill="#fff"/><path d="{chk}" fill="none" stroke="#000" '
                 f'stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></mask></defs>'
                 f'<circle cx="12" cy="12" r="11.6" fill="#fff" mask="url(#{pid}m)"/>')
    return f'<svg x="{x:.2f}" y="{y:.2f}" width="{size:.2f}" height="{size:.2f}" viewBox="0 0 24 24">{inner}</svg>'

def frame(w, h, st):
    bw = st['bw']; fill = st['bg'] or 'none'
    return (f'<rect x="{bw/2}" y="{bw/2}" width="{w-bw}" height="{h-bw}" rx="{8-bw/2}" '
            f'fill="{fill}" stroke="{st["border"]}" stroke-width="{bw}"/>')

def badge(kind, shape, sname):
    st = STYLES[sname]; v = kind == 'verified'; pid = f'{kind[0]}{shape[0]}{sname[0]}'
    words = 'Verified by' if v else 'Find us on'
    if shape == 'line':
        h = 48; ix, iy, isz = 7, 6, 36
        t1x = ix + isz + 10; s1, s2 = 14, 20.5; ls1, ls2 = 0.1, -0.2
        w1 = M.width(words, s1, ls1); t2x = t1x + w1 + 6; w2 = B.width('nomadwise.io', s2, ls2)
        w = round(t2x + w2 + 16 + 1)
        base = 24 + 0.711 * s2 / 2
        p1 = M.path(words, s1, t1x, base, ls1); p2 = B.path('nomadwise.io', s2, t2x, base, ls2)
    else:
        w = h = 128; isz = 54; ix = (w - isz) / 2; iy = 17
        s1, s2 = 12.5, 16.5; ls1, ls2 = 0, -0.1
        w1 = M.width(words, s1, ls1); w2 = B.width('nomadwise.io', s2, ls2)
        p1 = M.path(words, s1, (w - w1) / 2, 88, ls1); p2 = B.path('nomadwise.io', s2, (w - w2) / 2, 108, ls2)
    tk = isz * 0.44
    tx, ty = ix + isz + 3 - tk, iy + isz + 3 - tk
    ic = icon(ix, iy, isz, st['icon'], pid)
    if v and st['icon'] == 'white':
        # a small gap around the white tick, so it does not run into the
        # white ring of the logo (the badge colour shows through)
        gap = tk * 0.14
        ic = (f'<defs><mask id="{pid}g" maskUnits="userSpaceOnUse" x="0" y="0" width="{w}" height="{h}">'
              f'<rect width="{w}" height="{h}" fill="#fff"/>'
              f'<circle cx="{tx + tk/2:.2f}" cy="{ty + tk/2:.2f}" r="{tk/2 + gap:.2f}" fill="#000"/></mask></defs>'
              f'<g mask="url(#{pid}g)">{ic}</g>')
    parts = [frame(w, h, st), ic]
    if v: parts.append(tick(tx, ty, tk, st['icon'], pid))
    parts += [f'<path fill="{st["w1"]}" d="{p1}"/>', f'<path fill="{st["w2"]}" d="{p2}"/>']
    title = f'{words} nomadwise.io'
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="{title}">'
           f'<title>{title}</title>' + ''.join(parts) + '</svg>')
    return svg, w, h

sizes = {}
for kind in ('find', 'verified'):
    for shape in ('line', 'square'):
        for sname, suf in (('white', ''), ('red', '-red'), ('outline', '-outline')):
            svg, w, h = badge(kind, shape, sname)
            name = f'{kind}-{shape}{suf}'
            (OUT / f'{name}.svg').write_text(svg)
            sizes[name] = (w, h)
print(sizes)
import json; (OUT / 'sizes.json').write_text(json.dumps(sizes))
