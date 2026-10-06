---
title: "Blog post template (unpublished)"
description: "Copy this file when you write a new post. Keep published false until the article is ready."
image: /assets/uploads/sample-ipad.png
categories:
  - Buying guides
tags:
  - template
  - deals
date: 2026-10-05 06:00:00 -0500
author: Carlos Lerma
published: false
---

This is an **unpublished** template. Duplicate it (or create a new post in CloudCannon), replace the title and body with your article, set a real featured `image`, and flip `published` to `true` when you are ready.

## Embedding a deal

Pick a product slug from `_products/` (the filename without `.md`) and embed it:

{% include deal-card.html slug="kindle-paperwhite-signature-edition-32gb-bundle" %}

Amazon deals show the “Best deal seen on Amazon” treatment and a “See price at Amazon” button — never a static price.

## Scheduling a post

You can write a post now and have it go live later:

1. Set `date:` to the future date and time you want, with the Central offset: `-0500` during daylight time (CDT, March to November) or `-0600` during standard time (CST). For example: `date: 2026-11-20 08:00:00 -0600`.
2. Set `published: true`.

The post stays hidden until the site rebuilds on or after that time. The site rebuilds whenever anything is pushed to master, and a daily scheduled build in CloudCannon covers days with no pushes, so the post may show up a little after the exact time you picked.

`published: false` keeps a post as a draft no matter what the date is.

## Checklist before publishing

1. Unique `title` and `description` (about 150–160 characters).
2. Featured `image` under `assets/uploads/`.
3. At least one `categories` entry.
4. Set `date:` with the Central offset (`-0500` CDT or `-0600` CST). Use today's date and time to publish right away, or a future one to schedule it.
5. Set `published: true`.
