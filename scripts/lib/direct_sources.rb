# frozen_string_literal: true

require "json"
require "cgi"
require "net/http"
require "uri"
require "nokogiri"
require_relative "deal_tools"

# Readers for stores and feeds checked directly (see "sites:" in
# _data/deal_sources.yml). Each returns an Array of item hashes in the shape
# scripts/find_deals.rb expects:
#   title, link (page the item came from), store_url (real product page, or nil
#   with unresolved_reason), price, compare_at, image, brand, expires,
#   feed_category, highlights, from_site: true (price already read from the store)
module DirectSources
  module_function

  def log(msg) = puts("   #{msg}")

  def abs(base, href)
    return nil if href.to_s.strip.empty?
    URI.join(base, href.strip).to_s
  rescue URI::Error
    nil
  end

  def base_item(source, **h)
    # link is used for de-duplication, so it is the product page; the listing
    # page the item was read from is kept as :page.
    h = h.merge(page: h[:link], link: h[:store_url]) if h[:store_url]
    { source: source["id"], published: nil, html: "", text: "", from_site: true, expires: nil,
      store_hint: source["store"], guid: h[:store_url] || h[:link] }.merge(h)
  end

  # Fetch every listing URL of a source through the Fetcher; yields (url, body).
  def each_page(fetcher, source, ok_if:)
    Array(source["urls"]).each do |url|
      r = fetcher.fetch(url, source, ok_if: ok_if)
      unless r.ok
        log "#{url}: #{r.error}"
        next
      end
      log "#{url}: ok via #{r.via}#{r.credits.to_i.positive? ? " (#{r.credits} ZenRows credits)" : ''}"
      yield url, r.body
    end
  end

  # -------------------------------------------------------------- B&H ---
  # B&H deal and used-department listing pages are server-rendered and carry
  # the listing as JSON ("items":[{"itemKey":...}]) with price, strikethrough
  # price, stock and (for used gear) the condition grade.
  def bh_json_items(html)
    t = CGI.unescapeHTML(html).b
    out = []
    pos = 0
    while (i = t.index('"items":[{"itemKey"', pos))
      start = i + 8
      depth = 0
      j = start
      instr = false
      esc = false
      while j < t.bytesize
        c = t.getbyte(j)
        if instr
          if esc then esc = false
          elsif c == 92 then esc = true
          elsif c == 34 then instr = false
          end
        else
          case c
          when 34 then instr = true
          when 91, 123 then depth += 1
          when 93, 125
            depth -= 1
            break if depth.zero?
          end
        end
        j += 1
      end
      begin
        out.concat(JSON.parse(t[start..j].force_encoding("UTF-8")))
      rescue JSON::ParserError
        nil
      end
      pos = j
    end
    out
  end

  def bh_items(fetcher, source)
    items = {}
    each_page(fetcher, source, ok_if: ->(b) { b.include?("itemKey") }) do |url, body|
      bh_json_items(body).each do |it|
        pi = it["priceInfo"] || {}
        core = it["core"] || {}
        next unless pi["showPrice"] && pi["price"].to_f.positive?
        # statusMessage "Temporarily Out of Stock" is template text on every tile (the
        # product pages say In Stock), so only status and the cart button count.
        next if it.dig("stockInfo", "status").to_s != "IN_STOCK" || pi["addToCartButton"].to_s != "ADD_TO_CART" ||
                it.dig("stockInfo", "statusMessage").to_s =~ /coming soon|pre-?order|discontinued|no longer/i
        link = abs("https://www.bhphotovideo.com", core["detailsUrl"]) or next
        used = it.dig("conditionFlags", "isUsed") || it.dig("conditionFlags", "isOpenBox")
        grade = it.dig("usedInfo", "conditionCode")
        desc = it.dig("usedInfo", "conditionDescription")
        strike = pi["strikethroughPrice"].to_f
        hl = []
        hl << "Used at B&H, condition #{grade}#{desc ? " (#{desc})" : ''}; the original price shown is B&H's new price" if used && grade
        items[link] ||= base_item(source,
                                  title: core["shortDescription"].to_s.strip, link: url, store_url: link,
                                  price: pi["price"].to_f.round(2), compare_at: strike > pi["price"].to_f ? strike.round(2) : nil,
                                  image: it.dig("mainImage", "detail", "url") || it.dig("mainImage", "default", "url"),
                                  highlights: hl, condition: used ? "used" : nil)
      end
    end
    items.values
  end

  # ----------------------------------------------------------- Newegg ---
  # Newegg sale/outlet pages: server-rendered product tiles (.goods-container).
  def newegg_items(fetcher, source)
    items = {}
    each_page(fetcher, source, ok_if: ->(b) { b.include?("goods-container") }) do |url, body|
      Nokogiri::HTML(body).css(".goods-container").each do |el|
        a = el.at_css("a.goods-title") || el.at_css("a.goods-img") or next
        href = a["href"].to_s
        next unless href.include?("/p/")
        img = el.at_css("a.goods-img img")
        title = img&.[]("title").to_s.strip
        title = a.text.strip if title.empty?
        title = title.sub(/\A[A-Z0-9#\-]{5,}\s*;\s*/, "")
        cur = el.at_css(".goods-price-current .goods-price-value")&.text.to_s.gsub(/[^\d.]/, "")
        price = cur.empty? ? nil : cur.to_f.round(2)
        was = DealTools.money(el.at_css(".goods-price-was")&.text)
        next unless price&.positive?
        next if el.text =~ /out of stock|sold out|auto notify/i
        store_url = DealTools.clean_store_url(href.sub(/#.*\z/, ""))
        promo = el.at_css(".goods-promo")&.text.to_s.strip
        hl = []
        hl << "Open-box or refurbished: check the condition at Newegg" if title =~ /open box|refurb|renewed/i || href =~ /\d+R\b|-R\b/
        hl << promo[0, 90] unless promo.empty?
        items[store_url] ||= base_item(source, title: title, link: url, store_url: store_url, price: price,
                                               compare_at: was && was > price ? was : nil, image: img&.[]("src"),
                                               brand: el.at_css(".goods-brand img")&.[]("title"), highlights: hl)
      end
    end
    items.values
  end

  # Newegg's official RSS (daily deals). Returned 0 items when tested in Oct
  # 2026, but it's the sanctioned feed, so it stays on.
  def newegg_rss_items(fetcher, source)
    r = fetcher.fetch(source["url"], source)
    return (log("#{source['url']}: #{r.error}") || []) unless r.ok
    doc = Nokogiri::XML(r.body).remove_namespaces!
    doc.xpath("//item").filter_map do |it|
      link = it.at_xpath("link")&.text.to_s.strip
      next if link.empty?
      title = CGI.unescapeHTML(it.at_xpath("title")&.text.to_s.strip)
      desc = it.at_xpath("description")&.text.to_s
      price = DealTools.first_price(Nokogiri::HTML.fragment(desc).text) || DealTools.first_price(title)
      img = Nokogiri::HTML.fragment(desc).at_css("img")&.[]("src")
      base_item(source, title: title, link: link, store_url: DealTools.clean_store_url(link), price: price, image: img, text: Nokogiri::HTML.fragment(desc).text[0, 300])
    end
  end

  # --------------------------------------------------------- MacHeist ---
  # MacHeist (a StackCommerce store) collection pages list /sales/ links. Only
  # sale slugs that look like hardware (category keywords, no excluded words)
  # are opened; each sale page gives the deal price, the retail price and
  # whether it is sold out.
  def macheist_items(fetcher, source, category_re:, exclude_re:)
    slugs = []
    each_page(fetcher, source, ok_if: ->(b) { b.include?("/sales/") }) do |_url, body|
      slugs.concat(body.scan(%r{href="/sales/([a-z0-9\-]+)"}).flatten)
    end
    slugs = slugs.uniq.select { |s| t = s.tr("-", " "); category_re.match?(t) && !(exclude_re && exclude_re.match?(t)) }
    skip_re = source["title_exclude"] ? Regexp.new(source["title_exclude"], Regexp::IGNORECASE) : nil
    slugs = slugs.reject { |s| skip_re&.match?(s.tr("-", " ")) }
    slugs.first((source["max_offers"] || 20).to_i).filter_map do |slug|
      url = "https://www.macheist.com/sales/#{slug}"
      r = fetcher.fetch(url, source, ok_if: ->(b) { b.include?("salePrice") })
      next log("#{url}: #{r.error}") unless r.ok
      html = r.body
      doc = Nokogiri::HTML(html)
      price = DealTools.money(doc.at_css('[data-testid="salePrice"]')&.text)
      next unless price&.positive?
      flat = html.gsub('\\"', '"')
      m = flat.match(/"priceInCents":(\d+),"retailPriceInCents":(\d+)(?:,"calculatedDiscount":\d+)?,"miniBundle":[^,]*,"soldOut":(true|false),"group":[^,]*,"slug":"#{Regexp.escape(slug)}"/)
      next if m && m[3] == "true"
      retail = m ? (m[2].to_i / 100.0).round(2) : nil
      expires = (Date.parse(flat[/"expiresAt":"([^"]+)"/, 1]) rescue nil)
      base_item(source, title: doc.at_css("h1")&.text.to_s.strip, link: url, store_url: url, price: price,
                        compare_at: retail && retail > price ? retail : nil,
                        image: doc.at_css('meta[property="og:image"]')&.[]("content"), expires: expires,
                        feed_category: flat[/"category":\{"__typename":"Category","databaseId":\d+,"name":"([^"]+)"/, 1])
    end
  end

  # ------------------------------------------------------- Slickdeals ---
  # Slickdeals' official RSS, used as LEADS. Store links in the feed go through
  # slickdeals.net/click (robots.txt disallows it, so it is never requested) and
  # the destination is encrypted. A lead is resolved only when the feed itself
  # names the product: Amazon items carry the ASIN (data-aps-asin), which gives
  # the plain amazon.com/dp/ link (our Associates tag is added on publish).
  # Other leads are queued without a store link for a human to paste one.
  def slickdeals_items(fetcher, source)
    r = fetcher.fetch(source["url"], source)
    return (log("#{source['url']}: #{r.error}") || []) unless r.ok
    doc = Nokogiri::XML(r.body).remove_namespaces!
    doc.xpath("//item").map do |it|
      title = CGI.unescapeHTML(it.at_xpath("title")&.text.to_s.strip)
      thread = it.at_xpath("link")&.text.to_s.sub(/\?.*\z/, "")
      html = it.at_xpath("encoded")&.text.to_s
      frag = Nokogiri::HTML.fragment(html)
      a = frag.at_css('a[data-cta="outclick"]')
      exit_site = a&.[]("data-product-exitwebsite").to_s
      asin = a&.[]("data-aps-asin").to_s
      store_url, why =
        if exit_site =~ /\Aamazon\.com\z/i && asin =~ /\A[A-Z0-9]{10}\z/
          ["https://www.amazon.com/dp/#{asin}", nil]
        else
          [nil, "Slickdeals lead: store link not in the feed (#{exit_site.empty? ? 'unknown store' : exit_site})"]
        end
      desc = Nokogiri::HTML.fragment(it.at_xpath("description")&.text.to_s).text
      {
        source: source["id"], title: title, link: thread, guid: thread, published: (Time.parse(it.at_xpath("pubDate")&.text.to_s) rescue nil),
        html: "", text: desc[0, 400], image: DealTools.bigger_image(frag.at_css("img")&.[]("src")),
        store_hint: exit_site.empty? ? nil : DealTools.store_name("https://#{exit_site}"),
        price: DealTools.money(desc[/for \*?\$([\d,]+(?:\.\d{2})?)/, 1]) || DealTools.first_price(title),
        store_url: store_url, unresolved_reason: why, expires: nil, feed_category: nil
      }
    end
  end

  # ----------------------------------------------------------- Target ---
  # Target deal listing pages build their product grid with JavaScript, so
  # these go through ZenRows js_render (5 credits a page). Only cards with a
  # single current price AND Target's own "reg" price are kept; sponsored
  # cards are skipped.
  def target_items(fetcher, source)
    items = {}
    each_page(fetcher, source, ok_if: ->(b) { b.include?("@web/ProductCard/title") || b.include?("strikethroughFormattedRegPrice") }) do |url, body|
      doc = Nokogiri::HTML(body)
      # Product images sit in a sibling link of the card, keyed by Target's item id (A-12345678).
      images = {}
      doc.css('a[href*="/A-"]').each do |link|
        id = link["href"][%r{/A-(\d+)}, 1] or next
        src = link.css("img").map { |i| i["src"].to_s }.find { |x| x.include?("scene7.com/is/image/Target/GUEST") }
        images[id] ||= src if src
      end
      doc.css('[data-test="@web/site-top-of-funnel/ProductCardWrapper"], [data-test="productCardVariantMini"]').each do |card|
        next if card.at_css('[data-test="sponsoredText"], [data-test="sponsored-text"]')
        a = card.at_css('a[data-test="@web/ProductCard/title"]') || card.at_css('[data-test="productCardVariantMiniTitle"] a') or next
        href = a["href"].to_s
        next unless href.start_with?("/p/")
        title = (a["aria-label"] || a.text).to_s.strip
        price_txt = card.at_css('[data-test="current-price"]')&.text || card.at_css('[data-test="@web/Price/PriceAndPromoMinimal"] span')&.text
        next if price_txt.to_s.include?("-") # price range (variants)
        price = DealTools.money(price_txt)
        reg = DealTools.money(card.at_css('[data-test="strikethroughFormattedRegPrice"]')&.text)
        next unless price&.positive? && reg && reg > price
        store_url = "https://www.target.com#{href.sub(/[?#].*\z/, '')}"
        img = card.css("img").map { |i| i["src"].to_s }.find { |x| x.include?("scene7.com/is/image/Target/GUEST") } ||
              images[href[%r{/A-(\d+)}, 1]] || images[href[/preselect=(\d+)/, 1]]
        img = img&.sub(/\?.*\z/, "?wid=600&hei=600&qlt=80&fmt=pjpeg")
        msg = card.at_css('[data-test="strikethroughPriceMessage"]')&.text.to_s.strip
        items[store_url] ||= base_item(source, title: title, link: url, store_url: store_url, price: price, compare_at: reg,
                                               image: img, brand: card.at_css('[data-test="@web/ProductCard/ProductCardBrandAndRibbonMessage/brand"]')&.text,
                                               highlights: msg =~ /clearance/i ? ["Target clearance price"] : [])
      end
    end
    items.values
  end

  # ------------------------------------------------- Official APIs ---
  # Best Buy Products API (https://developer.bestbuy.com). Needs BESTBUY_API_KEY;
  # without it the source is skipped. Reads onSale=true products in the tech
  # categories listed under the source's category_ids.
  def bestbuy_api_items(_fetcher, source)
    key = ENV[Array(source["env"]).first.to_s].to_s.strip
    cats = Array(source["category_ids"])
    return [] if key.empty? || cats.empty?
    filter = "(#{cats.map { |c| "categoryPath.id=#{c}" }.join('|')})&onSale=true&onlineAvailability=true"
    show = %w[sku name salePrice regularPrice percentSavings url image largeFrontImage manufacturer categoryPath.name priceUpdateDate].join(",")
    items = []
    (1..(source["max_pages"] || 2).to_i).each do |page|
      q = URI.encode_www_form("apiKey" => key, "format" => "json", "show" => show, "pageSize" => (source["page_size"] || 100).to_i,
                              "page" => page, "sort" => "percentSavings.dsc")
      begin
        u = URI("https://api.bestbuy.com/v1/products(#{filter.gsub('|', '%7C')})?#{q}")
        http = Net::HTTP.new(u.host, u.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30
        res = http.request(Net::HTTP::Get.new(u.request_uri, "Accept" => "application/json"))
      rescue StandardError => e
        log "Best Buy API error: #{e.class}".gsub(key, "[redacted]")
        break
      end
      unless res.code.to_i == 200
        log "Best Buy API HTTP #{res.code}"
        break
      end
      data = JSON.parse(res.body) rescue {}
      Array(data["products"]).each do |p|
        price = p["salePrice"].to_f
        reg = p["regularPrice"].to_f
        next unless price.positive? && reg > price
        url = DealTools.clean_store_url(p["url"].to_s)
        next if url.to_s.empty?
        cat = Array(p["categoryPath"]).map { |c| c["name"] }.last
        items << base_item(source, title: p["name"].to_s, link: url, store_url: url, price: price.round(2),
                                   compare_at: reg.round(2), image: p["largeFrontImage"] || p["image"],
                                   brand: p["manufacturer"], feed_category: cat)
      end
      break if data["currentPage"].to_i >= data["totalPages"].to_i
      sleep 0.3
    end
    items
  end

  # Adapters for official sources that need a partner account / key first.
  # Listed in deal_sources.yml with enabled: false; flip them on once the
  # adapter is written and the key is in the environment.
  PLANNED = %w[walmart_affiliate impact_catalog woot_api amazon_paapi].freeze

  PARSERS = {
    "bh" => :bh_items, "newegg" => :newegg_items, "newegg_rss" => :newegg_rss_items,
    "macheist" => :macheist_items, "slickdeals_rss" => :slickdeals_items, "target" => :target_items,
    "bestbuy_api" => :bestbuy_api_items
  }.freeze
end
