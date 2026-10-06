# frozen_string_literal: true

# Offline test of the woot-api source (DirectSources.woot_api_items, Woot
# Developer API). Saved feed pages in scripts/test/fixtures/woot/ (trimmed
# answers of GET developer.woot.com/feed/Electronics and /feed/Computers).
# Net::HTTP is stubbed (developer.woot.com is never contacted) and a fake key
# is used; the real WOOT_API_KEY is never read here.
#
#   BUNDLE_WITH=deals bundle exec ruby scripts/test/test_woot_api.rb

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
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../lib/fetcher"
require_relative "../lib/direct_sources"

# Net::HTTP answers from WootStub.routes ("host/path?query" => [status, body]
# or an exception to raise); every request is logged with its headers.
# Unknown URLs: 404.
module WootStub
  class << self
    attr_accessor :routes, :log, :headers
  end

  def request(req, *)
    key = "#{address}#{req.path}"
    WootStub.log << key
    WootStub.headers << req.to_hash.transform_values(&:first)
    status, body = WootStub.routes[key] || [404, '{"Message":"not found"}']
    raise status if status.is_a?(Exception)
    res = Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "X")
    res["content-type"] = "application/json"
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    res
  end
end
Net::HTTP.prepend(WootStub)

class TestWootApi < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  FIX = File.join(__dir__, "fixtures", "woot")
  HOST = "developer.woot.com"
  KEY_ENV = "WOOT_TEST_KEY"
  KEY = "TESTKEY_DO_NOT_LEAK"
  NOW = Time.utc(2026, 10, 6, 17, 0)

  def feed(name) = JSON.parse(File.read(File.join(FIX, "sample-feed-#{name}.json")))
  def page_key(feed, n) = "#{HOST}/feed/#{feed}?page=#{n}"
  def config = YAML.load_file(File.join(REPO, "_data", "deal_sources.yml"))
  def real_source = config["sites"].find { |s| s["id"] == "woot-api" }

  # The configured source, with the fake key's env var and no delay.
  def source(extra = {})
    real_source.merge("env" => [KEY_ENV], "delay_seconds" => 0, "max_pages_per_feed" => 1).merge(extra)
  end

  def setup
    WootStub.log = []
    WootStub.headers = []
    WootStub.routes = {
      page_key("Electronics", 1) => [200, JSON.generate(feed("electronics"))],
      page_key("Computers", 1) => [200, JSON.generate(feed("computers"))]
    }
    @env_key = ENV[KEY_ENV]
    ENV[KEY_ENV] = KEY
    @deep = ENV.delete("DEALS_DEEP")
    RunBlocks.reset!
    @tmp = Dir.mktmpdir("cdeals-woot-test")
    @fetcher = Fetcher.new({ "http" => { "user_agent" => "cDealsFinderTest/1.0", "min_delay_seconds" => 0, "robots_cache_dir" => nil },
                             "zenrows" => { "usage_file" => "usage.json" } }, root: @tmp)
    @logs = []
  end

  def teardown
    # Every test: the key is never in anything that was logged.
    @logs.each { |l| refute_includes l, KEY }
    ENV[KEY_ENV] = @env_key
    ENV["DEALS_DEEP"] = @deep if @deep
    RunBlocks.reset!
    FileUtils.rm_rf(@tmp)
  end

  # Runs the parser quietly; returns [items, log text].
  def run_woot(src = source)
    RunBlocks.source = src
    out = StringIO.new
    $stdout = out
    items = DirectSources.woot_api_items(@fetcher, src, now: NOW)
    [items, out.string]
  ensure
    $stdout = STDOUT
    RunBlocks.source = nil
    @logs << out.string
  end

  def test_config
    s = real_source
    assert s, "woot-api is in sites:"
    refute_equal false, s["enabled"]
    assert_equal "api", s["fetch"]
    assert_equal ["WOOT_API_KEY"], s["env"]
    assert_equal ["woot.com"], s["official_for"]
    assert_equal %w[Electronics Computers], s["feeds"]
    assert_equal :woot_api_items, DirectSources::PARSERS["woot_api"]
    refute_includes DirectSources::PLANNED, "woot_api"
    html = config["sites"].find { |x| x["id"] == "woot" }
    assert_equal ["WOOT_API_KEY"], html["unless_env"]
    assert_equal "woot", html["parser"]
  end

  def test_items_from_fixtures
    items, log = run_woot
    assert_equal [page_key("Electronics", 1), page_key("Computers", 1)], WootStub.log
    WootStub.headers.each do |h|
      assert_equal KEY, h["x-api-key"]
      assert_equal "application/json", h["accept"]
      assert_equal "cDealsFinderTest/1.0", h["user-agent"]
    end
    assert_includes log, "Electronics page 1 of 9: 5 offers"
    assert_includes log, "Computers page 1 of 6: 5 offers"
    assert_includes log, "10 offers, 5 kept"
    assert_includes log, "variant price range 1"
    assert_includes log, "no was-price 1"
    assert_includes log, "variant list price range 1"
    assert_includes log, "title_exclude 1"
    assert_includes log, "software / subscription / gift card 1"

    by_url = items.to_h { |it| [it[:store_url], it] }
    assert_equal 5, items.size, by_url.keys.inspect
    # Feeds in turn: Electronics, Computers, Computers, ...
    assert_equal "https://electronics.woot.com/offers/new-jbl-flip-6-portable-ip67-waterproof-speaker", items[0][:store_url]
    assert_equal "https://computers.woot.com/offers/belkin-thunderbolt-3-dock-mini-hd-14", items[1][:store_url]

    jbl = items[0]
    assert_equal "JBL Flip 6 Portable IP67 Waterproof Speaker", jbl[:title]
    assert_equal 84.95, jbl[:price]
    assert_equal 129.95, jbl[:compare_at]
    assert_equal "https://d3gqasl9vmjfd8.cloudfront.net/2b55f1c3-e809-46c3-b5fd-73f2a22213f8.jpg", jbl[:image]
    assert_equal jbl[:store_url], jbl[:link]
    assert_equal "Portable Audio", jbl[:feed_category]
    assert_equal Date.new(2026, 10, 9), jbl[:expires] # 2026-10-10T04:59Z = Oct 9, 11:59 pm Chicago
    assert_equal "Woot", jbl[:store_hint]
    assert jbl[:from_site]
    assert_nil jbl[:condition]
    assert_empty jbl[:highlights]

    items.each do |it|
      %i[title price compare_at store_url image].each { |k| refute_nil it[k], "#{k} of #{it[:title]}" }
      assert it[:compare_at] > it[:price]
      assert_match %r{\Ahttps://(?:electronics|computers)\.woot\.com/offers/[^?#]+\z}, it[:store_url]
    end
    titles = items.map { |it| it[:title] }
    assert_includes titles, "HyperDrive iPad USB-C Hub"
    refute(titles.any? { |t| t =~ /fire tv|solo loop|malwarebytes/i }, titles.inspect)
  end

  def test_skip_rules_and_url_cleaning
    jbl = feed("electronics")["Items"].first
    o = ->(**h) { jbl.merge(h.transform_keys(&:to_s)) }
    offers = [
      o.call(Title: "Sold Out Speaker", Url: "https://electronics.woot.com/offers/sold-out", IsSoldOut: true),
      o.call(Title: "App Speaker", Url: "https://electronics.woot.com/offers/app-only", IsAvailableOnMobileAppOnly: true),
      o.call(Title: "No Photo Speaker", Url: "https://electronics.woot.com/offers/no-photo", Photo: nil),
      o.call(Title: "No Url Speaker", Url: nil),
      o.call(Title: "Elsewhere Speaker", Url: "https://example.com/offers/elsewhere"),
      o.call(Title: "Snack Box Speaker", Url: "https://home.woot.com/offers/snacks", Categories: ["GROCERY", "GROCERY/Snack Foods"]),
      o.call(Title: "Kitchen Sellout Speaker", Url: "https://sellout.woot.com/offers/kitchen", Categories: ["Sellout", "Sellout/Home & Kitchen"]),
      o.call(Title: "Office Software Suite", Url: "https://computers.woot.com/offers/office", Categories: ["PC", "PC/Other"]),
      o.call(Title: "Streaming Gift Card $50", Url: "https://electronics.woot.com/offers/gift"),
      o.call(Title: "No List Speaker", Url: "https://electronics.woot.com/offers/no-list", ListPrice: nil),
      o.call(Title: "Same List Speaker", Url: "https://electronics.woot.com/offers/same-list", ListPrice: { "Minimum" => 84.95, "Maximum" => 84.95 }),
      o.call(Title: "Range Speaker", Url: "https://electronics.woot.com/offers/range", SalePrice: { "Minimum" => 59.99, "Maximum" => 84.95 }),
      o.call(Title: "Ended Speaker", Url: "https://electronics.woot.com/offers/ended", EndDate: "2026-10-01T05:00:00+00:00"),
      o.call(Title: "(NEW) Tracked Speaker", Url: "https://electronics.woot.com/offers/tracked-speaker?utm_source=feed&utm_medium=api&ref=w#top"),
      o.call(Title: "(REFURBISHED) Sony WH-1000XM5 Headphones", Url: "https://Electronics.Woot.com/offers/sony-wh-1000xm5-refurb",
             Condition: "Factory Reconditioned", Categories: ["Sellout", "Sellout/Electronics"]),
      o.call(Title: "Bose QuietComfort Earbuds", Url: "https://electronics.woot.com/offers/bose-qc", Condition: "New - International Version")
    ]
    skipped = Hash.new(0)
    items = DirectSources.woot_api_page(offers, source, skipped: skipped, now: NOW)
    assert_equal({ "sold out" => 1, "mobile app only" => 1, "no photo" => 1, "no offer URL" => 2, "not a tech category" => 2,
                   "software / subscription / gift card" => 2, "no was-price" => 2, "variant price range" => 1, "ended" => 1 }, skipped)
    assert_equal 3, items.size, items.map { |i| i[:title] }.inspect

    tracked, refurb, intl = items
    assert_equal "Tracked Speaker", tracked[:title]
    assert_equal "https://electronics.woot.com/offers/tracked-speaker", tracked[:store_url]
    assert_equal "electronics.woot.com/offers/tracked-speaker",
                 DealTools.url_key("https://electronics.woot.com/offers/Tracked-Speaker/?utm_source=x&ref=y")

    assert_equal "(REFURBISHED) Sony WH-1000XM5 Headphones", refurb[:title]
    assert_equal "https://electronics.woot.com/offers/sony-wh-1000xm5-refurb", refurb[:store_url]
    assert_equal "used", refurb[:condition]
    assert_equal ["Refurbished, open-box or used (Woot: Factory Reconditioned): check the condition notes at Woot"], refurb[:highlights]
    assert_equal "Electronics", refurb[:feed_category]

    assert_nil intl[:condition]
    assert_equal ["International version (per Woot)"], intl[:highlights]
  end

  def test_pages_and_deep
    WootStub.routes[page_key("Electronics", 2)] = [200, JSON.generate(feed("electronics").merge("Items" => []))]
    WootStub.routes[page_key("Computers", 1)] = [200, JSON.generate(feed("computers").merge("TotalPages" => 1))]
    run_woot(source("max_pages_per_feed" => 3))
    # Electronics: page 2 is empty -> stop; Computers: TotalPages 1 -> stop.
    assert_equal [page_key("Electronics", 1), page_key("Electronics", 2), page_key("Computers", 1)], WootStub.log

    WootStub.log.clear
    ENV["DEALS_DEEP"] = "1"
    WootStub.routes[page_key("Electronics", 2)] = [200, JSON.generate(feed("electronics"))]
    run_woot(source("max_pages_per_feed" => 1, "deep_max_pages_per_feed" => 3))
    assert_equal [1, 2, 3].map { |n| page_key("Electronics", n) } + [page_key("Computers", 1)], WootStub.log
  ensure
    ENV.delete("DEALS_DEEP")
  end

  def test_403_stops_the_source
    WootStub.routes[page_key("Electronics", 1)] = [403, '{"Message":"Forbidden"}']
    items, log = run_woot(source("max_pages_per_feed" => 3))
    assert_empty items
    assert_equal [page_key("Electronics", 1)], WootStub.log, "no request after the 403"
    assert RunBlocks.source_blocked?("woot-api")
    assert_equal 1, log.scan("blocked: HTTP 403").size
    assert_includes log, "skipping the rest of woot-api this run"
  end

  def test_429_after_a_good_page_keeps_earlier_items
    WootStub.routes[page_key("Electronics", 2)] = [429, '{"Message":"Too Many Requests"}']
    items, log = run_woot(source("max_pages_per_feed" => 3))
    assert_equal [page_key("Electronics", 1), page_key("Electronics", 2)], WootStub.log
    assert RunBlocks.source_blocked?("woot-api")
    assert_includes log, "blocked: HTTP 429"
    assert_equal 1, items.size
  end

  def test_key_never_logged
    # Errors that echo the key back must be redacted.
    WootStub.routes[page_key("Electronics", 1)] = [500, %({"Message":"bad key #{KEY}"})]
    WootStub.routes[page_key("Computers", 1)] = [IOError.new("connection reset (x-api-key: #{KEY})"), nil]
    items, log = run_woot
    assert_empty items
    assert_includes log, "Woot API HTTP 500"
    assert_includes log, "Woot API error: IOError: connection reset (x-api-key: [redacted])"
    refute_includes log, KEY
    assert_equal 2, WootStub.log.size
    WootStub.log.each { |u| refute_includes u, KEY } # the key is a header, never in the URL
  end

  def test_no_key_no_requests
    ENV[KEY_ENV] = ""
    items, = run_woot
    assert_empty items
    assert_empty WootStub.log
  end
end
