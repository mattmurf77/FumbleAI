require_relative "home_brief_catalog"

# App Store version information and app-level privacy information have distinct
# localizations. Read each parent separately so draft and published values stay distinct.
class HomeStorefrontStatus
  CONTACT = %w[contactFirstName contactLastName contactEmail contactPhone].freeze

  def initialize(client, app_id:, log:)
    raise "This report is scoped to Home Blueprint" unless app_id == HomeBriefCatalog::APP_ID
    @client = client
    @log = log
    @app = "/v1/apps/#{app_id}"
  end

  def report
    versions = {
      "filter[platform]" => "IOS", "limit" => 200, "include" => "build,appStoreReviewDetail",
      "fields[appStoreVersions]" => "versionString,appVersionState,build,appStoreReviewDetail",
      "fields[builds]" => "version", "fields[appStoreReviewDetails]" => CONTACT.join(",")
    }
    inventory("iOS versions", "#{@app}/appStoreVersions", versions) do |version, included|
      attrs = version.fetch("attributes")
      build = related(version, "build", included)
      contact = related(version, "appStoreReviewDetail", included)
      number = build.is_a?(Hash) ? build.fetch("version", "unknown") : build
      contacts = if contact.is_a?(Hash)
                   CONTACT.map { |key| "#{key}=#{!contact[key].to_s.strip.empty?}" }.join(" ")
                 else
                   "reviewContact=#{contact}"
                 end
      @log.call("iOS version #{attrs.fetch('versionString')} | state=#{attrs.fetch('appVersionState')} | selectedBuild=#{number} | #{contacts}")
      localization("/v1/appStoreVersions/#{version.fetch('id')}", "appStoreVersionLocalizations", "supportUrl") do |locale|
        screenshots(locale) if attrs.values_at("versionString", "appVersionState") == ["1.0", "PREPARE_FOR_SUBMISSION"]
      end
    end
    inventory("app information", "#{@app}/appInfos", {"fields[appInfos]" => "state", "limit" => 200}) do |info, _|
      @log.call("App information | state=#{info.fetch('attributes').fetch('state')}")
      localization("/v1/appInfos/#{info.fetch('id')}", "appInfoLocalizations", "privacyPolicyUrl")
    end
  end

  private

  def inventory(label, path, params)
    page = @client.get(path, params)
    count = 0
    loop do
      page.fetch("data").each { |item| yield item, page.fetch("included", []); count += 1 }
      following = page.dig("links", "next")
      break unless following
      page = @client.get(following)
    end
    @log.call("Home Blueprint #{label} found=#{count}")
  rescue HomeBriefCatalog::ApiError => error
    @log.call("Home Blueprint #{label} inventory incomplete: #{error.message}")
  end

  def related(parent, name, included)
    link = parent.dig("relationships", name)
    return "unknown" unless link && link.key?("data")
    reference = link["data"]
    return "none" if reference.nil?
    record = included.find { |row| row["type"] == reference["type"] && row["id"] == reference["id"] }
    record&.fetch("attributes", nil) || "unknown"
  end

  def localization(parent, resource, field)
    rows = @client.get("#{parent}/#{resource}", {"filter[locale]" => "en-US",
      "fields[#{resource}]" => "locale,#{field}"}).fetch("data")
    matches = rows.select { |row| row.dig("attributes", "locale") == "en-US" }
    case matches.size
    when 0 then @log.call("  en-US localization=absent")
    when 1
      @log.call("  en-US localization=present | #{field}Present=#{!matches.first.dig('attributes', field).to_s.strip.empty?}")
      yield matches.first if block_given?
    else @log.call("  en-US localization=ambiguous")
    end
  rescue HomeBriefCatalog::ApiError => error
    @log.call("  en-US localization=unknown (#{error.message})")
  end

  def screenshots(locale)
    locale_id = locale["id"].to_s
    unless /\A[A-Za-z0-9-]{1,100}\z/.match?(locale_id)
      @log.call("  1.0 en-US screenshot inventory=unknown (localization ID unavailable)")
      return
    end
    inventory("1.0 en-US screenshot sets", "/v1/appStoreVersionLocalizations/#{locale_id}/appScreenshotSets",
      {"fields[appScreenshotSets]" => "screenshotDisplayType", "limit" => 200}) do |set, _|
      set_id = set["id"].to_s
      unless /\A[A-Za-z0-9-]{1,100}\z/.match?(set_id)
        @log.call("  1.0 en-US screenshot inventory=unknown (set ID unavailable)")
        next
      end
      display = set.fetch("attributes").fetch("screenshotDisplayType", "unknown")
      @log.call("  Screenshot set=#{set_id} | display=#{display.inspect}")
      inventory("1.0 en-US screenshot set #{set_id} assets", "/v1/appScreenshotSets/#{set_id}/appScreenshots",
        {"fields[appScreenshots]" => "fileName,sourceFileChecksum,assetDeliveryState", "limit" => 20}) do |asset, _|
        attrs = asset.fetch("attributes")
        @log.call("    screenshot file=#{attrs['fileName'].inspect} | checksum=#{attrs['sourceFileChecksum'].inspect} | state=#{attrs.dig('assetDeliveryState', 'state').inspect}")
      end
    end
  end
end
