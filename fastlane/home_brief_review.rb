require "digest"
require_relative "home_brief_catalog"

module HomeBriefReview
  PRODUCT = "6830947832"
  ASSETS = "/v1/inAppPurchaseAppStoreReviewScreenshots"
  PRODUCT_PATH = "/v2/inAppPurchases/#{PRODUCT}"
  TEST = "HomeBriefReviewScreenshotTests/testCaptureHomeBriefPurchaseForReview()"
  FILE_NAME = "Home-Brief-App-Review.png"
  NOTES = "From Home, open Home history, then Home Brief. The one-time purchase unlocks PDF export of selected completed projects. A purchaser can choose projects, optionally include costs and supporting-file counts, preview the PDF, and share it. Restore Purchase is on this screen and in Settings. Tasks, projects, inventory and CSV export remain free."

  def self.attachment(directory)
    manifest = JSON.parse(File.read(File.join(directory, "manifest.json")))
    tests = manifest.select { |row| row["testIdentifier"] == TEST }
    raise "Expected exactly one Home Brief screenshot test" unless tests.size == 1
    images = tests.first.fetch("attachments").select do |entry|
      entry["deviceName"].to_s.start_with?("iPhone") && entry["isAssociatedWithFailure"] == false &&
        /\AHome Brief - App Review(?:_\d+_[0-9A-Fa-f-]+)?\.png\z/.match?(entry["suggestedHumanReadableName"].to_s)
    end
    raise "Expected exactly one named iPhone Home Brief review PNG" unless images.size == 1
    name = images.first.fetch("exportedFileName")
    raise "Unexpected exported filename" unless /\A[0-9a-f-]{36}\.png\z/i.match?(name)
    path = File.join(directory, name)
    raise "Expected a regular screenshot file of at most 10 MiB" unless File.file?(path) && !File.symlink?(path) && File.size(path).between?(45, 10 * 1024 * 1024)
    data = File.binread(path)
    raise "Invalid iPhone PNG" unless data.start_with?("\x89PNG\r\n\x1a\n".b) && data.byteslice(12, 4) == "IHDR" &&
      data.byteslice(-8, 4) == "IEND" && data.byteslice(16, 8).unpack("N2").all? { |dim| dim.between?(600, 4000) }
    data
  end

  class Client < HomeBriefCatalog::Client
    def reserve(size)
      request(URI(ORIGIN + ASSETS), Net::HTTP::Post, {data: {
        type: "inAppPurchaseAppStoreReviewScreenshots", attributes: {fileName: FILE_NAME, fileSize: size},
        relationships: {inAppPurchaseV2: {data: {type: "inAppPurchases", id: PRODUCT}}}
      }}).fetch("data")
    end

    def upload(operation, bytes)
      url = URI(operation.fetch("url"))
      raise "Unexpected asset upload destination" unless url.scheme == "https" && url.host.to_s.end_with?(".apple.com") &&
        url.port == 443 && url.userinfo.nil? && url.fragment.nil? && operation["method"] == "PUT"
      req = Net::HTTP::Put.new(url.request_uri)
      Array(operation["requestHeaders"]).each do |header|
        name, value = header.values_at("name", "value")
        raise "Unexpected asset upload header" if %w[authorization proxy-authorization host cookie].include?(name.to_s.downcase)
        req[name] = value
      end
      req.body = bytes
      # Presigned Apple storage URLs get only their supplied headers, never the Connect token.
      result = Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: 15, read_timeout: 90) { |http| http.request(req) }
      raise "Apple asset upload failed (HTTP #{result.code})" unless result.is_a?(Net::HTTPSuccess)
    rescue URI::Error, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError
      raise "Apple asset upload connection failed", cause: nil
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
        ops = asset.fetch("attributes").fetch("uploadOperations").sort_by { |op| op.fetch("offset") }
        cursor = 0
        ops.each do |op|
          raise "Invalid upload byte ranges" unless op["offset"] == cursor && op["length"].is_a?(Integer) && op["length"].positive?
          cursor += op["length"]
        end
        raise "Apple upload operations must cover the entire PNG" unless cursor == bytes.bytesize
        ops.each { |op| @client.upload(op, bytes.byteslice(op["offset"], op["length"])) }
        @client.commit(id, checksum)
        wait_for_processing(id, checksum)
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

    def wait_for_processing(id, checksum)
      30.times do
        attrs = @client.get("#{ASSETS}/#{id}").fetch("data").fetch("attributes")
        state = attrs.fetch("assetDeliveryState").fetch("state")
        if state == "COMPLETE"
          raise "Processed screenshot checksum mismatch" unless attrs["sourceFileChecksum"] == checksum
          return
        end
        raise "Apple did not accept the screenshot (#{state})" unless %w[AWAITING_UPLOAD UPLOAD_COMPLETE].include?(state)
        sleep 2
      end
      raise "Apple is still processing the screenshot. Verify its state before retrying."
    end
  end
end
