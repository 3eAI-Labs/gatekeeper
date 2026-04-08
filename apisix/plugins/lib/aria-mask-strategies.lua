--
-- aria-mask-strategies.lua — Configurable masking strategy implementations
--
-- Each strategy transforms a value into a masked version.
-- All strategies are deterministic (same input = same output).
--
-- Business Rule: BR-MK-004 (mask strategies)
-- User Story: US-B04 (configurable strategies)
--

local ngx       = ngx
local cjson     = require("cjson.safe")
local str_rep   = string.rep
local str_sub   = string.sub
local str_fmt   = string.format
local str_len   = string.len

local _M = {
    version = "0.1.0",
}

local strategies = {}


--- Mask: show only last 4 characters.
-- 4111111111111111 → ****-****-****-1111
strategies.last4 = function(value)
    local s = tostring(value)
    if #s <= 4 then return s end
    return str_rep("*", #s - 4) .. str_sub(s, -4)
end


--- Mask: show first 2 and last 2 characters.
-- john.doe@example.com → jo***le.com
strategies.first2last2 = function(value)
    local s = tostring(value)
    if #s <= 4 then return s end
    return str_sub(s, 1, 2) .. str_rep("*", #s - 4) .. str_sub(s, -2)
end


--- Mask: consistent SHA-1 hash (first 16 hex chars).
-- Same input = same hash (useful for correlation without exposing value).
strategies.hash = function(value)
    local s = tostring(value)
    return ngx.encode_base16(ngx.sha1_bin(s)):sub(1, 16)
end


--- Mask: replace with [REDACTED].
strategies.redact = function(value)
    return "[REDACTED]"
end


--- Mask: email-specific masking.
-- john.doe@example.com → j***@e***.com
strategies["mask:email"] = function(value)
    local s = tostring(value)
    local local_part, domain = s:match("^(.-)@(.+)$")
    if not local_part then return "[REDACTED]" end

    local domain_parts = {}
    for part in domain:gmatch("[^.]+") do
        domain_parts[#domain_parts + 1] = part
    end

    local masked_local = str_sub(local_part, 1, 1) .. "***"
    local masked_domain
    if #domain_parts >= 2 then
        masked_domain = str_sub(domain_parts[1], 1, 1) .. "***." .. domain_parts[#domain_parts]
    else
        masked_domain = str_sub(domain, 1, 1) .. "***"
    end

    return masked_local .. "@" .. masked_domain
end


--- Mask: phone/MSISDN-specific masking.
-- +905321234567 → +90532***4567
strategies["mask:phone"] = function(value)
    local s = tostring(value):gsub("[%s%-%(%)]+", "")
    if #s < 10 then return "[REDACTED]" end
    return str_sub(s, 1, 5) .. "***" .. str_sub(s, -4)
end


--- Mask: Turkish national ID (TC Kimlik).
-- 12345678901 → ****56789**
strategies["mask:national_id"] = function(value)
    local s = tostring(value)
    if #s ~= 11 then return "[REDACTED]" end
    return "****" .. str_sub(s, 5, 9) .. "**"
end


--- Mask: IBAN masking.
-- TR330006100519786457841326 → TR33****1326
strategies["mask:iban"] = function(value)
    local s = tostring(value):gsub("%s", "")
    if #s < 8 then return "[REDACTED]" end
    return str_sub(s, 1, 4) .. str_rep("*", #s - 8) .. str_sub(s, -4)
end


--- Mask: IP address masking.
-- 192.168.1.100 → 192.168.*.*
strategies["mask:ip"] = function(value)
    local s = tostring(value)
    local octets = {}
    for o in s:gmatch("%d+") do octets[#octets + 1] = o end
    if #octets ~= 4 then return value end
    return octets[1] .. "." .. octets[2] .. ".*.*"
end


--- Mask: date of birth masking.
-- 1990-05-13 → ****-**-13
strategies["mask:dob"] = function(value)
    local s = tostring(value)
    local day = s:match("%-(%d+)$")
    return "****-**-" .. (day or "**")
end


--- "full" strategy — no masking (used for admin role).
strategies.full = function(value)
    return value
end


-- ────────────────────────────────────────────────────────────────────────────
-- Public API
-- ────────────────────────────────────────────────────────────────────────────

--- Apply a masking strategy to a value.
-- @param strategy_name  Strategy name string (e.g., "last4", "mask:email")
-- @param value          Original value
-- @return masked value
function _M.apply(strategy_name, value)
    if value == nil or value == cjson.null then return value end
    if strategy_name == "full" then return value end

    local fn = strategies[strategy_name]
    if not fn then
        -- Unknown strategy — fail safe to redact (BR-MK-002 failsafe)
        return "[REDACTED]"
    end

    local ok, result = pcall(fn, value)
    if not ok then
        return "[REDACTED]"
    end
    return result
end


--- Check if a strategy name is valid.
-- @param name  Strategy name string
-- @return boolean
function _M.is_valid(name)
    return strategies[name] ~= nil
end


--- List all available strategy names.
-- @return table of strings
function _M.list()
    local names = {}
    for k, _ in pairs(strategies) do
        names[#names + 1] = k
    end
    return names
end


return _M
