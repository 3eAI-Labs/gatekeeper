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
        -- Traffic shadowing (BR-CN-006 / US-C06 + US-C07).
        --   Iter 1: Lua-only basic diff (status + body length + latency).
        --   Iter 2c: optional bridge to aria-runtime sidecar for structural JSON diff.
        shadow = {
            type = "object",
            properties = {
                enabled           = { type = "boolean", default = false },
                traffic_pct       = { type = "integer", minimum = 1, maximum = 100, default = 10 },
                shadow_upstream   = {
                    type = "object",
                    properties = {
                        nodes  = { type = "object" },  -- { "host:port" = weight, ... }
                        scheme = { type = "string", enum = {"http", "https"}, default = "http" },
                    },
                    required = {"nodes"},
                },
                timeout_ms        = { type = "integer", minimum = 100, maximum = 30000, default = 2000 },
                failure_threshold = { type = "integer", minimum = 1, maximum = 100, default = 3 },
                disable_window_seconds = { type = "integer", minimum = 30, maximum = 3600, default = 300 },
                -- Optional sidecar bridge for structural JSON diff (Iter 2c).
                -- When enabled AND bodies fit within max_body_bytes, the log-phase
                -- timer POSTs primary+shadow to the sidecar's /v1/diff endpoint
                -- and uses the structural result. Any failure silently falls back
                -- to the basic diff, so shadow never blocks on the sidecar.
                sidecar = {
                    type = "object",
                    properties = {
                        enabled        = { type = "boolean", default = false },
                        endpoint       = { type = "string", default = "http://127.0.0.1:8081" },
                        timeout_ms     = { type = "integer", minimum = 50, maximum = 10000, default = 500 },
                        max_body_bytes = { type = "integer", minimum = 1024, maximum = 10485760, default = 1048576 },
                    },
                    default = { enabled = false },
                },
            },
            default = { enabled = false },
        },
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

    -- Shadow requires shadow_upstream.nodes when enabled (BR-CN-006)
    if conf.shadow and conf.shadow.enabled then
        local up = conf.shadow.shadow_upstream
        if not up or not up.nodes or next(up.nodes) == nil then
            return false, "shadow.shadow_upstream.nodes is required when shadow.enabled = true"
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

local function shadow_failures_key(route_id)
    return "aria:canary:shadow:fails:" .. route_id
end

local function shadow_disabled_key(route_id)
    return "aria:canary:shadow:disabled:" .. route_id
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

    -- Shadow sampling + payload capture (BR-CN-006). Independent of canary state.
    -- Captured here because ngx.req.* is unavailable in timer ctx (log phase fires the call).
    if should_shadow(conf, ctx, route_id) then
        ctx.aria_shadow_payload = capture_shadow_payload(conf, ctx)
    end

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
-- Body Filter: Primary Response Body Capture (Iter 2c — sidecar bridge)
-- Only activates when shadow sampled AND sidecar bridge is enabled, so the
-- hold_body_chunk cost is skipped for unrelated traffic.
-- ────────────────────────────────────────────────────────────────────────────

function _M.body_filter(conf, ctx)
    if not ctx.aria_shadow_payload then return end

    local sc = conf.shadow and conf.shadow.sidecar
    if not sc or not sc.enabled then return end

    -- Skip streaming responses (SSE) — structural diff needs a complete body.
    local content_type = ngx.header["Content-Type"] or ""
    if content_type:find("text/event-stream", 1, true) then
        return
    end

    local body = core.response.hold_body_chunk(ctx)
    if not body then return end  -- still accumulating chunks

    -- Size cap: leave ctx.aria_primary_body nil so fire_shadow falls back to basic diff.
    local max_bytes = sc.max_body_bytes or 1048576
    if #body > max_bytes then
        aria_core.counter_inc("aria_shadow_sidecar_calls_total", 1, {
            route  = ctx.var.route_id or "unknown",
            result = "skipped_oversized",
        })
        return
    end

    ctx.aria_primary_body = body
end


-- ────────────────────────────────────────────────────────────────────────────
-- Log Phase: Error Tracking & Stage Progression (BR-CN-002, BR-CN-003, BR-CN-004)
-- ────────────────────────────────────────────────────────────────────────────

function _M.log(conf, ctx)
    local route_id = ctx.var.route_id or "default"
    local status = ngx.status
    local latency = ngx.now() - (ctx.aria_request_start or ngx.now())

    -- Shadow fire-and-forget (BR-CN-006). Independent of canary state.
    -- Scheduled here so primary response stats (status/bytes/latency) are final.
    if ctx.aria_shadow_payload then
        local primary = {
            status     = status,
            bytes_sent = tonumber(ctx.var.bytes_sent) or 0,
            latency_ms = latency * 1000,
        }
        -- aria_primary_body may be nil (sidecar disabled, streaming, or oversized);
        -- fire_shadow treats nil as "basic diff only".
        local ok, terr = ngx.timer.at(0, fire_shadow, conf, route_id,
            ctx.aria_shadow_payload, primary, ctx.aria_primary_body)
        if not ok then
            aria_core.log_error("shadow_timer_failed",
                str_fmt("Failed to schedule shadow for route %s: %s", route_id, terr or "unknown"))
        end
    end

    local version = ctx.aria_canary_version
    if not version then return end

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
-- Traffic Shadowing (BR-CN-006) — Iter 1: Lua-only basic diff
-- Sidecar-based structural diff lands in Iter 2 (US-C07).
-- ────────────────────────────────────────────────────────────────────────────

--- Pick a shadow node via weighted random selection.
-- @param upstream { nodes = { "host:port" = weight, ... }, scheme = "http"|"https" }
-- @return host:port string or nil
function pick_shadow_node(upstream)
    if not upstream or not upstream.nodes then return nil end

    local total_weight = 0
    for _, w in pairs(upstream.nodes) do total_weight = total_weight + w end
    if total_weight <= 0 then return nil end

    local pick = math.random(total_weight)
    local cursor = 0
    for node, w in pairs(upstream.nodes) do
        cursor = cursor + w
        if pick <= cursor then return node end
    end
    return nil
end

--- Check Redis-backed auto-disable flag (set after failure_threshold breaches).
function is_shadow_disabled(conf, route_id)
    local v = aria_core.redis_do(conf, function(red)
        return red:get(shadow_disabled_key(route_id))
    end)
    return v and v ~= ngx.null and tostring(v) == "1"
end

--- Increment failure counter; if threshold breached, auto-disable + emit metric.
function record_shadow_failure(conf, route_id, err)
    aria_core.counter_inc("aria_shadow_upstream_failures", 1, { route = route_id })

    local fk = shadow_failures_key(route_id)
    local count = aria_core.redis_do(conf, function(red)
        local n = red:incr(fk)
        red:expire(fk, 300)  -- 5 min sliding window
        return n
    end)

    local threshold = (conf.shadow and conf.shadow.failure_threshold) or 3
    if count and tonumber(count) >= threshold then
        local window = (conf.shadow and conf.shadow.disable_window_seconds) or 300
        aria_core.redis_do(conf, function(red)
            red:set(shadow_disabled_key(route_id), "1", "EX", window)
            red:del(fk)
            return true
        end)
        aria_core.counter_inc("aria_shadow_upstream_down", 1, { route = route_id })
        aria_core.log_warn("shadow_auto_disabled",
            str_fmt("Shadow auto-disabled for route %s after %d failures: %s",
                route_id, count, err or "unknown"))
    end
end

--- Reset failure counter on successful shadow request.
local function reset_shadow_failures(conf, route_id)
    aria_core.redis_do(conf, function(red)
        return red:del(shadow_failures_key(route_id))
    end)
end

--- Sampling decision (BR-CN-006 madde 1). Independent of canary state.
function should_shadow(conf, ctx, route_id)
    if not conf.shadow or not conf.shadow.enabled then return false end
    if ctx.var.http_x_aria_shadow == "true" then return false end  -- never shadow a shadow
    if is_shadow_disabled(conf, route_id) then return false end
    return math.random(100) <= (conf.shadow.traffic_pct or 10)
end

--- Capture request data in access phase so log phase can replay it.
-- Reading body here is required because ngx.req.* is not available in timer ctx.
function capture_shadow_payload(conf, ctx)
    ngx.req.read_body()
    local headers = ngx.req.get_headers(50) or {}
    headers["X-Aria-Shadow"] = "true"  -- BR-CN-006 madde 5: shadow upstream can opt-out side effects
    return {
        uri     = ctx.var.request_uri or "/",
        method  = ngx.req.get_method(),
        body    = ngx.req.get_body_data(),
        headers = headers,
    }
end

--- Compute basic diff: status, body length, latency.
-- Returns { status_match, body_length_delta, latency_delta_ms, has_diff, diff_type }
function compute_basic_diff(primary, shadow)
    local status_match = (primary.status == shadow.status)
    local primary_len = primary.bytes_sent or 0
    local shadow_len = #(shadow.body or "")
    local body_length_delta = math.abs(shadow_len - primary_len)
    local latency_delta_ms = math_floor(shadow.latency_ms - primary.latency_ms)

    local diff_type = nil
    if not status_match then
        diff_type = "status"
    elseif body_length_delta > 0 then
        diff_type = "body_length"
    end

    return {
        status_match      = status_match,
        body_length_delta = body_length_delta,
        latency_delta_ms  = latency_delta_ms,
        has_diff          = (diff_type ~= nil),
        diff_type         = diff_type,
    }
end

--- Try structural diff via the sidecar bridge (Iter 2c). Returns a diff table
-- in the same shape as compute_basic_diff, OR nil when the sidecar is skipped,
-- unreachable, or the response is unparseable — caller must then fall back.
function try_sidecar_diff(conf, route_id, primary, primary_body, shadow_status, shadow_body, shadow_latency_ms)
    local sc = conf.shadow and conf.shadow.sidecar
    if not sc or not sc.enabled then return nil end
    if not primary_body then return nil end  -- streaming / oversized / disabled

    local max_bytes = sc.max_body_bytes or 1048576
    if #primary_body > max_bytes or (shadow_body and #shadow_body > max_bytes) then
        aria_core.counter_inc("aria_shadow_sidecar_calls_total", 1, {
            route = route_id, result = "skipped_oversized",
        })
        return nil
    end

    local req_payload = cjson.encode({
        requestId        = ngx.var.request_id or "",
        routeId          = route_id,
        primaryStatus    = primary.status,
        primaryBody      = ngx.encode_base64(primary_body),
        primaryLatencyMs = math_floor(primary.latency_ms),
        shadowStatus     = shadow_status,
        shadowBody       = ngx.encode_base64(shadow_body or ""),
        shadowLatencyMs  = math_floor(shadow_latency_ms),
    })

    local httpc = require("resty.http").new()
    httpc:set_timeout(sc.timeout_ms or 500)

    local endpoint = (sc.endpoint or "http://127.0.0.1:8081") .. "/v1/diff"
    local res, err = httpc:request_uri(endpoint, {
        method  = "POST",
        body    = req_payload,
        headers = { ["Content-Type"] = "application/json" },
    })

    if not res or res.status ~= 200 then
        aria_core.counter_inc("aria_shadow_sidecar_calls_total", 1, {
            route  = route_id,
            result = "error",
        })
        aria_core.log_warn("shadow_sidecar_unavailable",
            str_fmt("Sidecar diff failed for route %s: %s",
                route_id, err or ("http_" .. (res and res.status or "unknown"))))
        return nil
    end

    local parsed = cjson.decode(res.body or "")
    if not parsed then
        aria_core.counter_inc("aria_shadow_sidecar_calls_total", 1, {
            route = route_id, result = "error",
        })
        return nil
    end

    aria_core.counter_inc("aria_shadow_sidecar_calls_total", 1, {
        route = route_id, result = "ok",
    })

    local similarity = tonumber(parsed.bodySimilarity) or 0
    aria_core.histogram_observe("aria_shadow_body_similarity",
        similarity, { route = route_id })

    local status_match = parsed.statusMatch == true
    local has_diff = (not status_match) or similarity < 1.0
    local diff_type
    if not status_match then
        diff_type = "status"
    elseif similarity < 1.0 then
        diff_type = "structural"
    end

    return {
        status_match      = status_match,
        body_similarity   = similarity,
        latency_delta_ms  = tonumber(parsed.latencyDeltaMs) or 0,
        has_diff          = has_diff,
        diff_type         = diff_type,
        diff_fields       = parsed.diffFields,
        diff_summary      = parsed.diffSummary,
    }
end


--- ngx.timer callback: fire shadow request, record metrics, update failure state.
-- @param primary_body  Full primary response body (nil if sidecar disabled /
--                      streaming / oversized); triggers the sidecar bridge path
--                      when present, falls back to basic diff otherwise.
function fire_shadow(premature, conf, route_id, payload, primary, primary_body)
    if premature then return end

    aria_core.counter_inc("aria_shadow_requests_total", 1, { route = route_id })

    local node = pick_shadow_node(conf.shadow.shadow_upstream)
    if not node then
        record_shadow_failure(conf, route_id, "no_node")
        return
    end

    local scheme = (conf.shadow.shadow_upstream.scheme) or "http"
    local url = scheme .. "://" .. node .. payload.uri

    local httpc = require("resty.http").new()
    httpc:set_timeout(conf.shadow.timeout_ms or 2000)

    local shadow_start = ngx.now()
    local res, err = httpc:request_uri(url, {
        method  = payload.method,
        body    = payload.body,
        headers = payload.headers,
    })
    local shadow_latency_ms = (ngx.now() - shadow_start) * 1000

    if not res then
        record_shadow_failure(conf, route_id, err)
        return
    end

    reset_shadow_failures(conf, route_id)

    -- Try structural diff via sidecar; fall back to basic diff on any failure.
    local diff = try_sidecar_diff(conf, route_id, primary, primary_body,
        res.status, res.body, shadow_latency_ms)

    if not diff then
        diff = compute_basic_diff(primary, {
            status     = res.status,
            body       = res.body,
            latency_ms = shadow_latency_ms,
        })
    end

    aria_core.histogram_observe("aria_shadow_latency_delta_ms",
        diff.latency_delta_ms, { route = route_id })

    if diff.has_diff then
        aria_core.counter_inc("aria_shadow_diff_count", 1, {
            route = route_id,
            type  = diff.diff_type,
        })
    end
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
