--
-- aria-shield.lua — 3e-Aria-Shield: AI Governance Plugin for Apache APISIX
--
-- Shield v0.1: Multi-provider LLM routing, auto-failover, SSE streaming, OpenAI compatibility
-- Shield v0.2: Token quota enforcement, dollar budget, overage policies, budget alerts
--
-- Business Rules: BR-SH-001 (routing), BR-SH-002 (circuit breaker), BR-SH-003 (SSE),
--                 BR-SH-004 (OpenAI compat), BR-SH-005 (quota), BR-SH-006 (reconciliation),
--                 BR-SH-007 (dollar budget), BR-SH-008 (metrics), BR-SH-009 (alerts),
--                 BR-SH-010 (overage policy)
-- User Stories:   US-A01-A09
--

local core       = require("apisix.core")
local http       = require("resty.http")
local cjson      = require("cjson.safe")
local ngx        = ngx
local aria_core  = require("apisix.plugins.lib.aria-core")
local provider   = require("apisix.plugins.lib.aria-provider")
local aria_quota = require("apisix.plugins.lib.aria-quota")

local plugin_name = "aria-shield"

local schema = {
    type = "object",
    properties = {
        provider = {
            type = "string",
            enum = {"openai", "anthropic", "google", "azure_openai", "ollama"},
        },
        provider_config = {
            type = "object",
            properties = {
                endpoint  = { type = "string" },
                api_key   = { type = "string" },
                timeout_ms = { type = "integer", minimum = 1000, maximum = 120000, default = 30000 },
                -- Azure-specific
                azure_resource   = { type = "string" },
                azure_deployment = { type = "string" },
                azure_api_version = { type = "string", default = "2024-02-01" },
            },
        },
        fallback_providers = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    provider = { type = "string" },
                    endpoint = { type = "string" },
                    api_key  = { type = "string" },
                    -- Azure fields
                    azure_resource    = { type = "string" },
                    azure_deployment  = { type = "string" },
                    azure_api_version = { type = "string" },
                },
                required = {"provider"},
            },
            default = {},
        },
        circuit_breaker = {
            type = "object",
            properties = {
                failure_threshold = { type = "integer", minimum = 1, maximum = 100, default = 3 },
                cooldown_seconds  = { type = "integer", minimum = 5, maximum = 600, default = 30 },
            },
            default = { failure_threshold = 3, cooldown_seconds = 30 },
        },
        -- v0.2: Token quota and dollar budget (BR-SH-005, BR-SH-007)
        quota = {
            type = "object",
            properties = {
                daily_tokens    = { type = "integer", minimum = 1 },
                monthly_tokens  = { type = "integer", minimum = 1 },
                monthly_dollars = { type = "number", minimum = 0.01 },
                overage_policy  = { type = "string", enum = {"block", "throttle", "allow"}, default = "block" },
                fail_policy     = { type = "string", enum = {"fail_open", "fail_closed"}, default = "fail_open" },
            },
        },
        -- v0.2: Budget alerts (BR-SH-009)
        alerts = {
            type = "object",
            properties = {
                thresholds         = { type = "array", items = { type = "integer", minimum = 1, maximum = 100 }, default = {80, 90, 100} },
                webhook_url        = { type = "string" },
                slack_webhook_url  = { type = "string" },
                retry_count        = { type = "integer", minimum = 0, maximum = 10, default = 3 },
                retry_backoff_base_ms = { type = "integer", minimum = 100, maximum = 30000, default = 1000 },
            },
        },
        -- v0.2: Custom pricing table override
        pricing_table = {
            type = "object",
            additionalProperties = {
                type = "object",
                properties = {
                    input_per_1k  = { type = "number" },
                    output_per_1k = { type = "number" },
                },
            },
        },
        model_pin = { type = "string" },
        -- Redis connection for circuit breaker and quota state
        redis_host     = { type = "string", default = "127.0.0.1" },
        redis_port     = { type = "integer", default = 6379 },
        redis_password = { type = "string" },
        redis_database = { type = "integer", default = 0 },
    },
    required = {"provider"},
}


local _M = {
    version  = "0.1.0",
    priority = 2000,
    name     = plugin_name,
    schema   = schema,
}


-- ────────────────────────────────────────────────────────────────────────────
-- Schema check
-- ────────────────────────────────────────────────────────────────────────────

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    -- Validate provider exists in registry
    if not provider.get(conf.provider) then
        return false, "unknown provider: " .. conf.provider
    end

    return true
end


-- ────────────────────────────────────────────────────────────────────────────
-- Circuit Breaker (BR-SH-002)
-- ────────────────────────────────────────────────────────────────────────────

-- In-memory circuit breaker state (fallback when Redis unavailable)
local cb_memory = {}

local function cb_key(provider_name, route_id)
    return "aria:cb:" .. provider_name .. ":" .. (route_id or "default")
end

--- Check circuit breaker state for a provider.
-- Returns "CLOSED", "OPEN", or "HALF_OPEN".
local function check_circuit_breaker(conf, provider_name, route_id)
    local key = cb_key(provider_name, route_id)

    -- Try Redis first
    local state = aria_core.redis_do(conf, function(red)
        return red:hget(key, "state")
    end)

    if not state or state == ngx.null then
        -- Check in-memory fallback
        local mem = cb_memory[key]
        if not mem then return "CLOSED" end
        state = mem.state
    end

    if state == "OPEN" then
        -- Check cooldown
        local opened_at = aria_core.redis_do(conf, function(red)
            return red:hget(key, "opened_at")
        end)
        if not opened_at or opened_at == ngx.null then
            local mem = cb_memory[key]
            opened_at = mem and mem.opened_at
        end

        if opened_at then
            local elapsed = ngx.now() - tonumber(opened_at)
            if elapsed >= conf.circuit_breaker.cooldown_seconds then
                -- Transition to HALF_OPEN
                aria_core.redis_do(conf, function(red)
                    red:hset(key, "state", "HALF_OPEN")
                    return red:expire(key, 600)
                end)
                cb_memory[key] = { state = "HALF_OPEN" }
                aria_core.gauge_set("aria_circuit_breaker_state", 2,
                    { provider = provider_name, route = route_id })
                return "HALF_OPEN"
            end
        end
        return "OPEN"
    end

    return state or "CLOSED"
end


--- Record a provider call result for the circuit breaker.
local function record_provider_result(conf, provider_name, route_id, success)
    local key = cb_key(provider_name, route_id)

    if success then
        -- Reset circuit breaker on success
        aria_core.redis_do(conf, function(red)
            red:hmset(key, "state", "CLOSED", "failures", "0")
            return red:expire(key, 600)
        end)
        cb_memory[key] = { state = "CLOSED", failures = 0 }
        aria_core.gauge_set("aria_circuit_breaker_state", 0,
            { provider = provider_name, route = route_id })
    else
        -- Increment failure counter
        local failures = aria_core.redis_do(conf, function(red)
            return red:hincrby(key, "failures", 1)
        end)
        if not failures then
            local mem = cb_memory[key] or { state = "CLOSED", failures = 0 }
            mem.failures = (mem.failures or 0) + 1
            failures = mem.failures
            cb_memory[key] = mem
        end

        if tonumber(failures) >= conf.circuit_breaker.failure_threshold then
            aria_core.redis_do(conf, function(red)
                red:hmset(key, "state", "OPEN", "opened_at", tostring(ngx.now()))
                return red:expire(key, 600)
            end)
            cb_memory[key] = { state = "OPEN", opened_at = ngx.now(), failures = tonumber(failures) }
            aria_core.gauge_set("aria_circuit_breaker_state", 1,
                { provider = provider_name, route = route_id })

            core.log.warn("circuit breaker OPEN for provider: ", provider_name,
                " (failures: ", failures, ")")
        end
    end
end


-- ────────────────────────────────────────────────────────────────────────────
-- Provider Selection (BR-SH-001, BR-SH-002)
-- ────────────────────────────────────────────────────────────────────────────

--- Build a provider config from plugin conf + optional fallback entry.
local function build_provider_conf(conf, fallback_entry)
    if fallback_entry then
        return {
            provider          = fallback_entry.provider,
            endpoint          = fallback_entry.endpoint,
            api_key           = fallback_entry.api_key,
            azure_resource    = fallback_entry.azure_resource,
            azure_deployment  = fallback_entry.azure_deployment,
            azure_api_version = fallback_entry.azure_api_version,
        }
    end

    return {
        provider          = conf.provider,
        endpoint          = conf.provider_config and conf.provider_config.endpoint,
        api_key           = conf.provider_config and conf.provider_config.api_key,
        azure_resource    = conf.provider_config and conf.provider_config.azure_resource,
        azure_deployment  = conf.provider_config and conf.provider_config.azure_deployment,
        azure_api_version = conf.provider_config and conf.provider_config.azure_api_version,
    }
end


--- Select the best available provider considering circuit breaker state.
-- Returns provider_transformer, provider_conf or nil if all down.
local function select_provider(conf, route_id)
    -- Try primary
    local primary_state = check_circuit_breaker(conf, conf.provider, route_id)
    if primary_state ~= "OPEN" then
        local transformer = provider.get(conf.provider)
        return transformer, build_provider_conf(conf)
    end

    -- Primary is OPEN — try fallbacks (BR-SH-002)
    for _, fb in ipairs(conf.fallback_providers or {}) do
        local fb_state = check_circuit_breaker(conf, fb.provider, route_id)
        if fb_state ~= "OPEN" then
            local transformer = provider.get(fb.provider)
            if transformer then
                core.log.info("failover to provider: ", fb.provider)
                aria_core.counter_inc("aria_provider_failover_total", 1, {
                    from_provider = conf.provider,
                    to_provider = fb.provider,
                })
                return transformer, build_provider_conf(conf, fb)
            end
        end
    end

    return nil, nil  -- All providers down
end


-- ────────────────────────────────────────────────────────────────────────────
-- HTTP Client for LLM Provider Calls
-- ────────────────────────────────────────────────────────────────────────────

--- Forward the request to the LLM provider and return the response.
-- Handles both streaming and non-streaming.
local function call_provider(transformer, prov_conf, request_body, is_stream, timeout_ms)
    local url = transformer.build_url(prov_conf)
    local headers = transformer.build_headers(prov_conf)
    local body_str = cjson.encode(request_body)

    local httpc = http.new()
    httpc:set_timeout(timeout_ms or 30000)

    local res, err = httpc:request_uri(url, {
        method  = "POST",
        body    = body_str,
        headers = headers,
    })

    if not res then
        return nil, nil, err
    end

    return res.status, res.body, nil, res.headers
end


-- ────────────────────────────────────────────────────────────────────────────
-- Plugin Phases
-- ────────────────────────────────────────────────────────────────────────────

--- Access phase: validate request, select provider, forward to LLM.
-- BR-SH-001 (routing), BR-SH-002 (failover), BR-SH-018 (model pin)
function _M.access(conf, ctx)
    local request_start = ngx.now()

    -- Read and validate request body
    local body_str = core.request.get_body()
    if not body_str then
        return aria_core.exit_error(ctx, 400, "ARIA_SH_INVALID_REQUEST_FORMAT",
            "Request body is empty")
    end

    local body, decode_err = cjson.decode(body_str)
    if not body then
        return aria_core.exit_error(ctx, 400, "ARIA_SH_INVALID_REQUEST_FORMAT",
            "Invalid JSON: " .. (decode_err or "parse error"))
    end

    -- Validate required fields
    if not body.messages or type(body.messages) ~= "table" or #body.messages == 0 then
        return aria_core.exit_error(ctx, 400, "ARIA_SH_INVALID_REQUEST_FORMAT",
            "Field 'messages' is required and must be a non-empty array")
    end

    if not body.model or body.model == "" then
        return aria_core.exit_error(ctx, 400, "ARIA_SH_INVALID_REQUEST_FORMAT",
            "Field 'model' is required")
    end

    -- BR-SH-018: Apply model version pin
    if conf.model_pin and conf.model_pin ~= "" then
        body.model = conf.model_pin
    end

    local is_stream = body.stream == true
    local route_id = ctx.var.route_id or "default"
    local consumer_id = ctx.var.consumer_name or "anonymous"

    -- v0.2: Quota pre-flight check (BR-SH-005, DM-SH-001)
    local quota_result = aria_quota.check_quota(conf, consumer_id)
    if quota_result.exhausted then
        local overage_status, overage_body = aria_quota.apply_overage_policy(
            conf, ctx, consumer_id, quota_result)
        if overage_status then
            -- Overage policy returned an error (block or throttle within window)
            aria_core.counter_inc("aria_requests_total", 1, {
                consumer = consumer_id, model = body.model,
                route = route_id, status = tostring(overage_status) .. "xx",
            })
            return overage_status, overage_body
        end
        -- Policy is "allow" or "throttle" window elapsed — continue
    end

    -- Set quota remaining headers (even if no quota configured — omitted in that case)
    if quota_result.remaining_tokens then
        core.response.set_header("X-Aria-Quota-Remaining", tostring(quota_result.remaining_tokens))
    end
    if quota_result.remaining_dollars then
        core.response.set_header("X-Aria-Budget-Remaining",
            string.format("%.2f", quota_result.remaining_dollars))
    end

    -- Select provider with circuit breaker awareness (BR-SH-001, BR-SH-002)
    local transformer, prov_conf = select_provider(conf, route_id)
    if not transformer then
        return aria_core.exit_error(ctx, 503, "ARIA_SH_ALL_PROVIDERS_DOWN")
    end

    -- Transform request to provider format (BR-SH-001)
    local provider_request = transformer.transform_request(body, prov_conf)

    -- Call LLM provider
    local timeout_ms = conf.provider_config and conf.provider_config.timeout_ms or 30000
    local status, resp_body, call_err, resp_headers = call_provider(
        transformer, prov_conf, provider_request, is_stream, timeout_ms
    )

    if not status then
        -- Connection failure
        record_provider_result(conf, prov_conf.provider, route_id, false)
        aria_core.log_error("provider_unreachable", call_err or "connection failed", ctx)

        -- Try fallback if primary failed (BR-SH-002)
        if prov_conf.provider == conf.provider and conf.fallback_providers and #conf.fallback_providers > 0 then
            for _, fb in ipairs(conf.fallback_providers) do
                local fb_transformer = provider.get(fb.provider)
                if fb_transformer then
                    local fb_conf = build_provider_conf(conf, fb)
                    local fb_request = fb_transformer.transform_request(body, fb_conf)
                    status, resp_body, call_err, resp_headers = call_provider(
                        fb_transformer, fb_conf, fb_request, is_stream, timeout_ms
                    )
                    if status then
                        transformer = fb_transformer
                        prov_conf = fb_conf
                        aria_core.counter_inc("aria_provider_failover_total", 1, {
                            from_provider = conf.provider,
                            to_provider = fb.provider,
                        })
                        break
                    else
                        record_provider_result(conf, fb.provider, route_id, false)
                    end
                end
            end
        end

        if not status then
            return aria_core.exit_error(ctx, 502, "ARIA_SH_PROVIDER_UNREACHABLE",
                "Could not connect to any LLM provider")
        end
    end

    -- Handle provider error responses
    if status >= 500 then
        record_provider_result(conf, prov_conf.provider, route_id, false)

        -- Try inline failover for 5xx (BR-SH-002)
        if prov_conf.provider == conf.provider then
            for _, fb in ipairs(conf.fallback_providers or {}) do
                local fb_transformer = provider.get(fb.provider)
                if fb_transformer then
                    local fb_conf = build_provider_conf(conf, fb)
                    local fb_request = fb_transformer.transform_request(body, fb_conf)
                    local fb_status, fb_body, fb_err = call_provider(
                        fb_transformer, fb_conf, fb_request, is_stream, timeout_ms
                    )
                    if fb_status and fb_status < 500 then
                        status = fb_status
                        resp_body = fb_body
                        transformer = fb_transformer
                        prov_conf = fb_conf
                        record_provider_result(conf, fb.provider, route_id, true)
                        break
                    elseif fb_status then
                        record_provider_result(conf, fb.provider, route_id, false)
                    end
                end
            end
        end

        if status >= 500 then
            local mapped_status, mapped_body = transformer.map_error(status, resp_body or "", prov_conf)
            return aria_core.exit_error(ctx, 502, "ARIA_SH_PROVIDER_ERROR",
                "LLM provider returned HTTP " .. tostring(status))
        end
    elseif status == 401 or status == 403 then
        return aria_core.exit_error(ctx, 502, "ARIA_SH_PROVIDER_AUTH_FAILED")
    elseif status == 429 then
        return aria_core.exit_error(ctx, 429, "ARIA_SH_PROVIDER_RATE_LIMITED")
    end

    -- Success — record for circuit breaker
    record_provider_result(conf, prov_conf.provider, route_id, true)

    -- Transform response to OpenAI format (BR-SH-004)
    local transformed_body, transform_err = transformer.transform_response(resp_body, prov_conf)
    if not transformed_body then
        core.log.error("response transform failed: ", transform_err or "unknown")
        transformed_body = resp_body  -- Pass through on transform failure
    end

    -- Extract usage for metrics (BR-SH-008)
    local usage = provider.extract_usage(transformed_body)
    local latency = ngx.now() - request_start

    -- Emit metrics (BR-SH-008)
    local metric_labels = {
        consumer = consumer_id,
        model    = body.model,
        route    = route_id,
    }

    if usage then
        aria_core.counter_inc("aria_tokens_consumed", usage.prompt_tokens,
            { consumer = consumer_id, model = body.model, route = route_id, type = "input" })
        aria_core.counter_inc("aria_tokens_consumed", usage.completion_tokens,
            { consumer = consumer_id, model = body.model, route = route_id, type = "output" })

        -- v0.2: Update quota counters (BR-SH-005)
        local total_tokens = usage.total_tokens or (usage.prompt_tokens + usage.completion_tokens)
        aria_quota.update_token_count(conf, consumer_id, total_tokens)

        -- v0.2: Calculate and update dollar budget (BR-SH-007)
        local pricing_table = aria_quota.get_pricing_table(conf.pricing_table)
        local cost = aria_quota.calculate_cost(
            body.model, usage.prompt_tokens, usage.completion_tokens, pricing_table)
        aria_quota.update_dollar_budget(conf, consumer_id, cost)

        aria_core.counter_inc("aria_cost_dollars", cost, metric_labels)

        -- v0.2: Emit utilization metrics and check alert thresholds (BR-SH-008, BR-SH-009)
        local updated_quota = aria_quota.check_quota(conf, consumer_id)
        local utilization_pct = aria_quota.emit_utilization_metrics(conf, consumer_id, updated_quota)
        if utilization_pct and conf.alerts then
            aria_quota.check_alert_thresholds(conf, consumer_id, utilization_pct, updated_quota)
        end
    end

    aria_core.counter_inc("aria_requests_total", 1, {
        consumer = consumer_id, model = body.model,
        route = route_id, status = "2xx",
    })
    aria_core.histogram_observe("aria_request_latency_seconds", latency, metric_labels)

    -- Build response with Aria headers
    local resp_headers_out = {
        ["Content-Type"]          = "application/json",
        ["X-Aria-Provider"]       = prov_conf.provider,
        ["X-Aria-Model"]          = body.model,
        ["X-Aria-Request-Id"]     = ctx.var.request_id or "",
    }
    if usage then
        resp_headers_out["X-Aria-Tokens-Input"]  = tostring(usage.prompt_tokens)
        resp_headers_out["X-Aria-Tokens-Output"] = tostring(usage.completion_tokens)
    end

    for k, v in pairs(resp_headers_out) do
        core.response.set_header(k, v)
    end

    return status, transformed_body
end


return _M
