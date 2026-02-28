require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  setup do
    # Switch to MemoryStore so we can actually test caching logic
    @prior_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @params = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    @service = Api::V1::PricingService.new(**@params)
    @cache_key = "pricing/v1/FloatingPointResort/SingletonRoom/Summer"
    
    # Ensure a clean state for every test
    Rails.cache.clear
  end

  teardown do
    # Reset it so we don't break other tests in the suite
    Rails.cache = @prior_cache_store
  end

  test "cache miss case to fetch from API and stores in cache" do
    mock_body = { 'rates' => [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => '200' }] }.to_json
    mock_response = OpenStruct.new(success?: true, body: mock_body)

    RateApiClient.stub(:get_rate, mock_response) do
      result = @service.run
      
      assert_equal "200", result
      # Verify it was actually written to the cache
      assert_equal "200", Rails.cache.read(@cache_key)
    end
  end

  test "cache hit case to return data from cache without calling API" do
    # Pre-fill the cache
    Rails.cache.write(@cache_key, "300")

    # If the API is called, this test will fail because we aren't stubbing it
    # or we can stub it to return an error to prove it was never reached
    RateApiClient.stub(:get_rate, -> { flunk "API should not be called on cache hit" }) do
      result = @service.run
      assert_equal "300", result
    end
  end

  test "circuit breaker to trips on 429 and prevents API calls" do
    mock_response = OpenStruct.new(success?: false, code: 429, body: "Too Many Requests")

    # First call trips the circuit
    RateApiClient.stub(:get_rate, mock_response) do
      @service.run
      assert Rails.cache.exist?(Api::V1::PricingService::CIRCUIT_BREAKER_KEY)
    end

    # Second call should fail fast without hitting API
    RateApiClient.stub(:get_rate, -> { flunk "API called while circuit was open" }) do
      result = @service.run
      assert_nil result
      assert_includes @service.errors, "Rate service is cooling down. Please try again in 30s."
    end
  end

  test "circuit breaker to trips on 500 error" do
    mock_response = OpenStruct.new(success?: false, code: 500, body: "Internal Server Error")

    RateApiClient.stub(:get_rate, mock_response) do
      @service.run
      assert Rails.cache.exist?(Api::V1::PricingService::CIRCUIT_BREAKER_KEY)
    end
  end

  test "no-nil-caching case which does not store nil in cache on API failure" do
    mock_response = OpenStruct.new(success?: false, code: 404, body: "Not Found")

    RateApiClient.stub(:get_rate, mock_response) do
      @service.run
      # Cache should still be empty
      assert_nil Rails.cache.read(@cache_key)
    end
  end

  test "network failure case which trips circuit breaker on connection refused" do
    # Simulate network error
    RateApiClient.stub(:get_rate, ->(*) { raise Errno::ECONNREFUSED }) do
      @service.run
      assert Rails.cache.exist?(Api::V1::PricingService::CIRCUIT_BREAKER_KEY)
      assert_includes @service.errors, "Rate service temporarily unavailable. Please try again shortly."
    end
  end
end