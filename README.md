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
| `compare_at` (original price, shown crossed out) | optional | optional |
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

Edit the top of `_config.yml`: `title`, `tagline`, `url`, `contact_email`, `affiliate_disclosure`.

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
- `_data/categories.yml` maps each category to an icon for the Categories menu.
- Theme files live in `assets/css`, `assets/js`, `assets/fonts`, and `assets/images/theme`.
- Light/dark mode is built in (the sun icon in the header).
