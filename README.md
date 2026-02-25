# Requirement specification
 - Price rate validity: data fetched from rate model is not older than 5 mins(remains effective up to 5 minutes)
 - Optimal usage with constraints: have intermediary service to serve with high throughput(10k/day)  
 - Rate model API Rate Limit: The /pricing endpoint is limited to 1,000 requests per day. 


# Goal criteria
 - Performance optimization along with cost effectiveness
   -- Use cache mechanism
 - Failure/Error handling : exception case with proper error message(+ logging, tracing)
 - [Optional] log tracing
 - [Optional] `Connection Pooling` for network overhead

 # Proposed strategy:
  ## Caching
  - Memoizing (Caching) the expensive result:
    - Goal is to stop the request at service layer if we already have a "fresh" data-set.
    - Using a Low-Level Caching strategy with a shared store (like Redis) so that multiple app replicas can share the same cached rates.

  ## Implementation
   - Service object pattern:
     - Encapsulate in a Service Object with CACHE_TTL
     - Generate unique key based on the INPUT parameters
     - Rails.cache.fetch handles the "Read-else-Write" logic automatically before calling rate model
     - Error handling: using single API token, we need to handle 429 (Too Many Requests/slow doen), 503(overloaded/down) 500 errors here
   - Testing
     - `Unit Test` for new code of service class
     - [Optional]Integration test
   - Scaling for High Throughput (10k+ Requests)
     - Infrastructure: Use Redis as cache_store
     - Thundering Herd Protection: Use race_condition_ttl: 10.seconds in your Rails.cache.fetch
     - Connection Pooling: HTTP client (Faraday or HTTParty) to use connection pool so we aren't creating new TCP connections for every request.
     - 10k/day goal: With 10,000 requests and 1,000 allowed API calls, our `Cache Hit Ratio` needs to be at least 90%. 
     -- Current Strategy: 1 call per 5 minutes = 288 calls per day per unique hotel/room.
     -- [Optional] Etags: if we have hundreds of different hotels, we can implement "Conditional GET" (using ETags) to see if we can get data from the API without it counting against rate model's 1,000-call limit
  
  # Logging/Tracing
  - Since we are aiming for 10k/day and to use tools like Grafana for better visualization, we need to move beyond simple text strings in Rails.logger
  - To make logs "machine-readable" for a sidecar (like Fluentd), we should use Structured Logging to be used later for Grafana:
     -- Event-Based Metrics: In Grafana, we can count the event: "CACHE_MISS_API_CALL" to see exactly how close we are to 1,000 API limit in real-time.

     -- Trace Correlation: If a user reports a wrong price, we can search for that specific @trace_id and see every step: from the request start, through the cache check, to the API response.

     -- Performance Monitoring: By looking at the timestamps of PRICING_REQUEST_START and PRICING_REQUEST_END, we can calculate the latency of our service versus the external API.
     -- Filter by hotel_id or status in Grafana dashboards without complex regex

