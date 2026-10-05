# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "date"
require "fileutils"
require "nokogiri"
require_relative "polite_http"

# One place that decides HOW a page is fetched for the deal finder.
#
#   plain   - PoliteHTTP: honest User-Agent, per-host delay, robots.txt checked.
#   zenrows - ZenRows API (https://www.zenrows.com), only for sources that set
#             `fetch: zenrows` or `fallback: zenrows` in _data/deal_sources.yml.
#
# Rules for ZenRows (see "zenrows:" in deal_sources.yml):
#   * robots.txt of the target site is checked first, same as a plain fetch.
#   * never used for a host that has an official source (API / feed) configured,
#     even a planned one that is still disabled. Exception: an official API
#     source marked zenrows_until_key: true blocks ZenRows only once its key is set.
#   * cheapest tier first: plain (free) -> js_render (5 credits) -> premium tiers
#     only when the source sets allow_premium: true. The tier that worked is
#     remembered per source so the next run starts there.
#   * a monthly credit cap (default 4500) is enforced from a small usage file
#     (scripts/state/zenrows_usage.json: counts only, never the key).
#   * no ZENROWS_API_KEY in the environment -> the source is skipped, not an error.
#   * the API key is never printed, logged or written; error text is scrubbed.
class Fetcher
  ZENROWS_ENDPOINT = "https://api.zenrows.com/v1/"
  TIER_CREDITS = { "plain" => 0, "js" => 5, "premium" => 10, "js_premium" => 25 }.freeze
  TIER_PARAMS = {
    "js" => { "js_render" => "true" },
    "premium" => { "premium_proxy" => "true" },
    "js_premium" => { "js_render" => "true", "premium_proxy" => "true" }
  }.freeze
  # Bodies that mean "blocked / bot wall", not content.
  WALL_RE = /captcha-delivery\.com|<title>\s*Client Challenge|px-captcha|\/blocked\?url=|areyouahuman|Access Denied<\/title>|cf-chl-|Attention Required! \| Cloudflare|Please enable JS and disable any ad blocker/i

  Result = Struct.new(:ok, :body, :url, :via, :credits, :error, keyword_init: true)

  attr_reader :http, :usage_stats

  def initialize(cfg, root:)
    @cfg = cfg
    @http = PoliteHTTP.new(cfg["http"] || {})
    zr = cfg["zenrows"] || {}
    @cap = (ENV["ZENROWS_MONTHLY_CAP"] || zr["monthly_credit_cap"] || 4500).to_i
    @usage_file = File.join(root, zr["usage_file"] || "scripts/state/zenrows_usage.json")
    @key = ENV["ZENROWS_API_KEY"].to_s.strip
    @month = Date.today.strftime("%Y-%m")
    @usage = load_usage
    @usage_stats = Hash.new(0)
    @official_hosts = official_hosts(cfg)
  end

  def zenrows_key? = !@key.empty?
  def credits_this_month = @usage.dig("months", @month, "credits").to_i
  def cap = @cap

  def official_host?(url)
    h = host_of(url)
    @official_hosts.any? { |o| h == o || h.end_with?(".#{o}") }
  end

  # Fetch a page for a source. Returns Result.
  def fetch(url, source, ok_if: nil)
    mode = source["fetch"].to_s
    fallback = source["fallback"].to_s == "zenrows"
    unless @http.allowed?(url)
      return Result.new(ok: false, url: url, via: "plain", credits: 0, error: "robots.txt disallows #{url}")
    end

    if mode != "zenrows"
      final, res = @http.follow(url)
      good = res&.ok? && !wall?(res.body) && (ok_if.nil? || ok_if.call(res.body))
      return Result.new(ok: true, body: res.body, url: final, via: "plain", credits: 0) if good
      err = res&.error || (res && wall?(res.body) ? "bot wall (HTTP #{res.status})" : "HTTP #{res&.status}#{res&.ok? ? ' but no usable content' : ''}")
      return Result.new(ok: false, url: url, via: "plain", credits: 0, error: err) unless fallback
    end
    zenrows(url, source, ok_if: ok_if)
  end

  def save_usage!
    FileUtils.mkdir_p(File.dirname(@usage_file))
    # Keep the last 12 months only.
    @usage["months"] = @usage["months"].sort.last(12).to_h
    File.write(@usage_file, JSON.pretty_generate(@usage) + "\n")
  end

  private

  def zenrows(url, source, ok_if:)
    sid = source["id"].to_s
    return Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: "ZenRows not used: #{host_of(url)} has an official source configured") if official_host?(url)
    return Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: "ZenRows skipped: ZENROWS_API_KEY is not set") unless zenrows_key?
    # robots.txt must actually have been read before credits are spent. Some
    # stores refuse direct connections from this machine; then robots.txt itself
    # is read through ZenRows (basic request, 1 credit; js_render, 5 credits, if
    # the host requires it; never premium proxies), cached 24h on disk.
    unless @http.robots_read?(url)
      robots_url = url.sub(%r{\A(https?://[^/]+).*\z}, '\\1/robots.txt')
      if credits_this_month + 1 > @cap
        return Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: "ZenRows monthly credit cap reached (#{credits_this_month}/#{@cap})")
      end
      status, body, credits, _err = zenrows_get(robots_url, {})
      record(sid, credits || (status.to_i.between?(200, 299) ? 1 : 0))
      # Some hosts are only reachable with js_render (5 credits); never premium proxies.
      if !status.to_i.between?(200, 299) && credits_this_month + 5 <= @cap
        status, body, credits, _err = zenrows_get(robots_url, TIER_PARAMS["js"])
        record(sid, credits || (status.to_i.between?(200, 299) ? 5 : 0))
        body = Nokogiri::HTML(body).text if body.to_s.include?("<html") && defined?(Nokogiri)
      end
      @http.seed_robots(url, body) if status.to_i.between?(200, 299) && body =~ /user-agent/i
      unless @http.robots_read?(url)
        return Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: "robots.txt for #{host_of(url)} could not be read; not fetching")
      end
      unless @http.allowed?(url)
        return Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: "robots.txt disallows #{url}")
      end
    end

    zr = source["zenrows"] || {}
    tiers = %w[plain js]
    tiers += %w[premium js_premium] if zr["allow_premium"] == true
    tiers -= ["plain"] if source["fetch"].to_s != "zenrows" # plain already tried
    remembered = @usage.dig("tiers", sid)
    tiers = tiers.drop_while { |t| t != remembered } if remembered && tiers.include?(remembered)
    last_err = nil
    tiers.each do |tier|
      if tier == "plain"
        final, res = @http.follow(url)
        if res&.ok? && !wall?(res.body) && (ok_if.nil? || ok_if.call(res.body))
          remember_tier(sid, tier)
          return Result.new(ok: true, body: res.body, url: final, via: "plain", credits: 0)
        end
        last_err = "plain fetch had no usable content"
        next
      end
      cost = TIER_CREDITS[tier]
      if credits_this_month + cost > @cap
        return Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: "ZenRows monthly credit cap reached (#{credits_this_month}/#{@cap})")
      end
      params = TIER_PARAMS[tier].dup
      params["wait_for"] = zr["wait_for"] if zr["wait_for"] && params["js_render"]
      params["wait"] = zr["wait"].to_s if zr["wait"] && params["js_render"]
      params["js_instructions"] = JSON.generate(zr["js_instructions"]) if zr["js_instructions"] && params["js_render"]
      status, body, credits, err = zenrows_get(url, params)
      record(sid, credits || (status.to_i.between?(200, 299) ? cost : 0))
      if status.to_i.between?(200, 299) && !wall?(body) && (ok_if.nil? || ok_if.call(body))
        remember_tier(sid, tier)
        return Result.new(ok: true, body: body, url: url, via: "zenrows:#{tier}", credits: credits || cost)
      end
      last_err = err || "ZenRows #{tier}: HTTP #{status}#{status.to_i.between?(200, 299) ? ' but no usable content' : ''}"
    end
    Result.new(ok: false, url: url, via: "zenrows", credits: 0, error: last_err)
  end

  def zenrows_get(url, params)
    q = URI.encode_www_form({ "apikey" => @key, "url" => url }.merge(params))
    u = URI("#{ZENROWS_ENDPOINT}?#{q}")
    http = Net::HTTP.new(u.host, u.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 180
    res = http.request(Net::HTTP::Get.new(u.request_uri, "Accept-Encoding" => "identity"))
    @usage_stats[:requests] += 1
    credits = res["x-request-credits"]&.to_i
    body = res.body.to_s.dup.force_encoding("UTF-8")
    body = body.encode("UTF-8", invalid: :replace, undef: :replace) unless body.valid_encoding?
    err = res.code.to_i.between?(200, 299) ? nil : "ZenRows HTTP #{res.code}: #{scrub(body[0, 160])}"
    [res.code.to_i, body, credits, err]
  rescue StandardError => e
    [0, "", nil, "ZenRows error: #{scrub("#{e.class}: #{e.message}")[0, 160]}"]
  end

  def scrub(text) = @key.empty? ? text.to_s : text.to_s.gsub(@key, "[redacted]")

  def wall?(body) = body.to_s.size < 60_000 && WALL_RE.match?(body.to_s)

  def record(sid, credits)
    m = (@usage["months"][@month] ||= { "credits" => 0, "requests" => 0, "by_source" => {} })
    m["credits"] += credits.to_i
    m["requests"] += 1
    m["by_source"][sid] = m["by_source"][sid].to_i + credits.to_i
    @usage_stats[:credits] += credits.to_i
  end

  def remember_tier(sid, tier)
    (@usage["tiers"] ||= {})[sid] = tier
  end

  def load_usage
    data = File.exist?(@usage_file) ? JSON.parse(File.read(@usage_file)) : {}
    data["months"] ||= {}
    data["tiers"] ||= {}
    data.slice("months", "tiers")
  rescue JSON::ParserError
    { "months" => {}, "tiers" => {} }
  end

  def host_of(url)
    URI.parse(url).host.to_s.downcase.sub(/\Awww\./, "")
  rescue URI::InvalidURIError
    ""
  end

  # Hosts covered by an official source (official_for: [...]), INCLUDING
  # planned/disabled ones: once a store has an official API or feed in the
  # config, ZenRows is never used for it.
  # One exception: an official API source with `zenrows_until_key: true` only
  # blocks ZenRows once its key (env:) is set. Until then a separate
  # `fetch: zenrows` source for that store may run (Best Buy: top-deals pages
  # until BESTBUY_API_KEY exists, then the API takes over).
  def official_hosts(cfg)
    Array(cfg["sites"]).chain(Array(cfg["feeds"]), Array(cfg["official_sources"]))
                       .reject { |s| s["zenrows_until_key"] == true && Array(s["env"]).any? { |k| ENV[k].to_s.strip.empty? } }
                       .flat_map { |s| Array(s["official_for"]) }
                       .map { |h| h.to_s.downcase.sub(/\Awww\./, "") }.uniq
  end
end
