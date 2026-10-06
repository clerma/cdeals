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
    DealTools.source_urls(source).each do |url|
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

  # ----------------------------------------------------- Brad's Deals ---
  # bradsdeals.com pages are Nuxt: the deals sit in the inline window.__NUXT__
  # payload, a minified JS object literal (not JSON). Each product deal is a
  # record:{content_type:"product_listing", headline, images, tracking_link:
  # {untracked_url, tracked_url}, availability, unit_discount_price,
  # unit_regular_price, ...}. Values shared across the payload are written as
  # bare identifiers (a, b, eu...): those are read as nil (unknown), never
  # guessed. Deal posts (record:{url:"/deals/<slug>-<uid>", headline,
  # description, listings:[{uid, type}]}) carry the write-up and link their
  # product records by uid.
  # The listing prices are often shared references or stale (Beats Solo 4:
  # listing $129.95, write-up "drop from $199.99 to $99.99"), so each listing
  # that passes the cheap filters (in stock, store product URL, category
  # keyword in title, not excluded, not already known) gets its post's detail
  # page (/deals/<slug>-<uid>, max_detail_pages per run) and the price comes
  # from the write-up there (bd_writeup_price). No clear write-up price: the
  # listing price is used only when the detail page's JSON-LD offer confirms
  # it; otherwise the item is skipped.
  # Only listing and /deals/ detail pages are requested; never /go/ links
  # (robots.txt disallows /api/, /go/*, /c/*, /p/*, /search?query*). A
  # challenge page, 403 or 429 stops the source (or its detail pages) for
  # this run (no retries, no ZenRows).

  # Read one JS literal value at byte offset i of s (binary). Returns [value, next i].
  # Identifiers, `void 0`, `new Set([...])` and calls come back as nil.
  def js_value(s, i)
    i = js_ws(s, i)
    c = s.getbyte(i)
    case c
    when 123 # {
      h = {}
      i = js_ws(s, i + 1)
      while i < s.bytesize && s.getbyte(i) != 125
        if [34, 39].include?(s.getbyte(i))
          key, i = js_string(s, i)
        else
          j = i
          j += 1 while j < s.bytesize && s.getbyte(j) != 58 && s.getbyte(j) > 32
          key = s.byteslice(i, j - i).force_encoding("UTF-8")
          i = j
        end
        i = js_ws(s, i)
        return [h, s.bytesize] unless s.getbyte(i) == 58
        h[key], i = js_value(s, i + 1)
        i = js_ws(s, i)
        break unless s.getbyte(i) == 44
        i = js_ws(s, i + 1)
      end
      [h, i + 1]
    when 91 # [
      a = []
      i = js_ws(s, i + 1)
      while i < s.bytesize && s.getbyte(i) != 93
        v, i = js_value(s, i)
        a << v
        i = js_ws(s, i)
        break unless s.getbyte(i) == 44
        i = js_ws(s, i + 1)
      end
      [a, i + 1]
    when 34, 39 then js_string(s, i)
    when 33 then [nil, i + 2] # !0 / !1
    else
      tok = s.byteslice(i, 64)[/\A-?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?/i]
      return [tok.include?(".") || tok =~ /e/i ? tok.to_f : tok.to_i, i + tok.bytesize] if tok
      tok = s.byteslice(i, 64)[/\A[A-Za-z_$][\w$.]*/].to_s
      i += tok.bytesize
      case tok
      when "true" then [true, i]
      when "false" then [false, i]
      when "void" then [nil, js_value(s, i).last]
      when "new" then [nil, js_value(s, i).last]
      else
        i2 = js_ws(s, i)
        return [nil, i] unless s.getbyte(i2) == 40
        depth = 0 # call: skip the (...) arguments
        while i2 < s.bytesize
          b = s.getbyte(i2)
          if [34, 39].include?(b) then i2 = js_string(s, i2).last
            next
          end
          depth += 1 if b == 40
          depth -= 1 if b == 41
          i2 += 1
          break if depth.zero?
        end
        [nil, i2]
      end
    end
  end

  def js_ws(s, i)
    i += 1 while i < s.bytesize && s.getbyte(i) <= 32
    i
  end

  # JS string literal at i (quote byte); decodes \uXXXX (incl. surrogate pairs) and \x, \n, etc.
  def js_string(s, i)
    q = s.getbyte(i)
    out = +"".b
    i += 1
    while i < s.bytesize
      b = s.getbyte(i)
      if b == q
        str = out.force_encoding("UTF-8")
        return [str.valid_encoding? ? str : str.scrub, i + 1]
      elsif b == 92
        e = s.getbyte(i + 1).chr
        case e
        when "u"
          cp = s.byteslice(i + 2, 4).to_i(16)
          i += 6
          if cp.between?(0xD800, 0xDBFF) && s.byteslice(i, 2) == "\\u"
            lo = s.byteslice(i + 2, 4).to_i(16)
            if lo.between?(0xDC00, 0xDFFF)
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              i += 6
            end
          end
          out << [cp].pack("U").b
          next
        when "x"
          out << [s.byteslice(i + 2, 2).to_i(16)].pack("U").b
          i += 4
          next
        when "n" then out << "\n"
        when "t" then out << "\t"
        when "r" then out << "\r"
        else out << e
        end
        i += 2
      else
        out << b
        i += 1
      end
    end
    [out.force_encoding("UTF-8").scrub, i]
  end

  # Every record:{...} object in the page's __NUXT__ payload.
  def nuxt_records(html)
    s = html.to_s.b
    start = s.index("window.__NUXT__") or return []
    stop = s.index("</script>", start) || s.bytesize
    s = s.byteslice(start, stop - start)
    out = []
    pos = 0
    while (k = s.index("record:{", pos))
      v = begin
        js_value(s, k + 7).first
      rescue StandardError
        nil
      end
      out << v if v.is_a?(Hash)
      pos = k + 8
    end
    out
  end

  # Prime event wording. Not "Prime shipping" / "free with Prime" / "Prime
  # members get free shipping": only a Prime-event or Prime-members price.
  BD_PRIME_RE = /\bprime[\s-]*(?:days?|big[\s-]*deals?[\s-]*days?|events?|week|exclusives?)\b|\bfor\s+prime\s+members\b|\bprime[\s-]*members?\s+(?:only|exclusive|price|deal|can\s+get\s+this)\b/i

  def bd_text(v)
    case v
    when String then v
    when Hash then v["text"].is_a?(String) ? v["text"] : bd_text(v["children"]) # rich text: text nodes only
    when Array then v.map { |x| bd_text(x) }.join
    else ""
    end
  end

  def bd_num(v) = v.is_a?(Numeric) && v.positive? ? v.to_f.round(2) : nil

  # Store product URL of a record: untracked_url, else tracked_url with the
  # destination pulled out of the tracker and affiliate params removed.
  def bd_store_url(rec)
    tl = rec["tracking_link"].is_a?(Hash) ? rec["tracking_link"] : {}
    raw = [tl["untracked_url"], tl["tracked_url"]].find { |u| u.is_a?(String) && u.start_with?("http") } or return nil
    raw = DealTools.embedded_destination(raw) || raw if DealTools.tracker?(raw)
    u = DealTools.parse_uri(raw) or return nil
    host = DealTools.bare_host(u)
    return nil if host.end_with?("bradsdeals.com") || DealTools.tracker?(raw)
    if DealTools::AMAZON_HOST.match?(u.host.to_s) || host =~ /\Aamzn\./
      return nil unless DealTools.asin(raw) # product pages only (/dp/ or /gp/product/)
    elsif u.path.to_s.chomp("/").empty?
      return nil # store home page, not a product
    end
    DealTools.clean_store_url(raw)
  end

  # Detail page path of a deal post: /deals/<slug>-<uid>. Nothing else on
  # bradsdeals.com is requested from a post (never /go/, /c/, /p/, /api/, /search).
  BD_DETAIL_PATH = %r{\A/deals/[a-z0-9][a-z0-9-]*-blt[0-9a-f]+\z}

  # Write-up price rules: [rule, regex, group of the deal price, group of the
  # original price (nil: none stated)]. Every amount is a BD_M group.
  BD_M = '\$\s?((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)'
  BD_JUST = '(?:just\s+|only\s+|a\s+mere\s+)?'
  BD_USUAL = '(?:normally|usually|typically|regularly|originally)'
  BD_PRICE_RULES = [
    ["from $X to $Y", /\bfrom\s+(?:its\s+|the\s+|an?\s+)?(?:usual\s+|regular\s+|list\s+)?#{BD_M}\s+(?:all\s+the\s+way\s+)?(?:down\s+)?to\s+#{BD_JUST}#{BD_M}/i, 2, 1],
    ["was $X, now $Y", /\bwas\s+#{BD_M}\s*[,;]?\s*(?:and\s+|but\s+)?(?:is\s+|it's\s+)?now\s+#{BD_JUST}#{BD_M}/i, 2, 1],
    ["$Y, down from $X", /#{BD_M}\s*[,(]?\s*(?:which\s+is\s+|that's\s+)?down\s+from\s+(?:its\s+|the\s+|an?\s+)?(?:usual\s+|regular\s+|list\s+)?#{BD_M}/i, 1, 2],
    ["$Y (reg. $X)", /#{BD_M}\s*[(,]\s*(?:reg\.?|regularly|originally|orig\.?|list(?:\s+price)?|retail|was|normally|usually|typically)\s*:?\s*#{BD_M}/i, 1, 2],
    ["$Y, a savings of $Z off $X", /#{BD_M}\s*,?\s*(?:which\s+is\s+|that's\s+)?(?:an?\s+)?(?:savings?|discount)\s+of\s+#{BD_M}\s+off\s+(?:the\s+|its\s+)?(?:(?:list|regular|retail|original)\s+price\s+(?:of\s+)?)?#{BD_M}/i, 1, 3],
    ["for $Y, normally $X", /\bfor\s+#{BD_JUST}#{BD_M}(?!\d)(?!,\d)(?!\.\d)[^$;]{0,120}?\b#{BD_USUAL}\s+(?:sells?\s+for\s+|priced\s+at\s+|costs?\s+|goes\s+for\s+|listed\s+(?:at|for)\s+|retails?\s+for\s+|is\s+)?#{BD_M}/i, 1, 2],
    ["$Y ... down from $X", /#{BD_M}(?!\d)(?!,\d)(?!\.\d)[^$.!?]{0,60}?,\s*down\s+from\s+(?:its\s+|the\s+|an?\s+)?(?:usual\s+|regular\s+|list\s+)?#{BD_M}/i, 1, 2],
    ["usually $X ... drops to $Y", /\b#{BD_USUAL}\s+(?:listed\s+(?:at|for)\s+|priced\s+at\s+|sells?\s+for\s+|retails?\s+for\s+)?#{BD_M}(?!\d)(?!,\d)(?!\.\d)[^$!?;]{0,100}?\b(?:(?:drops?|falls?|dips?|is\s+(?:now\s+)?down|comes?\s+down)\s+to|for|is\s+now)\s+#{BD_JUST}#{BD_M}/i, 2, 1],
    ["drops to $Y", /\b(?:drops?|dropped|falls?|fell|dips?|is\s+down|comes?\s+down|slashed|cut|reduced|marked\s+down)\s+to\s+#{BD_JUST}#{BD_M}/i, 1, nil],
    ["on sale for $Y", /\b(?:on\s+sale\s+for|for\s+just|for\s+only|now\s+just|now\s+only|is\s+(?:now\s+)?(?:just|only))\s+#{BD_M}/i, 1, nil],
    ["get it for $Y", /\b(?:grab|get|pick\s+up|score|snag)\s[^$.!?]{0,100}?\bfor\s+#{BD_JUST}#{BD_M}/i, 1, nil]
  ].freeze
  # Wording that means more than one price (variants, ranges, per-unit, "from $X" alone).
  BD_VARIANT_RE = /\b(?:starting\s+at|starts?\s+at|as\s+low\s+as|prices?\s+(?:start|range|vary)|ranging\s+from|depending\s+on)\b|\bfrom\s+#{BD_M}|#{BD_M}\s*(?:each|apiece|per\s+\w+|\/\s*\w+|a\s+(?:month|year|week)|or\s+(?:less|under)|and\s+(?:up|under))\b|#{BD_M}\s*(?:-|–|to)\s*#{BD_M}|\bor\s+#{BD_M}/i
  # Words right after a deal price that make it not one item's price ("$10 or less", "$5 each", "$0 a month").
  BD_PRICE_QUALIFIER_RE = /\A(?:\+|\s*(?:or\s+(?:less|more|under|below)|and\s+(?:up|under)|each\b|apiece\b|per\s|a\s+(?:month|year|week)\b|\/\s*\w))/i
  # Sentences about other stores, past prices, shipping and add-on fees: their
  # amounts aren't this deal's price (history sentences don't give prices either).
  BD_HISTORY_RE = /\blast\s+(?:time|mention)|\bpreviously\b|\bused\s+to\b/i
  BD_ASIDE_RE = /\b(?:elsewhere|anywhere\s+else|other\s+(?:major\s+)?(?:stores|retailers|sellers|sites)|others\s+(?:charge|are)|most\s+(?:\w+\s+)?(?:charge|are\s+(?:charging|selling))|charges\s+(?:\$|around|about|over|at\s+least)|(?:are|is)\s+charging|we(?:'ve|\s+have)?\s+(?:never\s+|rarely\s+|only\s+|ever\s+)?(?:seen|see)|we(?:'re|\s+are)\s+seeing|we\s+couldn't|we\s+could\s+not|similar|comparable|you'd\s+spend|you\s+would\s+spend|would\s+run\s+you|reviewers|shipping|it\s+adds|otherwise|membership|activation|mounting|installation|set[\s-]?up\s+(?:is|costs?)|warranty|protection\s+plan)\b/i
  # Amounts that aren't a price for the item: thresholds, savings, store cash.
  BD_AMOUNT_IGNORE_BEFORE = /\b(?:earn|earning|every|spend|spending|over|above|under|below|less\s+than|than|around|about|roughly|nearly|almost|orders?(?:\s+of)?|minimum(?:\s+of)?|elsewhere\s+for|up\s+to|save|saving|savings\s+of|extra|by|plus|another|additional|threshold(?:\s+of)?|fee(?:\s+of)?|shipping(?:\s+is|\s+costs?|\s+of)?)\s*\z/i
  BD_AMOUNT_IGNORE_AFTER = /\A(?:\+|\s*(?:off|back|or\s+(?:more|less)|less|more|cheaper|in\s+savings|savings|worth|shipping|minimum|(?:in\s+)?(?:\w+['’]s\s+)?(?:cash|credit|rewards?|bonus|gift\s+cards?))\b)/i

  def bd_near(a, b, tol: 0.02, min: 0.01) = a && b && (a - b).abs <= [tol * b, min].max

  # Price-like $ amounts in t (thresholds, savings and store cash left out).
  def bd_loose_amounts(t)
    out = []
    t.scan(/#{BD_M}/) do
      m = Regexp.last_match
      next if t[[m.begin(0) - 40, 0].max...m.begin(0)] =~ BD_AMOUNT_IGNORE_BEFORE || t[m.end(0), 40].to_s =~ BD_AMOUNT_IGNORE_AFTER
      out << DealTools.money(m[1])
    end
    out
  end

  # Deal price from a Brad's Deals write-up (description; the headline only
  # when the description states none). Returns
  #   { price:, orig:, rule:, snippet:, sentence: }  one clear deal price; orig only when stated and higher
  #   { skip: reason, why: detail }                  several prices / variants / inconsistent: never guessed
  #   nil                                            no price stated
  def bd_writeup_price(text, headline: nil)
    r = bd_price_in(text)
    if r.nil? && headline
      r = bd_price_in(headline)
      r[:rule] = "headline: #{r[:rule]}" if r && !r[:skip]
    end
    return r if r.nil? || r[:skip]
    # The headline's own amounts ("... $199", "$110 (Reg. $350!)") must agree (rounding allowed).
    odd = bd_loose_amounts(CGI.unescapeHTML(headline.to_s)).reject { |a| bd_near(a, r[:price], min: 1.0) || bd_near(a, r[:orig], min: 1.0) }
    return { skip: "headline price differs from write-up", why: "$#{odd.first} vs $#{r[:price]}" } unless odd.empty?
    r
  end

  def bd_price_in(text)
    t = CGI.unescapeHTML(text.to_s).tr("\u00a0", " ").gsub(/\s+/, " ").strip
    sentences = []
    t.scan(/.+?(?:[.!?]+(?=\s|\z)|\z)/) { sentences << (Regexp.last_match.begin(0)...Regexp.last_match.end(0)) }
    sentence_of = ->(i) { t[sentences.find { |r| r.cover?(i) } || (i...i)] }
    found = []
    BD_PRICE_RULES.each do |rule, re, gp, go|
      t.scan(re) do
        m = Regexp.last_match
        next if sentence_of.call(m.begin(0)) =~ BD_HISTORY_RE # "the last time it dropped to $310"
        found << { rule: rule, price: DealTools.money(m[gp]), orig: go && DealTools.money(m[go]),
                   saved: rule.include?("savings") ? DealTools.money(m[2]) : nil, span: m.begin(0)...m.end(0), snippet: m[0],
                   after: t[m.end(gp), 16].to_s }
      end
    end
    kept = [] # overlapping matches: one stating the original price wins, then the longest
    found.sort_by { |f| [f[:orig] ? 0 : 1, -f[:snippet].size] }.each do |f|
      kept << f unless kept.any? { |k| k[:span].cover?(f[:span].begin) || f[:span].cover?(k[:span].begin) }
    end
    kept.sort_by! { |f| f[:span].begin }
    # What's left for the variant / other-price checks: matches masked out, and
    # history or aside sentences (other stores, shipping, fees) without a match blanked.
    rest = t.dup
    kept.each { |f| rest[f[:span]] = "#" * f[:snippet].size }
    sentences.each { |r| rest[r] = " " * r.size if !rest[r].include?("#") && (rest[r] =~ BD_ASIDE_RE || rest[r] =~ BD_HISTORY_RE) }
    variant = rest.match(BD_VARIANT_RE)
    if kept.empty?
      return { skip: "variant/range pricing in write-up", why: variant[0].strip } if variant
      amounts = bd_loose_amounts(rest).uniq
      return amounts.size > 1 ? { skip: "several prices in write-up, none clearly the deal price", why: amounts.map { |a| "$#{a}" }.join(" / ") } : nil
    end
    kept.each do |f|
      return { skip: "no clear price in write-up", why: f[:snippet] } unless f[:price].to_f.positive?
      return { skip: "variant/range pricing in write-up", why: "#{f[:snippet]}#{f[:after]}" } if f[:after] =~ BD_PRICE_QUALIFIER_RE
      return { skip: "price range in write-up", why: f[:snippet] } if f[:rule] == "from $X to $Y" && f[:orig] <= f[:price]
      return { skip: "write-up savings don't add up", why: f[:snippet] } if f[:saved] && !bd_near(f[:price] + f[:saved], f[:orig], tol: 0.01)
    end
    best = kept.find { |f| f[:orig] && f[:orig] > f[:price] } || kept.first
    price = best[:price]
    unless kept.all? { |f| bd_near(f[:price], price) }
      return { skip: "several prices in write-up", why: kept.map { |f| f[:snippet] }.join(" / ") }
    end
    origs = kept.filter_map { |f| f[:orig] if f[:orig] && f[:orig] > f[:price] }
    return { skip: "several original prices in write-up", why: origs.join(" / ") } unless origs.all? { |o| bd_near(o, origs.first) }
    orig = best[:orig] && best[:orig] > price ? best[:orig] : nil
    return { skip: "variant/range pricing in write-up", why: variant[0].strip } if variant
    extra = bd_loose_amounts(rest).reject { |a| bd_near(a, price) || bd_near(a, orig) }
    return { skip: "other prices in write-up", why: "$#{extra.first}" } unless extra.empty?
    { price: price, orig: orig, rule: best[:rule], snippet: best[:snippet], sentence: sentence_of.call(best[:span].begin).strip }
  end

  # JSON-LD offer prices on a detail page.
  def bd_jsonld_prices(html)
    Nokogiri::HTML(html.to_s).css('script[type="application/ld+json"]').flat_map do |s|
      data = begin
        JSON.parse(s.text)
      rescue JSON::ParserError
        nil
      end
      (data.is_a?(Array) ? data : [data]).flat_map { |d| d.is_a?(Hash) ? Array(d["offers"]) : [] }
    end.filter_map { |o| o.is_a?(Hash) && bd_num(o["price"].is_a?(String) ? o["price"].to_f : o["price"]) }
  end

  # A detail page: the deal post it is about (url or uid matches), the page's
  # product records by uid and the JSON-LD offer prices.
  def bd_detail(html, detail_url)
    path = DealTools.parse_uri(detail_url)&.path.to_s
    uid = path[/blt[0-9a-f]+\z/]
    recs = nuxt_records(html)
    post = recs.find { |r| r["listings"].is_a?(Array) && (r["url"] == path || (uid && r["uid"] == uid)) }
    products = recs.select { |r| r["content_type"] == "product_listing" && r["uid"].is_a?(String) }.to_h { |r| [r["uid"], r] }
    { post: post, products: products, offers: bd_jsonld_prices(html) }
  end

  def bradsdeals_items(fetcher, source, category_re: nil, exclude_re: nil, known: nil)
    ok_if = ->(b) { b.include?("window.__NUXT__") }
    leads = {}
    blocked = false
    DealTools.source_urls(source).each do |url|
      r = fetcher.fetch(url, source, ok_if: ok_if)
      unless r.ok
        # Challenge page / 403 / 429 (or anything else): back off for this run.
        log "#{url}: #{r.error}; stopping #{source['id']} for this run"
        blocked = true
        break
      end
      log "#{url}: ok via #{r.via}"
      bradsdeals_page(r.body, url, source).each { |it| leads[it[:store_url]] ||= it }
    end
    skipped = Hash.new(0)
    # Cheap filters first, so detail pages are only opened for likely candidates.
    leads = leads.values.select do |it|
      why =
        if exclude_re&.match?(it[:title]) then "excluded keyword"
        elsif source["require_title_category"] && category_re && !category_re.match?(it[:title]) then "no category keyword in title"
        elsif known&.call(it[:store_url]) then "already queued/published/rejected"
        elsif it[:bd_multi] then "post covers several products"
        elsif it[:bd_detail_url].nil? then "no detail page link in the data"
        end
      skipped[why] += 1 if why
      why.nil?
    end
    cap = ((DealTools.deep? && source["deep_max_detail_pages"]) || source["max_detail_pages"] || 40).to_i
    pages = {}
    items = {}
    via = Hash.new(0)
    leads.each do |it|
      durl = it[:bd_detail_url]
      unless pages.key?(durl)
        if blocked || pages.size >= cap
          skipped[blocked ? "detail pages stopped (blocked)" : "detail page cap (#{cap}) reached"] += 1
          next
        end
        r = fetcher.fetch(durl, source, ok_if: ok_if)
        pages[durl] = r.ok ? bd_detail(r.body, durl) : nil
        unless r.ok
          blocked = r.error.to_s =~ /bot wall|no usable content|\b403\b|\b429\b/
          log "#{durl}: #{r.error}#{blocked ? '; no more detail pages this run' : ''}"
        end
      end
      unless (d = pages[durl])
        skipped["detail page not read"] += 1
        next
      end
      item, why = bradsdeals_priced(it, d)
      if why
        skipped[why] += 1
        next
      end
      via[item[:price_conflict] ? :conflict : :ok] += 1
      via[item[:price_note].include?("write-up") ? :writeup : :jsonld] += 1
      items[item[:store_url]] ||= item
    end
    log "detail pages: #{pages.size} opened (cap #{cap}); priced from write-up #{via[:writeup]}, " \
        "listing price confirmed by JSON-LD #{via[:jsonld]}; price conflicts #{via[:conflict]}"
    log "not used: #{skipped.sort_by { |_, n| -n }.map { |r, n| "#{r} #{n}" }.join(', ')}" unless skipped.empty?
    items.values
  end

  # Final item for a lead from its detail page, or [nil, reason].
  def bradsdeals_priced(it, d)
    post = d[:post]
    prod = d[:products][it[:bd_uid]]
    return [nil, "not in stock (detail page)"] if prod && prod["availability"].is_a?(String) && prod["availability"] != "in_stock"
    store_url = (prod && bd_store_url(prod)) || it[:store_url]
    n_products = post ? post["listings"].count { |l| l.is_a?(Hash) && l["type"] == "Product" } : 0
    wp = n_products == 1 ? bd_writeup_price(bd_text(post["description"]), headline: post["headline"]) : nil
    return [nil, wp[:skip]] if wp&.[](:skip)
    lp = it[:bd_listing_price]
    conflict = nil
    if wp
      price = wp[:price]
      orig = wp[:orig]
      note = "Price from the Brad's Deals write-up (#{wp[:rule]}): \"#{wp[:snippet]}\"."
      conflict = { title: it[:title], listing: lp, writeup: price } if lp && !bd_near(lp, price)
    else
      offers = d[:offers]
      unless lp && !offers.empty? && offers.all? { |o| bd_near(o, lp, tol: 0.01) }
        return [nil, n_products > 1 ? "post covers several products, listing price not confirmed" : "no price in write-up, listing price not confirmed"]
      end
      price = lp
      orig = nil
      note = "Price from the Brad's Deals listing data, confirmed by the detail page's offer data (no price in the write-up)."
    end
    # Prime evidence: the product record, the listing-page posts and the detail write-up.
    texts = [*it[:bd_texts], post && "#{post['headline']}. #{bd_text(post['description'])}"]
    sentences = texts.grep(String).flat_map { |t| t.split(/(?<=[.!?])\s+/) }.select { |t| BD_PRIME_RE.match?(t) }
    prime = !sentences.empty?
    # The price sentence goes into the text (codes/coupons) unless it mentions
    # Prime without being Prime evidence ("Prime members get free shipping").
    said = wp && (wp[:sentence] !~ /prime/i || BD_PRIME_RE.match?(wp[:sentence])) ? " #{wp[:sentence][0, 240]}" : ""
    text = "Brad's Deals price $#{format('%.2f', price)}#{orig ? " (was $#{format('%.2f', orig)})" : ''}.#{said}"
    text += " Brad's Deals: #{sentences.uniq.first(2).join(' ')[0, 300]} (Prime Day deal)" if prime
    # Product copy is built from the write-up's own sentences (not the store
    # page's meta): those without a $ amount, so prices stay in why_deal.
    writeup = post ? CGI.unescapeHTML(bd_text(post["description"])).tr(" ", " ").gsub(/\s+/, " ").strip : ""
    writeup = writeup.split(/(?<=[.!?])\s+/).reject { |s| s.include?("$") || BD_ASIDE_RE.match?(s) }.uniq.join(" ")
    text += " #{writeup}" unless writeup.empty?
    item = it.reject { |k, _| k.to_s.start_with?("bd_") }
    [item.merge(price: price, compare_at: orig, store_url: store_url, link: store_url, guid: store_url,
                store_hint: DealTools.store_name(store_url), page: it[:bd_detail_url], listing: it[:page],
                text: text, writeup: writeup, price_note: note, price_conflict: conflict,
                prime_day_source: prime ? it[:bd_detail_url] : nil), nil]
  end

  # Leads from one saved/fetched listing page (no network): in-stock product
  # listings with a store product URL and their deal post's detail page.
  # stats filled when given.
  def bradsdeals_page(html, url, source, stats: nil)
    recs = nuxt_records(html)
    # Detail links: the post's url field, else a tile href ending in the post uid.
    hrefs = html.to_s.scan(%r{href="(/deals/[a-z0-9-]+-(blt[0-9a-f]+))"}).to_h { |path, uid| [uid, path] }
    posts = Hash.new { |h, k| h[k] = [] }
    recs.each do |rec|
      next unless rec["listings"].is_a?(Array) && rec["headline"].is_a?(String)
      path = rec["url"].is_a?(String) ? rec["url"] : hrefs[rec["uid"]]
      post = { path: path.to_s.match?(BD_DETAIL_PATH) ? path : nil, published: rec["published_at"].to_s,
               products: rec["listings"].count { |l| l.is_a?(Hash) && l["type"] == "Product" },
               price: bd_num(rec["bd_discount_price"]), text: "#{rec['headline']}. #{bd_text(rec['description'])}" }
      rec["listings"].each { |l| posts[l["uid"]] << post if l.is_a?(Hash) && l["uid"].is_a?(String) }
    end
    listings = recs.select { |r| r["content_type"] == "product_listing" || r["content_type"] == "sale_listing" }
                   .uniq { |r| r["uid"] }
    stats[:records] += listings.size if stats
    listings.filter_map do |rec|
      why =
        if rec["content_type"] == "sale_listing" || rec["type"] == "Sale" then "store-wide sale"
        elsif rec["availability"] != "in_stock" then "not in stock"
        end
      store_url = bd_store_url(rec) unless why
      why ||= "no store product URL" unless store_url
      if why
        stats[:skipped][why] += 1 if stats
        next
      end
      # The post for the detail page: the newest single-product post (a write-up
      # covering several products can't give this one's price).
      post = posts[rec["uid"]].select { |p| p[:path] && p[:products] == 1 }.max_by { |p| p[:published] }
      title_raw = rec["title"].is_a?(String) ? rec["title"] : ""
      title = rec["headline"].is_a?(String) && !rec["headline"].strip.empty? ? rec["headline"].strip : title_raw.sub(/\s+-\s+[^-]+\z/, "").strip
      img = Array(rec["images"]).find { |x| x.is_a?(Hash) && x["url"].is_a?(String) }&.[]("url")
      base_item(source, title: title, link: url, store_url: store_url, price: nil, image: img,
                        store_hint: DealTools.store_name(store_url),
                        bd_uid: rec["uid"], bd_detail_url: post && abs("https://www.bradsdeals.com/", post[:path]),
                        bd_multi: post.nil? && posts[rec["uid"]].any? { |p| p[:path] },
                        bd_listing_price: bd_num(rec["unit_discount_price"]) || bd_num(rec["discount_price"]) || post&.[](:price),
                        bd_texts: [rec["headline"], title_raw, bd_text(rec["callout"]), bd_text(rec["product_description"]),
                                   *posts[rec["uid"]].map { |p| p[:text] }])
    end
  end

  # ---------------------------------------------- Walmart / Sam's Club ---
  # Walmart-platform listing pages (walmart.com, samsclub.com) are Next.js: the
  # products sit in <script id="__NEXT_DATA__"> JSON as objects with
  # "__typename":"Product" and "usItemId" (found anywhere in the tree, deduped
  # by usItemId). Price = priceInfo.linePrice; the original price is
  # priceInfo.wasPrice only when shown and higher. Promotions such as "Sam's
  # Cash Offer" are rewards, never a discount. Member-only / early-access
  # pricing, variant ranges, missing prices and items not in stock are skipped.
  # Product pages are never requested (all data comes from the listing JSON).
  # Both sites load PerimeterX: a challenge ("Robot or human"), a redirect to
  # /blocked, 403, 429 or a page without __NEXT_DATA__ products stops the
  # source for this run (no retry, no ZenRows).
  WN_SAMS_CASH_RE = /sam'?s\s+cash/i

  def wn_products(html)
    json = html.to_s[%r{<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>}m, 1] or return []
    data = begin
      JSON.parse(json)
    rescue JSON::ParserError
      return []
    end
    found = {}
    walk = lambda do |n|
      case n
      when Array then n.each { |x| walk.call(x) }
      when Hash
        found[n["usItemId"].to_s] ||= n if n["__typename"] == "Product" && n["usItemId"]
        n.each_value { |v| walk.call(v) if v.is_a?(Hash) || v.is_a?(Array) }
      end
    end
    walk.call(data)
    found.values
  end

  def wn_blank?(v) = v.nil? || v.to_s.strip.empty?

  # "Ends Oct 10" / "Ends Dec 31, 2027" -> Date (no year: this year in
  # America/Chicago, next year when that is well in the past).
  def wn_promo_end(msg, today)
    m = msg.to_s.match(/\bends\s+([A-Z][a-z]{2,8})\.?\s+(\d{1,2})(?:,\s*(\d{4}))?/i) or return nil
    mon = Date::ABBR_MONTHNAMES.index(m[1][0, 3].capitalize) or return nil
    d = Date.new((m[3] || today.year).to_i, mon, m[2].to_i)
    m[3] || d >= today - 60 ? d : d.next_year
  rescue Date::Error
    nil
  end

  # shortDescription HTML list -> one plain sentence of facts (no prices or promo text).
  def wn_facts(html)
    bits = html.to_s.split(%r{</li>|</p>|</strong>|<br\s*/?>|\n}i).map do |b|
      CGI.unescapeHTML(b.gsub(/<[^>]+>/, " ")).delete("®™*").gsub(/\s+/, " ").strip.sub(/[\s.;,]+\z/, "")
    end
    # Whole bullets only (never cut mid-sentence); store/order/shipping notes left out.
    bits = bits.reject do |b|
      b.length < 3 || b.length > 200 || b.include?("$") ||
        b =~ /sam'?s\s+(?:cash|club)|member|walmart\+|offer|savings|signature|delivery|shipping|pickup|returns?\b|warranty registration/i ||
        b =~ /\b(?:download|visit|learn\s+more|click|great\s+for|perfect\s+for|ideal\s+for|you'll|you\s+own)\b/i
    end
    return "" if bits.empty?
    "Listing details: #{bits.uniq.first(3).join('; ')}."
  end

  def samsclub_items(fetcher, source)
    walmart_next_items(fetcher, source, base: "https://www.samsclub.com", require_shipping: true,
                                        highlight: "Sam's Club membership required")
  end

  def walmart_items(fetcher, source)
    walmart_next_items(fetcher, source, base: "https://www.walmart.com", seller: "Walmart.com")
  end

  def walmart_next_items(fetcher, source, base:, seller: nil, require_shipping: false, highlight: nil)
    ok_if = ->(b) { b.include?("__NEXT_DATA__") && b.include?("usItemId") }
    items = {}
    DealTools.source_urls(source).each do |url|
      r = fetcher.fetch(url, source, ok_if: ok_if)
      err = r.ok ? (r.url.to_s =~ %r{/blocked\b} ? "redirected to #{r.url}" : nil) : r.error
      if err
        log "#{url}: #{err}; stopping #{source['id']} for this run"
        break
      end
      log "#{url}: ok via #{r.via}"
      walmart_next_page(r.body, url, source, base: base, seller: seller, require_shipping: require_shipping,
                                             highlight: highlight).each { |it| items[it[:store_url]] ||= it }
    end
    items.values
  end

  # Items from one saved/fetched listing page (no network). stats filled when
  # given. today: the date in Chicago (CDT offset, like the Woot reader).
  def walmart_next_page(html, url, source, base:, seller: nil, require_shipping: false, highlight: nil,
                        stats: nil, today: Time.now.getlocal("-05:00").to_date)
    title_skip = source["title_exclude"] ? Regexp.new(source["title_exclude"], Regexp::IGNORECASE) : nil
    skipped = Hash.new(0)
    products = wn_products(html)
    out = products.filter_map do |p|
      pi = p["priceInfo"].is_a?(Hash) ? p["priceInfo"] : {}
      name = CGI.unescapeHTML(p["name"].to_s).gsub(/\s+/, " ").gsub(" | ", ", ").strip
      price = DealTools.money(pi["linePrice"].to_s.empty? ? nil : pi["linePrice"].to_s)
      was = wn_blank?(pi["wasPrice"]) ? nil : DealTools.money(pi["wasPrice"].to_s)
      promos = Array(p["promotionMessages"]).select { |m| m.is_a?(Hash) }
      price_promo = promos.find { |m| "#{m['badgeTitle']} #{m['message']}" !~ WN_SAMS_CASH_RE && m["expiryDateMessage"].to_s =~ /\bends\b/i }
      ends = price_promo && wn_promo_end(price_promo["expiryDateMessage"], today)
      why =
        if name.empty? then "no name"
        elsif seller && p["sellerName"].to_s != seller then "sold by a marketplace seller"
        elsif p.dig("availabilityStatusV2", "value").to_s != "IN_STOCK" then "not in stock"
        elsif p["isEarlyAccessItem"] == true || p["earlyAccessEvent"] == true || !wn_blank?(pi["eaPricingText"]) ||
              !wn_blank?(pi["memberPriceString"])
          "member-only / early-access price"
        elsif !wn_blank?(pi["priceRangeString"]) then "variant price range"
        elsif !price&.positive? then "no price (#{pi['linePriceDisplay'].to_s.strip.empty? ? 'missing' : pi['linePriceDisplay']})"
        elsif require_shipping && Array(p["fulfillmentBadges"]).none? { |b| b.to_s =~ /\bshipping\b/i } then "no shipping (in-club / pickup only)"
        elsif title_skip&.match?(name) then "title_exclude"
        elsif ends && ends < today then "promotion already ended"
        end
      if why
        skipped[why] += 1
        next
      end
      path = p["canonicalUrl"].to_s.sub(/[?#].*\z/, "")
      path = "/ip/#{p['usItemId']}" unless path.start_with?("/ip/")
      store_url = "#{base}#{path}"
      img = p.dig("imageInfo", "thumbnailUrl").to_s
      img = p["image"].to_s if img.empty?
      img = img.sub(/\?.*\z/, "")
      compare = was && was > price ? was : nil
      store = source["store"]
      hl = []
      hl << highlight if highlight
      hl << "Pre-owned: check the condition at #{store}" if p["isPreowned"] == true
      brand = [p["brand"], p["manufacturerName"]].find { |b| b.is_a?(String) && !b.strip.empty? }&.strip
      text = "#{store} price $#{format('%.2f', price)}#{compare ? " (was $#{format('%.2f', compare)})" : ''}."
      base_item(source, title: name, link: url, store_url: store_url, price: price, compare_at: compare,
                        image: img.empty? ? nil : img, brand: brand, expires: ends, highlights: hl,
                        text: text, writeup: wn_facts(p["shortDescription"]), us_item_id: p["usItemId"].to_s)
    end
    log "#{products.size} products in __NEXT_DATA__, #{out.size} kept"
    log "not used: #{skipped.sort_by { |_, n| -n }.map { |r, n| "#{r} #{n}" }.join(', ')}" unless skipped.empty?
    if stats
      stats[:products] += products.size
      skipped.each { |r, n| stats[:skipped][r] += n }
    end
    out
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
  PLANNED = %w[walmart_affiliate impact_catalog woot_api amazon_paapi bestbuy_pages].freeze

  PARSERS = {
    "bh" => :bh_items, "newegg" => :newegg_items, "newegg_rss" => :newegg_rss_items,
    "macheist" => :macheist_items, "slickdeals_rss" => :slickdeals_items, "target" => :target_items,
    "bestbuy_api" => :bestbuy_api_items, "bradsdeals" => :bradsdeals_items,
    "samsclub" => :samsclub_items, "walmart" => :walmart_items
  }.freeze
end
