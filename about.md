---
layout: page
title: "About cDeals: Who Runs It & How Buying Works"
breadcrumb_title: About
heading: About cDeals
permalink: /about/
description: "Meet the person behind cDeals and learn how buying used tech directly from me works, from condition checks and photos to secure checkout and shipping."
# Used while none of my own items is for sale (see _plugins/selling_mode.rb).
title_no_sale: "About cDeals: Who Picks the Deals & How It Works"
description_no_sale: "Meet the person behind cDeals, how each tech deal is found and checked by hand before it's posted, and how affiliate links help keep the site free to use."
show_faq: true
show_testimonials: true
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
