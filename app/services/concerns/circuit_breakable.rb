module CircuitBreakable
  extend ActiveSupport::Concern

 # Duration to stop hitting the API after a 429/5xx/network error
  CIRCUIT_BREAKER_TTL = 30.seconds

  def circuit_open?(key)
    Rails.cache.exist?(key)
  rescue Redis::CannotConnectError => e
    log_error("Redis unreachable checking circuit #{key}: #{e.message}. Failing open.")
    false
  end

  def trip_circuit!(key)
    Rails.cache.write(key, true, expires_in: CIRCUIT_BREAKER_TTL)
  end
end
