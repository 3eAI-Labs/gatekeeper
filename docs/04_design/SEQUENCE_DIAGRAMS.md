# Sequence Diagrams — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 4 — Design
**Version:** 1.1.3
**Date:** 2026-04-25 (v1.1.3 spec-coherence sweep); 2026-04-08 (v1.0 baseline)
**Author:** AI Architect + Human Oversight
**Input:** HLD.md v1.1.1, API_CONTRACTS.md v1.1, INTEGRATION_MAP.md v1.1.3, ADR-008, ADR-009
**v1.1.3 Driver:** v1.0 was missing every sidecar interaction shipped after 2026-04-08. Adds §6 NER bridge (BR-MK-006), §7 Canary shadow diff (BR-CN-007), §8 Audit pipeline LPOP drain (ADR-009). Updates Cross-Cutting Concerns (transport row "Sidecar (UDS)" → "Sidecar HTTP loopback" per ADR-008; Postgres failure mode for audit reflects AuditFlusher behaviour). §5 retains its title for historical continuity but adds an HTTP-bridge precedence note.

---

## Table of Contents

1. [Shield: LLM Request (Full Flow)](#1-shield-llm-request-full-flow)
2. [Shield: SSE Streaming Flow](#2-shield-sse-streaming-flow)
3. [Mask: Response Masking Flow](#3-mask-response-masking-flow)
4. [Canary: Progressive Deployment Lifecycle](#4-canary-progressive-deployment-lifecycle)
5. [Sidecar: gRPC Request Lifecycle](#5-sidecar-grpc-request-lifecycle) — **forward-compat only in v0.1**; HTTP bridge is the canonical Lua transport (ADR-008). New Lua-callable sequences land in §6+.
6. [Mask NER Bridge (HTTP, BR-MK-006)](#6-mask-ner-bridge-http-br-mk-006)
7. [Canary Shadow Diff (HTTP, BR-CN-007)](#7-canary-shadow-diff-http-br-cn-007)
8. [Audit Pipeline LPOP Drain (ADR-009)](#8-audit-pipeline-lpop-drain-adr-009)

---

## 1. Shield: LLM Request (Full Flow)

**Covers:** Complete request lifecycle from client through Shield plugin to LLM provider and back, including quota enforcement, prompt injection detection, PII scanning, provider failover, token accounting, and audit trail.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant SH as APISIX<br/>(Shield Lua)
    participant R as Redis
    participant SC as Sidecar<br/>(Shield)
    participant LLM as LLM Provider
    participant PG as Postgres

    C->>SH: POST /v1/chat/completions

    Note over SH: Read consumer_id from<br/>APISIX ctx (ngx.ctx.var.consumer_name)

    %% --- Quota Check ---
    SH->>R: GET aria:quota:{consumer}:tokens_used

    alt Redis unavailable
        alt fail_policy = fail_open
            Note over SH: ALLOW + WARN log<br/>aria_shield_redis_fallback_total++
        else fail_policy = fail_closed
            SH-->>C: 503 ARIA_SH_REDIS_UNAVAILABLE
        end
    else Quota response received
        alt Quota exhausted + overage_policy = block
            SH-->>C: 402 ARIA_SH_QUOTA_EXCEEDED
        else Quota exhausted + overage_policy = throttle
            SH-->>C: 429 ARIA_SH_QUOTA_THROTTLED
        else Quota exhausted + overage_policy = allow
            Note over SH: ALLOW + emit budget alert<br/>if threshold crossed
        else Within quota
            Note over SH: Continue processing
        end
    end

    %% --- Prompt Injection Scan ---
    Note over SH: Run prompt injection regex scan<br/>against messages[].content

    alt HIGH confidence regex match
        SH--)PG: Async: audit event (via sidecar)
        SH-->>C: 403 ARIA_SH_PROMPT_INJECTION_DETECTED
    else MEDIUM confidence match
        SH->>SC: gRPC AnalyzePrompt(content, patterns)
        alt Sidecar unavailable
            Note over SH: ALLOW + WARN log<br/>aria_shield_sidecar_fallback_total++
        else Sidecar confirms injection
            SH--)PG: Async: audit event (via sidecar)
            SH-->>C: 403 ARIA_SH_PROMPT_INJECTION_DETECTED
        else Sidecar clears prompt
            Note over SH: Continue processing
        end
    else No injection pattern
        Note over SH: Continue processing
    end

    %% --- PII in Prompt Scan ---
    Note over SH: Run PII regex scan on<br/>messages[].content

    alt PII found + action = block
        SH-->>C: 400 ARIA_SH_PII_IN_PROMPT_DETECTED
    else PII found + action = mask
        Note over SH: Replace PII with placeholders<br/>(e.g., [EMAIL_REDACTED])
    else No PII found
        Note over SH: Continue processing
    end

    %% --- Request Transform + Model Pin ---
    Note over SH: Transform request to<br/>provider-specific format<br/>(OpenAI/Anthropic/Google)

    alt Model version pin configured
        Note over SH: Override model field<br/>e.g., gpt-4o -> gpt-4o-2024-11-20
    end

    %% --- Forward to Provider ---
    SH->>LLM: Forward transformed request

    alt Provider returns 5xx
        Note over SH: Circuit breaker: failure_count++
        alt failure_count >= threshold
            Note over SH: Open circuit for cooldown_seconds
        end
        SH->>LLM: Try fallback_providers[0]
        alt Fallback also fails
            SH-->>C: 503 ARIA_SH_ALL_PROVIDERS_DOWN
        else Fallback succeeds
            LLM-->>SH: 200 OK (provider response)
        end
    else Provider returns 429
        SH-->>C: 429 ARIA_SH_PROVIDER_RATE_LIMITED
    else Provider timeout
        SH-->>C: 504 ARIA_SH_PROVIDER_TIMEOUT
    else Provider returns 200
        LLM-->>SH: 200 OK (provider response)
    end

    %% --- Response Processing ---
    Note over SH: Transform response to<br/>OpenAI-compatible format

    Note over SH: Extract usage.total_tokens<br/>from response

    SH->>R: INCRBY aria:quota:{consumer}:tokens_used {total_tokens}

    SH--)SC: Async gRPC CountTokens<br/>(exact tiktoken reconciliation)
    SC--)R: INCRBY delta (if lua_estimate != exact)

    Note over SH: Add X-Aria-* response headers:<br/>Provider, Model, Tokens-Input,<br/>Tokens-Output, Quota-Remaining,<br/>Budget-Remaining, Request-Id

    Note over SH: Emit Prometheus metrics (async):<br/>aria_shield_requests_total,<br/>aria_shield_tokens_total,<br/>aria_shield_latency_seconds

    alt Security event occurred
        SH--)SC: Async gRPC audit event
        SC--)PG: INSERT INTO aria_audit_events
    end

    SH-->>C: 200 OK (OpenAI-format response + X-Aria-* headers)
```

**Key Design Decisions:**

- **Fail-open vs. fail-closed** is configurable per consumer via `quota.fail_policy`. Fail-open is the default to avoid blocking production traffic when Redis is temporarily unavailable; the warn log and metric allow operators to detect and remediate.
- **Two-tier injection detection:** Regex runs in Lua (fast, no network hop). Only MEDIUM-confidence matches go to the sidecar for vector similarity analysis, keeping p99 latency low for clean requests.
- **Approximate-then-reconcile token counting:** Lua uses the provider-reported `usage.total_tokens` for immediate quota update. The sidecar runs exact tiktoken counting asynchronously and corrects any delta, ensuring eventual accuracy without blocking the response path.
- **Circuit breaker state** is kept in Lua shared dict (per-worker) rather than Redis to avoid adding another Redis round-trip in the critical path. Providers are tried in order from `fallback_providers[]`.

---

## 2. Shield: SSE Streaming Flow

**Covers:** Server-Sent Events (SSE) streaming for `stream: true` requests, including chunk-by-chunk forwarding, incremental token counting, client disconnect handling, and final usage reconciliation.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant SH as APISIX<br/>(Shield Lua)
    participant LLM as LLM Provider
    participant R as Redis
    participant SC as Sidecar<br/>(Shield)

    C->>SH: POST /v1/chat/completions<br/>{stream: true}

    Note over SH: Quota check + injection scan<br/>+ PII scan (same as non-streaming)

    SH->>LLM: Forward request (stream: true)
    LLM-->>SH: HTTP 200 + Transfer-Encoding: chunked<br/>Content-Type: text/event-stream

    SH-->>C: HTTP 200 + headers<br/>Content-Type: text/event-stream

    Note over SH: Initialize chunk_count = 0,<br/>accumulated_content = ""

    loop For each SSE chunk from provider
        LLM-->>SH: data: {choices[0].delta.content: "Hello"}

        Note over SH: Transform chunk to<br/>OpenAI SSE format

        Note over SH: Accumulate content for<br/>token estimation:<br/>accumulated_content += delta.content

        SH-->>C: data: {choices[0].delta.content: "Hello"}

        alt Client disconnects (ngx.req.socket error)
            Note over SH: Detect broken pipe
            Note over SH: Drain remaining provider chunks<br/>(avoid provider-side connection leak)
            Note over SH: Estimate tokens from<br/>accumulated_content length
            SH->>R: INCRBY aria:quota:{consumer}:tokens_used {estimated}
            SH--)SC: Async CountTokens(accumulated_content)
            Note over SH: Log: client_disconnect,<br/>chunks_sent = chunk_count
        end

        Note over SH: chunk_count++
    end

    LLM-->>SH: data: {..., finish_reason: "stop",<br/>usage: {total_tokens: 142}}

    Note over SH: Extract usage from final chunk<br/>(if provider includes it)

    SH-->>C: data: {..., finish_reason: "stop"}
    SH-->>C: data: [DONE]

    %% --- Post-stream accounting ---
    alt Final chunk included usage object
        SH->>R: INCRBY aria:quota:{consumer}:tokens_used<br/>{usage.total_tokens}
    else No usage in final chunk
        Note over SH: Estimate tokens:<br/>prompt_tokens (from request) +<br/>len(accumulated_content) / 4
        SH->>R: INCRBY aria:quota:{consumer}:tokens_used<br/>{estimated_total}
    end

    SH--)SC: Async gRPC CountTokens<br/>(accumulated_content for exact count)
    SC--)R: INCRBY delta correction

    Note over SH: Emit Prometheus metrics:<br/>aria_shield_stream_chunks_total,<br/>aria_shield_stream_duration_seconds

    alt Provider stream error mid-flight
        LLM-->>SH: Connection reset / 5xx mid-stream
        SH-->>C: data: {"error": "ARIA_SH_PROVIDER_STREAM_ERROR"}
        SH-->>C: data: [DONE]
        Note over SH: Account tokens sent so far
        SH->>R: INCRBY with partial estimate
    end
```

**Key Design Decisions:**

- **Chunk-by-chunk forwarding:** Each SSE chunk is forwarded to the client as it arrives from the provider. Shield does not buffer the entire response -- this preserves streaming latency (time-to-first-token).
- **Content accumulation:** Shield accumulates `delta.content` from all chunks in memory for two purposes: (1) post-stream token estimation, and (2) passing the full content to the sidecar for exact token counting.
- **Client disconnect handling:** When the client disconnects mid-stream, Shield continues to drain remaining chunks from the provider to avoid orphaned upstream connections, then performs best-effort token accounting.
- **Token estimation fallback:** Not all providers include `usage` in the final SSE chunk. When absent, Shield uses the heuristic `len(content) / 4` for approximate token count, corrected later by the sidecar's exact tiktoken calculation.

---

## 3. Mask: Response Masking Flow

**Covers:** Response body masking on the return path, including content-type gating, role-based policy resolution, JSONPath masking, PII auto-detection, tokenization with Redis, and optional NER via sidecar.

```mermaid
sequenceDiagram
    autonumber
    participant UP as Upstream
    participant MK as APISIX<br/>(Mask Lua)
    participant R as Redis
    participant SC as Sidecar<br/>(Mask)
    participant C as Client

    UP-->>MK: HTTP Response (body + headers)

    %% --- Content-Type gate ---
    alt Content-Type is NOT application/json
        Note over MK: Pass through unmodified
        MK-->>C: Original response
    end

    %% --- Body size gate ---
    alt Body size > max_body_size (10 MB)
        Note over MK: Pass through + emit metric<br/>aria_mask_body_too_large_total++
        MK-->>C: Original response (oversized)
    end

    %% --- Role resolution ---
    Note over MK: Read consumer role from<br/>APISIX ctx (consumer metadata)

    Note over MK: Resolve masking policy:<br/>1. Consumer metadata policy<br/>2. Route default policy<br/>3. Fallback: "redact" all

    %% --- JSONPath masking ---
    Note over MK: Parse JSON body

    loop For each masking rule in policy
        Note over MK: Evaluate JSONPath<br/>(e.g., $.customer.email)

        alt Strategy = "full" (admin role)
            Note over MK: No masking, keep original value
        else Strategy = "mask:email"
            Note over MK: j***@example.com
        else Strategy = "last4"
            Note over MK: ****-****-****-1234
        else Strategy = "mask:phone"
            Note over MK: +90-***-***-**-67
        else Strategy = "redact"
            Note over MK: [REDACTED]
        else Strategy = "tokenize"
            MK->>R: GET aria:token:{hash(value)}
            alt Redis available + token exists
                Note over MK: Replace with existing token
            else Redis available + no token
                Note over MK: Generate token (UUID)<br/>Store in Redis with TTL
                MK->>R: SET aria:token:{hash(value)} {uuid} EX {ttl}
            else Redis unavailable
                Note over MK: Fallback to "redact" strategy<br/>aria_mask_tokenize_fallback_total++
            end
        end
    end

    %% --- PII auto-detection ---
    Note over MK: Run PII regex auto-detection<br/>on remaining (non-whitelisted) fields

    alt PII detected by regex
        Note over MK: Apply default_strategy<br/>for role to detected fields
        Note over MK: Log: auto_detected_pii,<br/>field_count, patterns matched
    end

    %% --- Serialize + return ---
    Note over MK: Serialize masked JSON
    Note over MK: Set Content-Length header

    MK-->>C: Masked JSON response

    %% --- Async operations ---
    Note over MK: Async: emit masking audit events
    MK--)SC: Async gRPC audit<br/>(fields masked, strategies used)

    alt NER enabled in config
        MK--)SC: Async gRPC DetectPII<br/>(body text, already_masked_paths[])
        alt Sidecar unavailable
            Note over MK: Skip NER, log WARN<br/>aria_mask_ner_skip_total++
        else Sidecar returns entities
            alt New PII found (not caught by regex)
                Note over SC: Log ALERT:<br/>ner_additional_pii_found
                Note over SC: Store finding for<br/>policy tuning (Postgres)
                SC--)R: Cache NER result for<br/>future regex rule generation
            end
        end
    end
```

**Key Design Decisions:**

- **Content-Type and body-size gates** run first to avoid unnecessary JSON parsing. Oversized bodies are passed through with a metric emitted so operators can tune `max_body_size` or investigate.
- **Three-level policy resolution** (consumer > route > fallback "redact") ensures that no response leaks unmasked PII even when configuration is incomplete -- the strictest strategy is the default.
- **Tokenization fallback:** When Redis is unavailable and the strategy is `tokenize`, the plugin falls back to `redact` rather than failing the request. This maintains availability at the cost of losing the reversible token mapping.
- **NER is asynchronous and optional:** The sidecar-based NER scan runs after the response has already been sent to the client (post-body_filter). Its purpose is to detect PII that regex missed, feeding back into policy tuning rather than blocking the response path.

---

## 4. Canary: Progressive Deployment Lifecycle

**Covers:** End-to-end canary deployment lifecycle from operator configuration through progressive traffic shifting, health monitoring, auto-rollback, manual overrides, and retry policies.

```mermaid
sequenceDiagram
    autonumber
    participant OP as Operator
    participant ADM as APISIX<br/>Admin API
    participant CN as APISIX<br/>(Canary Lua)
    participant R as Redis
    participant SC as Sidecar
    participant WH as Webhook

    %% --- Configuration ---
    OP->>ADM: PUT /apisix/routes/{id}<br/>plugins.aria-canary = {schedule, thresholds}
    ADM-->>OP: 200 OK

    Note over CN: Load schedule:<br/>[5%, 10%, 25%, 50%, 100%]<br/>State = STAGE_1 (5%)

    CN->>R: SET aria:canary:{route}:state STAGE_1
    CN->>R: SET aria:canary:{route}:pct 5

    %% --- Request Routing ---
    loop For each incoming request
        Note over CN: hash = crc32(client_ip) mod 100

        alt hash < traffic_pct (canary)
            CN->>CN: Route to canary_upstream
            Note over CN: Record: status, latency<br/>in sliding window (shared dict)
        else hash >= traffic_pct (baseline)
            CN->>CN: Route to baseline_upstream
            Note over CN: Record: status, latency<br/>in sliding window (shared dict)
        end

        Note over CN: Increment request counters<br/>in Redis (per-stage)
    end

    %% --- Health Check (timer-based) ---
    Note over CN: Timer fires after<br/>hold_duration expires

    CN->>R: GET canary + baseline<br/>error rates and latency

    alt Error delta > threshold_pct (2%)
        CN->>R: SET state = PAUSED
        CN--)WH: POST canary_health_breach<br/>{route, error_rates, stage}

        Note over CN: Start sustained breach timer<br/>(sustained_breach_seconds = 60)

        alt Breach sustained > 60s
            CN->>R: SET state = ROLLED_BACK
            CN->>R: SET pct = 0
            CN--)WH: POST aria_canary_rollback<br/>{trigger: "auto", retry_count}

            alt retry_policy = manual
                Note over CN: Terminal state.<br/>Operator must intervene.
            else retry_policy = auto
                Note over CN: Wait retry_cooldown (10m)
                alt retry_count < max_retries
                    CN->>R: INCR retry_count
                    CN->>R: SET state = STAGE_1, pct = 5
                    Note over CN: Restart from stage 1
                else retry_count >= max_retries
                    CN->>R: SET state = ROLLED_BACK_FINAL
                    CN--)WH: POST canary_max_retries_exhausted
                    Note over CN: Terminal state
                end
            end
        else Breach recovers within 60s
            CN->>R: SET state = RESUMED (current stage)
            CN--)WH: POST canary_resumed<br/>{route, stage}
            Note over CN: Reset hold timer,<br/>continue at current stage
        end

    else Latency p95 > baseline * multiplier (1.5x)
        CN->>R: SET state = PAUSED
        CN--)WH: POST canary_latency_breach<br/>{canary_p95, baseline_p95}
        Note over CN: Same sustained breach flow<br/>as error delta above

    else Both healthy + hold_duration elapsed
        alt Current stage is final (100%)
            CN->>R: SET state = PROMOTED, pct = 100
            CN--)WH: POST aria_canary_promoted<br/>{route, total_duration}
            Note over CN: Canary is now<br/>the production upstream
        else Not final stage
            Note over CN: ADVANCE to next stage
            CN->>R: SET state = STAGE_{n+1}<br/>pct = schedule[n+1].pct
            CN--)WH: POST canary_stage_advanced<br/>{from_stage, to_stage, pct}
            Note over CN: Reset hold timer for<br/>new stage duration
        end
    end

    %% --- Manual Overrides ---
    rect rgb(240, 240, 255)
        Note over OP,WH: Manual Override Paths

        OP->>ADM: POST /aria/canary/{route}/promote
        ADM->>CN: Update route config
        CN->>R: SET state = PROMOTED, pct = 100
        CN--)WH: POST canary_promoted<br/>{promoted_by: operator}

        OP->>ADM: POST /aria/canary/{route}/rollback
        ADM->>CN: Update route config
        CN->>R: SET state = ROLLED_BACK, pct = 0
        CN--)WH: POST canary_rollback<br/>{rolled_back_by: operator}

        OP->>ADM: POST /aria/canary/{route}/pause
        ADM->>CN: Update route config
        CN->>R: SET state = PAUSED
        Note over CN: Traffic holds at<br/>current percentage

        OP->>ADM: POST /aria/canary/{route}/resume
        ADM->>CN: Update route config
        CN->>R: SET state = current stage
        Note over CN: Resume hold timer<br/>from where paused
    end
```

**Key Design Decisions:**

- **Consistent hashing:** `crc32(client_ip) mod 100` ensures the same client consistently hits the same upstream during a canary, avoiding session-level inconsistencies. The `consistent_hash` config flag controls this behavior.
- **Sustained breach timer:** A single error spike does not trigger rollback. The error rate must remain above the threshold for `sustained_breach_seconds` (default 60s) to avoid rollback on transient blips.
- **Two-phase rollback:** PAUSE comes first, giving the system time to recover. Only if the breach is sustained does the canary proceed to ROLLED_BACK. This prevents unnecessary rollbacks during brief transient errors.
- **Retry policy:** When `retry_policy = auto`, the system waits `retry_cooldown` then restarts from stage 1, up to `max_retries` times. When `retry_policy = manual`, rollback is terminal and requires operator intervention. This prevents infinite retry loops while allowing automated recovery for transient deployment issues.
- **Metrics are kept in Lua shared dict** (per APISIX worker, aggregated on read) for the sliding window, with periodic flush to Redis for cross-worker and cross-restart consistency.

---

## 5. Sidecar: gRPC Request Lifecycle

**Covers:** Internal lifecycle of a gRPC request from Lua plugin through the Java 21 sidecar, including Unix Domain Socket transport, virtual thread creation, ScopedValue propagation, handler dispatch, and async response flow.

```mermaid
sequenceDiagram
    autonumber
    participant LP as Lua Plugin
    participant UDS as Unix Domain<br/>Socket
    participant GS as gRPC Server<br/>(Netty/UDS)
    participant VT as Virtual Thread<br/>(JDK 21)
    participant SV as ScopedValue<br/>Context
    participant HD as Handler<br/>(Shield/Mask/Canary)
    participant EX as External<br/>(Redis / Postgres)

    LP->>UDS: gRPC request over<br/>/var/run/aria/aria.sock
    Note over LP: cosocket non-blocking I/O<br/>Request includes: request_id,<br/>consumer_id, payload

    UDS->>GS: Deliver request frame

    Note over GS: gRPC server interceptor chain:<br/>1. MetricsInterceptor<br/>2. TracingInterceptor<br/>3. LoggingInterceptor

    %% --- Virtual Thread Creation ---
    GS->>VT: Thread.ofVirtual()<br/>.name("aria-req-{request_id}")<br/>.start(handler)

    Note over VT: Virtual thread pinning avoided:<br/>no synchronized blocks,<br/>use ReentrantLock instead

    %% --- ScopedValue Propagation ---
    VT->>SV: ScopedValue.where(REQUEST_CTX, ctx)

    Note over SV: ScopedValue bindings:<br/>- REQUEST_ID (trace correlation)<br/>- CONSUMER_ID (tenant isolation)<br/>- TRACE_SPAN (OpenTelemetry)<br/>- DEADLINE (gRPC deadline)

    SV->>HD: .run(() -> handler.process(request))

    %% --- Handler Dispatch ---
    alt ShieldService.AnalyzePrompt
        Note over HD: Load vector embeddings<br/>for injection patterns
        HD->>EX: Query vector similarity<br/>(in-process or Redis cache)
        EX-->>HD: Similarity scores
        Note over HD: Classify: is_injection,<br/>confidence_score, category
    else ShieldService.CountTokens
        Note over HD: Run tiktoken tokenizer<br/>(model-specific encoding)
        HD->>EX: GET/SET token cache (Redis)
        alt Delta detected (lua_estimate != exact)
            HD->>EX: INCRBY correction to Redis quota
        end
    else MaskService.DetectPII
        Note over HD: Run NER model<br/>(spaCy / custom ML)
        Note over HD: Cross-reference with<br/>already_masked_paths[]
        HD-->>HD: Build PiiEntity list
    else CanaryService.DiffResponses
        Note over HD: Structural JSON diff
        Note over HD: Calculate body_similarity
        HD-->>HD: Build DiffResponse
    end

    %% --- Response Path ---
    HD-->>SV: Handler returns response

    Note over SV: ScopedValue automatically<br/>unbound on exit

    SV-->>VT: Response object

    alt Handler throws exception
        Note over VT: Exception mapped to<br/>gRPC Status code:<br/>INTERNAL, UNAVAILABLE,<br/>DEADLINE_EXCEEDED
        VT-->>GS: gRPC error response
    else Handler succeeds
        VT-->>GS: gRPC success response
    end

    %% --- Async post-processing ---
    Note over VT: Virtual thread terminates<br/>(returned to carrier pool)

    alt Audit event generated
        GS--)EX: Async: INSERT INTO<br/>aria_audit_events (Postgres)<br/>(via separate virtual thread)
    end

    GS-->>UDS: gRPC response frame
    UDS-->>LP: Response delivered

    Note over LP: Deserialize protobuf<br/>Continue plugin pipeline

    alt gRPC DEADLINE_EXCEEDED
        UDS-->>LP: gRPC error: DEADLINE_EXCEEDED
        Note over LP: Treat as sidecar unavailable<br/>Apply fallback behavior<br/>(allow + WARN for Shield,<br/>skip NER for Mask)
    end

    alt UDS connection failure
        LP->>UDS: Connection refused / timeout
        Note over LP: cosocket error detected
        Note over LP: Increment:<br/>aria_sidecar_unavailable_total
        Note over LP: Apply fail-open policy<br/>(continue without sidecar)
    end
```

**Key Design Decisions:**

- **Unix Domain Socket (UDS):** Communication between Lua plugins and the Java sidecar uses `/var/run/aria/aria.sock` instead of TCP. UDS eliminates TCP overhead (no three-way handshake, no Nagle, no port exhaustion) and provides kernel-level access control via file permissions.
- **Virtual threads (JDK 21):** Each gRPC request is handled on a virtual thread rather than a platform thread. This allows the sidecar to handle thousands of concurrent requests without thread pool sizing concerns. The `synchronized` keyword is avoided in handler code to prevent virtual thread pinning.
- **ScopedValue over ThreadLocal:** `ScopedValue` (JDK 21) is used instead of `ThreadLocal` for request context propagation. ScopedValues are immutable within their scope, automatically cleaned up, and compatible with virtual threads without the memory leak risks of ThreadLocal.
- **Fail-open from Lua side:** When the sidecar is unreachable (UDS connection failure or gRPC deadline exceeded), the Lua plugin always continues with degraded functionality rather than blocking the request. The sidecar provides enhanced analysis but is never in the critical path for request completion.
- **gRPC interceptor chain** handles cross-cutting concerns (metrics, tracing, logging) before handler dispatch, keeping handler code focused on business logic.

---

## 6. Mask NER Bridge (HTTP, BR-MK-006)

**Covers:** Lua Mask plugin delegates named-entity detection to the sidecar over the HTTP bridge (`POST /v1/mask/detect`) per ADR-008, with two-layer circuit breaker (Lua outer via `aria-circuit-breaker.lua` `ngx.shared.dict` state + Java inner via Resilience4j) and fail-open/fail-closed policy. Shipped 2026-04-24.

```mermaid
sequenceDiagram
    autonumber
    participant U as Upstream
    participant MK as APISIX<br/>(Mask Lua)
    participant CB as aria-circuit-<br/>breaker.lua<br/>(ngx.shared.dict)
    participant MC as MaskController<br/>(@RestController)
    participant NDS as NerDetectionService<br/>(@Service + Resilience4j)
    participant CNE as CompositeNerEngine
    participant ONE as OpenNlpNer<br/>Engine (English)
    participant DJL as DjlHuggingFace<br/>NerEngine (Turkish)

    U->>MK: JSON response (body_filter)
    MK->>MK: regex PII scan first<br/>(don't send pre-classified fields to ML)
    MK->>MK: collect candidate fields<br/>(ner.sidecar.entity_strategy)

    MK->>CB: state(endpoint='mask-ner')?
    alt breaker OPEN
        CB-->>MK: state=OPEN
        MK->>MK: apply fail_mode<br/>(open: regex-only result;<br/>closed: redact all candidates)
        Note over MK: skip HTTP call,<br/>increment circuit_state metric
    else breaker CLOSED or HALF-OPEN
        CB-->>MK: state=CLOSED
        MK->>MC: POST /v1/mask/detect<br/>{text, language, max_bytes}<br/>(timeout: ner.sidecar.timeout_ms, default 200ms)

        alt sidecar 200 OK
            MC->>NDS: detect(text, language)
            Note over NDS: Resilience4j inner CB<br/>guards repeated downstream<br/>failures (separate from Lua CB)
            NDS->>CNE: detect(text, language)
            par OpenNLP English
                CNE->>ONE: detect(text)
                ONE-->>CNE: [PiiEntity ...]
            and DJL Turkish-BERT
                CNE->>DJL: detect(text)
                DJL-->>CNE: [PiiEntity ...]
            end
            CNE-->>NDS: union + dedup + min_confidence filter
            NDS-->>MC: List<PiiEntity>
            MC-->>MK: 200 { entities: [{type,start,end,score,source}, ...] }
            MK->>CB: record success
            MK->>MK: assign entities to fields<br/>(offset → field path)
            MK->>MK: apply mask strategy per BR-MK-004
        else sidecar 5xx / timeout
            MC--xMK: error / no response within deadline
            MK->>CB: record failure<br/>(if threshold → trip OPEN)
            MK->>MK: apply fail_mode
            Note over MK: increment ner_calls_total{result=fail}<br/>+ ner_circuit_state metric
        end
    end

    MK->>MK: emit aria_mask_ner_calls_total,<br/>aria_mask_ner_latency_ms,<br/>aria_mask_ner_entities_total{type}
```

**Key Design Decisions:**

- **Two-layer circuit breaker.** Outer (Lua, `ngx.shared.dict`-backed via `aria-circuit-breaker.lua`) short-circuits before the HTTP call when the bridge is unhealthy — saves the cost of a doomed connect. Inner (Java, Resilience4j) protects the engine itself from sustained downstream failures (model inference loop). Defense in depth.
- **Regex first, NER second.** The Lua side runs the 8-pattern regex scan before the bridge call so the ML model never sees fields already classified as structural PII (PAN/MSISDN/TC Kimlik/etc.). Reduces inference cost + avoids double-classification noise.
- **Fail-mode is a deployment policy, not a code path.** `fail_mode: open` (default, availability-first) returns regex-only results when the bridge is unreachable; `fail_mode: closed` (defensive) redacts all candidate fields. Operators choose per route.
- **HTTP/JSON not gRPC.** Per ADR-008 — zero `lua-resty-grpc` dependency, debuggable with `curl`, latency trade-off accepted at LLM scale (NER inference dominates the budget anyway).
- **Engine code is community tier; model artefacts are operator-supplied** for the slim image, or enterprise-DPO bundled. The pluggable `NerEngine` interface allows new languages to be added without changing the bridge contract.

---

## 7. Canary Shadow Diff (HTTP, BR-CN-007)

**Covers:** Lua Canary plugin captures baseline + shadow responses in the `log` phase, ships them to the sidecar's structural diff engine via `POST /v1/diff` (ADR-008), and emits per-field diff metrics. Iter 1 (Lua-only basic diff: status + body_length + latency) shipped 2026-04-22; Iter 2 + 2c (HTTP bridge to `DiffEngine`) shipped 2026-04-22 → 2026-04-23.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant CN as APISIX<br/>(Canary Lua)
    participant U1 as Upstream v1<br/>(baseline)
    participant U2 as Upstream v2<br/>(canary / shadow)
    participant CB as aria-circuit-<br/>breaker.lua
    participant DC as DiffController<br/>(@RestController)
    participant DE as DiffEngine<br/>(@Service)

    C->>CN: Request
    CN->>CN: hash(client_ip) % 100
    Note over CN: route decision per BR-CN-001<br/>(stable client experience<br/>via consistent hashing)

    par primary path
        CN->>U1: forward (hash >= shadow_pct → baseline)
        U1-->>CN: baseline response
    and shadow path (BR-CN-006, fire-and-forget)
        opt hash < shadow_pct AND no X-Aria-Shadow header
            CN->>U2: forward (X-Aria-Shadow: true,<br/>recursion guard)
            U2-->>CN: shadow response (captured, not returned)
        end
    end

    CN-->>C: baseline response

    Note over CN: log phase begins —<br/>not on critical path
    opt shadow response captured AND BR-CN-007 enabled
        CN->>CB: state(endpoint='canary-diff')?
        alt breaker OPEN
            CB-->>CN: state=OPEN
            CN->>CN: emit aria_shadow_diff_unavailable,<br/>skip diff
        else breaker CLOSED
            CB-->>CN: state=CLOSED
            CN->>DC: POST /v1/diff<br/>{ primary, shadow }<br/>(timeout: ~500ms)

            alt sidecar 200 OK
                DC->>DE: compare(primary, shadow)
                DE->>DE: compareStatus(int, int)
                DE->>DE: compareHeaders(Map, Map)
                DE->>DE: compareBodyStructure(byte[], byte[])
                DE-->>DC: DiffResult { score, diffPaths, summary }
                DC-->>CN: 200 { diff: {...} }
                CN->>CB: record success
                CN->>CN: emit aria_shadow_diff_count{type=status|headers|body}
            else sidecar 5xx / timeout
                DC--xCN: error
                CN->>CB: record failure<br/>(if threshold → trip OPEN)
                CN->>CN: emit aria_shadow_bridge_timeout
            end
        end
    end
```

**Key Design Decisions:**

- **Diff happens in log phase, never on critical path.** Client receives baseline response immediately; shadow + diff are pure observability work. Diff failures cannot affect user requests.
- **Shadow is fire-and-forget at the request level, but captured for diff.** The Lua side does not wait on the shadow upstream; it fires the request and stores the response in a per-request context for the log phase to analyse.
- **Recursion guard.** Shadow requests carry `X-Aria-Shadow: true`; the plugin refuses to shadow a request that already has the flag. Prevents shadow-of-shadow loops if v1 and v2 both route through the same Canary instance.
- **Cross-transport engine sharing (canonical pattern, ADR-008).** `DiffEngine` is a Spring `@Service` shared by `DiffController` (HTTP, Lua-callable) and `CanaryServiceImpl` (gRPC, forward-compat). One source of truth for the diff logic; transport is a thin wrapper.
- **Iter 1 vs Iter 2+2c+3.** Iter 1 (2026-04-22) was Lua-only basic diff (status + body_length + latency delta); useful immediately, no sidecar dependency. Iter 2 (structural body comparison) + Iter 2c (HTTP bridge wiring) + Iter 3 (operator-facing report format) added the deeper analysis. Iter 1 metrics remain emitted alongside the structural diff metrics — operators can disable the bridge and fall back to Iter 1 alone.

---

## 8. Audit Pipeline LPOP Drain (ADR-009)

**Covers:** Async audit pipeline — Lua plugins emit events to a Redis buffer; sidecar `audit/AuditFlusher` Spring `@Scheduled` job drains the buffer via LPOP and persists each event to PostgreSQL. Closes FINDING-003. Shipped 2026-04-25 (`aria-runtime@d487026`).

```mermaid
sequenceDiagram
    autonumber
    participant L as Lua plugins<br/>(Shield + Mask)
    participant R as Redis<br/>(aria:audit_buffer)
    participant AF as AuditFlusher<br/>(@Component @Scheduled)
    participant PC as PostgresClient<br/>(R2DBC)
    participant PG as PostgreSQL<br/>(audit_events)

    Note over L: PII pre-masked Lua-side<br/>(BR-SH-015 / BR-MK-005)
    L->>R: LPUSH aria:audit_buffer<br/>(JSON event, 1h TTL)
    Note over L,R: NO request critical-path<br/>blocking — fire-and-forget

    loop every 5s (configurable: aria.audit.flush-interval-ms)
        AF->>R: LPOP aria:audit_buffer
        alt empty
            R-->>AF: nil
            Note over AF: tick ends, wait next interval
        else event present
            R-->>AF: JSON event

            alt parse OK
                AF->>AF: AuditEvent.fromJson(mapper, json)
                AF->>PC: insertAuditEvent(...)
                PC->>PG: INSERT INTO audit_events<br/>(append-only;<br/>DO INSTEAD NOTHING<br/>on UPDATE/DELETE)
                PG-->>PC: ack
                PC-->>AF: ok
                AF->>AF: persistedTotal++
            else parse failure (poison message)
                AF->>AF: log ERROR + raw event,<br/>failedTotal++,<br/>drop event<br/>(v0.3 candidate: dead-letter queue)
            end

            Note over AF: continues loop until<br/>MAX_PER_TICK (100) reached<br/>OR queue empty
        end

        opt unexpected exception (e.g. Redis blip)
            Note over AF: tick aborts gracefully;<br/>Lettuce auto-reconnects;<br/>next tick retries
        end
    end

    Note over PC,PG: Postgres rules enforce immutability:<br/>tamper-proof once persisted
```

**Key Design Decisions (ADR-009):**

- **LPOP polling chosen over HTTP bridge** (Karar A) per Levent's *"neden iki path?"* pushback against the hybrid alternative. Lua side already pushes to Redis correctly — adding an HTTP call would either (a) sync = adds latency to critical path, or (b) fire-and-forget = drops events on sidecar restart. LPOP polling decouples the pipeline; sidecar restart safety is free (events sit in Redis with 1h TTL).
- **ADR-008 not invalidated.** ADR-008 governs synchronous Lua→sidecar request/response (`/v1/diff`, `/v1/mask/detect`). Audit is asynchronous Lua emit → Redis buffer → sidecar drain. Orthogonal patterns.
- **Bounded per-tick batch (`MAX_PER_TICK=100`).** Prevents one long-running tick from monopolising the scheduler thread under burst load. Remaining events drain on the next tick.
- **Poison-message containment.** A single bad event does not stall the whole pipeline — it logs at ERROR with the raw payload, increments `failedTotal`, and drops. v0.3 candidate: dead-letter queue (`aria:audit_dead_letter`) for operator-driven replay.
- **No new ARIA error code emitted by the closed pipeline.** The v1.1-era `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` was retired in v1.1.1 (Karar A). Operators monitor health via `persistedTotal` / `failedTotal` Prometheus counters.

---

## Cross-Cutting Concerns

### Error Propagation Summary (v1.1.3)

| Origin | Failure Mode | Shield Behavior | Mask Behavior | Canary Behavior |
|--------|-------------|-----------------|---------------|-----------------|
| Redis | Connection timeout | Configurable: fail_open or fail_closed (BR-SH-005) | Tokenize falls back to redact | Use last-known state from shared dict |
| Sidecar HTTP loopback | Connection refused / timeout | n/a (Shield does not call sidecar in v0.1 hot path; v0.3 enterprise prompt-injection would go here) | Lua circuit breaker trips → apply `ner.sidecar.fail_mode` (open: regex-only result; closed: redact candidates) | Lua circuit breaker trips → emit `aria_shadow_bridge_timeout`, skip diff (no impact on baseline response) |
| Sidecar HTTP loopback | 5xx response | n/a in v0.1 | Same as above (failure record → may trip Lua breaker) | Same as above |
| Sidecar gRPC | n/a in v0.1 | n/a | n/a | n/a — gRPC services exist as forward-compat per ADR-008; no Lua callers |
| LLM Provider | 5xx response | Circuit breaker, try fallback chain (BR-SH-002) | n/a | n/a |
| LLM Provider | Timeout | 504 to client (after fallback chain exhausted) | n/a | n/a |
| Postgres | `insertAuditEvent` failure | Event remains in Redis buffer until next AuditFlusher tick (Lettuce auto-reconnects); per-event persist failure → `failedTotal++` + ERROR log + drop (poison-message containment per ADR-009) | Same as Shield (shared audit pipeline) | n/a (canary writes no audit events directly) |
| Postgres | Sidecar startup, table missing | Flyway applies V001..V003 migrations idempotently per FINDING-005 closure (v0.1.1); if Flyway disabled (`ARIA_FLYWAY_ENABLED=false`) and table absent, `AuditFlusher` ERROR-logs each drained event — failure surfaces, not silenced | Same as Shield | n/a |

### Async Operation Guarantees (v1.1.3)

All async operations (audit drain, token reconciliation, webhook notifications, shadow diff requests) use fire-and-forget semantics from the request critical path with the following safety nets:

1. **Metrics:** Every async failure increments a dedicated Prometheus counter so operators detect silent failures (`aria_*_failed_total`, `AuditFlusher.failedTotal`, `aria_shadow_bridge_timeout`, `aria_mask_ner_calls_total{result=fail}`).
2. **Bounded retry semantics:** AuditFlusher retries on every tick (default 5s) with no per-event backoff — Redis 1h TTL is the operator-visible bound. Lua circuit breakers (`aria-circuit-breaker.lua`) apply per-endpoint cool-down windows after failure thresholds trip.
3. **No request blocking:** No async operation can delay or block the client response. NER bridge, shadow diff, and audit emit are all post-response or background work.
4. **Sidecar-side resilience:** Lettuce auto-reconnects to Redis on transient failures; AuditFlusher tick aborts gracefully on unexpected exceptions and the next tick retries (poison-message containment ensures one bad event doesn't stall the pipeline).

---

*Document Version: 1.1.3 | Created: 2026-04-08 | Revised: 2026-04-25 (v1.1.3 spec-coherence sweep)*
*Status: v1.1.3 Draft — Pending Human Approval (part of doc-set audit Wave 3)*
*Change log v1.0 → v1.1.3: §6 NEW (NER bridge per BR-MK-006 — two-layer circuit breaker, fail-mode policy, ADR-008 HTTP bridge); §7 NEW (Canary shadow diff per BR-CN-007 — Iter 1+2+2c+3 history, log-phase analysis, recursion guard); §8 NEW (Audit pipeline LPOP drain per ADR-009 — Karar A vs Karar B rationale, poison-message containment, MAX_PER_TICK bound); §5 title retained for continuity but ToC entry now notes "forward-compat only in v0.1, HTTP bridge canonical"; Cross-Cutting Concerns table rebuilt (transport rows: UDS → HTTP loopback per ADR-008; Postgres-failure row reflects AuditFlusher buffer-and-retry behaviour rather than v1.0 "audit event dropped"); Async Operation Guarantees rewritten to reflect ADR-009 + Lua circuit breaker semantics.*
