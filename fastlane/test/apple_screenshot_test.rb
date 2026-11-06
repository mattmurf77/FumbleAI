require "minitest/autorun"
require_relative "../apple_screenshot"

class AppleScreenshotTest < Minitest::Test
  class Processing
    attr_reader :reads
    def initialize(complete_after:)
      @complete_after, @reads = complete_after, 0
    end

    def get(path)
      raise "Unexpected asset" unless path == "/v1/appScreenshots/test-id"
      @reads += 1
      {"data" => {"attributes" => {
        "assetDeliveryState" => {"state" => @reads > @complete_after ? "COMPLETE" : "UPLOAD_COMPLETE"},
        "sourceFileChecksum" => "expected"
      }}}
    end
  end

  def test_upload_can_finish_processing_after_the_previous_one_minute_limit
    api = Processing.new(complete_after: 40)
    AppleScreenshot.stub(:sleep, nil) do
      AppleScreenshot.wait_for_processing(api, "/v1/appScreenshots", "test-id", "expected")
    end
    assert_equal 41, api.reads
  end

  def test_processing_wait_is_bounded_and_does_not_reupload_or_delete_the_asset
    api = Processing.new(complete_after: 1_000)
    AppleScreenshot.stub(:sleep, nil) do
      error = assert_raises(RuntimeError) do
        AppleScreenshot.wait_for_processing(api, "/v1/appScreenshots", "test-id", "expected")
      end
      assert_match "Verify its state before retrying", error.message
    end
    assert_equal 150, api.reads
  end
end
