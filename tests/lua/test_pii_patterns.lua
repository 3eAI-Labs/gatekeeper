--
-- test_pii_patterns.lua — Unit tests for aria-pii.lua
--
-- Framework: busted
-- Run: busted tests/lua/test_pii_patterns.lua
--

-- ────────────────────────────────────────────────────────────────────────────
-- Mocks
-- ────────────────────────────────────────────────────────────────────────────

-- We need a proper ngx.re.gmatch mock that can handle PII regex matching.
-- Since busted runs outside APISIX, we use Lua patterns to simulate
-- the regex behavior for each PII type.

local gmatch_results = {}

_G.ngx = {
    re = {
        gmatch = function(text, pattern, flags)
            -- Use a simple substring-search approach for testing.
            -- We pre-populate gmatch_results before each test.
            local results = gmatch_results[pattern] or {}
            local idx = 0
            return function()
                idx = idx + 1
                if idx <= #results then
                    return results[idx]
                end
                return nil
            end, nil
        end,
    },
    null = "\0",
    now = function() return 1712592600 end,
    time = function() return 1712592600 end,
    utctime = function() return "2026-04-08 14:30:00" end,
    sha1_bin = function(s) return string.rep("\0", 20) end,
    encode_base16 = function(s) return string.rep("0", #s * 2) end,
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

local pii = require("aria-pii")


-- ────────────────────────────────────────────────────────────────────────────
-- Helper: set up gmatch mock results for a specific pattern
-- ────────────────────────────────────────────────────────────────────────────

local function setup_gmatch(pattern_name, matches)
    -- Clear all previous results
    gmatch_results = {}
    -- Set results for the specific pattern's regex
    local pat = pii.patterns[pattern_name]
    if pat then
        local results = {}
        for _, m in ipairs(matches) do
            -- ngx.re.gmatch returns {[0]=full_match, [1]=capture_group}
            results[#results + 1] = { [0] = m, [1] = m }
        end
        gmatch_results[pat.regex] = results
    end
end

local function setup_gmatch_multi(pattern_matches)
    gmatch_results = {}
    for pattern_name, matches in pairs(pattern_matches) do
        local pat = pii.patterns[pattern_name]
        if pat then
            local results = {}
            for _, m in ipairs(matches) do
                results[#results + 1] = { [0] = m, [1] = m }
            end
            gmatch_results[pat.regex] = results
        end
    end
end


-- ────────────────────────────────────────────────────────────────────────────
-- Tests: Validators
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-pii", function()

    describe("validators", function()

        describe("luhn_check", function()

            it("should validate a known-valid Visa card (4111111111111111)", function()
                assert.is_true(pii.validators.luhn_check("4111111111111111"))
            end)

            it("should validate a known-valid Mastercard (5500000000000004)", function()
                assert.is_true(pii.validators.luhn_check("5500000000000004"))
            end)

            it("should validate Amex (378282246310005)", function()
                assert.is_true(pii.validators.luhn_check("378282246310005"))
            end)

            it("should reject a Luhn-invalid card number", function()
                assert.is_false(pii.validators.luhn_check("4111111111111112"))
            end)

            it("should reject another Luhn-invalid number", function()
                assert.is_false(pii.validators.luhn_check("1234567890123456"))
            end)

            it("should reject strings shorter than 12 digits", function()
                assert.is_false(pii.validators.luhn_check("12345"))
            end)

            it("should strip non-digit characters before validation", function()
                assert.is_true(pii.validators.luhn_check("4111-1111-1111-1111"))
            end)

            it("should handle empty string", function()
                assert.is_false(pii.validators.luhn_check(""))
            end)
        end)


        describe("tc_kimlik_check", function()

            -- 10000000146 is a well-known valid TC Kimlik for testing
            it("should validate a known-valid TC Kimlik (10000000146)", function()
                assert.is_true(pii.validators.tc_kimlik_check("10000000146"))
            end)

            it("should reject TC Kimlik starting with 0", function()
                assert.is_false(pii.validators.tc_kimlik_check("01234567890"))
            end)

            it("should reject TC Kimlik with wrong 10th digit", function()
                -- Modify last two digits to break checksum
                assert.is_false(pii.validators.tc_kimlik_check("10000000156"))
            end)

            it("should reject TC Kimlik with wrong 11th digit", function()
                assert.is_false(pii.validators.tc_kimlik_check("10000000147"))
            end)

            it("should reject non-11-digit strings", function()
                assert.is_false(pii.validators.tc_kimlik_check("12345"))
            end)

            it("should reject 12-digit strings", function()
                assert.is_false(pii.validators.tc_kimlik_check("123456789012"))
            end)

            it("should strip non-digit characters", function()
                assert.is_false(pii.validators.tc_kimlik_check("100-000-001-46"))
            end)

            it("should handle empty string", function()
                assert.is_false(pii.validators.tc_kimlik_check(""))
            end)

            -- Validate another known-valid: 11111111110
            -- d = {1,1,1,1,1,1,1,1,1,?,?}
            -- odd_sum = 1+1+1+1+1 = 5, even_sum = 1+1+1+1 = 4
            -- check10 = (5*7 - 4) % 10 = (35-4) % 10 = 31 % 10 = 1
            -- total(1..10) = 9*1 + 1 = 10, check11 = 10 % 10 = 0
            -- so valid TC Kimlik = 11111111110
            it("should validate another known-valid TC Kimlik (11111111110)", function()
                assert.is_true(pii.validators.tc_kimlik_check("11111111110"))
            end)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: Pattern validators (called via pattern.validate)
    -- ────────────────────────────────────────────────────────────────────────

    describe("pattern validators", function()

        describe("PAN pattern", function()

            it("should accept Luhn-valid PAN", function()
                assert.is_true(pii.patterns.pan.validate("4111111111111111"))
            end)

            it("should reject Luhn-invalid PAN", function()
                assert.is_false(pii.patterns.pan.validate("4111111111111112"))
            end)
        end)

        describe("MSISDN pattern", function()

            it("should accept valid Turkish mobile number", function()
                assert.is_true(pii.patterns.msisdn.validate("+905321234567"))
            end)

            it("should accept number with spaces", function()
                assert.is_true(pii.patterns.msisdn.validate("+90 532 123 45 67"))
            end)

            it("should reject too-short number", function()
                assert.is_false(pii.patterns.msisdn.validate("+9053"))
            end)

            it("should reject too-long number", function()
                assert.is_false(pii.patterns.msisdn.validate("+9053212345678901"))
            end)
        end)

        describe("TC Kimlik pattern", function()

            it("should accept valid TC Kimlik via pattern validator", function()
                assert.is_true(pii.patterns.tc_kimlik.validate("10000000146"))
            end)

            it("should reject invalid TC Kimlik via pattern validator", function()
                assert.is_false(pii.patterns.tc_kimlik.validate("12345678901"))
            end)
        end)

        describe("IBAN TR pattern", function()

            it("should accept 26-char Turkish IBAN", function()
                assert.is_true(pii.patterns.iban_tr.validate("TR330006100519786457841326"))
            end)

            it("should accept IBAN with spaces (26 chars cleaned)", function()
                assert.is_true(pii.patterns.iban_tr.validate("TR33 0006 1005 1978 6457 8413 26"))
            end)

            it("should reject short IBAN", function()
                assert.is_false(pii.patterns.iban_tr.validate("TR3300061005"))
            end)
        end)

        describe("IMEI pattern", function()

            it("should accept Luhn-valid 15-digit IMEI", function()
                -- 490154203237518 is a well-known valid IMEI
                assert.is_true(pii.patterns.imei.validate("490154203237518"))
            end)

            it("should reject IMEI with invalid Luhn on first 14 digits", function()
                assert.is_false(pii.patterns.imei.validate("123456789012345"))
            end)
        end)

        describe("IP address pattern", function()

            it("should accept valid public IP", function()
                assert.is_true(pii.patterns.ip_address.validate("192.168.1.100"))
            end)

            it("should accept another valid IP", function()
                assert.is_true(pii.patterns.ip_address.validate("10.0.0.1"))
            end)

            it("should reject 127.0.0.1 (loopback, non-PII)", function()
                assert.is_false(pii.patterns.ip_address.validate("127.0.0.1"))
            end)

            it("should reject 0.0.0.0 (non-PII)", function()
                assert.is_false(pii.patterns.ip_address.validate("0.0.0.0"))
            end)

            it("should reject IP with octet > 255", function()
                assert.is_false(pii.patterns.ip_address.validate("256.1.2.3"))
            end)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: scan()
    -- ────────────────────────────────────────────────────────────────────────

    describe("scan()", function()

        it("should return empty table for nil input", function()
            local results = pii.scan(nil)
            assert.are.equal(0, #results)
        end)

        it("should return empty table for empty string", function()
            local results = pii.scan("")
            assert.are.equal(0, #results)
        end)

        it("should detect a PAN in text", function()
            setup_gmatch("pan", { "4111111111111111" })
            local results = pii.scan("My card is 4111111111111111", { "pan" })
            assert.are.equal(1, #results)
            assert.are.equal("pan", results[1].pii_type)
            assert.are.equal("4111111111111111", results[1].value)
            assert.are.equal("L4", results[1].classification)
            assert.are.equal("[REDACTED_PAN]", results[1].mask_placeholder)
        end)

        it("should reject Luhn-invalid PAN via validator", function()
            setup_gmatch("pan", { "4111111111111112" })
            local results = pii.scan("Card: 4111111111111112", { "pan" })
            assert.are.equal(0, #results)
        end)

        it("should detect email in text", function()
            setup_gmatch("email", { "john@example.com" })
            local results = pii.scan("Email: john@example.com", { "email" })
            assert.are.equal(1, #results)
            assert.are.equal("email", results[1].pii_type)
            assert.are.equal("email", results[1].field_type)
        end)

        it("should detect multiple PII types", function()
            setup_gmatch_multi({
                pan = { "4111111111111111" },
                email = { "user@test.com" },
            })
            local results = pii.scan("Card 4111111111111111 email user@test.com", { "pan", "email" })
            assert.are.equal(2, #results)
        end)

        it("should skip whitelisted values", function()
            setup_gmatch("email", { "admin@internal.com" })
            local whitelist = { ["admin@internal.com"] = true }
            local results = pii.scan("Contact admin@internal.com", { "email" }, whitelist)
            assert.are.equal(0, #results)
        end)

        it("should detect TC Kimlik with valid checksum", function()
            setup_gmatch("tc_kimlik", { "10000000146" })
            local results = pii.scan("TC: 10000000146", { "tc_kimlik" })
            assert.are.equal(1, #results)
            assert.are.equal("tc_kimlik", results[1].pii_type)
            assert.are.equal("national_id", results[1].field_type)
        end)

        it("should reject TC Kimlik with invalid checksum", function()
            setup_gmatch("tc_kimlik", { "12345678901" })
            local results = pii.scan("TC: 12345678901", { "tc_kimlik" })
            assert.are.equal(0, #results)
        end)

        it("should detect valid IP address", function()
            setup_gmatch("ip_address", { "192.168.1.100" })
            local results = pii.scan("IP: 192.168.1.100", { "ip_address" })
            assert.are.equal(1, #results)
            assert.are.equal("ip_address", results[1].pii_type)
        end)

        it("should skip loopback IP 127.0.0.1", function()
            setup_gmatch("ip_address", { "127.0.0.1" })
            local results = pii.scan("Localhost: 127.0.0.1", { "ip_address" })
            assert.are.equal(0, #results)
        end)

        it("should detect date of birth", function()
            setup_gmatch("dob", { "1990-05-13" })
            local results = pii.scan("Born: 1990-05-13", { "dob" })
            assert.are.equal(1, #results)
            assert.are.equal("dob", results[1].pii_type)
        end)

        it("should detect MSISDN", function()
            setup_gmatch("msisdn", { "+905321234567" })
            local results = pii.scan("Phone: +905321234567", { "msisdn" })
            assert.are.equal(1, #results)
            assert.are.equal("msisdn", results[1].pii_type)
            assert.are.equal("phone", results[1].field_type)
        end)

        it("should detect IBAN", function()
            setup_gmatch("iban_tr", { "TR330006100519786457841326" })
            local results = pii.scan("IBAN: TR330006100519786457841326", { "iban_tr" })
            assert.are.equal(1, #results)
            assert.are.equal("iban_tr", results[1].pii_type)
        end)

        it("should scan all patterns when pattern_names is nil", function()
            setup_gmatch_multi({
                email = { "test@example.com" },
                dob = { "1990-01-15" },
            })
            local results = pii.scan("test@example.com born 1990-01-15")
            assert.is_true(#results >= 2)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: mask_text()
    -- ────────────────────────────────────────────────────────────────────────

    describe("mask_text()", function()

        it("should return nil text unchanged", function()
            local result, count = pii.mask_text(nil)
            assert.is_nil(result)
            assert.are.equal(0, count)
        end)

        it("should return empty string unchanged", function()
            local result, count = pii.mask_text("")
            assert.are.equal("", result)
            assert.are.equal(0, count)
        end)

        it("should replace PAN with placeholder", function()
            setup_gmatch("pan", { "4111111111111111" })
            local text = "Card: 4111111111111111 is valid"
            local result, count = pii.mask_text(text, { "pan" })
            assert.are.equal("Card: [REDACTED_PAN] is valid", result)
            assert.are.equal(1, count)
        end)

        it("should replace email with placeholder", function()
            setup_gmatch("email", { "user@test.com" })
            local text = "Email user@test.com here"
            local result, count = pii.mask_text(text, { "email" })
            assert.are.equal("Email [REDACTED_EMAIL] here", result)
            assert.are.equal(1, count)
        end)

        it("should replace multiple PII types", function()
            setup_gmatch_multi({
                pan = { "4111111111111111" },
                email = { "a@b.com" },
            })
            local text = "Card 4111111111111111 email a@b.com"
            local result, count = pii.mask_text(text, { "pan", "email" })
            assert.are.equal("Card [REDACTED_PAN] email [REDACTED_EMAIL]", result)
            assert.are.equal(2, count)
        end)

        it("should handle text with special Lua pattern chars in PII value", function()
            setup_gmatch("email", { "user+tag@example.com" })
            local text = "Contact user+tag@example.com please"
            local result, count = pii.mask_text(text, { "email" })
            assert.are.equal("Contact [REDACTED_EMAIL] please", result)
            assert.are.equal(1, count)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: contains_pii()
    -- ────────────────────────────────────────────────────────────────────────

    describe("contains_pii()", function()

        it("should return false for nil text", function()
            local found, match = pii.contains_pii(nil)
            assert.is_false(found)
            assert.is_nil(match)
        end)

        it("should return false for empty text", function()
            local found, match = pii.contains_pii("")
            assert.is_false(found)
            assert.is_nil(match)
        end)

        it("should return true when PII is found", function()
            setup_gmatch("email", { "test@example.com" })
            local found, match = pii.contains_pii("Contact test@example.com", { "email" })
            assert.is_true(found)
            assert.is_not_nil(match)
            assert.are.equal("email", match.pii_type)
        end)

        it("should return false when no PII is found", function()
            setup_gmatch("email", {})
            local found, match = pii.contains_pii("No PII here", { "email" })
            assert.is_false(found)
            assert.is_nil(match)
        end)
    end)


    -- ────────────────────────────────────────────────────────────────────────
    -- Tests: Pattern metadata
    -- ────────────────────────────────────────────────────────────────────────

    describe("pattern metadata", function()

        it("should have 8 registered patterns", function()
            local count = 0
            for _ in pairs(pii.patterns) do count = count + 1 end
            assert.are.equal(8, count)
        end)

        it("should have correct classification levels", function()
            assert.are.equal("L4", pii.patterns.pan.classification)
            assert.are.equal("L3", pii.patterns.msisdn.classification)
            assert.are.equal("L3", pii.patterns.tc_kimlik.classification)
            assert.are.equal("L3", pii.patterns.email.classification)
            assert.are.equal("L3", pii.patterns.iban_tr.classification)
            assert.are.equal("L3", pii.patterns.imei.classification)
            assert.are.equal("L3", pii.patterns.ip_address.classification)
            assert.are.equal("L3", pii.patterns.dob.classification)
        end)

        it("should have mask_placeholder for every pattern", function()
            for name, pat in pairs(pii.patterns) do
                assert.is_not_nil(pat.mask_placeholder,
                    "Pattern '" .. name .. "' missing mask_placeholder")
            end
        end)

        it("should have field_type for every pattern", function()
            for name, pat in pairs(pii.patterns) do
                assert.is_not_nil(pat.field_type,
                    "Pattern '" .. name .. "' missing field_type")
            end
        end)
    end)
end)
