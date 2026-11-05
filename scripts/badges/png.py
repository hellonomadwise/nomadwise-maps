import json, pathlib, sys
from playwright.sync_api import sync_playwright
S = pathlib.Path(sys.argv[1]); OUT = pathlib.Path(sys.argv[2]); OUT.mkdir(exist_ok=True)
sizes = json.loads((S / 'sizes.json').read_text())
with sync_playwright() as p:
    br = p.chromium.launch()
    for scale, suf in ((2, ''), (4, '-large')):
        pg = br.new_page(device_scale_factor=scale)
        for name, (w, h) in sizes.items():
            pg.set_viewport_size({'width': w, 'height': h})
            pg.goto((S / f'{name}.svg').resolve().as_uri()); pg.wait_for_timeout(60)
            pg.screenshot(path=str(OUT / f'{name}{suf}.png'), omit_background=True, clip={'x': 0, 'y': 0, 'width': w, 'height': h})
    # preview sheet
    def img(n): w, h = sizes[n]; return f'<img src="{(S / (n + ".svg")).resolve().as_uri()}" width="{w}" height="{h}">'
    sites = [('#ffffff', ['', '-red']), ('#E9E1D3', ['', '-red']), ('#151A21', ['', '-outline']), ('linear-gradient(135deg,#6FB6C8,#22566A)', ['-outline', '-red'])]
    cols = ''
    for bg, sts in sites:
        cols += (f'<div style="background:{bg};padding:18px;border-radius:8px;display:flex;flex-direction:column;gap:12px;width:330px">'
                 + ''.join(img('verified-line' + s) for s in sts)
                 + '<div style="display:flex;gap:12px">' + ''.join(img('verified-square' + s) for s in sts) + '</div></div>')
    free = ''.join(f'<div style="background:{bg};padding:10px;border-radius:8px;display:flex;gap:10px">{img("find-line"+s)}{img("find-square"+s)}</div>' for bg, s in (('#fff', ''), ('#fff', '-red'), ('#151A21', '-outline')))
    pg = br.new_page(device_scale_factor=2); pg.set_viewport_size({'width': 1460, 'height': 520})
    hf = OUT.parent / 'preview3.html'
    hf.write_text(f'<body style="margin:0;padding:16px;font-family:sans-serif;background:#F4F4F2"><div style="display:flex;gap:14px">{cols}</div><div style="display:flex;gap:14px;margin-top:14px">{free}</div></body>')
    pg.goto(hf.resolve().as_uri())
    pg.wait_for_timeout(400); pg.screenshot(path=str(OUT.parent / 'preview3.png'), full_page=True)
    br.close()
