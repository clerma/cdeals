# frozen_string_literal: true

# Shared helpers for scripts/find_deals.rb and scripts/publish_deals.rb.
require "yaml"
require "date"
require "time"
require "uri"
require "net/http"
require "digest"
require "json"
require "cgi"

module DealTools
  ROOT = File.expand_path("../..", __dir__)
  QUEUE_FILE = File.join(ROOT, "_deal_queue", "queue.yml")
  REJECTED_FILE = File.join(ROOT, "_deal_queue", "rejected.yml")
  SOURCES_FILE = File.join(ROOT, "_data", "deal_sources.yml")
  PRODUCTS_DIR = File.join(ROOT, "_products")

  QUEUE_HEADER = <<~TXT
    # Deal candidates waiting for review. Written by scripts/find_deals.rb.
    # Nothing here is on the site. For each entry set
    #   status: approved   -> scripts/publish_deals.rb turns it into _products/<slug>.md
    #   status: rejected   -> removed and remembered so it never comes back
    # You can edit title, price, compare_at, category, brand, highlights,
    # affiliate_url, etc. before approving. Entries with a blank affiliate_url
    # (store link not found) need the store link pasted in first.
  TXT

  REJECTED_HEADER = <<~TXT
    # Deals you rejected. The finder never queues these again.
  TXT

  module_function

  def load_yaml(path, default)
    return default unless File.exist?(path)
    YAML.safe_load(File.read(path), permitted_classes: [Date, Time], aliases: true) || default
  end

  def config
    @config ||= load_yaml(SOURCES_FILE, {})
  end

  def site_config
    @site_config ||= load_yaml(File.join(ROOT, "_config.yml"), {})
  end

  def categories_yml
    @categories_yml ||= load_yaml(File.join(ROOT, "_data", "categories.yml"), [])
  end

  # Category names from _data/categories.yml (a list of {slug, name, icon}).
  def category_names
    Array(categories_yml).map { |c| c.is_a?(Hash) ? c["name"] : c.to_s }.compact
  end

  def load_queue = load_yaml(QUEUE_FILE, [])
  def load_rejected = load_yaml(REJECTED_FILE, [])

  def write_list(path, header, list)
    body = list.empty? ? "[]\n" : list.to_yaml.sub(/\A---\n/, "")
    File.write(path, header + body)
  end

  def save_queue(list) = write_list(QUEUE_FILE, QUEUE_HEADER, list)
  def save_rejected(list) = write_list(REJECTED_FILE, REJECTED_HEADER, list)

  # ---------------------------------------------------------------- URLs ---

  AMAZON_HOST = /(^|\.)amazon\.(com|ca|co\.uk|de)$/i
  ASIN_RE = %r{/(?:dp|gp/product|gp/aw/d|exec/obidos/ASIN|o/ASIN)/([A-Z0-9]{10})(?:[/?]|$)}i

  # Query params that are tracking/affiliate noise, never part of the product.
  TRACKING_PARAM = /\A(utm_.*|aff.*|irgwc|irclickid|clickid|click_id|cjevent|cjdata|sharedid|subid\d*|u1|ran(mid|eaid|siteid)|siteid|ref|ref_|tag|ascsubtag|camp|creative|linkcode|creativeasin|wmlspartner|sourceid|veh|campaign_?id|partner.*|publisherid|clickref|awc|sscid|ascid|mcid|gclid|fbclid|msclkid|adid|lid|th|psc|smid|ie|pd_rd_.*|pf_rd_.*|content-id|sd_.*|sdtid|sdfib|iref|xs|cid|icid|epik|loc|acampid|mpid|intl|rdr)\z/i

  # Affiliate networks / redirectors: the real URL is often a query param.
  TRACKER_HOST = /(^|\.)(linksynergy\.com|anrdoezrs\.net|dpbolvw\.net|jdoqocy\.com|tkqlhce\.com|kqzyfj\.com|emjcd\.com|shareasale\.com|awin1\.com|skimresources\.com|viglink\.com|redirectingat\.com|sjv\.io|pxf\.io|ojrq\.net|evyy\.net|7tiv\.net|goto\.walmart\.com|go\.magik\.ly|howl\.me|geni\.us|amzn\.to|bit\.ly|tidd\.ly|prf\.hn|avantlink\.com|pjtra\.com|pntrs\.com|slickdeals\.net|dealnews\.com|bensbargains\.com|techbargains\.com|dlnws\.com)$/i
  DEST_PARAMS = %w[murl url u ued urllink dest destination dl new deeplink lp].freeze

  def parse_uri(url)
    u = URI.parse(url.to_s.strip)
    u.is_a?(URI::HTTP) ? u : nil
  rescue URI::InvalidURIError
    begin
      u = URI.parse(URI::DEFAULT_PARSER.escape(url.to_s.strip))
      u.is_a?(URI::HTTP) ? u : nil
    rescue StandardError
      nil
    end
  end

  def bare_host(u) = u.host.to_s.downcase.sub(/\Awww\./, "")

  def tracker?(url)
    u = parse_uri(url)
    u && TRACKER_HOST.match?(u.host.to_s)
  end

  # Pull a destination URL out of a tracking link without requesting it.
  def embedded_destination(url)
    u = parse_uri(url) or return nil
    return nil unless u.query
    URI.decode_www_form(u.query).each do |k, v|
      next unless DEST_PARAMS.include?(k.downcase)
      v = URI.decode_www_form_component(v) if v.start_with?("http%3A", "https%3A")
      return v if v.start_with?("http://", "https://") && !v.include?(u.host)
    end
    nil
  rescue ArgumentError
    nil
  end

  def asin(url)
    u = parse_uri(url) or return nil
    return nil unless AMAZON_HOST.match?(u.host.to_s)
    u.path[ASIN_RE, 1]&.upcase
  end

  # Plain store URL: tracking params, fragments and affiliate tags removed.
  def clean_store_url(url)
    if (a = asin(url))
      return "https://www.amazon.com/dp/#{a}"
    end
    u = parse_uri(url) or return nil
    u = u.dup
    u.fragment = nil
    if u.query
      kept = URI.decode_www_form(u.query).reject { |k, _| TRACKING_PARAM.match?(k) }
      u.query = kept.empty? ? nil : URI.encode_www_form(kept)
    end
    u.to_s
  rescue ArgumentError
    url
  end

  # Key used for de-duplication.
  def url_key(url)
    return nil if url.to_s.strip.empty?
    if (a = asin(url))
      return "amazon:#{a}"
    end
    u = parse_uri(clean_store_url(url)) or return url.to_s.downcase
    # Walmart / Sam's Club product pages: the item id (usItemId) is the product;
    # the slug before it varies (/ip/<slug>/<id>, /ip/seort/<id>).
    if bare_host(u) =~ /\A(?:walmart|samsclub)\.com\z/ && (id = u.path[%r{\A/ip/(?:[^/]+/)?(\d+)/?\z}, 1])
      return "#{bare_host(u)}/ip/#{id}"
    end
    # OWC (eshop.macsales.com): /item/<brand>/<part>/ is the product, no query;
    # pre-owned Mac configurations keep only their ?sku=.
    if bare_host(u).end_with?("macsales.com")
      sku = u.path.start_with?("/configure-my-mac/") && URI.decode_www_form(u.query.to_s).assoc("sku")&.last
      return "#{bare_host(u)}#{u.path.downcase.chomp('/')}#{sku ? "?sku=#{sku.downcase}" : ''}"
    end
    q = u.query ? "?#{URI.decode_www_form(u.query).sort.map { |k, v| "#{k}=#{v}" }.join('&')}" : ""
    "#{bare_host(u)}#{u.path.downcase.chomp('/')}#{q}"
  rescue ArgumentError
    url.to_s.downcase
  end

  # The link that goes on the site.
  def affiliate_url(store_url)
    return "" if store_url.to_s.empty?
    if (a = asin(store_url))
      tag = site_config["amazon_tag"].to_s.strip
      # TODO: geniuslink_group support (would wrap the Amazon link). Pass-through for now.
      return tag.empty? ? "https://www.amazon.com/dp/#{a}" : "https://www.amazon.com/dp/#{a}?tag=#{URI.encode_www_form_component(tag)}"
    end
    clean_store_url(store_url)
  end

  STORE_NAMES = {
    "amazon.com" => "Amazon", "bestbuy.com" => "Best Buy", "walmart.com" => "Walmart",
    "woot.com" => "Woot", "newegg.com" => "Newegg", "dell.com" => "Dell", "lenovo.com" => "Lenovo",
    "homedepot.com" => "Home Depot", "target.com" => "Target", "ebay.com" => "eBay",
    "bhphotovideo.com" => "B&H Photo", "costco.com" => "Costco", "macsales.com" => "OWC",
    "apple.com" => "Apple", "samsung.com" => "Samsung", "hp.com" => "HP", "microsoft.com" => "Microsoft",
    "adorama.com" => "Adorama", "officedepot.com" => "Office Depot", "staples.com" => "Staples",
    "microcenter.com" => "Micro Center", "antonline.com" => "Antonline", "stacksocial.com" => "StackSocial",
    "lowes.com" => "Lowe's", "kohls.com" => "Kohl's", "gamestop.com" => "GameStop", "sonos.com" => "Sonos",
    "backmarket.com" => "Back Market", "macheist.com" => "MacHeist", "googlestore.com" => "Google Store", "store.google.com" => "Google Store"
  }.freeze

  def store_name(url)
    u = parse_uri(url) or return nil
    h = bare_host(u)
    STORE_NAMES.each { |dom, name| return name if h == dom || h.end_with?(".#{dom}") }
    label = h.split(".")[-2] || h
    label.capitalize
  end

  # ---------------------------------------------------------------- Text ---

  def money(str)
    return nil if str.nil?
    return str.to_f.round(2) if str.is_a?(Numeric)
    m = str.to_s.gsub(",", "")[/\d+(?:\.\d{1,2})?/]
    m && m.to_f.round(2)
  end

  def first_price(text)
    m = text.to_s.match(/\$\s?([\d,]+(?:\.\d{2})?)/)
    m && money(m[1])
  end

  # Original (list) price from the deal text, using real figures only:
  #   "reg $99", "list $199", "was $79", "This is normally $249", "Originally $999.99",
  #   "the $99.99 list price", "the regular $149.99 price",
  #   "$200 off list price" / "Save $39 off the $549 regular price" (price + that amount).
  # Never estimates: "about $70 off" and "NN% off" alone are ignored.
  # Returns nil unless the original is higher than the price.
  PRICE_RE = /\$\s?([\d,]+(?:\.\d{1,2})?)/.freeze
  def compare_from_text(text, price)
    t = text.to_s.gsub(/\s+/, " ")
    return nil unless price
    ok = ->(v) { v && v > price ? v : nil }
    # "$99.99 list price", "$549.00 regular price", "regular $149.99 price"
    if (m = t.match(/#{PRICE_RE.source}\s*(?:list|regular|retail|original)\s*price/i) ||
            t.match(/\b(?:list|regular|retail|original)\s*(?:price\s*)?(?:of\s*|is\s*)?:?\s*#{PRICE_RE.source}/i) ||
            t.match(/\b(?:normally|originally|regularly|usually|typically|reg\.?|was|orig\.?|msrp)\s*(?:price\s*)?(?:of\s*|is\s*|at\s*)?:?\s*#{PRICE_RE.source}/i))
      v = ok.call(money(m[1]))
      return v if v
    end
    # "$200 off list price", "Save $39 off the $549 regular price" handled above; plain "$N off (the) list/regular price"
    if (m = t.match(/(?<!about )(?<!around )(?<!roughly )#{PRICE_RE.source}\s*off\s*(?:the\s*|its\s*)?(?:list|regular|retail|original)\s*price/i))
      return ok.call((price + money(m[1])).round(2))
    end
    nil
  end

  # Short title written from the product name (not the feed's headline).
  def short_title(name, store: nil)
    t = name.to_s.dup
    t.sub!(/\A[^:]{0,40}\b(stores?|members?|in-store|prime|today only|ends today)\b[^:]{0,20}:\s+/i, "")
    t.gsub!(/\s*[\(\[][^)\]]*(\$|free ship|w\/|prime|coupon|reg\.|list|after|code)[^)\]]*[\)\]]/i, "")
    t.sub!(/\s+(?:for|now|only|just|from|starting at|@)?\s*\$\s?[\d,]+(?:\.\d{2})?.*\z/i, "")
    t.sub!(/\s+(?:at|@|via)\s+#{Regexp.escape(store)}\b.*\z/i, "") if store
    t.sub!(/\A#{Regexp.escape(store)}\s*(?:has|offers)\s+(?:the\s+)?/i, "") if store
    t.gsub!(/\s*[-–—|:]\s*(free shipping|amazon\.com|walmart\.com|best buy).*\z/i, "")
    t.gsub!(/\s*\+\s*free\s+(shipping|s&h).*\z/i, "")
    t.gsub!(/\s+/, " ")
    t = t.strip.sub(/[\s,;:\-–—]+\z/, "")
    if t.length > 75
      t = t[0, 75].sub(/\s+\S*\z/, "")
    end
    t = t.sub(/\s*\([^)]*\z/, "") # drop a parenthesis cut off by truncation
    t = t.sub(/(\s+(with|w\/|and|&|for|in|of|plus|\+|-|–|built-in))+\z/i, "").sub(/[\s,;:\-–—(\/&]+\z/, "")
    t
  end

  # Ask feed image CDNs for a larger size than the feed's thumbnail.
  def bigger_image(url)
    return nil if url.nil?
    url.sub(/(techbargains\.com\/imagery\/.*\.size_)\d+x\d+/, "\\1500x500")
       .sub(/(dlnws\.com\/.*)\?h=\d+&w=\d+\z/, "\\1?h=600&w=600")
  end

  # Prime Day evidence in a deal's source text (title, notes, description,
  # feed/page text, source link): "Prime Day", "Prime Big Deal Days", or a
  # Prime-exclusive / Prime-members price. Same wording the finder's "Prime
  # members only" highlight uses. Only Amazon deals get `prime_day: true`.
  PRIME_DAY_RE = /\bprime[\s-]*(?:days?|big[\s-]*deals?[\s-]*days?|members?|exclusives?|only)\b/i

  def prime_day?(text, store:, url: nil)
    return false unless store.to_s =~ /amazon/i || url.to_s =~ /amazon\.|amzn\./i

    PRIME_DAY_RE.match?(text.to_s)
  end

  # Prime Day roundup pages (prime_day_roundups: in deal_sources.yml): listings
  # whose Amazon products / Slickdeals threads count as Prime Day evidence.
  PRIME_EVENT_TITLE_RE = /\bprime[\s-]*(?:days?|big[\s-]*deals?[\s-]*days?)\b/i

  def prime_day_roundups(cfg = config)
    Array(cfg["prime_day_roundups"]).select { |r| r.is_a?(Hash) && r["url"].to_s.start_with?("http") && r["enabled"] != false }
  end

  # Listing URL without scheme/www/query/trailing slash, for page matching.
  def page_key(url)
    u = parse_uri(url) or return nil
    "#{bare_host(u)}#{u.path.downcase.chomp('/')}"
  end

  def slickdeals_thread_id(url)
    u = parse_uri(url) or return nil
    return nil unless bare_host(u).end_with?("slickdeals.net")
    u.path[%r{\A/f/(\d+)}, 1]
  end

  # Amazon ASINs and Slickdeals thread IDs on a roundup page. Store links can
  # be HTML-escaped, URL-encoded (tracker ?url=...) and JSON-escaped (\/).
  def prime_day_evidence(html)
    s = CGI.unescapeHTML(html.to_s).gsub("\\/", "/")
    2.times { s = s.gsub(/%2F/i, "/").gsub(/%3A/i, ":").gsub(/%3F/i, "?").gsub(/%3D/i, "=").gsub(/%26/i, "&") }
    asins = s.scan(%r{amazon\.com/(?:[^\s"'<>/?]{1,120}/)?(?:dp|gp/product|gp/aw/d)/([A-Z0-9]{10})(?![A-Z0-9])}i).flatten.map(&:upcase)
    threads = s.scan(%r{(?:slickdeals\.net|["'=\s])/f/(\d{4,})(?=[-?#/"'\s]|\z)}).flatten
    { asins: asins.uniq, threads: threads.uniq }
  end

  def slugify(str)
    s = str.to_s.downcase.gsub(/['"]/, "").gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    s.length > 60 ? s[0, 61].sub(/-[^-]*\z/, "") : s
  end

  def deal_id(key) = "d-#{Digest::SHA1.hexdigest(key.to_s)[0, 7]}"

  # ------------------------------------------------------------ Products ---

  def front_matter(path)
    s = File.read(path)
    m = s.match(/\A---\s*\n(.*?)\n---\s*(\n|\z)/m) or return {}
    YAML.safe_load(m[1], permitted_classes: [Date, Time]) || {}
  rescue StandardError
    {}
  end

  def existing_product_keys
    Dir[File.join(PRODUCTS_DIR, "*.md")].each_with_object({}) do |f, h|
      fm = front_matter(f)
      k = url_key(fm["affiliate_url"])
      h[k] = File.basename(f) if k
    end
  end

  # ------------------------------------------------- deep runs / paging ---
  # Daily runs read each source's `urls`. A deep run (find_deals.rb --deep, or
  # DEALS_DEEP=1) also reads `deep_urls`, uses `deep_pages` instead of `pages`
  # and ignores `rotate_daily`.
  def deep? = ENV["DEALS_DEEP"] == "1"

  # Listing URLs for a source on this run:
  #   rotate_daily: K  -> only K of the urls per day, rotating by day of year
  #                       (keeps daily ZenRows credits small; deep runs read all)
  #   pages: N + page_format: "{url}/pn/{n}" -> pages 2..N of every url too
  def source_urls(source, today: Date.today)
    urls = Array(source["urls"])
    urls += Array(source["deep_urls"]) if deep?
    k = source["rotate_daily"].to_i
    if k.positive? && !deep? && urls.size > k
      start = (today.yday * k) % urls.size
      urls = (urls + urls)[start, k]
    end
    pages = (deep? ? (source["deep_pages"] || source["pages"]) : source["pages"]).to_i
    fmt = source["page_format"].to_s
    return urls if pages <= 1 || fmt.empty?
    urls.flat_map { |u| [u] + (2..pages).map { |n| fmt.gsub("{url}", u).gsub("{n}", n.to_s) } }
  end

  # Same product at different stores: brand + model-number-like tokens +
  # storage sizes + condition. nil when the title has no model-like token
  # (then only the per-store title check applies).
  SIG_STOP = /\A(?:19|20)\d\d\z|\A\d+(?:hz|w|mah|mm|in|inch|ft|pack|pk|pcs?|ct|th|nd|rd|st|x)\z|\Awi-?fi\d?\z|\A\d+(?:k|p)\z|\Ausb\d?\z|\Ahdmi\d?\z|\A\d+gb(?:\/s|ps)\z/
  def product_signature(title, brand: nil)
    t = title.to_s.downcase.gsub(/[®™()\[\],|:;"]/, " ")
    words = t.split(/\s+/).map { |w| w.gsub(/\A[^a-z0-9]+|[^a-z0-9]+\z/, "") }.reject(&:empty?)
    models = words.select { |w| w =~ /[a-z]/ && w =~ /\d/ && w.length >= 3 && w !~ SIG_STOP && w !~ /\A\d+(?:gb|tb)\z/ }
    return nil if models.none? { |w| w.gsub(/[^a-z0-9]/, "").length >= 4 }
    sizes = words.select { |w| w =~ /\A\d+(?:gb|tb)\z/ || w =~ /\A\d{2,3}(?:\.\d)?(?:in|inch)?\z/ }  # storage and screen sizes
    cond = t =~ /refurb|renewed|open[- ]box|\bused\b|pre-owned/ ? "r" : "n"
    b = (brand.to_s.strip.empty? ? words.first : brand.to_s.downcase.split.first).to_s
    "sig:#{b}|#{models.uniq.sort.join(',')}|#{sizes.uniq.sort.join(',')}|#{cond}"
  end

  # Part numbers (OWC's Mfr P/N and SKU) as lowercase letters+digits, at least
  # 6 characters with both letters and digits ("US4EXP1M2" -> "us4exp1m2").
  def part_numbers(list)
    Array(list).map { |s| s.to_s.downcase.gsub(/[^a-z0-9]/, "") }.select { |s| s.length >= 6 && s =~ /[a-z]/ && s =~ /\d/ }.uniq
  end

  # Published deals by part-number-like token of their store URL path or title
  # (B&H: .../owc_owcus4exp1m2_express_1m2...html): { "mpn:<token>" => [file, store, price] }
  # (cheapest kept). Only items that carry part numbers (OWC) are looked up here.
  def existing_part_number_index
    Dir[File.join(PRODUCTS_DIR, "*.md")].each_with_object({}) do |f, h|
      fm = front_matter(f)
      next unless fm["type"].to_s == "affiliate"
      path = parse_uri(fm["affiliate_url"])&.path.to_s
      price = fm["price"].to_f
      part_numbers("#{path} #{fm['title']}".downcase.split(/[^a-z0-9]+/)).each do |t|
        h["mpn:#{t}"] = [File.basename(f), fm["store"].to_s, price] if h["mpn:#{t}"].nil? || price < h["mpn:#{t}"][2]
      end
    end
  end

  # Published deals by signature: { sig => [file, store, price] } (cheapest kept).
  def existing_product_signatures
    Dir[File.join(PRODUCTS_DIR, "*.md")].each_with_object({}) do |f, h|
      fm = front_matter(f)
      next unless fm["type"].to_s == "affiliate"
      sig = product_signature(fm["title"], brand: fm["brand"]) or next
      price = fm["price"].to_f
      h[sig] = [File.basename(f), fm["store"].to_s, price] if h[sig].nil? || price < h[sig][2]
    end
  end
end

