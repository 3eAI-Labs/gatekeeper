--
-- aria-mask.lua — 3e-Aria-Mask: Dynamic Data Privacy Plugin for Apache APISIX
--
-- Mask v0.1: Field-level JSON masking, PII regex detection, configurable strategies
--
-- Business Rules: BR-MK-001 (JSONPath masking), BR-MK-002 (role policies),
--                 BR-MK-003 (PII detection), BR-MK-004 (strategies), BR-MK-005 (audit)
-- Decision Matrices: DM-MK-001 (role-based strategy), DM-MK-002 (PII action)
-- User Stories: US-B01 (field masking), US-B02 (role policies), US-B03 (PII detection),
--               US-B04 (strategies), US-B05 (audit)
--

local core           = require("apisix.core")
local cjson          = require("cjson.safe")
local ngx            = ngx
local aria_core      = require("apisix.plugins.lib.aria-core")
local aria_pii       = require("apisix.plugins.lib.aria-pii")
local mask_strategies = require("apisix.plugins.lib.aria-mask-strategies")

local plugin_name = "aria-mask"

local schema = {
    type = "object",
    properties = {
        rules = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    id         = { type = "string" },
                    path       = { type = "string" },  -- JSONPath expression
                    strategy   = { type = "string" },
                    field_type = { type = "string" },
                },
                required = {"path", "strategy"},
            },
            default = {},
        },
        role_policies = {
            type = "object",
            additionalProperties = {
                type = "object",
                properties = {
                    default_strategy = { type = "string", default = "redact" },
                    overrides = {
                        type = "object",
                        additionalProperties = { type = "string" },
                    },
                },
            },
        },
        auto_detect = {
            type = "object",
            properties = {
                enabled  = { type = "boolean", default = false },
                patterns = {
                    type = "array",
                    items = { type = "string" },
                    default = {"pan", "msisdn", "tc_kimlik", "email", "iban"},
                },
                whitelist_paths = {
                    type = "array",
                    items = { type = "string" },
                    default = {},
                },
            },
        },
        max_body_size = { type = "integer", minimum = 1024, default = 10485760 },
        -- Redis for tokenization strategy
        redis_host     = { type = "string", default = "127.0.0.1" },
        redis_port     = { type = "integer", default = 6379 },
        redis_password = { type = "string" },
        redis_database = { type = "integer", default = 0 },
    },
}


local _M = {
    version  = "0.1.0",
    priority = 1000,  -- Lower than Shield (2000): run after Shield
    name     = plugin_name,
    schema   = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


-- ────────────────────────────────────────────────────────────────────────────
-- Role-Based Policy Resolution (BR-MK-002, DM-MK-001)
-- ────────────────────────────────────────────────────────────────────────────

--- Resolve the masking strategy for a field given the consumer's role.
-- Resolution order: consumer role policy override → role default → "redact" (failsafe).
-- @param conf       Plugin configuration
-- @param role       Consumer role string
-- @param field_type Field type (e.g., "pan", "email")
-- @param default    Default strategy from the rule
-- @return strategy name string
local function resolve_strategy(conf, role, field_type, default)
    if not conf.role_policies then
        return default or "redact"
    end

    -- Normalize role to lowercase
    local role_lower = (role or ""):lower()
    local policy = conf.role_policies[role_lower]

    if not policy then
        -- Unknown role → failsafe to redact (DM-MK-001 last row)
        return "redact"
    end

    -- Check for field-type-specific override
    if policy.overrides and field_type and policy.overrides[field_type] then
        return policy.overrides[field_type]
    end

    -- Use role default strategy
    return policy.default_strategy or default or "redact"
end


-- ────────────────────────────────────────────────────────────────────────────
-- Simple JSONPath Evaluation
-- Supports: $.field, $.nested.field, $..field (recursive), $.array[*].field
-- ────────────────────────────────────────────────────────────────────────────

--- Find all values matching a simple JSONPath in a JSON object.
-- @param obj   Parsed JSON table
-- @param path  JSONPath string
-- @return list of {path_str, value, parent_table, parent_key}
local function jsonpath_find(obj, path)
    local results = {}

    -- Recursive descent: $..field
    if path:sub(1, 3) == "$.." then
        local field = path:sub(4)
        local function recurse(node, current_path)
            if type(node) ~= "table" then return end
            for k, v in pairs(node) do
                local kp = current_path .. "." .. tostring(k)
                if tostring(k) == field then
                    results[#results + 1] = {
                        path = kp, value = v, parent = node, key = k
                    }
                end
                if type(v) == "table" then
                    recurse(v, kp)
                end
            end
        end
        recurse(obj, "$")
        return results
    end

    -- Regular path: $.a.b.c or $.a[*].b
    local segments = {}
    local path_body = path:gsub("^%$%.?", "")
    for seg in path_body:gmatch("[^.]+") do
        segments[#segments + 1] = seg
    end

    local function traverse(node, depth, current_path)
        if depth > #segments then
            return
        end

        local seg = segments[depth]

        -- Handle array wildcard: items[*]
        local array_field, is_wildcard = seg:match("^(.+)%[%*%]$")
        if is_wildcard then
            local arr = node[array_field]
            if type(arr) == "table" then
                for i, item in ipairs(arr) do
                    local item_path = current_path .. "." .. array_field .. "[" .. i .. "]"
                    if depth == #segments then
                        -- The wildcard itself is the last segment — match all items
                        results[#results + 1] = {
                            path = item_path, value = item, parent = arr, key = i
                        }
                    else
                        traverse(item, depth + 1, item_path)
                    end
                end
            end
            return
        end

        -- Regular field access
        local child = node[seg]
        if child == nil then return end

        local child_path = current_path .. "." .. seg

        if depth == #segments then
            -- Final segment — this is a match
            results[#results + 1] = {
                path = child_path, value = child, parent = node, key = seg
            }
        else
            if type(child) == "table" then
                -- Check if it's an array (for implicit iteration)
                if #child > 0 and type(child[1]) == "table" then
                    for i, item in ipairs(child) do
                        traverse(item, depth + 1, child_path .. "[" .. i .. "]")
                    end
                else
                    traverse(child, depth + 1, child_path)
                end
            end
        end
    end

    traverse(obj, 1, "$")
    return results
end


-- ────────────────────────────────────────────────────────────────────────────
-- PII Auto-Detection in JSON Values (BR-MK-003)
-- ────────────────────────────────────────────────────────────────────────────

--- Scan all string values in a JSON object for PII patterns.
-- @param obj              Parsed JSON table
-- @param auto_detect_conf Auto-detection configuration
-- @param already_masked   Set of paths already masked by explicit rules
-- @return list of {path, value, pii_type, field_type}
local function detect_pii_in_json(obj, auto_detect_conf, already_masked)
    local results = {}
    local whitelist = {}
    for _, wp in ipairs(auto_detect_conf.whitelist_paths or {}) do
        whitelist[wp] = true
    end

    local function recurse(node, current_path)
        if type(node) ~= "table" then return end
        for k, v in pairs(node) do
            local kp = current_path .. "." .. tostring(k)

            if type(v) == "string" and not already_masked[kp] and not whitelist[kp] then
                -- Scan this string value for PII
                local matches = aria_pii.scan(v, auto_detect_conf.patterns)
                for _, match in ipairs(matches) do
                    results[#results + 1] = {
                        path       = kp,
                        value      = v,
                        pii_type   = match.pii_type,
                        field_type = match.field_type,
                        parent     = node,
                        key        = k,
                    }
                    break  -- One match per field is enough
                end
            elseif type(v) == "table" then
                recurse(v, kp)
            end
        end
    end

    recurse(obj, "$")
    return results
end


-- ────────────────────────────────────────────────────────────────────────────
-- Plugin Phases
-- ────────────────────────────────────────────────────────────────────────────

--- Access phase: read consumer role from APISIX context.
function _M.access(conf, ctx)
    -- Read consumer role from APISIX consumer metadata
    local consumer = ctx.var.consumer_name
    local role = "unknown"

    -- Try to get role from consumer metadata
    if ctx.consumer and ctx.consumer.metadata then
        role = ctx.consumer.metadata.aria_role or "unknown"
    end

    ctx.aria_consumer_role = role
    ctx.aria_consumer_id = consumer or "anonymous"
end


--- Body filter phase: parse JSON response, apply masking rules, auto-detect PII.
-- BR-MK-001, BR-MK-002, BR-MK-003, BR-MK-004
function _M.body_filter(conf, ctx)
    -- Gate: only process JSON responses
    local content_type = ngx.header["Content-Type"] or ""
    if not content_type:find("application/json", 1, true) then
        return
    end

    -- Collect full body (APISIX handles chunked reassembly)
    local body = core.response.hold_body_chunk(ctx)
    if not body then return end

    -- Gate: skip oversized responses (DM-MK-003)
    if #body > conf.max_body_size then
        aria_core.counter_inc("aria_mask_skip_large_body", 1, {
            route = ctx.var.route_id or "unknown",
        })
        return
    end

    -- Parse JSON
    local json_body, parse_err = cjson.decode(body)
    if not json_body then
        return  -- Non-parseable JSON, pass through
    end

    local role = ctx.aria_consumer_role or "unknown"
    local masked_fields = {}
    local already_masked_paths = {}

    -- Step 1: Apply explicit JSONPath masking rules (BR-MK-001)
    for _, rule in ipairs(conf.rules or {}) do
        local strategy = resolve_strategy(conf, role, rule.field_type, rule.strategy)

        if strategy ~= "full" then
            local matches = jsonpath_find(json_body, rule.path)
            for _, match in ipairs(matches) do
                if match.value ~= nil and match.value ~= cjson.null then
                    local masked_value = mask_strategies.apply(strategy, match.value)
                    match.parent[match.key] = masked_value
                    already_masked_paths[match.path] = true

                    masked_fields[#masked_fields + 1] = {
                        path       = match.path,
                        strategy   = strategy,
                        rule_id    = rule.id or "rule-" .. _,
                        pii_type   = rule.field_type or "generic",
                        source     = "explicit_rule",
                    }
                end
            end
        end
    end

    -- Step 2: PII auto-detection on remaining fields (BR-MK-003)
    if conf.auto_detect and conf.auto_detect.enabled then
        local pii_matches = detect_pii_in_json(json_body, conf.auto_detect, already_masked_paths)

        for _, pii in ipairs(pii_matches) do
            local strategy = resolve_strategy(conf, role, pii.field_type, nil)

            if strategy ~= "full" then
                -- Determine the right type-specific strategy
                local type_strategy = strategy
                if strategy == "mask" then
                    -- Resolve to type-specific mask strategy
                    local type_mask_map = {
                        pan        = "last4",
                        phone      = "mask:phone",
                        email      = "mask:email",
                        national_id = "mask:national_id",
                        iban       = "mask:iban",
                        imei       = "last4",
                        ip         = "mask:ip",
                        dob        = "mask:dob",
                    }
                    type_strategy = type_mask_map[pii.field_type] or "redact"
                end

                local masked_value = mask_strategies.apply(type_strategy, pii.value)
                pii.parent[pii.key] = masked_value

                masked_fields[#masked_fields + 1] = {
                    path       = pii.path,
                    strategy   = type_strategy,
                    rule_id    = "auto:" .. pii.pii_type,
                    pii_type   = pii.field_type,
                    source     = "auto_detect",
                }

                -- Emit violation metric (auto-detected PII not covered by explicit rules)
                aria_core.counter_inc("aria_mask_violations", 1, {
                    type = pii.pii_type,
                })
            end
        end
    end

    -- Replace response body if any masking occurred
    if #masked_fields > 0 then
        ngx.arg[1] = cjson.encode(json_body)
    end

    -- Store for log phase
    ctx.aria_masked_fields = masked_fields
end


--- Log phase: emit masking audit events and metrics.
-- BR-MK-005
function _M.log(conf, ctx)
    local masked_fields = ctx.aria_masked_fields
    if not masked_fields or #masked_fields == 0 then return end

    local consumer_id = ctx.aria_consumer_id or "unknown"
    local route_id = ctx.var.route_id or "unknown"
    local role = ctx.aria_consumer_role or "unknown"

    -- Emit metrics per masked field (BR-MK-005)
    for _, field in ipairs(masked_fields) do
        aria_core.counter_inc("aria_mask_applied", 1, {
            field_type = field.pii_type,
            strategy   = field.strategy,
            consumer   = consumer_id,
        })
    end

    -- Buffer audit events (metadata only, never original values)
    aria_core.record_audit_event(conf, ctx, "MASK_APPLIED", "MASKED", {
        metadata = {
            consumer_id   = consumer_id,
            consumer_role = role,
            route_id      = route_id,
            fields_masked = #masked_fields,
            field_details = masked_fields,  -- Contains paths and strategies, no values
        },
    })
end


return _M
