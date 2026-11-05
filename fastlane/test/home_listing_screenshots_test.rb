require "minitest/autorun"
require_relative "../home_listing_screenshots"

class HomeListingScreenshotsTest < Minitest::Test
  LISTING = HomeListingScreenshots
  class Apple
    attr_reader :screens, :writes
    attr_accessor :state
    def initialize
      @screens, @writes = [], []
      @state = "PREPARE_FOR_SUBMISSION"
    end
    def item(type, id, fields)
      {"type" => type, "id" => id, "attributes" => fields}
    end
    def get(path, _ = {})
      data = case path
      when "/v1/apps/6817578211/appStoreVersions"
        [item("appStoreVersions", "v", {"platform" => "IOS", "versionString" => "1.0", "appVersionState" => @state})]
      when "/v1/appStoreVersions/v/appStoreVersionLocalizations" then [item("appStoreVersionLocalizations", "l", {"locale" => "en-US"})]
      when "/v1/appStoreVersionLocalizations/l/appScreenshotSets" then [@set].compact
      when "/v1/appScreenshotSets/s/appScreenshots" then @screens
      when %r{\A/v1/appScreenshots/[0-9]+\z} then @screens.fetch(path.split("/").last.to_i)
      else raise "Unscoped GET"
      end
      {"data" => data}
    end
    def create_set(locale)
      raise unless locale == "l"
      @writes << :set
      @set = item("appScreenshotSets", "s", {"screenshotDisplayType" => LISTING::DISPLAY})
    end
    def reserve(set, image)
      raise unless set == "s"
      @writes << [:reserve, image[:name]]
      asset = item("appScreenshots", @screens.size.to_s,
        {"fileName" => image[:name], "uploadOperations" => [{"offset" => 0, "length" => image[:bytes].bytesize}]})
      @screens << asset
      asset
    end
    def upload(_, _bytes)
      @writes << :put
    end
    def commit(id, checksum)
      @writes << :commit
      @screens.fetch(id.to_i)["attributes"].merge!("assetDeliveryState" => {"state" => "COMPLETE"}, "sourceFileChecksum" => checksum)
    end
  end

  def setup
    @api = Apple.new
    @runner = LISTING::Upload.new(@api, app_id: "6817578211")
    @images = LISTING::SCREENS.map { |name, _, _| {name: name, bytes: name.b, checksum: Digest::MD5.hexdigest(name)} }
  end

  def test_exactly_three_assets_with_matching_order_and_checksums_then_noop
    @runner.run(@images)
    assert_equal @images.map { |i| i[:name] }, @api.screens.map { |s| s["attributes"]["fileName"] }
    assert_equal @images.map { |i| i[:checksum] }, @api.screens.map { |s| s["attributes"]["sourceFileChecksum"] }
    assert_equal 3, @api.writes.count(:put)
    @api.writes.clear
    @runner.run(@images)
    assert_empty @api.writes
  end

  def test_differing_or_incomplete_existing_asset_is_preserved
    @runner.run(@images)
    @api.screens[0]["attributes"]["fileName"] = "owner.png"
    @api.writes.clear
    assert_raises(RuntimeError) { @runner.run(@images) }
    @api.screens[0]["attributes"]["fileName"] = @images[0][:name]
    @api.screens[0]["attributes"]["assetDeliveryState"] = {"state" => "AWAITING_UPLOAD"}
    assert_raises(RuntimeError) { @runner.run(@images) }
    assert_empty @api.writes
  end

  def test_repeat_after_a_complete_prefix_only_adds_missing_assets
    set = @api.create_set("l")
    asset = @api.reserve(set["id"], @images.first)
    @api.commit(asset["id"], @images.first[:checksum])
    @api.writes.clear
    @runner.run(@images)
    assert_equal [[:reserve, @images[1][:name]], [:reserve, @images[2][:name]]], @api.writes.grep(Array)
    assert_equal 2, @api.writes.count(:put)
  end

  def test_wrong_app_version_or_unapproved_image_makes_no_changes
    assert_raises(RuntimeError) { LISTING::Upload.new(@api, app_id: "other") }
    @api.state = "IN_REVIEW"
    assert_raises(RuntimeError) { @runner.run(@images) }
    assert_raises(RuntimeError) { @runner.run(@images.reverse) }
    assert_empty @api.writes
  end
end
