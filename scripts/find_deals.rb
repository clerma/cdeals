#!/usr/bin/env ruby
# frozen_string_literal: true

# Finds deal CANDIDATES from the feeds and store pages in _data/deal_sources.yml
# and adds them to _deal_queue/queue.yml for review. It never writes _products/.
#
#   bundle exec ruby scripts/find_deals.rb             # normal run
#   bundle exec ruby scripts/find_deals.rb --dry-run   # print, don't save
#   options: --source ID (only that feed/site), --limit N (max new candidates),
#            --verbose (explain every skip)
#
# Needs the optional "deals" gem group:  bundle config set --local with deals && bundle install

require "optparse"
require "cgi"
require "nokogiri"
require_relative "lib/deal_tools"
require_relative "lib/polite_http"



opts = { dry_run: false, source: nil, limit: nil, verbose: false }
OptionParser.new do |o|
  o.on("--dry-run") { opts[:dry_run] = true }
  o.on("--source ID") { |v| opts[:source] = v }
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
  o.on("--verbose", "-v") { opts[:verbose] = true }
end.parse!

cfg = DealTools.config
filters = cfg["filters"] || {}
defaults = cfg["defaults"] || {}
http = PoliteHTTP.new(cfg["http"] || {})
max_redirects = (cfg.dig("http", "max_redirects") || 8).to_i
skip_store_hosts = Array(cfg["skip_store_fetch_hosts"]).map(&:downcase)
limit = opts[:limit] || (defaults["max_candidates_per_run"] || 25).to_i
today = Date.today
now = Time.now

known_categories = DealTools.category_names
category_rules = (cfg["categories"] || {}).map do |cat, words|
  warn "deal_sources.yml: category #{cat.inspect} is not in _data/categories.yml" unless known_categories.include?(cat)
  [cat, Regexp.new("\\b(?:#{Array(words).map { |w| Regexp.escape(w.to_s.downcase) }.join('|')})\\b", Regexp::IGNORECASE)]
end
# The source's own category (e.g. TechBargains "Wireless Earbuds") -> our category.
feed_category_rules = (cfg["feed_categories"] || {}).map do |cat, words|
  warn "deal_sources.yml: feed_categories #{cat.inspect} is not in _data/categories.yml" unless known_categories.include?(cat)
  [cat, Regexp.new("\\b(?:#{Array(words).map { |w| Regexp.escape(w.to_s.downcase) }.join('|')})\\b", Regexp::IGNORECASE)]
end
skip_feed_cat_re = (l = Array(cfg["skip_feed_categories"])).empty? ? nil : Regexp.new("\\A(?:#{l.map { |w| Regexp.escape(w.to_s) }.join('|')})\\z", Regexp::IGNORECASE)
fallback_category = cfg["fallback_category"].to_s.strip
fallback_category = nil if fallback_category.empty?
words_re = ->(list) { list.empty? ? nil : Regexp.new("\\b(?:#{list.map { |w| Regexp.escape(w.to_s.downcase) }.join('|')})\\b", Regexp::IGNORECASE) }
include_re = words_re.call(Array(filters["include_keywords"]))
exclude_re = words_re.call(Array(filters["exclude_keywords"]))

# ------------------------------------------------------------ known items ---
queue = DealTools.load_queue
rejected = DealTools.load_rejected
stale_cutoff = today - (defaults["queue_max_days"] || 10).to_i
before = queue.size
queue.reject! { |e| e["status"].to_s == "new" && e["found"].is_a?(Date) && e["found"] < stale_cutoff }
dropped_stale = before - queue.size

seen = {}
DealTools.existing_product_keys.each_key { |k| seen[k] = "already in _products" }
queue.each { |e| [DealTools.url_key(e["store_url"]), e["source_link"]].compact.each { |k| seen[k] = "already queued" } }
rejected.each { |e| [e["key"], e["source_link"]].compact.each { |k| seen[k] = "rejected before" } }

stats = Hash.new(0)
skips = Hash.new(0)
unresolved_reasons = Hash.new(0)
added = []
source_blocked = Hash.new(0) # consecutive blocked resolutions per source (circuit breaker)

log = ->(msg) { puts msg if opts[:verbose] }
skip = lambda do |item, reason|
  skips[reason] += 1
  log.call("  skip (#{reason}): #{item[:title].to_s[0, 80]}")
  nil
end

text_of = ->(html) { Nokogiri::HTML.fragment(html.to_s).text.gsub(/\s+/, " ").strip }
abs_img = lambda do |src|
  next nil if src.to_s.strip.empty?
  s = src.strip
  s = "https:#{s}" if s.start_with?("//")
  s.start_with?("http") ? s : nil
end

# ------------------------------------------------------- feed parsing ---
def parse_time(str)
  Time.parse(str.to_s)
rescue ArgumentError
  nil
end

def feed_items(xml, source, text_of, abs_img)
  doc = Nokogiri::XML(xml)
  doc.remove_namespaces!
  doc.xpath("//item").map do |it|
    get = ->(name) { it.at_xpath(name)&.text.to_s.strip }
    desc_html = get.call("description")
    content_html = get.call("encoded")
    html = content_html.empty? ? desc_html : content_html
    frag = Nokogiri::HTML.fragment(html)
    image = DealTools.bigger_image(abs_img.call(it.at_xpath("content")&.[]("url"))) || DealTools.bigger_image(abs_img.call(get.call("imagelink"))) ||
            DealTools.bigger_image(abs_img.call(frag.at_css("img")&.[]("src")))
    {
      source: source["id"], title: CGI.unescapeHTML(get.call("title")), link: get.call("link"), guid: get.call("guid"),
      published: parse_time(get.call("pubDate")), html: html, text: text_of.call(html),
      image: image, store_hint: get.call("retailer").then { |v| v.empty? ? get.call("vendorname") : v },
      price: DealTools.money(get.call("price").then { |v| v.empty? ? nil : v }),
      expires: (Date.parse(get.call("expires")) rescue nil),
      feed_category: get.call("category")
    }
  end
end

# Deal write-ups from the source's own pages (e.g. TechBargains, whose RSS only
# has a title). Returns { url_key => "first paragraph of the write-up" }, used to
# find the real list/regular price ("This is normally $249", "$99.99 list price").
# Pages are listed under price_pages: in deal_sources.yml and respect robots.txt.
def source_price_texts(http, source, max_redirects)
  texts = {}
  Array(source["price_pages"]).each do |url|
    _final, res = http.follow(url, max: max_redirects)
    next unless res&.ok?
    Nokogiri::HTML(res.body).css("deal-offer-modal").each do |el|
      offer = JSON.parse(el[":offer"]) rescue next
      html = offer["description_tracked"].to_s
      frag = Nokogiri::HTML.fragment(html)
      first = (frag.at_css("p") || frag).text.to_s.split(/\n/).first.to_s.strip
      next if first.empty?
      links = [offer["outbound_url"], *frag.css("a[href]").map { |a| a["href"] }].compact
      links.each do |l|
        dest = DealTools.embedded_destination(l) || l
        key = DealTools.url_key(dest)
        texts[key] ||= first if key && !DealTools.tracker?(dest)
      end
    end
  end
  texts
end

# TechBargains deal pages (category / store pages). Each deal tile carries the
# write-up as JSON plus a tracking link with the store URL embedded (url=...),
# so the store link is read without requesting the tracker.
def techbargains_page_items(http, source, max_redirects)
  items = {}
  Array(source["urls"]).each do |url|
    _final, res = http.follow(url, max: max_redirects)
    unless res&.ok?
      puts "   #{url}: #{res&.error || "HTTP #{res&.status}"}"
      next
    end
    Nokogiri::HTML(res.body).css("div.deal[id^='o']").each do |tile|
      offer = JSON.parse(tile.at_css("deal-offer-modal")&.[](":offer").to_s) rescue next
      dest = DealTools.embedded_destination(offer["outbound_url"].to_s)
      next unless dest
      html = offer["description_tracked"].to_s
      frag = Nokogiri::HTML.fragment(html)
      first = (frag.at_css("p") || frag).text.to_s.split(/\n/).first.to_s.strip
      cat = tile.css("a[href*='/categories/']").map { |a| a.text.strip }.reject(&:empty?).first
      img_el = tile.at_css("a[data-ga-item='deal_image'] img") || tile.at_css("img.img-fluid")
      img = img_el&.[]("src").to_s
      # Lower tiles are lazy-loaded: the real URL is in v-image-loader="{ imageSrc: '...' }".
      img = img_el["v-image-loader"].to_s[/imageSrc:\s*'([^']+)'/, 1].to_s if img_el && (img.empty? || img.include?("image-default"))
      img = nil if img.to_s.empty? || img.include?("image-default")
      items[dest] ||= {
        source: source["id"], title: offer["name"].to_s.strip, link: dest, guid: "tb-#{offer['id']}",
        published: (Time.parse("#{offer['start_date']} UTC") rescue nil), html: html, text: first,
        image: DealTools.bigger_image(img), store_hint: offer.dig("merchant", "name").to_s.sub(/!+\z/, ""), price: nil,
        expires: nil, feed_category: cat
      }
    end
  end
  items.values
end

# Woot (store: Woot). Offer URLs come from server-rendered event pages
# (woot.com/plus/..., sold-out tiles skipped) and from the subdomain sitemaps
# (computers.woot.com/sitemap.xml etc.; the woot.com/category/... pages are
# built by JavaScript, so the sitemap is the readable list of those offers).
# Each offer page is then read for the real sale price, Woot's list price, the
# end date (availabilityEnds) and stock. ?ref= tracking params are dropped.
def woot_items(http, source, max_redirects, cfg_categories)
  strip_ref = ->(u) { u.to_s.sub(/[?#].*\z/, "") }
  offer_urls = []
  Array(source["listing_urls"]).each do |url|
    _f, res = http.follow(strip_ref.call(url), max: max_redirects)
    unless res&.ok?
      puts "   #{url}: #{res&.error || "HTTP #{res&.status}"}"
      next
    end
    Nokogiri::HTML(res.body).css("li").each do |li|
      next if li["class"].to_s.include?("sold-out")
      a = li.at_css("a[href*='/offers/']") or next
      offer_urls << strip_ref.call(a["href"])
    end
  end
  slug_re = Regexp.new(cfg_categories.values.flatten.map { |w| Regexp.escape(w.to_s.downcase.tr(" ", "-")) }.join("|"))
  Array(source["sitemaps"]).each do |url|
    _f, res = http.follow(url, max: max_redirects)
    next unless res&.ok?
    locs = Nokogiri::XML(res.body).remove_namespaces!.xpath("//url").map { |u| [u.at_xpath("loc")&.text.to_s, u.at_xpath("lastmod")&.text.to_s] }
    locs = locs.select { |l, _| l.include?("/offers/") && l.split("/offers/").last =~ slug_re }
    offer_urls.concat(locs.sort_by { |_, m| m }.reverse.first((source["max_per_sitemap"] || 40).to_i).map(&:first))
  end
  offer_urls.uniq.first((source["max_offers"] || 120).to_i).filter_map do |url|
    _f, res = http.follow(url, max: max_redirects)
    next unless res&.ok?
    html = res.body
    doc = Nokogiri::HTML(html)
    items_json = html[/var offerItems = (\[.*?\]);\s*$/, 1]
    offers = (JSON.parse(items_json) rescue []) if items_json
    offers = Array(offers).select { |o| o["SalePrice"].to_f.positive? && o["Quantity"].to_i.positive? }
    next if offers.empty? || html =~ /var offerAvailableQuantity = 0;/
    best = offers.min_by { |o| o["SalePrice"].to_f }
    ends = doc.at_css("time[itemprop='availabilityEnds']")&.[]("datetime")
    ends_t = (Time.parse(ends) rescue nil)
    next if ends_t && ends_t < Time.now
    title = doc.at_css("meta[property='og:title']")&.[]("content").to_s.sub(/\s+-\s+\$.*\z/, "").strip
    title = doc.at_css("h1")&.text.to_s.strip if title.empty?
    title = title.sub(/\A\(new\)\s*/i, "")
    list = best["ListPrice"].to_f
    cat = html[/itemCategory=([^\\&"]+)/, 1]
    {
      source: source["id"], title: title, link: url, guid: url, published: nil, html: "",
      text: list > best["SalePrice"].to_f ? "List $#{format('%.2f', list)}" : "",
      image: doc.at_css("meta[property='og:image']")&.[]("content"), store_hint: "Woot",
      price: best["SalePrice"].to_f.round(2), from_site: true,
      expires: ends_t && ends_t.getlocal("-05:00").to_date, feed_category: cat && CGI.unescape(cat)
    }
  end
end

# ------------------------------------------------------- store pages ---
def jsonld_products(doc)
  nodes = []
  walk = lambda do |n|
    case n
    when Array then n.each { |x| walk.call(x) }
    when Hash
      types = Array(n["@type"]).map(&:to_s)
      nodes << n if types.any? { |t| t =~ /\AProduct(Group)?\z/ }
      n.each_value { |v| walk.call(v) if v.is_a?(Hash) || v.is_a?(Array) }
    end
  end
  doc.css('script[type="application/ld+json"]').each do |s|
    walk.call(JSON.parse(s.text))
  rescue JSON::ParserError
    next
  end
  nodes
end

def product_from_jsonld(p)
  offers = p["offers"] || p.dig("hasVariant", 0, "offers")
  offers = offers.first if offers.is_a?(Array)
  offers ||= {}
  price = offers["price"] || offers["lowPrice"] || Array(offers["priceSpecification"]).find { |s| s.is_a?(Hash) && s["price"] }&.[]("price")
  compare = Array(offers["priceSpecification"]).find { |s| s.is_a?(Hash) && s["priceType"].to_s =~ /ListPrice|StrikethroughPrice|MSRP/i }&.[]("price")
  img = p["image"]
  img = img.first if img.is_a?(Array)
  img = img["url"] || img["contentUrl"] if img.is_a?(Hash)
  brand = p["brand"]
  brand = brand["name"] if brand.is_a?(Hash)
  brand = brand.first if brand.is_a?(Array)
  brand = brand["name"] if brand.is_a?(Hash)
  { name: p["name"], price: DealTools.money(price), compare_at: DealTools.money(compare), image: img,
    brand: brand.is_a?(String) ? brand : nil, url: offers["url"] || p["url"],
    in_stock: offers["availability"].nil? || offers["availability"].to_s !~ /OutOfStock|SoldOut|Discontinued/i }
end

def store_page_data(http, url, max_redirects)
  final, res = http.follow(url, max: max_redirects)
  return [nil, res&.error || "store page HTTP #{res&.status}"] unless res&.ok?
  return [nil, "store page served a captcha/bot check"] if res.body.size < 20_000 && res.body =~ /captcha|are you a robot|access denied|px-captcha|challenge-platform/i
  doc = Nokogiri::HTML(res.body)
  data = jsonld_products(doc).map { |p| product_from_jsonld(p) }.find { |p| p[:name] } || {}
  meta = ->(prop) { doc.at_css(%(meta[property="#{prop}"], meta[name="#{prop}"]))&.[]("content") }
  data[:name] ||= meta.call("og:title")
  data[:image] ||= meta.call("og:image")
  data[:price] ||= DealTools.money(meta.call("product:price:amount") || meta.call("og:price:amount"))
  data[:brand] ||= meta.call("product:brand")
  data[:final_url] = final
  [data, nil]
end

# Find the real store URL for a feed item.
def resolve_store_url(item, source, http, max_redirects)
  start =
    case source["resolve"].to_s
    when "direct" then item[:link]
    when "content_link"
      links = Nokogiri::HTML.fragment(item[:html]).css(source["link_selector"] || "a[href]").select { |x| x["href"].to_s.start_with?("http") }
      # Prefer a link whose exit site is a store, not the deal site itself.
      a = links.find { |x| x["data-product-exitwebsite"].to_s =~ /\./ && !DealTools.tracker?("https://#{x['data-product-exitwebsite']}") } || links.first
      return [nil, "no outbound link in feed item"] unless a
      if item[:store_hint].to_s.empty? && (exit_site = a["data-product-exitwebsite"].to_s) =~ /\./ && !DealTools.tracker?("https://#{exit_site}")
        item[:store_hint] = DealTools.store_name("https://#{exit_site}")
      end
      a["href"]
    when "page"
      page_url, res = http.follow(item[:link], max: max_redirects)
      return [nil, res&.error || "deal page HTTP #{res&.status}"] unless res&.ok?
      a = Nokogiri::HTML(res.body).css(source["link_selector"] || "a[href]").first
      return [nil, "no store link on deal page"] unless a
      URI.join(page_url, a["href"]).to_s
    else
      return [nil, "source is set to resolve: none"]
    end

  current = start
  max_redirects.times do
    return [current, nil] unless DealTools.tracker?(current)
    if (dest = DealTools.embedded_destination(current))
      current = dest
      next
    end
    res = http.get(current)
    if res.redirect?
      return [nil, "redirected to a bot dead-end (#{URI(res.location).host})"] if res.location =~ /dead-end|captcha|blocked/i
      current = res.location
      next
    end
    return [nil, res.error || "tracking link returned HTTP #{res.status} instead of redirecting"]
  end
  [nil, "too many redirects"]
end

def brand_guess(name)
  w = name.to_s.split(/\s+/).first.to_s.gsub(/[^\p{Alnum}&\-]/, "")
  return nil if w.length < 2 || w =~ /\A(new|the|refurbished|renewed|refurb|restored|open|open-box|select|grand|set|pack|\d.*|2-pack|3-pack|certified|used|apple's|my)\z/i || w == w.downcase
  w
end

# --------------------------------------------------------- one item ---
build_candidate = lambda do |item, source|
  stats[:items_seen] += 1
  title = item[:title].to_s
  blob = "#{title} #{item[:text]}"

  max_age = source["max_age_hours"] || filters["max_age_hours"]
  if item[:published] && max_age && now - item[:published] > max_age.to_f * 3600
    next skip.call(item, "older than #{max_age}h")
  end
  next skip.call(item, "already queued/published/rejected") if seen[item[:link]] || seen[item[:guid]]
  next skip.call(item, "excluded keyword") if exclude_re&.match?(title)
  next skip.call(item, "no include keyword") if include_re && !include_re.match?(blob)
  feed_cat = item[:feed_category].to_s.strip
  next skip.call(item, "non-tech source category (#{feed_cat})") if skip_feed_cat_re&.match?(feed_cat)
  category = category_rules.find { |_, re| re.match?(title) }&.first
  category ||= feed_category_rules.find { |_, re| re.match?(feed_cat) }&.first unless feed_cat.empty?
  category ||= fallback_category
  next skip.call(item, "no matching category") if category.nil? && filters.fetch("require_category", true)

  price = item[:price] || DealTools.first_price(title) || DealTools.first_price(item[:text])
  next skip.call(item, "price outside min/max") if price && ((filters["min_price"] && price < filters["min_price"]) || (filters["max_price"] && price > filters["max_price"]))
  compare = DealTools.compare_from_text(blob, price)

  # Resolve the real store link (circuit breaker after 3 blocked in a row).
  store_url = nil
  reason = nil
  if source_blocked[source["id"]] >= 3
    reason = "skipped: #{source['id']} store links kept failing this run"
  else
    store_url, reason = resolve_store_url(item, source, http, max_redirects)
    source_blocked[source["id"]] = store_url ? 0 : source_blocked[source["id"]] + (reason =~ /none|robots/ ? 0 : 1)
  end
  notes = []
  store_url = DealTools.clean_store_url(store_url) if store_url
  if store_url
    stats[:resolved] += 1
  else
    stats[:unresolved] += 1
    unresolved_reasons["#{source['id']}: #{reason}"] += 1
    notes << "Store link not found (#{reason}). Paste the store link into affiliate_url before approving."
  end

  key = store_url ? DealTools.url_key(store_url) : nil
  next skip.call(item, seen[key]) if key && seen[key]

  # Read product data from the store page when allowed.
  store = item[:store_hint].to_s.strip
  if store.empty?
    store = title[/\s(?:at|@)\s+([A-Z][\w&'.]*(?:\s[A-Z][\w&'.]*)?)\s*\z/, 1] ||
            item[:text][/\A(?:[A-Z][^.]{0,40}:\s*)?([A-Z][\w&'.]*(?:\s[A-Z][\w&'.]*)?)\s+(?:has|offers|is offering)\s/, 1] || ""
  end
  store = DealTools.store_name(store_url) if store_url && (store.empty? || store =~ /\./)
  store = store.sub(/\.com\z/i, "").capitalize if store =~ /\A[a-z0-9\-]+\.com\z/i
  data = {}
  if store_url
    host = DealTools.bare_host(URI(store_url))
    if item[:from_site]
      # Already read from the watched store page's JSON-LD / selectors.
    elsif skip_store_hosts.any? { |h| host == h || host.end_with?(".#{h}") }
      notes << "Price/photo from #{source['name']} (#{host} product pages aren't fetched)."
    else
      data, err = store_page_data(http, store_url, max_redirects)
      data ||= {}
      if err
        stats[:store_fetch_failed] += 1
        notes << "Store page not read (#{err}); price/photo from #{source['name']}."
      else
        stats[:store_fetch_ok] += 1
        next skip.call(item, "out of stock at store") if data[:in_stock] == false
      end
    end
  end

  price = data[:price] if data[:price]&.positive?
  compare = data[:compare_at] if data[:compare_at] && price && data[:compare_at] > price
  compare = nil if compare && price && compare <= price
  discount = compare && price ? ((1 - price / compare) * 100).round : nil
  if discount && filters["min_discount_pct"] && discount < filters["min_discount_pct"].to_i
    next skip.call(item, "discount below #{filters['min_discount_pct']}%")
  end
  next skip.call(item, "unknown discount") if discount.nil? && filters["allow_unknown_discount"] == false
  next skip.call(item, "no price found") unless price

  name = data[:name].to_s.strip.empty? ? title : data[:name]
  short = DealTools.short_title(name, store: store)
  short = DealTools.short_title(title, store: store) if short.length < 8
  highlights = []
  highlights << "$#{(compare - price).round} under its usual price" if compare && !(store =~ /amazon/i || store_url.to_s =~ /amazon\.|amzn\./i)
  highlights << "Refurbished or open-box: check the condition notes at #{store.empty? ? 'the store' : store}" if title =~ /refurb|reconditioned|renewed|like-new|like new|open[- ]box|scratch/i
  highlights << "Free shipping" if blob =~ /free ship/i
  highlights << "May need a coupon or promo code at checkout" if blob =~ /\bcoupon\b|\bclip\b|promo code|\bcode\b/i
  highlights << "Prime members only" if blob =~ /prime (members|exclusive|only)/i
  expires = item[:expires] && item[:expires] > today && item[:expires] <= today + 30 ? item[:expires] : today + (defaults["expires_days"] || 7).to_i

  money_s = ->(v) { v == v.round ? "$#{v.round}" : format("$%.2f", v) }
  amazon = store =~ /amazon/i || store_url.to_s =~ /amazon\.|amzn\./i
  summary =
    if amazon
      # Amazon Associates: no static prices in the text (the site hides Amazon prices too).
      "Amazon has a good price on this right now. Prices change fast, so check the current price at Amazon before you buy."
    else
      "#{store.empty? ? 'The store' : store} has it for #{money_s.call(price)}" \
        "#{compare ? ", down from #{money_s.call(compare)}" : ''}. Prices change fast, so check the price before you buy."
    end

  dedupe_key = key || item[:link]
  entry = {
    "id" => DealTools.deal_id(dedupe_key), "status" => "new", "title" => short, "store" => store,
    "price" => price, "compare_at" => compare, "discount_pct" => discount, "category" => category,
    "brand" => [data[:brand], item[:brand]].map { |b| b.to_s.strip }.find { |b| !b.empty? } || brand_guess(name),
    "affiliate_url" => store_url ? DealTools.affiliate_url(store_url) : "", "store_url" => store_url,
    "image" => abs_img.call(data[:image].to_s) || item[:image], "highlights" => highlights.first(3),
    "summary" => summary, "expires" => expires, "found" => today, "source" => source["id"],
    "source_link" => item[:link], "source_title" => title[0, 140], "notes" => notes.empty? ? nil : notes.join(" ")
  }.compact
  seen[dedupe_key] = "already queued"
  seen[item[:link]] = "already queued"
  log.call("  + #{entry['id']} #{short} — #{money_s.call(price)} at #{store}#{store_url ? '' : ' (unresolved)'}")
  entry
end

# ------------------------------------------------------------ run it ---
sources = Array(cfg["feeds"]).map { |f| f.merge("kind" => "feed") } + Array(cfg["sites"]).map { |s| s.merge("kind" => "site") }
sources.select! { |s| s["id"] == opts[:source] } if opts[:source]
sources.reject! { |s| s["enabled"] == false }

sources.each do |source|
  break if added.size >= limit
  puts "== #{source['name'] || source['id']} (#{source['url'] || "#{Array(source['urls']).size} pages"})"
  # Feeds are published for feed readers, so (like any feed reader) the feed URL
  # itself isn't checked against robots.txt. Everything else is.
  res = source["kind"] == "feed" ? http.follow(source["url"], max: max_redirects, robots: false).last : http.follow(source["url"], max: max_redirects).last unless source["parser"]
  unless source["parser"] || res&.ok?
    puts "   fetch failed: #{res&.error || "HTTP #{res&.status}"}"
    stats[:sources_failed] += 1
    next
  end
  items =
    if source["parser"] == "techbargains_pages"
      techbargains_page_items(http, source, max_redirects)
    elsif source["parser"] == "woot"
      woot_items(http, source, max_redirects, cfg["categories"] || {})
    elsif source["kind"] == "feed"
      feed_items(res.body, source, text_of, abs_img)
    else
      doc = Nokogiri::HTML(res.body)
      found =
        if (sel = source["selectors"])
          doc.css(sel["item"]).map do |el|
            link = el.at_css(sel["link"] || "a")&.[]("href")
            { title: el.at_css(sel["title"])&.text.to_s.strip, link: link && URI.join(source["url"], link).to_s,
              price: DealTools.money(el.at_css(sel["price"].to_s)&.text), html: "",
              compare_text: el.at_css(sel["compare_at"].to_s)&.text,
              image: abs_img.call(el.at_css(sel["image"] || "img")&.[]("src")) }
          end
        else
          jsonld_products(doc).map { |p| product_from_jsonld(p) }.select { |p| p[:url] && p[:in_stock] }.map do |p|
            { title: p[:name].to_s, link: URI.join(source["url"], p[:url]).to_s, price: p[:price], html: "",
              compare_text: p[:compare_at] && "was $#{p[:compare_at]}", image: abs_img.call(p[:image].to_s), brand: p[:brand] }
          end
        end
      found.map do |f|
        f.merge(source: source["id"], guid: f[:link], published: nil, from_site: true, text: f[:compare_text].to_s,
                store_hint: source["store"], expires: nil)
      end
    end
  items = items.first((source["max_items"] || 30).to_i)
  if source["price_pages"]
    price_texts = source_price_texts(http, source, max_redirects)
    matched = 0
    items.each do |it|
      t = price_texts[DealTools.url_key(it[:link])] or next
      it[:text] = "#{it[:text]} #{t}".strip
      matched += 1
    end
    puts "   price write-ups: #{price_texts.size} from #{Array(source['price_pages']).size} pages, matched #{matched} items"
  end
  stats[:items_fetched] += items.size
  puts "   #{items.size} items"
  site_source = source.merge("resolve" => source["kind"] == "site" ? "direct" : source["resolve"])
  per_source = (source["max_candidates"] || defaults["max_candidates_per_source"] || 8).to_i
  from_source = 0
  items.each do |item|
    break if added.size >= limit || from_source >= per_source
    c = build_candidate.call(item, site_source)
    next unless c
    added << c
    from_source += 1
  end
end

queue.concat(added)
DealTools.save_queue(queue) unless opts[:dry_run]

puts
puts "Items fetched: #{stats[:items_fetched]}  (checked after filters: #{stats[:items_seen]})"
puts "New candidates: #{added.size}  (store link resolved: #{added.count { |e| e['store_url'] }}, unresolved: #{added.count { |e| !e['store_url'] }})"
puts "Store pages read: #{stats[:store_fetch_ok]}, failed/blocked: #{stats[:store_fetch_failed]}"
puts "Dropped stale queue entries: #{dropped_stale}" if dropped_stale.positive?
puts "HTTP requests: #{http.stats[:requests]}, blocked by robots.txt: #{http.stats[:robots_blocked]}, errors: #{http.stats[:errors]}"
puts "Skipped:" unless skips.empty?
skips.sort_by { |_, n| -n }.each { |r, n| puts "  #{n.to_s.rjust(4)}  #{r}" }
puts "Unresolved store links:" unless unresolved_reasons.empty?
unresolved_reasons.sort_by { |_, n| -n }.each { |r, n| puts "  #{n.to_s.rjust(4)}  #{r}" }
puts(opts[:dry_run] ? "(dry run: queue not saved)" : "Queue: #{DealTools::QUEUE_FILE.sub("#{DealTools::ROOT}/", '')} (#{queue.size} entries)")
added.each { |e| puts "  #{e['id']}  #{e['title']} | #{e['price']}#{e['compare_at'] ? " (was #{e['compare_at']})" : ''} | #{e['store']} | #{e['category']} | #{e['affiliate_url'].to_s.empty? ? 'NO STORE LINK' : e['affiliate_url']}" }
