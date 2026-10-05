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

## Hosting

The output is a static site, so it can be hosted for free on CloudCannon, Netlify, Cloudflare Pages, or GitHub Pages (via a GitHub Action, because this site uses Jekyll 4). Expired deals are hidden at build time, so schedule a daily rebuild if you use `expires`.

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
- `amazon_show_prices` in `_config.yml` (default `false`): Amazon deals show "Best deal seen on Amazon" + "See price at Amazon" instead of static prices (Associates rules). The numbers stay in front matter.
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

- `feeds:` lists RSS feeds (TechBargains, Slickdeals, DealNews, Ben's Bargains). `resolve:` tells the finder how to find the real store link for each feed.
- `sites:` lists store pages to watch (commented examples are in the file). It reads products from the page's JSON-LD by default, or uses the CSS selectors you give it.
- `filters:` sets max age, min discount %, price range, and include/exclude keywords.
- `categories:` maps title keywords to the categories in `_data/categories.yml`; `feed_categories:` maps the source's own category; `skip_feed_categories:` drops non-tech ones; anything else falls back to `fallback_category` (Accessories).
- `sites:` includes TechBargains category/store pages (`parser: techbargains_pages`) and Woot (`parser: woot`: event pages + computers/electronics sitemaps, each offer page read for price, list price, end date and stock).
- `defaults:` sets `expires_days`, how many candidates to add per run and per source, how long unreviewed candidates stay in the queue, and whether approved images are downloaded or hotlinked.
- `http:` sets the User-Agent, timeouts, and a delay between requests to the same host. robots.txt is respected, including Crawl-delay. Like any feed reader, the finder doesn't check robots.txt for the feed URLs themselves.

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

- **Slickdeals:** robots.txt disallows the `/click` store links, so the finder leaves them alone. Slickdeals candidates come with the store name and price but a blank link.
- **DealNews:** store links redirect scripts to a "dead-end" page, so they stay blank.
- **Ben's Bargains:** store links are behind a POST click tracker that robots.txt disallows, so they stay blank.
- **TechBargains:** links go straight to the store, so these always resolve.
- **Store product pages:** Amazon, Walmart, and Best Buy return a captcha or time out for scripts, so the finder uses the feed's price and photo for them. The original price is often unknown for those.
