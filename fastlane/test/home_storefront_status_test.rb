require "minitest/autorun"
require_relative "../home_storefront_status"

class HomeStorefrontStatusTest < Minitest::Test
  class ReadFixture
    attr_reader :requests
    def initialize
      @requests = []
    end

    def get(path, params = {})
      @requests << [path, params]
      case path
      when "/v1/apps/6817578211/appStoreVersions"
        raise unless params["filter[platform]"] == "IOS" && params["fields[appStoreReviewDetails]"].split(",").sort == HomeStorefrontStatus::CONTACT.sort
        {"data" => [version("draft", "PREPARE_FOR_SUBMISSION", ref("builds", "b"), ref("appStoreReviewDetails", "review"))],
         "included" => [
           ref("builds", "b").merge("attributes" => {"version" => "20"}),
           ref("appStoreReviewDetails", "review").merge("attributes" => {
             "contactFirstName" => "PrivateTestFirst", "contactLastName" => "PrivateTestLast",
             "contactEmail" => "private@example.invalid", "contactPhone" => nil})],
         "links" => {"next" => "/v1/next-fixture-page"}}
      when "/v1/next-fixture-page"
        {"data" => [version("live", "READY_FOR_DISTRIBUTION", nil, nil)]}
      when "/v1/apps/6817578211/appInfos"
        {"data" => [{"id" => "info", "attributes" => {"state" => "PREPARE_FOR_SUBMISSION"}}]}
      when "/v1/appStoreVersions/draft/appStoreVersionLocalizations"
        locale(params, "appStoreVersionLocalizations", "supportUrl", "https://hidden.example/support")
      when "/v1/appStoreVersions/live/appStoreVersionLocalizations"
        {"data" => []}
      when "/v1/appInfos/info/appInfoLocalizations"
        locale(params, "appInfoLocalizations", "privacyPolicyUrl", nil)
      else
        raise "Unexpected GET"
      end
    end

    def ref(type, id)
      {"type" => type, "id" => id}
    end
    def version(id, state, build, contact)
      {"id" => id, "attributes" => {"versionString" => "1.0", "appVersionState" => state},
       "relationships" => {"build" => {"data" => build}, "appStoreReviewDetail" => {"data" => contact}}}
    end
    def locale(params, resource, field, value)
      raise unless params == {"filter[locale]" => "en-US", "fields[#{resource}]" => "locale,#{field}"}
      {"data" => [{"attributes" => {"locale" => "en-US", field => value}}]}
    end
  end

  def test_exact_target_versions_and_localizations_are_separate_and_sensitive_values_stay_out_of_logs
    client = ReadFixture.new
    log = []
    HomeStorefrontStatus.new(client, app_id: "6817578211", log: ->(line) { log << line }).report
    result = log.join("\n")
    assert_includes result, "state=PREPARE_FOR_SUBMISSION | selectedBuild=20"
    assert_includes result, "contactFirstName=true contactLastName=true contactEmail=true contactPhone=false"
    assert_includes result, "state=READY_FOR_DISTRIBUTION | selectedBuild=none | reviewContact=none"
    assert_includes result, "en-US localization=absent"
    assert_includes result, "supportUrlPresent=true"
    assert_includes result, "privacyPolicyUrlPresent=false"
    assert_includes result, "iOS versions found=2"
    refute_match(/PrivateTest|private@|hidden\.example/, result)
    assert_equal 6, client.requests.length
  end

  def test_inaccessible_is_unknown_and_never_reported_as_missing
    client = Object.new
    client.define_singleton_method(:get) { |*| raise HomeBriefCatalog::ApiError.new(403, "FORBIDDEN") }
    log = []
    HomeStorefrontStatus.new(client, app_id: "6817578211", log: ->(line) { log << line }).report
    assert_equal 2, log.size
    assert log.all? { |line| line.include?("incomplete: Apple returned HTTP 403") }
    refute_match(/absent|false|found=0/, log.join)
    assert_raises(RuntimeError) { HomeStorefrontStatus.new(client, app_id: "unrelated", log: ->(*) {}) }
  end
end
