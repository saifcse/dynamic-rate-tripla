require "net/http"

module Api::V1
  class PricingService < BaseService
    include ServiceLoggable
    include CircuitBreakable

    # Constants for high-throughput strategy
    CACHE_TTL = 5.minutes
    RACE_CONDITION_TTL = 10.seconds
    CIRCUIT_BREAKER_KEY = "circuit_breaker:rate_api"

    # Custom error for flow control
    class ApiFallbackError < StandardError; end

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      # Check if the Circuit Breaker is OPEN (tripped)
      if circuit_open?(CIRCUIT_BREAKER_KEY)
        log_error("Circuit is OPEN. Skipping API call for #{cache_key}")
        errors << "Rate service is cooling down. Please try again in 30s."
        return nil
      end

      self.result = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, race_condition_ttl: RACE_CONDITION_TTL) do
        log_info("CACHE_MISS_API_CALL: #{cache_key}. Fetching from API.")
        data = fetch_from_api
    
        # If data is nil, do NOT let fetch save it.
        raise ApiFallbackError, "API returned no data" if data.nil?
        
        data
      end
    rescue ApiFallbackError, SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
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
        # TRIP CIRCUIT for 429 OR any 5xx Server Error
        if response.code == 429 || (500..599).include?(response.code)
          log_error("API Error #{response.code}. Tripping circuit breaker for #{CIRCUIT_BREAKER_TTL}s")
          trip_circuit!(CIRCUIT_BREAKER_KEY)
        end

        log_error("API call failed with status #{response.code}") 
        handle_api_failure(response)
        nil # Rails.cache.fetch will not store this nil
      end
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
      # Trip the circuit for network/timeout issues too!
      # If the API is down, we shouldn't keep trying every millisecond.
      log_error("Network Error: #{e.message}. Tripping circuit breaker.")
      trip_circuit!(CIRCUIT_BREAKER_KEY)
      raise # Re-raise so the 'run' method rescue block handles the error message
    end

    def parse_rate_from_response(response_body)
      parsed = begin
        JSON.parse(response_body)
      rescue JSON::ParserError
        log_error("Invalid JSON from API for #{cache_key}")
        return nil
      end

      rates = Array(parsed['rates']) 
      
      rate_entry = rates.detect do |r| 
        r['period'] == @period && 
        r['hotel'] == @hotel && 
        r['room'] == @room 
      end

      rate_entry&.dig('rate')
    end  

    def handle_api_failure(response)
      case response.code
      when 429
        errors << "Rate API rate limit exceeded. Scaling back requests."
      when 500..599
        errors << "Rate API is currently overloaded. Please try again later."
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
