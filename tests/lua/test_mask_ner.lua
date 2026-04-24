--
-- test_mask_ner.lua — Unit tests for the NER sidecar bridge inside aria-mask.lua
--
-- Scope:
--   - collect_ner_candidates: JSON tree walk + already-masked suppression
--   - assign_entities_to_parts: offset-based entity → field mapping
--   - try_sidecar_ner: HTTP bridge happy path + every failure mode
--   - circuit breaker interaction with the bridge
--
-- Framework: busted
-- Run: busted tests/lua/test_mask_ner.lua
--

-- ────────────────────────────────────────────────────────────────────────────
-- Mocks with tunable state (mutated per test)
-- ────────────────────────────────────────────────────────────────────────────

local mock_now_seconds = 1000
local http_response   = { status = 200, body = '{"entities":[]}' }
local http_error      = nil
local last_http_body  = nil

local function reset_state()
    mock_now_seconds = 1000
    http_response    = { status = 200, body = '{"entities":[]}' }
    http_error       = nil
    last_http_body   = nil
end


-- Fake shared_dict (shared with circuit breaker)
local function new_fake_dict()
    local store = {}
    return {
        get  = function(_, k) return store[k] end,
        set  = function(_, k, v) store[k] = v end,
        incr = function(_, k, delta, init)
            local cur = store[k] or init or 0
            cur = cur + delta
            store[k] = cur
            return cur
        end,
    }
end


_G.ngx = {
    now  = function() return mock_now_seconds end,
    time = function() return mock_now_seconds end,
    utctime = function() return "2026-04-23 12:00:00" end,
    log  = function() end,
    ERR = 1, WARN = 2, INFO = 3, DEBUG = 4,
    shared = { ["prometheus-metrics"] = new_fake_dict() },
    var = { request_id = "req-test", route_id = "route-test" },
    null = "\0",
    header = {},
    arg = { [1] = "", [2] = false },
    re = { gmatch = function() return function() return nil end end },
    encode_base64 = function(s) return "b64:" .. (s or "") end,
    sha1_bin = function() return "\0\0\0\0\0" end,
    encode_base16 = function(s) return s end,
    crc32_long = function() return 42 end,
}

package.loaded["cjson.safe"] = {
    encode = function(t)
        last_http_body = t
        -- Minimal encode: only fields we check in tests
        if type(t) == "table" and t.content then
            return '{"content":"' .. t.content .. '"}'
        end
        return "{}"
    end,
    decode = function(s)
        -- Return a canned parsed response based on http_response.body
        if http_response.body == '{"entities":[]}' then
            return { entities = {} }
        elseif http_response.body == "malformed" then
            return nil
        elseif http_response.body == "not-an-entities-map" then
            return { something = "else" }
        else
            return http_response._parsed
        end
    end,
    null = "\0",
    empty_table = {},
}

package.loaded["apisix.core"] = {
    log = {
        error = function() end, warn = function() end,
        info  = function() end, debug = function() end,
    },
    schema = { check = function() return true end },
    response = {
        hold_body_chunk = function() return "" end,
        set_header      = function() end,
    },
}

package.loaded["resty.redis"] = { new = function() return {} end }

-- aria-core's metrics init loads apisix's prometheus exporter at runtime,
-- which we don't need in unit tests. Preload an empty stub.
package.loaded["apisix.plugins.prometheus.exporter"] = {}

package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout  = function() end,
            request_uri  = function(_, _, opts)
                last_http_body = opts.body
                if http_error then
                    return nil, http_error
                end
                return http_response
            end,
        }
    end,
}

-- Load module under test.
package.path = package.path .. ";./apisix/plugins/?.lua;./apisix/plugins/lib/?.lua"
local mask = require("aria-mask")
local helpers = mask._internal


-- ────────────────────────────────────────────────────────────────────────────
-- Tests
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-mask NER bridge", function()

    before_each(reset_state)

    describe("collect_ner_candidates", function()

        it("picks up every non-empty string leaf not already masked", function()
            local body = {
                user = { name = "Ali Veli", bio = "Istanbul resident" },
                id   = "42",
                notes = { "Ahmet called" },
            }
            local parts = helpers.collect_ner_candidates(body, {})
            -- Expected: user.name, user.bio, notes[1]. id too short (len<3 is 2).
            -- Actually "42" has length 2 so it's skipped.
            local paths = {}
            for _, p in ipairs(parts) do paths[#paths + 1] = p.path end
            table.sort(paths)
            assert.are.same({ "$.notes.1", "$.user.bio", "$.user.name" }, paths)
        end)

        it("skips fields already flagged by regex", function()
            local body = { msg = "secret text", secret = "hideme" }
            local already = { ["$.secret"] = true }
            local parts = helpers.collect_ner_candidates(body, already)
            assert.are.equal(1, #parts)
            assert.are.equal("$.msg", parts[1].path)
        end)

        it("skips values shorter than 3 chars", function()
            local body = { a = "hi", b = "hey" }
            local parts = helpers.collect_ner_candidates(body, {})
            assert.are.equal(1, #parts)
            assert.are.equal("hey", parts[1].value)
        end)

        it("recurses into nested tables", function()
            local body = { deep = { deeper = { value = "find me here" } } }
            local parts = helpers.collect_ner_candidates(body, {})
            assert.are.equal(1, #parts)
            assert.are.equal("$.deep.deeper.value", parts[1].path)
        end)

        it("returns empty when no candidates", function()
            local parts = helpers.collect_ner_candidates({}, {})
            assert.are.equal(0, #parts)
        end)
    end)


    describe("assign_entities_to_parts", function()

        it("maps entity offsets to the correct part", function()
            -- Parts: "Ali Veli" (8 chars) + \1 + "Ankara" (6 chars)
            -- Offsets: [0..8) first part, [9..15) second part
            local parts = {
                { path = "$.a", value = "Ali Veli" },
                { path = "$.b", value = "Ankara" },
            }
            local entities = {
                { start = 0, ["end"] = 8, entityType = "PERSON",   confidence = 0.9 },
                { start = 9, ["end"] = 15, entityType = "LOCATION", confidence = 0.85 },
            }
            local assigns = helpers.assign_entities_to_parts(entities, parts, 0.0)
            assert.are.equal(2, #assigns)
            assert.are.equal(1, assigns[1].part_index)
            assert.are.equal("PERSON", assigns[1].entity_type)
            assert.are.equal(2, assigns[2].part_index)
            assert.are.equal("LOCATION", assigns[2].entity_type)
        end)

        it("drops entities straddling the delimiter", function()
            local parts = {
                { path = "$.a", value = "hello" },
                { path = "$.b", value = "world" },
            }
            -- entity spans [3..9) which crosses the delimiter at offset 5
            local entities = {
                { start = 3, ["end"] = 9, entityType = "PERSON", confidence = 0.9 },
            }
            local assigns = helpers.assign_entities_to_parts(entities, parts, 0.0)
            assert.are.equal(0, #assigns)
        end)

        it("filters entities below min_confidence", function()
            local parts = { { path = "$.a", value = "Ali Veli" } }
            local entities = {
                { start = 0, ["end"] = 8, entityType = "PERSON", confidence = 0.5 },
            }
            assert.are.equal(0,
                #helpers.assign_entities_to_parts(entities, parts, 0.7))
            assert.are.equal(1,
                #helpers.assign_entities_to_parts(entities, parts, 0.4))
        end)

        it("ignores malformed entity entries", function()
            local parts = { { path = "$.a", value = "hello" } }
            local entities = {
                { start = nil, ["end"] = 5 },
                { start = 5,   ["end"] = 3 },  -- end before start
                { start = 0,   ["end"] = 5, confidence = 0.9, entityType = "PERSON" },
            }
            local assigns = helpers.assign_entities_to_parts(entities, parts, 0.0)
            assert.are.equal(1, #assigns)
        end)
    end)


    describe("try_sidecar_ner", function()

        local base_conf = {
            enabled         = true,
            endpoint        = "http://127.0.0.1:8081",
            timeout_ms      = 500,
            max_content_bytes = 131072,
        }

        it("returns nil when disabled", function()
            local conf = { enabled = false }
            local entities, err = helpers.try_sidecar_ner(conf, "r", "abc", nil)
            assert.is_nil(entities)
            assert.are.equal("disabled", err)
        end)

        it("returns empty-reason for empty content", function()
            local entities, err = helpers.try_sidecar_ner(base_conf, "r", "", nil)
            assert.is_nil(entities)
            assert.are.equal("empty", err)
        end)

        it("skips oversized payloads", function()
            local conf = { enabled = true, max_content_bytes = 10 }
            local entities, err = helpers.try_sidecar_ner(
                conf, "r", string.rep("x", 100), nil)
            assert.is_nil(entities)
            assert.are.equal("oversized", err)
        end)

        it("returns entities on 200 OK", function()
            http_response = { status = 200, body = "ok",
                _parsed = { entities = {
                    { start = 0, ["end"] = 5, entityType = "PERSON", confidence = 0.9 },
                }}}
            local entities = helpers.try_sidecar_ner(base_conf, "r", "Ali V", nil)
            assert.is_not_nil(entities)
            assert.are.equal(1, #entities)
        end)

        it("returns error on non-200 status", function()
            http_response = { status = 500, body = "err" }
            local entities, err = helpers.try_sidecar_ner(base_conf, "r", "content", nil)
            assert.is_nil(entities)
            assert.are.equal("error", err)
        end)

        it("returns error on transport failure", function()
            http_error = "connection refused"
            local entities, err = helpers.try_sidecar_ner(base_conf, "r", "content", nil)
            assert.is_nil(entities)
            assert.are.equal("error", err)
        end)

        it("returns parse_error on unparseable body", function()
            http_response = { status = 200, body = "malformed" }
            local entities, err = helpers.try_sidecar_ner(base_conf, "r", "content", nil)
            assert.is_nil(entities)
            assert.are.equal("parse_error", err)
        end)

        it("returns parse_error when entities field missing", function()
            http_response = { status = 200, body = "not-an-entities-map" }
            local entities, err = helpers.try_sidecar_ner(base_conf, "r", "content", nil)
            assert.is_nil(entities)
            assert.are.equal("parse_error", err)
        end)
    end)


    describe("circuit breaker interaction", function()

        local cb_mod
        setup(function()
            package.path = package.path .. ";./apisix/plugins/lib/?.lua"
            cb_mod = require("aria-circuit-breaker")
        end)

        it("short-circuits when breaker is open", function()
            local dict = new_fake_dict()
            local cb = cb_mod.new(dict, "ner-x", { failure_threshold = 1 })
            cb:record_failure()  -- open
            assert.are.equal("open", cb:state())

            local base_conf = { enabled = true, endpoint = "http://x", timeout_ms = 500 }
            local entities, err = helpers.try_sidecar_ner(base_conf, "r", "hi", cb)
            assert.is_nil(entities)
            assert.are.equal("circuit_open", err)
        end)

        it("records success on 200 OK", function()
            local dict = new_fake_dict()
            local cb = cb_mod.new(dict, "ner-y", { failure_threshold = 1 })
            cb:record_failure()  -- open
            -- Flip to half_open via time
            mock_now_seconds = mock_now_seconds + 31
            assert.are.equal("half_open", cb:state())

            http_response = { status = 200, body = "ok",
                _parsed = { entities = {} } }
            local base_conf = { enabled = true, endpoint = "http://x", timeout_ms = 500 }
            helpers.try_sidecar_ner(base_conf, "r", "hi", cb)
            assert.are.equal("closed", cb:state())
        end)

        it("records failure on HTTP error", function()
            local dict = new_fake_dict()
            local cb = cb_mod.new(dict, "ner-z", { failure_threshold = 2 })

            http_error = "timeout"
            local base_conf = { enabled = true, endpoint = "http://x", timeout_ms = 500 }
            helpers.try_sidecar_ner(base_conf, "r", "hi", cb)
            helpers.try_sidecar_ner(base_conf, "r", "hi", cb)
            assert.are.equal("open", cb:state())
        end)
    end)
end)
