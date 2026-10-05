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

## Checklist before publishing

1. Unique `title` and `description` (about 150–160 characters).
2. Featured `image` under `assets/uploads/`.
3. At least one `categories` entry.
4. Set `published: true`.
