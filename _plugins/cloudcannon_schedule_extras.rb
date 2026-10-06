# Extra scheduled builds for CloudCannon.
#
# The jekyll-cloudcannon-schedule plugin (Gemfile, _config.yml plugins:)
# writes /_schedule.txt with one line per post dated in the future. After each
# build CloudCannon reads that file and schedules a build at each line's time
# (Site Settings > Schedule > Automatic). Each line looks like:
#
#   2026-10-08T00:05:00-05:00,Build 'Prime Day ends',_config.yml
#   (time, build name, source file)
#
# This file adds more lines to it:
#
#   - Prime Day end: when prime_day.active is true and prime_day.ends is still
#     ahead, a build at 00:05 Central on `ends`, so the Prime Day section,
#     menu item and pill disappear on time (see _plugins/prime_day.rb).
#   - Each entry in scheduled_builds (_config.yml) whose time is still ahead:
#
#       scheduled_builds:
#         - time: "2026-12-01 00:05"   # Central time, YYYY-MM-DD HH:MM
#           name: Holiday page goes live
#           file: index.html           # optional; defaults to _config.yml
#
#     A bad entry is skipped with a warning; it never stops the build.
#
# "Now" is the build time (site.time). Times are Central because _config.yml
# sets timezone: America/Chicago, which Jekyll applies to Ruby's local time.
# The plugin doesn't escape post titles, so a title with a comma would add
# extra fields; commas inside the build name of its lines become spaces.
# The final list is sorted by time with no duplicate lines.
require "time"

module CloudCannonScheduleExtras
  module_function

  FILE_NAME = "_schedule.txt".freeze
  DEFAULT_FILE = "_config.yml".freeze

  # One schedule line. Commas would split the line in the wrong place, so
  # they're replaced with spaces.
  def line(time, name, file)
    clean = ->(text) { text.to_s.tr(",", " ").squeeze(" ").strip }
    "#{time.xmlschema},Build '#{clean.call(name)}',#{clean.call(file)}"
  end

  # Prime Day end: `ends` at 00:05 Central, if still ahead.
  def prime_day_line(site, now)
    settings = site.config["prime_day"]
    return nil unless settings.is_a?(Hash) && settings["active"] == true

    ends = PrimeDay.to_date(settings["ends"])
    return nil unless ends

    time = Time.new(ends.year, ends.month, ends.day, 0, 5, 0)
    time > now ? line(time, "Prime Day ends", DEFAULT_FILE) : nil
  end

  # Lines from scheduled_builds in _config.yml that are still ahead.
  def config_lines(site, now)
    entries = site.config["scheduled_builds"]
    return [] if entries.nil?
    unless entries.is_a?(Array)
      Jekyll.logger.warn "Schedule:", "scheduled_builds should be a list; ignored."
      return []
    end

    entries.filter_map do |entry|
      time = parse_time(entry.is_a?(Hash) ? entry["time"] : nil)
      name = entry.is_a?(Hash) ? entry["name"].to_s.strip : ""
      if time.nil? || name.empty?
        Jekyll.logger.warn "Schedule:", "skipped scheduled_builds entry #{entry.inspect} " \
          "(needs time: \"YYYY-MM-DD HH:MM\" and name)."
        next
      end
      next unless time > now

      file = entry["file"].to_s.strip
      line(time, name, file.empty? ? DEFAULT_FILE : file)
    end
  end

  # "YYYY-MM-DD HH:MM" in Central time, or nil if it doesn't look like that.
  def parse_time(value)
    match = value.to_s.strip.match(/\A(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})\z/)
    return nil unless match

    y, m, d, h, min = match.captures.map(&:to_i)
    return nil unless Date.valid_date?(y, m, d) && h < 24 && min < 60

    Time.new(y, m, d, h, min, 0)
  end

  # A plugin line with commas in its build name: keep the first field (time)
  # and last field (file), and replace commas in between with spaces. Lines
  # with fewer than 3 fields are left as they are.
  def clean_existing(text)
    first = text.index(",")
    last = text.rindex(",")
    return text if first.nil? || first == last

    middle = text[(first + 1)...last].tr(",", " ").squeeze(" ")
    "#{text[0...first]},#{middle},#{text[(last + 1)..]}"
  end

  # Time at the start of a line, for sorting; unreadable lines sort first.
  def line_time(text)
    Time.iso8601(text.split(",", 2).first.to_s.strip)
  rescue ArgumentError
    Time.at(0)
  end

  def apply(page)
    site = page.site
    now = site.time
    extras = [prime_day_line(site, now), *config_lines(site, now)].compact

    existing = page.output.to_s.lines.map(&:strip).reject(&:empty?)
                       .map { |text| clean_existing(text) }
    lines = (existing + extras).uniq.each_with_index
                               .sort_by { |text, i| [line_time(text), i] }
                               .map(&:first)
    page.output = lines.empty? ? "" : "#{lines.join("\n")}\n"
  rescue StandardError => e
    Jekyll.logger.warn "Schedule:", "could not add extra scheduled builds: #{e.message}"
  end
end

Jekyll::Hooks.register :pages, :post_render do |page|
  CloudCannonScheduleExtras.apply(page) if page.name == CloudCannonScheduleExtras::FILE_NAME
end
