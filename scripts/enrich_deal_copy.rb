#!/usr/bin/env ruby
# frozen_string_literal: true

# Enrich affiliate deals with source-backed summaries and specs.
# Non-Amazon: fetch the store listing (plain). --zenrows only for JS-heavy Target pages,
# never as a workaround for HTTP 429 rate limits.
# Amazon: never fetch amazon.com — try a manufacturer page when we know one.
# Cache: /workspace/cdeals-cache (or CDEALS_CACHE).
#
#   bundle exec ruby scripts/enrich_deal_copy.rb
#   bundle exec ruby scripts/enrich_deal_copy.rb --limit 40 --store "B&H Photo"
#   bundle exec ruby scripts/enrich_deal_copy.rb --zenrows   # Target JS only; not for 429s

require "optparse"
require "yaml"
$stdout.sync = true
require_relative "lib/deal_tools"
require_relative "lib/deal_copy"
require_relative "lib/source_cache"
require_relative "lib/fetcher"

opts = { limit: nil, store: nil, dry_run: false, zenrows: false, only_thin: false, cache_only: false, amazon: true, non_amazon: true }
OptionParser.new do |o|
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
  o.on("--store NAME") { |v| opts[:store] = v }
  o.on("--dry-run") { opts[:dry_run] = true }
  o.on("--zenrows") { opts[:zenrows] = true }
  o.on("--only-thin") { opts[:only_thin] = true }
  o.on("--cache-only") { opts[:cache_only] = true }
  o.on("--amazon-only") { opts[:non_amazon] = false }
  o.on("--non-amazon-only") { opts[:amazon] = false }
end.parse!

cfg = DealTools.config
# Be extra polite during bulk enrichment (B&H returns HTTP 429 if rushed).
(cfg["http"] ||= {})["min_delay_seconds"] = if opts[:zenrows]
  1.5
else
  [(cfg.dig("http", "min_delay_seconds") || 2).to_f, 6.0].max
end
fetcher = Fetcher.new(cfg, root: DealTools::ROOT)
files = Dir[File.join(DealTools::PRODUCTS_DIR, "*.md")].sort

stats = Hash.new(0)
done = 0

files.each do |path|
  break if opts[:limit] && done >= opts[:limit]
  raw = File.read(path)
  parts = raw.split(/^---\s*$/)
  next unless parts.size >= 3
  fm = YAML.safe_load(parts[1], permitted_classes: [Date, Time]) || {}
  next unless fm["type"].to_s == "affiliate"
  next if opts[:store] && fm["store"].to_s != opts[:store]

  body0 = parts[2].to_s.strip
  thin = body0 =~ /filed under|I posted it because|I posted it after checking|This is the / ||
         body0 =~ /I filed the .+ as a deal worth checking/ ||
         body0 =~ /I pulled these listing details/
  next if opts[:only_thin] && !thin

  amazon = DealCopy.amazon?(fm["store"], fm["affiliate_url"])
  next if amazon && !opts[:amazon]
  next if !amazon && !opts[:non_amazon]

  overview = ""
  page_specs = []
  via = "title"
  url = SourceCache.enrichment_url(fm)

  if url && !url.empty?
    if opts[:cache_only]
      cached = SourceCache.read_cache(url)
      if cached && (cached["overview"].to_s.length > 40 || (cached["specs"] || []).any?)
        overview = cached["overview"].to_s
        page_specs = cached["specs"] || []
        via = "cache"
      else
        stats[:cache_miss] += 1
      end
    elsif opts[:zenrows] && fm["store"].to_s =~ /target/i
      src = { "id" => "enrich-#{fm['store'].to_s.downcase.gsub(/\W+/, '-')}", "fetch" => "zenrows",
              "zenrows" => { "wait_for" => "body", "js_instructions" => [{ "scroll_y" => 2000 }, { "wait" => 1000 }] } }
      # Use Fetcher directly then extract
      unless SourceCache.amazon_url?(url)
        cached = SourceCache.read_cache(url)
        if cached && cached["overview"].to_s.length > 40
          overview = cached["overview"]; page_specs = cached["specs"] || []; via = "cache"
        else
          r = fetcher.fetch(url, src, ok_if: ->(b) { b.to_s.length > 2000 })
          if r.ok
            extracted = SourceCache.extract_html(r.body, url)
            SourceCache.write_cache(url, extracted.merge("via" => r.via, "credits" => r.credits.to_i))
            overview = extracted["overview"].to_s
            page_specs = extracted["specs"] || []
            via = r.via
            stats[:zenrows_credits] += r.credits.to_i
          else
            stats[:fetch_fail] += 1
          end
        end
      end
    else
      # Plain fetch + cache only. ZenRows is NOT used as a 429 escape hatch.
      # (Target JS pages use the branch above when --zenrows is set.)
      data = SourceCache.fetch_page(url, cfg: cfg, fetcher: fetcher, source_id: "enrich")
      if data["error"]
        stats[:fetch_fail] += 1
        stats[:amazon_skip] += 1 if amazon
        stats[:rate_limited] += 1 if data["error"].to_s =~ /429/
      else
        overview = data["overview"].to_s
        page_specs = data["specs"] || []
        via = data["via"] || "fetched"
        stats[:zenrows_credits] += data["credits"].to_i
      end
    end
  elsif amazon
    stats[:amazon_no_mfr] += 1
  end

  title_specs = DealCopy.specs_from_text(fm["title"], extra: overview, category: fm["category"])
  specs = DealCopy.merge_specs(page_specs, title_specs, max: 6)
  summary = DealCopy.summary(
    title: fm["title"], category: fm["category"], brand: fm["brand"], store: fm["store"],
    specs: specs, amazon: amazon, overview: overview
  )
  why = DealCopy.why_deal(price: fm["price"], compare_at: fm["compare_at"], store: fm["store"], amazon: amazon)
  desc = DealCopy.meta_description(summary, amazon: amazon)

  fm["specs"] = specs.empty? ? nil : specs
  fm["why_deal"] = why
  fm["description"] = desc
  manual = fm.slice(*DealTools::MANUAL_KEYS) # my_take etc.: kept exactly as written
  fm = fm.reject { |_, v| v.nil? || v == "" }.merge(manual)

  File.write(path, "#{fm.to_yaml}---\n#{summary}\n") unless opts[:dry_run]
  done += 1
  rich = overview.length >= 60
  stats[rich ? :rich : :thin] += 1
  stats[amazon ? :amazon_done : :non_amazon_done] += 1
  stats[:with_3specs] += 1 if specs.size >= 3
  puts "#{File.basename(path)}  #{amazon ? 'amz' : fm['store'][0, 8]}  via=#{via}  overview=#{overview.length}  specs=#{specs.size}#{rich ? ' RICH' : ' thin'}"
end

fetcher.save_usage!
puts "Updated #{done}: rich=#{stats[:rich]} thin=#{stats[:thin]} " \
     "non-amazon=#{stats[:non_amazon_done]} amazon=#{stats[:amazon_done]} " \
     "3+specs=#{stats[:with_3specs]} fetch_fail=#{stats[:fetch_fail]} " \
     "amazon_no_mfr=#{stats[:amazon_no_mfr]} zenrows_credits=#{stats[:zenrows_credits]}" \
     "#{opts[:dry_run] ? ' (dry run)' : ''}"
