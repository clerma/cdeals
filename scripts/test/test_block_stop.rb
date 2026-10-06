# frozen_string_literal: true

# Offline test of stop-on-block (scripts/lib/run_blocks.rb). Runs the real
# scripts/find_deals.rb from a temporary copy of the repo layout (own
# _data/deal_sources.yml, _products/, _deal_queue/) against small HTTP servers
# on 127.0.0.1, so no real site is contacted and nothing in the repo changes.
#
#   BUNDLE_WITH=deals bundle exec ruby scripts/test/test_block_stop.rb

require "rbconfig"
begin
  require "minitest/autorun"
rescue LoadError
  # Under `bundle exec` the Gemfile hides Ruby's bundled minitest gem (the test
  # itself needs only stdlib + minitest; the finder runs bundled in a subprocess).
  lib = [File.join(RbConfig::CONFIG["rubylibprefix"], "gems", RbConfig::CONFIG["ruby_version"]), Gem.default_dir]
        .flat_map { |d| Dir[File.join(d, "gems", "minitest-*", "lib")] }.max or raise
  $LOAD_PATH.unshift(lib)
  require "minitest/autorun"
end
require "socket"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "open3"

class TestBlockStop < Minitest::Test
  REPO = File.expand_path("../..", __dir__)

  # Tiny HTTP server: routes path => [status, body], logs every request path.
  # A permissive robots.txt is always served.
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
    def pages = @log.reject { |p| p == "/robots.txt" }

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

  # A B&H-style listing page (parser: bh). items: [[product url, price, original price, model]]
  def bh_page(items)
    json = items.map do |url, price, was, model|
      { itemKey: model, core: { shortDescription: "Acme #{model} 15.6-inch Laptop", detailsUrl: url },
        priceInfo: { showPrice: true, price: price, strikethroughPrice: was, addToCartButton: "ADD_TO_CART" },
        stockInfo: { status: "IN_STOCK" }, mainImage: { default: { url: "#{url}.jpg" } } }
    end
    "<html><head><title>Deals</title></head><body>#{'<p>listing</p>' * 2000}<script>window.x = {\"items\":#{JSON.generate(json)}};</script></body></html>"
  end

  def wall_page
    "<html><head><title>Access Denied</title></head><body><div id=\"px-captcha\"></div>Press and hold</body></html>"
  end

  def source(id, urls, pages: 1)
    { "id" => id, "name" => id, "store" => "Acme Store", "fetch" => "plain", "fallback" => "none", "parser" => "bh",
      "pages" => pages, "page_format" => "{url}/pn/{n}", "max_candidates" => 10, "urls" => urls }
  end

  def deal(file, url, price, src)
    File.write(File.join(@root, "_products", file), <<~MD)
      ---
      title: "#{file}"
      type: affiliate
      store: Acme Store
      price: #{price}
      affiliate_url: #{url}
      source: #{src}
      expires: 2099-01-01
      ---
      Test deal.
    MD
  end

  def products(file) = File.read(File.join(@root, "_products", file))

  def setup
    @root = Dir.mktmpdir("cdeals-block-test")
    FileUtils.mkdir_p(%w[_data _products _deal_queue scripts].map { |d| File.join(@root, d) })
    FileUtils.cp(File.join(REPO, "scripts/find_deals.rb"), File.join(@root, "scripts"))
    FileUtils.cp_r(File.join(REPO, "scripts/lib"), File.join(@root, "scripts"))
    FileUtils.cp(File.join(REPO, "_data/categories.yml"), File.join(@root, "_data"))
    File.write(File.join(@root, "_config.yml"), "amazon_tag: test-20\n")
    @sites = []
  end

  def teardown
    @sites.each(&:stop)
    FileUtils.rm_rf(@root)
  end

  def site(routes) = FakeSite.new(routes).tap { |s| @sites << s }

  # Writes the config and runs the finder (not a dry run: the temp _products
  # files show what the re-check would change). Returns its output.
  def run_finder(sources)
    cfg = {
      "filters" => { "min_discount_pct" => 5, "min_price" => 1, "max_price" => 5000, "require_category" => true },
      "categories" => { "Laptops" => ["laptop"] },
      "fallback_category" => "Accessories",
      "defaults" => { "expires_days" => 7, "max_candidates_per_run" => 50, "max_candidates_per_source" => 10 },
      "zenrows" => { "usage_file" => "scripts/state/zenrows_usage.json" },
      "http" => { "user_agent" => "cDealsFinderTest/1.0", "open_timeout" => 2, "read_timeout" => 5,
                  "min_delay_seconds" => 0, "respect_robots" => true, "robots_cache_dir" => nil },
      "skip_store_fetch_hosts" => [],
      "sites" => sources
    }
    File.write(File.join(@root, "_data/deal_sources.yml"), cfg.to_yaml)
    env = { "CDEALS_CACHE" => File.join(@root, "cache"), "ZENROWS_API_KEY" => nil, "DEALS_DEEP" => nil }
    out, status = Open3.capture2e(env, RbConfig.ruby, File.join(@root, "scripts/find_deals.rb"))
    puts out if ENV["VERBOSE"]
    assert status.success?, out
    out
  end

  # 403 on the first URL: nothing else from that source or host; the second
  # source on the host makes no request; their published deals aren't re-checked.
  def test_403_stops_source_and_host
    other = site({})
    other.routes["/c1"] = [200, bh_page([["#{other.base}/p/x", 150, 200, "X100"], ["#{other.base}/p/c", 130, 200, "C100"]])]
    blocked = site("/a1" => [403, "<html><body>Forbidden</body></html>"])
    %w[/a1/pn/2 /a1/pn/3 /a2 /a2/pn/2 /a2/pn/3 /a3 /b1].each_with_index do |path, i|
      blocked.routes[path] = [200, bh_page([["#{blocked.base}/p/#{i}", 50, 100, "B#{i}00"]])]
    end
    deal("deal-a.md", "#{other.base}/p/x", 100, "blk-a")   # its source is blocked: listed higher at ctl-c, still not expired
    deal("deal-b.md", "#{blocked.base}/p/b", 100, "blk-b") # source skipped because its host is blocked
    deal("deal-c.md", "#{other.base}/p/c", 100, "ctl-c")   # control: re-checked and expired as before
    before = %w[deal-a.md deal-b.md].to_h { |f| [f, products(f)] }

    out = run_finder([source("blk-a", %W[#{blocked.base}/a1 #{blocked.base}/a2 #{blocked.base}/a3], pages: 3),
                      source("blk-b", ["#{blocked.base}/b1"]), source("ctl-c", ["#{other.base}/c1"])])

    assert_equal ["/a1"], blocked.pages, out
    assert_equal 1, out.scan("blocked: HTTP 403 at #{blocked.base}/a1; skipping the rest of blk-a this run").size, out
    assert_match(/skipped: 127\.0\.0\.1:#{blocked.port} was blocked earlier this run \(blk-a, HTTP 403\); no requests/, out)
    assert_includes other.pages, "/c1"
    before.each { |f, text| assert_equal text, products(f), "#{f} must not change" }
    assert_match(/^expires: \d{4}-\d\d-\d\d$/, products("deal-c.md"))
    refute_includes products("deal-c.md"), "2099-01-01"
    assert_match(/Re-check skipped 2 published deals whose source was blocked this run \(blk-a 1, blk-b 1\)/, out)
    assert_includes out, "Blocked this run: blk-a (HTTP 403, 127.0.0.1:#{blocked.port}), blk-b (host blocked, 127.0.0.1:#{blocked.port})"
  end

  # 429 after a good page: items read before it may be queued, but no more
  # requests (pages, enrichment) and they are no evidence for other deals.
  def test_429_after_items_drops_evidence
    store = site({})
    blocked = site("/a1" => [200, bh_page([["#{store.base}/p/y", 150, 200, "Y100"], ["#{store.base}/p/n", 60, 100, "N100"]])],
                   "/a2" => [429, "<html><body>Too Many Requests</body></html>"],
                   "/a3" => [200, bh_page([])])
    deal("deal-y.md", "#{store.base}/p/y", 100, "not-run")
    deal("deal-a.md", "#{store.base}/p/a", 100, "blk-a")
    before = %w[deal-y.md deal-a.md].to_h { |f| [f, products(f)] }

    out = run_finder([source("blk-a", %W[#{blocked.base}/a1 #{blocked.base}/a2 #{blocked.base}/a3])])

    assert_equal ["/a1", "/a2"], blocked.pages, out
    assert_empty store.log, "no enrichment / store pages for a blocked source:\n#{out}"
    assert_equal 1, out.scan("blocked: HTTP 429 at #{blocked.base}/a2; skipping the rest of blk-a this run").size, out
    before.each { |f, text| assert_equal text, products(f), "#{f} must not change" }
    assert_match(/Re-checked published deals: matched 0, confirmed 0, now cheaper 0, expired 0/, out)
    assert_match(/Re-check skipped 1 published deals whose source was blocked this run \(blk-a 1\)/, out)
    assert_match(/New candidates: 1\b/, out) # N100 from the page read before the 429
    assert_includes out, "Blocked this run: blk-a (HTTP 429, 127.0.0.1:#{blocked.port})"
  end

  # 200 with a captcha / bot-wall body is a block too.
  def test_bot_wall_body
    blocked = site("/a1" => [200, wall_page], "/a2" => [200, bh_page([])])
    out = run_finder([source("blk-a", %W[#{blocked.base}/a1 #{blocked.base}/a2]), source("blk-b", ["#{blocked.base}/b1"])])
    assert_equal ["/a1"], blocked.pages, out
    assert_equal 1, out.scan("blocked: bot wall (HTTP 200) at #{blocked.base}/a1; skipping the rest of blk-a this run").size, out
    assert_includes out, "Blocked this run: blk-a (bot wall (HTTP 200), 127.0.0.1:#{blocked.port}), blk-b (host blocked, 127.0.0.1:#{blocked.port})"
  end

  # 404 is not a block: the next URL is still read.
  def test_404_is_not_a_block
    s = site("/a2" => [200, bh_page([])])
    out = run_finder([source("ok-a", %W[#{s.base}/a1 #{s.base}/a2])])
    assert_equal ["/a1", "/a2"], s.pages, out
    assert_includes out, "Blocked this run: none"
  end
end
