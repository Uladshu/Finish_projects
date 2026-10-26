"""Rebuild the prototype's map data: Wrocław vector tiles (Protomaps/OSM daily build) + Noto Sans glyphs.
Usage: python3 build_tiles.py [YYYYMMDD]  -> wro0..3.txt (base64 tile bundles) and fonts.json
Bundle format (before base64): uint32 header length, JSON {"tiles": {"z/x/y": [offset, length]}}, gzip tiles.
Split: wro0 = z0-13, wro1 = z14, wro2/wro3 = z15 west/east of tile x 17929 (keeps files under 16 MB)."""
import base64, functools, json, math, struct, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pmtiles.reader import Reader  # pip install pmtiles

URL = f'https://build.protomaps.com/{sys.argv[1] if len(sys.argv) > 1 else "20261025"}.pmtiles'
N, W, S, E = 51.2206, 16.7871, 51.0276, 17.1826
FONTS = 'https://raw.githubusercontent.com/protomaps/basemaps-assets/main/fonts/'

@functools.lru_cache(maxsize=4096)
def get_bytes(off, ln):
    req = urllib.request.Request(URL, headers={'Range': f'bytes={off}-{off + ln - 1}', 'User-Agent': 'curl/8.5.0'})
    for _ in range(5):
        try:
            return urllib.request.urlopen(req, timeout=90).read()
        except Exception as e:
            err = e
    raise err

def xy(lat, lng, z):
    n = 2 ** z
    return int((lng + 180) / 360 * n), int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n)

rd = Reader(get_bytes)
coords = []
for z in range(16):
    (x0, y0), (x1, y1) = xy(N, W, z), xy(S, E, z)
    coords += [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
with ThreadPoolExecutor(12) as ex:
    tiles = {c: d for c, d in ex.map(lambda c: (c, rd.get(*c)), coords) if d}
part = lambda z, x: 0 if z <= 13 else 1 if z == 14 else 2 if x < 17929 else 3
for i in range(4):
    index, blob = {}, bytearray()
    for (z, x, y), d in tiles.items():
        if part(z, x) == i:
            index[f'{z}/{x}/{y}'] = [len(blob), len(d)]
            blob += d
    head = json.dumps({'tiles': index}).encode()
    open(f'wro{i}.txt', 'w').write(base64.b64encode(struct.pack('<I', len(head)) + head + blob).decode())
fonts = {}
for f in ('Noto Sans Regular', 'Noto Sans Medium', 'Noto Sans Italic'):
    for r in ('0-255', '256-511', '8192-8447'):
        data = urllib.request.urlopen(FONTS + f.replace(' ', '%20') + f'/{r}.pbf', timeout=60).read()
        fonts[f'{f.replace(" ", "")}/{r}'] = base64.b64encode(data).decode()
json.dump(fonts, open('fonts.json', 'w'))
print(len(tiles), 'tiles written')
