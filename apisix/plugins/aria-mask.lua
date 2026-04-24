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

local core             = require("apisix.core")
local cjson            = require("cjson.safe")
local ngx              = ngx
local aria_core        = require("apisix.plugins.lib.aria-core")
local aria_pii         = require("apisix.plugins.lib.aria-pii")
local mask_strategies  = require("apisix.plugins.lib.aria-mask-strategies")
local circuit_breaker  = require("apisix.plugins.lib.aria-circuit-breaker")
local str_fmt          = string.format

-- Sentinel delimiter used when concatenating field values into a single
-- NER request. Byte value 0x01 is forbidden in JSON strings (RFC 8259 § 7),
-- so real response bodies can't contain it, which means no entity returned
-- by the sidecar can straddle two concatenated fields.
local NER_DELIM = "\1"

-- Per-worker cache of circuit breakers keyed by sidecar endpoint.
-- One worker holds one breaker per endpoint; state persists in the shared
-- dict so sibling workers see the same breaker state.
local ner_breakers = {}

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
        -- NER via aria-runtime sidecar bridge (BR-MK-006).
        --   enabled=false (default): regex-only detection — no extra latency,
        --     no external dependency. Matches v0.1 behaviour.
        --   enabled=true: after regex pass, unmasked string leaves are sent
        --     to the sidecar's /v1/mask/detect endpoint for named-entity
        --     detection (PERSON/LOCATION/ORGANIZATION). Returned entities
        --     are masked per entity_strategy.
        -- Hot-path semantics — unlike canary's shadow diff, this bridge runs
        -- inline in body_filter; the Lua outer circuit breaker and the Java
        -- inner breaker are defense in depth.
        ner = {
            type = "object",
            properties = {
                sidecar = {
                    type = "object",
                    properties = {
                        enabled           = { type = "boolean", default = false },
                        endpoint          = { type = "string", default = "http://127.0.0.1:8081" },
                        timeout_ms        = { type = "integer", minimum = 50, maximum = 10000, default = 500 },
                        max_content_bytes = { type = "integer", minimum = 1024, maximum = 10485760, default = 131072 },
                        -- On sidecar unreachable / open breaker:
                        --   "open"   : return response with regex-only masking (default, availability)
                        --   "closed" : block response with 503 (stricter privacy, e.g. healthcare)
                        fail_mode         = { type = "string", enum = {"open", "closed"}, default = "open" },
                        min_confidence    = { type = "number", minimum = 0.0, maximum = 1.0, default = 0.7 },
                        circuit_breaker   = {
                            type = "object",
                            properties = {
                                failure_threshold = { type = "integer", minimum = 1, maximum = 100, default = 5 },
                                cooldown_ms       = { type = "integer", minimum = 1000, maximum = 3600000, default = 30000 },
                            },
                            default = {},
                        },
                        -- Per-entity-type masking strategy. Falls back to "redact".
                        entity_strategy   = {
                            type = "object",
                            additionalProperties = { type = "string" },
                            default = {
                                PERSON       = "redact",
                                LOCATION     = "redact",
                                ORGANIZATION = "redact",
                                MISC         = "redact",
                            },
                        },
                    },
                    default = { enabled = false },
                },
            },
            default = {},
        },
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
-- NER Sidecar Bridge (BR-MK-006)
-- ────────────────────────────────────────────────────────────────────────────

--- Walk the parsed JSON body and collect every string leaf that:
--   - isn't empty or too short to carry a named entity (len >= 3),
--   - wasn't already masked by explicit rules or regex auto-detect.
-- Returns { parts, total_len } where total_len includes the delimiter bytes
-- that will sit between values in the concatenated buffer.
local function collect_ner_candidates(obj, already_masked_paths)
    local parts = {}
    local total_len = 0

    local function recurse(node, current_path)
        if type(node) ~= "table" then return end
        for k, v in pairs(node) do
            local kp = current_path .. "." .. tostring(k)
            if type(v) == "string" then
                if #v >= 3 and not already_masked_paths[kp] then
                    parts[#parts + 1] = {
                        path   = kp,
                        value  = v,
                        parent = node,
                        key    = k,
                    }
                    total_len = total_len + #v + 1  -- +1 for delimiter
                end
            elseif type(v) == "table" then
                recurse(v, kp)
            end
        end
    end
    recurse(obj, "$")
    return parts, total_len
end


--- Resolve (or lazily create) the circuit breaker for a given sidecar endpoint.
local function get_ner_breaker(endpoint, cb_conf)
    if not endpoint or endpoint == "" then return nil end
    local cached = ner_breakers[endpoint]
    if cached then return cached end

    local dict = ngx.shared["prometheus-metrics"]
    if not dict then
        aria_core.log_warn("ner_breaker_no_dict",
            "prometheus-metrics shared dict missing; NER circuit breaker disabled")
        return nil
    end
    local cb, err = circuit_breaker.new(dict, "ner:" .. endpoint, {
        failure_threshold = (cb_conf or {}).failure_threshold or 5,
        cooldown_ms       = (cb_conf or {}).cooldown_ms or 30000,
    })
    if not cb then
        aria_core.log_warn("ner_breaker_init_failed", err or "unknown")
        return nil
    end
    ner_breakers[endpoint] = cb
    return cb
end


--- Call the sidecar's /v1/mask/detect endpoint. On success returns the parsed
-- entities list; on any failure returns (nil, reason) where reason is one of:
--   "disabled", "circuit_open", "oversized", "error", "parse_error", "empty".
-- Caller decides what to do with the failure based on fail_mode.
local function try_sidecar_ner(sc, route_id, content, breaker)
    if not sc.enabled then return nil, "disabled" end
    if not content or #content == 0 then return nil, "empty" end
    if #content > (sc.max_content_bytes or 131072) then
        aria_core.counter_inc("aria_mask_ner_calls_total", 1, {
            route = route_id, result = "skipped_oversized",
        })
        return nil, "oversized"
    end
    if breaker and not breaker:allow() then
        aria_core.counter_inc("aria_mask_ner_calls_total", 1, {
            route = route_id, result = "circuit_open",
        })
        return nil, "circuit_open"
    end

    local payload = cjson.encode({
        requestId          = ngx.var.request_id or "",
        routeId            = route_id,
        content            = content,
        alreadyMaskedPaths = {},  -- passed through only; engine ignores
    })

    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(sc.timeout_ms or 500)

    local endpoint = (sc.endpoint or "http://127.0.0.1:8081") .. "/v1/mask/detect"
    local start_ms = ngx.now() * 1000
    local res, err = httpc:request_uri(endpoint, {
        method  = "POST",
        body    = payload,
        headers = { ["Content-Type"] = "application/json" },
    })
    local elapsed_ms = (ngx.now() * 1000) - start_ms
    aria_core.histogram_observe("aria_mask_ner_latency_ms",
        elapsed_ms, { route = route_id })

    if not res or res.status ~= 200 then
        if breaker then breaker:record_failure() end
        aria_core.counter_inc("aria_mask_ner_calls_total", 1, {
            route = route_id, result = "error",
        })
        aria_core.log_warn("mask_ner_unavailable",
            str_fmt("NER sidecar failed for route %s: %s",
                route_id, err or ("http_" .. (res and res.status or "unknown"))))
        return nil, "error"
    end

    local parsed = cjson.decode(res.body or "")
    if not parsed or type(parsed.entities) ~= "table" then
        if breaker then breaker:record_failure() end
        aria_core.counter_inc("aria_mask_ner_calls_total", 1, {
            route = route_id, result = "parse_error",
        })
        return nil, "parse_error"
    end

    if breaker then breaker:record_success() end
    aria_core.counter_inc("aria_mask_ner_calls_total", 1, {
        route = route_id, result = "ok",
    })
    if breaker then
        aria_core.gauge_set("aria_mask_ner_circuit_state",
            breaker:raw_state(), { endpoint = sc.endpoint or "default" })
    end
    return parsed.entities
end


--- Given a list of parts and the entities returned by the sidecar, pair each
-- entity with the part whose offset range fully contains it. Entities that
-- straddle the delimiter (and so two fields) are discarded — the delimiter
-- byte is reserved, so straddling indicates either a model quirk or an
-- offset-arithmetic mismatch; either way, not safe to apply.
local function assign_entities_to_parts(entities, parts, min_confidence)
    local ranges = {}
    local offset = 0
    for i, p in ipairs(parts) do
        ranges[i] = { start = offset, stop = offset + #p.value }
        offset = offset + #p.value + #NER_DELIM
    end

    local assignments = {}
    for _, e in ipairs(entities) do
        local s = tonumber(e.start)
        local en = tonumber(e["end"])
        local conf = tonumber(e.confidence) or 0
        if s and en and en > s and conf >= (min_confidence or 0) then
            for i, r in ipairs(ranges) do
                if r.start <= s and en <= r.stop then
                    assignments[#assignments + 1] = {
                        part_index = i,
                        entity_type = e.entityType or "MISC",
                        confidence  = conf,
                    }
                    break
                end
            end
        end
    end
    return assignments
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

    -- Step 3: NER via sidecar bridge (BR-MK-006)
    --   Runs after regex so the model never sees fields already classified as
    --   PAN/MSISDN/TC/etc. — cheaper calls, fewer false positives on structured
    --   identifiers the model wasn't trained on.
    local ner_sc = conf.ner and conf.ner.sidecar
    if ner_sc and ner_sc.enabled then
        local route_id = ctx.var.route_id or "unknown"
        local ner_parts, ner_total_len =
            collect_ner_candidates(json_body, already_masked_paths)

        if #ner_parts > 0 then
            local values = {}
            for i, p in ipairs(ner_parts) do values[i] = p.value end
            local ner_content = table.concat(values, NER_DELIM)

            local breaker = get_ner_breaker(ner_sc.endpoint, ner_sc.circuit_breaker)
            local entities, ner_err = try_sidecar_ner(
                ner_sc, route_id, ner_content, breaker)

            if entities then
                local assignments = assign_entities_to_parts(
                    entities, ner_parts, ner_sc.min_confidence)

                for _, a in ipairs(assignments) do
                    local part = ner_parts[a.part_index]
                    -- Type-specific strategy override via role, then per-entity
                    -- default, then hard-coded "redact" failsafe.
                    local default_strategy =
                        (ner_sc.entity_strategy or {})[a.entity_type] or "redact"
                    local strategy = resolve_strategy(
                        conf, role, a.entity_type, default_strategy)

                    if strategy ~= "full" and not already_masked_paths[part.path] then
                        local masked_value = mask_strategies.apply(strategy, part.value)
                        part.parent[part.key] = masked_value
                        already_masked_paths[part.path] = true

                        masked_fields[#masked_fields + 1] = {
                            path     = part.path,
                            strategy = strategy,
                            rule_id  = "ner:" .. a.entity_type,
                            pii_type = a.entity_type,
                            source   = "ner_sidecar",
                        }

                        aria_core.counter_inc("aria_mask_ner_entities_total", 1, {
                            type = a.entity_type,
                        })
                    end
                end
            elseif ner_err == "error" or ner_err == "parse_error"
                    or ner_err == "circuit_open" then
                -- Fail-closed: redact every candidate field with "redact" as a
                -- defensive measure when we can't verify what's inside them.
                -- fail-open (default) silently continues with regex-only output.
                if ner_sc.fail_mode == "closed" then
                    for _, part in ipairs(ner_parts) do
                        if not already_masked_paths[part.path] then
                            part.parent[part.key] =
                                mask_strategies.apply("redact", part.value)
                            already_masked_paths[part.path] = true
                            masked_fields[#masked_fields + 1] = {
                                path     = part.path,
                                strategy = "redact",
                                rule_id  = "ner:fail_closed",
                                pii_type = "UNKNOWN",
                                source   = "ner_fail_closed",
                            }
                        end
                    end
                    aria_core.counter_inc("aria_mask_ner_calls_total", 1, {
                        route = route_id, result = "fail_closed_redacted",
                    })
                end
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


-- ────────────────────────────────────────────────────────────────────────────
-- Test hooks (busted only). Not part of the public plugin API.
-- Exported here so test_mask_ner can exercise the helpers without driving
-- the full body_filter fixture.
-- ────────────────────────────────────────────────────────────────────────────
_M._internal = {
    collect_ner_candidates   = collect_ner_candidates,
    assign_entities_to_parts = assign_entities_to_parts,
    try_sidecar_ner          = try_sidecar_ner,
    get_ner_breaker          = get_ner_breaker,
    NER_DELIM                = NER_DELIM,
}

return _M
