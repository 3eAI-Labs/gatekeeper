--
-- test_circuit_breaker.lua — Unit tests for aria-circuit-breaker.lua
--
-- Framework: busted
-- Run: busted tests/lua/test_circuit_breaker.lua
--

-- ────────────────────────────────────────────────────────────────────────────
-- Mock ngx with a controllable clock — tests override ngx.now() to drive the
-- cooldown transition without real sleep.
-- ────────────────────────────────────────────────────────────────────────────

local mock_now_seconds = 1000

_G.ngx = {
    now = function() return mock_now_seconds end,
    log = function() end,
    ERR = 1, WARN = 2, INFO = 3, DEBUG = 4,
    shared = {},
}

-- ────────────────────────────────────────────────────────────────────────────
-- Fake shared_dict — dictionary API sufficient for the breaker's needs.
-- ────────────────────────────────────────────────────────────────────────────

local function new_fake_dict()
    local store = {}
    return {
        get  = function(_, k) return store[k] end,
        set  = function(_, k, v) store[k] = v end,
        incr = function(_, k, delta, init)
            local current = store[k]
            if current == nil then
                current = init or 0
            end
            current = current + delta
            store[k] = current
            return current
        end,
        -- Test-only: inspect the raw backing table
        _raw = store,
    }
end


package.path = package.path .. ";./apisix/plugins/lib/?.lua"
local cb_mod = require("aria-circuit-breaker")


describe("aria-circuit-breaker", function()

    before_each(function()
        mock_now_seconds = 1000
    end)

    describe("construction", function()

        it("requires a dict", function()
            local cb, err = cb_mod.new(nil, "x")
            assert.is_nil(cb)
            assert.is_truthy(err)
        end)

        it("requires a non-empty name", function()
            local cb, err = cb_mod.new(new_fake_dict(), "")
            assert.is_nil(cb)
            assert.is_truthy(err)
        end)

        it("creates a breaker with default config", function()
            local cb = cb_mod.new(new_fake_dict(), "ner")
            assert.is_not_nil(cb)
            assert.are.equal("closed", cb:state())
            assert.is_true(cb:allow())
        end)
    end)

    describe("closed → open transition", function()

        it("opens after N consecutive failures", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 3, cooldown_ms = 30000 })

            assert.is_true(cb:allow())
            cb:record_failure()
            cb:record_failure()
            assert.are.equal("closed", cb:state())
            assert.is_true(cb:allow())

            cb:record_failure()  -- this one trips
            assert.are.equal("open", cb:state())
            assert.is_false(cb:allow())
        end)

        it("single success resets the failure streak", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 3 })
            cb:record_failure()
            cb:record_failure()
            cb:record_success()
            cb:record_failure()
            cb:record_failure()
            assert.are.equal("closed", cb:state())  -- streak broken after 2 + 2, not 4
        end)
    end)

    describe("open → half_open transition", function()

        it("stays open before cooldown elapses", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 1, cooldown_ms = 30000 })
            cb:record_failure()  -- opens immediately
            assert.are.equal("open", cb:state())

            mock_now_seconds = mock_now_seconds + 10  -- 10s later
            assert.are.equal("open", cb:state())
            assert.is_false(cb:allow())
        end)

        it("flips to half_open after cooldown", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 1, cooldown_ms = 30000 })
            cb:record_failure()
            mock_now_seconds = mock_now_seconds + 31  -- 31s later, past 30s cooldown
            assert.are.equal("half_open", cb:state())
            assert.is_true(cb:allow())
        end)
    end)

    describe("half_open outcomes", function()

        local function drive_to_half_open(cb, cooldown_ms)
            cb:record_failure()
            mock_now_seconds = mock_now_seconds + (cooldown_ms / 1000) + 1
            assert.are.equal("half_open", cb:state())
        end

        it("success closes the breaker and clears failures", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 1, cooldown_ms = 30000 })
            drive_to_half_open(cb, 30000)
            cb:record_success()
            assert.are.equal("closed", cb:state())
            assert.are.equal(0, cb:failure_count())
        end)

        it("failure reopens the breaker with fresh cooldown", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 1, cooldown_ms = 30000 })
            drive_to_half_open(cb, 30000)
            cb:record_failure()
            assert.are.equal("open", cb:state())
            assert.is_false(cb:allow())
        end)
    end)

    describe("reset()", function()

        it("forces the breaker back to closed regardless of state", function()
            local cb = cb_mod.new(new_fake_dict(), "ner",
                { failure_threshold = 1 })
            cb:record_failure()
            assert.are.equal("open", cb:state())

            cb:reset()
            assert.are.equal("closed", cb:state())
            assert.is_true(cb:allow())
            assert.are.equal(0, cb:failure_count())
        end)
    end)

    describe("isolation between breakers", function()

        it("two breakers on the same dict do not share state", function()
            local dict = new_fake_dict()
            local a = cb_mod.new(dict, "ner-a", { failure_threshold = 2 })
            local b = cb_mod.new(dict, "ner-b", { failure_threshold = 2 })

            a:record_failure()
            a:record_failure()
            assert.are.equal("open", a:state())
            assert.are.equal("closed", b:state())
        end)
    end)

    describe("state constants are exposed", function()

        it("provides numeric state codes for gauge export", function()
            assert.are.equal(0, cb_mod.STATE_CLOSED)
            assert.are.equal(1, cb_mod.STATE_OPEN)
            assert.are.equal(2, cb_mod.STATE_HALF_OPEN)
        end)
    end)
end)
