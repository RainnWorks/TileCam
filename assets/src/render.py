#!/usr/bin/env python3
"""Rebuild TileCam README artwork: Python 3, Pillow, librsvg, Liberation Sans.

Run from any directory. The screenshot and icon are read from where the app keeps
them, so a new App Store screenshot or icon is picked up on the next run.
All layout, labels, connectors, and the exact-fit iPad bezel are SVG.
"""
from pathlib import Path
from io import BytesIO
from html import escape
import base64
import shutil
import subprocess
import tempfile
from PIL import Image, ImageOps, ImageFilter

SRC = Path(__file__).resolve().parent
ASSETS = SRC.parent
REPO = ASSETS.parent
SCREENSHOT = REPO / 'fastlane/screenshots/en-US/1_ipad13_grid.png'
ICON = REPO / 'GlassView/Assets.xcassets/AppIcon.appiconset/icon-1024.png'
OUT = Path(tempfile.mkdtemp())
# The deliverable is always a byte-for-byte copy of the shipping icon.
shutil.copyfile(ICON, ASSETS / 'icon-1024.png')
for size in (16, 32):
    Image.open(ASSETS / 'icon-1024.png').resize((size, size), Image.Resampling.LANCZOS).save(OUT / f'icon-preview-{size}.png')

# Split the generated master; normalize faint background noise to pure black.
# Crop only drawings. Never apply this processing to the app screenshot.
master = Image.open(SRC / 'objects-generated.png').convert('L')
w, h = master.size
regions = {'indoor': (0, 0, w//2, h//2), 'bullet': (w//2, 0, w, h//2),
           'doorbell': (0, h//2, w//2, h), 'watch': (w//2, h//2, w, h)}
for name, region in regions.items():
    im = master.crop(region).point(lambda v: 0 if v < 35 else v)
    bounds = im.point(lambda v: 255 if v > 100 else 0).getbbox()
    im = ImageOps.expand(im.crop(bounds), border=12, fill=0)
    # Strengthen object contours for GitHub's 900px and phone-size views.
    im = im.filter(ImageFilter.MaxFilter(5))
    im.save(SRC / f'{name}.png')

def raster(name, x, y, w, h):
    data = base64.b64encode(Path(SRC / name).read_bytes()).decode()
    return f'<image x="{x}" y="{y}" width="{w}" height="{h}" preserveAspectRatio="xMidYMid meet" xlink:href="data:image/png;base64,{data}"/>'

def text(x, y, value, size=44, anchor='middle', fill='white'):
    return f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" fill="{fill}">{escape(value)}</text>'

def line(d, width=3, color='white'):
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>'

def arrow(x1, y, x2):
    return line(f'M{x1} {y} H{x2} M{x2-13} {y-10} L{x2} {y} L{x2-13} {y+10}')

def box(x, y, w, h, radius=22, width=3):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="black" stroke="white" stroke-width="{width}"/>'

def svg(w, h, content, title, desc):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img">
<title>{escape(title)}</title><desc>{escape(desc)}</desc>
<rect width="{w}" height="{h}" fill="#000000"/>
<g fill="white" font-family="Liberation Sans, Arial, sans-serif" font-weight="400">
{content}
</g></svg>'''

# Three simple camera objects, one arrow, one genuine app screen.
hero = raster('indoor.png', 145, 110, 240, 205)
hero += raster('bullet.png', 110, 375, 310, 185)
hero += raster('doorbell.png', 175, 590, 180, 195)
for y, label in [(235, 'Tapo'), (480, 'Reolink'), (710, 'UniFi')]:
    hero += text(470, y, label, 50, 'start')
hero += text(418, 853, 'ONVIF / RTSP', 44)
hero += arrow(790, 450, 1020)
# Exact 3:4 screen aperture: unchanged full screenshot, uniform scaling only.
hero += box(1100, 64, 550, 728, 34)
hero += raster(SCREENSHOT, 1120, 88, 510, 680)
hero += '<circle cx="1375" cy="77" r="3" fill="white"/>'
hero += text(1375, 855, 'TileCam', 54)

# Primary video path: Camera -> go2rtc -> TileCam. The only Watch branch
# starts directly under the iPhone label, passing through the Watch button.
flow = raster('indoor.png', 87, 125, 260, 270)
flow += text(217, 453, 'Camera', 50)
flow += text(217, 511, 'RTSP / ONVIF', 40)
flow += arrow(367, 285, 453)
flow += box(487, 165, 420, 230, 24, 4)
flow += text(697, 265, 'go2rtc', 76)
flow += text(697, 332, 'your server', 44)
flow += text(1044, 251, 'WebRTC', 40)
flow += arrow(937, 285, 1150)
flow += box(1185, 165, 545, 230)
flow += text(1457, 262, 'TileCam', 64)
# Separate text elements anchor the branch unambiguously to iPhone.
flow += text(1227, 332, 'iPhone,', 42, 'start')
flow += text(1384, 332, 'iPad, Mac', 42, 'start')
flow += line('M1290 353 V565 M1280 552 L1290 565 L1300 552')
flow += box(1187, 588, 206, 80, 18)
flow += text(1290, 641, 'Watch', 46)
flow += text(1290, 714, 'button', 36)
flow += text(1550, 549, 'snapshots + audio', 38)
flow += arrow(1420, 628, 1578)
flow += raster('watch.png', 1605, 567, 113, 178)
flow += text(1610, 795, 'Apple Watch', 44)

for name, content, width, height, title, desc in [
    ('hero', hero, 1800, 900, 'TileCam camera grid', 'Tapo, Reolink and UniFi cameras; ONVIF / RTSP. One arrow leads to TileCam on an iPad showing the real six-feed app screenshot.'),
    ('how-it-works', flow, 1800, 850, 'How TileCam works', 'Camera (RTSP / ONVIF) to go2rtc (your server), then WebRTC to TileCam (iPhone, iPad, Mac). The iPhone Watch button sends snapshots + audio to Apple Watch. TileCam connects to go2rtc, never directly to cameras.')
]:
    source = OUT / f'{name}.svg'
    source.write_text(svg(width, height, content, title, desc))
    subprocess.run(['rsvg-convert', str(source), '-o', str(ASSETS / f'{name}.png')], check=True)
    im = Image.open(ASSETS / f'{name}.png').convert('RGB')
    im.save(ASSETS / f'{name}.png', optimize=True)
    for preview_width in (900, 390):
        im.resize((preview_width, round(height * preview_width / width)), Image.Resampling.LANCZOS).save(OUT / f'{name}-preview-{preview_width}.png')
print(f'Rendered hero.png, how-it-works.png; copied shipping icon; SVGs and review previews in {OUT}')
