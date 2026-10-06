source "https://rubygems.org"

# Run locally with:  bundle exec jekyll serve
gem "jekyll", "~> 4.3"

group :jekyll_plugins do
  gem "jekyll-sitemap"
  gem "jekyll-feed"
  # Writes /_schedule.txt so CloudCannon rebuilds when a future-dated post is due.
  gem "jekyll-cloudcannon-schedule"
end

# Windows and JRuby do not include zoneinfo files, so bundle the tzinfo-data gem.
platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "webrick", "~> 1.8" # needed for `jekyll serve` on Ruby 3+

# Deal finder (scripts/find_deals.rb, scripts/publish_deals.rb). Not needed to
# build the site, so it's optional. To use it locally:
#   bundle config set --local with deals && bundle install
group :deals, optional: true do
  gem "nokogiri", "~> 1.16"
end
