# Low-Level Design (LLD) — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 4 — Low-Level Design
**Version:** 1.0
**Date:** 2026-04-08
**Input:** HLD.md v1.0, BUSINESS_LOGIC.md v1.0, DECISION_MATRIX.md v1.0

---

## 1. Project Structure

```
3e-aria-gatekeeper/
├── apisix/
│   └── plugins/
│       ├── aria-shield.lua          # Module A: AI governance plugin
│       ├── aria-mask.lua            # Module B: Data masking plugin
│       ├── aria-canary.lua          # Module C: Progressive delivery plugin
│       └── lib/
│           ├── aria-core.lua        # Shared utilities (Redis, metrics, config)
│           ├── aria-provider.lua    # Provider transformation logic
│           ├── aria-pii.lua         # PII regex patterns (shared by Shield + Mask)
│           └── aria-grpc.lua        # gRPC/UDS client wrapper
├── wasm/
│   └── aria-mask-engine/            # Optional Rust WASM masking engine
│       ├── Cargo.toml
│       └── src/lib.rs
├── aria-runtime/                    # Java 21 sidecar
│   ├── build.gradle.kts
│   ├── src/main/java/com/eai/aria/runtime/
│   │   ├── AriaRuntimeApplication.java
│   │   ├── core/
│   │   │   ├── GrpcServer.java
│   │   │   ├── HealthController.java
│   │   │   ├── ShutdownManager.java
│   │   │   └── RequestContext.java
│   │   ├── shield/
│   │   │   ├── PromptAnalyzer.java
│   │   │   ├── TokenCounter.java
│   │   │   └── ContentFilter.java
│   │   ├── mask/
│   │   │   └── NerDetector.java
│   │   ├── canary/
│   │   │   └── DiffEngine.java
│   │   ├── common/
│   │   │   ├── RedisClient.java
│   │   │   ├── PostgresClient.java
│   │   │   └── AriaException.java
│   │   └── config/
│   │       └── AriaConfig.java
│   ├── src/main/proto/
│   │   └── aria/sidecar/v1/
│   │       ├── shield.proto
│   │       ├── mask.proto
│   │       ├── canary.proto
│   │       └── health.proto
│   └── src/test/
├── ariactl/                         # CLI tool
│   ├── cmd/
│   │   ├── root.go
│   │   ├── quota.go
│   │   ├── mask.go
│   │   └── canary.go
│   └── go.mod
├── deploy/
│   ├── helm/aria-gatekeeper/
│   ├── dashboards/
│   │   ├── shield-dashboard.json
│   │   ├── mask-dashboard.json
│   │   └── canary-dashboard.json
│   └── alerting-rules.yaml
├── db/
│   └── migration/
│       ├── V001__create_audit_events.sql
│       ├── V002__create_billing_records.sql
│       └── V003__create_masking_audit.sql
└── docs/
```

---

## 2. Module A: aria-shield.lua — Detailed Design

### 2.1 Lua Module Structure

```lua
-- aria-shield.lua
local _M = {}

-- APISIX plugin metadata
_M.version = "0.1.0"
_M.priority = 2000  -- High priority: run before most plugins
_M.name = "aria-shield"
_M.schema = { ... }  -- JSON Schema for plugin config

-- Plugin phases (mapped to business rules)
function _M.access(conf, ctx)           -- BR-SH-001, 005, 010, 011, 012, 018
function _M.header_filter(conf, ctx)    -- Response headers: X-Aria-*
function _M.body_filter(conf, ctx)      -- BR-SH-003, 004, 006, 007, 008
function _M.log(conf, ctx)              -- BR-SH-008, 015

return _M
```

### 2.2 Function Design — access Phase

```lua
-- BR-SH-001, BR-SH-005, BR-SH-010, BR-SH-011, BR-SH-012, BR-SH-018
function _M.access(conf, ctx)
    local consumer_id = ctx.var.consumer_name  -- From APISIX auth
    
    -- Step 1: Quota pre-flight check (BR-SH-005)
    local quota_result = check_quota(conf, ctx, consumer_id)
    -- Maps to: BR-SH-005 flowchart nodes D→F→G→K
    if quota_result.exhausted then
        -- Maps to: BR-SH-010, DM-SH-001
        return apply_overage_policy(conf, ctx, consumer_id, quota_result)
    end
    
    -- Step 2: Prompt injection scan (BR-SH-011)
    if conf.security.prompt_injection.enabled then
        local injection_result = scan_prompt_injection(conf, ctx)
        -- Maps to: BR-SH-011 flowchart nodes B→C→D
        if injection_result.detected and injection_result.confidence == "HIGH" then
            record_audit_event(ctx, "PROMPT_BLOCKED", injection_result)  -- BR-SH-015
            return error_response(ctx, 403, "ARIA_SH_PROMPT_INJECTION_DETECTED")
        end
        if injection_result.detected and injection_result.confidence == "MEDIUM" then
            -- Maps to: DM-SH-003 row 2
            local sidecar_result = grpc_analyze_prompt(ctx, injection_result)
            if sidecar_result == nil then  -- Sidecar unavailable (DM-SH-004)
                log_warn("sidecar_unavailable", "prompt_injection_medium_confidence_allowed")
            elseif sidecar_result.is_injection then
                record_audit_event(ctx, "PROMPT_BLOCKED", sidecar_result)
                return error_response(ctx, 403, "ARIA_SH_PROMPT_INJECTION_DETECTED")
            end
        end
    end
    
    -- Step 3: PII-in-prompt scan (BR-SH-012)
    if conf.security.pii_scanner.enabled then
        local pii_result = scan_pii_in_prompt(conf, ctx)
        -- Maps to: BR-SH-012 flowchart nodes B→C→E
        if pii_result.detected then
            if conf.security.pii_scanner.action == "block" then
                record_audit_event(ctx, "PII_IN_PROMPT", pii_result)
                return error_response(ctx, 400, "ARIA_SH_PII_IN_PROMPT_DETECTED")
            elseif conf.security.pii_scanner.action == "mask" then
                mask_pii_in_request(ctx, pii_result)  -- Replace with [REDACTED_*]
                record_audit_event(ctx, "PII_IN_PROMPT", pii_result)
            else  -- warn
                record_audit_event(ctx, "PII_IN_PROMPT", pii_result)
            end
        end
    end
    
    -- Step 4: Model version pin (BR-SH-018)
    if conf.model_pin then
        apply_model_pin(ctx, conf.model_pin)
    end
    
    -- Step 5: Provider routing (BR-SH-001, BR-SH-002, BR-SH-016, BR-SH-017)
    local provider = select_provider(conf, ctx)
    -- Maps to: BR-SH-001 flowchart nodes D→H→I1-I5
    if not provider then
        return error_response(ctx, 500, "ARIA_SH_PROVIDER_NOT_CONFIGURED")
    end
    
    -- Step 6: Transform request to provider format
    local ok, err = transform_request(ctx, provider)
    if not ok then
        return error_response(ctx, 400, "ARIA_SH_INVALID_REQUEST_FORMAT", err)
    end
    
    -- Step 7: Set upstream (provider endpoint)
    set_upstream(ctx, provider)
    
    -- Store context for body_filter phase
    ctx.aria_consumer_id = consumer_id
    ctx.aria_provider = provider
    ctx.aria_request_start = ngx.now()
end
```

### 2.3 Function Design — body_filter Phase

```lua
-- BR-SH-003, BR-SH-004, BR-SH-006, BR-SH-007
function _M.body_filter(conf, ctx)
    local is_streaming = ctx.var.http_content_type == "text/event-stream"
    
    if is_streaming then
        -- BR-SH-003: SSE streaming pass-through
        -- Forward each chunk immediately, accumulate approximate token count
        local chunk = ngx.arg[1]
        if chunk and #chunk > 0 then
            local tokens = approximate_token_count(chunk)  -- word_count * 1.3
            ctx.aria_stream_tokens = (ctx.aria_stream_tokens or 0) + tokens
        end
        
        local eof = ngx.arg[2]
        if eof then
            -- Stream complete — trigger reconciliation
            update_quota_async(ctx, ctx.aria_stream_tokens)
            grpc_count_tokens_async(ctx)  -- BR-SH-006
        end
        return  -- Pass through without modification
    end
    
    -- Non-streaming response
    -- Collect full body (APISIX handles chunked reassembly)
    local body = core.response.hold_body_chunk(ctx)
    if not body then return end
    
    -- BR-SH-004: Transform response to OpenAI format
    local transformed, usage = transform_response(ctx, body, ctx.aria_provider)
    if transformed then
        ngx.arg[1] = transformed
    end
    
    -- Extract token counts
    if usage then
        ctx.aria_tokens_input = usage.prompt_tokens or 0
        ctx.aria_tokens_output = usage.completion_tokens or 0
        local total = ctx.aria_tokens_input + ctx.aria_tokens_output
        
        -- BR-SH-005: Update quota in Redis
        update_quota(ctx, total)
        
        -- BR-SH-007: Calculate dollar cost
        local cost = calculate_cost(conf, ctx.aria_provider.model, usage)
        update_budget(ctx, cost)
        
        -- BR-SH-006: Async reconciliation via sidecar
        grpc_count_tokens_async(ctx)
    end
end
```

### 2.4 Function Design — log Phase

```lua
-- BR-SH-008, BR-SH-009, BR-SH-015
function _M.log(conf, ctx)
    local latency = ngx.now() - (ctx.aria_request_start or ngx.now())
    local status = ngx.status
    
    -- BR-SH-008: Emit Prometheus metrics
    emit_metric("aria_tokens_consumed", ctx.aria_tokens_input, {
        consumer = ctx.aria_consumer_id,
        model = ctx.aria_provider and ctx.aria_provider.model or "unknown",
        route = ctx.var.route_id,
        type = "input"
    })
    emit_metric("aria_tokens_consumed", ctx.aria_tokens_output, {
        consumer = ctx.aria_consumer_id,
        model = ctx.aria_provider and ctx.aria_provider.model or "unknown",
        route = ctx.var.route_id,
        type = "output"
    })
    emit_metric("aria_requests_total", 1, {
        consumer = ctx.aria_consumer_id,
        model = ctx.aria_provider and ctx.aria_provider.model or "unknown",
        route = ctx.var.route_id,
        status = tostring(math.floor(status / 100)) .. "xx"
    })
    emit_histogram("aria_request_latency_seconds", latency, {
        consumer = ctx.aria_consumer_id,
        model = ctx.aria_provider and ctx.aria_provider.model or "unknown",
        route = ctx.var.route_id
    })
    
    -- BR-SH-009: Check budget thresholds
    if conf.alerts and conf.alerts.thresholds then
        check_alert_thresholds(conf, ctx)
    end
end
```

### 2.5 Internal Functions — Business Rule Mapping

| Function | Business Rule | Decision Matrix | Input | Output |
|----------|--------------|-----------------|-------|--------|
| `check_quota(conf, ctx, consumer)` | BR-SH-005 | DM-SH-006 | consumer_id, quota config | `{exhausted, remaining, period}` |
| `apply_overage_policy(conf, ctx, consumer, quota)` | BR-SH-010 | DM-SH-001 | overage policy, quota state | HTTP response (402/429/200) |
| `scan_prompt_injection(conf, ctx)` | BR-SH-011 | DM-SH-003 | message content, patterns | `{detected, confidence, category}` |
| `grpc_analyze_prompt(ctx, initial)` | BR-SH-011 | DM-SH-004 | prompt content | `{is_injection, score}` or nil |
| `scan_pii_in_prompt(conf, ctx)` | BR-SH-012 | DM-SH-003 | message content, PII patterns | `{detected, pii_type, matches}` |
| `mask_pii_in_request(ctx, pii)` | BR-SH-012 | — | PII matches | Modified request body |
| `apply_model_pin(ctx, pin)` | BR-SH-018 | — | model pin config | Modified model in request |
| `select_provider(conf, ctx)` | BR-SH-001, 016, 017 | DM-SH-002 | routing strategy, providers | Selected provider |
| `transform_request(ctx, provider)` | BR-SH-001 | — | canonical request, provider type | Transformed request |
| `transform_response(ctx, body, provider)` | BR-SH-004 | — | provider response | OpenAI-format response |
| `approximate_token_count(text)` | BR-SH-006 | — | text string | Approximate token int |
| `calculate_cost(conf, model, usage)` | BR-SH-007 | — | model, token counts | Dollar amount (decimal) |
| `update_quota(ctx, tokens)` | BR-SH-005 | — | token count | Redis INCRBY |
| `check_alert_thresholds(conf, ctx)` | BR-SH-009 | — | thresholds, current usage | Alert sent or skipped |
| `record_audit_event(ctx, type, details)` | BR-SH-015 | — | event type, masked details | Postgres write (async) |

### 2.6 Circuit Breaker Implementation (BR-SH-002)

```lua
-- Redis-backed circuit breaker state
-- Key: aria:cb:{provider}:{route} = {state, failures, opened_at, last_probe}

local function check_circuit_breaker(provider_name, route_id, conf)
    local key = "aria:cb:" .. provider_name .. ":" .. route_id
    local state = redis:hgetall(key)
    
    if not state or state.state == "CLOSED" then
        return "CLOSED"  -- Allow traffic to this provider
    end
    
    if state.state == "OPEN" then
        local elapsed = ngx.now() - tonumber(state.opened_at)
        if elapsed >= conf.circuit_breaker.cooldown_seconds then
            -- Transition to HALF_OPEN: send probe
            redis:hset(key, "state", "HALF_OPEN")
            return "HALF_OPEN"
        end
        return "OPEN"  -- Still cooling down
    end
    
    return state.state  -- HALF_OPEN
end

local function record_provider_result(provider_name, route_id, success, conf)
    local key = "aria:cb:" .. provider_name .. ":" .. route_id
    
    if success then
        -- Reset on success
        redis:hmset(key, {state = "CLOSED", failures = 0})
        emit_metric("aria_circuit_breaker_state", 0, {provider = provider_name})
    else
        local failures = redis:hincrby(key, "failures", 1)
        if failures >= conf.circuit_breaker.failure_threshold then
            redis:hmset(key, {state = "OPEN", opened_at = tostring(ngx.now())})
            emit_metric("aria_circuit_breaker_state", 1, {provider = provider_name})
        end
    end
    redis:expire(key, 600)  -- 10 min TTL
end
```

### 2.7 Provider Transformation Functions (BR-SH-001)

```lua
-- Provider transformation registry
local transformers = {
    openai = {
        transform_request = function(ctx, body)
            -- Pass through: OpenAI is the canonical format
            return body
        end,
        transform_response = function(ctx, body)
            return body  -- Already in OpenAI format
        end
    },
    anthropic = {
        transform_request = function(ctx, body)
            -- Extract system messages → top-level "system" field
            local system_msgs = {}
            local messages = {}
            for _, msg in ipairs(body.messages) do
                if msg.role == "system" then
                    table.insert(system_msgs, msg.content)
                else
                    table.insert(messages, msg)
                end
            end
            return {
                model = body.model,
                system = table.concat(system_msgs, "\n"),
                messages = messages,
                max_tokens = body.max_tokens or 4096,
                temperature = body.temperature,
                top_p = body.top_p,
                stream = body.stream
            }
        end,
        transform_response = function(ctx, body)
            -- Anthropic → OpenAI format (see BR-SH-004 mapping table)
            return {
                id = body.id,
                object = "chat.completion",
                created = ngx.time(),
                model = body.model,
                choices = {{
                    index = 0,
                    message = {
                        role = "assistant",
                        content = body.content[1] and body.content[1].text or ""
                    },
                    finish_reason = anthropic_stop_reason_map[body.stop_reason] or "stop"
                }},
                usage = {
                    prompt_tokens = body.usage and body.usage.input_tokens or 0,
                    completion_tokens = body.usage and body.usage.output_tokens or 0,
                    total_tokens = (body.usage and body.usage.input_tokens or 0) +
                                   (body.usage and body.usage.output_tokens or 0)
                }
            }
        end
    },
    -- google, azure_openai, ollama: similar pattern
}
```

---

## 3. Module B: aria-mask.lua — Detailed Design

### 3.1 Lua Module Structure

```lua
-- aria-mask.lua
local _M = {}

_M.version = "0.1.0"
_M.priority = 1000  -- Lower than Shield: run after Shield on same route
_M.name = "aria-mask"
_M.schema = { ... }

function _M.access(conf, ctx)           -- Read consumer role, load policy
function _M.body_filter(conf, ctx)      -- BR-MK-001, 002, 003, 004
function _M.log(conf, ctx)              -- BR-MK-005

return _M
```

### 3.2 Function Design — body_filter Phase

```lua
-- BR-MK-001, BR-MK-002, BR-MK-003, BR-MK-004
function _M.body_filter(conf, ctx)
    -- Gate: only process JSON responses
    local content_type = ngx.header["Content-Type"] or ""
    if not content_type:find("application/json") then
        return  -- Pass through non-JSON
    end
    
    -- Gate: skip oversized responses (DM-MK-003 row 5)
    local body = core.response.hold_body_chunk(ctx)
    if not body then return end
    if #body > conf.max_body_size then
        emit_metric("aria_mask_skip_large_body", 1)
        return
    end
    
    -- Parse JSON
    local ok, json_body = pcall(cjson.decode, body)
    if not ok then return end  -- Non-parseable JSON, pass through
    
    -- BR-MK-002: Resolve role policy
    local role = ctx.aria_consumer_role or "unknown"
    local policy = resolve_role_policy(conf, role)
    -- Maps to: BR-MK-002 flowchart and DM-MK-001
    
    local masked_fields = {}
    
    -- BR-MK-001: Apply explicit JSONPath rules
    for _, rule in ipairs(conf.rules) do
        local strategy = get_strategy_for_role(policy, rule.field_type, rule.strategy)
        if strategy ~= "full" then
            local matches = jsonpath.query(json_body, rule.path)
            for _, match in ipairs(matches) do
                local masked_value = apply_mask_strategy(strategy, match.value, rule.field_type)
                jsonpath.set(json_body, match.path, masked_value)
                table.insert(masked_fields, {
                    path = match.path,
                    strategy = strategy,
                    rule_id = rule.id,
                    pii_type = rule.field_type,
                    source = "explicit_rule"
                })
            end
        end
    end
    
    -- BR-MK-003: Auto-detect PII patterns (if enabled)
    if conf.auto_detect and conf.auto_detect.enabled then
        local pii_matches = detect_pii_patterns(json_body, conf.auto_detect)
        for _, pii in ipairs(pii_matches) do
            -- Skip already-masked fields
            if not is_already_masked(masked_fields, pii.path) then
                local strategy = get_strategy_for_role(policy, pii.pii_type, nil)
                if strategy ~= "full" then
                    local masked_value = apply_mask_strategy(strategy, pii.value, pii.pii_type)
                    jsonpath.set(json_body, pii.path, masked_value)
                    table.insert(masked_fields, {
                        path = pii.path,
                        strategy = strategy,
                        rule_id = "auto:" .. pii.pii_type,
                        pii_type = pii.pii_type,
                        source = "auto_detect"
                    })
                end
            end
        end
    end
    
    -- Serialize and replace body
    if #masked_fields > 0 then
        ngx.arg[1] = cjson.encode(json_body)
    end
    
    -- Store for log phase (BR-MK-005)
    ctx.aria_masked_fields = masked_fields
end
```

### 3.3 Mask Strategy Implementation (BR-MK-004)

```lua
local mask_strategies = {
    last4 = function(value, field_type)
        local s = tostring(value)
        if #s <= 4 then return s end
        return string.rep("*", #s - 4) .. s:sub(-4)
    end,
    
    first2last2 = function(value, field_type)
        local s = tostring(value)
        if #s <= 4 then return s end
        return s:sub(1, 2) .. string.rep("*", #s - 4) .. s:sub(-2)
    end,
    
    hash = function(value, field_type)
        local salt = get_hash_salt()  -- From APISIX secrets
        local hash = ngx.sha1_bin(salt .. tostring(value))
        return ngx.encode_base16(hash):sub(1, 16)  -- First 16 hex chars
    end,
    
    redact = function(value, field_type)
        return "[REDACTED]"
    end,
    
    tokenize = function(value, field_type)
        local token_id = "tok_" .. generate_random_id(12)
        local encrypted = aes_encrypt(tostring(value))  -- AES-256
        local ok = redis:set("aria:tokenize:" .. token_id, encrypted, "EX", token_ttl)
        if not ok then
            log_warn("tokenize_redis_unavailable", "falling back to redact")
            return "[REDACTED]"  -- DM-MK-002 fallback
        end
        return token_id
    end,
    
    ["mask:email"] = function(value)
        -- john.doe@example.com → j***@e***.com
        local local_part, domain = value:match("^(.-)@(.+)$")
        if not local_part then return "[REDACTED]" end
        local d_parts = {}
        for part in domain:gmatch("[^.]+") do table.insert(d_parts, part) end
        return local_part:sub(1,1) .. "***@" .. d_parts[1]:sub(1,1) .. "***." .. d_parts[#d_parts]
    end,
    
    ["mask:phone"] = function(value)
        -- +905321234567 → +90532***4567
        local cleaned = value:gsub("[%s%-%(%)]+", "")
        if #cleaned < 10 then return "[REDACTED]" end
        return cleaned:sub(1, 5) .. "***" .. cleaned:sub(-4)
    end,
    
    ["mask:national_id"] = function(value)
        -- 12345678901 → ****56789**
        local s = tostring(value)
        if #s ~= 11 then return "[REDACTED]" end
        return "****" .. s:sub(5, 9) .. "**"
    end,
    
    ["mask:iban"] = function(value)
        -- TR330006100519786457841326 → TR33****1326
        local s = tostring(value)
        if #s < 8 then return "[REDACTED]" end
        return s:sub(1, 4) .. string.rep("*", #s - 8) .. s:sub(-4)
    end,
    
    ["mask:ip"] = function(value)
        -- 192.168.1.100 → 192.168.*.*
        local octets = {}
        for o in value:gmatch("%d+") do table.insert(octets, o) end
        if #octets ~= 4 then return value end
        return octets[1] .. "." .. octets[2] .. ".*.*"
    end,
    
    ["mask:dob"] = function(value)
        -- 1990-05-13 → ****-**-13
        return "****-**-" .. (value:match("%-(%d+)$") or "**")
    end,
}

local function apply_mask_strategy(strategy_name, value, field_type)
    if value == nil or value == cjson.null then return value end
    local fn = mask_strategies[strategy_name]
    if not fn then
        log_warn("unknown_mask_strategy", strategy_name)
        return "[REDACTED]"  -- Fail-safe
    end
    return fn(value, field_type)
end
```

---

## 4. Module C: aria-canary.lua — Detailed Design

### 4.1 Lua Module Structure

```lua
-- aria-canary.lua
local _M = {}

_M.version = "0.1.0"
_M.priority = 3000  -- Highest priority: routing decision before all others
_M.name = "aria-canary"
_M.schema = { ... }

function _M.access(conf, ctx)           -- BR-CN-001: Route decision
function _M.header_filter(conf, ctx)    -- Tag response with version
function _M.log(conf, ctx)              -- BR-CN-002, 003, 004: Error/latency tracking

return _M
```

### 4.2 Function Design — access Phase (Routing Decision)

```lua
-- BR-CN-001: Progressive traffic splitting
function _M.access(conf, ctx)
    -- Read canary state from Redis
    local state_key = "aria:canary:" .. ctx.var.route_id
    local canary_state = redis:hgetall(state_key)
    
    if not canary_state or canary_state.state == nil then
        -- No canary configured — route to default upstream
        return
    end
    
    if canary_state.state == "ROLLED_BACK" or canary_state.state == "PROMOTED" then
        if canary_state.state == "PROMOTED" then
            set_upstream_to(ctx, conf.canary_upstream)
        end
        -- ROLLED_BACK → default upstream (baseline)
        return
    end
    
    -- STAGE_N or PAUSED: apply traffic split
    local traffic_pct = tonumber(canary_state.traffic_pct) or 0
    local use_canary = false
    
    if conf.consistent_hash then
        -- Consistent hashing: same client → same version within a stage
        local hash = ngx.crc32_long(ctx.var.remote_addr)
        use_canary = (hash % 100) < traffic_pct
    else
        use_canary = math.random(100) <= traffic_pct
    end
    
    if use_canary then
        set_upstream_to(ctx, conf.canary_upstream)
        ctx.aria_canary_version = "canary"
    else
        set_upstream_to(ctx, conf.baseline_upstream)
        ctx.aria_canary_version = "baseline"
    end
    
    -- Shadow traffic (BR-CN-006)
    if conf.shadow and conf.shadow.enabled then
        if math.random(100) <= conf.shadow.shadow_pct then
            fire_and_forget_shadow(ctx, conf.shadow.shadow_upstream)
        end
    end
end
```

### 4.3 Function Design — log Phase (Monitoring & Progression)

```lua
-- BR-CN-002, BR-CN-003, BR-CN-004
function _M.log(conf, ctx)
    local version = ctx.aria_canary_version
    if not version then return end
    
    local route_id = ctx.var.route_id
    local status = ngx.status
    local latency = ngx.now() - ctx.aria_request_start
    
    -- Track error rate per version (BR-CN-002)
    local window = math.floor(ngx.now() / 10) * 10  -- 10-second windows
    local error_key = "aria:canary:errors:" .. route_id .. ":" .. version .. ":" .. window
    
    if status >= 500 then
        redis:incr(error_key)
    end
    redis:incr(error_key .. ":total")
    redis:expire(error_key, 120)  -- 2 min TTL
    redis:expire(error_key .. ":total", 120)
    
    -- Track latency per version (BR-CN-004)
    local latency_key = "aria:canary:latency:" .. route_id .. ":" .. version
    redis:zadd(latency_key, ngx.now(), latency)
    redis:expire(latency_key, 600)  -- 10 min TTL
    
    -- Emit metrics
    emit_metric("aria_canary_error_rate", status >= 500 and 1 or 0, {
        route = route_id, version = version
    })
    
    -- Check stage progression (only one worker should do this — use Redis lock)
    if version == "canary" then
        check_stage_progression(conf, ctx, route_id)
    end
end

-- BR-CN-001 state machine progression + BR-CN-003 auto-rollback
local function check_stage_progression(conf, ctx, route_id)
    -- Acquire lock (only one APISIX worker checks per interval)
    local lock_key = "aria:canary:lock:" .. route_id
    local acquired = redis:set(lock_key, "1", "NX", "EX", 5)
    if not acquired then return end
    
    local state_key = "aria:canary:" .. route_id
    local state = redis:hgetall(state_key)
    if state.state ~= "STAGE_N" then return end  -- Simplified: check actual stage state
    
    -- BR-CN-002: Calculate error rates
    local canary_rate = calculate_error_rate(route_id, "canary")
    local baseline_rate = calculate_error_rate(route_id, "baseline")
    
    -- DM-CN-003: Both unhealthy?
    if baseline_rate > 0.10 then
        send_alert("baseline_unhealthy", route_id, canary_rate, baseline_rate)
        return  -- Don't rollback canary for baseline problems
    end
    
    -- DM-CN-001: Error delta check
    local delta = canary_rate - baseline_rate
    if delta > (conf.error_monitor.threshold_pct / 100) then
        -- PAUSE or ROLLBACK
        local breach_key = "aria:canary:breach:" .. route_id
        local breach_start = redis:get(breach_key)
        if not breach_start then
            redis:set(breach_key, tostring(ngx.now()), "EX", 300)
            redis:hset(state_key, "state", "PAUSED")
            send_alert("canary_paused", route_id, canary_rate, baseline_rate)
        else
            local sustained = ngx.now() - tonumber(breach_start)
            if sustained >= conf.error_monitor.sustained_breach_seconds then
                -- BR-CN-003: AUTO-ROLLBACK
                redis:hmset(state_key, {state = "ROLLED_BACK", traffic_pct = "0"})
                redis:del(breach_key)
                emit_metric("aria_canary_rollback_total", 1, {route = route_id})
                send_rollback_notification(conf, route_id, canary_rate, baseline_rate)
            end
        end
        return
    end
    
    -- Clear any breach timer (recovered)
    redis:del("aria:canary:breach:" .. route_id)
    
    -- Check hold duration
    local stage_started = tonumber(state.stage_started_at)
    local hold_seconds = parse_duration(state.current_hold)
    if (ngx.now() - stage_started) >= hold_seconds then
        -- BR-CN-004: Latency guard check
        if conf.latency_guard and conf.latency_guard.enabled then
            local canary_p95 = calculate_p95(route_id, "canary")
            local baseline_p95 = calculate_p95(route_id, "baseline")
            if canary_p95 > baseline_p95 * conf.latency_guard.multiplier then
                redis:hset(state_key, "state", "PAUSED")
                send_alert("latency_breach", route_id, canary_p95, baseline_p95)
                return
            end
        end
        
        -- ADVANCE to next stage
        advance_canary_stage(state_key, state)
    end
end
```

---

## 5. Aria Runtime (Java 21 Sidecar) — Detailed Design

### 5.1 Java Class Hierarchy

```
AriaException (abstract)
├── ValidationException (400)
├── BusinessException (422)
├── ResourceNotFoundException (404)
├── SystemException (500)
└── ExternalServiceException (502/503/504)

AriaRuntimeApplication
├── core/
│   ├── GrpcServer           -- UDS listener, handler registration
│   │   ├── start()          -- Bind to UDS, register services
│   │   ├── stop()           -- Graceful drain
│   │   └── registerService(BindableService)
│   ├── HealthController     -- HTTP /healthz, /readyz
│   │   ├── liveness()       -- Always 200 if JVM alive
│   │   └── readiness()      -- 200 if Redis+Postgres reachable
│   ├── ShutdownManager      -- SIGTERM handler
│   │   └── onShutdown()     -- Set readiness=503, drain, close connections
│   └── RequestContext       -- ScopedValue definitions
│       ├── CONSUMER_ID      -- ScopedValue<String>
│       ├── ROUTE_ID         -- ScopedValue<String>
│       ├── REQUEST_ID       -- ScopedValue<String>
│       └── run(Runnable, values) -- Execute with scoped context
├── shield/
│   ├── PromptAnalyzer       -- gRPC ShieldService.AnalyzePrompt
│   │   ├── analyzePrompt(PromptAnalysisRequest)
│   │   ├── vectorSimilarity(String content, List<String> patterns)
│   │   └── calculateConfidence(double similarity) → float
│   ├── TokenCounter         -- gRPC ShieldService.CountTokens
│   │   ├── countTokens(TokenCountRequest)
│   │   ├── getTokenizer(String model) → Tokenizer
│   │   └── reconcile(String consumerId, int exact, int approximate)
│   └── ContentFilter        -- gRPC ShieldService.FilterResponse
│       ├── filterResponse(ContentFilterRequest)
│       └── classifyContent(String content) → ContentCategory
├── mask/
│   └── NerDetector          -- gRPC MaskService.DetectPII
│       ├── detectPII(PiiDetectionRequest)
│       └── extractEntities(String text) → List<PiiEntity>
├── canary/
│   └── DiffEngine           -- gRPC CanaryService.DiffResponses
│       ├── diffResponses(DiffRequest)
│       ├── compareStatus(int a, int b) → boolean
│       ├── compareBodyStructure(byte[] a, byte[] b) → float
│       └── summarizeDiff(DiffResult) → String
└── common/
    ├── RedisClient           -- Async Redis operations (Lettuce)
    │   ├── get(String key) → CompletableFuture<String>
    │   ├── incrBy(String key, long amount) → CompletableFuture<Long>
    │   └── close()
    ├── PostgresClient        -- Async Postgres operations (R2DBC or async JDBC)
    │   ├── insertAuditEvent(AuditEvent) → CompletableFuture<Void>
    │   ├── insertBillingRecord(BillingRecord) → CompletableFuture<Void>
    │   └── close()
    └── AriaException         -- Exception hierarchy
```

### 5.2 gRPC Server Implementation (BR-RT-001)

```java
public class GrpcServer {
    private final Server server;
    private final String udsPath;
    
    public GrpcServer(String udsPath, List<BindableService> services) {
        this.udsPath = udsPath;
        var builder = NettyServerBuilder
            .forAddress(new DomainSocketAddress(udsPath))
            .executor(Executors.newVirtualThreadPerTaskExecutor())  // BR-RT-002
            .addService(new HealthServiceImpl());
        
        for (var service : services) {
            builder.addService(service);
        }
        
        this.server = builder.build();
    }
    
    public void start() throws IOException {
        // Ensure parent directory exists
        Files.createDirectories(Path.of(udsPath).getParent());
        server.start();
        
        // Set socket permissions (0660)
        Files.setPosixFilePermissions(Path.of(udsPath),
            PosixFilePermissions.fromString("rw-rw----"));
    }
}
```

### 5.3 Token Counter Implementation (BR-SH-006)

```java
public class TokenCounter extends ShieldServiceGrpc.ShieldServiceImplBase {
    
    private final Map<String, Tokenizer> tokenizers = new ConcurrentHashMap<>();
    private final RedisClient redis;
    private final PostgresClient postgres;
    
    @Override
    public void countTokens(TokenCountRequest request,
                           StreamObserver<TokenCountResponse> observer) {
        // BR-RT-002: Runs on virtual thread via executor
        ScopedValue.runWhere(RequestContext.REQUEST_ID, request.getRequestId(), () -> {
            try {
                var tokenizer = getTokenizer(request.getModel());
                int exact = tokenizer.encode(request.getContent()).size();
                int delta = exact - request.getLuaApproximateCount();
                
                // Reconcile in Redis (BR-SH-006)
                if (delta != 0) {
                    var quotaKey = buildQuotaKey(request.getConsumerId());
                    redis.incrBy(quotaKey, delta);  // Correct the Lua estimate
                }
                
                // Write billing record to Postgres
                postgres.insertBillingRecord(BillingRecord.builder()
                    .consumerId(request.getConsumerId())
                    .model(request.getModel())
                    .tokensInput(request.getInputTokens())
                    .tokensOutput(request.getOutputTokens())
                    .isReconciled(true)
                    .build());
                
                observer.onNext(TokenCountResponse.newBuilder()
                    .setExactTokenCount(exact)
                    .setDelta(delta)
                    .build());
                observer.onCompleted();
                
            } catch (Exception e) {
                observer.onError(Status.INTERNAL
                    .withDescription("Token counting failed: " + e.getMessage())
                    .asRuntimeException());
            }
        });
    }
    
    private Tokenizer getTokenizer(String model) {
        // Cache tokenizers per model family
        return tokenizers.computeIfAbsent(
            getModelFamily(model),
            family -> TiktokenRegistry.getEncoding(family)
        );
    }
}
```

### 5.4 Graceful Shutdown (BR-RT-004)

```java
public class ShutdownManager {
    private final GrpcServer grpcServer;
    private final HealthController health;
    private final RedisClient redis;
    private final PostgresClient postgres;
    private final int graceSeconds;
    
    public void onShutdown() {
        // Step 1: Set readiness to 503
        health.setReady(false);
        
        // Step 2: Stop accepting new requests
        grpcServer.getServer().shutdown();
        
        // Step 3: Wait for in-flight requests
        try {
            boolean terminated = grpcServer.getServer()
                .awaitTermination(graceSeconds, TimeUnit.SECONDS);
            if (!terminated) {
                grpcServer.getServer().shutdownNow();  // Force after grace period
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            grpcServer.getServer().shutdownNow();
        }
        
        // Step 4: Close connections
        redis.close();
        postgres.close();
        
        // Step 5: Remove UDS socket file
        Files.deleteIfExists(Path.of(grpcServer.getUdsPath()));
    }
}
```

---

## 6. Shared Library: aria-core.lua

```lua
-- aria-core.lua — Shared utilities used by all three plugins

local _M = {}

-- Redis connection (reused across requests via cosocket pool)
function _M.get_redis()
    -- Returns pooled Redis connection from APISIX Redis cluster config
end

-- Prometheus metric emission (fire-and-forget)
function _M.emit_metric(name, value, labels)
    -- Uses APISIX's built-in Prometheus integration
    -- Checks cardinality limit (10K unique label combinations)
end

function _M.emit_histogram(name, value, labels)
end

-- Error response helper
function _M.error_response(ctx, status, code, message)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        error = {
            type = "aria_error",
            code = code,
            message = message or default_messages[code],
            aria_request_id = ctx.var.request_id
        }
    }))
    return ngx.exit(status)
end

-- gRPC/UDS client (lazy connection)
function _M.grpc_call(service, method, request)
    -- Returns response or nil (sidecar unavailable)
    -- Implements deadline (500ms default)
end

-- Async audit event (fire-and-forget to sidecar → Postgres)
function _M.record_audit_event(ctx, event_type, details)
    -- Mask PII in details before sending
    -- If sidecar unavailable, attempt direct Redis buffer
end

return _M
```

---

## 7. Shared Library: aria-pii.lua

```lua
-- aria-pii.lua — PII regex patterns shared by Shield (prompt scan) and Mask (response scan)

local patterns = {
    pan = {
        regex = [[\b[3-6]\d{12,18}\b]],
        validator = function(match) return luhn_check(match) end,
        field_type = "pan",
        classification = "L4"
    },
    msisdn = {
        regex = [[\+?90\s?5\d{2}\s?\d{3}\s?\d{2}\s?\d{2}]],
        validator = function(match) return #match:gsub("%D", "") >= 10 end,
        field_type = "phone",
        classification = "L3"
    },
    tc_kimlik = {
        regex = [[\b\d{11}\b]],
        validator = function(match) return tc_kimlik_checksum(match) end,
        field_type = "national_id",
        classification = "L3"
    },
    email = {
        regex = [[\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b]],
        validator = nil,  -- Regex is sufficient
        field_type = "email",
        classification = "L3"
    },
    iban_tr = {
        regex = [[\bTR\d{2}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{2}\b]],
        validator = function(match) return #match:gsub("%s", "") == 26 end,
        field_type = "iban",
        classification = "L3"
    },
    imei = {
        regex = [[\b\d{15}\b]],
        validator = function(match) return luhn_check(match:sub(1, 14)) end,
        field_type = "imei",
        classification = "L3"
    },
    ip_address = {
        regex = [[\b(?:\d{1,3}\.){3}\d{1,3}\b]],
        validator = function(match)
            for octet in match:gmatch("%d+") do
                if tonumber(octet) > 255 then return false end
            end
            return true
        end,
        field_type = "ip",
        classification = "L3"
    },
    dob = {
        regex = [[\b(19|20)\d{2}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\b]],
        validator = nil,
        field_type = "dob",
        classification = "L3"
    },
}
```

---

## 8. Configuration Validation

### 8.1 Shield Configuration JSON Schema

```json
{
  "type": "object",
  "required": ["provider"],
  "properties": {
    "provider": {
      "type": "string",
      "enum": ["openai", "anthropic", "google", "azure_openai", "ollama"]
    },
    "provider_config": {
      "type": "object",
      "required": ["endpoint"],
      "properties": {
        "endpoint": { "type": "string", "format": "uri" },
        "api_key_secret": { "type": "string", "pattern": "^\\$secret://" },
        "timeout_ms": { "type": "integer", "minimum": 1000, "maximum": 120000, "default": 30000 }
      }
    },
    "quota": {
      "type": "object",
      "properties": {
        "daily_tokens": { "type": "integer", "minimum": 1, "maximum": 10000000000 },
        "monthly_tokens": { "type": "integer", "minimum": 1, "maximum": 100000000000 },
        "monthly_dollars": { "type": "number", "minimum": 0.01 },
        "overage_policy": { "type": "string", "enum": ["block", "throttle", "allow"], "default": "block" },
        "fail_policy": { "type": "string", "enum": ["fail_open", "fail_closed"], "default": "fail_open" }
      }
    },
    "security": {
      "type": "object",
      "properties": {
        "prompt_injection": {
          "type": "object",
          "properties": {
            "enabled": { "type": "boolean", "default": false },
            "action": { "type": "string", "enum": ["block"], "default": "block" }
          }
        },
        "pii_scanner": {
          "type": "object",
          "properties": {
            "enabled": { "type": "boolean", "default": false },
            "action": { "type": "string", "enum": ["block", "mask", "warn"], "default": "mask" }
          }
        }
      }
    },
    "routing": {
      "type": "object",
      "properties": {
        "strategy": { "type": "string", "enum": ["direct", "failover", "latency", "cost"], "default": "direct" }
      }
    }
  }
}
```

---

## 9. Performance Design Decisions

| Concern | Decision | Rationale |
|---------|----------|-----------|
| Redis connection pooling | APISIX cosocket pool (max 100 connections per worker) | Reuse connections across requests |
| JSON parsing in Mask | Single-pass parse + rewrite (no intermediate objects) | O(n) memory, minimize GC |
| Prometheus cardinality | Check `aria_metrics_count` before emitting. Drop if > 10K | Prevent Prometheus OOM |
| Canary error tracking | 10-second Redis counters with 2m TTL | Bounded memory, automatic cleanup |
| SSE streaming | No buffering — forward each `ngx.arg[1]` chunk immediately | O(1) memory per stream |
| Sidecar gRPC deadline | 500ms default, configurable | Fail fast if sidecar is slow |
| Virtual thread per request | No pooling — JVM manages scheduling | Virtual threads are ~1KB each |

---

## 10. Testing Strategy

### 10.1 Unit Tests

| Module | Framework | Coverage Target | Key Tests |
|--------|-----------|----------------|-----------|
| Lua plugins | busted (Lua test framework) | > 80% | Mask strategies, PII regex, provider transforms, quota logic |
| Java sidecar | JUnit 5 + Mockito | > 80% | Token counting, NER detection, diff engine, gRPC handlers |
| ariactl | Go testing | > 70% | Command parsing, API client, output formatting |

### 10.2 Integration Tests

| Test Suite | Environment | Key Scenarios |
|-----------|-------------|---------------|
| Shield e2e | APISIX + Redis + mock LLM | Request routing, quota enforcement, failover, streaming |
| Mask e2e | APISIX + Redis + upstream mock | JSONPath masking, role policies, PII detection, tokenization |
| Canary e2e | APISIX + Redis + two upstreams | Stage progression, auto-rollback, manual override |
| Sidecar e2e | Java + Redis + Postgres | gRPC handlers, token counting, audit persistence |

### 10.3 Performance Tests

| Test | Tool | Target | Scenario |
|------|------|--------|----------|
| Shield latency overhead | wrk2 / k6 | < 5ms P95 | 1000 req/s through Shield vs. direct |
| Mask throughput | k6 | < 1ms P95 for 50KB body | 1000 req/s with 10 masking rules |
| Canary routing accuracy | Custom script | < 1% variance | 10K requests, verify traffic split |
| SSE streaming | Custom client | < 1ms per chunk | 100 concurrent streams |

---

## 11. Traceability Matrix

| Business Rule | LLD Section | Function / Class | Test |
|--------------|-------------|-----------------|------|
| BR-SH-001 | 2.2, 2.7 | `_M.access()`, `transform_request()`, `transformers.*` | Shield e2e: routing |
| BR-SH-002 | 2.6 | `check_circuit_breaker()`, `record_provider_result()` | Shield e2e: failover |
| BR-SH-003 | 2.3 | `_M.body_filter()` (streaming branch) | SSE streaming test |
| BR-SH-004 | 2.7 | `transformers.*.transform_response()` | Unit: response mapping |
| BR-SH-005 | 2.2 | `check_quota()` | Shield e2e: quota |
| BR-SH-006 | 5.3 | `TokenCounter.countTokens()` | Sidecar e2e: reconciliation |
| BR-SH-007 | 2.3 | `calculate_cost()` | Unit: cost calculation |
| BR-SH-010 | 2.2 | `apply_overage_policy()` | Shield e2e: overage |
| BR-SH-011 | 2.2 | `scan_prompt_injection()`, `grpc_analyze_prompt()` | Shield e2e: injection |
| BR-SH-012 | 2.2 | `scan_pii_in_prompt()`, `mask_pii_in_request()` | Shield e2e: PII |
| BR-SH-015 | 2.4 | `record_audit_event()` | Sidecar e2e: audit |
| BR-MK-001 | 3.2 | `_M.body_filter()` | Mask e2e: JSONPath |
| BR-MK-002 | 3.2 | `resolve_role_policy()` | Mask e2e: roles |
| BR-MK-003 | 3.2, 7 | `detect_pii_patterns()`, `aria-pii.lua` | Unit: PII regex |
| BR-MK-004 | 3.3 | `apply_mask_strategy()`, `mask_strategies.*` | Unit: strategies |
| BR-MK-005 | 3.2 | `_M.log()` | Mask e2e: audit |
| BR-CN-001 | 4.2, 4.3 | `_M.access()`, `check_stage_progression()` | Canary e2e: progression |
| BR-CN-002 | 4.3 | `calculate_error_rate()` | Canary e2e: error rate |
| BR-CN-003 | 4.3 | `check_stage_progression()` (rollback branch) | Canary e2e: rollback |
| BR-CN-004 | 4.3 | `calculate_p95()` | Canary e2e: latency guard |
| BR-RT-001 | 5.2 | `GrpcServer` | Sidecar e2e: gRPC |
| BR-RT-002 | 5.2 | `newVirtualThreadPerTaskExecutor()` | Sidecar e2e: concurrency |
| BR-RT-004 | 5.4 | `ShutdownManager.onShutdown()` | Sidecar e2e: shutdown |

---

*Document Version: 1.0 | Created: 2026-04-08*
*Status: Draft — Pending Human Approval*
