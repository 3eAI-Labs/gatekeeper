# Sequence Diagrams — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 4 — Design
**Version:** 1.0
**Date:** 2026-04-08
**Author:** AI Architect + Human Oversight
**Input:** HLD.md v1.0, API_CONTRACTS.md v1.0, INTEGRATION_MAP.md v1.0

---

## Table of Contents

1. [Shield: LLM Request (Full Flow)](#1-shield-llm-request-full-flow)
2. [Shield: SSE Streaming Flow](#2-shield-sse-streaming-flow)
3. [Mask: Response Masking Flow](#3-mask-response-masking-flow)
4. [Canary: Progressive Deployment Lifecycle](#4-canary-progressive-deployment-lifecycle)
5. [Sidecar: gRPC Request Lifecycle](#5-sidecar-grpc-request-lifecycle)

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

## Cross-Cutting Concerns

### Error Propagation Summary

| Origin | Failure Mode | Shield Behavior | Mask Behavior | Canary Behavior |
|--------|-------------|-----------------|---------------|-----------------|
| Redis | Connection timeout | Configurable: fail_open or fail_closed | Tokenize falls back to redact | Use last-known state from shared dict |
| Sidecar (UDS) | Connection refused | Allow + WARN log | Skip NER | N/A (canary does not use sidecar in hot path) |
| Sidecar (gRPC) | DEADLINE_EXCEEDED | Allow + WARN log | Skip NER | N/A |
| LLM Provider | 5xx response | Circuit breaker, try fallback | N/A | N/A |
| LLM Provider | Timeout | 504 to client | N/A | N/A |
| Postgres | Insert failure | Audit event dropped + WARN metric | Audit event dropped + WARN metric | Audit event dropped + WARN metric |

### Async Operation Guarantees

All async operations (audit writes, token reconciliation, NER scans, webhook notifications) use fire-and-forget semantics with the following safety nets:

1. **Metrics:** Every async failure increments a dedicated Prometheus counter so operators can detect silent failures.
2. **Retry in sidecar:** The sidecar batches Postgres audit writes and retries with exponential backoff (up to 3 attempts).
3. **No request blocking:** No async operation can delay or block the client response.

---

*Document Version: 1.0 | Created: 2026-04-08*
*Status: Draft -- Pending Human Approval*
