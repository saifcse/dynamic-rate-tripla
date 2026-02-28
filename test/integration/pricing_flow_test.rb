require "test_helper"

class PricingFlowTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    # Loading JSON data once per test run
    @test_data = JSON.parse(File.read(Rails.root.join("test/fixtures/pricing_test_cases.json")))
  end

  test "verify all pricing scenarios from external JSON" do
    @test_data.each do |scenario|
      url = scenario["url"]
      expected = scenario["expected_rate"]
      p = scenario["params"]

      # Setup Mock for the specific API response
      mock_body = {
        'rates' => [
          { 'period' => p['period'], 'hotel' => p['hotel'], 'room' => p['room'], 'rate' => expected }
        ]
      }.to_json
      
      mock_response = OpenStruct.new(success?: true, body: mock_body)

      # Execute and Assert
      RateApiClient.stub(:get_rate, mock_response) do
        get url
        
        assert_response :success, "Endpoint failed for #{url}"
        
        json_response = JSON.parse(@response.body)
        assert_equal expected, json_response["rate"], "Rate mismatch for #{url}"
      end
    end
  end
end