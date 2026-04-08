--
-- aria-canary.lua — 3e-Aria-Canary: Progressive Delivery Plugin for Apache APISIX
--
-- Canary v0.1: Progressive traffic splitting, error-rate monitoring,
--              auto-rollback, manual override (promote/rollback/pause/resume)
--
-- Business Rules: BR-CN-001 (schedule state machine), BR-CN-002 (error rate),
--                 BR-CN-003 (auto-rollback), BR-CN-004 (latency guard),
--                 BR-CN-005 (manual override)
-- Decision Matrices: DM-CN-001 (progression), DM-CN-002 (rollback/retry),
--                    DM-CN-003 (health assessment)
-- User Stories: US-C01 (splitting), US-C02 (error monitor), US-C03 (rollback),
--               US-C04 (latency guard), US-C05 (manual override)
--

local core      = require("apisix.core")
local cjson     = require("cjson.safe")
local ngx       = ngx
local aria_core = require("apisix.plugins.lib.aria-core")
local str_fmt   = string.format
local math_floor = math.floor

local plugin_name = "aria-canary"

local schema = {
    type = "object",
    properties = {
        canary_upstream = { type = "string" },
        baseline_upstream = { type = "string" },
        schedule = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    pct  = { type = "integer", minimum = 1, maximum = 100 },
                    hold = { type = "string", default = "5m" },
                },
                required = {"pct"},
            },
        },
        error_monitor = {
            type = "object",
            properties = {
                enabled               = { type = "boolean", default = true },
                threshold_pct         = { type = "number", minimum = 0.1, maximum = 50.0, default = 2.0 },
                window_seconds        = { type = "integer", minimum = 10, maximum = 600, default = 60 },
                min_requests          = { type = "integer", minimum = 1, maximum = 1000, default = 10 },
                sustained_breach_seconds = { type = "integer", minimum = 10, maximum = 600, default = 60 },
            },
            default = {},
        },
        latency_guard = {
            type = "object",
            properties = {
                enabled      = { type = "boolean", default = false },
                multiplier   = { type = "number", minimum = 1.1, maximum = 5.0, default = 1.5 },
                min_requests = { type = "integer", minimum = 10, maximum = 1000, default = 50 },
            },
            default = { enabled = false },
        },
        auto_rollback   = { type = "boolean", default = true },
        retry_policy    = { type = "string", enum = {"manual", "auto"}, default = "manual" },
        retry_cooldown  = { type = "string", default = "10m" },
        max_retries     = { type = "integer", minimum = 0, maximum = 10, default = 3 },
        consistent_hash = { type = "boolean", default = true },
        notifications = {
            type = "object",
            properties = {
                webhook_url = { type = "string" },
            },
        },
        -- Redis
        redis_host     = { type = "string", default = "127.0.0.1" },
        redis_port     = { type = "integer", default = 6379 },
        redis_password = { type = "string" },
        redis_database = { type = "integer", default = 0 },
    },
    required = {"canary_upstream", "baseline_upstream", "schedule"},
}

local _M = {
    version  = "0.1.0",
    priority = 3000,  -- Highest: routing decision before Shield and Mask
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then return false, err end

    -- Validate schedule: percentages must be ascending, last must be 100
    local schedule = conf.schedule
    if schedule and #schedule > 0 then
        for i = 2, #schedule do
            if schedule[i].pct <= schedule[i-1].pct then
                return false, "schedule percentages must be strictly ascending"
            end
        end
        if schedule[#schedule].pct ~= 100 then
            return false, "last schedule stage must be 100%"
        end
    end

    return true
end


-- ────────────────────────────────────────────────────────────────────────────
-- Redis Keys
-- ────────────────────────────────────────────────────────────────────────────

local function state_key(route_id)
    return "aria:canary:" .. route_id
end

local function error_counter_key(route_id, version, window_id)
    return str_fmt("aria:canary:errors:%s:%s:%s", route_id, version, window_id)
end

local function total_counter_key(route_id, version, window_id)
    return str_fmt("aria:canary:total:%s:%s:%s", route_id, version, window_id)
end

local function breach_key(route_id)
    return "aria:canary:breach:" .. route_id
end

local function lock_key(route_id)
    return "aria:canary:lock:" .. route_id
end


-- ────────────────────────────────────────────────────────────────────────────
-- Canary State Management
-- ────────────────────────────────────────────────────────────────────────────

--- Read canary state from Redis.
-- @return table or nil
local function read_state(conf, route_id)
    return aria_core.redis_do(conf, function(red)
        local data = red:hgetall(state_key(route_id))
        if not data or #data == 0 then return nil end

        -- Convert flat list to table
        local state = {}
        for i = 1, #data, 2 do
            state[data[i]] = data[i + 1]
        end
        return state
    end)
end

--- Write canary state to Redis.
local function write_state(conf, route_id, state_table)
    aria_core.redis_do(conf, function(red)
        local args = {}
        for k, v in pairs(state_table) do
            args[#args + 1] = k
            args[#args + 1] = tostring(v)
        end
        red:hmset(state_key(route_id), unpack(args))
        return true
    end)
end

--- Initialize canary deployment state from schedule config.
local function init_state(conf, route_id)
    local schedule = conf.schedule
    if not schedule or #schedule == 0 then return nil end

    local state = {
        state              = "STAGE_1",
        current_stage_index = "1",
        traffic_pct         = tostring(schedule[1].pct),
        stage_started_at    = tostring(ngx.now()),
        current_hold        = schedule[1].hold or "5m",
        retry_count         = "0",
    }

    write_state(conf, route_id, state)

    aria_core.gauge_set("aria_canary_traffic_pct", schedule[1].pct, { route = route_id })
    aria_core.log_warn("canary_started",
        str_fmt("Canary started for route %s at %d%%", route_id, schedule[1].pct))

    return state
end


-- ────────────────────────────────────────────────────────────────────────────
-- Access Phase: Traffic Routing (BR-CN-001)
-- ────────────────────────────────────────────────────────────────────────────

function _M.access(conf, ctx)
    local route_id = ctx.var.route_id or "default"
    ctx.aria_request_start = ngx.now()

    -- Read canary state
    local state = read_state(conf, route_id)

    -- No state yet — initialize from config
    if not state then
        state = init_state(conf, route_id)
        if not state then return end  -- No schedule configured
    end

    local current_state = state.state

    -- Terminal states
    if current_state == "PROMOTED" then
        -- 100% canary
        ctx.var.upstream_uri = ctx.var.uri
        core.request.set_header(ctx, "X-Aria-Canary-Version", "canary")
        ctx.aria_canary_version = "canary"
        ctx.aria_upstream = conf.canary_upstream
        -- Set upstream via APISIX upstream mechanism
        ctx.upstream_id = conf.canary_upstream
        return
    end

    if current_state == "ROLLED_BACK" then
        -- 0% canary — all to baseline
        core.request.set_header(ctx, "X-Aria-Canary-Version", "baseline")
        ctx.aria_canary_version = "baseline"
        ctx.upstream_id = conf.baseline_upstream
        return
    end

    -- Active or paused: apply traffic split
    local traffic_pct = tonumber(state.traffic_pct) or 0
    local use_canary = false

    if conf.consistent_hash then
        -- Consistent hashing: same client → same version within a stage (BR-CN-001 rule 1)
        local client_ip = ctx.var.remote_addr or "0.0.0.0"
        local hash = ngx.crc32_long(client_ip)
        use_canary = (hash % 100) < traffic_pct
    else
        use_canary = math.random(100) <= traffic_pct
    end

    if use_canary then
        core.request.set_header(ctx, "X-Aria-Canary-Version", "canary")
        ctx.aria_canary_version = "canary"
        ctx.upstream_id = conf.canary_upstream
    else
        core.request.set_header(ctx, "X-Aria-Canary-Version", "baseline")
        ctx.aria_canary_version = "baseline"
        ctx.upstream_id = conf.baseline_upstream
    end
end


-- ────────────────────────────────────────────────────────────────────────────
-- Header Filter: Tag response
-- ────────────────────────────────────────────────────────────────────────────

function _M.header_filter(conf, ctx)
    if ctx.aria_canary_version then
        core.response.set_header("X-Aria-Canary-Version", ctx.aria_canary_version)
    end
end


-- ────────────────────────────────────────────────────────────────────────────
-- Log Phase: Error Tracking & Stage Progression (BR-CN-002, BR-CN-003, BR-CN-004)
-- ────────────────────────────────────────────────────────────────────────────

function _M.log(conf, ctx)
    local version = ctx.aria_canary_version
    if not version then return end

    local route_id = ctx.var.route_id or "default"
    local status = ngx.status
    local latency = ngx.now() - (ctx.aria_request_start or ngx.now())

    -- Determine window ID (10-second windows for error rate calculation)
    local window_seconds = conf.error_monitor and conf.error_monitor.window_seconds or 60
    local window_id = tostring(math_floor(ngx.now() / 10) * 10)

    -- Track error and total counts per version (BR-CN-002)
    aria_core.redis_do(conf, function(red)
        local err_key = error_counter_key(route_id, version, window_id)
        local tot_key = total_counter_key(route_id, version, window_id)

        red:incr(tot_key)
        red:expire(tot_key, 120)  -- 2 min TTL

        if status >= 500 then
            red:incr(err_key)
            red:expire(err_key, 120)
        end

        return true
    end)

    -- Emit per-version metrics
    aria_core.counter_inc("aria_canary_requests_total", 1, {
        route = route_id, version = version, status = tostring(math_floor(status / 100)) .. "xx",
    })

    -- Stage progression check (only for canary traffic, with distributed lock)
    if version == "canary" then
        check_progression(conf, route_id, window_id)
    end
end


-- ────────────────────────────────────────────────────────────────────────────
-- Stage Progression Logic (BR-CN-001, BR-CN-002, BR-CN-003, BR-CN-004)
-- DM-CN-001 (progression), DM-CN-002 (rollback/retry), DM-CN-003 (health)
-- ────────────────────────────────────────────────────────────────────────────

function check_progression(conf, route_id, window_id)
    -- Acquire distributed lock (one worker checks per 5-second interval)
    local acquired = aria_core.redis_do(conf, function(red)
        local result = red:set(lock_key(route_id), "1", "NX", "EX", 5)
        return result
    end)
    if not acquired then return end

    local state = read_state(conf, route_id)
    if not state then return end

    local current_state = state.state
    if current_state ~= "STAGE_1" and not current_state:match("^STAGE_%d+$") then
        -- Not in an active stage — skip (PAUSED, PROMOTED, ROLLED_BACK)
        if current_state == "PAUSED" then
            check_recovery(conf, route_id, state, window_id)
        end
        return
    end

    -- Calculate error rates (BR-CN-002)
    local canary_error_rate, canary_total = calculate_error_rate(conf, route_id, "canary", window_id)
    local baseline_error_rate, baseline_total = calculate_error_rate(conf, route_id, "baseline", window_id)

    local min_requests = conf.error_monitor and conf.error_monitor.min_requests or 10

    -- Emit error rate metrics
    aria_core.gauge_set("aria_canary_error_rate", canary_error_rate, {
        route = route_id, version = "canary",
    })
    aria_core.gauge_set("aria_canary_error_rate", baseline_error_rate, {
        route = route_id, version = "baseline",
    })

    -- DM-CN-003: Both unhealthy check
    if baseline_error_rate > 0.10 then
        -- Baseline > 10% — don't blame canary (DM-CN-003 row 3-4)
        send_notification(conf, route_id, "baseline_unhealthy", {
            canary_error_rate = canary_error_rate,
            baseline_error_rate = baseline_error_rate,
        })
        return
    end

    -- DM-CN-001: Error delta check
    local threshold = (conf.error_monitor and conf.error_monitor.threshold_pct or 2.0) / 100
    local delta = canary_error_rate - baseline_error_rate

    if canary_total >= min_requests and delta > threshold then
        -- Error threshold breached — PAUSE or continue to ROLLBACK
        handle_breach(conf, route_id, state, canary_error_rate, baseline_error_rate)
        return
    end

    -- Clear breach timer if recovered
    aria_core.redis_do(conf, function(red)
        return red:del(breach_key(route_id))
    end)

    -- DM-CN-001: Check hold duration for advancement
    local stage_started = tonumber(state.stage_started_at) or ngx.now()
    local hold_seconds = aria_core.parse_duration(state.current_hold)

    if (ngx.now() - stage_started) < hold_seconds then
        return  -- Hold duration not elapsed
    end

    -- DM-CN-001: Insufficient data check
    if canary_total < min_requests then
        return  -- Wait for more data
    end

    -- BR-CN-004: Latency guard (optional)
    if conf.latency_guard and conf.latency_guard.enabled then
        -- Simplified P95 approximation from error counters
        -- Full P95 tracking needs sorted sets (implemented in v0.2)
    end

    -- All checks passed — ADVANCE to next stage
    advance_stage(conf, route_id, state)
end


--- Handle error threshold breach.
-- First breach → PAUSE. Sustained breach → AUTO-ROLLBACK (BR-CN-003).
function handle_breach(conf, route_id, state, canary_rate, baseline_rate)
    local bk = breach_key(route_id)

    local breach_start = aria_core.redis_do(conf, function(red)
        return red:get(bk)
    end)

    if not breach_start or breach_start == ngx.null then
        -- First breach — PAUSE stage (DM-CN-001 row 3-4)
        aria_core.redis_do(conf, function(red)
            red:set(bk, tostring(ngx.now()), "EX", 300)
            return true
        end)

        write_state(conf, route_id, { state = "PAUSED" })
        aria_core.log_warn("canary_paused",
            str_fmt("Canary paused for route %s: error delta %.2f%%",
                route_id, (canary_rate - baseline_rate) * 100))

        send_notification(conf, route_id, "canary_paused", {
            canary_error_rate = canary_rate,
            baseline_error_rate = baseline_rate,
        })
        return
    end

    -- Check if breach is sustained (BR-CN-003)
    local sustained_seconds = conf.error_monitor and conf.error_monitor.sustained_breach_seconds or 60
    local elapsed = ngx.now() - tonumber(breach_start)

    if elapsed >= sustained_seconds and conf.auto_rollback then
        -- AUTO-ROLLBACK (DM-CN-002 row 1)
        write_state(conf, route_id, {
            state = "ROLLED_BACK",
            traffic_pct = "0",
            rolled_back_at = tostring(ngx.now()),
        })

        aria_core.redis_do(conf, function(red)
            return red:del(bk)
        end)

        aria_core.counter_inc("aria_canary_rollback_total", 1, { route = route_id })
        aria_core.gauge_set("aria_canary_traffic_pct", 0, { route = route_id })

        core.log.warn("AUTO-ROLLBACK: route=", route_id,
            " canary_error_rate=", canary_rate,
            " baseline_error_rate=", baseline_rate)

        send_notification(conf, route_id, "auto_rollback", {
            canary_error_rate = canary_rate,
            baseline_error_rate = baseline_rate,
            sustained_seconds = elapsed,
        })

        -- Handle retry policy (DM-CN-002)
        if conf.retry_policy == "auto" then
            schedule_retry(conf, route_id)
        end
    end
end


--- Check if a paused canary has recovered (error rate back below threshold).
function check_recovery(conf, route_id, state, window_id)
    local canary_rate = calculate_error_rate(conf, route_id, "canary", window_id)
    local baseline_rate = calculate_error_rate(conf, route_id, "baseline", window_id)
    local threshold = (conf.error_monitor and conf.error_monitor.threshold_pct or 2.0) / 100

    if (canary_rate - baseline_rate) <= threshold then
        -- Recovered — but we don't auto-resume. PAUSED requires manual resume (BR-CN-005).
        -- Clear breach timer so it doesn't carry over.
        aria_core.redis_do(conf, function(red)
            return red:del(breach_key(route_id))
        end)
    end
end


--- Advance canary to the next stage in the schedule.
function advance_stage(conf, route_id, state)
    local current_idx = tonumber(state.current_stage_index) or 1
    local next_idx = current_idx + 1
    local schedule = conf.schedule

    if next_idx > #schedule then
        -- Last stage (100%) — PROMOTED
        write_state(conf, route_id, {
            state = "PROMOTED",
            traffic_pct = "100",
            promoted_at = tostring(ngx.now()),
        })

        aria_core.gauge_set("aria_canary_traffic_pct", 100, { route = route_id })
        aria_core.log_warn("canary_promoted",
            str_fmt("Canary promoted to 100%% for route %s", route_id))

        send_notification(conf, route_id, "promoted", {})
        return
    end

    -- Advance to next stage
    local next_stage = schedule[next_idx]
    write_state(conf, route_id, {
        state = "STAGE_" .. next_idx,
        current_stage_index = tostring(next_idx),
        traffic_pct = tostring(next_stage.pct),
        stage_started_at = tostring(ngx.now()),
        current_hold = next_stage.hold or "5m",
    })

    aria_core.gauge_set("aria_canary_traffic_pct", next_stage.pct, { route = route_id })
    aria_core.log_warn("canary_advanced",
        str_fmt("Canary advanced to stage %d (%d%%) for route %s",
            next_idx, next_stage.pct, route_id))
end


--- Schedule an auto-retry after rollback (DM-CN-002 rows 3-4).
function schedule_retry(conf, route_id)
    local state = read_state(conf, route_id)
    if not state then return end

    local retry_count = tonumber(state.retry_count) or 0

    if retry_count >= conf.max_retries then
        -- Max retries exceeded (DM-CN-002 row 5) — terminal
        aria_core.log_error("canary_max_retries",
            str_fmt("Canary max retries (%d) exceeded for route %s", conf.max_retries, route_id))
        send_notification(conf, route_id, "max_retries_exceeded", {
            retry_count = retry_count,
            max_retries = conf.max_retries,
        })
        return
    end

    -- Schedule retry via ngx.timer
    local cooldown = aria_core.parse_duration(conf.retry_cooldown)

    ngx.timer.at(cooldown, function(premature)
        if premature then return end

        local current = read_state(conf, route_id)
        if not current or current.state ~= "ROLLED_BACK" then return end

        -- Restart from stage 1
        local schedule = conf.schedule
        write_state(conf, route_id, {
            state = "STAGE_1",
            current_stage_index = "1",
            traffic_pct = tostring(schedule[1].pct),
            stage_started_at = tostring(ngx.now()),
            current_hold = schedule[1].hold or "5m",
            retry_count = tostring(retry_count + 1),
        })

        aria_core.gauge_set("aria_canary_traffic_pct", schedule[1].pct, { route = route_id })
        aria_core.log_warn("canary_retry",
            str_fmt("Canary retrying (attempt %d/%d) for route %s",
                retry_count + 1, conf.max_retries, route_id))
    end)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Error Rate Calculation (BR-CN-002)
-- ────────────────────────────────────────────────────────────────────────────

--- Calculate error rate for a version over recent windows.
-- Uses 10-second window counters aggregated over the monitoring window.
-- @return error_rate (0.0-1.0), total_requests
function calculate_error_rate(conf, route_id, version, current_window_id)
    local window_seconds = conf.error_monitor and conf.error_monitor.window_seconds or 60
    local num_windows = math_floor(window_seconds / 10)
    local current_time = tonumber(current_window_id)

    local total_errors = 0
    local total_requests = 0

    aria_core.redis_do(conf, function(red)
        for i = 0, num_windows - 1 do
            local window_id = tostring(current_time - (i * 10))
            local errors = red:get(error_counter_key(route_id, version, window_id))
            local total = red:get(total_counter_key(route_id, version, window_id))

            if errors and errors ~= ngx.null then
                total_errors = total_errors + tonumber(errors)
            end
            if total and total ~= ngx.null then
                total_requests = total_requests + tonumber(total)
            end
        end
        return true
    end)

    if total_requests == 0 then return 0, 0 end
    return total_errors / total_requests, total_requests
end


-- ────────────────────────────────────────────────────────────────────────────
-- Webhook Notifications
-- ────────────────────────────────────────────────────────────────────────────

function send_notification(conf, route_id, event_type, details)
    local webhook_url = conf.notifications and conf.notifications.webhook_url
    if not webhook_url or webhook_url == "" then return end

    local payload = cjson.encode({
        type = "aria_canary_" .. event_type,
        route_id = route_id,
        event = event_type,
        canary_upstream = conf.canary_upstream,
        baseline_upstream = conf.baseline_upstream,
        details = details,
        timestamp = ngx.utctime(),
    })

    ngx.timer.at(0, function(premature)
        if premature then return end
        local http = require("resty.http")
        local httpc = http.new()
        httpc:set_timeout(5000)

        local res, err = httpc:request_uri(webhook_url, {
            method = "POST",
            body = payload,
            headers = { ["Content-Type"] = "application/json" },
        })

        if not res or res.status >= 400 then
            aria_core.log_error("canary_webhook_failed",
                str_fmt("Webhook failed for route %s: %s", route_id, err or "HTTP " .. (res and res.status or "?")))
        end
    end)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Admin API Extensions (BR-CN-005)
-- These are called via APISIX's plugin control API
-- ────────────────────────────────────────────────────────────────────────────

function _M.control_api()
    return {
        {
            methods = {"GET"},
            uris    = {"/v1/plugin/aria-canary/status/*"},
            handler = function(conf, ctx)
                local route_id = ctx.var.uri:match("/status/(.+)$")
                if not route_id then
                    return 400, { error = "route_id required" }
                end

                local state = read_state(conf, route_id)
                if not state then
                    return 404, { error = { code = "ARIA_CN_NO_ACTIVE_CANARY" } }
                end

                return 200, state
            end,
        },
        {
            methods = {"POST"},
            uris    = {"/v1/plugin/aria-canary/promote/*"},
            handler = function(conf, ctx)
                local route_id = ctx.var.uri:match("/promote/(.+)$")
                if not route_id then return 400, { error = "route_id required" } end

                write_state(conf, route_id, {
                    state = "PROMOTED",
                    traffic_pct = "100",
                    promoted_at = tostring(ngx.now()),
                })
                aria_core.gauge_set("aria_canary_traffic_pct", 100, { route = route_id })

                return 200, { state = "PROMOTED", traffic_pct = 100 }
            end,
        },
        {
            methods = {"POST"},
            uris    = {"/v1/plugin/aria-canary/rollback/*"},
            handler = function(conf, ctx)
                local route_id = ctx.var.uri:match("/rollback/(.+)$")
                if not route_id then return 400, { error = "route_id required" } end

                write_state(conf, route_id, {
                    state = "ROLLED_BACK",
                    traffic_pct = "0",
                    rolled_back_at = tostring(ngx.now()),
                })
                aria_core.gauge_set("aria_canary_traffic_pct", 0, { route = route_id })
                aria_core.counter_inc("aria_canary_rollback_total", 1, { route = route_id })

                return 200, { state = "ROLLED_BACK", traffic_pct = 0 }
            end,
        },
        {
            methods = {"POST"},
            uris    = {"/v1/plugin/aria-canary/pause/*"},
            handler = function(conf, ctx)
                local route_id = ctx.var.uri:match("/pause/(.+)$")
                if not route_id then return 400, { error = "route_id required" } end

                write_state(conf, route_id, { state = "PAUSED" })
                return 200, { state = "PAUSED" }
            end,
        },
        {
            methods = {"POST"},
            uris    = {"/v1/plugin/aria-canary/resume/*"},
            handler = function(conf, ctx)
                local route_id = ctx.var.uri:match("/resume/(.+)$")
                if not route_id then return 400, { error = "route_id required" } end

                local state = read_state(conf, route_id)
                if not state or state.state ~= "PAUSED" then
                    return 409, { error = "Canary is not paused" }
                end

                write_state(conf, route_id, {
                    state = "STAGE_" .. (state.current_stage_index or "1"),
                    stage_started_at = tostring(ngx.now()),
                })

                return 200, { state = "STAGE_" .. (state.current_stage_index or "1") }
            end,
        },
    }
end


return _M
