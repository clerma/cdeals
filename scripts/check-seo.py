"""Post-build SEO validator — run against _site/ after `jekyll build`.

Parses every JSON-LD block, asserts exactly one title/description/canonical
per page, and checks internal links. Handles jekyll-redirect-from stub pages
and extensionless permalinks.
"""
import re, json, glob, os, sys

site = sys.argv[1] if len(sys.argv) > 1 else '_site'
fail = False
pages = sorted(set(glob.glob(f'{site}/**/*.html', recursive=True)))
for f in pages:
    html = open(f).read()
    if 'http-equiv="refresh"' in html:
        continue  # jekyll-redirect-from stub pages
    for b in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        try:
            json.loads(b)
        except Exception as e:
            print(f'INVALID JSON-LD in {f}: {e}'); fail = True
    if 'application/ld+json' not in html:
        print(f'{f}: no JSON-LD found'); fail = True
    for tag, n in [('<title>', 1), ('name="description"', 1), ('rel="canonical"', 1)]:
        if html.count(tag) != n:
            print(f'{f}: expected {n} x {tag}, found {html.count(tag)}'); fail = True

# Plain-text files must not be wrapped in an HTML layout
for txt in ('robots.txt', 'llms.txt'):
    p = os.path.join(site, txt)
    if os.path.exists(p) and '<html' in open(p).read():
        print(f'{txt} is wrapped in an HTML layout (add layout: null)'); fail = True

hrefs = {h for f in pages for h in re.findall(r'href="(/[^"#?]*)"', open(f).read())}
for h in sorted(hrefs):
    p = site + h
    if not (os.path.exists(p)
            or os.path.exists(p.rstrip('/') + '/index.html')
            or os.path.exists(p.rstrip('/') + '.html')):   # extensionless permalinks
        print('BROKEN LINK:', h); fail = True

if not pages:
    print(f'No HTML pages found in {site}. Did the build fail?'); fail = True
sys.exit(1 if fail else print(f'ALL OK ({len(pages)} pages)'))
