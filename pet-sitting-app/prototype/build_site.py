"""Build a standalone site from the prototype for any static HTTPS host (Netlify Drop, Cloudflare Pages, GitHub Pages).
Usage: python3 build_site.py  -> dist/ and pupilobok-site.zip (needs wro0..3.txt and fonts.json from build_tiles.py).
On its own HTTPS domain the browser shows the normal "allow location?" prompt (blocked inside the Claude preview)."""
import pathlib, shutil, zipfile

here = pathlib.Path(__file__).parent
dist = here / 'dist'
shutil.rmtree(dist, ignore_errors=True); dist.mkdir()
page = (here / 'index.html').read_text(encoding='utf-8')
head = ('<!doctype html><html lang="pl"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
        '<meta name="theme-color" content="#f63f3f"><style>body{margin:0}</style></head><body>')
(dist / 'index.html').write_text(head + page.replace('<meta charset="utf-8">', '', 1) + '</body></html>', encoding='utf-8')
for f in ['streets.json', 'fonts.json', 'wro0.txt', 'wro1.txt', 'wro2.txt', 'wro3.txt']:
    shutil.copy(here / f, dist / f)
import os
if os.environ.get('NETLIFY') or os.environ.get('SITE_ONLY'):  # on the hosting only the site itself is needed
    print('dist/ ready for Netlify'); raise SystemExit(0)
for f in (here / 'launch').iterdir():  # one-click local test: Windows .bat + PowerShell server, Mac/Linux .command, instructions
    shutil.copy(f, dist / f.name)
with zipfile.ZipFile(here / 'pupilobok-site.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for f in dist.iterdir():
        info = zipfile.ZipInfo(f.name, date_time=(2026, 10, 27, 12, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (0o755 if f.suffix in ('.command', '.sh') else 0o644) << 16
        z.writestr(info, f.read_bytes())
print('dist/ ready,', round((here / 'pupilobok-site.zip').stat().st_size / 1e6, 1), 'MB zip')
