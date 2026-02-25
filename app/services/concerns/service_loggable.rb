module Concerns
  module ServiceLoggable
    extend ActiveSupport::Concern

    private

    def log_trace_id
      @trace_id ||= "#{SecureRandom.uuid}"
    end

    def log_info(event, extra = {})
      write_log(:info, event, extra)
    end

    def log_error(event, extra = {})
      write_log(:error, event, extra)
    end

    def write_log(level, event, extra)
      log_data = {
        timestamp: Time.current,
        event: event,
        trace_id: log_trace_id, # Unique identifier for tracing
        service: self.class.name,
        hotel_id: @hotel,
        room_id: @room 
      }.merge(extra)

      Rails.logger.send(level, log_data.to_json)
    end
  end
end