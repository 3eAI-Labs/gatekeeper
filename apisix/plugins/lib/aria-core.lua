--
-- aria-core.lua — Shared utilities for 3e-Aria-Gatekeeper plugins
--
-- Provides: Redis client, Prometheus metrics, error responses, gRPC client, audit events.
-- Used by: aria-shield, aria-mask, aria-canary
--
-- Business Rules: BR-SH-008 (metrics), BR-SH-015 (audit), BR-MK-005 (audit)
--

local core = require("apisix.core")
local redis_new = require("resty.redis").new
local ngx = ngx
local cjson = require("cjson.safe")
local str_format = string.format

local _M = {
    version = "0.1.0",
}

-- Maximum unique metric label combinations per APISIX instance (SRS 4.2)
local MAX_METRIC_CARDINALITY = 10000
local metric_cardinality_count = 0

-- Default error messages keyed by ARIA error code
local DEFAULT_MESSAGES = {
    ARIA_SH_INVALID_REQUEST_FORMAT = "Request body is not valid OpenAI-compatible JSON",
    ARIA_SH_INVALID_MODEL = "Requested model is not recognized or not configured",
    ARIA_SH_PII_IN_PROMPT_DETECTED = "PII detected in prompt content",
    ARIA_SH_PROMPT_INJECTION_DETECTED = "Potential prompt injection detected",
    ARIA_SH_QUOTA_EXCEEDED = "Token or dollar quota exhausted",
    ARIA_SH_QUOTA_THROTTLED = "Quota exhausted, request throttled",
    ARIA_SH_PROVIDER_AUTH_FAILED = "LLM provider authentication failed",
    ARIA_SH_PROVIDER_RATE_LIMITED = "LLM provider rate limit exceeded",
    ARIA_SH_PROVIDER_ERROR = "LLM provider returned an error",
    ARIA_SH_PROVIDER_TIMEOUT = "LLM provider request timed out",
    ARIA_SH_PROVIDER_UNREACHABLE = "Could not connect to LLM provider",
    ARIA_SH_ALL_PROVIDERS_DOWN = "All configured LLM providers are unavailable",
    ARIA_SH_PROVIDER_NOT_CONFIGURED = "No LLM provider configured for this route",
    ARIA_SH_CONTENT_FILTERED = "Response filtered for policy-violating content",
    ARIA_SH_EXFILTRATION_DETECTED = "Suspected data exfiltration in response",
    ARIA_SH_STREAM_INTERRUPTED = "SSE stream terminated unexpectedly",
    ARIA_SH_QUOTA_SERVICE_UNAVAILABLE = "Quota service is temporarily unavailable",
    ARIA_CN_NO_ACTIVE_CANARY = "No active canary deployment for this route",
    ARIA_CN_CANARY_UPSTREAM_UNHEALTHY = "Canary upstream has no healthy targets",
    ARIA_CN_INVALID_SCHEDULE = "Canary schedule configuration is invalid",
    ARIA_SYS_INTERNAL_ERROR = "An unexpected error occurred",
    ARIA_SYS_CONFIG_INVALID = "Plugin configuration is invalid",
}


--- Return a standardized Aria error response and exit the request.
-- Follows OpenAI error format for Shield, Aria envelope for others.
-- @param ctx       APISIX request context
-- @param status    HTTP status code
-- @param code      ARIA error code string
-- @param message   Optional human-readable message (falls back to DEFAULT_MESSAGES)
-- @param details   Optional table of structured details
function _M.exit_error(ctx, status, code, message, details)
    local request_id = ctx.var.request_id or ""
    local body = cjson.encode({
        error = {
            type = "aria_error",
            code = code,
            message = message or DEFAULT_MESSAGES[code] or "Unknown error",
            aria_request_id = request_id,
            details = details or cjson.empty_table,
        }
    })

    core.response.set_header("Content-Type", "application/json")
    return status, body
end


-- ────────────────────────────────────────────────────────────────────────────
-- Redis
-- ────────────────────────────────────────────────────────────────────────────

local redis_config_cache = {}

--- Get a Redis connection from the cosocket pool.
-- @param conf  Plugin configuration (must contain redis_host, redis_port, etc.)
-- @return redis connection or nil, error message
function _M.get_redis(conf)
    local redis_conf = conf._redis or conf
    local host = redis_conf.redis_host or "127.0.0.1"
    local port = redis_conf.redis_port or 6379
    local password = redis_conf.redis_password
    local database = redis_conf.redis_database or 0
    local timeout_ms = redis_conf.redis_timeout_ms or 1000

    local red = redis_new()
    red:set_timeouts(timeout_ms, timeout_ms, timeout_ms)

    local ok, err = red:connect(host, port)
    if not ok then
        core.log.error("redis connect failed: ", err)
        return nil, err
    end

    if password and password ~= "" then
        local auth_ok, auth_err = red:auth(password)
        if not auth_ok then
            core.log.error("redis auth failed: ", auth_err)
            return nil, auth_err
        end
    end

    if database > 0 then
        red:select(database)
    end

    return red
end


--- Return a Redis connection to the cosocket pool.
-- @param red   Redis connection object
function _M.put_redis(red)
    if not red then return end
    local ok, err = red:set_keepalive(10000, 100)  -- 10s idle, 100 pool size
    if not ok then
        core.log.warn("redis set_keepalive failed: ", err)
    end
end


--- Safely execute a Redis command, returning nil on failure.
-- Handles connection acquisition and release.
-- @param conf  Plugin configuration
-- @param fn    Function receiving (redis_conn) → result, err
-- @return result or nil, error message
function _M.redis_do(conf, fn)
    local red, err = _M.get_redis(conf)
    if not red then
        return nil, err
    end

    local ok, result = pcall(fn, red)
    _M.put_redis(red)

    if not ok then
        core.log.error("redis operation failed: ", result)
        return nil, result
    end

    return result
end


-- ────────────────────────────────────────────────────────────────────────────
-- Prometheus Metrics (BR-SH-008)
-- ────────────────────────────────────────────────────────────────────────────

local prometheus
local metrics_initialized = false
local metric_registry = {}

--- Initialize Prometheus metrics (called once per worker).
function _M.init_metrics()
    if metrics_initialized then return end

    -- APISIX exposes prometheus via its built-in plugin.
    -- We register custom aria_* metrics via the shared dict.
    prometheus = require("apisix.plugins.prometheus.exporter")
    metrics_initialized = true
end


--- Increment a counter metric.
-- @param name    Metric name (e.g., "aria_tokens_consumed")
-- @param value   Increment amount
-- @param labels  Table of label key-value pairs
function _M.counter_inc(name, value, labels)
    if not metrics_initialized then _M.init_metrics() end

    -- Cardinality guard (SRS 4.2)
    if metric_cardinality_count > MAX_METRIC_CARDINALITY then
        if not metric_registry[name] then
            core.log.warn("aria metrics cardinality exceeded, dropping: ", name)
            return
        end
    end

    if not metric_registry[name] then
        metric_registry[name] = true
        metric_cardinality_count = metric_cardinality_count + 1
    end

    -- Use APISIX shared dict for custom metrics export
    local label_str = _M.labels_to_string(labels)
    local key = name .. "{" .. label_str .. "}"
    local dict = ngx.shared["prometheus-metrics"]
    if dict then
        dict:incr(key, value, 0)
    end
end


--- Observe a histogram value.
-- @param name    Metric name
-- @param value   Observed value
-- @param labels  Table of label key-value pairs
function _M.histogram_observe(name, value, labels)
    if not metrics_initialized then _M.init_metrics() end

    local label_str = _M.labels_to_string(labels)
    local key = name .. "{" .. label_str .. "}"
    local dict = ngx.shared["prometheus-metrics"]
    if dict then
        -- Store as sum and count for histogram approximation
        dict:incr(key .. ":sum", value, 0)
        dict:incr(key .. ":count", 1, 0)
    end
end


--- Set a gauge metric.
-- @param name    Metric name
-- @param value   Gauge value
-- @param labels  Table of label key-value pairs
function _M.gauge_set(name, value, labels)
    if not metrics_initialized then _M.init_metrics() end

    local label_str = _M.labels_to_string(labels)
    local key = name .. "{" .. label_str .. "}"
    local dict = ngx.shared["prometheus-metrics"]
    if dict then
        dict:set(key, value)
    end
end


--- Convert a labels table to Prometheus label string.
-- @param labels  e.g., {consumer="team-a", model="gpt-4o"}
-- @return string e.g., 'consumer="team-a",model="gpt-4o"'
function _M.labels_to_string(labels)
    if not labels then return "" end

    local parts = {}
    for k, v in pairs(labels) do
        parts[#parts + 1] = str_format('%s="%s"', k, tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end


-- ────────────────────────────────────────────────────────────────────────────
-- Structured Logging
-- ────────────────────────────────────────────────────────────────────────────

--- Log a structured warning with context.
-- @param event   Event name (e.g., "sidecar_unavailable")
-- @param message Human-readable message
-- @param ctx     Optional APISIX request context
function _M.log_warn(event, message, ctx)
    local log_data = {
        event = event,
        message = message,
        module = "aria",
    }
    if ctx then
        log_data.request_id = ctx.var.request_id
        log_data.consumer = ctx.var.consumer_name
        log_data.route_id = ctx.var.route_id
    end
    core.log.warn(cjson.encode(log_data))
end


--- Log a structured error with context.
-- @param event   Event name
-- @param message Human-readable message
-- @param ctx     Optional APISIX request context
function _M.log_error(event, message, ctx)
    local log_data = {
        event = event,
        message = message,
        module = "aria",
    }
    if ctx then
        log_data.request_id = ctx.var.request_id
        log_data.consumer = ctx.var.consumer_name
        log_data.route_id = ctx.var.route_id
    end
    core.log.error(cjson.encode(log_data))
end


-- ────────────────────────────────────────────────────────────────────────────
-- Audit Events (BR-SH-015, BR-MK-005)
-- ────────────────────────────────────────────────────────────────────────────

--- Record a security or compliance audit event asynchronously.
-- Attempts to buffer in Redis if the sidecar/Postgres is unavailable.
-- @param conf       Plugin configuration
-- @param ctx        APISIX request context
-- @param event_type Event type string (e.g., "PROMPT_BLOCKED")
-- @param action     Action taken (e.g., "BLOCKED", "MASKED")
-- @param details    Table with masked details (no raw PII)
function _M.record_audit_event(conf, ctx, event_type, action, details)
    local event = cjson.encode({
        timestamp = ngx.utctime(),
        consumer_id = ctx.var.consumer_name or "unknown",
        route_id = ctx.var.route_id or "unknown",
        request_id = ctx.var.request_id or "",
        event_type = event_type,
        action_taken = action,
        payload_excerpt = details and details.excerpt or nil,
        rule_id = details and details.rule_id or nil,
        metadata = details and details.metadata or nil,
    })

    -- Buffer in Redis list for async flush to Postgres
    local result, err = _M.redis_do(conf, function(red)
        local len = red:llen("aria:audit_buffer")
        if len and tonumber(len) >= 1000 then
            -- Buffer overflow — drop oldest (BR-SH-015 rule 3)
            red:lpop("aria:audit_buffer")
            _M.counter_inc("aria_audit_buffer_overflow", 1)
        end
        return red:rpush("aria:audit_buffer", event)
    end)

    if not result then
        _M.log_error("audit_buffer_failed", "Could not buffer audit event: " .. (err or "unknown"), ctx)
    end
end


-- ────────────────────────────────────────────────────────────────────────────
-- Utility
-- ────────────────────────────────────────────────────────────────────────────

--- Generate a short random ID.
-- @param len  Number of hex characters (default 12)
-- @return string  Random hex string
function _M.random_id(len)
    len = len or 12
    local bytes = math.ceil(len / 2)
    local rand = require("resty.random").bytes(bytes)
    if not rand then
        -- Fallback
        local parts = {}
        for _ = 1, bytes do
            parts[#parts + 1] = str_format("%02x", math.random(0, 255))
        end
        return table.concat(parts):sub(1, len)
    end
    return require("resty.string").to_hex(rand):sub(1, len)
end


--- Approximate token count from text using word-based heuristic.
-- Returns conservative estimate: word_count * 1.3 (BR-SH-006 rule 1).
-- @param text  Input string
-- @return int  Approximate token count
function _M.approximate_tokens(text)
    if not text or text == "" then return 0 end
    local word_count = 0
    for _ in text:gmatch("%S+") do
        word_count = word_count + 1
    end
    return math.ceil(word_count * 1.3)
end


--- Parse a duration string (e.g., "5m", "30s", "1h") to seconds.
-- @param duration_str  Duration string
-- @return int  Seconds
function _M.parse_duration(duration_str)
    if not duration_str then return 0 end
    local num, unit = duration_str:match("^(%d+)(%a)$")
    if not num then return tonumber(duration_str) or 0 end
    num = tonumber(num)
    if unit == "s" then return num
    elseif unit == "m" then return num * 60
    elseif unit == "h" then return num * 3600
    elseif unit == "d" then return num * 86400
    end
    return num
end


return _M
