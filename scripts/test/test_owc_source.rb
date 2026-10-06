# frozen_string_literal: true

# Offline test of the owc source (DirectSources.owc_items, OWC / MacSales
# specials). Saved pages in scripts/test/fixtures/owc/: the specials page
# (trimmed: its morePages script) and the real load-more answer for batch 1.
#   * parser tests: the real Fetcher / PoliteHTTP / RunBlocks with Net::HTTP
#     stubbed (eshop.macsales.com is never contacted);
#   * one finder run from a temporary copy of the repo layout against a small
#     HTTP server on 127.0.0.1 (cross-store dedupe and the re-check), like
#     scripts/test/test_block_stop.rb. Nothing in the repo changes.
#
#   BUNDLE_WITH=deals bundle exec ruby scripts/test/test_owc_source.rb

require "rbconfig"
begin
  require "minitest/autorun"
rescue LoadError
  # Under `bundle exec` the Gemfile hides Ruby's bundled minitest gem.
  lib = [File.join(RbConfig::CONFIG["rubylibprefix"], "gems", RbConfig::CONFIG["ruby_version"]), Gem.default_dir]
        .flat_map { |d| Dir[File.join(d, "gems", "minitest-*", "lib")] }.max or raise
  $LOAD_PATH.unshift(lib)
  require "minitest/autorun"
end
require "socket"
require "yaml"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require_relative "../lib/fetcher"
require_relative "../lib/direct_sources"

# Net::HTTP answers from OwcStub.routes ("host/path?query" => [status, body]);
# every request is logged. Unknown URLs: 404. robots.txt allows everything.
module OwcStub
  class << self
    attr_accessor :routes, :log
  end

  def request(req, *)
    key = "#{address}#{req.path}"
    OwcStub.log << key
    status, body = key.end_with?("/robots.txt") ? [200, "User-agent: *\nAllow: /\n"] : (OwcStub.routes[key] || [404, "<html><body>not found</body></html>"])
    res = Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "X")
    res["content-type"] = key.end_with?("/robots.txt") ? "text/plain" : "text/html;charset=UTF-8"
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    res
  end
end
Net::HTTP.prepend(OwcStub)

class TestOwcSource < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  FIX = File.join(__dir__, "fixtures", "owc")
  HOST = "eshop.macsales.com"
  SPECIALS = "https://#{HOST}/shop/specials"

  def specials = File.read(File.join(FIX, "specials.html"))
  def batch1 = File.read(File.join(FIX, "load-more-1.html"))
  def batches = DirectSources.owc_more_pages(specials)
  def batch_key(ids) = "#{HOST}/api/search/load-more/?view=specials&items=#{ids}"
  def pages = OwcStub.log.reject { |k| k.end_with?("/robots.txt") }

  def source(extra = {})
    { "id" => "owc", "name" => "OWC specials", "store" => "OWC", "fetch" => "plain", "fallback" => "none",
      "parser" => "owc", "urls" => [SPECIALS] }.merge(extra)
  end

  def setup
    OwcStub.log = []
    # Batch 1 is the saved answer; the other batches get the same cards (deduped by URL).
    OwcStub.routes = { "#{HOST}/shop/specials" => [200, specials] }
    batches.each { |ids| OwcStub.routes[batch_key(ids)] = [200, batch1] }
    RunBlocks.reset!
    @tmp = Dir.mktmpdir("cdeals-owc-test")
    cfg = { "http" => { "user_agent" => "cDealsFinderTest/1.0", "min_delay_seconds" => 0, "robots_cache_dir" => nil },
            "zenrows" => { "usage_file" => "usage.json" },
            # A planned official source for the host (like impact-catalogs) must not stop plain fetches.
            "official_sources" => [{ "id" => "impact", "enabled" => false, "official_for" => ["macsales.com"] }] }
    @fetcher = Fetcher.new(cfg, root: @tmp)
  end

  def teardown
    RunBlocks.reset!
    FileUtils.rm_rf(@tmp)
  end

  # Runs the parser quietly; returns [items, listing, log text].
  def run_owc(src = source)
    RunBlocks.source = src
    listing = {}
    out = StringIO.new
    $stdout = out
    items = DirectSources.owc_items(@fetcher, src, listing: listing)
    [items, listing, out.string]
  ensure
    $stdout = STDOUT
    RunBlocks.source = nil
  end

  def test_batches_extracted
    assert_equal 6, batches.size
    assert_equal [21, 63, 63, 63, 63, 39], batches.map { |b| b.split(",").size }
    assert batches.first.start_with?("103792,128995,128847,")
    assert_empty DirectSources.owc_more_pages("<html><body>no script</body></html>")
  end

  def test_items_parsed_and_skips
    items, listing, log = run_owc
    assert_equal ["#{HOST}/shop/specials", *batches.map { |b| batch_key(b) }], pages
    assert_includes log, "126 product cards, 15 kept" # 6 batches x the same 21 cards
    by_url = items.to_h { |it| [it[:store_url], it] }
    assert_equal 15, items.size, by_url.keys.inspect

    cable = by_url.fetch("https://#{HOST}/item/OWC/CBLTB5C0.3M/")
    assert_equal '0.3M (11.8") OWC Universal Thunderbolt Cable (80/120Gb/s)', cable[:title]
    assert_equal 16.88, cable[:price]
    assert_equal 19.99, cable[:compare_at]
    assert_equal "https://#{HOST}/images/_inventory_/300x300/OWCCBLTB5C0.3M.jpg", cable[:image]
    assert_includes cable[:highlights], "Price after OWC's instant rebate, taken off at checkout"
    assert_equal "OWC", cable[:brand_hint]
    assert_equal true, cable[:from_site]

    big = by_url.fetch("https://#{HOST}/item/OWC/TB38SRT144C/")
    assert_equal [7799.99, 10_299.99], [big[:price], big[:compare_at]]

    mac = items.find { |it| it[:title].start_with?("Mac mini") }
    assert_equal "https://#{HOST}/configure-my-mac/apple-mac-mini-apple-silicon-late-2020?sku=UAEI1HS7XXXXXXB", mac[:store_url]
    assert_equal "used", mac[:condition]
    assert_match(/Pre-owned\/used \(OWC grade: NICE!\): check the condition at OWC/, mac[:highlights].first)
    assert_equal "Mac mini 8-Core M1 16GB RAM, 2TB SSD, 8-Core GPU", mac[:title]

    # No was-price (ThunderBay 4, ThunderBay 8 kit, hub, stand, dock, miniStack) and cart-only price (Hyper): skipped.
    %w[OWC/TB3IVKIT000 OWC/TB38SRKIT0 Rain-Design/12031 OWC/TB3MDK5P OWC/T4MS9H06N00 Hyper/GN28NGRAY].each do |p|
      refute by_url.key?("https://#{HOST}/item/#{p}/"), p
    end
    assert_includes log, "not used: no was-price 30, price only in the cart 6"
    items.each do |it|
      assert_match(%r{\Ahttps://#{HOST}/(?:item/|configure-my-mac/[^?]+\?sku=\w+\z)}, it[:store_url])
      refute_includes it[:store_url], "afv="
      assert it[:compare_at] > it[:price]
    end
    # Full listing: every batch loaded, all 21 cards recorded for the re-check.
    assert_equal true, listing[:ok]
    assert_equal 21, listing[:products].size
    assert_nil listing[:products]["#{HOST}/item/owc/tb3ivkit000"][:why] # still on the page, price checked
    assert_equal "price only in the cart", listing[:products]["#{HOST}/item/hyper/gn28ngray"][:why]
  end

  def test_card_rules
    doc = batch1
    card = doc[/<div class="product-specials__view">.*?CBLTB5C0\.3M.*?catpathlink.*?<\/div>\s*<\/div>\s*<\/div>\s*<\/div>/m]
    refute_nil card
    variants = {
      "mail-in rebate price" => card.sub("After Instant Rebate", "After Mail-In Rebate"),
      "not in stock (sold out / backorder / pre-order)" => card.sub("Save $3.11 After Instant Rebate", "Backordered"),
      "no Add to Cart button" => card.sub(%r{<a href="/shop/add/[^>]*>Add to Cart</a>}, ""),
      "price only in the cart" => card.sub("Save $3.11 After Instant Rebate", "Add to cart for price"),
      "not hardware (software / license / gift card / service plan)" => card.sub("Universal Thunderbolt Cable (80/120Gb/s)</h3>", "SoftRAID XT License</h3>"),
      "no was-price" => card.sub(%r{<del[^>]*>\$19\.99</del>}, "")
    }
    variants.each do |why, html|
      skipped = Hash.new(0)
      r = DirectSources.owc_page(html, SPECIALS, source, skipped: skipped)
      assert_equal 1, r[:cards]
      assert_empty r[:items], why
      assert_equal({ why => 1 }, skipped, why)
    end
    assert_equal 1, DirectSources.owc_page(card, SPECIALS, source)[:items].size
  end

  def test_url_key_stable
    k = "eshop.macsales.com/item/owc/us4exp1m2"
    assert_equal k, DealTools.url_key("https://eshop.macsales.com/item/OWC/US4EXP1M2/")
    assert_equal k, DealTools.url_key("https://eshop.macsales.com/item/OWC/US4EXP1M2/?afv=specials&utm_source=x#top")
    assert_equal k, DealTools.url_key("http://eshop.macsales.com/item/owc/us4exp1m2")
    assert_equal "eshop.macsales.com/configure-my-mac/apple-mac-mini-apple-silicon-late-2020?sku=uaei1hs7xxxxxxb",
                 DealTools.url_key("https://eshop.macsales.com/configure-my-mac/apple-mac-mini-apple-silicon-late-2020?afv=x&sku=UAEI1HS7XXXXXXB")
    assert_equal "OWC", DealTools.store_name("https://eshop.macsales.com/item/OWC/US4EXP1M2/")
    assert_equal %w[us4exp1m2 owcus4exp1m2], DealTools.part_numbers(["US4EXP1M2", "OWCUS4EXP1M2", "BTO/CTO", "12031"])
  end

  def test_403_on_specials_page_stops
    OwcStub.routes["#{HOST}/shop/specials"] = [403, "<html><body>Forbidden</body></html>"]
    items, listing, log = run_owc
    assert_empty items
    assert_equal ["#{HOST}/shop/specials"], pages
    assert_equal 1, log.scan("blocked: HTTP 403 at #{SPECIALS}; skipping the rest of owc this run").size, log
    assert RunBlocks.source_blocked?("owc")
    assert_equal false, listing[:ok]
    # Nothing more to the host this run (robots.txt included).
    n = OwcStub.log.size
    assert @fetcher.fetch("https://#{HOST}/item/OWC/US4EXP1M2/", source).blocked
    assert_equal n, OwcStub.log.size
  end

  def test_403_on_batch_stops_further_batches
    OwcStub.routes[batch_key(batches[1])] = [429, "<html><body>Too Many Requests</body></html>"]
    items, listing, log = run_owc
    assert_equal ["#{HOST}/shop/specials", batch_key(batches[0]), batch_key(batches[1])], pages
    assert_equal 1, log.scan("blocked: HTTP 429 at https://#{batch_key(batches[1])}; skipping the rest of owc this run").size, log
    assert_equal 15, items.size # batch 1 was read before the block
    assert_equal false, listing[:ok]
  end

  def test_403_on_first_batch
    OwcStub.routes[batch_key(batches[0])] = [403, "<html><body>Forbidden</body></html>"]
    items, _listing, _log = run_owc
    assert_equal ["#{HOST}/shop/specials", batch_key(batches[0])], pages
    assert_empty items
  end

  def test_no_more_pages_and_batch_cap
    OwcStub.routes["#{HOST}/shop/specials"] = [200, specials.sub(/var morePages = \[.*?\];/m, "var morePages = [];")]
    items, listing, log = run_owc
    assert_empty items
    assert_equal ["#{HOST}/shop/specials"], pages
    assert_includes log, "no morePages batches on the page; stopping owc for this run"
    assert_equal false, listing[:ok]

    setup
    items, listing, log = run_owc(source("max_batches" => 2))
    assert_equal ["#{HOST}/shop/specials", batch_key(batches[0]), batch_key(batches[1])], pages
    assert_includes log, "reading the first 2 of 6 batches (max_batches)"
    assert_equal 15, items.size
    assert_equal false, listing[:ok] # not the full listing: no recheck_missing expiry
  end

  # ---------------------------------------------------- finder run ---
  class FakeSite
    attr_reader :log, :port, :routes

    def initialize(routes)
      @routes = routes
      @log = []
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { loop { serve(@server.accept) } }
    end

    def base = "http://127.0.0.1:#{@port}"

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve(sock)
      line = sock.gets.to_s
      nil while (h = sock.gets) && h != "\r\n"
      path = line.split[1].to_s
      @log << path
      status, body = path == "/robots.txt" ? [200, "User-agent: *\nAllow: /\n"] : (@routes[path] || [404, "<html><body>not found</body></html>"])
      type = path == "/robots.txt" ? "text/plain" : "text/html; charset=utf-8"
      sock.write("HTTP/1.1 #{status} X\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue StandardError
      nil
    ensure
      sock&.close
    end
  end

  def deal(root, file, fm)
    File.write(File.join(root, "_products", file), "#{fm.merge('type' => 'affiliate', 'expires' => Date.new(2099, 1, 1)).to_yaml}---\nTest deal.\n")
  end

  # The real finder with the owc source (as configured in deal_sources.yml,
  # pointed at a local server): the OWC Express 1M2 published from B&H at the
  # same price stays (part-number match), its listing price re-checks
  # published owc deals, and no /item/ page is requested.
  def test_finder_dedupe_and_recheck
    root = Dir.mktmpdir("cdeals-owc-finder")
    FileUtils.mkdir_p(%w[_data _products _deal_queue scripts].map { |d| File.join(root, d) })
    FileUtils.cp(File.join(REPO, "scripts/find_deals.rb"), File.join(root, "scripts"))
    FileUtils.cp_r(File.join(REPO, "scripts/lib"), File.join(root, "scripts"))
    FileUtils.cp(File.join(REPO, "_data/categories.yml"), File.join(root, "_data"))
    File.write(File.join(root, "_config.yml"), "amazon_tag: test-20\n")
    site = FakeSite.new({ "/shop/specials" => [200, specials] })
    batches.each { |ids| site.routes["/api/search/load-more/?view=specials&items=#{ids}"] = [200, batch1] }

    real = YAML.load_file(File.join(REPO, "_data/deal_sources.yml"))
    owc = real["sites"].find { |s| s["id"] == "owc" }
    refute_equal false, owc["enabled"]
    owc = owc.merge("urls" => ["#{site.base}/shop/specials"])
    cfg = real.slice("filters", "categories", "feed_categories", "fallback_category", "defaults", "skip_store_fetch_hosts")
              .merge("zenrows" => { "usage_file" => "scripts/state/zenrows_usage.json" },
                     "http" => { "user_agent" => "cDealsFinderTest/1.0", "open_timeout" => 2, "read_timeout" => 5,
                                 "min_delay_seconds" => 0, "respect_robots" => true, "robots_cache_dir" => nil },
                     "sites" => [owc], "official_sources" => real["sites"].select { |s| s["id"] == "impact-catalogs" })
    File.write(File.join(root, "_data/deal_sources.yml"), cfg.to_yaml)
    deal(root, "owc-express-1m2-usb4-external-ssd-enclosure.md",
         "title" => "OWC Express 1M2 USB4 External SSD Enclosure", "brand" => "OWC", "price" => 88.99, "compare_at" => 119.99,
         "store" => "B&H Photo", "source" => "bh-deals",
         "affiliate_url" => "https://www.bhphotovideo.com/c/product/1801760-REG/owc_owcus4exp1m2_express_1m2_portable_nvme.html")
    deal(root, "owc-go-dock.md", "title" => "OWC Thunderbolt Go Dock", "brand" => "OWC", "price" => 199.99, "store" => "OWC",
                                 "source" => "owc", "affiliate_url" => "#{site.base}/item/OWC/TB4DKG11P/")
    deal(root, "owc-gone.md", "title" => "OWC Something Gone", "price" => 50, "store" => "OWC", "source" => "owc",
                              "affiliate_url" => "#{site.base}/item/OWC/GONE123/")
    env = { "CDEALS_CACHE" => File.join(root, "cache"), "ZENROWS_API_KEY" => nil, "DEALS_DEEP" => nil }
    out, status = Open3.capture2e(env, RbConfig.ruby, File.join(root, "scripts/find_deals.rb"), "-v")
    puts out if ENV["VERBOSE"]
    assert status.success?, out

    assert_match(/skip \(same product cheaper or equal elsewhere\): OWC Express 1M2 DIY Portable/, out)
    queue = YAML.safe_load(File.read(File.join(root, "_deal_queue/queue.yml")), permitted_classes: [Date, Time])
    titles = queue.map { |e| e["title"] }
    refute(titles.any? { |t| t.include?("Express 1M2") }, titles.inspect)
    # The 4M2 enclosure and its SoftRAID bundle are different products (different part numbers).
    assert_equal 2, titles.count { |t| t.start_with?("OWC Express 4M2") }, titles.inspect
    e = queue.find { |x| x["title"].start_with?("OWC Express 4M2 USB4") }
    assert_equal ["OWC", "OWC", "Accessories", 178.99, 239.99], e.values_at("store", "brand", "category", "price", "compare_at")
    assert_equal "#{site.base}/item/OWC/US4EXP4M2/", e["affiliate_url"]
    mbp = queue.find { |x| x["title"].include?("MacBook Pro") }
    assert_equal "Laptops", mbp["category"]
    assert_includes mbp["highlights"].join(" "), "Pre-owned/used"
    # Cables / adapters (global exclude_keywords), over max_price, below min discount: not queued.
    refute(titles.any? { |t| t =~ /cable|ThunderBay|Mercury|Thunderbolt Hub/i }, titles.inspect)

    # Re-check: the Go Dock is $229.99 on the listing (> $199.99), GONE123 isn't on it.
    assert_match(/Re-checked published deals: matched 2, confirmed 0, now cheaper 0, expired 2/, out)
    assert_match(/^expired_reason: "listing price \$229\.99 > \$199\.99 \(owc, /, File.read(File.join(root, "_products/owc-go-dock.md")))
    assert_match(/^expired_reason: "not on the owc listing \(21 products, /, File.read(File.join(root, "_products/owc-gone.md")))
    assert_includes File.read(File.join(root, "_products/owc-express-1m2-usb4-external-ssd-enclosure.md")), "2099-01-01"

    assert(site.log.none? { |p| p.start_with?("/item/", "/configure-my-mac/", "/shop/add/") }, site.log.inspect)
    assert_includes out, "Blocked this run: none"
  ensure
    site&.stop
    FileUtils.rm_rf(root) if root
  end
end
