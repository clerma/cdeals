"""Post-build SEO validator — run against _site/ after `jekyll build`.

Parses every JSON-LD block, asserts exactly one title/description/canonical
per page, and checks internal links. Handles jekyll-redirect-from stub pages
and extensionless permalinks.

Also checks blog posts: BlogPosting JSON-LD, article OG type, and /blog/ index.
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

# Blog index must exist
blog_idx = os.path.join(site, 'blog', 'index.html')
if not os.path.exists(blog_idx):
    print('MISSING: /blog/ index (expected blog/index.html in output)'); fail = True
else:
    blog_html = open(blog_idx).read()
    if 'Our blog' not in blog_html and 'No posts yet' not in blog_html:
        print('blog/index.html: missing expected blog heading or empty state'); fail = True

# Each built post page under blog/YYYY/ must have BlogPosting + article OG
post_pages = []
for f in pages:
    # Match /blog/2026/10/05/slug/index.html style paths
    rel = os.path.relpath(f, site).replace('\\', '/')
    if re.match(r'blog/\d{4}/\d{2}/\d{2}/.+', rel):
        post_pages.append(f)

for f in post_pages:
    html = open(f).read()
    if '"@type": "BlogPosting"' not in html and '"@type":"BlogPosting"' not in html:
        # pretty-printed or compact
        if 'BlogPosting' not in html:
            print(f'{f}: missing BlogPosting JSON-LD'); fail = True
    if 'og:type" content="article"' not in html and "og:type\" content='article'" not in html:
        if 'content="article"' not in html:
            print(f'{f}: expected og:type article'); fail = True

# RSS / Atom feed from jekyll-feed
feed = os.path.join(site, 'feed.xml')
if not os.path.exists(feed):
    print('MISSING: feed.xml (jekyll-feed)'); fail = True

# llms.txt should mention Blog when the file exists
llms = os.path.join(site, 'llms.txt')
if os.path.exists(llms) and 'Blog' not in open(llms).read():
    print('llms.txt: missing Blog entry'); fail = True

hrefs = {h for f in pages for h in re.findall(r'href="(/[^"#?]*)"', open(f).read())}
for h in sorted(hrefs):
    p = site + h
    if not (os.path.exists(p)
            or os.path.exists(p.rstrip('/') + '/index.html')
            or os.path.exists(p.rstrip('/') + '.html')):   # extensionless permalinks
        print('BROKEN LINK:', h); fail = True

if not pages:
    print(f'No HTML pages found in {site}. Did the build fail?'); fail = True
sys.exit(1 if fail else print(f'ALL OK ({len(pages)} pages, {len(post_pages)} posts)'))
