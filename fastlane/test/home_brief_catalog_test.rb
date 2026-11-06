require "minitest/autorun"
require_relative "../home_brief_catalog"

class HomeBriefCatalogTest < Minitest::Test
  class AppleFixture
    attr_accessor :item, :locale, :schedule, :availability, :fail_prices
    attr_reader :writes, :reads

    def initialize
      @writes = []
      @reads = []
    end

    def get(path, params = {})
      @reads << path
      case path
      when "/v1/apps/6817578211/inAppPurchasesV2"
        raise "Missing exact SKU filter" unless params["filter[productId]"] == "app.test.homebrief"
        data(@item ? [@item] : [])
      when "/v2/inAppPurchases/11/inAppPurchaseLocalizations"
        data(@locale ? [@locale] : [])
      when "/v2/inAppPurchases/11/iapPriceSchedule"
        raise HomeBriefCatalog::ApiError.new(404) unless @schedule
        data({"id" => "s1"})
      when "/v2/inAppPurchases/11/inAppPurchaseAvailability"
        raise HomeBriefCatalog::ApiError.new(404) unless @availability
        data({"id" => "a1"})
      when "/v1/inAppPurchaseAvailabilities/a1/relationships/availableTerritories"
        data([{"id" => "USA"}])
      when "/v1/inAppPurchasePriceSchedules/s1/baseTerritory"
        data({"id" => "USA"})
      when "/v1/inAppPurchasePriceSchedules/s1/manualPrices"
        data([{"attributes" => {"startDate" => nil}, "relationships" => {"inAppPurchasePricePoint" => {"data" => {"id" => "p2"}}}}]).merge(
          "included" => [{"type" => "inAppPurchasePricePoints", "id" => "p2", "attributes" => {"customerPrice" => "14.99"}}])
      when "/v2/inAppPurchases/11/pricePoints"
        raise "Expected specific US storefront" unless params["filter[territory]"] == "USA"
        data([{"id" => "p1", "attributes" => {"customerPrice" => "1.99"}}]).merge("links" => {"next" => "/v2/inAppPurchasePricePoints-test-page2"})
      when "/v2/inAppPurchasePricePoints-test-page2"
        data([{"id" => "p2", "attributes" => {"customerPrice" => "14.99"}}])
      else raise "Unexpected GET: #{path}"
      end
    end

    def post(path, payload)
      @writes << [path, payload]
      case path
      when "/v2/inAppPurchases"
        @item = {"id" => "11", "attributes" => {"productId" => "app.test.homebrief", "inAppPurchaseType" => "NON_CONSUMABLE", "state" => "MISSING_METADATA"}}
        data(@item)
      when "/v1/inAppPurchaseLocalizations"
        @locale = {"attributes" => {"locale" => "en-US", "name" => payload[:data][:attributes][:name]}}
      when "/v1/inAppPurchasePriceSchedules"
        raise HomeBriefCatalog::ApiError.new(403) if @fail_prices
        @schedule = true
      when "/v1/inAppPurchaseAvailabilities"
        @availability = true
      else raise "Unexpected write: #{path}"
      end
    end

    def data(value)
      {"data" => value}
    end
  end

  def setup
    @api = AppleFixture.new
    @messages = []
    @product = HomeBriefCatalog::Product.new(@api, app_id: HomeBriefCatalog::APP_ID, bundle_id: "app.test", log: @messages.method(:<<))
  end

  def test_absent_read_only_status
    @product.status
    assert_match(/absent/, @messages.join)
    assert_empty @api.writes
    assert_raises(RuntimeError) { HomeBriefCatalog::Client.new(nil).post("/v2/inAppPurchases", {}) }
  end

  def test_new_draft_exact_metadata_price_and_availability
    @product.provision
    assert_equal HomeBriefCatalog::WRITABLE_PATHS, @api.writes.map(&:first)
    item, loc, price, availability = @api.writes.map(&:last)
    assert_equal "app.test.homebrief", item.dig(:data, :attributes, :productId)
    assert_equal "NON_CONSUMABLE", item.dig(:data, :attributes, :inAppPurchaseType)
    assert_equal HomeBriefCatalog::APP_ID, item.dig(:data, :relationships, :app, :data, :id)
    assert_equal "en-US", loc.dig(:data, :attributes, :locale)
    assert_operator loc.dig(:data, :attributes, :description).size, :<=, 45
    assert_equal "USA", price.dig(:data, :relationships, :baseTerritory, :data, :id)
    assert_equal "p2", price[:included][0].dig(:relationships, :inAppPurchasePricePoint, :data, :id)
    assert_nil price[:included][0].dig(:attributes, :startDate)
    assert_equal false, availability.dig(:data, :attributes, :availableInNewTerritories)
    assert_equal ["USA"], availability.dig(:data, :relationships, :availableTerritories, :data).map { |t| t[:id] }
    assert @messages.any? { |m| m.include?("USD 14.99") }
    assert @messages.any? { |m| m.include?("US available=true") }

    @product.provision
    @product.provision(resume_id: "11")
    assert_equal 4, @api.writes.length
  end

  def test_partial_draft_requires_matching_explicit_resume
    @api.fail_prices = true
    assert_raises(HomeBriefCatalog::ApiError) { @product.provision }
    first_writes = @api.writes.size
    @api.fail_prices = false
    @product.provision
    assert_equal first_writes, @api.writes.size
    assert_raises(RuntimeError) { @product.provision(resume_id: "another") }
    @product.provision(resume_id: "11")
    assert_equal ["/v1/inAppPurchasePriceSchedules", "/v1/inAppPurchaseAvailabilities"], @api.writes.drop(first_writes).map(&:first)
  end

  def test_existing_different_type_state_or_sku_are_preserved
    @product.provision
    @api.item["attributes"]["inAppPurchaseType"] = "CONSUMABLE"
    @product.provision
    assert_raises(RuntimeError) { @product.provision(resume_id: "11") }
    @api.item["attributes"]["inAppPurchaseType"] = "NON_CONSUMABLE"
    @api.item["attributes"]["state"] = "APPROVED"
    assert_raises(RuntimeError) { @product.provision(resume_id: "11") }
    @api.item["attributes"]["productId"] = "unrelated"
    assert_raises(RuntimeError) { @product.provision }
    assert_equal 4, @api.writes.length
  end

  def test_token_cannot_leave_apple_and_unrelated_writes_are_impossible
    client = HomeBriefCatalog::Client.new(nil, write: true)
    assert_raises(RuntimeError) { client.get("https://unrelated.example/v1/apps") }
    assert_raises(RuntimeError) { client.get("http://api.appstoreconnect.apple.com/v1/foo") }
    assert_raises(RuntimeError) { client.post("/v1/reviewSubmissions", {}) }
    assert_raises(RuntimeError) { HomeBriefCatalog::Product.new(client, app_id: "1", bundle_id: "test", log: @messages.method(:<<)) }
  end
end
