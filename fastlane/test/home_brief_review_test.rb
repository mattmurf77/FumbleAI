require "minitest/autorun"
require "tmpdir"
require_relative "../home_brief_review"

class HomeBriefReviewTest < Minitest::Test
  class Fixture
    attr_accessor :product, :linked, :note, :state, :checksum, :ops
    attr_reader :writes, :parts
    def initialize
      @product = {"type" => "inAppPurchases", "id" => HomeBriefReview::PRODUCT,
        "attributes" => {"productId" => "test.home.homebrief", "state" => "MISSING_METADATA", "inAppPurchaseType" => "NON_CONSUMABLE"}}
      @writes = []
      @parts = []
      @asset = {"type" => "inAppPurchaseAppStoreReviewScreenshots", "id" => "fixture-id"}
      @ops = [{"offset" => 3, "length" => 4}, {"offset" => 0, "length" => 3}]
      @state = "COMPLETE"
    end
    def get(path, params = {})
      if path == "/v1/apps/6817578211/inAppPurchasesV2" && params["include"] == "appStoreReviewScreenshot" &&
          params["filter[productId]"] == "test.home.homebrief"
        @product["attributes"]["reviewNote"] = @note
        @product["relationships"] = {"appStoreReviewScreenshot" => {"data" => @linked}}
        {"data" => [@product]}
      elsif path == HomeBriefReview::ASSETS + "/fixture-id"
        {"data" => @asset.merge("attributes" => {"assetDeliveryState" => {"state" => @state}, "sourceFileChecksum" => @checksum})}
      else
        raise "Unexpected read"
      end
    end
    def reserve(size)
      @writes << [:reserve, size]
      @linked = @asset
      @asset.merge("attributes" => {"uploadOperations" => @ops})
    end
    def upload(op, part)
      @writes << [:upload, op["offset"]]
      @parts << part
    end
    def commit(id, sum)
      @writes << [:commit, id]
      @checksum = sum
    end
    def add_notes
      @writes << [:notes]
      @note = HomeBriefReview::NOTES
    end
  end

  def setup
    @fixture = Fixture.new
    @uploader = HomeBriefReview::Upload.new(@fixture, app_id: HomeBriefCatalog::APP_ID, bundle_id: "test.home")
    @bytes = "picture"
  end

  def test_ranges_are_uploaded_in_order_checksum_is_verified_then_blank_notes_are_filled
    assert_equal :complete, @uploader.call(@bytes)
    assert_equal [[:reserve, 7], [:upload, 0], [:upload, 3], [:commit, "fixture-id"], [:notes]], @fixture.writes
    assert_equal ["pic", "ture"], @fixture.parts
    assert_equal Digest::MD5.hexdigest(@bytes), @fixture.checksum
    assert_equal HomeBriefReview::NOTES, @fixture.note
    @fixture.writes.clear
    assert_equal :notes_preserved, @uploader.call(@bytes)
    assert_empty @fixture.writes
  end

  def test_mismatched_or_incomplete_existing_screenshot_is_preserved
    @uploader.call(@bytes)
    @fixture.writes.clear
    assert_raises(RuntimeError) { @uploader.call("other image") }
    @fixture.state = "AWAITING_UPLOAD"
    assert_raises(RuntimeError) { @uploader.call(@bytes) }
    assert_empty @fixture.writes
  end

  def test_owner_notes_are_preserved
    @fixture.note = "Owner's information"
    assert_equal :notes_preserved, @uploader.call(@bytes)
    assert_equal "Owner's information", @fixture.note
    refute_includes @fixture.writes, [:notes]
  end

  def test_apple_api_writes_are_limited_to_reservation_commit_and_notes
    client = HomeBriefReview::Client.new(nil)
    captured = []
    client.define_singleton_method(:request) do |url, method, payload|
      captured << [url.to_s, method, payload[:data]]
      {"data" => {}}
    end
    client.reserve(7)
    client.commit("fixture-id", Digest::MD5.hexdigest("picture"))
    client.add_notes
    origin = "https://api.appstoreconnect.apple.com"
    assert_equal [origin + HomeBriefReview::ASSETS, origin + HomeBriefReview::ASSETS + "/fixture-id",
                  origin + "/v2/inAppPurchases/6830947832"], captured.map(&:first)
    assert_equal [Net::HTTP::Post, Net::HTTP::Patch, Net::HTTP::Patch], captured.map { |op| op[1] }
    assert_equal({fileName: "Home-Brief-App-Review.png", fileSize: 7}, captured[0][2][:attributes])
    assert_equal({type: "inAppPurchases", id: "6830947832"}, captured[0][2].dig(:relationships, :inAppPurchaseV2, :data))
    assert_equal({uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest("picture")}, captured[1][2][:attributes])
    assert_equal({reviewNote: HomeBriefReview::NOTES}, captured[2][2][:attributes])
    assert_raises(RuntimeError) { client.upload({"url" => "https://example.net", "method" => "PUT"}, "picture") }
    assert_raises(RuntimeError) { client.upload({"url" => "https://upload.apple.com", "method" => "PUT",
      "requestHeaders" => [{"name" => "Authorization", "value" => "unused"}]}, "picture") }
  end

  def test_wrong_app_product_type_sku_or_submitted_state_refuses_every_write
    assert_raises(RuntimeError) { HomeBriefReview::Upload.new(@fixture, app_id: "other", bundle_id: "test.home") }
    [["id", "other"], ["productId", "other.homebrief"], ["state", "WAITING_FOR_REVIEW"], ["inAppPurchaseType", "CONSUMABLE"]].each do |key, value|
      record = key == "id" ? @fixture.product : @fixture.product["attributes"]
      saved = record[key]
      record[key] = value
      assert_raises(RuntimeError) { @uploader.call(@bytes) }
      record[key] = saved
    end
    assert_empty @fixture.writes
  end

  def test_incomplete_ranges_or_failed_processing_never_write_review_notes
    @fixture.ops.first["offset"] = 4
    assert_raises(RuntimeError) { @uploader.call(@bytes) }
    assert_equal [[:reserve, 7]], @fixture.writes
    @fixture.linked = nil
    @fixture.ops.first["offset"] = 3
    @fixture.state = "FAILED"
    assert_raises(RuntimeError) { @uploader.call(@bytes) }
    refute_includes @fixture.writes, [:notes]
  end

  def test_manifest_requires_named_successful_iphone_capture_and_valid_file
    Dir.mktmpdir do |dir|
      name = "ABCD1234-1234-1234-1234-123456789ABC.png"
      entry = {"deviceName" => "iPhone Air", "exportedFileName" => name, "isAssociatedWithFailure" => false,
        "suggestedHumanReadableName" => "Home Brief - App Review_0_ABCD1234-1234-1234-1234-123456789ABC.png"}
      rows = [{"testIdentifier" => HomeBriefReview::TEST, "attachments" => [entry]}]
      save = -> { File.write(File.join(dir, "manifest.json"), JSON.generate(rows)) }
      png = "\x89PNG\r\n\x1a\n".b + [13].pack("N") + "IHDR" + [1260, 2736].pack("N2") + "\0" * 20 + "IEND\xAE\x42\x60\x82".b
      File.binwrite(File.join(dir, name), png)
      save.call
      assert_equal png, HomeBriefReview.attachment(dir)
      rows[0]["attachments"] << entry.dup
      save.call
      assert_raises(RuntimeError) { HomeBriefReview.attachment(dir) }
      rows[0]["attachments"].pop
      entry["isAssociatedWithFailure"] = true
      save.call
      assert_raises(RuntimeError) { HomeBriefReview.attachment(dir) }
      entry["isAssociatedWithFailure"] = false
      entry["exportedFileName"] = "../else.png"
      save.call
      assert_raises(RuntimeError) { HomeBriefReview.attachment(dir) }
    end
  end
end
