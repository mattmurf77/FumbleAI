# frozen_string_literal: true

require_relative "home_brief_catalog"

module HomeDraftBuild
  VERSION = "1.0"
  DRAFT = "PREPARE_FOR_SUBMISSION"
  ID = /\A[A-Za-z0-9-]{1,100}\z/

  class Client < HomeBriefCatalog::Client
    def select(draft_id, build_id)
      raise "Unexpected Apple resource ID" unless ID.match?(draft_id) && ID.match?(build_id)
      request(URI("#{ORIGIN}/v1/appStoreVersions/#{draft_id}/relationships/build"), Net::HTTP::Patch,
        {data: {type: "builds", id: build_id}})
    end
  end

  class Selection
    def initialize(client, app_id:, number:)
      raise "Expected the Home Blueprint app" unless app_id == HomeBriefCatalog::APP_ID
      raise "Select one positive numeric build number" unless /\A[1-9][0-9]{0,17}\z/.match?(number.to_s)
      @client = client
      @app_id = app_id
      @number = number.to_s
    end

    def run
      draft, = draft_and_build
      chosen = candidate_id
      current_draft, selected = draft_and_build
      raise "Draft version changed during selection" unless draft == current_draft
      path = "/v1/appStoreVersions/#{draft}/relationships/build"
      expected = {"type" => "builds", "id" => chosen}
      if selected
        return :already_selected if expected.all? { |k, v| selected[k] == v }
        raise "A different build is already selected; preserving the existing selection"
      end
      @client.select(draft, chosen)
      linked = @client.get(path).fetch("data")
      raise "Could not verify the selected build" unless linked && expected.all? { |k, v| linked[k] == v }
      :selected
    end

    private

    def draft_and_build
      page = @client.get("/v1/apps/#{@app_id}/appStoreVersions", {"filter[platform]" => "IOS", "filter[versionString]" => VERSION,
        "fields[appStoreVersions]" => "platform,versionString,appVersionState,build", "include" => "build",
        "fields[builds]" => "version", "limit" => 2})
      draft = unique(page, "appStoreVersions")
      attrs = draft.fetch("attributes")
      unless attrs["platform"] == "IOS" && attrs["versionString"] == VERSION && attrs["appVersionState"] == DRAFT
        raise "The exact iOS 1.0 version must still be in Prepare for Submission"
      end
      [draft.fetch("id"), draft.fetch("relationships").fetch("build").fetch("data")]
    end

    def candidate_id
      page = @client.get("/v1/builds", {"filter[app]" => @app_id, "filter[version]" => @number,
        "filter[preReleaseVersion.version]" => VERSION, "filter[preReleaseVersion.platform]" => "IOS",
        "filter[processingState]" => "VALID", "filter[expired]" => "false", "filter[buildAudienceType]" => "APP_STORE_ELIGIBLE",
        "fields[builds]" => "version,processingState,expired,buildAudienceType,app,preReleaseVersion", "include" => "app,preReleaseVersion",
        "fields[apps]" => "bundleId", "fields[preReleaseVersions]" => "version,platform", "limit" => 2})
      item = unique(page, "builds")
      attrs = item.fetch("attributes")
      release = item.fetch("relationships").fetch("preReleaseVersion").fetch("data")
      app = item.fetch("relationships").fetch("app").fetch("data")
      version = page.fetch("included").find { |row| row["type"] == "preReleaseVersions" && row["id"] == release["id"] }
      unless app["type"] == "apps" && app["id"] == @app_id && release["type"] == "preReleaseVersions" &&
             version&.dig("attributes", "version") == VERSION && version.dig("attributes", "platform") == "IOS" &&
             attrs["version"] == @number && attrs["processingState"] == "VALID" && attrs["expired"] == false &&
             attrs["buildAudienceType"] == "APP_STORE_ELIGIBLE"
        raise "The build must be valid, unexpired and App Store eligible for this app's iOS 1.0 train"
      end
      item.fetch("id")
    end

    def unique(page, type)
      rows = page.fetch("data")
      unless !page.dig("links", "next") && rows.size == 1 && rows.first["type"] == type && ID.match?(rows.first.fetch("id"))
        raise "Expected one unique #{type} match"
      end
      rows.first
    end
  end
end
