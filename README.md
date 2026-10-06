# cDeals

A Jekyll site built on the Cartzilla 3 electronics store design that does two jobs:

1. **Sells my used tech.** Items have an **Add to cart** button powered by [AnyCart](https://anycart.co). AnyCart adds a cart drawer, checks prices and stock on its server, and sends buyers to Stripe or Square checkout. There's no server or database to run ($5/month + 1.5% per sale).
2. **Shares deals.** Affiliate items link out to Amazon, Best Buy, and other stores with `rel="sponsored"` and an FTC disclosure.

## Run locally

```sh
bundle install
bundle exec jekyll serve   # http://localhost:4000
```

## Add an item

Create one file per item in `_products/` (or use the CloudCannon "Products" form). Copy one of the samples:

| Field | Item I'm selling (`type: sale`) | Affiliate deal (`type: affiliate`) |
|---|---|---|
| `title`, `category`, `price`, `images`, `highlights` | ✓ | ✓ |
| `brand` (search + brand logos on the home page) | optional | optional |
| `compare_at` (original/list price: shown crossed out with a -NN% badge, only when higher than `price`; leave it out if you don't have a real figure) | optional | optional |
| `status` (`available` / `sold`) | ✓ | – |
| `condition`, `shipping` | ✓ | – |
| `anycart_id` (product ID in AnyCart) | ✓ | – |
| `store`, `affiliate_url` | – | ✓ |
| `expires` (hides the deal after this date) | – | optional |

The text under the front matter becomes the item description. Put photos in `assets/uploads/`.

## Setting up AnyCart

1. Create an AnyCart store and connect Stripe (or Square) on its Billing page.
2. Copy your public key (`ac_live_...`) into `anycart_api_key` in `_config.yml`. The cart script only loads once this is set.
3. For each item you sell, add a product in the AnyCart dashboard with the same price. Set **stock to 1** for one-off used items so it can't sell twice.
4. Put that product's ID in the item's `anycart_id`.
5. After it sells, set `status: sold`. The item stays up with a "Sold" badge.

AnyCart re-checks every price at checkout against its dashboard, so the price in the item file only controls what the page and cart show. Keep the two in sync.

## Affiliate links

| Store | What to paste in `affiliate_url` |
|---|---|
| Amazon | Your Amazon Associates link (SiteStripe or `?tag=yourtag-20`). Sovrn and Skimlinks don't pay on Amazon. |
| Any other store (Woot, MacSales/OWC, Office Depot, Best Buy, ...) | The plain product link, once `sovrn_key` or `skimlinks_id` is set in `_config.yml`. Their script turns it into an affiliate link when clicked. |
| A store you joined directly (Impact, CJ) | That network's tracking link. You keep the full commission. |

Sovrn and Skimlinks keep about 25% of commissions, so join a store directly once it sends you a lot of sales. Set only one of the two keys.

## Settings

Edit the top of `_config.yml`: `title`, `tagline`, `url`, `contact_email`, `affiliate_disclosure`, plus `legal_name`, `governing_law_state`, and `hosting_provider` for the policy pages.

## Policy pages

`disclosure.md` (/disclosure/), `terms.md` (/terms/), `privacy.md` (/privacy/), and `returns.md` (/returns/) are Markdown pages on the `page` layout, linked from the footer. Each has an `updated:` date, shown as "Last updated", so change it whenever you edit a policy. Anything in `[BRACKETS]` is a placeholder you still need to fill in:

- `_config.yml`: `legal_name`, `governing_law_state`, `hosting_provider`.
- `returns.md` front matter: where you ship, shipping cost, return window, who pays return shipping, restocking fee, refund timing, and how long buyers have to report shipping damage.

These pages are a starting point, not legal advice.

## Selling mode (automatic)

While none of your own items is for sale (no `_products/` item with `type: sale` and `status: available`), the site reads as a deals site: the footer tagline and site/meta description switch to `tagline_no_sale` / `description_no_sale` in `_config.yml`, the home page uses its `title_no_sale` / `description_no_sale`, and the "Returns & shipping" and "All items for sale" links, the shop hero slides, the selling part of About and the "I also sell my own used items" part of the disclosure are hidden. The shop and returns pages still exist but are left out of `sitemap.xml`. Publish one sale item and all of it comes back on the next build. The switch is `_plugins/selling_mode.rb`; templates use `{% if site.selling %}`. The Terms, Privacy and Returns pages keep their selling sections.

## Amazon-only switch (affiliate networks)

Deals at stores other than Amazon only earn through Skimlinks. While Skimlinks is pending, `_config.yml` has:

```yaml
affiliate_networks:
  skimlinks_active: false
```

and every non-Amazon deal is left out of the whole site: no `/item/` page, card, filter, category pill, search entry, schema, `sitemap.xml` or `llms.txt` line. Category pages with no live deals left aren't built. A deal counts as Amazon when its `store` is Amazon or its `affiliate_url` is on amazon.com / amzn.to; your own `type: sale` items are never hidden. The deal finder keeps saving non-Amazon deals to `_products/`, so they're ready. Meta text that names other stores switches to the `*_amazon_only` values (in `_config.yml`, `index.html`, `deals.html`). Set `skimlinks_active: true` and everything comes back on the next build. The switch is `_plugins/affiliate_networks.rb`.

## Hosting

The output is a static site, so it can be hosted for free on CloudCannon, Netlify, Cloudflare Pages, or GitHub Pages (via a GitHub Action, because this site uses Jekyll 4). Expired deals are hidden at build time, so schedule a daily rebuild if you use `expires`.

## SEO, AI answers (AIO/GEO)

One include, `_includes/seo.html`, outputs every page's title, description, canonical URL, Open Graph/Twitter tags and structured data (JSON-LD). There's no SEO plugin.

| Schema | Where | Source |
|---|---|---|
| WebSite (+ site search box) | every page | `_config.yml` |
| OnlineStore (the business; Organization while nothing is for sale) | every page | `_config.yml` + `_data/company.yml` |
| WebPage + BreadcrumbList | every page | page front matter |
| Product + Offer | each item in `_products` | item front matter (price, condition, sold/in stock, brand, store) |
| CollectionPage + ItemList | For sale, Deals | `show_collection` / `collection_type` front matter |
| FAQPage | About | `_data/faqs.yml` (only when it has entries) |
| Reviews / rating | OnlineStore | `_data/testimonials.yml`, `rating_value` / `review_count` (only when real) |

**Amazon prices:** with `amazon_show_prices: true` (current), Amazon deals show the stored front-matter price and Product/Offer schema. Strikethrough/-NN% only when `compare_at` > `price` from the source. CTA: "See the savings on Amazon". With `false`, numbers are hidden (badge + CTA only; no Offer schema).

**Selling mode:** while nothing of mine is for sale, the business schema is a plain Organization (no payment methods or buyer reviews), the site search box points at `/deals/?q=`, `/llms.txt` leaves out the shop, returns and "For sale now" parts, and `/shop/` and `/returns/` are `noindex` and out of `sitemap.xml`. All of it switches back when a sale item is published.

Optional data stays out of the markup until it's real. Add the first FAQ or review and both the About page section and the schema appear together.

**Per-page front matter:** `title` (60 characters max), `description` (150–160), `image`, `breadcrumb_title`, `noindex: true`, `canonical_url`. Items get their description and image from their own fields automatically.

**For AI crawlers:** `/llms.txt` lists the pages, everything for sale and the current deals in plain Markdown, rebuilt with the site. `/robots.txt` and `/sitemap.xml` are generated too.

**Check before publishing:**
```
bundle exec jekyll build && python3 scripts/check-seo.py _site
```

## Home page and theme

Every page's content lives in its own front matter (or Markdown body):

| File | What it controls |
|---|---|
| `index.html` front matter | Home page: hero slides, feature row, section headings, banners, brand logos |
| `shop.html` / `deals.html` front matter | Headings, empty-state text, disclosure toggle |
| `about.md` body | About page text (Markdown, `layout: page`) |
| `thanks.md`, `404.md` front matter | Message, icon, and buttons (`layout: message`) |
| `_products/*.md` | Each item: front matter fields + description in the body |
| `_data/navigation.yml` | Main menu links |
- `_data/categories.yml` is the fixed list of deal categories (slug, name, icon). Each has a page at `/deals/<slug>/` (stubs in `_deal_categories/`); menus, the footer and the /deals/ pills only show categories with at least one live deal.
- `amazon_show_prices` in `_config.yml` (currently `true`): show stored Amazon prices; savings UI only with both `price` and `compare_at`. CTA "See the savings on Amazon". Set `false` to hide numbers.
- Theme files live in `assets/css`, `assets/js`, `assets/fonts`, and `assets/images/theme`. The carousel script (Swiper) only loads on pages with `swiper: true` in their front matter, which right now is just the home page.
- The `_products/` samples and `assets/uploads/sample-*.png` are placeholders. Delete them once you've added real items.
- Light/dark mode is built in (the sun icon in the header).

## Deal finder (review first)

A Ruby script checks a few deal feeds every day and adds **candidates** to a review queue. Nothing goes on the site until you approve it.

### Setup

```sh
bundle config set --local with deals   # the finder's gems (nokogiri) are an optional group
bundle install
```

Put your Amazon Associates ID in `amazon_tag` in `_config.yml`. Every Amazon link becomes `https://www.amazon.com/dp/ASIN?tag=yourtag-20`. Links to other stores stay as plain store links, and Sovrn or Skimlinks turns them into affiliate links if you've set one up. The finder strips the feed sites' own affiliate tags and tracking parameters.

### Sources and filters: `_data/deal_sources.yml`

- `feeds:` lists RSS feeds (TechBargains, DealNews, Ben's Bargains). `resolve:` tells the finder how to find the real store link for each feed.
- `sites:` lists store pages to watch (commented examples are in the file). It reads products from the page's JSON-LD by default, or uses the CSS selectors you give it.
- `filters:` sets max age, min discount %, price range, and include/exclude keywords.
- `categories:` maps title keywords to the categories in `_data/categories.yml`; `feed_categories:` maps the source's own category; `skip_feed_categories:` drops non-tech ones; anything else falls back to `fallback_category` (Accessories).
- `sites:` includes TechBargains category/store pages (`parser: techbargains_pages`) and Woot (`parser: woot`: event pages + computers/electronics sitemaps, each offer page read for price, list price, end date and stock).
- `defaults:` sets `expires_days`, how many candidates to add per run and per source, how long unreviewed candidates stay in the queue, and whether approved images are downloaded or hotlinked.
- `http:` sets the User-Agent, timeouts, and a delay between requests to the same host. robots.txt is respected, including Crawl-delay. Like any feed reader, the finder doesn't check robots.txt for the feed URLs themselves.
- `fetch:` on each source says how it's read: `plain` (polite request), `rss` (official feed), `sitemap`, `api` (official API, skipped until its env vars in `env:` are set) or `zenrows`. Direct store sources (`scripts/lib/direct_sources.rb`): B&H deals and used gear, Newegg Outlet plus Newegg's RSS, MacHeist hardware, the Slickdeals frontpage RSS as leads (only Amazon items resolve, from the ASIN in the feed), Target deals through ZenRows, and the Best Buy Products API (`BESTBUY_API_KEY`). Walmart, Impact catalogs (OWC/Adorama, later Target), the Woot API and Amazon PA-API are listed as disabled placeholders with the env vars they'll need. Adorama, OWC, Walmart and Brad's Deals are disabled: they put up a captcha/bot wall.
- **ZenRows** (`zenrows:`): used only for sources with `fetch: zenrows` (Target, whose listings are built by JavaScript), and never for a store that has an official source in the file (`official_for:`). It tries the cheapest option first (plain, then JS rendering at 5 credits; premium proxies only if a source sets `allow_premium: true`), remembers what worked, and stops at a monthly cap (`monthly_credit_cap`, default 4500). Credit counts (no key) are kept in `scripts/state/zenrows_usage.json`. The key comes from the `ZENROWS_API_KEY` environment variable / GitHub secret; without it those sources are skipped.

### Run it

```sh
bundle exec ruby scripts/find_deals.rb            # add candidates to _deal_queue/queue.yml
bundle exec ruby scripts/find_deals.rb --dry-run -v   # see what it would add and why items were skipped
```

Each candidate in `_deal_queue/queue.yml` has a short title the finder writes itself, price, original price (when known), store, category, brand, image, the cleaned `affiliate_url`, an `expires` date, and `source`/`source_link` so you know where it came from. The finder skips anything already in `_products/`, already in the queue, or rejected before (`_deal_queue/rejected.yml`). Jekyll ignores the `_deal_queue/` folder.

### Review and approve

Edit any field you like, then either:

- run `bundle exec ruby scripts/publish_deals.rb approve d-1a2b3c4` (or `reject d-...`), or
- set `status: approved` / `status: rejected` in the queue and run `bundle exec ruby scripts/publish_deals.rb`.

Each approved candidate becomes `_products/<slug>.md` with `type: affiliate`. Its image is saved to `assets/uploads/deals/`. Candidates with a blank `affiliate_url` (the store link couldn't be found) need the store link pasted in before they can be approved.

### Daily GitHub Action

The workflow is in `scripts/find-deals.workflow.yml`. Move it to `.github/workflows/find-deals.yml` to turn it on (on GitHub: Add file → Create new file, paste it in). Once enabled, it runs every day at 13:17 UTC. You can also start it from the Actions tab. It commits new candidates to the `deals-queue` branch and opens a PR called "Deal candidates for review". To approve deals on GitHub, edit `_deal_queue/queue.yml` on that branch and re-run the workflow. Approved entries turn into product files on the branch, and merging the PR publishes them. The workflow uses the built-in `GITHUB_TOKEN`. For it to open the PR, turn on **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**.

### Known limits

- **Slickdeals:** robots.txt disallows the `/click` store links and the old `newsearch.php?...rss=1` feed, so the finder reads `slickdeals.net/rss/frontpage` and never requests `/click`. Amazon items resolve from the ASIN in the feed; others are queued with a blank link.
- **Newegg RSS:** the official daily-deals feed returned no items in Oct 2026; the Outlet page is read instead.
- **DealNews:** store links redirect scripts to a "dead-end" page, so they stay blank.
- **Ben's Bargains:** store links are behind a POST click tracker that robots.txt disallows, so they stay blank.
- **TechBargains:** links go straight to the store, so these always resolve.
- **Store product pages:** Amazon, Walmart, and Best Buy return a captcha or time out for scripts, so the finder uses the feed's price and photo for them. The original price is often unknown for those.

### Deep runs, paging and volume

- `bundle exec ruby scripts/find_deals.rb --deep` also reads each source's `deep_urls`, `deep_pages` and `deep_max_*` and ignores `rotate_daily`. Use it for an occasional manual pass; the daily workflow runs without it.
- `pages` + `page_format` (B&H: `{url}/pn/{n}`) read more pages of a listing. TechBargains page 2+ only holds old deals and Newegg ignores `?page=`, so those get depth from more category/store URLs instead.
- `rotate_daily: K` reads only K of a ZenRows source's URLs per day (Target: 4 of 7 = 20 credits/day).
- Same product at two stores (brand + model number + size + condition) keeps the cheaper one. A cheaper find than a published deal is queued with `replaces:` and a note.
- `max_candidates_per_category` (default 45) keeps one category from flooding a run. Per-source `expires_days` (TechBargains/Slickdeals 3-4 days) covers sale events like Prime days.
- Best Buy: the API takes over once `BESTBUY_API_KEY` is set (`zenrows_until_key`). A ZenRows stand-in source exists but is disabled, because ZenRows requires premium proxies for bestbuy.com (anti-bot). Best Buy deals come in through TechBargains `/stores/bestbuy` meanwhile.
- ZenRows only spends credits after it has actually read the host's robots.txt (directly, or through ZenRows when the host refuses direct connections).
### Deal page copy (summary + specs)

Every affiliate deal gets a short first-person summary, a `why_deal` line, and optional `specs:` (label/value) pulled only from the product title and any source write-up text — never invented. `scripts/lib/deal_copy.rb` builds them; `publish_deals.rb` and `find_deals.rb` use it for new deals. Re-run for existing ones with:

```
bundle exec ruby scripts/enrich_deal_copy.rb
```

Fetched store/manufacturer text is cached under `/workspace/cdeals-cache/` Plain HTTP backs off and retries on HTTP 429; ZenRows is never used to bypass rate limits (only for configured JS-heavy sources like Target when plain content is unusable). (override with `CDEALS_CACHE`). Amazon.com is never fetched; Amazon deals use a manufacturer page when one is known. `publish_deals.rb` reuses the cache and fails soft if a fetch fails.


The product detail page shows Description / Key specs / Why it's a deal tabs under the gallery and buy box. Listing cards stay short.

