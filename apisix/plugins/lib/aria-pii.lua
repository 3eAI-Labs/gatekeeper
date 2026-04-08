--
-- aria-pii.lua — PII pattern detection library
--
-- Shared regex patterns with validators for PII detection.
-- Used by: aria-shield (prompt scanning), aria-mask (response masking)
--
-- Business Rules: BR-SH-012 (PII in prompts), BR-MK-003 (PII in responses)
-- Data Classification: L3/L4 patterns per DATA_CLASSIFICATION.md
--

local ngx_re = ngx.re

local _M = {
    version = "0.1.0",
}


-- ────────────────────────────────────────────────────────────────────────────
-- Validators
-- ────────────────────────────────────────────────────────────────────────────

--- Luhn algorithm check for credit card (PAN) and IMEI validation.
-- @param number_str  Digit string
-- @return boolean
local function luhn_check(number_str)
    local digits = number_str:gsub("%D", "")
    if #digits < 12 then return false end

    local sum = 0
    local alt = false
    for i = #digits, 1, -1 do
        local d = tonumber(digits:sub(i, i))
        if alt then
            d = d * 2
            if d > 9 then d = d - 9 end
        end
        sum = sum + d
        alt = not alt
    end
    return (sum % 10) == 0
end


--- TC Kimlik (Turkish National ID) checksum validation.
-- 11-digit number with mod-11 based checksum on digits 10 and 11.
-- @param id_str  11-digit string
-- @return boolean
local function tc_kimlik_check(id_str)
    local digits = id_str:gsub("%D", "")
    if #digits ~= 11 then return false end
    if digits:sub(1, 1) == "0" then return false end

    local d = {}
    for i = 1, 11 do
        d[i] = tonumber(digits:sub(i, i))
    end

    -- 10th digit check
    local odd_sum  = d[1] + d[3] + d[5] + d[7] + d[9]
    local even_sum = d[2] + d[4] + d[6] + d[8]
    local check10 = ((odd_sum * 7) - even_sum) % 10
    if check10 ~= d[10] then return false end

    -- 11th digit check
    local total = 0
    for i = 1, 10 do
        total = total + d[i]
    end
    if (total % 10) ~= d[11] then return false end

    return true
end


-- ────────────────────────────────────────────────────────────────────────────
-- Pattern Definitions
-- ────────────────────────────────────────────────────────────────────────────

--- PII pattern registry.
-- Each pattern has: regex, optional validator function, field_type, classification level.
_M.patterns = {
    pan = {
        name     = "pan",
        regex    = [[\b([3-6]\d{12,18})\b]],
        validate = function(match)
            return luhn_check(match)
        end,
        field_type      = "pan",
        classification  = "L4",
        mask_placeholder = "[REDACTED_PAN]",
    },

    msisdn = {
        name     = "msisdn",
        regex    = [[(\+?90\s?5\d{2}\s?\d{3}\s?\d{2}\s?\d{2})]],
        validate = function(match)
            local cleaned = match:gsub("%D", "")
            return #cleaned >= 10 and #cleaned <= 13
        end,
        field_type      = "phone",
        classification  = "L3",
        mask_placeholder = "[REDACTED_PHONE]",
    },

    tc_kimlik = {
        name     = "tc_kimlik",
        regex    = [[\b(\d{11})\b]],
        validate = function(match)
            return tc_kimlik_check(match)
        end,
        field_type      = "national_id",
        classification  = "L3",
        mask_placeholder = "[REDACTED_NATIONAL_ID]",
    },

    email = {
        name     = "email",
        regex    = [[\b([a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})\b]],
        validate = nil,  -- Regex is sufficient
        field_type      = "email",
        classification  = "L3",
        mask_placeholder = "[REDACTED_EMAIL]",
    },

    iban_tr = {
        name     = "iban_tr",
        regex    = [[\b(TR\d{2}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{2})\b]],
        validate = function(match)
            local cleaned = match:gsub("%s", "")
            return #cleaned == 26
        end,
        field_type      = "iban",
        classification  = "L3",
        mask_placeholder = "[REDACTED_IBAN]",
    },

    imei = {
        name     = "imei",
        regex    = [[\b(\d{15})\b]],
        validate = function(match)
            return luhn_check(match:sub(1, 14))
        end,
        field_type      = "imei",
        classification  = "L3",
        mask_placeholder = "[REDACTED_IMEI]",
    },

    ip_address = {
        name     = "ip_address",
        regex    = [[\b((?:\d{1,3}\.){3}\d{1,3})\b]],
        validate = function(match)
            for octet in match:gmatch("%d+") do
                local n = tonumber(octet)
                if n > 255 then return false end
            end
            -- Skip common non-PII IPs
            if match == "0.0.0.0" or match == "127.0.0.1" then
                return false
            end
            return true
        end,
        field_type      = "ip",
        classification  = "L3",
        mask_placeholder = "[REDACTED_IP]",
    },

    dob = {
        name     = "dob",
        regex    = [[\b((19|20)\d{2}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01]))\b]],
        validate = nil,
        field_type      = "dob",
        classification  = "L3",
        mask_placeholder = "[REDACTED_DOB]",
    },
}


-- ────────────────────────────────────────────────────────────────────────────
-- Public API
-- ────────────────────────────────────────────────────────────────────────────

--- Scan text for PII patterns.
-- @param text          String to scan
-- @param pattern_names Table of pattern names to check (e.g., {"pan", "email"}).
--                      If nil, all patterns are checked.
-- @param whitelist     Optional table of values to skip
-- @return table of matches: { {type, value, start, stop}, ... }
function _M.scan(text, pattern_names, whitelist)
    if not text or text == "" then return {} end

    local results = {}
    local patterns_to_check

    if pattern_names then
        patterns_to_check = {}
        for _, name in ipairs(pattern_names) do
            if _M.patterns[name] then
                patterns_to_check[#patterns_to_check + 1] = _M.patterns[name]
            end
        end
    else
        patterns_to_check = {}
        for _, p in pairs(_M.patterns) do
            patterns_to_check[#patterns_to_check + 1] = p
        end
    end

    for _, pat in ipairs(patterns_to_check) do
        local iter, err = ngx_re.gmatch(text, pat.regex, "jo")
        if iter then
            while true do
                local m = iter()
                if not m then break end

                local matched_value = m[1] or m[0]
                local is_valid = true

                -- Run validator if defined
                if pat.validate then
                    is_valid = pat.validate(matched_value)
                end

                -- Check whitelist
                if whitelist and whitelist[matched_value] then
                    is_valid = false
                end

                if is_valid then
                    results[#results + 1] = {
                        pii_type         = pat.name,
                        field_type       = pat.field_type,
                        value            = matched_value,
                        classification   = pat.classification,
                        mask_placeholder = pat.mask_placeholder,
                    }
                end
            end
        end
    end

    return results
end


--- Replace all PII matches in text with their mask placeholders.
-- @param text          String to mask
-- @param pattern_names Optional table of pattern names
-- @return masked text, number of replacements
function _M.mask_text(text, pattern_names)
    if not text or text == "" then return text, 0 end

    local matches = _M.scan(text, pattern_names)
    local count = 0

    for _, match in ipairs(matches) do
        text = text:gsub(match.value:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"),
            match.mask_placeholder)
        count = count + 1
    end

    return text, count
end


--- Check if text contains any PII.
-- @param text          String to check
-- @param pattern_names Optional table of pattern names
-- @return boolean, first match or nil
function _M.contains_pii(text, pattern_names)
    local matches = _M.scan(text, pattern_names)
    if #matches > 0 then
        return true, matches[1]
    end
    return false, nil
end


--- Expose validators for external use (e.g., testing).
_M.validators = {
    luhn_check    = luhn_check,
    tc_kimlik_check = tc_kimlik_check,
}


return _M
