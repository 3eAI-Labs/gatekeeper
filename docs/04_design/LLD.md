# Low-Level Design (LLD) — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 4 — Low-Level Design
**Version:** 1.1
**Date:** 2026-04-25 (revised); 2026-04-08 (v1.0 baseline)
**Input:** HLD.md v1.1, BUSINESS_LOGIC.md v1.0, DECISION_MATRIX.md v1.0
**v1.1 Driver:** PHASE_REVIEW_2026-04-25 adversarial drift audit. Reconciles to shipped reality: HTTP bridge over gRPC for Lua transport (ADR-008), mask NER pipeline (BR-MK-006), canary admin control_api (BR-CN-005), shadow diff structural compare (BR-CN-007), `aria-circuit-breaker.lua` shared lib, audit pipeline gap acknowledgment, Karar A `cl100k_base` fallback, ariactl deferred.

---

## 1. Project Structure

```
3e-aria-gatekeeper/                  # Lua plugins repo (Apache 2.0, public)
├── apisix/
│   └── plugins/
│       ├── aria-shield.lua          # Module A: AI governance plugin
│       ├── aria-mask.lua            # Module B: Data masking plugin (incl. NER bridge)
│       ├── aria-canary.lua          # Module C: Progressive delivery plugin (incl. control_api §4.4)
│       └── lib/
│           ├── aria-core.lua        # Shared utilities (Redis, metrics, audit buffer)
│           ├── aria-provider.lua    # Provider transformation logic (5 LLM providers)
│           ├── aria-pii.lua         # PII regex patterns (shared by Shield + Mask)
│           ├── aria-quota.lua       # Quota check / overage policy / cost calc
│           ├── aria-mask-strategies.lua  # 12 masking strategies (last4, hash, redact, …)
│           └── aria-circuit-breaker.lua  # NEW 2026-04-24 — generic per-endpoint breaker (ngx.shared.dict-backed); reused by mask NER bridge and (planned) all future Lua↔sidecar HTTP bridges. See §8.
├── runtime/                         # Operator deployment artefacts (this repo)
│   ├── apisix.yaml                  # Standalone YAML routes config
│   ├── docker-compose.yaml
│   ├── docs/{CONFIGURATION,DEPLOYMENT,NER_MODELS}.md
│   ├── helm/aria-gatekeeper/        # Sidecar Helm chart (Chart.yaml, templates/, values.yaml)
│   └── dashboards/                  # Grafana JSONs: shield, mask, canary
├── docs/                            # Phase 1-6 deliverables (this repo)
└── db/
    └── migration/                   # Flyway-format SQL (auto-applied by migration-job in Helm chart, not by sidecar startup yet — see §5.4 + Phase 6 FINDING-005)
        ├── V001__create_schema_and_enums.sql
        ├── V002__create_billing_and_masking_tables.sql
        └── V003__create_partitions_and_maintenance.sql

aria-runtime/                        # Java 21 sidecar repo (proprietary, separate)
├── build.gradle.kts                 # Gradle 9.4.1, toolchain Java 21
├── src/main/java/com/eai/aria/runtime/
│   ├── AriaRuntimeApplication.java  # Spring Boot @SpringBootApplication entry
│   ├── core/
│   │   ├── GrpcServer.java          # gRPC listener (forward-compat per ADR-008; no Lua callers in v0.1)
│   │   ├── GrpcExceptionInterceptor.java
│   │   ├── HealthController.java    # HTTP /healthz, /readyz
│   │   ├── ShutdownManager.java     # SIGTERM grace drain
│   │   └── RequestContext.java      # ScopedValue definitions
│   ├── shield/
│   │   ├── ShieldServiceImpl.java   # gRPC ShieldService — analyzePrompt + filterResponse are STUBS (return safe defaults; v0.3 enables real detection); countTokens delegates to TokenEncoder
│   │   └── TokenEncoder.java        # REAL — jtokkit (cl100k_base fallback per Karar A); see §5.3 + §5.3.1
│   ├── mask/
│   │   ├── MaskController.java      # HTTP @RestController POST /v1/mask/detect (Lua-callable, ADR-008)
│   │   ├── MaskServiceImpl.java     # gRPC MaskService.DetectPII — delegates to NerDetectionService; forward-compat
│   │   └── ner/                     # NER pipeline (BR-MK-006), shipped 2026-04-24
│   │       ├── NerEngine.java                # Interface
│   │       ├── NerEngineRegistry.java        # Spring-injected List<NerEngine>; filtered by config
│   │       ├── NerDetectionService.java      # Domain @Service shared by HTTP + gRPC
│   │       ├── NerProperties.java            # @ConfigurationProperties for aria.mask.ner.*
│   │       ├── PiiEntity.java                # Detected entity DTO
│   │       ├── CompositeNerEngine.java       # Unions+dedupes results from registered engines
│   │       ├── OpenNlpNerEngine.java         # English NER (Apache OpenNLP)
│   │       └── DjlHuggingFaceNerEngine.java  # Multilingual ONNX (Turkish-BERT default, see runtime/docs/NER_MODELS.md)
│   ├── canary/
│   │   ├── CanaryServiceImpl.java   # gRPC CanaryService.DiffResponses — delegates to DiffEngine; forward-compat
│   │   ├── DiffController.java      # HTTP @RestController POST /v1/diff (Lua-callable, ADR-008)
│   │   └── DiffEngine.java          # REAL — structural diff (status, headers, body), shipped 2026-04-22 → 2026-04-23 across Iter 1+2+2c+3
│   ├── common/
│   │   ├── AriaRedisClient.java     # Lettuce async (was "RedisClient" in v1.0 spec)
│   │   ├── PostgresClient.java      # R2DBC async — insertAuditEvent() exists but has 0 callers in v0.1 (FINDING-003)
│   │   └── AriaException.java
│   └── config/
│       └── AriaConfig.java          # @ConfigurationProperties: uds-path, shutdown-grace-seconds, mask.ner.*
├── src/main/proto/
│   ├── shield.proto
│   ├── mask.proto
│   ├── canary.proto
│   └── health.proto
└── src/test/                        # JUnit 5: 121 tests as of 2026-04-24

ariactl/                              # DEFERRED to v0.2 (HLD §3.5, ADR-007). Directory does not exist in v0.1; v0.1 substitute = APISIX Admin API + canary control_api endpoints (§4.4).
```

**Differences vs v1.0 plan worth noting:**
- `aria-grpc.lua` was specified but never written (per ADR-008, Lua uses `resty.http` instead of a gRPC client).
- `aria-circuit-breaker.lua` shipped 2026-04-24 as a new shared lib — see §8.
- `aria-quota.lua` and `aria-mask-strategies.lua` are split-out modules from `aria-core.lua` (organic refactor during Phase 5).
- WASM masking engine (HLD §2.3 / ADR-005) not in v0.1 — Lua + Java sidecar covers the perf envelope.
- Java sidecar shield package was specced as 3 separate classes (`PromptAnalyzer`, `TokenCounter`, `ContentFilter`); shipped as 2 (`ShieldServiceImpl` consolidates the gRPC-side stubs + `TokenEncoder` for the real tiktoken work). Permitted simplification — see §5.1.

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

| Function | Business Rule | Decision Matrix | Input | Output | v0.1 Status |
|----------|--------------|-----------------|-------|--------|-------------|
| `check_quota(conf, ctx, consumer)` | BR-SH-005 | DM-SH-006 | consumer_id, quota config | `{exhausted, remaining, period}` | Shipped |
| `apply_overage_policy(conf, ctx, consumer, quota)` | BR-SH-010 | DM-SH-001 | overage policy, quota state | HTTP response (402/429/200) | Shipped |
| `scan_prompt_injection(conf, ctx)` | BR-SH-011 (Lua tier) | DM-SH-003 | message content, patterns | `{detected, confidence, category}` | Shipped (regex tier; community) |
| `grpc_analyze_prompt(ctx, initial)` | BR-SH-011 (sidecar tier) | DM-SH-004 | prompt content | `{is_injection, score}` or nil | **NOT WIRED in v0.1.** Sidecar stub `ShieldServiceImpl.analyzePrompt` returns `is_injection=false`. Lua-side caller not added because the sidecar response is meaningless until vector-similarity is implemented. **v0.3 (enterprise CISO tier)** enables both sides simultaneously. |
| `scan_pii_in_prompt(conf, ctx)` | BR-SH-012 | DM-SH-003 | message content, PII patterns | `{detected, pii_type, matches}` | Shipped |
| `mask_pii_in_request(ctx, pii)` | BR-SH-012 | — | PII matches | Modified request body | Shipped |
| `apply_model_pin(ctx, pin)` | BR-SH-018 | — | model pin config | Modified model in request | Shipped |
| `select_provider(conf, ctx)` | BR-SH-001, 016, 017 | DM-SH-002 | routing strategy, providers | Selected provider | Shipped |
| `transform_request(ctx, provider)` | BR-SH-001 | — | canonical request, provider type | Transformed request | Shipped (5 providers) |
| `transform_response(ctx, body, provider)` | BR-SH-004 | — | provider response | OpenAI-format response | Shipped |
| `approximate_token_count(text)` | BR-SH-006 | — | text string | Approximate token int | Shipped |
| `calculate_cost(conf, model, usage)` | BR-SH-007 | — | model, token counts | Dollar amount (decimal) | Shipped |
| `update_quota(ctx, tokens)` | BR-SH-005 | — | token count | Redis INCRBY | Shipped |
| `check_alert_thresholds(conf, ctx)` | BR-SH-009 | — | thresholds, current usage | Alert sent or skipped | Shipped |
| `record_audit_event(ctx, type, details)` | BR-SH-015 | — | event type, masked details | Pushes JSON onto Redis list `aria:audit_buffer` (1h TTL). | **Lua side shipped; sidecar consumer NOT IMPLEMENTED in v0.1 (FINDING-003).** Events accumulate in Redis and TTL out without being written to `audit_events` table. v0.2 fix: implement `AuditFlusher` Spring `@Scheduled` bean OR add `POST /v1/audit/event` HTTP bridge per ADR-008 pattern (preferred). See HLD §8.3. |

**v0.1 implementation status legend.** Rows marked "Shipped" have working Lua implementations exercised by integration tests. Rows with explicit deferral notes are documented gaps that v0.2/v0.3 must close. The Lua-tier branch of BR-SH-011 (regex prompt-injection scan) ships in v0.1 and provides community-tier prompt security; the sidecar-tier branch (vector similarity + corpus matching) is enterprise CISO scope and intentionally deferred — see HLD §14 Tiering & License.

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

### 3.4 NER Sidecar Bridge (BR-MK-006 — shipped 2026-04-24)

**Goal.** Augment the regex-based PII detection in §3.2 with named-entity recognition for free-text content (PERSON, LOCATION, ORGANIZATION). Engine code is community tier; multilingual model **artefacts** (Turkish/Arabic/EN) are operator-supplied or enterprise-DPO bundled.

**Transport.** HTTP `POST /v1/mask/detect` to sidecar `127.0.0.1:8081` (ADR-008). The Lua side sends candidate text strings; the sidecar returns recognized entity spans with confidence scores; the Lua side maps them back to JSONPath fields and applies the same strategy registry from §3.3.

**Lua-side helpers (in `aria-mask.lua`):**

```lua
-- Helper: collect candidate strings from JSON body for NER analysis
local function collect_ner_candidates(json_body, conf)
    -- Walk the body, gather text-shaped values that pass regex prefiltering
    -- (skip already-masked paths, skip non-string values, respect max_body_size)
    local candidates = {}  -- list of {path, text, char_offset_in_combined}
    local combined = {}    -- flat string sent to sidecar (one delimiter byte between parts)
    -- ... walk JSON, append to candidates + combined ...
    return candidates, table.concat(combined, "\x1F")  -- ASCII Unit Separator
end

-- Helper: send to sidecar, with circuit breaker
local function try_sidecar_ner(text, route_id)
    local breaker = aria_cb.get("ner-sidecar:" .. route_id)
    if breaker:is_open() then
        emit_metric("aria_mask_ner_circuit_open_total", 1, { route = route_id })
        return nil  -- Skip; outer code falls back to regex-only
    end

    local httpc = require("resty.http").new()
    httpc:set_timeout(conf.ner.sidecar.timeout_ms or 500)
    local res, err = httpc:request_uri("http://127.0.0.1:8081/v1/mask/detect", {
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({ text = text, language = conf.ner.language or "auto" }),
    })

    if not res or res.status >= 500 then
        breaker:record_failure()
        return nil
    end
    breaker:record_success()
    return cjson.decode(res.body).entities  -- list of {type, start, end, score}
end

-- Helper: map sidecar entities back to JSONPath fields
local function assign_entities_to_parts(candidates, entities)
    -- For each entity span (start, end) in the combined string,
    -- find the candidate whose offsets contain it, slice the local span,
    -- emit {path, value, pii_type=entity.type, source="ner"}.
    -- Skip entities below conf.ner.min_confidence.
end
```

**body_filter integration sketch.** Inside `_M.body_filter`, after the regex `auto_detect` block (§3.2):

```lua
if conf.ner and conf.ner.enabled then
    local candidates, combined = collect_ner_candidates(json_body, conf)
    if #combined > 0 then
        local entities = try_sidecar_ner(combined, ctx.var.route_id)
        if entities then
            local ner_matches = assign_entities_to_parts(candidates, entities)
            for _, m in ipairs(ner_matches) do
                if not is_already_masked(masked_fields, m.path) then
                    local strategy = get_strategy_for_role(policy, m.pii_type, nil)
                    if strategy ~= "full" then
                        local masked_value = apply_mask_strategy(strategy, m.value, m.pii_type)
                        jsonpath.set(json_body, m.path, masked_value)
                        table.insert(masked_fields, {
                            path = m.path, strategy = strategy,
                            rule_id = "ner:" .. m.pii_type,
                            pii_type = m.pii_type, source = "sidecar_ner"
                        })
                    end
                end
            end
        elseif conf.ner.fail_mode == "closed" then
            -- Sidecar unavailable AND fail-closed: redact all NER candidate fields
            -- defensively. Cannot return 503 from body_filter (headers already sent).
            for _, c in ipairs(candidates) do
                jsonpath.set(json_body, c.path, "[REDACTED]")
            end
        end
        -- fail_mode == "open" (default): silently skip; rely on regex-tier coverage
    end
end
```

**Schema additions** (extending §3.2 config schema):

```json
"ner": {
    "enabled":     { "type": "boolean", "default": false },
    "fail_mode":   { "type": "string",  "enum": ["open", "closed"], "default": "open" },
    "language":    { "type": "string",  "default": "auto" },
    "min_confidence": { "type": "number", "default": 0.7, "minimum": 0.0, "maximum": 1.0 },
    "sidecar": {
        "type": "object",
        "properties": {
            "endpoint":   { "type": "string", "default": "http://127.0.0.1:8081" },
            "timeout_ms": { "type": "integer", "default": 500, "minimum": 50, "maximum": 5000 }
        }
    }
}
```

**Defense in depth.** The Lua circuit breaker in §8 wraps every `try_sidecar_ner` call (per-endpoint state in `ngx.shared.dict`). The Java sidecar carries its **own inner breaker** (Resilience4j on `NerDetectionService.detect`) — both layers are intentional, not redundant. Levent locked this two-layer pattern 2026-04-24 (memory `project_session_2026-04-24.md`). The same pattern applies to all future Lua↔sidecar HTTP bridges.

**Status:** Engine code (Java side: 8 classes in `aria-runtime/src/main/java/.../mask/ner/`) and Lua bridge code (above) are **shipped**. Model artefacts are **operator-supplied** (`runtime/docs/NER_MODELS.md` has the `optimum-cli export onnx` recipe for the default `savasy/bert-base-turkish-ner-cased`). Engine reports `ready=false` if no model file is mounted; the registry filters it out at startup.

**Traceability:** BR-MK-006 → `aria-mask.lua` (`try_sidecar_ner`, `collect_ner_candidates`, `assign_entities_to_parts`, this section) + `MaskController.java` + `NerDetectionService.java` + 7 supporting NER classes.

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

### 4.4 Admin Control API — Manual Override (BR-CN-005)

**Mechanism.** `aria-canary.lua` exposes a `_M.control_api()` function that registers admin endpoints with APISIX's plugin control-plane (`/v1/plugin/{plugin_name}/...`). These endpoints are reachable via the APISIX Admin API (port `9180`, protected by Admin API key). They give operators **manual override** of canary state without restarting APISIX or editing config.

**Endpoints:**

| Method + Path | Purpose | State transition |
|---|---|---|
| `GET  /v1/plugin/aria-canary/status/{route_id}` | Read current canary state from Redis | none — read-only |
| `POST /v1/plugin/aria-canary/promote/{route_id}` | Force promote canary to 100% | `STAGE_N` / `PAUSED` → `PROMOTED`, `traffic_pct=100` |
| `POST /v1/plugin/aria-canary/rollback/{route_id}` | Force rollback to baseline | any state → `ROLLED_BACK`, `traffic_pct=0` |
| `POST /v1/plugin/aria-canary/pause/{route_id}` | Halt stage progression | `STAGE_N` → `PAUSED` (manual breach declaration) |
| `POST /v1/plugin/aria-canary/resume/{route_id}` | Resume stage progression | `PAUSED` → `STAGE_N` (must verify breach window has passed) |

**Request/response schema (representative — `status`):**

```json
// GET /v1/plugin/aria-canary/status/api-orders → 200
{
  "route_id":    "api-orders",
  "state":       "STAGE_2",
  "traffic_pct": 25,
  "stage_started_at": "2026-04-24T10:15:00Z",
  "current_stage_index": 1,
  "schedule": [{"pct":5,"hold":"5m"},{"pct":25,"hold":"10m"},{"pct":100,"hold":"0"}],
  "error_rate": { "canary": 0.012, "baseline": 0.008 },
  "p95_latency_ms": { "canary": 142, "baseline": 138 },
  "last_progression_check": "2026-04-24T10:25:13Z"
}
```

**Lua skeleton (`aria-canary.lua`):**

```lua
function _M.control_api()
    return {
        {
            methods = {"GET"},
            uris    = {"/v1/plugin/aria-canary/status/*"},
            handler = function(api_ctx)
                local route_id = ngx.var.uri:match("/status/(.+)$")
                local state = redis:hgetall("aria:canary:" .. route_id)
                if not state or state.state == nil then
                    return 404, cjson.encode({ error = "no canary configured for route " .. route_id })
                end
                return 200, cjson.encode(enrich_with_metrics(state, route_id))
            end
        },
        {
            methods = {"POST"},
            uris    = {"/v1/plugin/aria-canary/promote/*"},
            handler = function(api_ctx)
                local route_id = ngx.var.uri:match("/promote/(.+)$")
                redis:hmset("aria:canary:" .. route_id, {
                    state = "PROMOTED",
                    traffic_pct = "100",
                    promoted_at = tostring(ngx.now())
                })
                aria_core.counter_inc("aria_canary_promote_total", 1, { route = route_id })
                send_notification(nil, route_id, "promoted", { manual = true })
                return 200, cjson.encode({ status = "promoted", route_id = route_id })
            end
        },
        -- … rollback / pause / resume follow the same pattern …
    }
end
```

**Authorization.** APISIX's plugin control-plane is exposed on the Admin API port (default `9180`) and requires the Admin API key. No app-level auth in the plugin; the gateway perimeter is the trust boundary. Network-policy guidance: restrict port `9180` to the operator subnet (or to a bastion) — this is documented in `runtime/docs/DEPLOYMENT.md`.

**Idempotency.** Promote/rollback/pause/resume are idempotent — calling promote twice is a no-op once `state == "PROMOTED"`. The handlers re-write the state regardless to refresh `promoted_at` timestamps; consumers should treat duplicate calls as a non-event.

**v0.1 substitute for ariactl.** ariactl (HLD §3.5) is deferred to v0.2; in v0.1, operator scripts call these endpoints directly with `curl`. v0.2's ariactl will be a thin wrapper. This is the rationale documented in HLD §3.5.

**Traceability:** BR-CN-005 → `aria-canary.lua _M.control_api()` (lines 1012–1097 in current source) + this section.

---

## 5. Aria Runtime (Java 21 Sidecar) — Detailed Design

### 5.1 Java Class Hierarchy (shipped reality, 2026-04-25)

```
AriaException (RuntimeException, mapped to ARIA_* error codes)

AriaRuntimeApplication                          # @SpringBootApplication
├── core/
│   ├── GrpcServer                              # gRPC listener; FORWARD-COMPAT only — no Lua callers in v0.1 (ADR-008)
│   │   ├── start()
│   │   ├── stop()                              # graceful drain
│   │   └── registerService(BindableService)
│   ├── GrpcExceptionInterceptor                # Maps Java exceptions to gRPC Status codes
│   ├── HealthController                        # @RestController — /healthz, /readyz, /actuator/*
│   │   ├── liveness()                          # 200 if JVM alive
│   │   └── readiness()                         # 200 iff Redis + Postgres reachable
│   ├── ShutdownManager                         # SIGTERM hook
│   │   └── onShutdown()                        # readiness=503 → drain HTTP + gRPC → close clients
│   └── RequestContext                          # ScopedValue<…> CONSUMER_ID / ROUTE_ID / REQUEST_ID; runScoped(Runnable, values)
│
├── shield/
│   ├── ShieldServiceImpl                       # gRPC ShieldService — consolidates the v1.0-spec'd PromptAnalyzer/TokenCounter/ContentFilter
│   │   ├── analyzePrompt(PromptAnalysisRequest) -- v0.1 STUB returns is_injection=false (v0.3 enables real detection — enterprise CISO)
│   │   ├── countTokens(TokenCountRequest)       -- delegates to TokenEncoder (REAL)
│   │   └── filterResponse(ContentFilterRequest) -- v0.1 STUB returns is_harmful=false (v0.3 enables real filter — enterprise CISO)
│   └── TokenEncoder                            # REAL — jtokkit cl100k_base + per-model registry; Karar A fallback (§5.3.1)
│       ├── count(String model, String content) → TokenCountResult{ tokenCount, encodingUsed, accuracy }
│       └── selectEncoding(String model) → Encoding
│
├── mask/
│   ├── MaskController                          # @RestController POST /v1/mask/detect (Lua-callable canonical, ADR-008)
│   ├── MaskServiceImpl                         # gRPC MaskService.DetectPII — delegates to NerDetectionService (forward-compat; no Lua callers)
│   └── ner/                                    # NER pipeline — BR-MK-006 (shipped 2026-04-24)
│       ├── NerEngine (interface)
│       │   └── detect(String text, String language) → List<PiiEntity>
│       ├── NerEngineRegistry                   # @Component — Spring injects List<NerEngine>; filters by aria.mask.ner.engines config + isReady() probe
│       ├── NerDetectionService                 # @Service — orchestrator shared by HTTP + gRPC; applies min_confidence, dedup, merge
│       ├── NerProperties                       # @ConfigurationProperties("aria.mask.ner") — engines list, min_confidence, circuit-breaker thresholds
│       ├── PiiEntity                           # DTO: type, start, end, score, source(engine_id)
│       ├── CompositeNerEngine                  # Unions+dedupes outputs across registered engines
│       ├── OpenNlpNerEngine                    # English (Apache OpenNLP); models in /opt/aria/models/opennlp/
│       └── DjlHuggingFaceNerEngine             # Multilingual ONNX (Turkish-BERT default); models in /opt/aria/models/turkish-bert/
│
├── canary/
│   ├── DiffController                          # @RestController POST /v1/diff (Lua-callable canonical, ADR-008)
│   ├── CanaryServiceImpl                       # gRPC CanaryService.DiffResponses — delegates to DiffEngine (forward-compat; no Lua callers)
│   └── DiffEngine                              # @Service — REAL structural diff; shared by HTTP + gRPC
│       ├── compare(DiffInput a, DiffInput b) → DiffResult
│       ├── compareStatus(int, int) → boolean
│       ├── compareHeaders(Map, Map) → HeaderDelta
│       ├── compareBodyStructure(byte[], byte[]) → BodySimilarity{score, diffPaths}
│       └── summarize(DiffResult) → String
│
├── common/
│   ├── AriaRedisClient                         # Lettuce async (renamed from "RedisClient" in v1.0 spec)
│   │   ├── get(String key) → CompletableFuture<String>
│   │   ├── incrBy(String key, long amount) → CompletableFuture<Long>
│   │   ├── lpush / rpush / blpop                # for audit buffer (consumer not yet wired — FINDING-003)
│   │   └── close()
│   ├── PostgresClient                          # R2DBC async
│   │   ├── insertAuditEvent(...) → CompletableFuture<Void>   ← v0.1: 0 callers; FINDING-003 / HLD §8.3
│   │   ├── insertBillingRecord(...) → CompletableFuture<Void>
│   │   └── close()
│   └── AriaException
│
└── config/
    └── AriaConfig                              # @ConfigurationProperties("aria") — uds-path, shutdown-grace-seconds, mask.ner.*
```

**Departures from v1.0 spec (permitted simplifications, all reflected in shipped tests):**
- `PromptAnalyzer` + `TokenCounter` + `ContentFilter` consolidated into `ShieldServiceImpl` + `TokenEncoder`. Two of the three concerns are stubs in v0.1; collapsing reduces ceremony without reducing testability.
- `RedisClient` → `AriaRedisClient`. Project-internal rename for clarity (avoids collision with Lettuce's own `RedisClient`).
- `NerDetector` (1 class in v1.0) expanded into the 8-class `mask/ner/` package — needed for the pluggable multi-engine architecture (BR-MK-006).
- `DiffEngine` (1 class in v1.0) split into `DiffEngine` (logic) + `DiffController` (HTTP) + `CanaryServiceImpl` (gRPC). Cross-transport engine sharing — see §5.2.1.
- `AriaException` is a single class with error-code hierarchy in fields (not subclasses for each error category). Mapping to HTTP status codes happens in `GrpcExceptionInterceptor` and a Spring `@RestControllerAdvice`.

### 5.2 gRPC Server (BR-RT-001) — forward-compat only in v0.1

The gRPC server is retained per ADR-008 as a v1.x evolution path for non-Lua callers, but **no Lua plugin uses it in v0.1.** The canonical Lua-callable transport is HTTP/JSON over loopback TCP — see §5.2.1 below.

The server now binds to loopback TCP (port `8082`) instead of UDS (per ADR-008 supersession of ADR-003). Virtual-thread executor and graceful drain remain unchanged from v1.0:

```java
public class GrpcServer {
    private final Server server;
    public GrpcServer(int port, List<BindableService> services) {
        var builder = NettyServerBuilder
            .forAddress(new InetSocketAddress("127.0.0.1", port))   // loopback only
            .executor(Executors.newVirtualThreadPerTaskExecutor())  // BR-RT-002
            .addService(new HealthServiceImpl());
        for (var s : services) builder.addService(s);
        this.server = builder.build();
    }
    public void start() throws IOException { server.start(); }
}
```

NetworkPolicy in the Helm chart restricts ingress to `127.0.0.1:8082` from the same-pod APISIX container only.

### 5.2.1 HTTP/JSON Bridges (canonical Lua transport, ADR-008)

**Pattern.** Each domain `@Service` is injected into both an `@RestController` (HTTP, Lua-callable) and a `@GrpcService` impl (forward-compat). Logic lives in the `@Service` once; transport is a thin wrapper. This is the **cross-transport engine-sharing pattern** that ADR-008 establishes as canonical.

**Two instances shipped in v0.1:**

```
DiffEngine (@Service)
  ├── used by → DiffController (@RestController, POST /v1/diff)
  └── used by → CanaryServiceImpl (gRPC CanaryService.DiffResponses)

NerDetectionService (@Service)
  ├── used by → MaskController (@RestController, POST /v1/mask/detect)
  └── used by → MaskServiceImpl (gRPC MaskService.DetectPII)
```

**Sketch — `DiffController`:**

```java
@RestController
public class DiffController {
    private final DiffEngine engine;

    @PostMapping("/v1/diff")
    public ResponseEntity<DiffHttpResponse> diff(@RequestBody DiffHttpRequest req) {
        // Decode base64 bodies (HTTP/JSON envelope), build DiffInput, delegate
        DiffResult r = engine.compare(req.toInputA(), req.toInputB());
        return ResponseEntity.ok(DiffHttpResponse.of(r));
    }
}
```

**Sketch — `MaskController`:**

```java
@RestController
public class MaskController {
    private final NerDetectionService ner;

    @PostMapping("/v1/mask/detect")
    public DetectResponse detect(@RequestBody DetectRequest req) {
        // Validation, then delegate; min_confidence + dedup applied inside the service
        return DetectResponse.of(ner.detect(req.text(), req.language()));
    }
}
```

**Why this pattern, not just gRPC.** ADR-008 documents the rationale (no Lua gRPC client; debuggability with curl; performance trade-off accepted). For LLD purposes, the contract is: *new sidecar functionality exposed to Lua MUST go through the HTTP bridge pattern; new domain services SHOULD be Spring `@Service` beans so both transports can share the implementation when forward-compat needs add the gRPC side later.*

**Bridge endpoint conventions** (followed by both `DiffController` and `MaskController`, recommended for future bridges):
- Path prefix: `/v1/{module}/{action}`. Example: `/v1/audit/event` (planned for FINDING-003 fix).
- Request: JSON body with explicit base64 fields for binary payloads (do not rely on multipart).
- Response: JSON, with `X-Aria-Trace-Id` header for correlation.
- Errors: HTTP status + JSON `{ "error": { "type": "aria_error", "code": "ARIA_*", "message": "..." } }` per HLD §4.3.
- Latency budget: < 5ms P95 for sub-prompt operations (mask, audit), < 20ms P95 for body-level diff.

### 5.3 Token Counter — `TokenEncoder` (BR-SH-006)

Real implementation shipped 2026-04-22 via `aria-runtime@19c8118`. Uses **jtokkit** (Apache 2.0 Java port of OpenAI's tiktoken). The class lives in `shield/TokenEncoder.java` and is invoked by `ShieldServiceImpl.countTokens` (the gRPC service-impl is forward-compat; the actual call path in v0.1 is a future HTTP bridge `POST /v1/shield/count` — not yet wired because async reconciliation runs on the Lua side via `aria-quota.lua` / `aria-core.lua`):

```java
@Component
public class TokenEncoder {
    private final EncodingRegistry registry = Encodings.newDefaultEncodingRegistry();
    private final Map<String, Encoding> cache = new ConcurrentHashMap<>();

    public TokenCountResult count(String model, String content) {
        var enc = selectEncoding(model);  // see §5.3.1
        int n = enc.countTokens(content);
        return new TokenCountResult(n, enc.getName(), accuracyFor(model));
    }

    private Encoding selectEncoding(String model) {
        return cache.computeIfAbsent(model, m -> {
            var byModel = registry.getEncodingForModel(m);
            if (byModel.isPresent()) return byModel.get();
            // Karar A: cl100k_base fallback for unknown models — see §5.3.1
            return registry.getEncoding(EncodingType.CL100K_BASE);
        });
    }

    private Accuracy accuracyFor(String model) {
        return registry.getEncodingForModel(model).isPresent()
            ? Accuracy.EXACT
            : Accuracy.FALLBACK;
    }
}

public record TokenCountResult(int tokenCount, String encodingUsed, Accuracy accuracy) {}
public enum Accuracy { EXACT, FALLBACK }
```

**Reconciliation (per BR-SH-006).** The Lua side computes a fast approximate token count in `body_filter` and updates Redis quota immediately (write-then-correct pattern). When the sidecar has the response body it computes `exact - approximate = delta` and applies an `INCRBY delta` to the quota key. v0.1 ships the Lua-side approximation + write; the **sidecar reconciliation HTTP path is on the v0.2 backlog** (depends on the same HTTP bridge pattern as audit/diff/ner).

### 5.3.1 Tokenizer Fallback Chain (Karar A locked 2026-04-22, Karar B open)

**Karar A — model unknown to the registry → use `cl100k_base`, return `Accuracy.FALLBACK`.**

Rationale (locked 2026-04-22 per memory `project_license_split_refinement.md`):
- Gatekeeper is a horizontal product; customer model mix is unpredictable (OpenAI, Claude, Gemini, self-hosted Llama, custom fine-tunes).
- Every model must get a working count — strict mode (throw on unknown) would break customer integrations.
- `cl100k_base` is within 5–20% of most modern tokenizers; honest `FALLBACK` flag lets billing pipelines apply provider-specific correction if needed.

**Resolution chain:**

```
selectEncoding(model):
    1. Exact match in jtokkit's model→encoding table (e.g., "gpt-4o" → o200k_base)
       → return Accuracy.EXACT
    2. Future extension point — provider-specific branches BEFORE the fallback:
       - "claude-*" → (when added) Anthropic tokenizer, Accuracy.EXACT
       - "gemini-*" → (when added) SentencePiece, Accuracy.EXACT
    3. Default fallback → cl100k_base, Accuracy.FALLBACK
```

The extension point in step 2 is intentional: when a customer requires exact accuracy for a specific non-OpenAI provider, add a dedicated branch above the fallback. Fallback remains the catch-all.

**Karar B — role-token semantics — STILL OPEN.**

Current code: `ShieldServiceImpl.countTokens` returns `tokenCount` for the supplied content but does NOT separately attribute tokens to message roles (system / user / assistant). Inline comment in source: *"input_tokens / output_tokens left at 0 — Karar B (role semantics) is still open."*

Per OpenAI's tiktoken-with-roles spec, each message carries ~3 tokens of role/structural overhead. Three options for v0.2:
1. **(recommended)** Apply OpenAI's standard 3-tokens-per-message overhead. Universal across providers, defacto standard.
2. Content-only counting (current behavior) — under-counts billing slightly.
3. Configurable per provider — most flexible but adds knobs.

**Pending decision** to be recorded as **ADR-009** before v0.2 starts. Until then, `input_tokens` / `output_tokens` are reported as 0 in the proto response and the Lua side carries the responsibility for splitting input vs output via the upstream `usage` object (which all major providers return in the response body).

### 5.4 Graceful Shutdown (BR-RT-004)

**Per-transport drain.** `ShutdownManager.onShutdown()` orchestrates a four-phase drain over the `aria.shutdown-grace-seconds` window (default 30s):

```java
public class ShutdownManager {
    public void onShutdown() {
        // 1. Set readiness=503 — load balancer / k8s service stops sending new traffic
        health.setReady(false);

        // 2. Stop accepting new HTTP connections (Spring Boot / Tomcat)
        applicationContext.close();   // triggers @PreDestroy on @RestControllers

        // 3. Stop accepting new gRPC connections, drain in-flight (forward-compat path)
        grpcServer.shutdown();
        if (!grpcServer.awaitTermination(graceSeconds, TimeUnit.SECONDS)) {
            grpcServer.shutdownNow();
        }

        // 4. Close datastore clients
        redis.close();
        postgres.close();
    }
}
```

Differences vs v1.0 spec:
- **No UDS socket file to delete** — sidecar binds to loopback TCP per ADR-008.
- HTTP server (Spring Boot) drained alongside gRPC; both transports respect the same grace window.
- Readiness is flipped to `503` BEFORE drain so the kube `Service` removes the pod from rotation; `preStop sleep 5` in the pod spec gives the readiness probe one cycle to flip before SIGTERM (see HLD §3.4 deployment guidance).

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

-- HTTP/JSON sidecar client (canonical Lua transport per ADR-008)
-- Replaces the v1.0-spec'd grpc_call(); aria-grpc.lua was never written.
function _M.http_call(endpoint, method, body, opts)
    -- Returns parsed-json response or nil (sidecar unavailable / circuit open)
    -- Honors aria-circuit-breaker.lua state for the given endpoint key
    -- Implements deadline (500ms default)
end

-- Async audit event (Lua → Redis list `aria:audit_buffer`)
function _M.record_audit_event(ctx, event_type, details)
    -- Mask PII in details before pushing
    -- v0.1 GAP: sidecar consumer not implemented — events accumulate
    -- in Redis with 1h TTL and are silently dropped without DB write.
    -- v0.2 fix: AuditFlusher Spring @Scheduled bean OR POST /v1/audit/event
    -- bridge per ADR-008. See HLD §8.3 + FINDING-003.
end

return _M
```

**Dependencies:** `aria-core.lua` is required by all three plugins. Plugins also pull in `aria-circuit-breaker.lua` (§8) when invoking sidecar HTTP bridges (`try_sidecar_ner` in mask, `try_sidecar_diff` in canary).

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

## 8. Shared Library: aria-circuit-breaker.lua (NEW — shipped 2026-04-24)

A generic, per-endpoint circuit breaker shared library. Wraps every Lua → sidecar HTTP call so a misbehaving sidecar endpoint does not cascade into request failures. Used by the mask NER bridge today (§3.4); precedent for all future Lua↔sidecar HTTP bridges.

### 8.1 State machine

```
                         failure_threshold breached
                ┌────────────────────────────────────────┐
                │                                         ▼
        ┌──────────────┐                       ┌──────────────┐
        │   CLOSED     │                       │     OPEN     │
        │ (allow all)  │                       │ (skip calls; │
        └──────────────┘                       │  cooldown)   │
                ▲                              └──────────────┘
                │                                         │
                │   probe_succeeds                        │ cooldown elapsed
                │                                         ▼
                │                              ┌──────────────┐
                └──────────────────────────────│  HALF_OPEN   │
                          probe_fails          │ (one probe)  │
                          → re-open            └──────────────┘
```

### 8.2 Storage

State per endpoint key in `ngx.shared.dict("aria_cb")` (allocated in `nginx.conf` snippet — see deployment docs). Keys:

| Key | Value | TTL |
|---|---|---|
| `cb:{endpoint_key}:state` | `"CLOSED" \| "OPEN" \| "HALF_OPEN"` | none |
| `cb:{endpoint_key}:failures` | int (sliding window) | `window_seconds` |
| `cb:{endpoint_key}:opened_at` | float (`ngx.now()`) | reset on transition |

`endpoint_key` is operator-supplied at construction (e.g., `"ner-sidecar:" .. route_id` or `"shadow-diff"`). Per-route isolation prevents one bad route from tripping breakers for unrelated routes.

### 8.3 Public API

```lua
local cb = require("apisix.plugins.lib.aria-circuit-breaker")

local breaker = cb.get(endpoint_key, {
    failure_threshold     = 5,    -- consecutive failures to open
    cooldown_seconds      = 30,   -- time in OPEN before HALF_OPEN probe
    window_seconds        = 60,   -- failure-counter sliding window
})

-- Hot-path usage:
if breaker:is_open() then
    -- skip sidecar, fall back to regex-only mode (or fail-closed per config)
    return nil
end

local res, err = make_http_call()  -- via aria_core.http_call

if err or not res or res.status >= 500 then
    breaker:record_failure()
    return nil
else
    breaker:record_success()
    return res.body
end
```

### 8.4 Defense-in-depth pairing with Java side

The Java sidecar carries its **own inner breaker** (Resilience4j on `NerDetectionService.detect`, `DiffEngine.compare`, etc.) with separate thresholds. Two-layer breaker is intentional, not redundant:
- The **Lua outer breaker** protects APISIX from sidecar slowness (latency budget).
- The **Java inner breaker** protects sidecar resources from a misbehaving model or downstream dep.

This pairing was locked by Levent on 2026-04-24 (memory `project_session_2026-04-24.md`) and is expected for every new Lua↔sidecar HTTP bridge. Configuration-wise, the two layers should NOT have identical thresholds — the inner should be tighter (faster open) so the outer rarely needs to.

### 8.5 Metrics

| Metric | Type | Labels |
|---|---|---|
| `aria_cb_state` | gauge | `endpoint_key`, `state` (0=closed, 1=half_open, 2=open) |
| `aria_cb_open_total` | counter | `endpoint_key` (tripped count) |
| `aria_cb_skipped_total` | counter | `endpoint_key` (calls short-circuited while open) |
| `aria_cb_probe_success_total` | counter | `endpoint_key` |
| `aria_cb_probe_failure_total` | counter | `endpoint_key` |

Exposed via `aria_core.emit_metric` to the standard APISIX Prometheus endpoint.

### 8.6 Relationship to Shield's existing circuit breaker (§2.6)

§2.6 documents a Redis-backed circuit breaker for **provider failover** (per-provider state shared across APISIX workers). `aria-circuit-breaker.lua` is a **per-worker, per-endpoint** breaker for **sidecar HTTP bridges** (worker-local `ngx.shared.dict`, no Redis dependency). They serve different concerns:

| Concern | Storage | Scope | Module |
|---|---|---|---|
| LLM provider failover (BR-SH-002) | Redis | cluster-wide | `aria-shield.lua` §2.6 |
| Sidecar bridge failure (BR-MK-006, BR-CN-007, …) | `ngx.shared.dict` | worker-local | `aria-circuit-breaker.lua` (this section) |

Unifying them in v0.2 has been considered (open question) — for now, both exist intentionally because cluster-wide state for sidecar calls (which are loopback to the same pod) adds latency without benefit.

---

## 9. Configuration Validation

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

## 10. Performance Design Decisions

| Concern | Decision | Rationale |
|---------|----------|-----------|
| Redis connection pooling | APISIX cosocket pool (max 100 connections per worker) | Reuse connections across requests |
| JSON parsing in Mask | Single-pass parse + rewrite (no intermediate objects) | O(n) memory, minimize GC |
| Prometheus cardinality | Check `aria_metrics_count` before emitting. Drop if > 10K | Prevent Prometheus OOM |
| Canary error tracking | 10-second Redis counters with 2m TTL | Bounded memory, automatic cleanup |
| SSE streaming | No buffering — forward each `ngx.arg[1]` chunk immediately | O(1) memory per stream |
| **Lua → sidecar HTTP/JSON over loopback (ADR-008)** | `resty.http` to `127.0.0.1:8081`; deadline 500ms default; cross-transport engine sharing pattern (§5.2.1) | ~1–2ms vs UDS gRPC ~0.1ms; trade-off accepted to avoid `lua-resty-grpc` dependency. Inner Java breaker + outer Lua breaker (§8.4) for fault isolation. |
| Sidecar HTTP deadline | 500ms default, configurable per bridge (mask NER 500ms, shadow diff 2000ms) | Fail fast if sidecar is slow; longer for body-level diff |
| Virtual thread per request (sidecar) | No pooling — JVM manages scheduling | Virtual threads are ~1KB each |
| Tokenizer cache (TokenEncoder) | Per-model `ConcurrentHashMap<String, Encoding>` | Tokenizer construction is expensive; one cache key per model; bounded by # of distinct models seen |

---

## 11. Testing Strategy

### 11.1 Unit Tests

| Module | Framework | Coverage Target | Key Tests | v0.1 Test File Count |
|---|---|---|---|---|
| Lua plugins | busted | > 80% | Mask strategies, PII regex, provider transforms, quota logic, NER bridge helpers, circuit breaker state machine, canary diff helpers, control_api handlers | 7+ test files |
| Java sidecar | JUnit 5 + Mockito | > 80% | TokenEncoder fallback chain (Karar A), DiffEngine structural compare, NerEngineRegistry, NerDetectionService, MaskController, DiffController, CompositeNerEngine dedup | 16+ test files (~121 tests as of 2026-04-24) |
| ariactl | Go testing | > 70% | Command parsing, API client, output formatting | **DEFERRED to v0.2** |

### 11.2 Integration Tests

| Test Suite | Environment | Key Scenarios |
|---|---|---|
| Shield e2e | APISIX + Redis + mock LLM | Request routing, quota enforcement, failover, SSE streaming, OpenAI-compat across 5 providers |
| Mask e2e | APISIX + Redis + upstream mock | JSONPath masking, role policies, PII regex detection, NER bridge fail-open/fail-closed, circuit breaker open/half-open/closed transitions |
| Canary e2e | APISIX + Redis + two upstreams | Stage progression, auto-rollback, manual override via `_M.control_api()` (status/promote/rollback/pause/resume), shadow diff sidecar bridge |
| Sidecar e2e | Sidecar JVM + Redis + Postgres | TokenEncoder accuracy + Karar A fallback, DiffEngine structural compare, MaskController + NER pipeline, /healthz + /readyz, graceful HTTP+gRPC drain |
| Smoke (full stack) | docker-compose | End-to-end: client → APISIX → Lua plugins → sidecar HTTP bridges → Redis/Postgres |

### 11.3 Performance Tests

| Test | Tool | Target | Scenario |
|---|---|---|---|
| Shield latency overhead | wrk2 / k6 | < 5ms P95 | 1000 req/s through Shield vs. direct |
| Mask throughput (regex only) | k6 | < 1ms P95 for 50KB body | 1000 req/s with 10 masking rules |
| Mask + NER bridge throughput | k6 | < 5ms P95 added | 1000 req/s, `fail_mode=open`, engine ready |
| Canary routing accuracy | Custom script | < 1% variance | 10K requests, verify traffic split |
| Shadow diff latency | k6 | < 20ms P95 | Async path; primary unaffected |
| SSE streaming | Custom client | < 1ms per chunk | 100 concurrent streams |
| Circuit breaker behavior | Chaos test | Opens within `failure_threshold` failures; half-open after `cooldown_seconds` | Sidecar offline simulation |

---

## 12. Traceability Matrix

| Business Rule | LLD Section | Function / Class | Test | v0.1 Status |
|---|---|---|---|---|
| BR-SH-001 | 2.2, 2.7 | `_M.access()`, `transform_request()`, `transformers.*` | Shield e2e: routing | Shipped (5 providers) |
| BR-SH-002 | 2.6 | `check_circuit_breaker()`, `record_provider_result()` | Shield e2e: failover | Shipped (Redis-backed, separate from §8 lib) |
| BR-SH-003 | 2.3 | `_M.body_filter()` (streaming branch) | SSE streaming test | Shipped |
| BR-SH-004 | 2.7 | `transformers.*.transform_response()` | Unit: response mapping | Shipped |
| BR-SH-005 | 2.2 | `check_quota()` | Shield e2e: quota | Shipped |
| BR-SH-006 | 5.3 | `TokenEncoder.count()` (was `TokenCounter.countTokens` in v1.0 spec) | Sidecar unit: tokenizer accuracy + Karar A fallback | Shipped — Lua side does write-then-correct; sidecar HTTP reconciliation path on v0.2 backlog |
| BR-SH-007 | 2.3 | `calculate_cost()` | Unit: cost calculation | Shipped |
| BR-SH-008 | 2.4 | `_M.log()` metric emissions | Shield e2e: metrics | Shipped |
| BR-SH-009 | 2.4 | `check_alert_thresholds()` | Unit: alert thresholds | Shipped |
| BR-SH-010 | 2.2 | `apply_overage_policy()` | Shield e2e: overage | Shipped |
| BR-SH-011 (Lua/regex tier) | 2.2 | `scan_prompt_injection()` | Shield e2e: injection (regex) | Shipped — community |
| BR-SH-011 (sidecar/vector tier) | 2.2, 5.1 | `grpc_analyze_prompt()` (Lua, NOT WIRED) + `ShieldServiceImpl.analyzePrompt` (Java STUB) | — | **DEFERRED v0.3** — enterprise CISO tier |
| BR-SH-012 | 2.2 | `scan_pii_in_prompt()`, `mask_pii_in_request()` | Shield e2e: PII | Shipped |
| BR-SH-013 (data exfiltration guard) | — | — | — | **DEFERRED v0.3** — enterprise CISO |
| BR-SH-014 (system prompt extraction guard) | — | — | — | **DEFERRED v0.3** — enterprise CISO |
| BR-SH-015 | 2.4 | `record_audit_event()` (Lua, pushes to Redis) + `PostgresClient.insertAuditEvent()` (Java, **0 callers**) | Sidecar e2e: audit | **PARTIAL — Lua side wired; sidecar consumer NOT IMPLEMENTED in v0.1 (FINDING-003).** v0.2 fix per HLD §8.3. |
| BR-SH-018 | 2.2 | `apply_model_pin()` | Shield e2e: model pin | Shipped |
| BR-MK-001 | 3.2 | `_M.body_filter()` JSONPath rules | Mask e2e: JSONPath | Shipped |
| BR-MK-002 | 3.2 | `resolve_role_policy()` | Mask e2e: roles | Shipped |
| BR-MK-003 | 3.2, 7 | `detect_pii_patterns()`, `aria-pii.lua` | Unit: PII regex | Shipped (8 patterns including PAN scope-hygiene per HLD §10.2) |
| BR-MK-004 | 3.3 | `apply_mask_strategy()`, `mask_strategies.*` | Unit: 12 strategies | Shipped — *`tokenize` strategy currently emits non-reversible hash; Redis-backed reversible tokens reserved for v0.2 (HLD §9.1)* |
| BR-MK-005 | 3.2 | `_M.log()` masking audit | Mask e2e: audit | **PARTIAL — same gap as BR-SH-015** (Lua emits, sidecar does not consume) |
| BR-MK-006 | 3.4 | `try_sidecar_ner`, `collect_ner_candidates`, `assign_entities_to_parts` (Lua) + `MaskController` + `NerDetectionService` + 7 supporting NER classes (Java) | Mask e2e: NER fail-open/fail-closed | Shipped 2026-04-24 — engine code community; multilingual model artefacts operator-supplied or enterprise DPO bundled |
| BR-MK-007 (advanced policy semantics) | — | — | — | **DEFERRED v0.3** |
| BR-MK-008 (DLP-style outbound mask) | — | — | — | **DEFERRED v0.3** — enterprise DPO |
| BR-CN-001 | 4.2, 4.3 | `_M.access()`, `check_stage_progression()` | Canary e2e: progression | Shipped |
| BR-CN-002 | 4.3 | `calculate_error_rate()` | Canary e2e: error rate | Shipped |
| BR-CN-003 | 4.3 | `check_stage_progression()` (rollback branch) | Canary e2e: rollback | Shipped |
| BR-CN-004 | 4.3 | `calculate_p95()` | Canary e2e: latency guard | Shipped |
| BR-CN-005 | 4.4 | `_M.control_api()` (status/promote/rollback/pause/resume) | Canary e2e: manual override | Shipped (was missing from v1.0 traceability matrix) |
| BR-CN-006 | 4.2 | `should_shadow`, `capture_shadow_payload`, `fire_shadow` | Canary e2e: shadow traffic | Shipped (Iter 1, 2026-04-22) |
| BR-CN-007 | 4.3 | `try_sidecar_diff` (Lua) + `DiffController` + `DiffEngine` (Java) | Canary e2e: shadow diff | Shipped (Iter 2c+3, 2026-04-23) |
| BR-RT-001 | 5.2 | `GrpcServer` | Sidecar e2e: gRPC startup | Shipped — but no Lua callers in v0.1 (forward-compat per ADR-008) |
| BR-RT-002 | 5.2 | `newVirtualThreadPerTaskExecutor()` | Sidecar e2e: concurrency | Shipped |
| BR-RT-004 | 5.4 | `ShutdownManager.onShutdown()` | Sidecar e2e: shutdown | Shipped (HTTP + gRPC drain) |

**v1.0 → v1.1 changes to traceability:** Added BR-SH-008, BR-SH-009, BR-SH-018, BR-CN-005, BR-CN-006, BR-CN-007, BR-MK-006. Added "v0.1 Status" column. Marked BR-SH-011 sidecar tier, BR-SH-013/014, BR-MK-007/008 as v0.3 deferred (enterprise scope per HLD §14). Acknowledged audit pipeline gap (BR-SH-015, BR-MK-005). Renamed `TokenCounter.countTokens` to `TokenEncoder.count` per shipped class names.

---

*Document Version: 1.1 | Created: 2026-04-08 | Revised: 2026-04-25*
*Status: v1.1 Draft — Pending Human Approval (after PHASE_REVIEW_2026-04-25 adversarial drift report)*
*Change log v1.0 → v1.1: §1 plugin tree (real layout, ariactl deferred, no aria-grpc.lua, +aria-circuit-breaker.lua, real Java class roster), §2.5 internal-functions table (audit gap + sidecar stub status notes), §3.4 NEW (NER bridge BR-MK-006), §4.4 NEW (control_api admin endpoints BR-CN-005), §5.1 class hierarchy (shipped reality — ShieldServiceImpl + TokenEncoder, 8 NER classes, DiffController/MaskController), §5.2 (gRPC forward-compat only) + §5.2.1 NEW (HTTP bridges per ADR-008), §5.3 (TokenEncoder real impl with jtokkit), §5.3.1 NEW (Karar A cl100k_base fallback chain + Karar B open), §5.4 (HTTP+gRPC drain, no UDS file deletion), §6 (HTTP not gRPC, audit gap acknowledgement), §8 NEW (aria-circuit-breaker shared lib design), renumbered §9-§12, §10 added HTTP bridge perf row, §11 (test counts updated, ariactl deferred), §12 traceability rewrite (BR-MK-006 + BR-CN-005-007 + BR-SH-018/008/009 added; v0.1 Status column).*
