require "minitest/autorun"
require_relative "../home_draft_build"

class HomeDraftBuildTest < Minitest::Test
  class Fixture
    attr_accessor :link, :duplicates, :expired, :state, :app, :platform, :version, :processing, :audience, :drop_write
    attr_reader :writes, :lookups
    def initialize
      @lookups, @writes = [], []
      @app = "6817578211"
      @version, @platform, @processing, @expired, @audience = "1.0", "IOS", "VALID", false, "APP_STORE_ELIGIBLE"
      @state = HomeDraftBuild::DRAFT
    end
    def get(path, params = {})
      @lookups << path
      case path
      when "/v1/apps/6817578211/appStoreVersions"
        raise "Wrong app version query" unless params["filter[versionString]"] == "1.0" && params["filter[platform]"] == "IOS"
        {"data" => [{"type" => "appStoreVersions", "id" => "v1", "relationships" => {"build" => {"data" => @link}}, "attributes" => {
          "platform" => "IOS", "versionString" => "1.0", "appVersionState" => @state}}]}
      when "/v1/builds"
        raise "Wrong build query" unless params["filter[app]"] == "6817578211" && params["filter[version]"] == "32" &&
          params["filter[preReleaseVersion.version]"] == "1.0" && params["filter[preReleaseVersion.platform]"] == "IOS"
        item = {"type" => "builds", "id" => "b32", "attributes" => {"version" => "32", "expired" => @expired,
          "processingState" => @processing, "buildAudienceType" => @audience}, "relationships" => {
          "app" => {"data" => {"type" => "apps", "id" => @app}},
          "preReleaseVersion" => {"data" => {"type" => "preReleaseVersions", "id" => "release"}}}}
        {"data" => @duplicates ? [item, item] : [item], "included" => [
          {"type" => "preReleaseVersions", "id" => "release", "attributes" => {"version" => @version, "platform" => @platform}}]}
      when "/v1/appStoreVersions/v1/relationships/build"
        {"data" => @link}
      else
        raise "Unexpected GET"
      end
    end
    def select(id, build)
      @writes << [id, build]
      @link = {"type" => "builds", "id" => build} unless @drop_write
    end
  end

  def setup
    @apple = Fixture.new
    @selector = HomeDraftBuild::Selection.new(@apple, app_id: "6817578211", number: "32")
  end

  def test_links_once_and_reads_it_back_without_resubmitting_or_uploading
    assert_equal :selected, @selector.run
    assert_equal [["v1", "b32"]], @apple.writes
    assert_equal "/v1/appStoreVersions/v1/relationships/build", @apple.lookups.last
    assert_equal :already_selected, @selector.run
    assert_equal 1, @apple.writes.length
  end

  def test_different_selected_build_is_preserved
    @apple.link = {"type" => "builds", "id" => "older"}
    assert_raises(RuntimeError) { @selector.run }
    assert_equal "older", @apple.link["id"]
    assert_empty @apple.writes
  end

  def test_wrong_scope_ambiguous_or_ineligible_build_makes_no_change
    {duplicates: true, app: "other", version: "0.1.0", platform: "MAC_OS", expired: true,
     audience: "INTERNAL_ONLY", state: "READY_FOR_REVIEW", processing: "PROCESSING"}.each do |attribute, bad|
      saved = @apple.public_send(attribute)
      @apple.public_send("#{attribute}=", bad)
      assert_raises(RuntimeError) { @selector.run }
      @apple.public_send("#{attribute}=", saved)
    end
    assert_raises(RuntimeError) { HomeDraftBuild::Selection.new(@apple, app_id: "elsewhere", number: "32") }
    assert_raises(RuntimeError) { HomeDraftBuild::Selection.new(@apple, app_id: "6817578211", number: " 32") }
    assert_empty @apple.writes
  end

  def test_failed_readback_is_an_error
    @apple.drop_write = true
    assert_raises(RuntimeError) { @selector.run }
  end

  def test_only_the_build_relationship_is_patched
    client = HomeDraftBuild::Client.new(nil)
    captured = []
    client.define_singleton_method(:request) { |uri, method, payload| captured << [uri.to_s, method, payload] }
    client.select("v1", "b32")
    assert_equal [["https://api.appstoreconnect.apple.com/v1/appStoreVersions/v1/relationships/build",
      Net::HTTP::Patch, {data: {type: "builds", id: "b32"}}]], captured
    assert_raises(RuntimeError) { client.select("v1/build", "b32") }
  end
end
