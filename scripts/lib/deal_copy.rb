# frozen_string_literal: true

# Grounded product copy for deal pages. Specs and facts come ONLY from the
# title, fetched store/manufacturer write-up, or known front-matter fields.
# Nothing is invented. Used by publish_deals.rb and scripts/enrich_deal_copy.rb.
module DealCopy
  module_function

  def amazon?(store, url)
    store.to_s =~ /amazon/i || url.to_s =~ /amazon\.|amzn\./i
  end

  def strip_html(text)
    t = text.to_s
      .gsub(/<br\s*\/?>/i, " ")
      .gsub(/<\/p>/i, ". ")
      .gsub(/<[^>]+>/, " ")
      .gsub(/&nbsp;/i, " ")
      .gsub(/&amp;/i, "&")
      .gsub(/&quot;/i, '"')
      .gsub(/&#39;|&apos;/i, "'")
      .gsub(/&rdquo;|&ldquo;/i, '"')
      .gsub(/&rsquo;|&lsquo;/i, "'")
      .gsub(/&mdash;|&ndash;/i, "-")
      .gsub(/&[a-z]+;/i, " ")
      .gsub(/\s+/, " ")
      .strip
    t.gsub(/\.\s*\./, ".")
  end

  def clean_value(value)
    v = value.to_s.gsub(/\s+/, " ").strip
    # Collapse accidental "Foo Foo" duplicates from table scrapes
    v = v.sub(/\A(.+?)\s+\1\z/m, '\1') while v =~ /\A(.+?)\s+\1\z/m
    v.sub(/[,;.]+\z/, "")
  end

  # Pull key specs from free text (title + optional write-up). Returns up to
  # max [{ "label" => ..., "value" => ... }], first match wins per label.
  def specs_from_text(title, extra: "", category: nil, max: 6)
    blob = "#{title} #{extra}".gsub(/\s+/, " ").strip
    found = []
    add = lambda do |label, value|
      return if found.any? { |s| s["label"] == label }
      v = clean_value(value)
      return if v.empty?
      found << { "label" => label, "value" => v }
    end

    if (m = blob.match(/\b(M[1-9](?:\s+Pro|\s+Max|\s+Ultra)?(?:\s+\d+-Core)?)\b/i))
      add.call("Chip", m[1].sub(/\s+Chip\b/i, "").strip)
    elsif (m = blob.match(/\b(A1[4-9]\s*Pro|A1[4-9])\b/i))
      add.call("Chip", m[1])
    elsif (m = blob.match(/\b(AMD\s+B\d{3}|Intel\s+B\d{3}|X670|B850|B760|Z790)\b/i))
      add.call("Chipset", m[1])
    elsif (m = blob.match(/\b(Intel\s+Core\s+(?:Ultra\s+)?[iI]?[3579](?:-\d+\w*)?|Core\s+Ultra\s+\d+|Core\s+[iI][3579](?:-\d+\w*)?|Ryzen\s+[3579]\s+\d{4}\w*|Snapdragon\s+[A-Z0-9]+|Celeron\s+\w+|Pentium\s+\w+)\b/i))
      add.call("Processor", m[1])
    elsif (m = blob.match(/\b(AM5|LGA\s?\d{4})\b/i))
      add.call("Socket", m[1])
    end

    if (m = blob.match(/\b(\d+\s*GB)\s*(?:Memory|RAM|DDR\d)\b/i) || blob.match(/\((\d+GB)\/\d+(?:GB|TB)/i))
      add.call("Memory", m[1].gsub(/\s+/, ""))
    end

    if (m = blob.match(/\b(\d+\s*(?:GB|TB))\s*(SSD|HDD|eMMC|NVMe|microSD(?:XC)?|Internal SSD|Portable SSD|Storage)\b/i))
      val = m[1].gsub(/\s+/, "")
      val += " #{m[2]}" unless m[2] =~ /\AStorage\z/i
      add.call("Storage", val.strip)
    elsif (m = blob.match(/\/(\d+(?:GB|TB))\)/i))
      add.call("Storage", m[1])
    elsif (m = blob.match(/\b(\d+\s*TB)\b/i))
      add.call("Storage", m[1].gsub(/\s+/, ""))
    elsif category.to_s =~ /Tablet|Phone|Wearable/i && (m = blob.match(/\b(\d+\s*GB)\b/i))
      add.call("Storage", m[1].gsub(/\s+/, ""))
    end

    if (m = blob.match(/\b(\d{1,2}(?:\.\d+)?)\s*(?:["”]|-?inch|in)\b/i) ||
            blob.match(/\b(\d{1,2}(?:\.\d+)?)["”](?=\s|,|$|\))/ ) ||
            blob.match(/\b(?:HD|Fire)\s+(\d{1,2})\b/i) || blob.match(/\b(\d{1,2})\s+Tablet\b/i) ||
            blob.match(/\b(\d{2})\s*Class\b/i))
      size = m[1].to_f
      add.call("Display", %(#{m[1]}")) unless size > 0 && size < 6 && blob =~ /\b(SSD|HDD|NVMe|Internal SSD)\b/i
    end
    if (m = blob.match(/\b(4K|8K|5K|6K|QHD|WQHD|UHD|Full HD|1080p|1440p|2160p|OLED|QLED|Mini[- ]?LED|Nano IPS|IPS)\b/i))
      add.call("Panel", m[1])
    end
    if (m = blob.match(/\b(\d{2,3})\s*Hz\b/i))
      add.call("Refresh rate", "#{m[1]} Hz")
    end
    if (m = blob.match(/\b(\d{3,4}\s*[x×]\s*\d{3,4})\b/i))
      add.call("Resolution", m[1].gsub(/\s/, "").tr("×", "x"))
    end
    if (m = blob.match(/\b(\d+\s*MP|\d+-Megapixel)\b/i))
      add.call("Sensor", m[1].gsub(/\s+/, ""))
    end
    if (m = blob.match(/\b(noise[- ]cancell?ing|ANC|open-back|over-ear|on-ear|in-ear|true wireless|wireless|wired)\b/i))
      add.call("Style", m[1])
    end
    if (m = blob.match(/\b(\d[\d,]*\s*Pa)\b/i))
      add.call("Suction", m[1].gsub(/\s+/, ""))
    end
    if (m = blob.match(/\b(Wi-?Fi\s*[67]?|Bluetooth|USB-C|Thunderbolt\s*\d*|GPS(?:\s*\+\s*Cellular)?)\b/i))
      add.call("Connectivity", m[1])
    end
    if category.to_s =~ /Accessor|Audio|Smart/i && (m = blob.match(/\b(\d+(?:\.\d+)?\s*W)\b/i))
      add.call("Power", m[1].gsub(/\s+/, ""))
    end
    if (m = blob.match(/\b(Micro[- ]?ATX|Mini[- ]?ITX|ATX|portable|curved)\b/i))
      add.call("Form", m[1])
    end
    if (m = blob.match(/\b\((\d{4})\)|\b(20[2-3]\d)\s+(?:Edition|Generation|Model)\b/i))
      add.call("Year", (m[1] || m[2]).to_s)
    elsif (m = blob.match(/\b(\d)(?:st|nd|rd|th)\s+Gen(?:eration)?\b/i))
      add.call("Generation", "#{m[1]}#{m[0][/st|nd|rd|th/]} gen")
    end

    found.first(max)
  end

  def merge_specs(page_specs, title_specs, max: 6)
    out = []
    seen = {}
    (Array(page_specs) + Array(title_specs)).each do |s|
      next unless s.is_a?(Hash)
      label = s["label"].to_s.strip
      value = clean_value(s["value"])
      next if label.empty? || value.empty? || seen[label.downcase]
      seen[label.downcase] = true
      out << { "label" => label[0, 40], "value" => value[0, 100] }
      break if out.size >= max
    end
    out
  end

  # Unique first-person summary from overview text when available.
  # Never invents features. Drops "filed under X on this site" filler.
  def summary(title:, category:, brand: nil, store: nil, specs: [], amazon: false, overview: nil)
    name = title.to_s.sub(/\A['"]|['"]\z/, "").strip
    overview = strip_html(overview.to_s)
    brand_s = brand.to_s.strip
    store_s = store.to_s.strip

    # Prefer 1–3 clean sentences from the source overview.
    sentences = overview.split(/(?<=[.!?])\s+/).map(&:strip).reject { |s|
      s.length < 28 ||
        s =~ /\b(add to cart|free shipping|sold by|subscribe|prime members|limited time|click here|buy now|sku:|upc:|you save|% off)\b/i ||
        s =~ /\ABuy\s+/i ||
        s =~ /\AShop\s+/i
    }

    # Drop sentences that are just a rephrase of the title / "Buy X featuring"
    title_words = name.downcase.scan(/[a-z0-9]+/).reject { |w| w.length < 3 }
    sentences = sentences.reject { |s|
      sw = s.downcase.scan(/[a-z0-9]+/)
      next false if sw.size < 6
      overlap = (title_words & sw).size
      overlap >= [title_words.size * 0.7, 5].max && s.length < name.length + 40
    }

    picked = sentences.first(3)
    # If overview was one long marketing blob without periods, carve a chunk.
    if picked.empty? && overview.length >= 80
      chunk = overview[0, 320].sub(/\s+\S*\z/, "").strip
      # Prefer cutting after a comma/semicolon if no period
      if chunk !~ /[.!?]\z/ && (m = chunk.match(/\A(.{100,280}[,;])/))
        chunk = m[1].sub(/[,;]\z/, ".")
      elsif chunk !~ /[.!?]\z/
        chunk = "#{chunk}."
      end
      picked = [chunk] unless chunk.length < 40
    end

    parts = []
    if picked.any?
      lead =
        if brand_s.empty? || name.downcase.include?(brand_s.downcase)
          "I looked at the #{name}."
        else
          "I looked at this #{brand_s} pick: #{name}."
        end
      parts << lead
      # Keep source wording; lightly peel "Buy X featuring" if present
      cleaned = picked.map { |s|
        s = s.sub(/\ABuy\s+.+?\s+featuring\s+/i, "")
        s = s[0].upcase + s[1..] if s.length > 1
        s = "#{s}." unless s =~ /[.!?]\z/
        s
      }
      parts.concat(cleaned.first(2))
    elsif specs.any?
      bits = specs.first(4).map { |s| "#{s['label'].downcase} #{s['value']}" }.join(", ")
      parts << "I pulled these listing details for the #{name}: #{bits}."
    else
      parts << "I filed the #{name} as a deal worth checking."
    end

    # Short closer — deal context lives in why_deal; keep body unique for SEO.
    if amazon
      parts << "I posted the Amazon listing so you can confirm the live price."
    elsif !store_s.empty?
      parts << "I saw it at #{store_s} and wanted a clean product write-up here."
    end

    parts.map { |p| p.to_s.strip }.reject(&:empty?).join(" ").gsub(/\s+/, " ").strip
  end

  def why_deal(price:, compare_at:, store:, amazon:)
    if amazon
      "Amazon has a good price on this right now. Prices change fast, so check the current price at Amazon before you buy."
    else
      money = ->(v) { v.to_f == v.to_f.round ? "$#{v.to_f.round}" : format("$%.2f", v.to_f) }
      store_s = store.to_s.strip.empty? ? "The store" : store
      if compare_at && price && compare_at.to_f > price.to_f
        "#{store_s} has it for #{money.call(price)}, down from #{money.call(compare_at)}. Prices change fast, so check the price before you buy."
      elsif price
        "#{store_s} has it for #{money.call(price)}. Prices change fast, so check the price before you buy."
      else
        "Prices change fast, so check the price at #{store_s} before you buy."
      end
    end
  end

  def meta_description(summary_text, amazon:)
    t = summary_text.to_s.gsub(/\s+/, " ").strip
    t = t.gsub(/\$[\d,]+(?:\.\d{2})?/, "").gsub(/\s{2,}/, " ").strip if amazon
    return t if t.length <= 155
    cut = t[0, 155]
    cut = cut.sub(/\s+\S*\z/, "")
    cut.strip
  end
end
