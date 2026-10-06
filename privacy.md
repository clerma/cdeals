---
layout: page
title: Privacy Policy
breadcrumb_title: Privacy
description: "What information cDeals collects when you browse, buy, or click a deal link, how it's used, which outside services handle it, and the choices you have about it."
permalink: /privacy/
updated: 2026-10-04
---
This policy explains what information is collected when you use {{ site.title }}, who collects it, and what you can do about it. The site is run by {{ site.legal_name }}. Contact: [{{ site.contact_email }}](mailto:{{ site.contact_email }}).

## The short version

{% assign ga_on = false %}{% if site.google_analytics and site.google_analytics != "" %}{% assign ga_on = true %}{% endif %}
{%- assign clarity_on = false %}{% if site.clarity_id and site.clarity_id != "" %}{% assign clarity_on = true %}{% endif %}
{%- assign fb_on = false %}{% if site.facebook_pixel and site.facebook_pixel != "" %}{% assign fb_on = true %}{% endif %}
{%- if ga_on or clarity_on or fb_on %}
- This site uses {% if ga_on %}Google Analytics{% endif %}{% if ga_on and clarity_on %}{% if fb_on %}, {% else %} and {% endif %}{% endif %}{% if clarity_on %}Microsoft Clarity{% endif %}{% if fb_on %}{% if ga_on or clarity_on %} and {% endif %}the Meta (Facebook) Pixel{% endif %} to understand how visitors use it{% if fb_on %} and to measure and target ads{% endif %}. I don't sell or rent your personal information.
{%- else %}
- I don't run my own analytics or ad tracking on this site, and I don't sell or rent your personal information.
{%- endif %}
- If you buy an item from me, checkout and payment are handled by AnyCart and Stripe or Square. They share with me what I need to ship your order.
- Affiliate links and link services (Amazon, Sovrn Commerce or Skimlinks, Geniuslink) may set their own cookies when you use them.

## What's collected, and by whom

**When you buy from me.** AnyCart runs the cart and checkout, and Stripe or Square processes the payment. They collect your name, email, shipping address, and payment details. Your card details go straight to the payment processor; I never see or store them. I receive your name, email, shipping address, and what you bought, and use them only to fulfill the order, send tracking, and handle returns or questions. I keep order records as long as I need them for taxes and accounting.

**When you email me.** I get your email address and whatever you write, and use it only to reply.

**Affiliate links and link services.** When you click a deal link, the store (for example Amazon) and any affiliate network or link service involved may set cookies or record the click so the purchase can be credited. If enabled on this site, Sovrn Commerce or Skimlinks loads a script that can turn store links into affiliate links and may set cookies. A link service like Geniuslink may use your location to send you to your local store. Those companies handle that data under their own privacy policies.

{% if ga_on or clarity_on or fb_on %}**Analytics and advertising.** {% if ga_on %}Google Analytics records pages visited, how you got here, device and browser type, and approximate location, using cookies. You can opt out with [Google's browser add-on](https://tools.google.com/dlpage/gaoptout). {% endif %}{% if clarity_on %}Microsoft Clarity records how you interact with pages (clicks, scrolling, mouse movement) to help me improve the site, using cookies; see [Microsoft's privacy statement](https://privacy.microsoft.com/privacystatement). {% endif %}{% if fb_on %}The Meta (Facebook) Pixel tells Meta that you visited this site so I can measure and target ads on Facebook and Instagram; manage this in your [Facebook ad preferences](https://www.facebook.com/adpreferences). {% endif %}These services handle that data under their own privacy policies.

{% endif %}**Hosting.** The site is hosted by {{ site.hosting_provider }}. Like any web host, it may keep standard server logs (IP address, browser type, pages requested) for security and to keep the site running.

**Stored on your device.** The site saves your light/dark mode choice in your browser's local storage (the key `theme`). The AnyCart cart may store your cart contents in your browser so they're still there when you come back. You can clear either in your browser settings.

## Your choices and rights

- You can block or delete cookies in your browser. The site still works; affiliate tracking just may not credit me.
- **California (CCPA/CPRA):** you can ask what personal information I hold about you, ask me to delete it, and ask me to correct it. I don't sell personal information.{% if fb_on %} This site uses the Meta Pixel for advertising, which may count as "sharing" for cross-context behavioral advertising; you can opt out by emailing me or by turning on Global Privacy Control in your browser.{% else %} I don't share personal information for cross-context behavioral advertising.{% endif %}
- **EU/UK (GDPR):** I use order information to fulfill a contract with you (your purchase) and to meet legal obligations like tax records. You can ask for access, correction, deletion, or a copy of your data, and object to processing. You can also complain to your local data protection authority.

To make any of these requests, email [{{ site.contact_email }}](mailto:{{ site.contact_email }}). I'll respond within the time the law requires.

## Children

This site isn't aimed at children under 13, and I don't knowingly collect their information.

## Changes

If this policy changes, I'll update the "Last updated" date at the top of this page.
