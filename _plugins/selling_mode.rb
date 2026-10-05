# Selling mode: hides "used tech I'm selling" messaging while none of my own
# items is for sale, and brings it all back as soon as one is published.
#
# "Selling" = at least one _products/ item with type: sale and status: available.
#
# While NOT selling:
#   - site.tagline / site.description use tagline_no_sale / description_no_sale
#     from _config.yml (footer, meta descriptions, social cards).
#   - any page with title_no_sale / description_no_sale in its front matter
#     uses those instead (home page title, etc.).
#   - pages with selling_only: true (shop, returns) are left out of sitemap.xml.
# Templates check {% if site.selling %} for everything else.
module SellingMode
  class Generator < Jekyll::Generator
    priority :highest

    def generate(site)
      products = site.collections["products"]&.docs || []
      selling = products.any? { |d| d.data["type"] == "sale" && d.data["status"] == "available" }

      # Keep the original values so `jekyll serve` can switch back on rebuild.
      %w[tagline description].each do |key|
        site.config["#{key}_selling"] ||= site.config[key]
        site.config[key] = selling ? site.config["#{key}_selling"] : (site.config["#{key}_no_sale"] || site.config["#{key}_selling"])
      end
      site.config["selling"] = selling
      return if selling

      (site.pages + products).each do |page|
        %w[title description].each do |key|
          alt = page.data["#{key}_no_sale"]
          page.data[key] = alt if alt
        end
        page.data["sitemap"] = false if page.data["selling_only"]
      end
    end
  end
end
