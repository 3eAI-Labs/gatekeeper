--
-- aria-quota.lua — Token quota and dollar budget enforcement
--
-- Manages per-consumer token quotas and dollar budgets with Redis-backed state.
-- Supports daily/monthly periods, overage policies (block/throttle/allow),
-- budget alerts at configurable thresholds, and pricing table lookups.
--
-- Business Rules: BR-SH-005 (quota check), BR-SH-006 (reconciliation),
--                 BR-SH-007 (dollar budget), BR-SH-008 (metrics),
--                 BR-SH-009 (alerts), BR-SH-010 (overage policy)
-- Decision Matrices: DM-SH-001 (overage), DM-SH-006 (Redis unavailability)
-- User Stories: US-A05 (quota), US-A06 (budget), US-A07 (metrics),
--               US-A08 (alerts), US-A09 (overage)
--

local cjson     = require("cjson.safe")
local ngx       = ngx
local aria_core  = require("apisix.plugins.lib.aria-core")
local str_format = string.format

local _M = {
    version = "0.2.0",
}


-- ────────────────────────────────────────────────────────────────────────────
-- Default pricing table (BR-SH-007)
-- Can be overridden via APISIX plugin_metadata for "aria-shield"
-- ────────────────────────────────────────────────────────────────────────────

local DEFAULT_PRICING = {
    ["gpt-4o"]              = { input_per_1k = 0.0025,  output_per_1k = 0.01 },
    ["gpt-4o-mini"]         = { input_per_1k = 0.00015, output_per_1k = 0.0006 },
    ["gpt-4.1"]             = { input_per_1k = 0.002,   output_per_1k = 0.008 },
    ["gpt-4.1-mini"]        = { input_per_1k = 0.0004,  output_per_1k = 0.0016 },
    ["gpt-4.1-nano"]        = { input_per_1k = 0.0001,  output_per_1k = 0.0004 },
    ["claude-sonnet-4-6"]   = { input_per_1k = 0.003,   output_per_1k = 0.015 },
    ["claude-opus-4-6"]     = { input_per_1k = 0.015,   output_per_1k = 0.075 },
    ["claude-haiku-4-5"]    = { input_per_1k = 0.0008,  output_per_1k = 0.004 },
    ["gemini-2.0-flash"]    = { input_per_1k = 0.0001,  output_per_1k = 0.0004 },
    ["gemini-2.5-pro"]      = { input_per_1k = 0.00125, output_per_1k = 0.01 },
    _default                = { input_per_1k = 0.01,    output_per_1k = 0.03 },
}


-- ────────────────────────────────────────────────────────────────────────────
-- Redis Key Builders
-- ────────────────────────────────────────────────────────────────────────────

local function daily_token_key(consumer_id)
    local date = os.date("!%Y-%m-%d")
    return str_format("aria:quota:%s:daily:%s:tokens", consumer_id, date)
end

local function monthly_token_key(consumer_id)
    local month = os.date("!%Y-%m")
    return str_format("aria:quota:%s:monthly:%s:tokens", consumer_id, month)
end

local function daily_dollar_key(consumer_id)
    local date = os.date("!%Y-%m-%d")
    return str_format("aria:quota:%s:daily:%s:dollars", consumer_id, date)
end

local function monthly_dollar_key(consumer_id)
    local month = os.date("!%Y-%m")
    return str_format("aria:quota:%s:monthly:%s:dollars", consumer_id, month)
end

local function alert_sent_key(consumer_id, threshold, period)
    return str_format("aria:alert:%s:%d:%s", consumer_id, threshold, period)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Quota Pre-Flight Check (BR-SH-005)
-- ────────────────────────────────────────────────────────────────────────────

--- Check if the consumer has remaining quota.
-- Returns a result table with quota status.
-- @param conf         Plugin configuration (contains quota settings)
-- @param consumer_id  Consumer identifier
-- @return table {allowed, exhausted, remaining_tokens, remaining_dollars, period, reason}
function _M.check_quota(conf, consumer_id)
    local quota = conf.quota
    if not quota then
        return { allowed = true, exhausted = false }
    end

    local has_token_limit = quota.daily_tokens or quota.monthly_tokens
    local has_dollar_limit = quota.monthly_dollars

    if not has_token_limit and not has_dollar_limit then
        return { allowed = true, exhausted = false }
    end

    -- Read current usage from Redis
    local result = { allowed = true, exhausted = false }

    local redis_ok, usage = pcall(function()
        return aria_core.redis_do(conf, function(red)
            local data = {}

            -- Check daily tokens
            if quota.daily_tokens then
                local val = red:get(daily_token_key(consumer_id))
                data.daily_tokens_used = tonumber(val ~= ngx.null and val or 0) or 0
            end

            -- Check monthly tokens
            if quota.monthly_tokens then
                local val = red:get(monthly_token_key(consumer_id))
                data.monthly_tokens_used = tonumber(val ~= ngx.null and val or 0) or 0
            end

            -- Check monthly dollars
            if quota.monthly_dollars then
                local val = red:get(monthly_dollar_key(consumer_id))
                data.monthly_dollars_used = tonumber(val ~= ngx.null and val or 0) or 0
            end

            return data
        end)
    end)

    -- DM-SH-006: Redis unavailability handling
    if not redis_ok or not usage then
        local fail_policy = quota.fail_policy or "fail_open"
        aria_core.counter_inc("aria_quota_redis_unavailable", 1)

        if fail_policy == "fail_closed" then
            return {
                allowed = false,
                exhausted = true,
                reason = "quota_service_unavailable",
                error_code = "ARIA_SH_QUOTA_SERVICE_UNAVAILABLE",
            }
        end

        -- fail_open: allow with warning
        aria_core.log_warn("quota_redis_unavailable", "Allowing request (fail_open policy)")
        return { allowed = true, exhausted = false, degraded = true }
    end

    -- Check daily token limit
    if quota.daily_tokens and usage.daily_tokens_used >= quota.daily_tokens then
        result.allowed = false
        result.exhausted = true
        result.remaining_tokens = 0
        result.period = "daily"
        result.limit = quota.daily_tokens
        result.used = usage.daily_tokens_used
        result.reason = "daily_token_quota_exceeded"
        return result
    end

    -- Check monthly token limit
    if quota.monthly_tokens and usage.monthly_tokens_used >= quota.monthly_tokens then
        result.allowed = false
        result.exhausted = true
        result.remaining_tokens = 0
        result.period = "monthly"
        result.limit = quota.monthly_tokens
        result.used = usage.monthly_tokens_used
        result.reason = "monthly_token_quota_exceeded"
        return result
    end

    -- Check monthly dollar limit
    if quota.monthly_dollars and usage.monthly_dollars_used >= quota.monthly_dollars then
        result.allowed = false
        result.exhausted = true
        result.remaining_dollars = 0
        result.period = "monthly"
        result.limit = quota.monthly_dollars
        result.used = usage.monthly_dollars_used
        result.reason = "monthly_dollar_budget_exceeded"
        return result
    end

    -- Calculate remaining
    if quota.daily_tokens then
        result.remaining_tokens = quota.daily_tokens - (usage.daily_tokens_used or 0)
    elseif quota.monthly_tokens then
        result.remaining_tokens = quota.monthly_tokens - (usage.monthly_tokens_used or 0)
    end

    if quota.monthly_dollars then
        result.remaining_dollars = quota.monthly_dollars - (usage.monthly_dollars_used or 0)
    end

    return result
end


-- ────────────────────────────────────────────────────────────────────────────
-- Overage Policy (BR-SH-010, DM-SH-001)
-- ────────────────────────────────────────────────────────────────────────────

--- Apply the configured overage policy when quota is exhausted.
-- @param conf         Plugin configuration
-- @param ctx          APISIX request context
-- @param consumer_id  Consumer identifier
-- @param quota_result Result from check_quota()
-- @return HTTP status, body (to be returned by exit_error)
function _M.apply_overage_policy(conf, ctx, consumer_id, quota_result)
    local policy = conf.quota and conf.quota.overage_policy or "block"

    aria_core.counter_inc("aria_overage_requests", 1, {
        consumer = consumer_id,
        policy = policy,
    })

    -- Record audit event
    aria_core.record_audit_event(conf, ctx, "QUOTA_EXCEEDED", "BLOCKED", {
        metadata = {
            consumer = consumer_id,
            period = quota_result.period,
            limit = quota_result.limit,
            used = quota_result.used,
            policy = policy,
        },
    })

    if policy == "block" then
        -- DM-SH-001 row 1: Return 402
        local reset_time = _M.get_reset_time(quota_result.period)
        return aria_core.exit_error(ctx, 402, "ARIA_SH_QUOTA_EXCEEDED",
            str_format("Token quota exceeded for consumer '%s'. Resets at %s.",
                consumer_id, reset_time),
            {
                consumer_id = consumer_id,
                quota_type = quota_result.reason,
                quota_limit = quota_result.limit,
                quota_used = quota_result.used,
                resets_at = reset_time,
                overage_policy = "block",
            })

    elseif policy == "throttle" then
        -- DM-SH-001 rows 2-3: Rate limit to 1 req/min
        local throttle_key = str_format("aria:throttle:%s", consumer_id)
        local last_allowed = aria_core.redis_do(conf, function(red)
            return red:get(throttle_key)
        end)

        if last_allowed and last_allowed ~= ngx.null then
            local elapsed = ngx.now() - tonumber(last_allowed)
            if elapsed < 60 then
                -- Still within throttle window
                local retry_after = math.ceil(60 - elapsed)
                ngx.header["Retry-After"] = tostring(retry_after)
                return aria_core.exit_error(ctx, 429, "ARIA_SH_QUOTA_THROTTLED",
                    str_format("Quota exhausted, throttled. Retry after %d seconds.", retry_after),
                    { retry_after = retry_after, overage_policy = "throttle" })
            end
        end

        -- Allow one request, record timestamp
        aria_core.redis_do(conf, function(red)
            red:set(throttle_key, tostring(ngx.now()))
            return red:expire(throttle_key, 120)
        end)
        -- Fall through — request is allowed

    elseif policy == "allow" then
        -- DM-SH-001 row 4: Allow but alert
        _M.check_alert_thresholds(conf, consumer_id, 100, quota_result)
        -- Fall through — request is allowed
    end

    return nil  -- Request is allowed (throttle window elapsed, or allow policy)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Token Count Update (BR-SH-005)
-- ────────────────────────────────────────────────────────────────────────────

--- Update quota counters after a request completes.
-- @param conf         Plugin configuration
-- @param consumer_id  Consumer identifier
-- @param tokens       Total tokens consumed (approximate from Lua)
function _M.update_token_count(conf, consumer_id, tokens)
    if not tokens or tokens <= 0 then return end
    if not conf.quota then return end

    aria_core.redis_do(conf, function(red)
        -- Update daily counter
        if conf.quota.daily_tokens then
            local key = daily_token_key(consumer_id)
            red:incrby(key, tokens)
            red:expire(key, 172800)  -- 48h TTL
        end

        -- Update monthly counter
        if conf.quota.monthly_tokens then
            local key = monthly_token_key(consumer_id)
            red:incrby(key, tokens)
            red:expire(key, 3024000)  -- 35 days TTL
        end

        return true
    end)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Dollar Budget (BR-SH-007)
-- ────────────────────────────────────────────────────────────────────────────

--- Calculate dollar cost from token usage using the pricing table.
-- @param model          Model name string
-- @param input_tokens   Number of input tokens
-- @param output_tokens  Number of output tokens
-- @param pricing_table  Optional custom pricing table (defaults to built-in)
-- @return number  Dollar cost (6 decimal precision)
function _M.calculate_cost(model, input_tokens, output_tokens, pricing_table)
    local table_to_use = pricing_table or DEFAULT_PRICING
    local pricing = table_to_use[model] or table_to_use._default

    if not pricing then
        aria_core.counter_inc("aria_unknown_model_pricing", 1, { model = model })
        pricing = { input_per_1k = 0.01, output_per_1k = 0.03 }
    end

    local cost = (input_tokens / 1000) * pricing.input_per_1k
                + (output_tokens / 1000) * pricing.output_per_1k

    -- Round to 6 decimal places (fixed-point precision)
    return math.floor(cost * 1000000 + 0.5) / 1000000
end


--- Update dollar budget counter after a request completes.
-- @param conf         Plugin configuration
-- @param consumer_id  Consumer identifier
-- @param cost_dollars Dollar cost for this request
function _M.update_dollar_budget(conf, consumer_id, cost_dollars)
    if not cost_dollars or cost_dollars <= 0 then return end
    if not conf.quota or not conf.quota.monthly_dollars then return end

    -- Store as integer microdollars to avoid float precision issues
    local microdollars = math.floor(cost_dollars * 1000000 + 0.5)

    aria_core.redis_do(conf, function(red)
        local key = monthly_dollar_key(consumer_id)
        -- Use INCRBYFLOAT for dollar values (stored as string)
        red:incrbyfloat(key, tostring(cost_dollars))
        red:expire(key, 3024000)  -- 35 days TTL
        return true
    end)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Budget Alerts (BR-SH-009)
-- ────────────────────────────────────────────────────────────────────────────

--- Check if any budget alert thresholds have been crossed.
-- Each threshold fires exactly once per budget period (de-duplicated via Redis SETNX).
-- @param conf          Plugin configuration
-- @param consumer_id   Consumer identifier
-- @param current_pct   Current utilization percentage (0-100+)
-- @param quota_result  Quota check result (for details)
function _M.check_alert_thresholds(conf, consumer_id, current_pct, quota_result)
    if not conf.alerts or not conf.alerts.thresholds then return end

    local period = os.date("!%Y-%m")

    for _, threshold in ipairs(conf.alerts.thresholds) do
        if current_pct >= threshold then
            -- De-duplicate: only alert once per threshold per period
            local dedup_key = alert_sent_key(consumer_id, threshold, period)
            local already_sent = aria_core.redis_do(conf, function(red)
                -- SETNX: returns true (1) if key was set (= not sent before)
                local result = red:setnx(dedup_key, "1")
                if result == 1 then
                    red:expire(dedup_key, 3024000)  -- 35 days
                end
                return result
            end)

            if already_sent == 1 then
                -- First crossing of this threshold — send alert
                _M.send_alert(conf, consumer_id, threshold, current_pct, quota_result)
            end
        end
    end
end


--- Send a budget alert notification via webhook.
-- @param conf         Plugin configuration
-- @param consumer_id  Consumer identifier
-- @param threshold    Threshold percentage that was crossed
-- @param current_pct  Current utilization percentage
-- @param quota_result Quota details
function _M.send_alert(conf, consumer_id, threshold, current_pct, quota_result)
    local webhook_url = conf.alerts and conf.alerts.webhook_url
    if not webhook_url or webhook_url == "" then return end

    local payload = cjson.encode({
        type = "aria_budget_alert",
        consumer_id = consumer_id,
        threshold_pct = threshold,
        current_spend = quota_result and quota_result.used or 0,
        budget_limit = quota_result and quota_result.limit or 0,
        budget_period = quota_result and quota_result.period or "monthly",
        period = os.date("!%Y-%m"),
        timestamp = ngx.utctime(),
    })

    -- Fire-and-forget webhook call with retry
    -- Use ngx.timer for async execution (non-blocking)
    ngx.timer.at(0, function(premature)
        if premature then return end

        local http = require("resty.http")
        local httpc = http.new()
        httpc:set_timeout(5000)

        local max_retries = conf.alerts.retry_count or 3
        local backoff_base = conf.alerts.retry_backoff_base_ms or 1000

        for attempt = 1, max_retries do
            local res, err = httpc:request_uri(webhook_url, {
                method  = "POST",
                body    = payload,
                headers = { ["Content-Type"] = "application/json" },
            })

            if res and res.status < 400 then
                aria_core.log_warn("alert_sent",
                    str_format("Budget alert sent: consumer=%s threshold=%d%%", consumer_id, threshold))
                return
            end

            -- Exponential backoff with jitter
            if attempt < max_retries then
                local wait_ms = backoff_base * (2 ^ (attempt - 1)) + math.random(0, 1000)
                ngx.sleep(wait_ms / 1000)
            end
        end

        aria_core.log_error("alert_delivery_failed",
            str_format("Failed to deliver budget alert after %d attempts: consumer=%s",
                max_retries, consumer_id))
    end)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Quota Utilization Metrics (BR-SH-008)
-- ────────────────────────────────────────────────────────────────────────────

--- Emit quota utilization percentage as a Prometheus gauge.
-- @param conf         Plugin configuration
-- @param consumer_id  Consumer identifier
-- @param quota_result Result from check_quota()
function _M.emit_utilization_metrics(conf, consumer_id, quota_result)
    if not conf.quota then return end

    if quota_result.remaining_tokens ~= nil and conf.quota.monthly_tokens then
        local used = conf.quota.monthly_tokens - quota_result.remaining_tokens
        local pct = (used / conf.quota.monthly_tokens) * 100
        aria_core.gauge_set("aria_quota_utilization_pct", pct, {
            consumer = consumer_id,
            period = "monthly",
        })
        return pct
    end

    if quota_result.remaining_tokens ~= nil and conf.quota.daily_tokens then
        local used = conf.quota.daily_tokens - quota_result.remaining_tokens
        local pct = (used / conf.quota.daily_tokens) * 100
        aria_core.gauge_set("aria_quota_utilization_pct", pct, {
            consumer = consumer_id,
            period = "daily",
        })
        return pct
    end

    return 0
end


-- ────────────────────────────────────────────────────────────────────────────
-- Utility
-- ────────────────────────────────────────────────────────────────────────────

--- Get the next reset time for a given period.
-- @param period  "daily" or "monthly"
-- @return string ISO 8601 timestamp
function _M.get_reset_time(period)
    if period == "daily" then
        -- Next day at 00:00 UTC
        local tomorrow = os.time() + 86400
        return os.date("!%Y-%m-%dT00:00:00Z", tomorrow)
    else
        -- First day of next month at 00:00 UTC
        local now = os.date("!*t")
        if now.month == 12 then
            return str_format("%d-01-01T00:00:00Z", now.year + 1)
        else
            return str_format("%d-%02d-01T00:00:00Z", now.year, now.month + 1)
        end
    end
end


--- Get the pricing table, merging custom pricing from plugin_metadata.
-- @param custom_pricing  Optional custom pricing table from APISIX metadata
-- @return pricing table
function _M.get_pricing_table(custom_pricing)
    if not custom_pricing then return DEFAULT_PRICING end

    -- Merge custom over defaults
    local merged = {}
    for k, v in pairs(DEFAULT_PRICING) do merged[k] = v end
    for k, v in pairs(custom_pricing) do merged[k] = v end
    return merged
end


return _M
