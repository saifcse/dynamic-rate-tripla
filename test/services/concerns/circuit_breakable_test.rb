require "test_helper"

class CircuitBreakableTest < ActiveSupport::TestCase
  # Minimal test double that includes the concern
  class TestService
    include CircuitBreakable
    
    # Stub log_error so the Redis failsafe rescue doesn't blow up
    def log_error(msg); end
  end

  TEST_KEY = "circuit_breaker:test_service"

  setup do
    @prior_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    @service = TestService.new
  end

  teardown do
    Rails.cache = @prior_cache_store
  end

  test "circuit_open? returns false when no key exists" do
    assert_not @service.circuit_open?(TEST_KEY)
  end

  test "circuit_open? returns true when key exists in cache" do
    Rails.cache.write(TEST_KEY, true)
    assert @service.circuit_open?(TEST_KEY)
  end

  test "trip_circuit! writes key to cache with TTL" do
    @service.trip_circuit!(TEST_KEY)
    assert Rails.cache.exist?(TEST_KEY)
  end

  test "trip_circuit! key expires after CIRCUIT_BREAKER_TTL" do
    # Travel past the TTL and confirm the key is gone
    @service.trip_circuit!(TEST_KEY)
    travel CircuitBreakable::CIRCUIT_BREAKER_TTL + 1.second do
      assert_not Rails.cache.exist?(TEST_KEY)
    end
  end

  test "circuit_open? fails open (returns false) when Redis is unreachable" do
    Rails.cache.stub(:exist?, ->(*) { raise Redis::CannotConnectError }) do
      assert_not @service.circuit_open?(TEST_KEY)  # fails open, does not raise
    end
  end
end
