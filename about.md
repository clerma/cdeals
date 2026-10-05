---
layout: page
title: About
heading: About cDeals
permalink: /about/
---
{% comment %} The selling parts only show while at least one of my own items is for sale (site.selling). {% endcomment %}
{% if site.selling %}
I'm {{ site.author }}. I buy a lot of tech, and when I upgrade I sell the old gear here instead of dealing with
marketplace fees and lowball offers. I also post the best deals I come across.

## Buying from me

- Checkout is handled by AnyCart and Stripe. Your card details never touch this site.
- Items ship within 2 business days. You'll get tracking by email.
- If something arrives not as described, I'll make it right. See [Returns & Shipping]({{ '/returns/' | relative_url }}).
{% else %}
I'm {{ site.author }}. I buy a lot of tech and spend too much time watching prices, so I post the best deals I come across
here. Every deal is picked and checked by me before it goes up.
{% endif %}

## Deals and affiliate links

Items on the [Deals]({{ '/deals/' | relative_url }}) page are sold by other stores, not by me.
{{ site.affiliate_disclosure }} The [Affiliate Disclosure]({{ '/disclosure/' | relative_url }}) has the details.

## Contact

[{{ site.contact_email }}](mailto:{{ site.contact_email }})
