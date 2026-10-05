#!/usr/bin/env ruby
# frozen_string_literal: true

# Rewrites every affiliate deal in _products/ with grounded summary + specs.
# Specs come only from the title (and optional --fetch store pages for
# non-Amazon deals). Never invents facts. Amazon pages are never fetched.
#
#   bundle exec ruby scripts/enrich_deal_copy.rb
#   bundle exec ruby scripts/enrich_deal_copy.rb --limit 50
#   bundle exec ruby scripts/enrich_deal_copy.rb --fetch   # also read non-Amazon store pages (robots.txt respected)

require "optparse"
require "yaml"
require "nokogiri"
require_relative "lib/deal_tools"
require_relative "lib/deal_copy"
require_relative "lib/polite_http"

opts = { limit: nil, fetch: false, dry_run: false }
OptionParser.new do |o|
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
  o.on("--fetch") { opts[:fetch] = true }
  o.on("--dry-run") { opts[:dry_run] = true }
end.parse!

cfg = DealTools.config
http = opts[:fetch] ? PoliteHTTP.new(cfg["http"] || {}) : nil
skip_hosts = Array(cfg["skip_store_fetch_hosts"]).map(&:downcase) + %w[amazon.com amzn.to]

files = Dir[File.join(DealTools::PRODUCTS_DIR, "*.md")].sort
done = full = thin = 0

store_text = lambda do |url|
  return "" unless http && url
  host = DealTools.bare_host(URI(url)) rescue ""
  return "" if skip_hosts.any? { |h| host == h || host.end_with?(".#{h}") }
  return "" unless http.allowed?(url)
  _f, res = http.follow(url, max: 6)
  return "" unless res&.ok?
  doc = Nokogiri::HTML(res.body)
  bits = []
  bits << doc.at_css("meta[name='description']")&.[]("content").to_s
  bits << doc.css("table tr, .specs li, [data-test='item-details-specifications'] li, .product-specs li").first(20).map(&:text).join(" ")
  bits << doc.at_css("h1")&.text.to_s
  bits.join(" ").gsub(/\s+/, " ").strip[0, 2000]
rescue StandardError
  ""
end

files.each do |path|
  break if opts[:limit] && done >= opts[:limit]
  raw = File.read(path)
  parts = raw.split(/^---\s*$/)
  next unless parts.size >= 3
  fm = YAML.safe_load(parts[1], permitted_classes: [Date, Time]) || {}
  next unless fm["type"].to_s == "affiliate"

  title = fm["title"].to_s
  amazon = DealCopy.amazon?(fm["store"], fm["affiliate_url"])
  extra = ""
  if opts[:fetch] && !amazon
    extra = store_text.call(fm["affiliate_url"] || fm["store_url"])
  end
  specs = DealCopy.specs_from_text(title, extra: extra, category: fm["category"])
  # Prefer existing specs only if they look like our shape; otherwise replace.
  if Array(fm["specs"]).any? { |s| s.is_a?(Hash) && s["label"] && s["value"] } && specs.empty?
    specs = fm["specs"]
  end
  summary = DealCopy.summary(
    title: title, category: fm["category"], brand: fm["brand"], store: fm["store"],
    specs: specs, amazon: amazon
  )
  why = DealCopy.why_deal(price: fm["price"], compare_at: fm["compare_at"], store: fm["store"], amazon: amazon)
  desc = DealCopy.meta_description(summary, amazon: amazon)

  fm["specs"] = specs unless specs.empty?
  fm["why_deal"] = why
  fm["description"] = desc
  # Drop empty specs key if nothing found
  fm.delete("specs") if specs.empty?

  body = "#{summary}\n"
  out = "#{fm.to_yaml}---\n#{body}"
  File.write(path, out) unless opts[:dry_run]
  done += 1
  if specs.size >= 3
    full += 1
  else
    thin += 1
  end
  puts "#{File.basename(path)}  specs=#{specs.size}  #{amazon ? 'amazon' : fm['store']}"
end

puts "Updated #{done} deals (#{full} with 3+ specs, #{thin} with fewer).#{opts[:dry_run] ? ' (dry run)' : ''}"
