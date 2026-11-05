import re, pathlib
D = pathlib.Path(__file__).parent
PATHS = []
for block in (D / 'logo_icon_paths.txt').read_text().split('\nst')[0:]:
    pass
raw = (D / 'logo_icon_paths.txt').read_text()
for m in re.finditer(r'(st\d)\|(.*?)(?=\nst\d\||\Z)', raw, re.S):
    PATHS.append((m.group(1), re.sub(r'\s+', '', m.group(2))))
COL = {'st0': '#FF444F', 'st1': '#054A58', 'st2': '#EFEFEF', 'st3': '#F0F0F0', 'st4': '#5FD7D8'}
CX, CY, R = 231.279, 223.652, 217.94
VB = (CX - R, CY - R, 2 * R, 2 * R)

def colour_icon(pid):
    return ''.join(f'<path fill="{COL[c]}" d="{d}"/>' for c, d in PATHS)

def white_icon(pid, ink='#fff'):
    clip = f'<clipPath id="{pid}c"><circle cx="{CX}" cy="{CY}" r="{R-10}"/></clipPath>'
    parts = []
    for c, d in PATHS:
        if c == 'st0': continue
        if c in ('st1', 'st3'):
            parts.append(f'<path fill="{ink}" d="{d}"/>')
        elif c == 'st2':
            parts.append(f'<path fill="none" stroke="{ink}" stroke-width="12" stroke-linejoin="round" d="{d}"/>')
        elif c == 'st4':
            parts.append(f'<path fill="none" stroke="{ink}" stroke-width="10" stroke-linejoin="round" d="{d}"/>')
    return (f'<defs>{clip}</defs><g clip-path="url(#{pid}c)">' + ''.join(parts) + '</g>'
            f'<circle cx="{CX}" cy="{CY}" r="{R-8}" fill="none" stroke="{ink}" stroke-width="16"/>')

def icon_svg(kind, pid='i'):
    body = colour_icon(pid) if kind == 'colour' else white_icon(pid)
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{VB[0]:.3f} {VB[1]:.3f} {VB[2]:.3f} {VB[3]:.3f}">{body}</svg>'
