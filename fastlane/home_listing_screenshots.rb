# frozen_string_literal: true

require_relative "apple_screenshot"

module HomeListingScreenshots
  DISPLAY = "APP_IPHONE_67"
  SETS = "/v1/appScreenshotSets"
  ASSETS = "/v1/appScreenshots"
  SCREENS = [
    ["01-Home.png", "HomeRecommendationUITests/testHomeRecommendsAnActualOverdueTaskAndOpensIt()", "Home • recommendation and scheduled tasks"],
    ["02-Equipment.png", "EquipmentCatalogUITests/testStartWithoutRoomsAndAddFindAndEditOwnedTool()", "Whole-home inventory before creating a floor plan"],
    ["03-History.png", "CaptureJourneysTests/testMapSpreadsheetReviewAndConfirmCompletedWorkAppearsInHistory()", "Home History · imported year and actual cost"]
  ].freeze

  def self.images(directory)
    SCREENS.map do |name, test, title|
      bytes = AppleScreenshot.attachment(directory, test: test, title: title)
      unless bytes.byteslice(16, 8).unpack("N2") == [1320, 2868] && bytes.getbyte(25) == 2
        raise "Expected a 1320 × 2868 RGB iPhone screenshot for #{name}"
      end
      {name: name, bytes: bytes, checksum: Digest::MD5.hexdigest(bytes)}
    end
  end

  class Client < HomeBriefCatalog::Client
    include AppleScreenshot::Storage

    def create_set(locale)
      request(URI(ORIGIN + SETS), Net::HTTP::Post, {data: {type: "appScreenshotSets", attributes: {screenshotDisplayType: DISPLAY},
        relationships: {appStoreVersionLocalization: {data: {type: "appStoreVersionLocalizations", id: locale}}}}}).fetch("data")
    end

    def reserve(set, image)
      request(URI(ORIGIN + ASSETS), Net::HTTP::Post, {data: {type: "appScreenshots",
        attributes: {fileName: image[:name], fileSize: image[:bytes].bytesize},
        relationships: {appScreenshotSet: {data: {type: "appScreenshotSets", id: set}}}}}).fetch("data")
    end

    def commit(id, checksum)
      request(URI("#{ORIGIN}#{ASSETS}/#{id}"), Net::HTTP::Patch, {data: {type: "appScreenshots", id: id,
        attributes: {uploaded: true, sourceFileChecksum: checksum}}})
    end
  end

  class Upload
    def initialize(client, app_id:)
      raise "Expected Home Blueprint" unless app_id == HomeBriefCatalog::APP_ID
      @client = client
    end

    def run(images)
      unless images.map { |i| i[:name] } == SCREENS.map(&:first) && images.all? { |i| i[:checksum] == Digest::MD5.hexdigest(i[:bytes]) }
        raise "Unexpected listing images"
      end
      locale = draft_locale
      matches = rows("/v1/appStoreVersionLocalizations/#{locale}/appScreenshotSets",
        {"filter[screenshotDisplayType]" => DISPLAY, "fields[appScreenshotSets]" => "screenshotDisplayType", "limit" => 2})
      raise "Ambiguous or unexpected screenshot set" if matches.size > 1 || matches.any? { |r| r.dig("attributes", "screenshotDisplayType") != DISPLAY }
      set = safe_id(matches.first || @client.create_set(locale), "appScreenshotSets")
      expected = images.map { |i| [i[:name], i[:checksum]] }
      loop do
        existing = rows("#{SETS}/#{set}/appScreenshots", {"fields[appScreenshots]" => "fileName,sourceFileChecksum,assetDeliveryState", "limit" => 20}).map do |row|
          attrs = row.fetch("attributes")
          raise "Existing screenshot is incomplete; preserving it" unless attrs.dig("assetDeliveryState", "state") == "COMPLETE"
          [attrs["fileName"], attrs["sourceFileChecksum"]]
        end
        unless existing == expected.first(existing.size) && existing.size <= images.size
          raise "Existing listing screenshots differ; preserving the set"
        end
        return if existing == expected
        raise "Editable draft changed" unless draft_locale == locale
        image = images.fetch(existing.size)
        asset = @client.reserve(set, image)
        id = safe_id(asset, "appScreenshots")
        AppleScreenshot.transfer(@client, ASSETS, asset, id, image[:bytes], image[:checksum])
        # A completed reservation must be linked before another image can be created.
        linked = rows("#{SETS}/#{set}/appScreenshots", {"fields[appScreenshots]" => "fileName", "limit" => 20})
        raise "Could not verify reserved screenshot association" unless linked.size == existing.size + 1 && linked.last["id"] == id
      end
    end

    private

    def draft_locale
      versions = rows("/v1/apps/#{HomeBriefCatalog::APP_ID}/appStoreVersions", {"filter[platform]" => "IOS",
        "filter[versionString]" => "1.0", "fields[appStoreVersions]" => "platform,versionString,appVersionState", "limit" => 2})
      raise "Expected the existing editable iOS 1.0" unless versions.size == 1 &&
        versions.first.fetch("attributes").values_at("platform", "versionString", "appVersionState") == ["IOS", "1.0", "PREPARE_FOR_SUBMISSION"]
      version = safe_id(versions.first, "appStoreVersions")
      locales = rows("/v1/appStoreVersions/#{version}/appStoreVersionLocalizations", {"filter[locale]" => "en-US", "fields[appStoreVersionLocalizations]" => "locale"})
      raise "Expected the existing en-US listing" unless locales.size == 1 && locales.first.dig("attributes", "locale") == "en-US"
      safe_id(locales.first, "appStoreVersionLocalizations")
    end

    def rows(path, params)
      page = @client.get(path, params)
      raise "Unexpected paginated screenshot context" if page.dig("links", "next")
      page.fetch("data")
    end

    def safe_id(row, type)
      id = row.fetch("id")
      raise "Unexpected Apple resource" unless row["type"] == type && /\A[A-Za-z0-9-]{1,100}\z/.match?(id)
      id
    end
  end
end
