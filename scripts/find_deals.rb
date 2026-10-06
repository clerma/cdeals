#!/usr/bin/env ruby
# frozen_string_literal: true

# Finds deal CANDIDATES from the feeds and store pages in _data/deal_sources.yml
# and adds them to _deal_queue/queue.yml for review. It never writes _products/.
#
#   bundle exec ruby scripts/find_deals.rb             # normal run
#   bundle exec ruby scripts/find_deals.rb --dry-run   # print, don't save
#   options: --source ID (only that feed/site), --limit N (max new candidates),
#            --verbose (explain every skip),
#            --deep (also read deep_urls / deep_pages, ignore rotate_daily:
#                    for an occasional manual deep pass, not the daily run)
#   bundle exec ruby scripts/find_deals.rb --tag-prime-day [--dry-run]
#            only reads the prime_day_roundups: pages and adds prime_day: true /
#            prime_day_source: to published Amazon deals listed there
#   --no-recheck  skip the re-check of published deals (see "re-check" below)
#
# Stop-on-block (scripts/lib/run_blocks.rb): a 403, 429 or bot-wall answer
# blocks that source and host for the rest of the run (no more requests, no
# retries, no ZenRows); its published deals are left out of the re-check.
#
# Needs the optional "deals" gem group:  bundle config set --local with deals && bundle install

require "optparse"
require "cgi"
require "nokogiri"
require_relative "lib/deal_tools"
require_relative "lib/polite_http"
require_relative "lib/fetcher"
require_relative "lib/direct_sources"
require_relative "lib/deal_copy"
require_relative "lib/source_cache"
require_relative "lib/run_blocks"



opts = { dry_run: false, source: nil, limit: nil, verbose: false, recheck: true }
OptionParser.new do |o|
  o.on("--dry-run") { opts[:dry_run] = true }
  o.on("--source ID") { |v| opts[:source] = v }
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
  o.on("--verbose", "-v") { opts[:verbose] = true }
  o.on("--deep") { ENV["DEALS_DEEP"] = "1" }
  o.on("--tag-prime-day") { opts[:tag_prime_day] = true }
  o.on("--no-recheck") { opts[:recheck] = false }
end.parse!

cfg = DealTools.config
filters = cfg["filters"] || {}
defaults = cfg["defaults"] || {}
fetcher = Fetcher.new(cfg, root: DealTools::ROOT)
http = fetcher.http
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

# ------------------------------------------------ Prime Day roundups ---
# Pages listed under prime_day_roundups: in deal_sources.yml, read once per run.
# Returns { asins: { ASIN => url }, threads: { slickdeals id => url }, pages: { page_key => url } }.
def prime_day_index(http, roundups, max_redirects)
  index = { asins: {}, threads: {}, pages: {} }
  roundups.each do |r|
    url = r["url"]
    RunBlocks.source = { "id" => "prime-day-roundup #{RunBlocks.host_key(url)}", "url" => url }
    final, res = http.follow(url, max: max_redirects)
    next if res&.blocked # logged once by RunBlocks
    unless res&.ok?
      puts "   #{url}: #{res&.error || "HTTP #{res&.status}"}"
      next
    end
    title = Nokogiri::HTML(res.body).at_css("title")&.text.to_s.strip
    if r["require_title"] && !DealTools::PRIME_EVENT_TITLE_RE.match?(title)
      puts "   #{url}: not used, page title #{title[0, 80].inspect} doesn't mention Prime Day"
      next
    end
    ev = DealTools.prime_day_evidence(res.body)
    ev[:asins].each { |a| index[:asins][a] ||= url }
    ev[:threads].each { |t| index[:threads][t] ||= url } if DealTools.page_key(final).to_s.start_with?("slickdeals.net")
    [url, final].filter_map { |u| DealTools.page_key(u) }.each { |k| index[:pages][k] ||= url }
    puts "   #{url}: #{ev[:asins].size} Amazon products, #{ev[:threads].size} Slickdeals threads"
  end
  RunBlocks.source = nil
  index
end

prime_roundups = DealTools.prime_day_roundups(cfg)
prime_index = nil
unless prime_roundups.empty?
  puts "== Prime Day roundups (#{prime_roundups.size} pages)"
  prime_index = prime_day_index(http, prime_roundups, max_redirects)
end

# Re-check published deals: add prime_day / prime_day_source lines (nothing else
# in the file changes) to Amazon deals whose ASIN is on a roundup page.
if opts[:tag_prime_day]
  abort "No enabled prime_day_roundups in _data/deal_sources.yml" unless prime_index
  checked = matched = tagged = 0
  Dir[File.join(DealTools::PRODUCTS_DIR, "*.md")].sort.each do |path|
    fm = DealTools.front_matter(path)
    next unless fm["type"].to_s == "affiliate"
    asin = DealTools.asin(fm["affiliate_url"]) or next
    checked += 1
    url = prime_index[:asins][asin] or next
    matched += 1
    name = File.basename(path)
    if fm["prime_day"] == false
      puts "  skip  #{name} (prime_day: false)"
      next
    end
    add = []
    add << "prime_day: true" unless fm.key?("prime_day")
    add << "prime_day_source: #{url}" unless fm.key?("prime_day_source")
    next if add.empty?
    text = File.read(path)
    m = text.match(/\A---\s*\n(.*?)\n---\s*(\n|\z)/m) or next
    File.write(path, text.insert(m.end(1), "\n#{add.join("\n")}")) unless opts[:dry_run]
    tagged += 1
    puts "  tag   #{name}: #{add.join(', ')}"
  end
  puts "Amazon deals checked: #{checked}, on a roundup: #{matched}, tagged: #{tagged}#{opts[:dry_run] ? ' (dry run: nothing written)' : ''}"
  puts "HTTP requests: #{http.stats[:requests]}, blocked by robots.txt: #{http.stats[:robots_blocked]}, errors: #{http.stats[:errors]}"
  puts "Blocked this run: #{RunBlocks.summary}"
  exit
end

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
# Walmart / Sam's Club keys saved before url_key went by item id (walmart.com/ip/<slug>/<id>).
rejected.each do |e|
  k = DealTools.url_key("https://#{e['key']}") if e["key"].to_s =~ %r{\A(?:walmart|samsclub)\.com/ip/}
  seen[k] ||= "rejected before" if k
end

# Re-check of published deals: active affiliate deals by url_key. Source items
# matching one are recorded in recheck_hits (key => [{ price:, was:, source: }])
# and, for recheck_missing: sources, their whole listing in recheck_listings.
published = {}
if opts[:recheck]
  Dir[File.join(DealTools::PRODUCTS_DIR, "*.md")].sort.each do |path|
    fm = DealTools.front_matter(path)
    next unless fm["type"].to_s == "affiliate"
    next if fm["expires"].is_a?(Date) && fm["expires"] < today
    k = DealTools.url_key(fm["affiliate_url"]) or next
    published[k] = { path: path, price: fm["price"].to_f, source: fm["source"].to_s }
  end
end
recheck_hits = Hash.new { |h, k| h[k] = [] }
recheck_listings = {}
# Store link of an item without any request (tracking links only when the
# destination is embedded in them).
item_key = lambda do |it|
  u = it.key?(:store_url) ? it[:store_url] : it[:link]
  u = DealTools.embedded_destination(u) || u if DealTools.tracker?(u)
  DealTools.tracker?(u) ? nil : DealTools.url_key(u)
end

# Same product across stores: keep the best price. sig -> { price:, store:, entry: (this run) | file: (published) }
sig_seen = DealTools.existing_product_signatures.transform_values { |file, store, price| { price: price, store: store, file: file } }
# Items with part numbers (OWC's Mfr P/N / SKU) also match a published deal whose
# store URL or title has that part number ("mpn:<token>" keys, same rules).
DealTools.existing_part_number_index.each { |k, (file, store, price)| sig_seen[k] = { price: price, store: store, file: file } }
queue.each do |e|
  next unless e["status"].to_s == "new" && e["price"]
  sig = DealTools.product_signature(e["title"], brand: e["brand"]) or next
  sig_seen[sig] = { price: e["price"].to_f, store: e["store"].to_s, queued: e["id"] } if sig_seen[sig].nil? || e["price"].to_f < sig_seen[sig][:price]
end
# Category balance: no single category may take more than this many new candidates per run.
max_per_category = (defaults["max_candidates_per_category"] || 0).to_i
cat_counts = Hash.new(0)
replaced = []

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
    break if RunBlocks.source_blocked?(source["id"])
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
  DealTools.source_urls(source).each do |url|
    break if RunBlocks.source_blocked?(source["id"])
    _final, res = http.follow(url, max: max_redirects)
    next if res&.blocked # logged once by RunBlocks
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
        source: source["id"], title: offer["name"].to_s.strip, link: dest, guid: "tb-#{offer['id']}", listing: url,
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
  deep = DealTools.deep?
  Array(source["listing_urls"]).each do |url|
    break if RunBlocks.source_blocked?(source["id"])
    _f, res = http.follow(strip_ref.call(url), max: max_redirects)
    next if res&.blocked # logged once by RunBlocks
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
    break if RunBlocks.source_blocked?(source["id"])
    _f, res = http.follow(url, max: max_redirects)
    next unless res&.ok?
    locs = Nokogiri::XML(res.body).remove_namespaces!.xpath("//url").map { |u| [u.at_xpath("loc")&.text.to_s, u.at_xpath("lastmod")&.text.to_s] }
    locs = locs.select { |l, _| l.include?("/offers/") && l.split("/offers/").last =~ slug_re }
    offer_urls.concat(locs.sort_by { |_, m| m }.reverse.first(((deep && source["deep_max_per_sitemap"]) || source["max_per_sitemap"] || 40).to_i).map(&:first))
  end
  offer_urls.uniq.first(((deep && source["deep_max_offers"]) || source["max_offers"] || 120).to_i).filter_map do |url|
    next if RunBlocks.source_blocked?(source["id"])
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
    return [nil, res.error || "blocked (#{res.blocked})"] if res.blocked
    if res.redirect?
      return [nil, "redirected to a bot dead-end (#{URI(res.location).host})"] if res.location =~ /dead-end|captcha|blocked/i
      current = res.location
      next
    end
    return [nil, res.error || "tracking link returned HTTP #{res.status} instead of redirecting"]
  end
  [nil, "too many redirects"]
end

BRAND_GENERIC_RE = /\A(newest|new|latest|all-new|wifi|wi-fi|dash|smart|wireless|mini|portable|outdoor|indoor|security|camera|cam|bluetooth|video|home|tv|prime|like-new)\z/i

# Brands already used in _products (generic words like "Newest" left out).
def known_brands
  @known_brands ||= Dir[File.join(DealTools::PRODUCTS_DIR, "*.md")]
                    .filter_map { |f| DealTools.front_matter(f)["brand"].to_s.strip }
                    .reject { |b| b.empty? || b =~ BRAND_GENERIC_RE }.uniq
end

# known: true (Brad's Deals) also skips generic leading words ("Newest Blink
# Camera", "WiFi Security Camera") and matches multi-word brands from
# _products ("Harman Kardon"); after a skipped word only a known brand counts.
def brand_guess(name, known: false)
  if known
    words = name.to_s.split(/\s+/)
    skipped = words.take_while { |w| w.gsub(/[^\p{Alnum}\-]/, "") =~ BRAND_GENERIC_RE }.size
    words = words.drop(skipped)
    multi = known_brands.select { |b| b.include?(" ") }.find { |b| words.join(" ") =~ /\A#{Regexp.escape(b)}\b/i }
    return multi if multi
    if skipped.positive?
      w = words.first.to_s.gsub(/[^\p{Alnum}&\-]/, "")
      return known_brands.find { |b| b.casecmp?(w) }
    end
  end
  w = name.to_s.split(/\s+/).first.to_s.gsub(/[^\p{Alnum}&\-]/, "")
  return nil if w.length < 2 || w =~ /\A(new|the|refurbished|renewed|refurb|restored|open|open-box|select|grand|set|pack|\d.*|2-pack|3-pack|certified|used|apple's|my)\z/i || w == w.downcase
  w
end

# Walmart / Sam's Club titles: only a brand already used in _products, at the
# start of the title (after generic / condition words), in its _products
# spelling ("SAMSUNG 65\" ..." -> Samsung). Nothing else is guessed.
def known_brand_only(name)
  words = name.to_s.split(/\s+/)
  words = words.drop_while { |w| w.gsub(/[^\p{Alnum}\-]/, "") =~ BRAND_GENERIC_RE || w =~ /\A\(?(?:restored|refurbished|renewed|open|box\)?|pre-owned)\)?\z/i }
  rest = words.join(" ")
  known_brands.select { |b| rest =~ /\A#{Regexp.escape(b)}(?![\p{Alnum}])/i }.max_by(&:length)
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
  src_include = words_re.call(Array(source["include_keywords"]))
  next skip.call(item, "no source include keyword") if src_include && !src_include.match?(blob)
  feed_cat = item[:feed_category].to_s.strip
  next skip.call(item, "non-tech source category (#{feed_cat})") if skip_feed_cat_re&.match?(feed_cat)
  category = category_rules.find { |_, re| re.match?(title) }&.first
  category ||= feed_category_rules.find { |_, re| re.match?(feed_cat) }&.first unless feed_cat.empty?
  next skip.call(item, "no category keyword in title") if category.nil? && source["require_title_category"]
  category ||= fallback_category
  next skip.call(item, "no matching category") if category.nil? && filters.fetch("require_category", true)
  next skip.call(item, "category quota reached (#{category})") if max_per_category.positive? && cat_counts[category] >= max_per_category

  price = item[:price] || DealTools.first_price(title) || DealTools.first_price(item[:text])
  next skip.call(item, "price outside min/max") if price && ((filters["min_price"] && price < filters["min_price"]) || (filters["max_price"] && price > filters["max_price"]))
  compare = item[:compare_at] && price && item[:compare_at] > price ? item[:compare_at] : DealTools.compare_from_text(blob, price)
  # no_was_price (OWC pre-owned Macs): listed with their condition and no original
  # price, so the discount rules below don't apply; everything else does.
  no_was = item[:no_was_price] == true
  compare = nil if no_was

  # Resolve the real store link (circuit breaker after 3 blocked in a row).
  store_url = nil
  reason = nil
  if RunBlocks.source_blocked?(source["id"]) && !item.key?(:store_url)
    reason = "skipped: #{source['id']} was blocked this run"
  elsif source_blocked[source["id"]] >= 3
    reason = "skipped: #{source['id']} store links kept failing this run"
  elsif item.key?(:store_url)
    # Direct sources already know the product page (or why they don't).
    store_url = item[:store_url]
    reason = item[:unresolved_reason] || "no store link"
  else
    store_url, reason = resolve_store_url(item, source, http, max_redirects)
    source_blocked[source["id"]] = store_url ? 0 : source_blocked[source["id"]] + (reason =~ /none|robots/ ? 0 : 1)
  end
  notes = []
  notes << item[:price_note] if item[:price_note]
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
    elsif RunBlocks.source_blocked?(source["id"]) || RunBlocks.host_blocked?(store_url)
      notes << "Store page not read (#{source['id']} or #{host} was blocked this run); price/photo from #{source['name']}."
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
  compare = nil if no_was
  discount = compare && price ? ((1 - price / compare) * 100).round : nil
  min_disc = source["min_discount_pct"] || filters["min_discount_pct"]
  if discount && min_disc && discount < min_disc.to_i
    next skip.call(item, "discount below #{min_disc}%")
  end
  next skip.call(item, "unknown discount") if discount.nil? && !no_was && (filters["allow_unknown_discount"] == false || source["require_discount"])
  next skip.call(item, "no price found") unless price
  if discount && source["max_discount_pct"] && discount > source["max_discount_pct"].to_i
    next skip.call(item, "discount above #{source['max_discount_pct']}% (inflated list price?)")
  end

  name = data[:name].to_s.strip.empty? ? title : data[:name]
  short = DealTools.short_title(name, store: store)
  short = DealTools.short_title(title, store: store) if short.length < 8
  # Same product from the same store under another URL (colour/variant pages).
  title_key = "title:#{store.downcase}|#{short.downcase.gsub(/[^a-z0-9]+/, ' ').strip}"
  next skip.call(item, "same product already found (variant)") if seen[title_key]
  image_url = abs_img.call(data[:image].to_s) || item[:image]
  next skip.call(item, "no product image") if source["require_image"] && image_url.to_s.empty?
  brand = [data[:brand], item[:brand]].map { |b| b.to_s.strip }.find { |b| !b.empty? }
  brand ||= case source["parser"]
            when "bradsdeals" then brand_guess(name, known: true) || brand_guess(title, known: true)
            when "walmart", "samsclub" then known_brand_only(name)
            # OWC: a known brand at the start of the title, else the /item/<brand>/ URL segment if it is a known brand.
            when "owc" then known_brand_only(name) || known_brands.find { |b| b.casecmp?(item[:brand_hint].to_s) }
            else brand_guess(name)
            end
  # Same product at another store (or already queued): keep the best price.
  # At the same price Amazon wins over Walmart / Sam's Club found in this run.
  sig = DealTools.product_signature(short, brand: brand)
  sig = sig.sub(/\|n\z/, "|r") if sig && item[:condition].to_s.casecmp?("used") # used at the store, even when the title doesn't say so
  mpn_keys = DealTools.part_numbers(item[:mpns]).map { |m| "mpn:#{m}" }
  replaces = nil
  prev = (sig && sig_seen[sig]) || mpn_keys.lazy.filter_map { |k| sig_seen[k] }.first
  if prev
    amazon_over_walmart = prev[:price] == price && prev[:entry] && prev[:store].to_s =~ /walmart|sam's club/i &&
                          DealCopy.amazon?(store, store_url)
    next skip.call(item, "same product cheaper or equal elsewhere") if prev[:price] <= price && !amazon_over_walmart
    if prev[:entry]
      added.delete(prev[:entry])
      cat_counts[prev[:entry]["category"]] -= 1
      replaced << "#{prev[:entry]['title']} (#{prev[:store]} $#{prev[:price]}) -> #{store} $#{price}"
    elsif prev[:file]
      replaces = prev[:file]
      notes << "Cheaper than the published #{prev[:file]} (#{prev[:store]} $#{prev[:price]}): remove that one when approving this."
    elsif prev[:queued]
      notes << "Cheaper than queued #{prev[:queued]} (#{prev[:store]} $#{prev[:price]}): reject that one."
    end
  end
  highlights = Array(item[:highlights]).reject { |h| h.to_s.strip.empty? }
  highlights << "$#{(compare - price).round} under its usual price" if compare && !(store =~ /amazon/i || store_url.to_s =~ /amazon\.|amzn\./i)
  highlights << "Refurbished or open-box: check the condition notes at #{store.empty? ? 'the store' : store}" if title =~ /refurb|reconditioned|renewed|like-new|like new|open[- ]box|scratch/i && highlights.none? { |h| h =~ /used|refurb|open-box/i }
  highlights << "Free shipping" if blob =~ /free ship/i
  highlights << "May need a coupon or promo code at checkout" if blob =~ /\bcoupon\b|\bclip\b|promo code|\bcode\b/i
  highlights << "Prime members only" if blob =~ /prime (members|exclusive|only)/i
  expires = item[:expires] && item[:expires] >= today && item[:expires] <= today + 30 ? item[:expires] : today + (source["expires_days"] || defaults["expires_days"] || 7).to_i

  money_s = ->(v) { v == v.round ? "$#{v.round}" : format("$%.2f", v) }
  amazon = DealCopy.amazon?(store, store_url)
  # Prime Day (shown on /deals/prime-day/), Amazon only: the product (ASIN) or
  # Slickdeals thread is on a prime_day_roundups page, the item was read from
  # one, or the source text mentions Prime Day / Prime members.
  prime_src = nil
  if amazon && prime_index
    asin = DealTools.asin(store_url)
    thread = DealTools.slickdeals_thread_id(item[:link]) || DealTools.slickdeals_thread_id(item[:page])
    prime_src = (asin && prime_index[:asins][asin]) || (thread && prime_index[:threads][thread]) ||
                [item[:page], item[:listing]].filter_map { |u| prime_index[:pages][DealTools.page_key(u)] }.first
  end
  prime_text = DealTools.prime_day?("#{blob} #{item[:page] || item[:link]}", store: store, url: store_url)
  prime_src ||= item[:prime_day_source] || [item[:page], item[:listing], item[:link]].find { |u| u.to_s.start_with?("http") } if prime_text
  # Brad's Deals: the deal write-up beats store-page meta for the copy.
  overview = item[:writeup].to_s
  page_specs = []
  begin
    fm_probe = { "title" => short, "brand" => brand, "store" => store, "affiliate_url" => store_url }
    # enrich_store_page: false -> the listing data is all there is (Walmart / Sam's Club product pages aren't fetched).
    enrich_url = source["enrich_store_page"] == false || RunBlocks.source_blocked?(source["id"]) ? nil : SourceCache.enrichment_url(fm_probe)
    if enrich_url && !enrich_url.empty? && !SourceCache.amazon_url?(enrich_url)
      data = SourceCache.fetch_page(enrich_url, cfg: cfg, source_id: "find")
      unless data["error"]
        overview = data["overview"].to_s if overview.empty?
        page_specs = data["specs"] || []
      end
    end
  rescue StandardError => err
    warn "  enrich soft-fail: #{err.message[0, 80]}"
  end
  specs_preview = DealCopy.merge_specs(page_specs, DealCopy.specs_from_text(short, extra: "#{title} #{overview}", category: category))
  # Full product summary (what it is / who it's for). The price "why it's a deal"
  # line is rebuilt at publish time into why_deal / the deal tab.
  summary = DealCopy.summary(title: short, category: category, brand: brand, store: store,
                             specs: specs_preview, amazon: amazon, overview: overview)

  dedupe_key = key || item[:link]
  entry = {
    "id" => DealTools.deal_id(dedupe_key), "status" => "new", "title" => short, "store" => store,
    "price" => price, "compare_at" => compare, "discount_pct" => discount, "category" => category,
    "brand" => brand,
    # Shown on the deal ("Used"); only set by sources listing it without a was-price.
    "condition" => (item[:condition] if no_was),
    "affiliate_url" => store_url ? DealTools.affiliate_url(store_url) : "", "store_url" => store_url,
    "image" => image_url, "highlights" => highlights.first(3),
    "summary" => summary, "expires" => expires, "found" => today.dup, "source" => source["id"],
    "source_link" => item[:page] || item[:link], "source_title" => title[0, 140], "notes" => notes.empty? ? nil : notes.join(" "),
    "replaces" => replaces,
    "prime_day" => (true if prime_src || prime_text),
    "prime_day_source" => prime_src
  }.compact
  ([sig] + mpn_keys).compact.each { |k| sig_seen[k] = { price: price, store: store, entry: entry } }
  cat_counts[category] += 1
  seen[dedupe_key] = "already queued"
  seen[title_key] = "already queued"
  seen[item[:link]] = "already queued"
  log.call("  + #{entry['id']} #{short} — #{money_s.call(price)} at #{store}#{store_url ? '' : ' (unresolved)'}")
  entry
end

# ------------------------------------------------------------ run it ---
sources = Array(cfg["feeds"]).map { |f| f.merge("kind" => "feed") } + Array(cfg["sites"]).map { |s| s.merge("kind" => "site") }
sources.select! { |s| s["id"] == opts[:source] } if opts[:source]
disabled = sources.select { |s| s["enabled"] == false }
sources.reject! { |s| s["enabled"] == false }
disabled.each { |s| puts "-- #{s['name'] || s['id']}: disabled#{s['note'] ? " (#{s['note']})" : ''}" } if opts[:verbose]

sources.each do |source|
  break if added.size >= limit
  puts "== #{source['name'] || source['id']} (#{source['url'] || "#{Array(source['urls']).size} pages"}#{source['fetch'] ? ", fetch: #{source['fetch']}" : ''})"
  # Official APIs: skipped quietly until their key is in the environment.
  missing_env = Array(source["env"]).select { |k| ENV[k].to_s.strip.empty? }
  unless missing_env.empty?
    puts "   skipped: #{missing_env.join(', ')} not set"
    stats[:sources_skipped] += 1
    next
  end
  # unless_env: run only while these are missing (e.g. a ZenRows stand-in until an official API key exists).
  if Array(source["unless_env"]).any? { |k| !ENV[k].to_s.strip.empty? }
    puts "   skipped: #{Array(source['unless_env']).join(', ')} is set, the official source takes over"
    next
  end
  if DirectSources::PLANNED.include?(source["parser"].to_s)
    puts "   skipped: the #{source['parser']} adapter isn't built yet"
    next
  end
  # A host that answered 403 / 429 / a bot wall earlier this run: no requests at all.
  if (why = RunBlocks.skip_source?(source))
    puts "   #{why}"
    next
  end
  RunBlocks.source = source
  # Feeds are published for feed readers, so (like any feed reader) the feed URL
  # itself isn't checked against robots.txt. Everything else is.
  res = source["kind"] == "feed" ? http.follow(source["url"], max: max_redirects, robots: false).last : http.follow(source["url"], max: max_redirects).last unless source["parser"]
  unless source["parser"] || res&.ok?
    puts "   fetch failed: #{res&.error || "HTTP #{res&.status}"}" unless res&.blocked
    stats[:sources_failed] += 1
    next
  end
  items =
    if (meth = DirectSources::PARSERS[source["parser"].to_s])
      if meth == :macheist_items
        DirectSources.macheist_items(fetcher, source, category_re: Regexp.union(category_rules.map(&:last)), exclude_re: exclude_re)
      elsif meth == :bradsdeals_items
        # Same cheap filters as build_candidate, applied before any detail page is opened.
        DirectSources.bradsdeals_items(fetcher, source, category_re: Regexp.union(category_rules.map(&:last)), exclude_re: exclude_re,
                                                        known: ->(url) { seen[DealTools.url_key(url)] })
      elsif opts[:recheck] && source["recheck_missing"] && DirectSources.method(meth).parameters.any? { |_, n| n == :listing }
        DirectSources.public_send(meth, fetcher, source, listing: (recheck_listings[source["id"]] = {}))
      else
        warn "deal_sources.yml: recheck_missing isn't supported by the #{source['parser']} parser" if source["recheck_missing"]
        DirectSources.public_send(meth, fetcher, source)
      end
    elsif source["parser"] == "techbargains_pages"
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
  # Published deals seen in this source's items (all of them, before max_items;
  # items older than max_age_hours don't show today's price).
  max_age = source["max_age_hours"] || filters["max_age_hours"]
  items.each do |it|
    next unless published.any? && it[:price]&.positive? && (k = item_key.call(it)) && published[k]
    next if it[:published] && max_age && now - it[:published] > max_age.to_f * 3600
    recheck_hits[k] << { price: it[:price].to_f, was: it[:compare_at], source: source["id"] }
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
  items.each do |it|
    next unless (c = it[:price_conflict])
    stats[:price_conflicts] += 1
    log.call("  price conflict: #{c[:title].to_s[0, 70]} | listing $#{c[:listing]} | write-up $#{c[:writeup]}")
  end
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
RunBlocks.source = nil

# ------------------------------------------- re-check published deals ---
# Prices of published deals against the listings read in this run (no extra
# requests). Listing price higher by more than 1% or $0.50 -> expired; lower is
# only reported. recheck_missing: sources whose listing loaded (no failed page,
# at least 10 products) also expire their own deals that are gone from the
# listing or skipped there (not in stock, member-only price, ...).
# Sources blocked this run (403 / 429 / bot wall, or their host was): their
# deals are skipped entirely and their items are no evidence for other deals.
recheck = { matched: 0, confirmed: 0, cheaper: [], expired: [], skipped_blocked: Hash.new(0) }
fmt_money = ->(v) { v == v.round ? "$#{v.round}" : format("$%.2f", v) }
if opts[:recheck]
  blocked_ids = RunBlocks.blocked_source_ids
  usable = recheck_listings.select do |id, l|
    if blocked_ids.include?(id)
      puts "Re-check: #{id} listing not used (#{id} was blocked this run)"
      next false
    end
    n = l[:products]&.size.to_i
    ok = l[:ok] && n >= 10
    puts "Re-check: #{id} listing not used for missing deals (#{l[:ok] ? "only #{n} products" : 'a page failed'})" unless ok
    ok
  end
  published.each do |k, pub|
    name = File.basename(pub[:path])
    if blocked_ids.include?(pub[:source])
      recheck[:skipped_blocked][pub[:source]] += 1
      log.call("  not re-checked: #{name} (#{pub[:source]} was blocked this run)")
      next
    end
    reason = rec = nil
    if (l = usable[pub[:source]])
      if !(rec = l[:products][k])
        reason = "not on the #{pub[:source]} listing (#{l[:products].size} products, #{today})"
      elsif rec[:why]
        reason = "#{rec[:why]} on the #{pub[:source]} listing (#{today})"
      end
    end
    hits = recheck_hits[k].reject { |h| blocked_ids.include?(h[:source]) }
    hits += [{ price: rec[:price], was: rec[:was], source: pub[:source] }] if rec && !rec[:why] && rec[:price]
    next if reason.nil? && hits.empty?
    recheck[:matched] += 1
    # The deal's own source wins; otherwise the lowest listing price.
    hit = hits.select { |h| h[:source] == pub[:source] }.min_by { |h| h[:price] } || hits.min_by { |h| h[:price] }
    if reason.nil? && hit && pub[:price].positive?
      diff = hit[:price] - pub[:price]
      if diff > 0.5 || diff > pub[:price] * 0.01
        reason = "listing price #{fmt_money.call(hit[:price])} > #{fmt_money.call(pub[:price])} (#{hit[:source]}, #{today})"
      elsif diff < -0.005
        recheck[:cheaper] << "now cheaper: #{name}, published #{fmt_money.call(pub[:price])}, listing #{fmt_money.call(hit[:price])} (#{hit[:source]})"
      end
    end
    unless reason
      recheck[:confirmed] += 1
      log.call("  confirmed: #{name}#{hit ? " #{fmt_money.call(hit[:price])}#{hit[:was] ? " (was #{fmt_money.call(hit[:was])})" : ''} via #{hit[:source]}" : ''}")
      next
    end
    recheck[:expired] << "#{name}: #{reason}"
    next if opts[:dry_run]
    # Only the expires / expired_reason lines change (like --tag-prime-day).
    text = File.read(pub[:path])
    m = text.match(/\A---\s*\n(.*?)\n---\s*(\n|\z)/m) or next
    fm = m[1].gsub(/^expired_reason:.*\n?/, "").sub(/\n\z/, "")
    exp = "expires: #{today - 1}"
    fm = fm =~ /^expires:.*$/ ? fm.sub(/^expires:.*$/, exp) : "#{fm}\n#{exp}"
    fm = "#{fm}\nexpired_reason: #{reason.to_json}"
    File.write(pub[:path], text[0, m.begin(1)] + fm + text[m.end(1)..])
  end
end

queue.concat(added)
DealTools.save_queue(queue) unless opts[:dry_run]
# Credits are spent even on a dry run, so the usage counts are always saved.
fetcher.save_usage!

puts
puts "Items fetched: #{stats[:items_fetched]}  (checked after filters: #{stats[:items_seen]})"
puts "New candidates: #{added.size}  (store link resolved: #{added.count { |e| e['store_url'] }}, unresolved: #{added.count { |e| !e['store_url'] }})"
puts "Store pages read: #{stats[:store_fetch_ok]}, failed/blocked: #{stats[:store_fetch_failed]}"
puts "Price conflicts (listing data vs write-up, over 2%): #{stats[:price_conflicts]}" if stats[:price_conflicts].positive?
puts "Dropped stale queue entries: #{dropped_stale}" if dropped_stale.positive?
puts "HTTP requests: #{http.stats[:requests]}, blocked by robots.txt: #{http.stats[:robots_blocked]}, errors: #{http.stats[:errors]}"
puts "ZenRows: #{fetcher.usage_stats[:requests]} requests, #{fetcher.usage_stats[:credits]} credits this run; " \
     "#{fetcher.credits_this_month}/#{fetcher.cap} credits this month#{fetcher.zenrows_key? ? '' : ' (ZENROWS_API_KEY not set)'}"
puts "Run: #{DealTools.deep? ? 'deep' : 'daily'}; new per category: #{cat_counts.select { |_, n| n.positive? }.sort_by { |_, n| -n }.map { |c, n| "#{c} #{n}" }.join(', ')}"
puts "Prime Day tagged: #{added.count { |e| e['prime_day'] }}" if prime_index || added.any? { |e| e["prime_day"] }
puts "Replaced in this run by a cheaper store: #{replaced.size}" unless replaced.empty?
replaced.each { |r| puts "  #{r}" }
puts "Skipped:" unless skips.empty?
skips.sort_by { |_, n| -n }.each { |r, n| puts "  #{n.to_s.rjust(4)}  #{r}" }
puts "Unresolved store links:" unless unresolved_reasons.empty?
unresolved_reasons.sort_by { |_, n| -n }.each { |r, n| puts "  #{n.to_s.rjust(4)}  #{r}" }
if opts[:recheck]
  puts "Re-checked published deals: matched #{recheck[:matched]}, confirmed #{recheck[:confirmed]}, " \
       "now cheaper #{recheck[:cheaper].size}, expired #{recheck[:expired].size}#{opts[:dry_run] && recheck[:expired].any? ? ' (dry run: nothing written)' : ''}"
  recheck[:cheaper].each { |c| puts "  #{c}" }
  recheck[:expired].each { |e| puts "  expired #{e}" }
  sb = recheck[:skipped_blocked]
  puts "Re-check skipped #{sb.values.sum} published deals whose source was blocked this run (#{sb.map { |id, n| "#{id} #{n}" }.join(', ')})" unless sb.empty?
end
puts "Blocked this run: #{RunBlocks.summary}"
puts(opts[:dry_run] ? "(dry run: queue not saved)" : "Queue: #{DealTools::QUEUE_FILE.sub("#{DealTools::ROOT}/", '')} (#{queue.size} entries)")
added.each { |e| puts "  #{e['id']}  #{e['title']} | #{e['price']}#{e['compare_at'] ? " (was #{e['compare_at']})" : ''} | #{e['store']} | #{e['category']} | #{e['affiliate_url'].to_s.empty? ? 'NO STORE LINK' : e['affiliate_url']}" }
