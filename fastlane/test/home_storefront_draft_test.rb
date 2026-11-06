require "minitest/autorun"
require_relative "../home_storefront_draft"

class HomeStorefrontDraftTest < Minitest::Test
  DRAFT = HomeStorefrontDraft
  class Apple
    attr_reader :version, :info, :listing, :privacy, :writes
    attr_accessor :duplicate, :fail_verify, :block_privacy

    def initialize
      @version = make("appStoreVersions", "v1", {"platform" => "IOS", "versionString" => "1.0", "appVersionState" => DRAFT::EDITABLE})
      @info = make("appInfos", "i1", {"state" => DRAFT::EDITABLE})
      @listing = make(DRAFT::VERSION_LOCALE, "l1", {"locale" => "en-US", "keywords" => "publisher keywords"})
      @privacy = make(DRAFT::INFO_LOCALE, "p1", {"locale" => "en-US", "name" => "Keep this name"})
      @writes = []
    end

    def make(type, id, attrs)
      {"type" => type, "id" => id, "attributes" => attrs}
    end

    def get(path, params)
      row = case path
      when "/v1/apps/6817578211/appStoreVersions"
        raise unless params["filter[platform]"] == "IOS" && params["filter[versionString]"] == "1.0"
        @version
      when "/v1/apps/6817578211/appInfos" then @info
      when "/v1/appStoreVersions/v1/appStoreVersionLocalizations" then @listing
      when "/v1/appInfos/i1/appInfoLocalizations" then @privacy
      else raise "Unscoped GET"
      end
      raise if path.end_with?("Localizations") && params["filter[locale]"] != "en-US"
      records = [row]
      records << row if @duplicate && row == @info
      {"data" => Marshal.load(Marshal.dump(records))}
    end

    def fill(row, changes)
      raise "Fixture denied second write" if @block_privacy && row["id"] == @privacy["id"]
      @writes << [row["id"], changes.keys]
      target = [@listing, @privacy].find { |item| item["id"] == row["id"] }
      target.fetch("attributes").merge!(changes) unless @fail_verify
    end
  end

  def setup
    @apple = Apple.new
    @editor = DRAFT::Editor.new(@apple, app_id: "6817578211", log: ->(_) {})
  end

  def test_fills_only_blank_en_us_fields_and_preserves_owner_values_on_repeat
    @editor.run
    assert_equal [["l1", %w[supportUrl description]], ["p1", %w[privacyPolicyUrl]]], @apple.writes
    assert_equal "publisher keywords", @apple.listing["attributes"]["keywords"]
    assert_equal "Keep this name", @apple.privacy["attributes"]["name"]
    assert_equal DRAFT::VALUES[DRAFT::INFO_LOCALE]["privacyPolicyUrl"], @apple.privacy["attributes"]["privacyPolicyUrl"]
    @editor.run
    assert_equal 2, @apple.writes.size
  end

  def test_rejects_wrong_app_noneditable_parent_version_or_locale_before_any_write
    assert_raises(RuntimeError) { DRAFT::Editor.new(@apple, app_id: "other", log: ->(_) {}) }
    [[@apple.version, "appVersionState", "READY_FOR_DISTRIBUTION"], [@apple.version, "versionString", "0.1.0"],
     [@apple.version, "platform", "MAC_OS"], [@apple.info, "state", "WAITING_FOR_REVIEW"],
     [@apple.privacy, "locale", "fr-FR"]].each do |row, key, value|
      old = row["attributes"][key]
      row["attributes"][key] = value
      assert_raises(RuntimeError) { @editor.run }
      row["attributes"][key] = old
    end
    @apple.duplicate = true
    assert_raises(RuntimeError) { @editor.run }
    assert_empty @apple.writes
  end

  def test_reports_unverified_update_and_can_resume_a_partial_completion_without_overwriting_listing
    @apple.fail_verify = true
    assert_raises(RuntimeError) { @editor.run }
    assert_equal ["l1"], @apple.writes.map(&:first)
    @apple.fail_verify = false
    @apple.block_privacy = true
    assert_raises(RuntimeError) { @editor.run }
    @apple.block_privacy = false
    @apple.listing["attributes"]["description"] = "Publisher revision"
    @editor.run
    assert_equal 2, @apple.writes.count { |op| op[0] == "l1" }
    assert_equal "Publisher revision", @apple.listing["attributes"]["description"]
    assert_equal "p1", @apple.writes.last.first
  end

  def test_client_only_allows_the_exact_apple_localization_payloads
    ops = []
    client = DRAFT::Client.new(nil)
    client.define_singleton_method(:request) { |uri, method, body| ops << [uri.to_s, method, body] }
    attrs = DRAFT::VALUES[DRAFT::VERSION_LOCALE].slice("supportUrl")
    client.fill(@apple.listing, attrs)
    assert_equal "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/l1", ops.first[0]
    assert_equal Net::HTTP::Patch, ops.first[1]
    assert_equal({type: DRAFT::VERSION_LOCALE, id: "l1", attributes: attrs}, ops.first[2][:data])
    assert_raises(RuntimeError) { client.fill(@apple.privacy, {"privacyPolicyUrl" => "https://other.example/policy"}) }
    assert_raises(RuntimeError) { client.fill(@apple.listing, {"description" => "unauthorized copy"}) }
    assert_raises(RuntimeError) { client.fill(@apple.listing, {"whatsNew" => "other feature"}) }
    assert_raises(KeyError) { client.fill(@apple.version, {"versionString" => "2.0"}) }
    assert_operator DRAFT::VALUES[DRAFT::VERSION_LOCALE]["keywords"].bytesize, :<=, 100
  end
end
