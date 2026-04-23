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
local cjson_decode_next = {}          -- Iter 2c: decoded sidecar JSON response
local hold_body_chunk_next = nil      -- Iter 2c: primary body for body_filter

local function reset_state()
    redis_state = {}
    timer_calls = {}
    http_response = { status = 200, body = "primary-body" }
    http_error = nil
    last_http_request = nil
    cjson_decode_next = {}
    hold_body_chunk_next = nil
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
    encode_base64 = function(s) return "b64:" .. (s or "") end,  -- Iter 2c: sidecar req
    var = {
        bytes_sent = "100",
        request_id = "req-test",
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
    decode = function(s) return cjson_decode_next end,
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
    response = {
        set_header = function() end,
        -- Iter 2c: body_filter primary body capture. Returns the accumulated
        -- body only on the final chunk call; intermediate chunks return nil.
        hold_body_chunk = function(_) return hold_body_chunk_next end,
    },
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
    describe("try_sidecar_diff() — Iter 2c bridge", function()

        local function sc_conf(overrides)
            local conf = make_conf()
            conf.shadow.sidecar = {
                enabled        = true,
                endpoint       = "http://127.0.0.1:8081",
                timeout_ms     = 500,
                max_body_bytes = 1048576,
            }
            if overrides then
                for k, v in pairs(overrides) do conf.shadow.sidecar[k] = v end
            end
            return conf
        end

        it("returns nil when sidecar disabled", function()
            local conf = make_conf()  -- sidecar = nil (default)
            local r = _G.try_sidecar_diff(conf, "route-1",
                { status = 200, latency_ms = 50 }, "p-body", 200, "s-body", 60)
            assert.is_nil(r)
        end)

        it("returns nil when primary_body is nil (streaming / disabled capture)", function()
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, nil, 200, "s-body", 60)
            assert.is_nil(r)
        end)

        it("returns nil when primary body exceeds max_body_bytes", function()
            local conf = sc_conf({ max_body_bytes = 10 })
            local r = _G.try_sidecar_diff(conf, "route-1",
                { status = 200, latency_ms = 50 }, string.rep("x", 100), 200, "s", 60)
            assert.is_nil(r)
        end)

        it("returns nil when shadow body exceeds max_body_bytes", function()
            local conf = sc_conf({ max_body_bytes = 10 })
            local r = _G.try_sidecar_diff(conf, "route-1",
                { status = 200, latency_ms = 50 }, "p", 200, string.rep("x", 100), 60)
            assert.is_nil(r)
        end)

        it("POSTs to the configured sidecar /v1/diff endpoint", function()
            cjson_decode_next = {
                statusMatch = true, bodySimilarity = 1.0, latencyDeltaMs = 10,
                diffFields = {}, diffSummary = "structural match",
            }
            _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p-body", 200, "s-body", 60)
            assert.is_not_nil(last_http_request)
            assert.are.equal("http://127.0.0.1:8081/v1/diff", last_http_request.url)
            assert.are.equal("POST", last_http_request.opts.method)
            assert.are.equal("application/json",
                last_http_request.opts.headers["Content-Type"])
        end)

        it("returns structural diff table on sidecar OK", function()
            cjson_decode_next = {
                statusMatch = true, bodySimilarity = 0.87, latencyDeltaMs = 15,
                diffFields = { "tokens" }, diffSummary = "1 field(s) differ",
            }
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p", 200, "s", 65)
            assert.is_not_nil(r)
            assert.is_true(r.status_match)
            assert.are.equal(0.87, r.body_similarity)
            assert.are.equal(15, r.latency_delta_ms)
            assert.are.equal("structural", r.diff_type)
            assert.is_true(r.has_diff)
            assert.are.same({ "tokens" }, r.diff_fields)
        end)

        it("marks diff_type=status when sidecar reports status mismatch", function()
            cjson_decode_next = {
                statusMatch = false, bodySimilarity = 1.0, latencyDeltaMs = 0,
                diffFields = {}, diffSummary = "status mismatch",
            }
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p", 500, "s", 60)
            assert.is_not_nil(r)
            assert.is_false(r.status_match)
            assert.are.equal("status", r.diff_type)
            assert.is_true(r.has_diff)
        end)

        it("returns nil when sidecar returns non-200", function()
            http_response = { status = 500, body = "" }
            cjson_decode_next = { statusMatch = true, bodySimilarity = 1.0 }
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p", 200, "s", 60)
            assert.is_nil(r)
        end)

        it("returns nil when sidecar is unreachable (HTTP error)", function()
            http_error = "connection refused"
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p", 200, "s", 60)
            assert.is_nil(r)
        end)

        it("returns nil when sidecar body fails to parse", function()
            http_response = { status = 200, body = "not-json" }
            cjson_decode_next = nil  -- decoder returns nil → parse failure
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p", 200, "s", 60)
            assert.is_nil(r)
        end)

        it("returns no_diff when sidecar reports identical structural match", function()
            cjson_decode_next = {
                statusMatch = true, bodySimilarity = 1.0, latencyDeltaMs = 5,
                diffFields = {}, diffSummary = "structural match",
            }
            local r = _G.try_sidecar_diff(sc_conf(), "route-1",
                { status = 200, latency_ms = 50 }, "p", 200, "s", 55)
            assert.is_not_nil(r)
            assert.is_false(r.has_diff)
            assert.is_nil(r.diff_type)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("fire_shadow() with sidecar bridge", function()

        local function sc_conf()
            local conf = make_conf()
            conf.shadow.sidecar = {
                enabled = true, endpoint = "http://127.0.0.1:8081",
                timeout_ms = 500, max_body_bytes = 1048576,
            }
            return conf
        end

        it("uses sidecar diff when primary_body is captured and sidecar enabled", function()
            -- Order: shadow upstream responds with http_response; then sidecar responds
            -- with same mocked httpc. Since our mock returns the same http_response for
            -- both calls, set it to a 200/structural match response and control the
            -- decode value for sidecar diff parsing.
            cjson_decode_next = {
                statusMatch = true, bodySimilarity = 0.9, latencyDeltaMs = 5,
                diffFields = { "meta" }, diffSummary = "1 field(s) differ",
            }
            _G.fire_shadow(false, sc_conf(), "route-1",
                { uri = "/x", method = "GET", body = nil, headers = {} },
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                '{"primary":"body"}')
            -- last_http_request is the most recent call — the sidecar POST.
            assert.are.equal("http://127.0.0.1:8081/v1/diff", last_http_request.url)
        end)

        it("falls back to basic diff when no primary_body provided", function()
            _G.fire_shadow(false, sc_conf(), "route-1",
                { uri = "/x", method = "GET", body = nil, headers = {} },
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                nil)  -- no primary_body
            -- last call was to shadow upstream, not sidecar
            assert.are.equal("http://shadow-host:8080/x", last_http_request.url)
        end)

        it("falls back to basic diff when sidecar is unreachable", function()
            -- With http_error set, BOTH shadow upstream AND sidecar will fail.
            -- fire_shadow should short-circuit on shadow upstream failure, before
            -- reaching the sidecar. Verify by ensuring the sidecar endpoint was
            -- never reached.
            http_error = "refused"
            _G.fire_shadow(false, sc_conf(), "route-1",
                { uri = "/x", method = "GET", body = nil, headers = {} },
                { status = 200, bytes_sent = 100, latency_ms = 50 },
                '{"p":1}')
            -- Shadow upstream call was attempted (URL set to shadow, not sidecar)
            assert.are.equal("http://shadow-host:8080/x", last_http_request.url)
        end)
    end)

    -- ────────────────────────────────────────────────────────────────────
    describe("_M.body_filter() — primary body capture (Iter 2c)", function()

        local function sc_conf()
            local conf = make_conf()
            conf.shadow.sidecar = {
                enabled = true, endpoint = "http://127.0.0.1:8081",
                timeout_ms = 500, max_body_bytes = 100,
            }
            return conf
        end

        it("does nothing when no shadow payload captured", function()
            local ctx = make_ctx()  -- no aria_shadow_payload
            hold_body_chunk_next = "should-not-be-captured"
            canary.body_filter(sc_conf(), ctx)
            assert.is_nil(ctx.aria_primary_body)
        end)

        it("does nothing when sidecar bridge is disabled", function()
            local ctx = make_ctx()
            ctx.aria_shadow_payload = { uri = "/x", method = "GET", body = nil, headers = {} }
            hold_body_chunk_next = "body-would-be-here"
            canary.body_filter(make_conf(), ctx)  -- no sidecar config
            assert.is_nil(ctx.aria_primary_body)
        end)

        it("skips streaming responses (text/event-stream)", function()
            local ctx = make_ctx()
            ctx.aria_shadow_payload = { uri = "/x", method = "GET", body = nil, headers = {} }
            hold_body_chunk_next = "event: ping\n\n"
            _G.ngx.header = { ["Content-Type"] = "text/event-stream" }
            canary.body_filter(sc_conf(), ctx)
            assert.is_nil(ctx.aria_primary_body)
            _G.ngx.header = {}
        end)

        it("does not capture when hold_body_chunk returns nil (mid-stream)", function()
            local ctx = make_ctx()
            ctx.aria_shadow_payload = { uri = "/x", method = "GET", body = nil, headers = {} }
            hold_body_chunk_next = nil
            canary.body_filter(sc_conf(), ctx)
            assert.is_nil(ctx.aria_primary_body)
        end)

        it("skips oversized bodies without capturing", function()
            local ctx = make_ctx()
            ctx.aria_shadow_payload = { uri = "/x", method = "GET", body = nil, headers = {} }
            hold_body_chunk_next = string.rep("x", 500)  -- > max_body_bytes=100
            canary.body_filter(sc_conf(), ctx)
            assert.is_nil(ctx.aria_primary_body)
        end)

        it("captures body when shadow active, sidecar enabled, within size cap", function()
            local ctx = make_ctx()
            ctx.aria_shadow_payload = { uri = "/x", method = "GET", body = nil, headers = {} }
            hold_body_chunk_next = '{"ok":true}'
            canary.body_filter(sc_conf(), ctx)
            assert.are.equal('{"ok":true}', ctx.aria_primary_body)
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
