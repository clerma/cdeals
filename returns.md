---
layout: page
title: Returns & Shipping
breadcrumb_title: Returns & shipping
description: "How shipping works for used tech bought from cDeals, when orders go out, and how returns, refunds, and items that arrive damaged or not as described are handled."
permalink: /returns/
updated: 2026-10-04
# Money terms are placeholders until you decide them. Replace every
# [BRACKETED] value below (or in the CloudCannon form), then delete this note.
ships_to: "[WHERE YOU SHIP, e.g. the contiguous US only]"
shipping_cost: "[SHIPPING COST, e.g. free / flat $X / calculated at checkout]"
handling_time: 2 business days   # matches the home page and order confirmation text
return_window: "[RETURN WINDOW, e.g. 14 days]"
return_shipping_payer: "[WHO PAYS RETURN SHIPPING, e.g. buyer / me if the item isn't as described]"
restocking_fee: "[RESTOCKING FEE, e.g. none / X%]"
refund_timing: "[REFUND TIMING, e.g. within X business days after I receive the return]"
damage_report_window: "[DAMAGE REPORT WINDOW, e.g. 48 hours after delivery]"
---
This page covers items I sell myself on the [For sale]({{ '/shop/' | relative_url }}) page. For deals at other stores, that store's shipping and return policies apply.

## Shipping

- **Where I ship:** {{ page.ships_to }}.
- **Cost:** {{ page.shipping_cost }}.
- **When it ships:** within {{ page.handling_time }} after your payment clears. I pack every item carefully.
- **Tracking:** you'll get a tracking number by email when it ships.
- **Damaged in transit:** if the package arrives damaged, email me photos of the box and item within {{ page.damage_report_window }} and I'll work it out with you and the carrier.

## Returns

- **Return window:** {{ page.return_window }} from delivery.
- **Condition:** please return the item in the condition it arrived, with everything that came with it (charger, box, accessories).
- **Return shipping:** {{ page.return_shipping_payer }}.
- **Restocking fee:** {{ page.restocking_fee }}.
- **Refunds:** go back to your original payment method {{ page.refund_timing }}.

### If an item isn't as described

Every listing states the item's condition and shows its wear. If what arrives doesn't match the listing (a fault that wasn't mentioned, missing parts, the wrong item), email me within the return window with photos or a short description. I'll make it right, with a return and refund or another fix we agree on.

### How to start a return

1. Email [{{ site.contact_email }}](mailto:{{ site.contact_email }}?subject=Return%20request) with your order email and the item name.
2. Wait for my reply with the return address before shipping anything back.
3. Ship it with tracking and send me the tracking number.

Used items are sold as described in each listing; see the [Terms]({{ '/terms/' | relative_url }}) for details.
