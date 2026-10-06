# frozen_string_literal: true

require "uri"

# Stop-on-block for one run of the deal finder (in memory only, nothing is
# saved). A request answered with HTTP 403, HTTP 429, a challenge / bot-wall
# page or a redirect to a block page (/blocked, /areyouahuman, captcha,
# dead-end) blocks:
#   * its host, for every source, for the rest of the run;
#   * the source being read (RunBlocks.source = ...), when the host is one of
#     the source's own (same site as its configured URLs). A blocked source
#     makes no more requests of any kind this run (pages, detail pages, store
#     pages, enrichment, store-link resolution) and its items don't count in
#     the re-check of published deals.
# 404 / 500 / timeouts and robots.txt disallows are not blocks. There are no
# retries, proxies or ZenRows after a block.
# PoliteHTTP checks every request here (robots.txt reads too), so a blocked
# host or source never gets another request.
module RunBlocks
  module_function

  # Bodies that mean "blocked / bot wall", not content (pages under 60 KB).
  WALL_RE = /captcha-delivery\.com|<title>\s*Client Challenge|px-captcha|\/blocked\?url=|areyouahuman|Access Denied<\/title>|cf-chl-|Attention Required! \| Cloudflare|Please enable JS and disable any ad blocker|Robot or human\?/i
  # Small HTML pages (under 20 KB) with these words are challenge pages.
  CHALLENGE_RE = /captcha|are you a robot|robot or human|access denied|px-captcha|challenge-platform/i
  # Redirects to these are a block by the host that sent them.
  BLOCK_LOCATION_RE = %r{/blocked\b|areyouahuman|captcha|dead-end}i

  def reset!
    @hosts = {}
    @sources = {}
    @order = []
    @current = nil
  end
  reset!

  # Host key: host name, plus the port when it isn't the scheme's default.
  def host_key(url)
    u = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
    return nil unless u.host
    h = u.host.downcase
    u.port && u.port != u.default_port ? "#{h}:#{u.port}" : h
  rescue URI::InvalidURIError
    nil
  end

  # Site of a host for "is this the source's own host" (www.bhphotovideo.com,
  # bhphotovideo.com and static.bhphotovideo.com are one site).
  def site_of(key) = key.to_s.sub(/:\d+\z/, "").split(".").last(2).join(".") + key.to_s[/:\d+\z/].to_s

  # Configured URLs of a source (any of its listing / feed / sitemap pages).
  def source_urls(source)
    %w[url urls deep_urls listing_urls sitemaps price_pages].flat_map { |k| Array(source[k]) }.grep(String)
  end

  def source_hosts(source) = source_urls(source).filter_map { |u| host_key(u) }.uniq

  # The source whose requests are being made now (a source Hash from
  # deal_sources.yml, or nil between sources).
  def source=(source)
    @current = source && { id: source["id"].to_s, sites: source_hosts(source).map { |h| site_of(h) }.uniq }
  end

  def source_id = @current&.dig(:id)

  def host_blocked?(url) = @hosts.key?(host_key(url))
  def source_blocked?(id) = @sources.key?(id.to_s)
  def blocked_source_ids = @sources.keys
  def any? = !@hosts.empty?

  # Why a request to url must not be made (nil: go ahead).
  def refusal(url)
    if (s = @current && @sources[@current[:id]])
      "#{@current[:id]} was blocked earlier this run (#{s[:reason]})"
    elsif (h = @hosts[host_key(url)])
      "#{host_key(url)} was blocked earlier this run (#{h[:reason]}#{h[:source] ? ", #{h[:source]}" : ''})"
    end
  end

  # Block reason for a response, or nil when it is a normal answer.
  def block_reason(status:, body: nil, location: nil, content_type: nil)
    return "HTTP #{status}" if [403, 429].include?(status.to_i)
    return "redirect to #{location}" if location && status.to_i.between?(300, 399) && BLOCK_LOCATION_RE.match?(location.to_s)
    b = body.to_s
    return "bot wall (HTTP #{status})" if b.size < 60_000 && WALL_RE.match?(b)
    html = content_type.to_s.include?("html") || b.lstrip[0, 200] =~ /\A(?:<!doctype html|<html)/i
    return "challenge page (HTTP #{status})" if html && b.size < 20_000 && CHALLENGE_RE.match?(b)
    nil
  end

  # Record a block on url's host (and on the current source when the host is
  # its own, or own: true). Logs once per source / host. Returns the reason.
  def block!(url, reason, own: false)
    key = host_key(url) or return reason
    src = @current && (own || @current[:sites].include?(site_of(key))) ? @current[:id] : nil
    new_host = !@hosts.key?(key)
    @hosts[key] ||= { reason: reason, url: url, source: src }
    @order << [:host, key] if new_host
    if src && !@sources.key?(src)
      @sources[src] = { reason: reason, host: key, url: url }
      @order << [:source, src]
      puts "   blocked: #{reason} at #{url}; skipping the rest of #{src} this run"
    elsif new_host
      puts "   blocked: #{reason} at #{url}; no more requests to #{key} this run#{@current ? " (while reading #{@current[:id]})" : ''}"
    end
    reason
  end

  # A source not read at all because one of its hosts was blocked earlier.
  # Returns the log line, or nil when none of its hosts is blocked.
  def skip_source?(source)
    key = source_hosts(source).find { |h| @hosts.key?(h) } or return nil
    id = source["id"].to_s
    unless @sources.key?(id)
      @sources[id] = { reason: "host blocked", host: key, url: nil }
      @order << [:source, id]
    end
    by = @hosts[key]
    "skipped: #{key} was blocked earlier this run (#{[by[:source], by[:reason]].compact.join(', ')}); no requests"
  end

  # "bh-deals (HTTP 403, www.bhphotovideo.com), bh-deals-categories (host blocked, www.bhphotovideo.com), example.com (HTTP 429)"
  def summary
    listed = @sources.values.map { |s| s[:host] }
    parts = @order.filter_map do |kind, k|
      if kind == :source
        "#{k} (#{@sources[k][:reason]}, #{@sources[k][:host]})"
      elsif !listed.include?(k)
        "#{k} (#{@hosts[k][:reason]})"
      end
    end
    parts.empty? ? "none" : parts.join(", ")
  end
end
