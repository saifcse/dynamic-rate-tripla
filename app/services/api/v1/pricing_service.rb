module Api::V1
  class PricingService < BaseService
    include ::Concerns::ServiceLoggable

    # Constants for high-throughput strategy
    CACHE_TTL = 5.minutes
    RACE_CONDITION_TTL = 10.seconds

    # Custom error for flow control
    class ApiFallbackError < StandardError; end

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      @result = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, race_condition_ttl: RACE_CONDITION_TTL) do
        log_info("Cache miss for #{cache_key}. Fetching from API.")
        fetch_from_api
      end
    rescue ApiFallbackError, SocketError, Errno::ECONNREFUSED, Net::OpenTimeout => e
      # Failure/Error handling: Logging the specific exception
      log_error("Failed for #{cache_key}: #{e.message}")
      errors << "Rate service temporarily unavailable. Please try again shortly."
      nil
    end

    private

    def fetch_from_api
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)

      if response.success?
        parse_rate_from_response(response.body)
      else
        log_error("API call failed with status", { status: response.code, body: response.body }) 
        # Handle specific status codes (429 Too Many Requests, 503 Overloaded)
        handle_api_failure(response)
        # Return nil so Rails.cache doesn't persist the error/failure
        nil 
      end
    end

    def parse_rate_from_response(response_body)
      parsed = JSON.parse(response_body)
      parsed['rates'].detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }&.dig('rate')
    end  

    def handle_api_failure(response)
      case response.code
      when 429
        errors << "Rate API rate limit exceeded. Scaling back requests."
      when 500..599
        errors << "External AI Model is currently overloaded. Please try again later."
      else
        errors << "Failed to fetch rate from API: #{response.code}"
      end
    end

    def cache_key
      # Unique key based on input parameters to ensure users get the right rates
      "pricing/v1/#{@hotel}/#{@room}/#{@period}"
    end
  end
end
