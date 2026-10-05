# frozen_string_literal: true

# Grounded product copy for deal pages. Specs and facts come ONLY from the
# title, optional source/store write-up text, or known front-matter fields.
# Nothing is invented. Used by publish_deals.rb and scripts/enrich_deal_copy.rb.
module DealCopy
  module_function

  # Pull key specs from free text (title + optional write-up). Returns up to
  # max [{ "label" => ..., "value" => ... }], first match wins per label.
  def specs_from_text(title, extra: "", category: nil, max: 5)
    blob = "#{title} #{extra}".gsub(/\s+/, " ").strip
    found = []
    add = lambda do |label, value|
      return if found.any? { |s| s["label"] == label }
      v = value.to_s.strip.sub(/[,;.]+\z/, "")
      return if v.empty?
      found << { "label" => label, "value" => v }
    end

    # Chip / processor (order matters: more specific first)
    if (m = blob.match(/\b(M[1-9](?:\s+Pro|\s+Max|\s+Ultra)?(?:\s+\d+-Core)?(?:\s+Chip)?)\b/i))
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

    # Memory (require Memory/RAM/DDR so we do not steal storage sizes)
    if (m = blob.match(/\b(\d+\s*GB)\s*(?:Memory|RAM|DDR\d)\b/i) || blob.match(/\((\d+GB)\/\d+(?:GB|TB)/i))
      add.call("Memory", m[1].gsub(/\s+/, ""))
    end

    # Storage: require a storage keyword, or the second size in (16GB/512GB)
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

    # Display / screen size
    if (m = blob.match(/\b(\d{1,2}(?:\.\d+)?)\s*(?:["”]|-?inch|in)\b/i) ||
            blob.match(/\b(\d{1,2}(?:\.\d+)?)["”](?=\s|,|$|\))/ ) ||
            blob.match(/\b(?:HD|Fire)\s+(\d{1,2})\b/i) || blob.match(/\b(\d{1,2})\s+Tablet\b/i) ||
            blob.match(/\b(\d{2})\s*Class\b/i))
      size = m[1].to_f
      add.call("Display", %(#{m[1]}")) unless size > 0 && size < 6 && blob =~ /\b(SSD|HDD|NVMe|Internal SSD)\b/i
    end
    if (m = blob.match(/\b(4K|8K|5K|6K|QHD|WQHD|UHD|Full HD|1080p|1440p|2160p|OLED|QLED|Mini[- ]?LED|Nano IPS|IPS)\b/i))
      add.call("Panel", m[1]) unless found.any? { |s| s["label"] == "Panel" }
    end
    if (m = blob.match(/\b(\d{2,3})\s*Hz\b/i))
      add.call("Refresh rate", "#{m[1]} Hz")
    end
    if (m = blob.match(/\b(\d{3,4}\s*[x×]\s*\d{3,4})\b/i))
      add.call("Resolution", m[1].gsub(/\s/, "").tr("×", "x"))
    end

    # Camera / photo
    if (m = blob.match(/\b(\d+\s*MP|\d+-Megapixel)\b/i))
      add.call("Sensor", m[1].gsub(/\s+/, ""))
    end
    if (m = blob.match(/\b(mirrorless|DSLR|action cam|360)\b/i))
      add.call("Type", m[1])
    end

    # Audio
    if (m = blob.match(/\b(noise[- ]cancell?ing|ANC|open-back|over-ear|on-ear|in-ear|true wireless|wireless|wired)\b/i))
      add.call("Style", m[1])
    end

    # Smart home / vacuum
    if (m = blob.match(/\b(\d[\d,]*\s*Pa)\b/i))
      add.call("Suction", m[1].gsub(/\s+/, ""))
    end
    if (m = blob.match(/\b(LiDAR|self-emptying|robot vacuum)\b/i))
      add.call("Feature", m[1])
    end

    # Connectivity / capacity extras
    if (m = blob.match(/\b(Wi-?Fi\s*[67]?|Bluetooth|USB-C|Thunderbolt\s*\d*|GPS(?:\s*\+\s*Cellular)?|Ethernet)\b/i))
      add.call("Connectivity", m[1])
    end
    if category.to_s =~ /Accessor|Audio|Smart/i && (m = blob.match(/\b(\d+(?:\.\d+)?\s*W)\b/i))
      add.call("Power", m[1].gsub(/\s+/, ""))
    end
    if (m = blob.match(/\b(IPX?\d)\b/i))
      add.call("Water resistance", m[1])
    end

    # Case / form (computers)
    if (m = blob.match(/\b(Micro[- ]?ATX|Mini[- ]?ITX|ATX|portable|curved)\b/i))
      add.call("Form", m[1])
    end

    # Generation / year when clearly stated
    if (m = blob.match(/\b\((\d{4})\)|\b(20[2-3]\d)\s+(?:Edition|Generation|Model)\b/i))
      add.call("Year", (m[1] || m[2]).to_s)
    elsif (m = blob.match(/\b(\d)(?:st|nd|rd|th)\s+Gen(?:eration)?\b/i))
      add.call("Generation", "#{m[1]}th gen")
    end

    found.first(max)
  end

  # Short first-person summary. Uses only title, category, brand, store, specs.
  # No invented features. Templated so every deal gets something useful.
  def summary(title:, category:, brand: nil, store: nil, specs: [], amazon: false)
    name = title.to_s.sub(/\A['"]|['"]\z/, "").strip
    brand_s = brand.to_s.strip
    cat = category.to_s.strip
    bits = specs.map { |s| "#{s['label'].downcase} #{s['value']}" }
    who =
      case cat
      when "Laptops" then "if you need a portable computer for work or school"
      when "Computers" then "if you're building or updating a desktop setup"
      when "Tablets" then "for reading, browsing, and light everyday use"
      when "Phones" then "if you're due for a phone upgrade"
      when "Audio" then "if you want better sound without a big setup"
      when "Cameras" then "for photos and video"
      when "TV & Home Theater" then "for movies, sports, and everyday watching"
      when "Smart Home" then "if you're adding to a smart home"
      when "Wearables" then "for fitness tracking and quick notifications"
      when "Gaming" then "for playing at home or on the go"
      when "Accessories" then "as a useful add-on for your gear"
      else "if it fits what you're shopping for"
      end

    lead =
      if brand_s.empty? || name.downcase.include?(brand_s.downcase)
        "This is the #{name}."
      else
        article = brand_s =~ /\A[aeiou]/i ? "an" : "a"
        "This is #{article} #{brand_s} #{cat.downcase.sub(/s\z/, '')}: #{name}."
      end

    mid =
      if bits.any?
        "From the listing: #{bits.first(4).join(', ')}."
      else
        "It's filed under #{cat} on this site."
      end

    close =
      if amazon
        "I posted it because Amazon had a strong price when I checked. Prices move, so confirm the current price at Amazon before you buy."
      else
        store_s = store.to_s.strip.empty? ? "the store" : store
        "I posted it after checking the price at #{store_s}. Worth a look #{who}."
      end

    "#{lead} #{mid} #{close}"
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
    # Stored as page.description (unique). seo.html truncates for the meta tag.
    # Amazon: strip any dollar amounts (Associates).
    t = summary_text.to_s.gsub(/\s+/, " ").strip
    t = t.gsub(/\$[\d,]+(?:\.\d{2})?/, "").gsub(/\s{2,}/, " ").strip if amazon
    t
  end

  def amazon?(store, url)
    store.to_s =~ /amazon/i || url.to_s =~ /amazon\.|amzn\./i
  end
end
