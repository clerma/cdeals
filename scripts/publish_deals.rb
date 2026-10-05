#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns approved deal candidates from _deal_queue/queue.yml into _products/<slug>.md
# (type: affiliate) and forgets rejected ones.
#
#   bundle exec ruby scripts/publish_deals.rb                 # apply status: approved / rejected from the queue
#   bundle exec ruby scripts/publish_deals.rb approve d-1a2b3c4 [more ids]
#   bundle exec ruby scripts/publish_deals.rb reject d-1a2b3c4 [more ids]
#   options: --dry-run, --images download|hotlink (default from deal_sources.yml)

require "optparse"
require "fileutils"
require_relative "lib/deal_tools"
require_relative "lib/polite_http"
require_relative "lib/deal_copy"
require_relative "lib/source_cache"

opts = { dry_run: false, images: nil }
OptionParser.new do |o|
  o.on("--dry-run") { opts[:dry_run] = true }
  o.on("--images MODE", %w[download hotlink]) { |v| opts[:images] = v }
end.parse!

cfg = DealTools.config
image_mode = opts[:images] || cfg.dig("defaults", "images") || "download"
queue = DealTools.load_queue
rejected = DealTools.load_rejected

if (action = ARGV.shift)
  abort "Usage: publish_deals.rb [approve|reject ID...]" unless %w[approve reject].include?(action) && ARGV.any?
  ARGV.each do |id|
    e = queue.find { |x| x["id"] == id } or abort("No candidate #{id} in the queue")
    e["status"] = action == "approve" ? "approved" : "rejected"
  end
end

http = nil
num = ->(v) { v.nil? ? nil : (v.to_f == v.to_f.round ? v.to_f.round : v.to_f.round(2)) }

download_image = lambda do |url, slug|
  return url if image_mode == "hotlink" || url.to_s.empty?
  http ||= PoliteHTTP.new(cfg["http"] || {})
  # Adobe Scene7 store images (Dell, HP, ...) accept a size; ask for 800px.
  url = url.gsub(/([?&])wid=\d+/, "\\1wid=800").gsub(/&hei=\d+/, "") if url.include?("/is/image/")
  _final, res = http.follow(url)
  unless res&.ok? && res.content_type.to_s.start_with?("image/") && res.body.bytesize.between?(500, 2_000_000)
    warn "  image not downloaded (#{res&.error || "HTTP #{res&.status} #{res&.content_type} #{res&.body&.bytesize} bytes"}); hotlinking #{url}"
    return url
  end
  ext = { "image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp", "image/avif" => ".avif", "image/gif" => ".gif" }[res.content_type.split(";").first.strip] || ".jpg"
  rel = "/assets/uploads/deals/#{slug}#{ext}"
  unless opts[:dry_run]
    FileUtils.mkdir_p(File.join(DealTools::ROOT, "assets/uploads/deals"))
    File.binwrite(File.join(DealTools::ROOT, rel), res.body)
  end
  rel
end


published = []
problems = []
queue.each do |e|
  case e["status"].to_s
  when "rejected"
    rejected << { "key" => DealTools.url_key(e["store_url"] || e["affiliate_url"]), "source_link" => e["source_link"],
                  "title" => e["title"], "rejected" => Date.today }.compact
    e["_done"] = true
    puts "rejected  #{e['id']}  #{e['title']}"
  when "approved"
    missing = %w[title price category affiliate_url store].select { |k| e[k].to_s.strip.empty? }
    unless missing.empty?
      problems << "#{e['id']} (#{e['title']}): fill in #{missing.join(', ')} first"
      next
    end
    key = DealTools.url_key(e["affiliate_url"])
    if (dup = DealTools.existing_product_keys[key])
      problems << "#{e['id']}: already published as _products/#{dup}"
      e["_done"] = true
      next
    end
    base = DealTools.slugify(e["title"])
    slug = base
    n = 1
    slug = "#{base}-#{n += 1}" while File.exist?(File.join(DealTools::PRODUCTS_DIR, "#{slug}.md"))
    affiliate = DealTools.affiliate_url(e["affiliate_url"]) # re-clean in case it was pasted by hand
    amazon = DealCopy.amazon?(e["store"], affiliate)
    overview = ""
    page_specs = []
    begin
      fm_probe = { "title" => e["title"], "brand" => e["brand"], "store" => e["store"], "affiliate_url" => affiliate }
      enrich_url = SourceCache.enrichment_url(fm_probe)
      if enrich_url && !enrich_url.empty? && !SourceCache.amazon_url?(enrich_url)
        data = SourceCache.fetch_page(enrich_url, cfg: cfg, source_id: "publish")
        unless data["error"]
          overview = data["overview"].to_s
          page_specs = data["specs"] || []
        end
      end
    rescue StandardError => err
      warn "  enrich soft-fail #{e['id']}: #{err.message[0, 80]}"
    end
    title_specs = DealCopy.specs_from_text(e["title"], extra: "#{e['source_title']} #{overview}", category: e["category"])
    specs = DealCopy.merge_specs(page_specs, title_specs)
    summary = e["summary"].to_s.strip
    if summary.empty? || summary =~ /filed under|I posted it because|I posted it after checking|\A(?:Amazon has a good price|The store|\S+ has it for \$)/
      summary = DealCopy.summary(title: e["title"], category: e["category"], brand: e["brand"],
                                 store: e["store"], specs: specs, amazon: amazon, overview: overview)
    end
    why = DealCopy.why_deal(price: e["price"], compare_at: e["compare_at"], store: e["store"], amazon: amazon)
    fm = {
      "title" => e["title"].to_s.strip,
      "type" => "affiliate",
      "category" => e["category"],
      "brand" => e["brand"],
      "price" => num.call(e["price"]),
      # Original/list price, only when the source gave a real one higher than the price
      # (shown struck through with a -NN% badge; left out otherwise).
      "compare_at" => (c = num.call(e["compare_at"])) && num.call(e["price"]) && c > num.call(e["price"]) ? c : nil,
      "store" => e["store"],
      "affiliate_url" => affiliate,
      "expires" => e["expires"],
      "date" => Date.today,
      "images" => [download_image.call(e["image"], slug)].compact.reject(&:empty?),
      "highlights" => (h = Array(e["highlights"]).reject { |x| x.to_s.strip.empty? }).empty? ? ["Sold by #{e['store']}"] : h,
      "specs" => specs.empty? ? nil : specs,
      "why_deal" => why,
      "description" => DealCopy.meta_description(summary, amazon: amazon),
      "source" => e["source"] # internal: which feed/site found it (not shown on the site)
    }.reject { |_, v| v.nil? || v == "" }
    body = "#{fm.to_yaml}---\n#{summary}\n"
    path = File.join(DealTools::PRODUCTS_DIR, "#{slug}.md")
    File.write(path, body) unless opts[:dry_run]
    published << path.sub("#{DealTools::ROOT}/", "")
    e["_done"] = true
    puts "published #{e['id']}  -> #{path.sub("#{DealTools::ROOT}/", '')}"
  end
end

unless opts[:dry_run]
  DealTools.save_queue(queue.reject { |e| e["_done"] })
  DealTools.save_rejected(rejected)
end
puts "Published #{published.size}, rejected #{queue.count { |e| e['_done'] && e['status'] == 'rejected' }}, still waiting #{queue.count { |e| !e['_done'] }}."
problems.each { |p| warn "  ! #{p}" }
puts "(dry run: nothing written)" if opts[:dry_run]
