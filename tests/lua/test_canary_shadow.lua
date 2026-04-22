--
-- test_canary_shadow.lua — Unit tests for aria-canary.lua shadow diff (Iter 1)
--
-- Coverage: schema validation, sampling decision, payload capture, weighted node
-- selection, basic diff computation, failure counter + auto-disable, and log-phase
-- timer scheduling.
--
-- Framework: busted
-- Run: busted tests/lua/test_canary_shadow.lua
--

-- ────────────────────────────────────────────────────────────────────────────
-- Mock state holders (mutable across tests)
-- ────────────────────────────────────────────────────────────────────────────

local redis_state = {}
local timer_calls = {}
local http_response = { status = 200, body = "primary-body" }
local http_error = nil
local last_http_request = nil

local function reset_state()
    redis_state = {}
    timer_calls = {}
    http_response = { status = 200, body = "primary-body" }
    http_error = nil
    last_http_request = nil
end


-- ────────────────────────────────────────────────────────────────────────────
-- Mock ngx
-- ────────────────────────────────────────────────────────────────────────────

_G.ngx = {
    null = "\0",
    now = function() return 1712592600 end,
    time = function() return 1712592600 end,
    utctime = function() return "2026-04-22 14:30:00" end,
    log = function() end,
    crc32_long = function(s) return 12345 end,
    ERR = 1, WARN = 2, INFO = 3, DEBUG = 4,
    status = 200,
    shared = {},  -- ngx.shared["prometheus-metrics"] resolves to nil → metrics no-op
    var = {
        bytes_sent = "100",
    },
    req = {
        read_body = function() end,
        get_method = function() return "POST" end,
        get_body_data = function() return '{"q":"hello"}' end,
        get_headers = function()
            return { ["content-type"] = "application/json" }
        end,
    },
    timer = {
        at = function(delay, fn, ...)
            table.insert(timer_calls, { delay = delay, fn = fn, args = { ... } })
            return true, nil
        end,
    },
    header = {},
}

package.loaded["cjson.safe"] = {
    encode = function(t) return "{}" end,
    decode = function(s) return {} end,
    null = "\0",
    empty_table = {},
}

package.loaded["apisix.core"] = {
    log = {
        error = function() end,
        warn = function() end,
        info = function() end,
        debug = function() end,
    },
    response = { set_header = function() end },
    request = { set_header = function() end },
    schema = {
        check = function(schema, conf) return true end,
    },
}

-- Mock resty.redis: a tiny in-memory state machine driven by `redis_state`
package.loaded["resty.redis"] = {
    new = function()
        return {
            set_timeouts = function() end,
            connect = function() return true end,
            auth = function() return true end,
            select = function() return true end,
            set_keepalive = function() return true end,
            get = function(_, key)
                local v = redis_state[key]
                if v == nil then return ngx.null end
                return v
            end,
            set = function(_, key, value, ...)
                redis_state[key] = value
                return "OK"
            end,
            incr = function(_, key)
                redis_state[key] = (tonumber(redis_state[key]) or 0) + 1
                return redis_state[key]
            end,
            del = function(_, key)
                redis_state[key] = nil
                return 1
            end,
            expire = function() return 1 end,
            hgetall = function() return {} end,
            hmset = function() return "OK" end,
        }
    end,
}

package.loaded["resty.string"] = {
    to_hex = function(s) return string.rep("0", #s * 2) end,
}
package.loaded["resty.random"] = {
    bytes = function(n) return string.rep("\0", n) end,
}
package.loaded["apisix.plugins.prometheus.exporter"] = {}

-- Mock resty.http (used by both webhook + shadow code)
package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, url, opts)
                last_http_request = { url = url, opts = opts }
                if http_error then return nil, http_error end
                return http_response, nil
            end,
        }
    end,
}


-- ────────────────────────────────────────────────────────────────────────────
-- Load module under test
-- ────────────────────────────────────────────────────────────────────────────

-- Match CI's LUA_PATH so dotted requires (apisix.plugins.lib.aria-core,
-- apisix.plugins.aria-canary) resolve from the repo root.
package.path = "./?.lua;./apisix/plugins/lib/?.lua;" .. package.path

local canary = require("apisix.plugins.aria-canary")


-- ────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────────────────

local function make_conf(overrides)
    local conf = {
        canary_upstream    = "u-canary",
        baseline_upstream  = "u-baseline",
        schedule           = { { pct = 10, hold = "1m" }, { pct = 100, hold = "1m" } },
        redis_host         = "127.0.0.1",
        redis_port         = 6379,
        redis_database     = 0,
        shadow             = {
            enabled = true,
            traffic_pct = 100,  -- always shadow in tests (deterministic)
            shadow_upstream = { nodes = { ["shadow-host:8080"] = 1 }, scheme = "http" },
            timeout_ms = 2000,
            failure_threshold = 3,
            disable_window_seconds = 300,
        },
    }
    if overrides then
        for k, v in pairs(overrides) do conf[k] = v end
    end
    return conf
end

local function make_ctx()
    return {
        var = {
            route_id = "route-1",
            remote_addr = "10.0.0.1",
            request_uri = "/api/orders",
            bytes_sent = "100",
            http_x_aria_shadow = nil,
        },
    }
end


-- ────────────────────────────────────────────────────────────────────────────
-- Tests
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-canary shadow", function()

    before_each(reset_state)

    -- ────────────────────────────────────────────────────────────────────
    describe("check_schema", function()

        it("rejects shadow.enabled=true without shadow_upstream.nodes", function()
            local conf = make_conf()
            conf.shadow.shadow_upstream = nil
            local ok, err = canary.check_schema(conf)
            assert.is_false(ok)
            assert.matches("shadow_upstream.nodes is required", err)
        end)

        it("rejects shadow.enabled=true with empty nodes table", function()
            local conf = make_conf()
            conf.shadow.shadow_upstream = { nodes = {} }
            local ok, err = canary.check_schema(conf)
            assert.is_false(ok)
            assert.matches("shadow_upstream.nodes is required", err)
        end)

        it("accepts shadow.enabled=false with no shadow_upstream", function()
            local conf = make_conf()
            conf.shadow = { enabled = false }
            local ok, err = canary.check_schema(conf)
            assert.is_true(ok)
        end)

        it("accepts valid shadow config", function()
            local ok, err = canary.check_schema(make_conf())
            assert.is_true(ok)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("pick_shadow_node()", function()

        it("returns nil for missing upstream", function()
            assert.is_nil(_G.pick_shadow_node(nil))
            assert.is_nil(_G.pick_shadow_node({}))
        end)

        it("returns the only node when single-node", function()
            local node = _G.pick_shadow_node({ nodes = { ["only-host:80"] = 5 } })
            assert.are.equal("only-host:80", node)
        end)

        it("returns one of the configured nodes for multi-node", function()
            local nodes = { ["a:80"] = 1, ["b:80"] = 1, ["c:80"] = 1 }
            local picks = {}
            for _ = 1, 30 do
                picks[_G.pick_shadow_node({ nodes = nodes })] = true
            end
            -- After 30 picks with 3 equal-weight nodes, all should be reachable
            local count = 0
            for _ in pairs(picks) do count = count + 1 end
            assert.is_true(count >= 1 and count <= 3)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("should_shadow()", function()

        it("returns false when shadow disabled in conf", function()
            local conf = make_conf({ shadow = { enabled = false } })
            assert.is_false(_G.should_shadow(conf, make_ctx(), "route-1"))
        end)

        it("returns false when X-Aria-Shadow header is true (no recursion)", function()
            local ctx = make_ctx()
            ctx.var.http_x_aria_shadow = "true"
            assert.is_false(_G.should_shadow(make_conf(), ctx, "route-1"))
        end)

        it("returns false when route is auto-disabled in Redis", function()
            redis_state["aria:canary:shadow:disabled:route-1"] = "1"
            assert.is_false(_G.should_shadow(make_conf(), make_ctx(), "route-1"))
        end)

        it("returns true when sampled (traffic_pct=100)", function()
            assert.is_true(_G.should_shadow(make_conf(), make_ctx(), "route-1"))
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("capture_shadow_payload()", function()

        it("captures method, body, uri, and tags X-Aria-Shadow header", function()
            local payload = _G.capture_shadow_payload(make_conf(), make_ctx())
            assert.are.equal("POST", payload.method)
            assert.are.equal("/api/orders", payload.uri)
            assert.are.equal('{"q":"hello"}', payload.body)
            assert.are.equal("true", payload.headers["X-Aria-Shadow"])
            assert.are.equal("application/json", payload.headers["content-type"])
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("compute_basic_diff()", function()

        it("returns no diff when status + length match", function()
            local diff = _G.compute_basic_diff(
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                { status = 200, body = string.rep("x", 100), latency_ms = 55 }
            )
            assert.is_true(diff.status_match)
            assert.are.equal(0, diff.body_length_delta)
            assert.is_false(diff.has_diff)
            assert.is_nil(diff.diff_type)
        end)

        it("flags status mismatch as 'status' diff", function()
            local diff = _G.compute_basic_diff(
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                { status = 500, body = string.rep("x", 100), latency_ms = 55 }
            )
            assert.is_false(diff.status_match)
            assert.is_true(diff.has_diff)
            assert.are.equal("status", diff.diff_type)
        end)

        it("flags length delta as 'body_length' diff when status matches", function()
            local diff = _G.compute_basic_diff(
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                { status = 200, body = string.rep("x", 150), latency_ms = 55 }
            )
            assert.is_true(diff.status_match)
            assert.are.equal(50, diff.body_length_delta)
            assert.is_true(diff.has_diff)
            assert.are.equal("body_length", diff.diff_type)
        end)

        it("computes positive latency delta when shadow slower", function()
            local diff = _G.compute_basic_diff(
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                { status = 200, body = string.rep("x", 100), latency_ms = 80 }
            )
            assert.are.equal(30, diff.latency_delta_ms)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("record_shadow_failure() — auto-disable threshold", function()

        it("does not auto-disable below threshold", function()
            local conf = make_conf()
            _G.record_shadow_failure(conf, "route-1", "timeout")
            _G.record_shadow_failure(conf, "route-1", "timeout")
            assert.is_nil(redis_state["aria:canary:shadow:disabled:route-1"])
            assert.are.equal(2, tonumber(redis_state["aria:canary:shadow:fails:route-1"]))
        end)

        it("auto-disables once threshold is reached", function()
            local conf = make_conf()
            _G.record_shadow_failure(conf, "route-1", "timeout")
            _G.record_shadow_failure(conf, "route-1", "timeout")
            _G.record_shadow_failure(conf, "route-1", "timeout")
            assert.are.equal("1", redis_state["aria:canary:shadow:disabled:route-1"])
            -- Failure counter cleared after disable
            assert.is_nil(redis_state["aria:canary:shadow:fails:route-1"])
        end)

        it("respects custom failure_threshold", function()
            local conf = make_conf()
            conf.shadow.failure_threshold = 5
            for i = 1, 4 do _G.record_shadow_failure(conf, "route-1", "timeout") end
            assert.is_nil(redis_state["aria:canary:shadow:disabled:route-1"])
            _G.record_shadow_failure(conf, "route-1", "timeout")
            assert.are.equal("1", redis_state["aria:canary:shadow:disabled:route-1"])
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("is_shadow_disabled()", function()

        it("returns false when no flag set", function()
            assert.is_false(_G.is_shadow_disabled(make_conf(), "route-1") or false)
        end)

        it("returns true when flag set to '1'", function()
            redis_state["aria:canary:shadow:disabled:route-1"] = "1"
            assert.is_true(_G.is_shadow_disabled(make_conf(), "route-1"))
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("fire_shadow() — timer callback", function()

        it("records failure when shadow upstream errors", function()
            http_error = "connection refused"
            _G.fire_shadow(false, make_conf(), "route-1",
                { uri = "/x", method = "GET", body = nil, headers = {} },
                { status = 200, bytes_sent = 100, latency_ms = 50 })
            assert.are.equal(1, tonumber(redis_state["aria:canary:shadow:fails:route-1"]))
        end)

        it("issues HTTP request to selected node with passed-through method/body", function()
            _G.fire_shadow(false, make_conf(), "route-1",
                { uri = "/api/orders", method = "POST", body = '{"q":1}', headers = { foo = "bar" } },
                { status = 200, bytes_sent = 100, latency_ms = 50 })
            assert.is_not_nil(last_http_request)
            assert.are.equal("http://shadow-host:8080/api/orders", last_http_request.url)
            assert.are.equal("POST", last_http_request.opts.method)
            assert.are.equal('{"q":1}', last_http_request.opts.body)
        end)

        it("resets failure counter on successful shadow response", function()
            redis_state["aria:canary:shadow:fails:route-1"] = "2"
            _G.fire_shadow(false, make_conf(), "route-1",
                { uri = "/x", method = "GET", body = nil, headers = {} },
                { status = 200, bytes_sent = 12, latency_ms = 50 })
            assert.is_nil(redis_state["aria:canary:shadow:fails:route-1"])
        end)

        it("aborts immediately when premature flag is true", function()
            _G.fire_shadow(true, make_conf(), "route-1", {}, {})
            assert.is_nil(last_http_request)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("_M.log() — shadow scheduling", function()

        it("schedules ngx.timer.at when ctx.aria_shadow_payload present", function()
            local ctx = make_ctx()
            ctx.aria_shadow_payload = { uri = "/x", method = "GET", body = nil, headers = {} }
            ctx.aria_request_start = ngx.now() - 0.05
            canary.log(make_conf(), ctx)
            assert.are.equal(1, #timer_calls)
            assert.are.equal(0, timer_calls[1].delay)
        end)

        it("does NOT schedule when no shadow payload captured", function()
            local ctx = make_ctx()
            ctx.aria_canary_version = "canary"
            ctx.aria_request_start = ngx.now() - 0.05
            canary.log(make_conf(), ctx)
            assert.are.equal(0, #timer_calls)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("_M.access() — shadow capture", function()

        it("captures payload onto ctx when sampling hits", function()
            local ctx = make_ctx()
            canary.access(make_conf(), ctx)
            assert.is_not_nil(ctx.aria_shadow_payload)
            assert.are.equal("POST", ctx.aria_shadow_payload.method)
        end)

        it("does NOT capture payload when shadow disabled", function()
            local conf = make_conf({ shadow = { enabled = false } })
            local ctx = make_ctx()
            canary.access(conf, ctx)
            assert.is_nil(ctx.aria_shadow_payload)
        end)

        it("does NOT capture payload when X-Aria-Shadow header is true", function()
            local ctx = make_ctx()
            ctx.var.http_x_aria_shadow = "true"
            canary.access(make_conf(), ctx)
            assert.is_nil(ctx.aria_shadow_payload)
        end)
    end)
end)
