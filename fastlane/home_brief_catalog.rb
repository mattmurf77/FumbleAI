require "json"
require "net/http"
require "uri"
require "bigdecimal"

# Only the Home Brief draft in the established Home Blueprint app may be created.
module HomeBriefCatalog
  APP_ID = "6817578211"
  US = "USA"
  DESCRIPTION = "Export selected home projects as a PDF."
  WRITABLE_PATHS = %w[/v2/inAppPurchases /v1/inAppPurchaseLocalizations /v1/inAppPurchasePriceSchedules /v1/inAppPurchaseAvailabilities].freeze

  class ApiError < StandardError
    attr_reader :status

    def initialize(status, code = nil)
      @status = status
      super("Apple returned HTTP #{status}#{code ? " (#{code})" : ""}")
    end
  end

  # Spaceship holds the signing key and refreshes the short-lived JWT in memory.
  # Never include request headers or raw Apple error bodies in output.
  class Client
    ORIGIN = "https://api.appstoreconnect.apple.com"

    def initialize(token, write: false)
      @token = token
      @write = write
    end

    def get(path, params = {})
      url = URI.join(ORIGIN, path)
      url.query = URI.encode_www_form(params) unless params.empty?
      request(url, Net::HTTP::Get)
    end

    def post(path, body)
      raise "Write not allowed" unless @write && WRITABLE_PATHS.include?(path)
      request(URI.join(ORIGIN, path), Net::HTTP::Post, body)
    end

    private

    def request(url, method, body = nil)
      unless url.scheme == "https" && url.host == "api.appstoreconnect.apple.com" && url.port == 443 &&
             url.userinfo.nil? && url.path.start_with?("/v1/", "/v2/")
        raise "Unexpected App Store Connect resource URL"
      end
      @token.refresh! if @token.expired?
      req = method.new(url.request_uri)
      req["Authorization"] = "Bearer #{@token.text}"
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      result = Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: 12, read_timeout: 40) { |http| http.request(req) }
      unless result.is_a?(Net::HTTPSuccess)
        code = (JSON.parse(result.body).dig("errors", 0, "code") rescue nil)
        raise ApiError.new(result.code.to_i, code.to_s[/\A[A-Z0-9_.-]+\z/])
      end
      return nil if result.is_a?(Net::HTTPNoContent)
      JSON.parse(result.body)
    end
  end

  class Product
    def initialize(client, app_id:, bundle_id:, log:)
      raise "Home Brief belongs to the existing Home Blueprint app" unless app_id == APP_ID && !bundle_id.to_s.empty?
      @client = client
      @sku = "#{bundle_id}.homebrief"
      @log = log
    end

    def status
      product = find_product
      unless product
        @log.call("Home Brief: absent for this bundle")
        return
      end
      attrs = product.fetch("attributes")
      @log.call("Home Brief: type=#{attrs['inAppPurchaseType']} state=#{attrs['state']} id=#{product['id']}")
      localizations = rows("/v2/inAppPurchases/#{product['id']}/inAppPurchaseLocalizations")
      locales = localizations.map { |item| item.fetch("attributes").fetch("locale") }
      @log.call("Home Brief localizations: #{locales.empty? ? 'none' : locales.join(', ')}")
      schedule = relation(product, "iapPriceSchedule")
      if schedule
        base = @client.get("/v1/inAppPurchasePriceSchedules/#{schedule['id']}/baseTerritory").fetch("data").fetch("id")
        report_prices(schedule.fetch("id"), "manualPrices")
        report_prices(schedule.fetch("id"), "automaticPrices") unless base == US
      else
        @log.call("Home Brief: no price schedule reported")
      end
      availability = relation(product, "inAppPurchaseAvailability")
      if availability
        territories = rows("/v1/inAppPurchaseAvailabilities/#{availability['id']}/relationships/availableTerritories")
        @log.call("Home Brief: US available=#{territories.any? { |t| t['id'] == US }}, territories=#{territories.size}")
      else
        @log.call("Home Brief: no availability reported")
      end
    end

    # Never repair an arbitrary existing SKU. An explicit resume ID may continue missing
    # fields on a partial, matching MISSING_METADATA draft without replacing a setup.
    def provision(resume_id: nil)
      product = find_product
      if product
        if resume_id.to_s.empty?
          @log.call("Home Brief already exists. Existing settings preserved.")
          return status
        end
        unless product["id"] == resume_id && product.dig("attributes", "inAppPurchaseType") == "NON_CONSUMABLE" &&
               product.dig("attributes", "state") == "MISSING_METADATA"
          raise "Resume requires the matching Home Brief non-consumable draft in MISSING_METADATA"
        end
      else
        raise "Cannot resume: no matching Home Brief exists" if resume_id && !resume_id.empty?
        product = @client.post("/v2/inAppPurchases", {data: {
          type: "inAppPurchases", attributes: {name: "Home Brief", productId: @sku, inAppPurchaseType: "NON_CONSUMABLE"},
          relationships: {app: link("apps", APP_ID)}
        }}).fetch("data")
        @log.call("Created Home Brief draft id=#{product.fetch('id')}. Retain this ID in case setup is interrupted.")
      end

      id = product.fetch("id")
      localizations = rows("/v2/inAppPurchases/#{id}/inAppPurchaseLocalizations")
      unless localizations.any? { |item| item.dig("attributes", "locale") == "en-US" }
        @client.post("/v1/inAppPurchaseLocalizations", {data: {
          type: "inAppPurchaseLocalizations", attributes: {name: "Home Brief", locale: "en-US", description: DESCRIPTION},
          relationships: {inAppPurchaseV2: link("inAppPurchases", id)}
        }})
      end
      if relation(product, "iapPriceSchedule")
        @log.call("Existing price schedule preserved.")
      else
        set_us_price(id)
      end
      if relation(product, "inAppPurchaseAvailability")
        @log.call("Existing availability preserved.")
      else
        @client.post("/v1/inAppPurchaseAvailabilities", {data: {
          type: "inAppPurchaseAvailabilities", attributes: {availableInNewTerritories: false},
          relationships: {inAppPurchase: link("inAppPurchases", id), availableTerritories: {data: [{type: "territories", id: US}]}}
        }})
      end
      status
    end

    private

    def find_product
      matches = rows("/v1/apps/#{APP_ID}/inAppPurchasesV2", {"filter[productId]" => @sku})
      raise "Unexpected product returned for the exact Home Brief SKU" unless matches.all? { |item| item.dig("attributes", "productId") == @sku }
      raise "Multiple Home Brief products matched" if matches.size > 1
      matches.first
    end

    def relation(product, name)
      @client.get("/v2/inAppPurchases/#{product.fetch('id')}/#{name}").fetch("data")
    rescue ApiError => error
      raise unless error.status == 404
      nil
    end

    def rows(path, params = {})
      values = []
      page = @client.get(path, params)
      loop do
        values.concat(page.fetch("data"))
        following = page.dig("links", "next")
        return values unless following
        page = @client.get(following)
      end
    end

    def report_prices(schedule_id, source)
      path = "/v1/inAppPurchasePriceSchedules/#{schedule_id}/#{source}"
      page = @client.get(path, {"filter[territory]" => US, "include" => "inAppPurchasePricePoint", "limit" => 200})
      found = false
      loop do
        points = (page["included"] || []).select { |item| item["type"] == "inAppPurchasePricePoints" }.to_h { |item| [item["id"], item.dig("attributes", "customerPrice")] }
        page.fetch("data").each do |item|
          attrs = item.fetch("attributes", {})
          amount = points[item.dig("relationships", "inAppPurchasePricePoint", "data", "id")]
          @log.call("Home Brief US #{source}: USD #{amount || 'unknown'}, from #{attrs['startDate'] || 'initial'} through #{attrs['endDate'] || 'ongoing'}")
          found = true
        end
        following = page.dig("links", "next")
        break unless following
        page = @client.get(following)
      end
      @log.call("Home Brief: no US prices in #{source}") unless found
    end

    def set_us_price(id)
      candidates = rows("/v2/inAppPurchases/#{id}/pricePoints", {"filter[territory]" => US, "limit" => 8000})
      matches = candidates.select { |point| BigDecimal(point.dig("attributes", "customerPrice")) == BigDecimal("14.99") }
      raise "Expected one exact USD 14.99 US price point; inspect the draft manually" unless matches.size == 1
      price_id = '${home-brief-us-price}'
      @client.post("/v1/inAppPurchasePriceSchedules", {
        data: {type: "inAppPurchasePriceSchedules", relationships: {
          inAppPurchase: link("inAppPurchases", id), baseTerritory: link("territories", US),
          manualPrices: {data: [{type: "inAppPurchasePrices", id: price_id}]}
        }},
        included: [{type: "inAppPurchasePrices", id: price_id, attributes: {startDate: nil}, relationships: {
          inAppPurchaseV2: link("inAppPurchases", id), inAppPurchasePricePoint: link("inAppPurchasePricePoints", matches.first.fetch("id"))
        }}]
      })
    end

    def link(type, id)
      {data: {type: type, id: id}}
    end
  end
end
