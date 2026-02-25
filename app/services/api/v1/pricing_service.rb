module Api::V1
  class PricingService < BaseService

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      # TODO: Start to implement here
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)
      if response.success?
        parse_rate_from_response(response.body)
      else
        handle_api_failure(response)
        # errors << rate.body['error']
      end
    end

    def parse_rate_from_response(response_body)
      parsed = JSON.parse(response_body)
      parsed['rates'].detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }&.dig('rate')
    end  

    def handle_api_failure(response)
      case response.status
      when 429
        errors << "Rate API rate limit exceeded. Scaling back requests."
      when 500..599
        errors << "External AI Model is currently overloaded. Please try again later."
      else
        errors << "Failed to fetch rate from API: #{response.status}"
      end
  end
end
