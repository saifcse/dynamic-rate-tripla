# About This Document
This document extends the base scaffolding README provided by Tripla (https://github.com/umami-dev/interview/blob/main/dynamic-pricing/README.md). The quick start guide remains the same as described there; this document covers the architecture decisions, trade-offs, and implementation notes added on top.

---

# Requirements

- Price rate validity: data fetched from rate model is not older than 5 mins(remains effective up to 5 minutes)
- Optimal usage with constraints: have intermediary service to serve with high throughput(10k/day)
- Rate model API Rate Limit: The /pricing endpoint is limited to 1,000 requests per day.

# Goals

- Performance optimization along with cost effectiveness
- Failure/Error handling : exception case with proper error message(+ logging, tracing)
- [Optional] `Connection Pooling` for network overhead
- [Optional] `Circuit breaker` to prevent indefinite API call on failure

---

# Architecture & Design

## Caching Strategy

**Approach:** Low-level caching via `Rails.cache.fetch` with a shared Redis store and a 5-minute TTL — intercepts requests at the service layer before they reach the rate API.

| Aspect | Detail |
|---|---|
| **Store** | Redis (shared across all app replicas) |
| **TTL** | 5 minutes — acts as a hard freshness boundary; expired cache triggers an API refresh |
| **Goal** | Serve repeated requests from cache, keeping API usage within the 1,000-call daily limit |

## Service Object Pattern

**Approach:** Business logic encapsulated in `Api::V1::PricingService`, keeping controllers thin and the caching/error-handling logic testable in isolation.

| Responsibility | Implementation |
|---|---|
| **Cache key** | Unique per request: `pricing/v1/{hotel}/{room}/{period}` |
| **Cache read/write** | "Read-else-Write" via `Rails.cache.fetch` — reads cache first, calls API only on miss |
| **Error handling** | Handles 429 (rate limit), 500–503 (server errors) with user-facing error messages |

## Scaling for High Throughput (10k+ Requests)

**Goal:** Serve 10,000 requests/day using at most 1,000 API calls — requiring a minimum 90% cache hit ratio (1 API call per 5 minutes = 288 calls/day per unique combination).

| Strategy | Implementation | Why |
|---|---|---|
| **Shared Cache** | `config.cache_store = :redis_cache_store` | Multiple app replicas share the same cached rates |
| **Thundering Herd Protection** | `race_condition_ttl: 10.seconds` in `Rails.cache.fetch` | Prevents simultaneous cache-miss requests from all hitting the API at once |
| **Circuit Breaker** | Global "Mute" key in Redis (30s TTL) — no heavy gems like `stoplight` | On 429/5xx, one request sets the key; all subsequent requests skip the API until it expires. Prevents a nil-returning API from being hammered indefinitely |
| **Connection Pooling** | `persistent_httparty` (pool of 10 persistent TCP connections) | Avoids per-request TCP handshake overhead; reuses established connections |

**Optional future improvements:**
- Configure connection pooling for Redis as well
- Add a stale data strategy — serve the last cached value when the API returns nil or errors
- Load/performance test to validate throughput under burst traffic

## Logging & Tracing

**Approach:** Use structured (JSON) logging via `Rails.logger` so logs are machine-readable by sidecars like Fluentd and can be visualized in Grafana dashboards.

| Capability | What It Enables |
|---|---|
| **Event-Based Metrics** | Count `CACHE_MISS_API_CALL` events in Grafana to monitor real-time proximity to the 1,000 API call limit |
| **Trace Correlation** | Search by `trace_id` to replay every step of a request — cache check, API call, response — when debugging a wrong price |
| **Performance Monitoring** | Diff log timestamps to calculate service latency vs. external API latency |
| **Structured Filtering** | Filter by `hotel_id` or `room_id` in Grafana without complex regex |

---

# Trade-offs

## Caching: Redis vs. No Cache
We trade perfect real-time accuracy for system survival. Direct API calls would exhaust the 1,000-request daily limit quickly, whereas caching ensures 100% uptime for 10k+ requests.

## Caching: Redis vs. Basic In-Memory/File Cache
We trade minimal setup complexity for global consistency. Redis allows multiple web workers/servers to share the same 5-minute "fresh" window, preventing each server from redundantly hitting the API.

## Capacity: From 10k Requests to 1k API Calls
Average QPS is low (10,000 ÷ 86,400s ≈ 0.11 QPS), but web traffic is bursty — we might receive 500 requests in a single minute. To stay within the API limit, we must serve at least 10 cached responses for every 1 API call (90% cache hit ratio).

- **High Throughput:** handled by Redis sub-2ms cache reads — 9,136 out of 10,000 requests (91.3%) get an instant cache hit from Redis (<2ms response time).
- **Rate Limit Protection:** handled by the 5-minute TTL (`expires_in: 5.minutes`).
- **Concurrency Protection:** handled by `race_condition_ttl: 10.seconds` (thundering herd prevention).

**5-Minute Window — How far can we go?**
One unique combination (Hotel + Room + Period) needs at most 288 API calls/day to stay fresh. The table below shows how many unique combinations we can support before hitting the 1,000-call daily limit:

| Unique API Combinations | API Calls/Day | Within 1,000 Limit? |
|---|---|---|
| 1 (e.g. 1 hotel/room/period) | 288 | ✅ Yes |
| 3 | 864 | ✅ Yes |
| 3 + buffer | 864 + headroom | ✅ Yes (~136 calls spare) |
| 4 | 1,152 | ❌ Exceeds limit |

> **Beyond 3 unique combinations — ETags / Conditional GET**
> On cache expiry, send the saved ETag back via `If-None-Match`. If unchanged, the API replies `304 Not Modified` — typically free against the rate limit and no body transferred — scaling capacity from ~3 to **100+ unique combinations**.
> _Requires the outside API to support `ETag` + `If-None-Match` headers._

## Summary

| Problem | Strategy | Rails Tool |
|---|---|---|
| Throughput > API Limit | Time-based Expiration | `Rails.cache.fetch(expires_in: 5.minutes)` |
| Burst Traffic | Race Condition Protection | `race_condition_ttl: 10.seconds` |
| Resource Exhaustion | Fail-Fast / Circuit Breaking | Redis-backed global "Mute" key |
| Multiple Web Servers | Distributed Caching | `config.cache_store = :redis_cache_store` |

---

# Environment Setup

## Redis:
```bash
# Need to add redis in Gemfile
# Use Redis adapter to run Action Cable in production
gem "redis", ">= 4.0.1"

# to enable rails cache (toggled)
docker compose exec interview-dev ./bin/rails dev:cache
  # output: Development mode is now being cached.

# Restart: usually need to restart the web container (docker compose restart interview-dev) after toggling the cache for the environment change to take full effect.
# Verify: Run 
docker compose exec interview-dev ./bin/rails c 
# and try writing to cache
Rails.cache.write("test", 1)

# get container logs
docker compose exec interview-dev tail -f log/development.log
```

---

# Testing

- `Unit Test` for service class:
   - cache miss case to fetch from API and stores in cache
   - cache hit case to return data from cache without calling API
   - case of circuit breaker that trips on 429/500 and prevents API calls
   - case on no-nil-caching, which does not store nil in cache on API failure
   - case on network failure, which trips circuit breaker on connection refused
- `Unit Test` for CircuitBreakable concern
- `Integration test`: data-driven integration test, we can iterate over a collection of URLs and verify that each one returns a successful response. This is a very clean way to test multiple scenarios (different hotels, rooms, or periods) without duplicating test code.
   - Use JSON data file: to separate `Test Logic` from `Test Data`. It makes the test suite cleaner and allows non-developers (like QA or Product) to potentially add test cases just by editing a JSON file (added 4 different API endpoints to test at once via a single file)

```bash
# test run specific case
docker compose exec interview-dev ./bin/rails test test/services/api/v1/pricing_service_test.rb -n test_cache_miss_case_to_fetch_from_API_and_stores_in_cache

# test whole class
docker compose exec interview-dev ./bin/rails test test/services/api/v1/pricing_service_test.rb
docker compose exec interview-dev ./bin/rails test dynamic-pricing/test/services/concerns/circuit_breakable_test.rb
```

---

# Manual Testing & Debugging

## Simulate a 429 response manually in rate_api_client.rb
```bash
# add below on top or comment out at line:2
require 'ostruct'
# inside get_rate method, add or comment out line: 23
return OpenStruct.new(success?: false, code: 429, body: "{}")
# comment out line: 34
self.post("/pricing", body: params)
```
## Implemented connection pool using HTTParty::Persistent.
  - Even though we implemented connection pooling, we got a `close` header from the rate API, so couldn't prove it.
  - To see connection pool status:
    `docker-compose exec interview-dev sh -c "netstat -ant | grep :8080"`
   -- if we see `ESTABLISHED` from above command, means it is working for opened connections

  - In service (fetch_from_api method), we confirmed it by logging connection header:
    `log_info("DEBUG: Connection Header from API: #{response.headers['connection']}")`
   --> got connection `close` header from rate API :
  - log while testing using above code:
```bash
{"timestamp":"2026-02-25T21:19:08.275Z","event":"DEBUG: Connection Header from API: close","trace_id":"c97c79c8-2ebb-4ae2-a1a1-3e999bdcb91e","service":"Api::V1::PricingService","hotel_id":"FloatingPointResort","room_id":"SingletonRoom"}
Completed 200 OK in 4ms (Views: 0.1ms | ActiveRecord: 0.0ms | Allocations: 895)
```