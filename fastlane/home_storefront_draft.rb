# frozen_string_literal: true

require_relative "home_brief_catalog"

module HomeStorefrontDraft
  VERSION = "1.0"
  EDITABLE = "PREPARE_FOR_SUBMISSION"
  VERSION_LOCALE = "appStoreVersionLocalizations"
  INFO_LOCALE = "appInfoLocalizations"
  VALUES = {
    VERSION_LOCALE => {
      "supportUrl" => "https://home-server-ecxo.onrender.com/support",
      "description" => "See what needs doing around your home and keep a history of work you have finished. Schedule maintenance, check which supplies you already own, and make a shopping list for DIY projects. Keep track of appliances and equipment.\n\nRecord repairs and improvements with dates, costs and receipts. Import past projects from a CSV spreadsheet or add documents and review the details you want to save. An optional one-time Home Brief purchase lets you export selected completed projects as a PDF.",
      "keywords" => "maintenance,repairs,upkeep,chores,projects,receipts,appliances,inventory,DIY"
    }.freeze,
    INFO_LOCALE => {"privacyPolicyUrl" => "https://home-server-ecxo.onrender.com/privacy"}.freeze
  }.freeze

  class Client < HomeBriefCatalog::Client
    def fill(localization, changes)
      type = localization.fetch("type")
      id = localization.fetch("id")
      expected = VALUES.fetch(type)
      unless /\A[A-Za-z0-9-]{1,100}\z/.match?(id) && !changes.empty? && changes.all? { |key, value| expected.key?(key) && value == expected[key] }
        raise "Unexpected localization update"
      end
      request(URI("#{ORIGIN}/v1/#{type}/#{id}"), Net::HTTP::Patch, {data: {type: type, id: id, attributes: changes}})
    end
  end

  class Editor
    def initialize(client, app_id:, log:)
      raise "Expected the Home Blueprint app" unless app_id == HomeBriefCatalog::APP_ID
      @client = client
      @app = "/v1/apps/#{app_id}"
      @log = log
    end

    def run
      # Preflight both parents and locales before any write. Re-read on each
      # mutation so reruns and partially completed operations preserve owner edits.
      initial = targets
      VALUES.each do |type, fields|
        row = targets.fetch(type)
        raise "Draft localization changed before update" unless row["id"] == initial.fetch(type).fetch("id")
        changes = fields.select { |key, _| row.fetch("attributes")[key].to_s.strip.empty? }
        if changes.empty?
          @log.call("#{type}: existing en-US values preserved")
          next
        end
        @client.fill(row, changes)
        verified = targets.fetch(type)
        unless verified["id"] == row["id"] && changes.all? { |key, value| verified.fetch("attributes")[key] == value }
          raise "Draft localization readback failed"
        end
        @log.call("#{type}: verified en-US fields #{changes.keys.join(', ')}; remaining fields preserved")
      end
    end

    private

    def targets
      version = single("#{@app}/appStoreVersions", {"filter[platform]" => "IOS", "filter[versionString]" => VERSION,
        "fields[appStoreVersions]" => "platform,versionString,appVersionState", "limit" => 200}, "appStoreVersions") do |attrs|
        attrs["platform"] == "IOS" && attrs["versionString"] == VERSION && attrs["appVersionState"] == EDITABLE
      end
      info = single("#{@app}/appInfos", {"fields[appInfos]" => "state", "limit" => 200}, "appInfos") { |attrs| attrs["state"] == EDITABLE }
      {VERSION_LOCALE => localization(version, VERSION_LOCALE), INFO_LOCALE => localization(info, INFO_LOCALE)}
    end

    def localization(parent, type)
      single("/v1/#{parent['type']}/#{parent['id']}/#{type}",
        {"filter[locale]" => "en-US", "fields[#{type}]" => (["locale"] + VALUES.fetch(type).keys).join(",")}, type) do |attrs|
        attrs["locale"] == "en-US"
      end
    end

    def single(path, params, type)
      response = @client.get(path, params)
      raise "Unable to establish unique draft on a paginated response" if response.dig("links", "next")
      matches = response.fetch("data").select { |row| row["type"] == type && yield(row.fetch("attributes")) }
      raise "Expected one matching #{type} record" unless matches.size == 1 && /\A[A-Za-z0-9-]{1,100}\z/.match?(matches.first.fetch("id"))
      matches.first
    end
  end
end
