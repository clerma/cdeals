# frozen_string_literal: true

# Shared helpers for scripts/find_deals.rb and scripts/publish_deals.rb.
require "yaml"
require "date"
require "time"
require "uri"
require "net/http"
require "digest"
require "json"

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
    @categories_yml ||= load_yaml(File.join(ROOT, "_data", "categories.yml"), {})
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
  TRACKING_PARAM = /\A(utm_.*|aff.*|irgwc|irclickid|clickid|click_id|cjevent|cjdata|sharedid|subid\d*|u1|ran(mid|eaid|siteid)|siteid|ref|ref_|tag|ascsubtag|camp|creative|linkcode|creativeasin|wmlspartner|sourceid|veh|partner.*|publisherid|clickref|awc|sscid|ascid|mcid|gclid|fbclid|msclkid|adid|lid|th|psc|smid|ie|pd_rd_.*|pf_rd_.*|content-id|sd_.*|sdtid|sdfib|iref|xs|cid|icid|epik|loc|acampid|mpid|intl|rdr)\z/i

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
    "backmarket.com" => "Back Market", "googlestore.com" => "Google Store", "store.google.com" => "Google Store"
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

  # Original price from phrases like "list $199", "reg. $99", "$40 savings", "50% off".
  def compare_from_text(text, price)
    t = text.to_s
    if (m = t.match(/\b(?:list|reg(?:ular)?|was|orig(?:inal|\.)?|retail|msrp|normally|typically)\.?\s*(?:price\s*)?(?:of\s*)?:?\s*\$\s?([\d,]+(?:\.\d{2})?)/i))
      v = money(m[1])
      return v if price && v > price
    end
    if price && (m = t.match(/\$\s?([\d,]+(?:\.\d{2})?)\s*(?:savings|off\b)/i) || t.match(/\bsave\s*\$\s?([\d,]+(?:\.\d{2})?)/i))
      return (price + money(m[1])).round(2)
    end
    if price && (m = t.match(/\b(\d{1,2})%\s*off\b/i))
      pct = m[1].to_i
      return (price / (1 - pct / 100.0)).round(0).to_f if pct.between?(5, 90)
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
    t = t.sub(/(\s+(with|w\/|and|&|for|in|of|plus|\+|-|–))+\z/i, "").sub(/[\s,;:\-–—(\/&]+\z/, "")
    t
  end

  # Ask feed image CDNs for a larger size than the feed's thumbnail.
  def bigger_image(url)
    return nil if url.nil?
    url.sub(/(techbargains\.com\/imagery\/.*\.size_)\d+x\d+/, "\\1500x500")
       .sub(/(dlnws\.com\/.*)\?h=\d+&w=\d+\z/, "\\1?h=600&w=600")
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
end
