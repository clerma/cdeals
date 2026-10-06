# Affiliate networks switch: hides deals whose links don't earn yet.
#
# Amazon deals earn through amazon_tag. Every other store earns only through
# Skimlinks (skimlinks_id). While _config.yml has
#
#   affiliate_networks:
#     skimlinks_active: false
#
# every _products/ deal that isn't an Amazon deal is dropped right after the
# site is read, before any generator (selling_mode.rb, jekyll-sitemap) or
# template sees it. So no /item/ page, card, filter, pill, schema, sitemap or
# llms.txt entry exists for it. The files in _products/ stay as they are (the
# deal finder keeps adding them); set skimlinks_active: true and they all come
# back on the next build, exactly as before.
#
# Amazon deal = store is "Amazon" (any case), or affiliate_url points at
# amazon.com / amzn.to. Items with type: sale (mine) are never hidden. A deal
# with no store and no Amazon link is hidden.
#
# Also while hidden:
#   - deal category pages (_deal_categories/) left with no live deals aren't
#     generated (menus and pills already skip them).
#   - any `<key>_amazon_only` value in _config.yml or in a page's front matter
#     replaces `<key>` (e.g. description_no_sale_amazon_only), so meta text
#     doesn't name stores whose deals are hidden.
#   - site.affiliate_hidden_count / affiliate_hidden_slugs list what was hidden
#     (deal-card.html renders nothing for a hidden slug).
require "date"
require "uri"

module AffiliateNetworks
  SUFFIX = "_amazon_only".freeze
  AMAZON_HOST = /(\A|\.)(amazon\.com|amzn\.to)\z/i

  module_function

  def amazon?(doc)
    return true if doc.data["store"].to_s.strip.casecmp?("amazon")

    host = begin
      URI.parse(doc.data["affiliate_url"].to_s.strip).host
    rescue URI::InvalidURIError
      nil
    end
    !host.nil? && host.match?(AMAZON_HOST)
  end

  def hidden?(doc)
    doc.data["type"] != "sale" && !amazon?(doc)
  end

  def live?(doc, today)
    exp = doc.data["expires"]
    return true if exp.nil? || exp.to_s.strip.empty?

    date = exp.respond_to?(:to_date) ? exp.to_date : Date.parse(exp.to_s)
    date >= today
  rescue ArgumentError
    true
  end

  def apply(site)
    settings = site.config["affiliate_networks"] || {}
    amazon_only = settings["skimlinks_active"] == false

    # Config alternates. Keep the originals so `jekyll serve` can switch back.
    site.config.keys.select { |k| k.end_with?(SUFFIX) }.each do |alt_key|
      key = alt_key.delete_suffix(SUFFIX)
      site.config["#{key}_all_stores"] ||= site.config[key]
      site.config[key] = amazon_only ? site.config[alt_key] : site.config["#{key}_all_stores"]
    end

    site.config["amazon_only"] = amazon_only
    site.config["affiliate_hidden_count"] = 0
    site.config["affiliate_hidden_slugs"] = []
    site.config["affiliate_hidden_categories"] = []
    return unless amazon_only

    products = site.collections["products"]
    hidden = products ? products.docs.select { |d| hidden?(d) } : []
    products.docs.reject! { |d| hidden.include?(d) } if products
    site.config["affiliate_hidden_count"] = hidden.size
    site.config["affiliate_hidden_slugs"] = hidden.map { |d| d.data["slug"] || d.basename_without_ext }

    # Page / document alternates (pages are re-read on every build).
    (site.pages + site.collections.values.flat_map(&:docs)).each do |page|
      page.data.keys.select { |k| k.end_with?(SUFFIX) }.each do |alt_key|
        page.data[alt_key.delete_suffix(SUFFIX)] = page.data[alt_key]
      end
    end

    # Category pages with no live deal left.
    cats = site.collections["deal_categories"]
    return unless cats

    today = site.time.to_date
    deals = products ? products.docs.select { |d| d.data["type"] == "affiliate" && live?(d, today) } : []
    live_names = deals.map { |d| d.data["category"] }.uniq
    names = (site.data["categories"] || []).to_h { |c| [c["slug"], c["name"]] }
    empty = cats.docs.reject { |d| live_names.include?(names[d.data["slug"] || d.basename_without_ext]) }
    cats.docs.reject! { |d| empty.include?(d) }
    site.config["affiliate_hidden_categories"] = empty.map { |d| d.data["slug"] || d.basename_without_ext }
  end
end

# post_read runs after every (re)build reads the files and before all
# generators, so selling_mode.rb, jekyll-sitemap and jekyll-feed only ever see
# the visible deals.
Jekyll::Hooks.register :site, :post_read do |site|
  AffiliateNetworks.apply(site)
end
