# To simulate a 429 response manually, we need below line along with line 17 in RateApiClient
# require 'ostruct'

class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  
  # Set a timeout so we don't wait forever (in seconds)
  # This triggers Net::OpenTimeout or Net::ReadTimeout
  default_timeout 5

  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')

  def self.get_rate(period:, hotel:, room:)
    # Simulate a 429 response manually
    # return OpenStruct.new(success?: false, code: 429, body: "{}")

    params = {
      attributes: [
        {
          period: period,
          hotel: hotel,
          room: room
        }
      ]
    }.to_json
    self.post("/pricing", body: params)
  end
end
