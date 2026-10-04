# frozen_string_literal: true

require "net/http"
require "uri"

# Small HTTP client for the deal finder: one User-Agent, timeouts, a minimum
# delay per host (or the site's robots.txt Crawl-delay), robots.txt checks,
# and manual redirect handling so tracking hops can be inspected.
class PoliteHTTP
  Response = Struct.new(:status, :body, :location, :url, :error, :content_type, keyword_init: true) do
    def ok? = status.to_i.between?(200, 299)
    def redirect? = status.to_i.between?(300, 399) && location
  end

  attr_reader :stats

  def initialize(opts = {})
    @ua = opts["user_agent"] || "cDealsFinder/1.0"
    @open_timeout = (opts["open_timeout"] || 8).to_i
    @read_timeout = (opts["read_timeout"] || 20).to_i
    @min_delay = (opts["min_delay_seconds"] || 2).to_f
    @respect_robots = opts.fetch("respect_robots", true)
    @max_bytes = 3_000_000
    @last = {}
    @robots = {}
    @stats = Hash.new(0)
  end

  def allowed?(url)
    return true unless @respect_robots
    u = URI.parse(url)
    rules = robots_for(u)
    path = u.request_uri
    allow = rules[:allow].select { |p| match_rule?(p, path) }.map(&:length).max || -1
    disallow = rules[:disallow].select { |p| match_rule?(p, path) }.map(&:length).max || -1
    disallow <= allow || disallow.negative?
  rescue URI::InvalidURIError
    false
  end

  # One request, no redirect following.
  def get(url, accept: "*/*", robots: true)
    u = URI.parse(url)
    if robots && !allowed?(url)
      @stats[:robots_blocked] += 1
      return Response.new(status: 0, url: url, error: "robots.txt disallows #{u.host}#{u.path}")
    end
    wait_for(u.host)
    @stats[:requests] += 1
    http = Net::HTTP.new(u.host, u.port)
    http.use_ssl = u.scheme == "https"
    http.open_timeout = @open_timeout
    http.read_timeout = @read_timeout
    req = Net::HTTP::Get.new(u.request_uri, "User-Agent" => @ua, "Accept" => accept, "Accept-Language" => "en-US,en;q=0.8")
    res = http.request(req)
    body = res.body.to_s
    body = body[0, @max_bytes] if body.bytesize > @max_bytes
    unless res["content-type"].to_s.start_with?("image/")
      body = body.dup.force_encoding("UTF-8")
      body = body.encode("UTF-8", invalid: :replace, undef: :replace) unless body.valid_encoding?
    end
    loc = res["location"] && URI.join(url, res["location"].strip).to_s
    Response.new(status: res.code.to_i, body: body, location: loc, url: url, content_type: res["content-type"].to_s)
  rescue StandardError => e
    @stats[:errors] += 1
    Response.new(status: 0, url: url, error: "#{e.class}: #{e.message}"[0, 160])
  end

  # Follow redirects; yields each hop URL so the caller can stop early.
  def follow(url, max: 8, robots: true)
    current = url
    max.times do
      return [current, nil] if block_given? && yield(current)
      res = get(current, robots: robots)
      return [current, res] unless res.redirect?
      current = res.location
    end
    [current, Response.new(status: 0, url: current, error: "too many redirects")]
  end

  private

  def match_rule?(rule, path)
    return false if rule.empty?
    re = Regexp.new("\\A" + Regexp.escape(rule).gsub("\\*", ".*").sub(/\\\$\z/, "\\z"))
    re.match?(path)
  end

  def robots_for(u)
    key = "#{u.scheme}://#{u.host}"
    @robots[key] ||= begin
      rules = { allow: [], disallow: [], delay: nil }
      txt = raw_get("#{key}/robots.txt")
      applies = false
      seen_rule = false
      txt.to_s.each_line do |line|
        line = line.sub(/#.*/, "").strip
        next if line.empty?
        field, value = line.split(":", 2).map { |x| x.to_s.strip }
        case field.downcase
        when "user-agent"
          applies = false if seen_rule
          seen_rule = false
          applies ||= value == "*" || @ua.downcase.include?(value.downcase)
        when "allow" then (seen_rule = true; rules[:allow] << value if applies)
        when "disallow" then (seen_rule = true; rules[:disallow] << value if applies)
        when "crawl-delay" then rules[:delay] = value.to_f if applies
        end
      end
      rules
    end
  end

  def raw_get(url)
    u = URI.parse(url)
    wait_for(u.host)
    http = Net::HTTP.new(u.host, u.port)
    http.use_ssl = u.scheme == "https"
    http.open_timeout = @open_timeout
    http.read_timeout = @read_timeout
    res = http.request(Net::HTTP::Get.new(u.request_uri, "User-Agent" => @ua))
    res.is_a?(Net::HTTPSuccess) ? res.body.to_s : ""
  rescue StandardError
    ""
  end

  def wait_for(host)
    delay = [@min_delay, @robots.find { |k, _| k.end_with?("//#{host}") }&.last&.dig(:delay).to_f].max
    if (t = @last[host]) && (gap = delay - (Time.now - t)).positive?
      sleep(gap)
    end
    @last[host] = Time.now
  end
end
