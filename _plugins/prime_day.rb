# Prime Day switch: the "Best Prime Day Deals" page (/deals/prime-day/), the
# home page section, the menu item and the category pill.
#
# _config.yml:
#
#   prime_day:
#     active: true
#     ends: 2026-10-08   # first day AFTER the event
#
# Live = active is true AND today (America/Chicago) is before `ends`.
#
# Sets, for the templates:
#   site.prime_day_live   true / false
#   site.prime_day_deals  qualifying deals, best first (see below)
#   site.prime_day_count  how many
#
# Qualifying deal = type: affiliate, an Amazon deal (same test as
# affiliate_networks.rb), `prime_day: true` in front matter, not expired.
# Order: deals with a verified discount (price and compare_at, compare_at
# higher) by percent off, biggest first; then the rest, newest first.
#
# While NOT live the page (front matter prime_day_page: true) still builds,
# shows a "Prime Day has ended" message instead of the grid, gets noindex and
# is left out of sitemap.xml. The home section, menu item and pill disappear.
require "date"

module PrimeDay
  module_function

  # Today's date in America/Chicago (US Central), without needing tzinfo:
  # CDT (UTC-5) from the 2nd Sunday of March to the 1st Sunday of November,
  # switching at 2:00 local; CST (UTC-6) otherwise.
  def chicago_date(time)
    utc = time.getutc
    year = utc.year
    dst_start = nth_sunday(year, 3, 2)
    dst_end = nth_sunday(year, 11, 1)
    start_utc = Time.utc(year, 3, dst_start.day, 8)  # 2:00 CST
    end_utc = Time.utc(year, 11, dst_end.day, 7)     # 2:00 CDT
    offset = utc >= start_utc && utc < end_utc ? -5 : -6
    (utc + offset * 3600).to_date
  end

  def nth_sunday(year, month, n)
    first = Date.new(year, month, 1)
    first + ((7 - first.wday) % 7) + 7 * (n - 1)
  end

  def to_date(value)
    return nil if value.nil? || value.to_s.strip.empty?
    return value.to_date if value.respond_to?(:to_date)

    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def number(value)
    Float(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Percent off when the original price is verified, else nil.
  def verified_off(doc)
    price = number(doc.data["price"])
    was = number(doc.data["compare_at"])
    return nil unless price && was && was > price

    (1 - price / was) * 100
  end

  def sorted_deals(site, today)
    docs = site.collections["products"]&.docs || []
    deals = docs.select do |d|
      d.data["type"] == "affiliate" && d.data["prime_day"] == true &&
        AffiliateNetworks.amazon?(d) && AffiliateNetworks.live?(d, today)
    end
    newest = ->(d) { -(d.date || Time.at(0)).to_f }
    verified, rest = deals.partition { |d| verified_off(d) }
    verified.sort_by { |d| [-verified_off(d), newest.call(d)] } + rest.sort_by(&newest)
  end

  def apply(site)
    settings = site.config["prime_day"] || {}
    today = chicago_date(site.time)
    ends = to_date(settings["ends"])
    live = settings["active"] == true && (ends.nil? || today < ends)

    deals = sorted_deals(site, today)
    site.config["prime_day_live"] = live
    site.config["prime_day_deals"] = deals
    site.config["prime_day_count"] = deals.size
    return if live

    site.pages.each do |page|
      next unless page.data["prime_day_page"]

      page.data["noindex"] = true
      page.data["sitemap"] = false
      page.data.delete("show_collection") # no grid shown, so no ItemList schema
    end
  end

  class Generator < Jekyll::Generator
    priority :high # before jekyll-sitemap (:lowest)

    def generate(site)
      PrimeDay.apply(site)
    end
  end
end
