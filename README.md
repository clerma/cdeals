# cDeals

A Jekyll site (Cartzilla theme) that does two jobs:

1. **Sells my used tech.** Each item has a **Buy now** button that opens a Stripe Payment Link. Stripe handles card payment, shipping address, and receipts, so there's no server or database.
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
| `compare_at` (original price, shown crossed out) | optional | optional |
| `status` (`available` / `sold`) | ✓ | – |
| `condition`, `shipping` | ✓ | – |
| `buy_link` (Stripe Payment Link) | ✓ | – |
| `store`, `affiliate_url` | – | ✓ |
| `expires` (hides the deal after this date) | – | optional |

The text under the front matter becomes the item description. Put photos in `assets/uploads/`.

## Setting up a Stripe Payment Link for a used item

1. In the Stripe Dashboard, go to **Payment Links → New** and create a product with your price.
2. Turn on **Collect customers' addresses → Shipping addresses**.
3. Under **Advanced options**, turn on **Limit the number of payments** and set it to **1** so a one-off item can't sell twice.
4. Under **After payment**, choose **Don't show confirmation page** and redirect to `https://YOUR-SITE/thanks/`.
5. Paste the link into the item's `buy_link`.
6. After it sells, set `status: sold`. The item stays up with a "Sold" badge.

## Settings

Edit the top of `_config.yml`: `title`, `tagline`, `url`, `contact_email`, `affiliate_disclosure`.

## Hosting

The output is a static site, so it can be hosted for free on CloudCannon, Netlify, Cloudflare Pages, or GitHub Pages (via a GitHub Action, because this site uses Jekyll 4). Expired deals are hidden at build time, so schedule a daily rebuild if you use `expires`.

## Theme reference

`_pages/` holds the original Cartzilla demo pages. It isn't built and is only there to copy sections from.
