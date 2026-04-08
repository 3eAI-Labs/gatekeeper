--
-- test_quota.lua — Unit tests for aria-quota.lua and parse_duration from aria-core.lua
--
-- Framework: busted
-- Run: busted tests/lua/test_quota.lua
--

-- ────────────────────────────────────────────────────────────────────────────
-- Mocks
-- ────────────────────────────────────────────────────────────────────────────

_G.ngx = {
    re = { gmatch = function() return function() return nil end end },
    null = "\0",
    now = function() return 1712592600 end,
    time = function() return 1712592600 end,
    utctime = function() return "2026-04-08 14:30:00" end,
    sha1_bin = function(s) return string.rep("\0", 20) end,
    encode_base16 = function(s) return string.rep("0", #s * 2) end,
    log = function() end,
    ERR = 1, WARN = 2, INFO = 3, DEBUG = 4,
    shared = {},
    header = {},
    timer = { at = function() end },
}

package.loaded["cjson.safe"] = {
    encode = function(t)
        -- Minimal JSON encode for test assertions
        if type(t) == "table" then return "{}" end
        return tostring(t)
    end,
    decode = function(s)
        if not s or s == "" then return nil end
        return {}
    end,
    null = "\0",
    empty_table = {},
}

-- Mock apisix.core
package.loaded["apisix.core"] = {
    log = {
        error = function() end,
        warn = function() end,
        info = function() end,
        debug = function() end,
    },
    response = {
        set_header = function() end,
    },
}

-- Mock resty.redis
package.loaded["resty.redis"] = {
    new = function()
        return {
            set_timeouts = function() end,
            connect = function() return true end,
            auth = function() return true end,
            select = function() return true end,
            set_keepalive = function() return true end,
            get = function() return ngx.null end,
            incrby = function() return true end,
            incrbyfloat = function() return true end,
            expire = function() return true end,
            setnx = function() return 1 end,
            llen = function() return 0 end,
            rpush = function() return true end,
            lpop = function() return true end,
        }
    end,
}

-- Mock resty.random
package.loaded["resty.random"] = {
    bytes = function(n) return string.rep("\0", n) end,
}

-- Mock resty.string
package.loaded["resty.string"] = {
    to_hex = function(s) return string.rep("0", #s * 2) end,
}

-- Mock prometheus exporter
package.loaded["apisix.plugins.prometheus.exporter"] = {}


-- ────────────────────────────────────────────────────────────────────────────
-- Load modules under test
-- ────────────────────────────────────────────────────────────────────────────

package.path = package.path .. ";./apisix/plugins/lib/?.lua"

local aria_core = require("aria-core")
local quota = require("aria-quota")


-- ────────────────────────────────────────────────────────────────────────────
-- Tests: calculate_cost()
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-quota", function()

    describe("calculate_cost()", function()

        it("should calculate cost for gpt-4o", function()
            -- gpt-4o: input_per_1k = 0.0025, output_per_1k = 0.01
            -- 1000 input tokens = 0.0025, 500 output tokens = 0.005
            local cost = quota.calculate_cost("gpt-4o", 1000, 500)
            assert.are.equal(0.0075, cost)
        end)

        it("should calculate cost for gpt-4o-mini", function()
            -- gpt-4o-mini: input_per_1k = 0.00015, output_per_1k = 0.0006
            -- 2000 input = 0.0003, 1000 output = 0.0006
            local cost = quota.calculate_cost("gpt-4o-mini", 2000, 1000)
            assert.are.equal(0.0009, cost)
        end)

        it("should calculate cost for claude-sonnet-4-6", function()
            -- claude-sonnet-4-6: input_per_1k = 0.003, output_per_1k = 0.015
            -- 1000 input = 0.003, 1000 output = 0.015
            local cost = quota.calculate_cost("claude-sonnet-4-6", 1000, 1000)
            assert.are.equal(0.018, cost)
        end)

        it("should calculate cost for claude-opus-4-6", function()
            -- claude-opus-4-6: input_per_1k = 0.015, output_per_1k = 0.075
            -- 1000 input = 0.015, 1000 output = 0.075
            local cost = quota.calculate_cost("claude-opus-4-6", 1000, 1000)
            assert.are.equal(0.09, cost)
        end)

        it("should use _default pricing for unknown model", function()
            -- _default: input_per_1k = 0.01, output_per_1k = 0.03
            -- 1000 input = 0.01, 1000 output = 0.03
            local cost = quota.calculate_cost("unknown-model-xyz", 1000, 1000)
            assert.are.equal(0.04, cost)
        end)

        it("should return 0 for zero tokens", function()
            local cost = quota.calculate_cost("gpt-4o", 0, 0)
            assert.are.equal(0, cost)
        end)

        it("should handle large token counts", function()
            -- gpt-4o: input_per_1k = 0.0025, output_per_1k = 0.01
            -- 1M input = 2.5, 500K output = 5.0
            local cost = quota.calculate_cost("gpt-4o", 1000000, 500000)
            assert.are.equal(7.5, cost)
        end)

        it("should handle only input tokens", function()
            -- gpt-4o: 500 input = 500/1000 * 0.0025 = 0.00125
            local cost = quota.calculate_cost("gpt-4o", 500, 0)
            assert.are.equal(0.00125, cost)
        end)

        it("should handle only output tokens", function()
            -- gpt-4o: 500 output = 500/1000 * 0.01 = 0.005
            local cost = quota.calculate_cost("gpt-4o", 0, 500)
            assert.are.equal(0.005, cost)
        end)

        it("should accept custom pricing table", function()
            local custom = {
                ["my-model"] = { input_per_1k = 0.1, output_per_1k = 0.2 },
                _default = { input_per_1k = 0.05, output_per_1k = 0.1 },
            }
            local cost = quota.calculate_cost("my-model", 1000, 1000, custom)
            assert.are.equal(0.3, cost)
        end)

        it("should use custom _default for unknown model in custom table", function()
            local custom = {
                _default = { input_per_1k = 0.05, output_per_1k = 0.1 },
            }
            local cost = quota.calculate_cost("nonexistent", 1000, 1000, custom)
            assert.are.equal(0.15, cost)
        end)

        it("should round to 6 decimal places", function()
            -- gemini-2.0-flash: input_per_1k = 0.0001, output_per_1k = 0.0004
            -- 1 input token = 0.0001/1000 = 0.0000001
            -- 1 output token = 0.0004/1000 = 0.0000004
            -- total = 0.0000005 -> rounds to 0.000001
            local cost = quota.calculate_cost("gemini-2.0-flash", 1, 1)
            assert.are.equal(0.000001, cost)
        end)

        it("should calculate cost for gemini-2.5-pro", function()
            -- gemini-2.5-pro: input_per_1k = 0.00125, output_per_1k = 0.01
            -- 1000 input = 0.00125, 1000 output = 0.01
            local cost = quota.calculate_cost("gemini-2.5-pro", 1000, 1000)
            assert.are.equal(0.01125, cost)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: get_pricing_table()
    -- ────────────────────────────────────────────────────────────────────────

    describe("get_pricing_table()", function()

        it("should return default pricing when no custom pricing", function()
            local table = quota.get_pricing_table(nil)
            assert.is_not_nil(table["gpt-4o"])
            assert.is_not_nil(table["claude-sonnet-4-6"])
            assert.is_not_nil(table._default)
        end)

        it("should merge custom pricing over defaults", function()
            local custom = {
                ["my-custom-model"] = { input_per_1k = 0.05, output_per_1k = 0.1 },
            }
            local merged = quota.get_pricing_table(custom)
            -- Custom model should be present
            assert.is_not_nil(merged["my-custom-model"])
            assert.are.equal(0.05, merged["my-custom-model"].input_per_1k)
            -- Default models should still be present
            assert.is_not_nil(merged["gpt-4o"])
        end)

        it("should override default model pricing with custom", function()
            local custom = {
                ["gpt-4o"] = { input_per_1k = 0.999, output_per_1k = 0.999 },
            }
            local merged = quota.get_pricing_table(custom)
            assert.are.equal(0.999, merged["gpt-4o"].input_per_1k)
            assert.are.equal(0.999, merged["gpt-4o"].output_per_1k)
        end)

        it("should preserve _default in merged table", function()
            local custom = {
                ["new-model"] = { input_per_1k = 0.01, output_per_1k = 0.02 },
            }
            local merged = quota.get_pricing_table(custom)
            assert.is_not_nil(merged._default)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: get_reset_time()
    -- ────────────────────────────────────────────────────────────────────────

    describe("get_reset_time()", function()

        it("should return next day for daily period", function()
            local result = quota.get_reset_time("daily")
            -- Should be a valid ISO 8601 date at 00:00:00Z
            assert.truthy(result:match("^%d%d%d%d%-%d%d%-%d%dT00:00:00Z$"))
        end)

        it("should return first of next month for monthly period", function()
            local result = quota.get_reset_time("monthly")
            -- Should end with -01T00:00:00Z
            assert.truthy(result:match("T00:00:00Z$"))
            assert.truthy(result:match("%-%d%d%-01T"))
        end)

        it("should handle December monthly reset (rolls to next year)", function()
            -- Override os.date temporarily to simulate December
            local original_date = os.date
            os.date = function(fmt, time)
                if fmt == "!*t" then
                    return { year = 2026, month = 12, day = 15 }
                end
                return original_date(fmt, time)
            end

            local result = quota.get_reset_time("monthly")
            assert.are.equal("2027-01-01T00:00:00Z", result)

            os.date = original_date
        end)

        it("should handle non-December monthly reset", function()
            local original_date = os.date
            os.date = function(fmt, time)
                if fmt == "!*t" then
                    return { year = 2026, month = 4, day = 8 }
                end
                return original_date(fmt, time)
            end

            local result = quota.get_reset_time("monthly")
            assert.are.equal("2026-05-01T00:00:00Z", result)

            os.date = original_date
        end)

        it("should handle January monthly reset", function()
            local original_date = os.date
            os.date = function(fmt, time)
                if fmt == "!*t" then
                    return { year = 2026, month = 1, day = 31 }
                end
                return original_date(fmt, time)
            end

            local result = quota.get_reset_time("monthly")
            assert.are.equal("2026-02-01T00:00:00Z", result)

            os.date = original_date
        end)
    end)
end)


-- ────────────────────────────────────────────────────────────────────────────
-- Tests: parse_duration() from aria-core
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-core", function()

    describe("parse_duration()", function()

        it("should parse seconds '30s' to 30", function()
            assert.are.equal(30, aria_core.parse_duration("30s"))
        end)

        it("should parse minutes '5m' to 300", function()
            assert.are.equal(300, aria_core.parse_duration("5m"))
        end)

        it("should parse hours '1h' to 3600", function()
            assert.are.equal(3600, aria_core.parse_duration("1h"))
        end)

        it("should parse hours '2h' to 7200", function()
            assert.are.equal(7200, aria_core.parse_duration("2h"))
        end)

        it("should parse days '1d' to 86400", function()
            assert.are.equal(86400, aria_core.parse_duration("1d"))
        end)

        it("should parse plain number string as seconds", function()
            assert.are.equal(120, aria_core.parse_duration("120"))
        end)

        it("should return 0 for nil input", function()
            assert.are.equal(0, aria_core.parse_duration(nil))
        end)

        it("should return 0 for non-numeric string", function()
            assert.are.equal(0, aria_core.parse_duration("abc"))
        end)

        it("should parse '10m' to 600", function()
            assert.are.equal(600, aria_core.parse_duration("10m"))
        end)

        it("should parse '0s' to 0", function()
            assert.are.equal(0, aria_core.parse_duration("0s"))
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: approximate_tokens()
    -- ────────────────────────────────────────────────────────────────────────

    describe("approximate_tokens()", function()

        it("should return 0 for nil", function()
            assert.are.equal(0, aria_core.approximate_tokens(nil))
        end)

        it("should return 0 for empty string", function()
            assert.are.equal(0, aria_core.approximate_tokens(""))
        end)

        it("should approximate tokens from word count * 1.3", function()
            -- "hello world" = 2 words, ceil(2 * 1.3) = ceil(2.6) = 3
            assert.are.equal(3, aria_core.approximate_tokens("hello world"))
        end)

        it("should handle single word", function()
            -- 1 word, ceil(1 * 1.3) = ceil(1.3) = 2
            assert.are.equal(2, aria_core.approximate_tokens("hello"))
        end)

        it("should handle multiple spaces between words", function()
            -- "a   b   c" = 3 words, ceil(3 * 1.3) = ceil(3.9) = 4
            assert.are.equal(4, aria_core.approximate_tokens("a   b   c"))
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: labels_to_string()
    -- ────────────────────────────────────────────────────────────────────────

    describe("labels_to_string()", function()

        it("should return empty string for nil labels", function()
            assert.are.equal("", aria_core.labels_to_string(nil))
        end)

        it("should format single label", function()
            local result = aria_core.labels_to_string({ consumer = "team-a" })
            assert.are.equal('consumer="team-a"', result)
        end)

        it("should sort multiple labels alphabetically", function()
            local result = aria_core.labels_to_string({
                model = "gpt-4o",
                consumer = "team-a",
            })
            assert.are.equal('consumer="team-a",model="gpt-4o"', result)
        end)

        it("should handle empty labels table", function()
            assert.are.equal("", aria_core.labels_to_string({}))
        end)
    end)
end)
