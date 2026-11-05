require "digest"
require_relative "apple_screenshot"

module HomeBriefReview
  PRODUCT = "6830947832"
  ASSETS = "/v1/inAppPurchaseAppStoreReviewScreenshots"
  PRODUCT_PATH = "/v2/inAppPurchases/#{PRODUCT}"
  TEST = "HomeBriefReviewScreenshotTests/testCaptureHomeBriefPurchaseForReview()"
  FILE_NAME = "Home-Brief-App-Review.png"
  NOTES = "From Home, open Home history, then Home Brief. The one-time purchase unlocks PDF export of selected completed projects. A purchaser can choose projects, optionally include costs and supporting-file counts, preview the PDF, and share it. Restore Purchase is on this screen and in Settings. Tasks, projects, inventory and CSV export remain free."

  def self.attachment(directory)
    AppleScreenshot.attachment(directory, test: TEST, title: "Home Brief - App Review")
  end

  class Client < HomeBriefCatalog::Client
    include AppleScreenshot::Storage

    def reserve(size)
      request(URI(ORIGIN + ASSETS), Net::HTTP::Post, {data: {
        type: "inAppPurchaseAppStoreReviewScreenshots", attributes: {fileName: FILE_NAME, fileSize: size},
        relationships: {inAppPurchaseV2: {data: {type: "inAppPurchases", id: PRODUCT}}}
      }}).fetch("data")
    end

    def commit(id, checksum)
      request(URI(ORIGIN + ASSETS + "/" + id), Net::HTTP::Patch, {data: {
        type: "inAppPurchaseAppStoreReviewScreenshots", id: id, attributes: {uploaded: true, sourceFileChecksum: checksum}
      }})
    end

    def add_notes
      request(URI(ORIGIN + PRODUCT_PATH), Net::HTTP::Patch, {data: {
        type: "inAppPurchases", id: PRODUCT, attributes: {reviewNote: NOTES}
      }})
    end
  end

  class Upload
    def initialize(client, app_id:, bundle_id:)
      raise "Expected the Home Blueprint app" unless app_id == HomeBriefCatalog::APP_ID && !bundle_id.to_s.empty?
      @client = client
      @sku = "#{bundle_id}.homebrief"
    end

    def draft
      response = @client.get("/v1/apps/#{HomeBriefCatalog::APP_ID}/inAppPurchasesV2",
        {"filter[productId]" => @sku, "include" => "appStoreReviewScreenshot",
         "fields[inAppPurchases]" => "productId,inAppPurchaseType,state,reviewNote,appStoreReviewScreenshot"})
      found = response.fetch("data")
      raise "Expected exactly the existing Home Brief draft" unless found.size == 1
      product = found.first
      attrs = product.fetch("attributes")
      unless product["type"] == "inAppPurchases" && product["id"] == PRODUCT && attrs["productId"] == @sku &&
             attrs["inAppPurchaseType"] == "NON_CONSUMABLE" && %w[MISSING_METADATA READY_TO_SUBMIT].include?(attrs["state"])
        raise "Home Brief must be the matching unsubmitted non-consumable"
      end
      screenshot = product.fetch("relationships").fetch("appStoreReviewScreenshot").fetch("data")
      [attrs["reviewNote"], screenshot]
    end

    def call(bytes)
      checksum = Digest::MD5.hexdigest(bytes)
      _, existing = draft
      if existing
        id = asset_id(existing)
        asset = @client.get("#{ASSETS}/#{id}").fetch("data")
        attrs = asset.fetch("attributes")
        unless attrs.dig("assetDeliveryState", "state") == "COMPLETE" && attrs["sourceFileChecksum"] == checksum
          raise "An existing or incomplete screenshot is present; leaving it untouched"
        end
      else
        asset = @client.reserve(bytes.bytesize)
        id = asset_id(asset)
        AppleScreenshot.transfer(@client, ASSETS, asset, id, bytes, checksum)
      end
      # Re-read immediately before writing notes, preserving any edits made during processing.
      note, linked = draft
      raise "Screenshot association changed; review notes untouched" unless linked && asset_id(linked) == id
      return :notes_preserved unless note.to_s.strip.empty?
      @client.add_notes
      note, linked = draft
      raise "Unable to verify review information" unless note == NOTES && linked && asset_id(linked) == id
      :complete
    end

    private

    def asset_id(item)
      id = item.fetch("id")
      raise "Unexpected review asset" unless item["type"] == "inAppPurchaseAppStoreReviewScreenshots" && /\A[A-Za-z0-9-]{1,100}\z/.match?(id)
      id
    end


  end
end
