# High-Level Design (HLD) — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 3 — Architecture
**Version:** 1.0
**Date:** 2026-04-08
**Author:** AI Architect + Human Oversight
**Input:** BUSINESS_LOGIC.md v1.0, DECISION_MATRIX.md v1.0, EXCEPTION_CODES.md v1.0

---

## 1. System Scope & Goals

### 1.1 Business Objectives

3e-Aria-Gatekeeper is a modular governance suite for Apache APISIX that solves three enterprise API concerns at the gateway layer:

| Objective | Module | Success Metric |
|-----------|--------|---------------|
| Control AI costs and prevent prompt attacks | Shield | Token spend under budget, injection attempts blocked |
| Enforce data privacy compliance at the edge | Mask | PII masked per GDPR/KVKK, zero unmasked PII leaks |
| Eliminate blind canary deployments | Canary | Auto-rollback within 5s, zero 3AM manual interventions |

### 1.2 System Boundaries

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       SYSTEM BOUNDARY                                   │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    Apache APISIX (Host)                            │  │
│  │                                                                   │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │  │
│  │  │ Lua Plugin:  │  │ Lua Plugin:  │  │ Lua Plugin:  │              │  │
│  │  │ aria-shield  │  │ aria-mask    │  │ aria-canary  │              │  │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │  │
│  │         │                 │                 │                      │  │
│  │         └────────────┬────┴────────────┬────┘                      │  │
│  │                      │  gRPC / UDS     │                           │  │
│  │              ┌───────▼─────────────────▼───────┐                   │  │
│  │              │   Java 21 Sidecar (Aria Runtime) │                   │  │
│  │              │   • Shield handlers              │                   │  │
│  │              │   • Mask handlers                │                   │  │
│  │              │   • Canary handlers              │                   │  │
│  │              └───────┬─────────────────┬───────┘                   │  │
│  └──────────────────────┼─────────────────┼──────────────────────────┘  │
│                         │                 │                              │
│              ┌──────────▼──────┐  ┌───────▼──────────┐                  │
│              │  Redis Cluster   │  │  PostgreSQL       │                  │
│              │  (quotas, cache) │  │  (audit, billing) │                  │
│              └─────────────────┘  └──────────────────┘                  │
└─────────────────────────────────────────────────────────────────────────┘
         │                                              │
    ─────┼──────── TRUST BOUNDARY ──────────────────────┼─────
         │                                              │
    ┌────▼─────┐                                   ┌────▼─────┐
    │ Clients  │                                   │  LLM     │
    │ (Apps)   │                                   │ Providers │
    └──────────┘                                   └──────────┘
```

### 1.3 What This System Is NOT
- NOT a standalone API gateway (it's plugins for APISIX)
- NOT a replacement for WAF (complements it)
- NOT an LLM provider (routes to existing providers)
- NOT a database service (uses external Redis + Postgres)

---

## 2. Platform Architecture

### 2.1 Adapted Platform Stack

Since Aria is an APISIX plugin suite (not a standalone microservice), the standard platform stack is adapted:

| Platform Service | Standard Approach | Aria Adaptation | ADR |
|-----------------|-------------------|----------------|-----|
| Authentication | Keycloak via platform libs | N/A — APISIX handles auth. Aria trusts consumer identity from APISIX context | ADR-001 |
| API Gateway | APISIX | Inherent — Aria IS an APISIX plugin | — |
| Monitoring | Prometheus + Grafana | `aria_*` metrics on APISIX metrics endpoint. Pre-built Grafana dashboards | — |
| Logging | Loki (JSON structured) | JSON structured logging to stdout (Loki-compatible) | — |
| Tracing | OpenTelemetry → Jaeger | OTel spans for sidecar gRPC calls | — |
| Database | PostgreSQL 18.1+ | Central Postgres for audit/billing | — |
| Cache | Redis Cluster | Central Redis for quotas, tokens, state | — |
| Message Queue | Kafka (KRaft) | Not used in v1.0 — all communication is synchronous (gRPC/UDS) or fire-and-forget | ADR-006 |
| Frontend | React 18 + Refine | Deferred — Grafana dashboards + ariactl CLI for v1.0 | ADR-007 |

### 2.2 Deployment Topology

```
┌─────────────────── Kubernetes Cluster ────────────────────┐
│                                                            │
│  ┌─────────── Pod: apisix-node-N ──────────────────────┐  │
│  │                                                      │  │
│  │  Container 1: APISIX                                 │  │
│  │  ├── Lua plugins: aria-shield, aria-mask, aria-canary│  │
│  │  ├── Port 9080 (HTTP), 9443 (HTTPS)                 │  │
│  │  └── Port 9091 (Prometheus metrics)                  │  │
│  │                                                      │  │
│  │  Container 2: Aria Runtime (Java 21 Sidecar)         │  │
│  │  ├── gRPC over /var/run/aria/aria.sock (UDS)         │  │
│  │  ├── Port 8081 (/healthz, /readyz)                   │  │
│  │  └── Memory: 256MB-512MB, CPU: 0.5-1.0              │  │
│  │                                                      │  │
│  │  Shared Volume: /var/run/aria/ (UDS socket)          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ┌─────────── External Services ───────────────────────┐  │
│  │  Redis Cluster (3+ nodes)                            │  │
│  │  PostgreSQL (primary + replica)                      │  │
│  │  Prometheus (scrape target: APISIX :9091)            │  │
│  │  Grafana (dashboards provisioned from JSON)          │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### 2.3 Technology Stack

| Layer | Technology | Version | Rationale | ADR |
|-------|-----------|---------|-----------|-----|
| Plugin runtime | Lua 5.1 / LuaJIT (OpenResty) | APISIX-bundled | Zero overhead, Nginx event loop | ADR-002 |
| Heavy processing | Java 21 (Virtual Threads) | 21 LTS | Concurrent AI requests, NLP/NER, tiktoken | ADR-002 |
| IPC | gRPC over Unix Domain Socket | gRPC 1.60+ | ~0.1ms latency, no TCP overhead | ADR-003 |
| Quota/state store | Redis 7+ (Cluster) | 7.2+ | Sub-ms reads for pre-flight checks | ADR-004 |
| Audit/billing store | PostgreSQL 18.1+ | 18.1+ | ACID, immutable audit trail | ADR-004 |
| High-perf masking | WASM (Rust) | Optional | Complex patterns at scale | ADR-005 |
| Metrics | Prometheus (`aria_*`) | — | Native APISIX integration | — |
| Dashboards | Grafana (JSON provisioning) | 10+ | Pre-built, zero manual setup | — |
| CLI | ariactl (Go or Java native) | — | APISIX Admin API wrapper | — |

---

## 3. Module Decomposition

### 3.1 Module A: aria-shield (Lua Plugin)

**Tech Stack:** Lua 5.1 (APISIX plugin)
**Deployment:** APISIX plugin directory (hot-reloadable)
**File:** `apisix/plugins/aria-shield.lua`

**Primary Responsibility:**
AI governance at the gateway layer — token quota enforcement, prompt security scanning, multi-provider LLM routing with failover.

**Key Features:**
1. Multi-provider request transformation (BR-SH-001)
2. Circuit breaker with auto-failover (BR-SH-002)
3. SSE streaming pass-through (BR-SH-003)
4. OpenAI SDK compatibility (BR-SH-004)
5. Token quota pre-flight check (BR-SH-005)
6. Overage policy enforcement (BR-SH-010)
7. Prompt injection regex detection (BR-SH-011, Lua tier)
8. PII-in-prompt regex scanning (BR-SH-012, Lua tier)
9. Usage metrics emission (BR-SH-008)

**Internal Dependencies:**
- Redis: Quota state, circuit breaker state, latency tracking
- Aria Runtime (sidecar): Token reconciliation, deep prompt analysis, NER

**APISIX Plugin Phases Used:**

| Phase | Shield Activity |
|-------|----------------|
| `access` | Quota pre-flight check, prompt security scan, provider routing decision |
| `header_filter` | Add X-Aria-* response headers |
| `body_filter` | Extract `usage.total_tokens` from response, update quota |
| `log` | Emit Prometheus metrics, send async audit event |

**Configuration Schema:**
```json
{
  "provider": "openai",
  "fallback_providers": ["anthropic", "google"],
  "api_key_secret": "$secret://aria/openai-key",
  "quota": {
    "daily_tokens": 100000,
    "monthly_tokens": 1000000,
    "monthly_dollars": 500.00,
    "overage_policy": "block",
    "fail_policy": "fail_open"
  },
  "security": {
    "prompt_injection": { "enabled": true, "action": "block" },
    "pii_scanner": { "enabled": true, "action": "mask" },
    "response_filter": { "enabled": false }
  },
  "routing": {
    "strategy": "failover",
    "circuit_breaker": {
      "failure_threshold": 3,
      "cooldown_seconds": 30
    }
  },
  "model_pin": null,
  "pricing_table": "default"
}
```

---

### 3.2 Module B: aria-mask (Lua Plugin)

**Tech Stack:** Lua 5.1 (APISIX plugin), optional WASM (Rust)
**Deployment:** APISIX plugin directory (hot-reloadable)
**File:** `apisix/plugins/aria-mask.lua`

**Primary Responsibility:**
Dynamic data masking in API responses — field-level JSONPath masking with role-based policies, automatic PII pattern detection, compliance audit logging.

**Key Features:**
1. JSONPath field masking (BR-MK-001)
2. Role-based policy resolution (BR-MK-002)
3. PII pattern regex detection (BR-MK-003)
4. Configurable mask strategies (BR-MK-004)
5. Masking audit event recording (BR-MK-005)

**Internal Dependencies:**
- Redis: Tokenization store (for `tokenize` strategy)
- Aria Runtime (sidecar): NER-based PII detection (async)

**APISIX Plugin Phases Used:**

| Phase | Mask Activity |
|-------|--------------|
| `access` | Read consumer role from APISIX context, load role policy |
| `body_filter` | Parse JSON response, apply JSONPath masking rules, apply PII auto-detection |
| `log` | Emit masking audit event (async), emit Prometheus metrics |

**Configuration Schema:**
```json
{
  "rules": [
    { "path": "$.customer.email", "strategy": "mask:email", "field_type": "email" },
    { "path": "$.customer.phone", "strategy": "mask:phone", "field_type": "phone" },
    { "path": "$.payment.card_number", "strategy": "last4", "field_type": "pan" }
  ],
  "role_policies": {
    "admin": { "default_strategy": "full" },
    "support_agent": { "default_strategy": "mask" },
    "external_partner": { "default_strategy": "redact" }
  },
  "auto_detect": {
    "enabled": true,
    "patterns": ["pan", "msisdn", "tc_kimlik", "email", "iban", "imei", "ip", "dob"]
  },
  "max_body_size": 10485760,
  "hash_salt_secret": "$secret://aria/mask-hash-salt",
  "ner_enabled": false
}
```

---

### 3.3 Module C: aria-canary (Lua Plugin)

**Tech Stack:** Lua 5.1 (APISIX plugin)
**Deployment:** APISIX plugin directory (hot-reloadable)
**File:** `apisix/plugins/aria-canary.lua`

**Primary Responsibility:**
Intelligent progressive delivery — configurable canary schedules with automatic stage progression, error-rate monitoring, latency guard, auto-rollback, and traffic shadowing.

**Key Features:**
1. Progressive traffic splitting with consistent hashing (BR-CN-001)
2. Error rate comparison (canary vs. baseline) (BR-CN-002)
3. Auto-rollback on sustained breach (BR-CN-003)
4. Latency guard (P95 comparison) (BR-CN-004)
5. Manual override via Admin API extension (BR-CN-005)
6. Traffic shadowing (BR-CN-006)

**Internal Dependencies:**
- Redis: Canary state, error rate counters, latency histograms
- Aria Runtime (sidecar): Shadow diff engine (async)

**APISIX Plugin Phases Used:**

| Phase | Canary Activity |
|-------|----------------|
| `access` | Route decision: canary vs. baseline (weighted random / consistent hash) |
| `header_filter` | Tag response with upstream version |
| `body_filter` | Collect status for error rate tracking |
| `log` | Update error rate counters, check stage progression, trigger rollback if needed |

**Canary State (Redis):**
```json
{
  "route_id": "route-api-v2",
  "state": "STAGE_2",
  "current_stage_index": 1,
  "traffic_pct": 10,
  "stage_started_at": "2026-04-08T14:00:00Z",
  "schedule": [
    { "pct": 5, "hold": "5m" },
    { "pct": 10, "hold": "5m" },
    { "pct": 25, "hold": "10m" },
    { "pct": 50, "hold": "10m" },
    { "pct": 100, "hold": "0" }
  ],
  "retry_count": 0,
  "retry_policy": "manual",
  "max_retries": 3,
  "canary_upstream": "upstream-v2",
  "baseline_upstream": "upstream-v1"
}
```

---

### 3.4 Aria Runtime (Java 21 Sidecar)

**Tech Stack:** Java 21 (Virtual Threads, ScopedValue), gRPC, Spring Boot 3.x or Micronaut
**Deployment:** Sidecar container in APISIX pod
**Base Package:** `com.eai.aria.runtime`

**Primary Responsibility:**
Heavy-computation backend for Lua plugins — prompt analysis, exact token counting, NER-based PII detection, shadow response diff engine. All operations are non-blocking with virtual threads.

**Module Structure:**

```
aria-runtime/
├── core/                    # gRPC server, health checks, lifecycle
│   ├── GrpcServer.java      # UDS listener, handler registry
│   ├── HealthController.java # /healthz, /readyz
│   └── ShutdownManager.java # Graceful drain
├── shield/                  # Shield module handlers
│   ├── PromptAnalyzer.java  # Vector similarity injection detection
│   ├── TokenCounter.java    # tiktoken-exact counting
│   └── ContentFilter.java   # Response content moderation
├── mask/                    # Mask module handlers
│   └── NerDetector.java     # Named entity recognition
├── canary/                  # Canary module handlers
│   └── DiffEngine.java      # Shadow response comparison
├── common/                  # Shared utilities
│   ├── RedisClient.java     # Async Redis operations
│   ├── PostgresClient.java  # Async Postgres operations
│   └── RequestContext.java  # ScopedValue definitions
└── proto/                   # gRPC service definitions
    └── aria/sidecar/v1/
        ├── shield.proto
        ├── mask.proto
        ├── canary.proto
        └── health.proto
```

**gRPC Services Exposed:**

| Service | Methods | Module |
|---------|---------|--------|
| `ShieldService` | `AnalyzePrompt`, `CountTokens`, `FilterResponse` | Shield |
| `MaskService` | `DetectPII` | Mask |
| `CanaryService` | `DiffResponses` | Canary |
| `HealthService` | `Check` | Core |

**NFRs:**
- Startup: < 3 seconds
- Memory: 256MB base, 512MB max
- Concurrent virtual threads: 10K+
- gRPC round-trip (UDS): < 0.5ms

---

### 3.5 ariactl CLI

**Tech Stack:** Go (single binary) or Java native-image (GraalVM)
**Deployment:** Standalone binary, distributed via GitHub releases

**Primary Responsibility:**
CLI wrapper around APISIX Admin API for Aria-specific operations.

**Commands:**

| Command | Description | APISIX API |
|---------|-------------|------------|
| `ariactl quota set` | Configure token/dollar quotas | PATCH route/consumer metadata |
| `ariactl quota status` | Show current usage vs. budget | GET Redis state via Admin API ext |
| `ariactl mask rules list` | List masking rules for a route | GET route metadata |
| `ariactl canary status` | Show canary stage and error rates | GET Redis state via Admin API ext |
| `ariactl canary promote` | Instantly promote to 100% | POST Admin API extension |
| `ariactl canary rollback` | Instantly rollback to 0% | POST Admin API extension |
| `ariactl pricing update` | Update model pricing table | PATCH global plugin metadata |

---

## 4. Interface & Data Contracts

See `API_CONTRACTS.md` for full OpenAPI and gRPC specifications.

### 4.1 External Interfaces

| Interface | Protocol | Direction | Auth | Rate Limit |
|-----------|----------|-----------|------|-----------|
| Client → APISIX (Shield) | HTTPS (OpenAI-compatible REST) | Inbound | APISIX consumer auth (key-auth, JWT, etc.) | APISIX rate-limiting plugin |
| Client → APISIX (Mask) | HTTPS (any REST API) | Inbound | APISIX consumer auth | APISIX rate-limiting plugin |
| Client → APISIX (Canary) | HTTPS (any REST API) | Inbound | APISIX consumer auth | APISIX rate-limiting plugin |
| Operator → APISIX Admin API | HTTPS | Inbound | APISIX Admin API key (L4) | Internal only |
| APISIX → LLM Providers | HTTPS | Outbound | Provider API key (L4) | Provider-managed |
| APISIX → Upstream Services | HTTP/HTTPS | Outbound | Pass-through | N/A |
| Shield → Webhook/Slack | HTTPS | Outbound | Webhook URL | 3 retries |

### 4.2 Internal Interfaces

| Interface | Protocol | Direction | Auth | Latency Target |
|-----------|----------|-----------|------|---------------|
| Lua Plugin ↔ Aria Runtime | gRPC over UDS | Bidirectional | File-system permissions (0660) | < 0.5ms |
| Lua Plugin → Redis | TCP (TLS) | Outbound | Redis AUTH | < 2ms |
| Aria Runtime → Redis | TCP (TLS) | Outbound | Redis AUTH | < 2ms |
| Aria Runtime → PostgreSQL | TCP (TLS) | Outbound | User/password | < 5ms |

### 4.3 Error Response Standard

All Aria error responses follow the OpenAI error format (for Shield) or a standard Aria envelope:

```json
{
  "error": {
    "type": "aria_error",
    "code": "ARIA_SH_QUOTA_EXCEEDED",
    "message": "Human-readable description",
    "aria_request_id": "aria-req-abc123",
    "details": {}
  }
}
```

See `EXCEPTION_CODES.md` for the full catalog.

---

## 5. Security & Access Control

### 5.1 Trust Boundaries

```
UNTRUSTED          │           TRUSTED (within APISIX)
                   │
Client ────────────┤──── APISIX Consumer Auth ────── Lua Plugins
                   │                                      │
                   │                                 UDS (local)
                   │                                      │
                   │                               Aria Runtime
                   │                                  │       │
                   │                              TLS 1.3  TLS 1.3
                   │                                  │       │
LLM Providers ─────┤──── API Key Auth ──────── Redis   Postgres
                   │
```

### 5.2 Authentication Model

Aria does NOT implement its own authentication. It relies entirely on APISIX's consumer authentication plugins:

| Concern | Handled By |
|---------|-----------|
| Client identity | APISIX auth plugins (key-auth, jwt-auth, openid-connect) |
| Consumer metadata (role, quota config) | APISIX consumer metadata |
| Admin API access | APISIX Admin API key |
| LLM provider auth | Provider API keys in APISIX secrets |
| Sidecar access | UDS file permissions (not network-accessible) |

### 5.3 Permission Matrix (Aria-Specific)

| Feature | Admin (APISIX Admin API) | Consumer (API client) | ariactl |
|---------|------------------------|----------------------|---------|
| Configure quotas | Yes | No | Yes (via Admin API) |
| Configure masking rules | Yes | No | Yes (via Admin API) |
| Configure canary schedule | Yes | No | Yes (via Admin API) |
| View own quota status | N/A | Yes (via response headers) | N/A |
| Promote/rollback canary | Yes | No | Yes |
| View audit logs | Yes (Postgres direct) | No | Future |
| Access Grafana dashboards | Yes (Grafana auth) | No | N/A |

### 5.4 Data Protection Controls

| Data | Protection | Implementation |
|------|-----------|----------------|
| Provider API keys (L4) | Encrypted at rest, never logged | APISIX secrets vault integration |
| Tokenization mappings (L4) | AES-256 encrypted in Redis | Application-level encryption |
| Audit log payload excerpts (L3) | PII masked before storage | BR-SH-015, BR-MK-005 |
| Redis quota data (L2) | TLS 1.3 in transit | Redis TLS configuration |
| Postgres audit data (L2-L3) | TDE at rest, TLS 1.3 in transit | Database-level encryption |
| gRPC/UDS traffic | File-system isolation | UDS — no network exposure |

### 5.5 Threat Model (STRIDE)

| Threat | Category | Target | Mitigation | Control |
|--------|----------|--------|------------|---------|
| Attacker bypasses quota by spoofing consumer ID | Spoofing | Shield quota | Consumer identity validated by APISIX auth plugins before Aria processes request | APISIX auth |
| Tampering with quota counts in Redis | Tampering | Shield quota | Redis AUTH + TLS. Redis ACLs restrict write access to Aria-specific keys | Redis ACL |
| User denies sending a prompt injection | Repudiation | Shield audit | Immutable audit trail with masked prompt excerpt, consumer ID, timestamp | BR-SH-015 |
| PII leaks through API responses | Information Disclosure | Mask | Field-level masking + auto-detection at gateway edge | BR-MK-001-003 |
| Prompt injection hijacks LLM behavior | Elevation of Privilege | Shield | Regex + vector-similarity detection pipeline | BR-SH-011 |
| PII sent to third-party LLM provider | Information Disclosure | Shield | PII-in-prompt scanner blocks/masks before forwarding | BR-SH-012 |
| DoS via large request bodies | Denial of Service | All plugins | APISIX request body size limits + `max_body_size` config | APISIX + config |
| Attacker extracts system prompts via LLM | Information Disclosure | Shield | Data exfiltration guard detects extraction patterns | BR-SH-014 |
| Admin API key compromise | Elevation of Privilege | All modules | Admin API restricted to internal network. Key rotation policy | Network policy |
| Sidecar process crash exposes data | Information Disclosure | Runtime | UDS socket cleaned up on shutdown. No persistent data in sidecar memory | BR-RT-004 |

---

## 6. Observability Strategy

### 6.1 Metrics (Prometheus)

All metrics use the `aria_` prefix and are exposed on the APISIX Prometheus endpoint.

**Shield Metrics:**

| Metric | Type | Labels | Alert Threshold |
|--------|------|--------|----------------|
| `aria_tokens_consumed` | counter | consumer, model, route, type | N/A (dashboard) |
| `aria_cost_dollars` | counter | consumer, model, route | N/A (dashboard) |
| `aria_requests_total` | counter | consumer, model, route, status | error rate > 5% for 5m |
| `aria_request_latency_seconds` | histogram | consumer, model, route | P95 > 10s for 5m |
| `aria_circuit_breaker_state` | gauge | provider, route | state=open for > 5m |
| `aria_quota_utilization_pct` | gauge | consumer, period | > 90% |
| `aria_overage_requests` | counter | consumer, policy | > 0 |
| `aria_security_events_total` | counter | event_type | > 0 for injection |

**Mask Metrics:**

| Metric | Type | Labels | Alert Threshold |
|--------|------|--------|----------------|
| `aria_mask_applied` | counter | field_type, strategy, consumer | N/A (dashboard) |
| `aria_mask_violations` | counter | type | > 0 (auto-detected PII not covered by rules) |
| `aria_mask_latency_seconds` | histogram | engine | P95 > 5ms |

**Canary Metrics:**

| Metric | Type | Labels | Alert Threshold |
|--------|------|--------|----------------|
| `aria_canary_traffic_pct` | gauge | route | N/A (dashboard) |
| `aria_canary_error_rate` | gauge | route, version | delta > threshold |
| `aria_canary_latency_p95` | gauge | route, version | canary > baseline * 1.5 |
| `aria_canary_rollback_total` | counter | route | > 0 |

**System Metrics:**

| Metric | Type | Labels | Alert Threshold |
|--------|------|--------|----------------|
| `aria_sidecar_unavailable` | gauge | — | > 0 for > 5m |
| `aria_quota_redis_unavailable` | counter | — | > 0 |
| `aria_audit_buffer_overflow` | counter | — | > 0 |
| `aria_metrics_cardinality_exceeded` | counter | — | > 0 |

### 6.2 Logging

JSON structured logging to stdout (Loki-compatible):

```json
{
  "timestamp": "2026-04-08T14:30:00.123Z",
  "level": "INFO",
  "service": "aria-runtime",
  "module": "shield",
  "trace_id": "abc-123",
  "span_id": "def-456",
  "consumer_id": "team-a",
  "message": "Prompt injection detected and blocked",
  "context": {
    "route_id": "route-llm-proxy",
    "detection_source": "regex",
    "confidence": "HIGH",
    "pattern_category": "direct_override"
  }
}
```

**Log Level Policy:**

| Level | Usage | Examples |
|-------|-------|---------|
| ERROR | System failures, data loss risk | Redis connection failed, audit buffer overflow |
| WARN | Degradation, unexpected but handled | Sidecar unavailable (degraded), unknown model pricing |
| INFO | Business events, lifecycle | Plugin loaded, canary promoted, rollback executed |
| DEBUG | Development troubleshooting | Request transformation details (disabled in prod) |

**PII in Logs:** L3/L4 data MUST be masked in all log output. Prompt content is never logged in full — only masked excerpts in audit events.

### 6.3 Distributed Tracing

OpenTelemetry spans for sidecar gRPC calls:

```
[client request]
  └── [apisix.aria-shield.access]         # Lua plugin phase
       ├── [redis.quota_check]             # Redis pre-flight
       └── [grpc.shield.analyze_prompt]    # Sidecar call
            ├── [shield.regex_scan]
            └── [shield.vector_similarity]
  └── [apisix.aria-shield.body_filter]
       └── [grpc.shield.count_tokens]      # Async, off critical path
```

### 6.4 Alerting Rules

| Alert | Condition | Severity | Duration | Notification |
|-------|-----------|----------|----------|-------------|
| All providers down | `aria_circuit_breaker_state == 1` for all providers | CRITICAL | 1m | PagerDuty + Slack |
| Sidecar down | `aria_sidecar_unavailable > 0` | HIGH | 5m | Slack |
| Redis down | `aria_quota_redis_unavailable > 0` | HIGH | 2m | Slack |
| Audit buffer overflow | `aria_audit_buffer_overflow > 0` | HIGH | immediate | Slack |
| High injection rate | `rate(aria_security_events_total{event_type="injection"}[5m]) > 10` | MEDIUM | 5m | Slack |
| Canary rollback | `increase(aria_canary_rollback_total[5m]) > 0` | MEDIUM | immediate | Slack + webhook |
| Quota near limit | `aria_quota_utilization_pct > 90` | LOW | 10m | Dashboard |

---

## 7. Non-Functional Requirements (Per Module)

### 7.1 aria-shield NFRs

| Category | Target | Measurement |
|----------|--------|-------------|
| **Request transformation latency** | < 5ms added | `aria_request_latency_seconds` overhead |
| **SSE chunk forwarding** | < 1ms per chunk | Benchmark: direct vs. via plugin |
| **Redis quota check** | < 2ms (P95) | Redis latency metrics |
| **Prompt regex scan** | < 2ms | Plugin timing |
| **Failover detection** | < 100ms | Circuit breaker transition time |
| **Availability** | Plugin error must not crash APISIX | Integration test |
| **Concurrent streams** | 10K per APISIX instance | Load test |

### 7.2 aria-mask NFRs

| Category | Target | Measurement |
|----------|--------|-------------|
| **Lua masking (< 100KB, ≤ 20 rules)** | < 1ms | Benchmark |
| **WASM masking (< 1MB, any rules)** | < 3ms | Benchmark |
| **Large body skip** | Responses > 10MB pass through | Config: `max_body_size` |
| **Memory** | O(response size) single-pass rewrite | Profiling |

### 7.3 aria-canary NFRs

| Category | Target | Measurement |
|----------|--------|-------------|
| **Routing decision** | < 0.5ms | Plugin timing |
| **Traffic split accuracy** | Within 1% of configured percentage | Statistical test over 10K requests |
| **Auto-rollback execution** | < 5 seconds from decision to traffic shift | Canary e2e test |
| **Error rate monitoring granularity** | 10-second sliding window | Redis counter precision |

### 7.4 Aria Runtime NFRs

| Category | Target | Measurement |
|----------|--------|-------------|
| **Startup time** | < 3 seconds | Container startup metric |
| **Memory footprint** | 256MB base, 512MB max | JVM memory metrics |
| **gRPC round-trip (UDS)** | < 0.5ms | gRPC client metrics |
| **Concurrent virtual threads** | 10K+ | JVM metrics |
| **Graceful shutdown** | < 30 seconds | Deployment rollout |
| **Health check latency** | < 10ms | HTTP probe timing |

---

## 8. Failure Modes & Recovery

### 8.1 Java Sidecar Failure

**Detection:** Lua plugins detect gRPC deadline exceeded or connection refused.
**Impact:** Degraded accuracy, not outage (see DM-SH-004).
**Response:**
1. All features fall back to Lua-only mode
2. `aria_sidecar_unavailable` metric set to 1
3. Alert after 5 minutes
4. Kubernetes restarts sidecar via liveness probe failure

**Recovery:** Automatic — Kubernetes restarts, Lua plugins detect socket availability.

### 8.2 Redis Failure

**Detection:** Redis connection timeout or refused.
**Impact:** Quota enforcement and canary state unavailable.
**Response:**
1. Quota: Apply fail-open or fail-closed policy (configurable, DM-SH-006)
2. Canary: Use last known state from in-memory cache. Pause stage progression
3. Tokenization: Fall back to `redact` strategy
4. `aria_quota_redis_unavailable` metric incremented

**Recovery:** Automatic — Redis reconnection. Quota counters resume from last known value.

### 8.3 PostgreSQL Failure

**Detection:** Connection timeout or refused.
**Impact:** Audit events not persisted (buffered in Redis).
**Response:**
1. Buffer audit events in Redis (max 1000, FIFO)
2. Background flush job retries every 5 seconds
3. If buffer exceeds 1000, drop oldest and emit `aria_audit_buffer_overflow`
4. No impact on request pipeline (audit is async)

**Recovery:** Automatic — flush Redis buffer to Postgres on reconnection.

### 8.4 LLM Provider Failure

**Detection:** 5xx response or timeout from provider.
**Impact:** AI requests fail for affected provider.
**Response:**
1. Circuit breaker opens after `failure_threshold` consecutive failures (BR-SH-002)
2. Traffic routes to fallback chain
3. If all providers fail: 503 ALL_PROVIDERS_DOWN
4. Circuit breaker probes primary after cooldown

**Recovery:** Automatic — circuit breaker half-open probe.

### 8.5 APISIX Worker Crash

**Detection:** APISIX master process detects worker exit.
**Impact:** In-flight requests on that worker are lost.
**Response:**
1. APISIX master respawns worker automatically
2. Lua plugin state is re-initialized (stateless by design)
3. Redis/Postgres connections re-established
4. UDS socket remains available (sidecar is a separate container)

**Recovery:** Automatic — APISIX worker respawn (< 1 second).

---

## 9. Data Storage Design

### 9.1 Redis Key Design

| Key Pattern | Type | Module | TTL |
|------------|------|--------|-----|
| `aria:quota:{consumer}:daily:{date}:tokens` | STRING (int) | Shield | 48h |
| `aria:quota:{consumer}:monthly:{month}:dollars` | STRING (decimal) | Shield | 35d |
| `aria:cb:{provider}:{route}` | HASH | Shield | 10m |
| `aria:latency:{provider}:{model}` | SORTED_SET | Shield | 10m |
| `aria:alert:{consumer}:{threshold}` | STRING | Shield | budget period |
| `aria:canary:{route}` | HASH (JSON) | Canary | none (persistent) |
| `aria:canary:errors:{route}:{version}:{window}` | STRING (int) | Canary | 2m |
| `aria:canary:latency:{route}:{version}` | SORTED_SET | Canary | 10m |
| `aria:tokenize:{token_id}` | STRING (encrypted) | Mask | configurable |
| `aria:audit_buffer` | LIST | All | 1h |

### 9.2 PostgreSQL Schema (Conceptual)

**Tables:**

| Table | Module | Purpose | Partitioning |
|-------|--------|---------|-------------|
| `audit_events` | Shield, Mask | Security and masking audit trail | Monthly (by timestamp) |
| `billing_records` | Shield | Token/dollar usage per request | Monthly (by timestamp) |
| `masking_audit` | Mask | Masking action metadata | Monthly (by timestamp) |

**Indexes:**

| Table | Index | Purpose |
|-------|-------|---------|
| `audit_events` | `(consumer_id, timestamp)` | Query by consumer and date range |
| `audit_events` | `(event_type, timestamp)` | Query by event type |
| `billing_records` | `(consumer_id, timestamp)` | Usage aggregation queries |
| `billing_records` | `(model, timestamp)` | Cost-per-model analytics |
| `masking_audit` | `(consumer_id, timestamp)` | Compliance queries |

**Constraints:**
- No UPDATE/DELETE on `audit_events` (append-only)
- All tables partitioned by month for efficient archival
- Partition drop after 7 years (automated)

---

## 10. Compliance Requirements

### 10.1 GDPR / KVKK

| Requirement | Implementation |
|-------------|----------------|
| Data minimization | Mask PII at the gateway edge (Module B) — services return full data, gateway strips PII per role |
| Right to access | Audit trail supports data subject requests (query by consumer) |
| Right to erasure | Anonymize consumer records in audit/billing tables on request |
| Breach notification | Incident response procedure — 72 hours (KVKK) |
| Consent management | Application-level concern (not gateway) |

### 10.2 PCI-DSS

| Requirement | Implementation |
|-------------|----------------|
| PAN never stored in full | Masking at gateway edge — `last4` or `tokenize` strategy |
| Encryption in transit | TLS 1.3 for all external communication |
| Access logging | Full audit trail for PAN access events |
| Tokenization | Reversible tokens stored encrypted in Redis with TTL |

---

## 11. Cost Estimation

### 11.1 Resource Requirements (Per APISIX Node)

| Component | CPU | Memory | Storage | Monthly Cost (Est.) |
|-----------|-----|--------|---------|-------------------|
| APISIX container | 1-2 cores | 512MB-1GB | — | Existing infra |
| Aria Runtime sidecar | 0.5-1 core | 256-512MB | — | ~$25-50 (cloud) |
| Redis (shared, 3-node cluster) | 2 cores total | 4GB total | 10GB | ~$100 |
| PostgreSQL (shared) | 2 cores | 4GB | 100GB (growing) | ~$150 |
| **Total incremental per node** | — | — | — | **~$75-100** |

### 11.2 Scaling Projections

| Traffic Level | APISIX Nodes | Redis | Postgres | Est. Monthly |
|--------------|-------------|-------|----------|-------------|
| 1K req/s | 2 | 3-node cluster | 1 primary + 1 replica | ~$400 |
| 10K req/s | 5 | 6-node cluster | 1 primary + 2 replicas | ~$1,200 |
| 50K req/s | 10 | 6-node cluster | 1 primary + 2 replicas | ~$2,500 |

---

## 12. Deployment & Release Strategy

### 12.1 Packaging

| Component | Package Format | Distribution |
|-----------|---------------|-------------|
| Lua plugins | `.lua` files | Git submodule, APISIX plugin path, or OCI artifact |
| WASM plugin | `.wasm` file | Git submodule or OCI artifact |
| Aria Runtime | Docker image | Container registry (ghcr.io) |
| Grafana dashboards | `.json` files | Git, Grafana provisioning |
| ariactl | Single binary (Go/GraalVM) | GitHub Releases (Linux, macOS, Windows) |
| Helm chart | Helm chart | Helm repository |

### 12.2 Helm Chart Structure

```
aria-gatekeeper/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── apisix-config.yaml      # Plugin configuration
│   ├── sidecar-deployment.yaml  # Aria Runtime sidecar
│   ├── redis-config.yaml        # Redis connection
│   ├── postgres-config.yaml     # Postgres connection
│   ├── grafana-dashboards.yaml  # Dashboard provisioning
│   └── alerting-rules.yaml      # Prometheus alert rules
└── dashboards/
    ├── shield-dashboard.json
    ├── mask-dashboard.json
    └── canary-dashboard.json
```

### 12.3 CI/CD Pipeline

```
git push → Lint (Lua + Java) → Unit Test → Build Sidecar Image →
  Integration Test (APISIX + Redis + Postgres) →
  Security Scan (Trivy) → Helm Package →
  Deploy Staging → Smoke Test → Manual Approval → Deploy Prod
```

---

## 13. Architecture Decision Records

See `docs/03_architecture/ADR/` for detailed ADRs:

| ADR | Title | Decision |
|-----|-------|----------|
| ADR-001 | Authentication delegation to APISIX | Aria trusts APISIX consumer identity, no own auth |
| ADR-002 | Lua + Java hybrid architecture | Lua for fast path (< 5ms), Java sidecar for heavy processing |
| ADR-003 | gRPC over Unix Domain Sockets for IPC | ~0.1ms latency vs ~1ms HTTP, no TCP overhead |
| ADR-004 | Redis + PostgreSQL dual data store | Redis for real-time state, Postgres for audit/compliance |
| ADR-005 | Optional WASM (Rust) masking engine | Progressive performance tier: Lua → WASM → Java |
| ADR-006 | No Kafka in v1.0 | All IPC is synchronous gRPC/UDS or fire-and-forget. Kafka adds complexity without proportional benefit for plugin-to-sidecar communication |
| ADR-007 | Grafana + ariactl instead of Admin UI | v1.0 ops via Grafana dashboards and CLI. Custom React/Refine UI deferred to post-v1.0 |

---

## Appendix: Traceability Matrix

| Vision Section | Business Rule | Functional Req | User Story | HLD Section |
|---------------|---------------|----------------|------------|-------------|
| 4.1 Token Quota | BR-SH-005-010 | FR-A05-A09 | US-A05-A09 | 3.1 Shield |
| 4.2 Prompt Security | BR-SH-011-014 | FR-A10-A14 | US-A10-A14 | 3.1 Shield, 3.4 Runtime |
| 4.3 Smart Routing | BR-SH-001-002,016-018 | FR-A01-A04,A15-A17 | US-A01-A04,A15-A17 | 3.1 Shield |
| 5.1-5.5 Data Masking | BR-MK-001-008 | FR-B01-B08 | US-B01-B08 | 3.2 Mask, 3.4 Runtime |
| 6.1-6.3 Canary | BR-CN-001-007 | FR-C01-C07 | US-C01-C07 | 3.3 Canary, 3.4 Runtime |
| 7 Architecture | BR-RT-001-004 | FR-S01-S04 | US-S01-S04 | 3.4 Runtime |

---

*Document Version: 1.0 | Created: 2026-04-08*
*Status: Draft — Pending Human Approval*
