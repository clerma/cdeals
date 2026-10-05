# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "nokogiri"
require_relative "polite_http"
require_relative "fetcher"
require_relative "deal_tools"

# Fetches and caches store / manufacturer page text for deal enrichment.
# Cache root: /workspace/cdeals-cache (gitignored). Never fetches amazon.com.
module SourceCache
  module_function

  ROOT = ENV.fetch("CDEALS_CACHE", "/workspace/cdeals-cache")
  AMAZON_HOSTS = %w[amazon.com amzn.to amzn.com amazon.co.uk].freeze

  def amazon_url?(url)
    host = DealTools.bare_host(URI(url)) rescue ""
    AMAZON_HOSTS.any? { |h| host == h || host.end_with?(".#{h}") }
  end

  def cache_path(url)
    key = Digest::SHA1.hexdigest(url.to_s)
    File.join(ROOT, "pages", "#{key}.json")
  end

  def read_cache(url)
    path = cache_path(url)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  def write_cache(url, data)
    path = cache_path(url)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data.merge("url" => url, "cached_at" => Time.now.utc.iso8601)) + "\n")
    path
  end

  # Returns { "url", "title", "overview", "specs" => [{label,value}], "via", "credits" }
  def fetch_page(url, cfg:, fetcher: nil, source_id: "enrich", force: false)
    return { "error" => "amazon.com never fetched", "url" => url } if amazon_url?(url)
    unless force
      cached = read_cache(url)
      return cached if cached && cached["overview"].to_s.length > 40
    end

    fetcher ||= Fetcher.new(cfg, root: DealTools::ROOT)
    # Prefer plain; ZenRows only when source asks (caller sets fetch mode via fake source)
    src = { "id" => source_id, "fetch" => "plain", "fallback" => "none" }
    r = fetcher.fetch(url, src, ok_if: ->(b) { b.to_s.length > 2000 })
    # Rate limits / blips: back off and retry PLAIN only. Never escalate to ZenRows
    # for HTTP 429 — that is rate limiting, not "page unreadable without JS".
    if !r.ok && r.error.to_s =~ /429|503|timeout|timed out/i
      sleep 15
      r = fetcher.fetch(url, src, ok_if: ->(b) { b.to_s.length > 2000 })
      if !r.ok && r.error.to_s =~ /429/i
        sleep 30
        r = fetcher.fetch(url, src, ok_if: ->(b) { b.to_s.length > 2000 })
      end
    end
    unless r.ok
      return { "error" => r.error.to_s, "url" => url, "via" => r.via, "credits" => r.credits.to_i }
    end
    extracted = extract_html(r.body, url)
    data = extracted.merge("via" => r.via, "credits" => r.credits.to_i)
    write_cache(url, data) if extracted["overview"].to_s.length > 40 || extracted["specs"].to_a.any?
    data
  end

  def extract_html(html, url)
    doc = Nokogiri::HTML(html)
    host = (DealTools.bare_host(URI(url)) rescue "")
    title = doc.at_css("h1")&.text.to_s.gsub(/\s+/, " ").strip
    title = doc.at_css("meta[property='og:title']")&.[]("content").to_s if title.empty?

    overview = ""
    specs = []

    case host
    when /bhphotovideo/
      overview = [
        doc.at_css("#overview-content, #TabOverview, [data-selenium='overviewDescription'], .js-overview")&.text,
        doc.css("#overview-content p, .overview-text p, [data-selenium='sellingPoints'] li").map(&:text).join(" "),
        doc.at_css("meta[name='description']")&.[]("content"),
        doc.at_css("meta[property='og:description']")&.[]("content")
      ].compact.map { |t| t.to_s.gsub(/\s+/, " ").strip }.reject(&:empty?).max_by(&:length).to_s
      doc.css("table tr, [data-selenium='specsPair'], .spec-item").each do |tr|
        cells = tr.css("th, td, .spec-name, .spec-value, span").map { |c| c.text.gsub(/\s+/, " ").strip }.reject(&:empty?)
        next if cells.size < 2
        label = cells[0]
        vals = cells[1..]
        value = vals.uniq.size == 1 ? vals[0] : vals.join(" ")
        value = value.sub(/\A(.+?)\s+\1\z/m, '\1') while value =~ /\A(.+?)\s+\1\z/m
        next if label.length > 40 || value.length > 80 || label =~ /sku|upc|mfr|item #/i
        specs << { "label" => label.sub(/:\z/, ""), "value" => value } unless specs.any? { |s| s["label"] == label }
        break if specs.size >= 8
      end
    when /newegg/
      overview = doc.at_css("#product-overview, .product-bullets, [class*='product-description']")&.text.to_s.gsub(/\s+/, " ").strip
      overview = doc.at_css("meta[name='description']")&.[]("content").to_s if overview.length < 40
      doc.css("#product-details table tr, .table-horizontal tr").each do |tr|
        cells = tr.css("th,td").map { |c| c.text.gsub(/\s+/, " ").strip }
        next unless cells.size >= 2
        specs << { "label" => cells[0].sub(/:\z/, ""), "value" => cells[1] }
        break if specs.size >= 8
      end
    when /target/
      overview = doc.at_css("[data-test='item-details-description'], [data-test='product-description']")&.text.to_s.gsub(/\s+/, " ").strip
      overview = doc.at_css("meta[name='description']")&.[]("content").to_s if overview.length < 40
      doc.css("[data-test='item-details-specifications'] li, table tr").each do |el|
        t = el.text.gsub(/\s+/, " ").strip
        if t.include?(":")
          label, value = t.split(":", 2)
          specs << { "label" => label.strip, "value" => value.strip } if value && !value.empty?
        end
        break if specs.size >= 8
      end
    when /woot/
      overview = [
        doc.at_css("#Features, .description, .offer-description, #story, #tab-description")&.text,
        doc.css("main p, article p, .padded-box p").first(6).map(&:text).join(" "),
        doc.at_css("meta[property='og:description']")&.[]("content"),
        doc.at_css("meta[name='description']")&.[]("content")
      ].compact.map { |t| t.to_s.gsub(/\s+/, " ").strip }.reject(&:empty?).max_by(&:length).to_s
      doc.css("#Features li, .specs li, table tr").first(12).each do |el|
        t = el.text.gsub(/\s+/, " ").strip
        next if t.length < 4
        if t.include?(":")
          a, b = t.split(":", 2)
          specs << { "label" => a.strip[0, 40], "value" => b.strip[0, 80] }
        end
      end
    when /macheist|stacksocial|stackcommerce/
      overview = doc.at_css("[data-testid='description'], .product-description, article")&.text.to_s.gsub(/\s+/, " ").strip[0, 1200]
      overview = doc.at_css("meta[name='description']")&.[]("content").to_s if overview.length < 40
    else
      # Manufacturer / generic
      overview = [
        doc.at_css("meta[name='description']")&.[]("content"),
        doc.at_css("meta[property='og:description']")&.[]("content"),
        doc.css("main p, article p, .product-description p, #overview p").first(4).map(&:text).join(" ")
      ].compact.map { |t| t.to_s.gsub(/\s+/, " ").strip }.reject(&:empty?).first(2).join(" ")
      doc.css("table tr, dl dt").first(20).each do |el|
        if el.name == "dt"
          dd = el.next_element
          next unless dd && dd.name == "dd"
          specs << { "label" => el.text.gsub(/\s+/, " ").strip[0, 40], "value" => dd.text.gsub(/\s+/, " ").strip[0, 80] }
        else
          cells = el.css("th,td").map { |c| c.text.gsub(/\s+/, " ").strip }
          next unless cells.size >= 2 && cells[0].length < 40
          specs << { "label" => cells[0].sub(/:\z/, ""), "value" => cells[1][0, 80] }
        end
        break if specs.size >= 8
      end
    end

    overview = overview.to_s.gsub(/\s+/, " ").strip[0, 1500]
    # Prefer useful specs
    specs = specs.select { |s| s["label"].to_s.length.between?(2, 40) && s["value"].to_s.length.between?(1, 100) }
                 .first(6)
    { "title" => title, "overview" => overview, "specs" => specs }
  end

  # Best non-Amazon URL to fetch for a product (store page, or manufacturer for Amazon deals).
  def enrichment_url(fm)
    store_url = fm["affiliate_url"].to_s
    brand = fm["brand"].to_s.downcase
    title = fm["title"].to_s.downcase

    # Lighting brand pages beat blocked retailers (Walmart) when we know the brand.
    return "https://www.philips-hue.com/en-us" if brand =~ /philips|hue/ || title =~ /philips hue/
    return "https://us.govee.com/" if brand =~ /govee/ || title =~ /\bgovee\b/
    return "https://www.gelighting.com/smart-home" if brand =~ /\bge\b|cync/ || title =~ /\bcync\b|ge cync/
    return "https://www.lifx.com/" if brand =~ /lifx/ || title =~ /\blifx\b/
    return "https://www.linkind.com/" if brand =~ /linkind/ || title =~ /\blinkind\b/
    return "https://www.orein.com/" if brand =~ /orein/ || title =~ /\borein\b/

    return store_url unless amazon_url?(store_url) || fm["store"].to_s =~ /amazon/i
    # Amazon-owned brands: official non-amazon.com sites
    return "https://ring.com/" if title =~ /\bring\b/ || brand == "ring"
    return "https://blinkforhome.com/" if title =~ /\bblink\b/ || brand == "blink"
    return "https://eero.com/" if title =~ /\beero\b/ || brand == "eero"
    # Apple / Samsung / Sony / Bose / Anker / Google — try a search-free known pattern from model tokens
    if brand =~ /apple/ || title =~ /\b(macbook|iphone|ipad|airpods|apple watch)\b/
      return apple_guess(fm["title"])
    end
    if brand =~ /samsung/ || title =~ /samsung|galaxy|odyssey/
      return nil # samsung.com product URLs are hard without search; skip rather than invent
    end
    if brand =~ /sony/ || title =~ /\bsony\b|wh-1000|inzone/
      return nil
    end
    # Amazon Echo / Kindle / Fire: no reliable non-amazon product page; return nil (title-only honest short)
    nil
  end

  def apple_guess(title)
    t = title.to_s.downcase
    return "https://www.apple.com/macbook-air/" if t =~ /macbook air/
    return "https://www.apple.com/macbook-pro/" if t =~ /macbook pro/
    return "https://www.apple.com/mac-mini/" if t =~ /mac mini/
    return "https://www.apple.com/airpods-pro/" if t =~ /airpods pro/
    return "https://www.apple.com/airpods-max/" if t =~ /airpods max/
    return "https://www.apple.com/airpods/" if t =~ /airpods/
    return "https://www.apple.com/apple-watch-se/" if t =~ /watch se/
    return "https://www.apple.com/apple-watch-ultra/" if t =~ /watch ultra/
    return "https://www.apple.com/ipad/" if t =~ /\bipad\b/
    nil
  end
end
