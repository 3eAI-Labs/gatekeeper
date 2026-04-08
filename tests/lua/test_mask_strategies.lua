--
-- test_mask_strategies.lua — Unit tests for aria-mask-strategies.lua
--
-- Framework: busted
-- Run: busted tests/lua/test_mask_strategies.lua
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
    crc32_long = function(s) return 12345 end,
    log = function() end,
    ERR = 1, WARN = 2, INFO = 3, DEBUG = 4,
    shared = {},
}

package.loaded["cjson.safe"] = {
    encode = function(t) return "{}" end,
    decode = function(s) return {} end,
    null = "\0",
    empty_table = {},
}

-- ────────────────────────────────────────────────────────────────────────────
-- Load module under test
-- ────────────────────────────────────────────────────────────────────────────

package.path = package.path .. ";./apisix/plugins/lib/?.lua"

local mask = require("aria-mask-strategies")


-- ────────────────────────────────────────────────────────────────────────────
-- Tests
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-mask-strategies", function()

    -- ── apply() nil / null / empty handling ──────────────────────────────

    describe("apply()", function()

        it("should return nil when value is nil", function()
            assert.is_nil(mask.apply("last4", nil))
        end)

        it("should return cjson.null when value is cjson.null", function()
            local cjson = package.loaded["cjson.safe"]
            local result = mask.apply("last4", cjson.null)
            assert.are.equal(cjson.null, result)
        end)

        it("should return [REDACTED] for unknown strategy", function()
            assert.are.equal("[REDACTED]", mask.apply("no_such_strategy", "secret"))
        end)

        it("should return value unchanged for 'full' strategy", function()
            assert.are.equal("sensitive_data", mask.apply("full", "sensitive_data"))
        end)

        it("should return nil for 'full' strategy with nil value", function()
            assert.is_nil(mask.apply("full", nil))
        end)
    end)


    -- ── last4 strategy ──────────────────────────────────────────────────

    describe("last4 strategy", function()

        it("should mask a credit card number showing last 4", function()
            local result = mask.apply("last4", "4111111111111111")
            assert.are.equal("************1111", result)
        end)

        it("should return short strings unchanged (<=4 chars)", function()
            assert.are.equal("1234", mask.apply("last4", "1234"))
        end)

        it("should return very short strings unchanged", function()
            assert.are.equal("ab", mask.apply("last4", "ab"))
        end)

        it("should handle empty string", function()
            assert.are.equal("", mask.apply("last4", ""))
        end)

        it("should handle exactly 5-char string", function()
            assert.are.equal("*2345", mask.apply("last4", "12345"))
        end)

        it("should handle numeric input by converting to string", function()
            local result = mask.apply("last4", 123456)
            assert.are.equal("**3456", result)
        end)
    end)


    -- ── first2last2 strategy ────────────────────────────────────────────

    describe("first2last2 strategy", function()

        it("should mask email showing first 2 and last 2", function()
            local result = mask.apply("first2last2", "john.doe@example.com")
            assert.are.equal("jo****************om", result)
        end)

        it("should return short strings unchanged (<=4 chars)", function()
            assert.are.equal("abcd", mask.apply("first2last2", "abcd"))
        end)

        it("should handle 5-char string", function()
            assert.are.equal("ab*de", mask.apply("first2last2", "abcde"))
        end)

        it("should handle empty string", function()
            assert.are.equal("", mask.apply("first2last2", ""))
        end)
    end)


    -- ── hash strategy ───────────────────────────────────────────────────

    describe("hash strategy", function()

        it("should return a 16-character hex string", function()
            local result = mask.apply("hash", "test@example.com")
            assert.are.equal(16, #result)
        end)

        it("should be deterministic (same input = same output)", function()
            local r1 = mask.apply("hash", "test_value")
            local r2 = mask.apply("hash", "test_value")
            assert.are.equal(r1, r2)
        end)

        it("should handle numeric input", function()
            local result = mask.apply("hash", 42)
            assert.are.equal(16, #result)
        end)
    end)


    -- ── redact strategy ─────────────────────────────────────────────────

    describe("redact strategy", function()

        it("should return [REDACTED] regardless of input", function()
            assert.are.equal("[REDACTED]", mask.apply("redact", "any value"))
        end)

        it("should return [REDACTED] for numbers", function()
            assert.are.equal("[REDACTED]", mask.apply("redact", 12345))
        end)

        it("should return [REDACTED] for empty string", function()
            assert.are.equal("[REDACTED]", mask.apply("redact", ""))
        end)
    end)


    -- ── mask:email strategy ─────────────────────────────────────────────

    describe("mask:email strategy", function()

        it("should mask a standard email address", function()
            local result = mask.apply("mask:email", "john.doe@example.com")
            assert.are.equal("j***@e***.com", result)
        end)

        it("should mask email with subdomain", function()
            local result = mask.apply("mask:email", "user@mail.example.co.uk")
            assert.are.equal("u***@m***.uk", result)
        end)

        it("should return [REDACTED] for non-email string", function()
            local result = mask.apply("mask:email", "not-an-email")
            assert.are.equal("[REDACTED]", result)
        end)

        it("should handle single-part domain", function()
            local result = mask.apply("mask:email", "user@localhost")
            assert.are.equal("u***@l***", result)
        end)
    end)


    -- ── mask:phone strategy ─────────────────────────────────────────────

    describe("mask:phone strategy", function()

        it("should mask a Turkish MSISDN", function()
            local result = mask.apply("mask:phone", "+905321234567")
            assert.are.equal("+9053***4567", result)
        end)

        it("should mask phone with spaces", function()
            local result = mask.apply("mask:phone", "+90 532 123 4567")
            assert.are.equal("+9053***4567", result)
        end)

        it("should mask phone with dashes", function()
            local result = mask.apply("mask:phone", "+90-532-123-4567")
            assert.are.equal("+9053***4567", result)
        end)

        it("should return [REDACTED] for short numbers", function()
            assert.are.equal("[REDACTED]", mask.apply("mask:phone", "12345"))
        end)

        it("should handle number without country code", function()
            local result = mask.apply("mask:phone", "5321234567")
            assert.are.equal("53212***4567", result)
        end)
    end)


    -- ── mask:national_id strategy ───────────────────────────────────────

    describe("mask:national_id strategy", function()

        it("should mask an 11-digit TC Kimlik number", function()
            local result = mask.apply("mask:national_id", "12345678901")
            assert.are.equal("****56789**", result)
        end)

        it("should return [REDACTED] for non-11-digit string", function()
            assert.are.equal("[REDACTED]", mask.apply("mask:national_id", "123456"))
        end)

        it("should return [REDACTED] for 12-digit string", function()
            assert.are.equal("[REDACTED]", mask.apply("mask:national_id", "123456789012"))
        end)
    end)


    -- ── mask:iban strategy ──────────────────────────────────────────────

    describe("mask:iban strategy", function()

        it("should mask a Turkish IBAN", function()
            local result = mask.apply("mask:iban", "TR330006100519786457841326")
            assert.are.equal("TR33******************1326", result)
        end)

        it("should handle IBAN with spaces", function()
            local result = mask.apply("mask:iban", "TR33 0006 1005 1978 6457 8413 26")
            assert.are.equal("TR33******************1326", result)
        end)

        it("should return [REDACTED] for short IBAN", function()
            assert.are.equal("[REDACTED]", mask.apply("mask:iban", "TR33"))
        end)

        it("should handle exactly 8-char IBAN", function()
            local result = mask.apply("mask:iban", "TR330006")
            assert.are.equal("TR330006", result)
        end)
    end)


    -- ── mask:ip strategy ────────────────────────────────────────────────

    describe("mask:ip strategy", function()

        it("should mask last two octets of IPv4", function()
            local result = mask.apply("mask:ip", "192.168.1.100")
            assert.are.equal("192.168.*.*", result)
        end)

        it("should mask loopback address", function()
            local result = mask.apply("mask:ip", "127.0.0.1")
            assert.are.equal("127.0.*.*", result)
        end)

        it("should return the value unchanged for non-IPv4", function()
            local result = mask.apply("mask:ip", "not-an-ip")
            assert.are.equal("not-an-ip", result)
        end)

        it("should handle 0.0.0.0", function()
            local result = mask.apply("mask:ip", "0.0.0.0")
            assert.are.equal("0.0.*.*", result)
        end)
    end)


    -- ── mask:dob strategy ───────────────────────────────────────────────

    describe("mask:dob strategy", function()

        it("should mask a date of birth keeping day", function()
            local result = mask.apply("mask:dob", "1990-05-13")
            assert.are.equal("****-**-13", result)
        end)

        it("should mask date with single-digit day", function()
            local result = mask.apply("mask:dob", "2000-01-05")
            assert.are.equal("****-**-05", result)
        end)

        it("should handle date without matching day pattern", function()
            local result = mask.apply("mask:dob", "not-a-date")
            assert.are.equal("****-**-**", result)
        end)

        it("should handle date ending with day-like suffix", function()
            local result = mask.apply("mask:dob", "1990-12-31")
            assert.are.equal("****-**-31", result)
        end)
    end)


    -- ── full strategy ───────────────────────────────────────────────────

    describe("full strategy", function()

        it("should return value unchanged", function()
            assert.are.equal("sensitive_data_123", mask.apply("full", "sensitive_data_123"))
        end)

        it("should return numeric value unchanged", function()
            assert.are.equal(42, mask.apply("full", 42))
        end)

        it("should return empty string unchanged", function()
            assert.are.equal("", mask.apply("full", ""))
        end)

        it("should return table unchanged", function()
            local t = { key = "value" }
            assert.are.equal(t, mask.apply("full", t))
        end)
    end)


    -- ── is_valid() ──────────────────────────────────────────────────────

    describe("is_valid()", function()

        it("should return true for known strategies", function()
            assert.is_true(mask.is_valid("last4"))
            assert.is_true(mask.is_valid("first2last2"))
            assert.is_true(mask.is_valid("hash"))
            assert.is_true(mask.is_valid("redact"))
            assert.is_true(mask.is_valid("mask:email"))
            assert.is_true(mask.is_valid("mask:phone"))
            assert.is_true(mask.is_valid("mask:national_id"))
            assert.is_true(mask.is_valid("mask:iban"))
            assert.is_true(mask.is_valid("mask:ip"))
            assert.is_true(mask.is_valid("mask:dob"))
            assert.is_true(mask.is_valid("full"))
        end)

        it("should return false for unknown strategy", function()
            assert.is_falsy(mask.is_valid("unknown_strategy"))
        end)

        it("should return false for nil", function()
            assert.is_falsy(mask.is_valid(nil))
        end)
    end)


    -- ── list() ──────────────────────────────────────────────────────────

    describe("list()", function()

        it("should return all 11 strategies", function()
            local names = mask.list()
            assert.are.equal(11, #names)
        end)

        it("should include known strategy names", function()
            local names = mask.list()
            local name_set = {}
            for _, n in ipairs(names) do name_set[n] = true end
            assert.is_true(name_set["last4"])
            assert.is_true(name_set["redact"])
            assert.is_true(name_set["mask:email"])
            assert.is_true(name_set["full"])
        end)
    end)
end)
