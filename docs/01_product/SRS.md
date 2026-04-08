# Software Requirements Specification (SRS) — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 1 — Requirements
**Version:** 1.0
**Date:** 2026-04-08
**Author:** Levent Sezgin Genc (3EAI Labs Ltd)
**Source:** VISION.md v1.0, USER_STORIES.md v1.0

---

## 1. Introduction

### 1.1 Purpose
This document defines the software requirements for 3e-Aria-Gatekeeper, a modular governance suite for Apache APISIX. It bridges the product vision to the technical team by specifying functional requirements, non-functional requirements (NFRs), security standards, and platform constraints.

### 1.2 Scope
3e-Aria-Gatekeeper consists of three independent, composable APISIX plugin modules and a shared Java 21 sidecar:

| Module | Code Name | Function |
|--------|-----------|----------|
| A | 3e-Aria-Shield | AI governance: token quotas, prompt security, multi-provider LLM routing |
| B | 3e-Aria-Mask | Dynamic data masking: GDPR/KVKK/PDPL compliance at the API gateway |
| C | 3e-Aria-Canary | Progressive delivery: auto-rollback canary deployments, traffic shadowing |
| Runtime | Aria Sidecar | Java 21 sidecar: gRPC/UDS, virtual threads, NER, token counting, diff engine |

### 1.3 Definitions and Acronyms

| Term | Definition |
|------|-----------|
| APISIX | Apache APISIX — open-source API gateway |
| SSE | Server-Sent Events |
| UDS | Unix Domain Socket |
| PII | Personally Identifiable Information |
| NER | Named Entity Recognition |
| PAN | Primary Account Number (credit card) |
| MSISDN | Mobile subscriber number (phone) |
| IMEI | International Mobile Equipment Identity |
| KVKK | Turkish Personal Data Protection Law |
| PDPL | Personal Data Protection Law (Saudi Arabia / Iraq) |
| tiktoken | OpenAI's tokenizer library for exact token counting |
| ScopedValue | Java 21 mechanism for per-virtual-thread context propagation |

### 1.4 References

| Document | Location |
|----------|----------|
| VISION.md | `01_product/VISION.md` |
| USER_STORIES.md | `docs/01_product/USER_STORIES.md` |
| DATA_CLASSIFICATION.md | `docs/01_product/DATA_CLASSIFICATION.md` |
| APISIX Plugin Development Guide | https://apisix.apache.org/docs/apisix/plugin-develop/ |

---

## 2. System Overview

### 2.1 Architecture

```
Client (OpenAI SDK compatible)
         │
         ▼
┌──────────────────────────────────┐
│       Apache APISIX Gateway       │
│                                   │
│  Lua Plugins:                     │
│  ├── 3e-Aria-Shield (Module A)    │
│  ├── 3e-Aria-Mask (Module B)      │
│  └── 3e-Aria-Canary (Module C)    │
│                                   │
│  ◄── gRPC/UDS ──►                 │
│                                   │
│  Java 21 Sidecar (Aria Runtime)   │
│  ├── Prompt analysis (Shield)     │
│  ├── tiktoken counter (Shield)    │
│  ├── NER PII detection (Mask)     │
│  └── Shadow diff engine (Canary)  │
│                                   │
└───────┬──────────┬──────────┬─────┘
        │          │          │
   LLM Providers   Upstream v1   Upstream v2
                   (baseline)    (canary)
```

### 2.2 Deployment Model
- **APISIX Plugins:** Deployed as Lua files in the APISIX plugin directory. Loaded at APISIX startup or via hot-reload.
- **Java Sidecar:** Deployed as a container alongside each APISIX instance (sidecar pattern). Communicates via gRPC over Unix Domain Socket.
- **Data Stores:** Redis (real-time quota, token cache) and PostgreSQL (audit logs, billing records).
- **Modules are independent:** Each module can be installed and configured individually. No module depends on another module being present.

### 2.3 Technology Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Plugin runtime | Lua 5.1 (APISIX/OpenResty) | Zero-overhead, runs in Nginx event loop |
| Heavy processing | Java 21 (Virtual Threads) | Concurrent AI requests, NLP/NER, accurate tokenization |
| IPC | gRPC over Unix Domain Sockets | ~0.1ms latency, no TCP overhead |
| Quota storage | Redis 7+ (Cluster) | Sub-millisecond reads for pre-flight quota checks |
| Audit storage | PostgreSQL 18.1+ | ACID, immutable audit trail, compliance queries |
| Metrics | Prometheus (`aria_*` namespace) | Native APISIX metrics integration |
| Dashboards | Grafana (pre-built JSON) | Provisioned dashboards, no manual setup |
| Configuration | APISIX route/consumer metadata | Native tooling, declarative, hot-reload |
| High-perf masking | WASM (Rust) — optional | Complex patterns at scale |

---

## 3. Functional Requirements

### 3.1 Module A: 3e-Aria-Shield

| ID | Requirement | Priority | User Story |
|----|------------|----------|------------|
| FR-A01 | Route LLM requests to configurable providers (OpenAI, Anthropic, Google, Azure OpenAI, Ollama/vLLM) with canonical request/response transformation | Must | US-A01 |
| FR-A02 | Circuit breaker with auto-failover to fallback providers on 5xx/timeout | Must | US-A02 |
| FR-A03 | SSE streaming pass-through without response buffering | Must | US-A03 |
| FR-A04 | OpenAI SDK-compatible API (apps change `base_url` only) | Must | US-A04 |
| FR-A05 | Token quota enforcement (daily/monthly, per consumer/route/app) with Redis pre-flight check | Must | US-A05 |
| FR-A06 | Dollar-denominated budgets with per-model pricing table | Must | US-A06 |
| FR-A07 | Prometheus metrics: `aria_tokens_consumed`, `aria_cost_dollars`, `aria_requests_total`, `aria_request_latency_seconds` | Must | US-A07 |
| FR-A08 | Webhook/Slack alerts at configurable budget thresholds (80%, 90%, 100%) | Should | US-A08 |
| FR-A09 | Overage policy: block (402), throttle, or allow-with-alert | Must | US-A09 |
| FR-A10 | Prompt injection detection (regex + optional vector similarity via sidecar) | Should | US-A10 |
| FR-A11 | PII-in-prompt scanning (regex + optional NER via sidecar). Actions: block, mask, warn | Should | US-A11 |
| FR-A12 | LLM response content filtering via sidecar | Could | US-A12 |
| FR-A13 | Data exfiltration / system prompt leakage detection | Could | US-A13 |
| FR-A14 | Immutable audit trail for all security events (Postgres, append-only) | Must | US-A14 |
| FR-A15 | Latency-based routing (P95 sliding window) | Should | US-A15 |
| FR-A16 | Cost-based routing (cheapest model meeting quality threshold) | Could | US-A16 |
| FR-A17 | Per-consumer model version pinning | Should | US-A17 |

### 3.2 Module B: 3e-Aria-Mask

| ID | Requirement | Priority | User Story |
|----|------------|----------|------------|
| FR-B01 | JSONPath-based field masking in API responses (Lua `body_filter` phase) | Must | US-B01 |
| FR-B02 | Role-based masking policies (admin: full, agent: last4, partner: redact) per consumer metadata | Must | US-B02 |
| FR-B03 | Automatic PII pattern detection: PAN, MSISDN, TC Kimlik, IMEI, IBAN, email, IP, DoB | Must | US-B03 |
| FR-B04 | Configurable mask strategies: `last4`, `first2last2`, `hash`, `redact`, `tokenize` | Must | US-B04 |
| FR-B05 | Masking audit log (metadata only, never original values) with Prometheus metrics | Must | US-B05 |
| FR-B06 | NER-based PII detection via Java sidecar (async, non-blocking) | Should | US-B06 |
| FR-B07 | WASM (Rust) masking engine for high-throughput complex patterns | Could | US-B07 |
| FR-B08 | Compliance report export (JSON/CSV) for GDPR/KVKK auditors | Should | US-B08 |

### 3.3 Module C: 3e-Aria-Canary

| ID | Requirement | Priority | User Story |
|----|------------|----------|------------|
| FR-C01 | Configurable progressive canary schedule with hold durations per stage | Must | US-C01 |
| FR-C02 | Continuous canary vs. baseline error rate comparison with configurable delta threshold | Must | US-C02 |
| FR-C03 | Auto-rollback to 0% canary when error threshold is exceeded for sustained period | Must | US-C03 |
| FR-C04 | Latency guard: pause promotion when canary P95 > baseline P95 x multiplier | Should | US-C04 |
| FR-C05 | Manual promote/rollback via APISIX Admin API | Must | US-C05 |
| FR-C06 | Traffic shadowing (duplicate % of live traffic to shadow upstream) | Should | US-C06 |
| FR-C07 | Shadow response diff engine via Java sidecar | Could | US-C07 |

### 3.4 Sidecar: Aria Runtime

| ID | Requirement | Priority | User Story |
|----|------------|----------|------------|
| FR-S01 | gRPC server over Unix Domain Socket with modular handler registration | Must | US-S01 |
| FR-S02 | Virtual thread pool with ScopedValue context propagation; no `synchronized` in hot path | Must | US-S02 |
| FR-S03 | Kubernetes-compatible health (`/healthz`) and readiness (`/readyz`) endpoints | Must | US-S03 |
| FR-S04 | Graceful shutdown on SIGTERM with configurable drain period | Must | US-S04 |

### 3.5 Operations

| ID | Requirement | Priority | User Story |
|----|------------|----------|------------|
| FR-O01 | Pre-built Grafana dashboard JSON files for Shield, Mask, and Canary | Must | US-O01 |
| FR-O02 | `ariactl` CLI for quota, masking policy, and canary management | Should | US-O02 |
| FR-O03 | All Aria config via APISIX Admin API and route/consumer metadata with hot-reload | Must | US-O03 |

---

## 4. Non-Functional Requirements

### 4.1 Performance

| Requirement | Target | Measurement Method |
|-------------|--------|-------------------|
| Lua plugin latency overhead (per request) | < 5ms (Shield routing), < 1ms (Mask regex), < 0.5ms (Canary split) | APM / Prometheus `aria_request_latency_seconds` |
| SSE streaming chunk latency | < 1ms added per chunk | Benchmark: measured vs. direct upstream |
| Redis quota lookup | < 2ms (P95) | Redis latency metrics |
| gRPC/UDS round-trip (sidecar call) | < 0.5ms | gRPC client metrics |
| Sidecar NER processing | < 10ms (async, off critical path) | Sidecar internal metrics |
| WASM masking (100KB body, 20 rules) | < 3ms | Benchmark suite |
| End-to-end added latency (Lua-only path) | < 10ms total for Shield + Mask combined | Integration test benchmark |
| Canary rollback execution | < 5 seconds from decision to traffic shift | Canary e2e test |

### 4.2 Scalability

| Requirement | Target | Measurement Method |
|-------------|--------|-------------------|
| Concurrent LLM streams | 10K per APISIX instance | Load test with streaming connections |
| Concurrent sidecar virtual threads | 10K+ | JVM metrics |
| Prometheus metric cardinality | < 10K unique label combinations per instance | Prometheus `scrape_series_added` |
| Masking rules per route | Up to 100 JSONPath rules | Benchmark at 100 rules |
| Canary deployment tracking | Up to 50 concurrent canaries per instance | Load test |

### 4.3 Availability

| Requirement | Target | Measurement Method |
|-------------|--------|-------------------|
| Plugin crash isolation | Plugin error must NOT crash APISIX | Integration test: inject errors, verify APISIX stays up |
| Sidecar unavailability | Lua plugins must degrade gracefully (reduced accuracy, not failure) | Chaos test: kill sidecar, verify requests still flow |
| Redis unavailability | Configurable fail-open or fail-closed (default: fail-open with alert) | Chaos test: block Redis, verify fallback behavior |
| Effective LLM uptime (with failover) | 99.9% across provider pool | Synthetic monitor |

### 4.4 Security

| Requirement | Target | Reference |
|-------------|--------|-----------|
| Provider API keys | Never logged, never exposed in error responses. Stored encrypted at rest | DATA_CLASSIFICATION.md (L4) |
| PII in prompts | Detected and actioned (block/mask/warn) before reaching LLM provider | FR-A11, US-A11 |
| PII in responses | Masked at gateway edge per role policy | FR-B01-B04, US-B01-B04 |
| Audit trail | Immutable, append-only, 7-year retention | FR-A14, FR-B05 |
| PII in audit logs | Masked before storage — never store original PII values | DATA_CLASSIFICATION.md |
| Prompt injection | Detected and blocked at gateway | FR-A10, US-A10 |
| Communication | gRPC/UDS (no network exposure). Redis/Postgres over TLS 1.3 | Architecture |
| Tokenization tokens | Stored in Redis with TTL, reversible only with authorized API call | FR-B04 (tokenize strategy) |
| APISIX Admin API | Protected by API key (L4). Access restricted to operators | FR-O03 |

### 4.5 Compliance

| Framework | Requirement | Implementation |
|-----------|-------------|----------------|
| **GDPR (EU)** | Right to minimization — mask PII at the edge | Module B (Mask) |
| **GDPR (EU)** | Right to access / erasure — audit trail supports data subject requests | FR-A14, FR-B05 |
| **KVKK (Turkey)** | Personal data masking at processing layer | Module B (Mask) |
| **KVKK (Turkey)** | Breach notification within 72 hours | Incident response procedure (operational) |
| **PDPL (Saudi Arabia / Iraq)** | Data localization + masking | Module B + deployment topology |
| **PCI-DSS** | PAN tokenization, card data masking, no storage of full PAN | FR-B03, FR-B04 (tokenize) |

### 4.6 Reliability

| Requirement | Target | Measurement Method |
|-------------|--------|-------------------|
| Sidecar startup time | < 3 seconds | Container startup metric |
| Sidecar graceful shutdown | < 30 seconds (configurable) | Deployment rollout observation |
| Sidecar memory footprint | < 256MB base | JVM memory metrics |
| Plugin hot-reload | Config changes effective on next request (< 1s) | Integration test |
| Audit event durability | Zero audit events lost (Redis buffer on Postgres failure) | Chaos test |

### 4.7 Observability

| Requirement | Target | Reference |
|-------------|--------|-----------|
| Metrics prefix | All metrics use `aria_*` prefix | FR-A07 |
| Logging | JSON structured, to stdout (Loki-compatible) | Observability guideline |
| Log levels | ERROR for failures, WARN for degradation, INFO for lifecycle events, DEBUG for development | Observability guideline |
| PII in logs | L3/L4 data MUST be masked in all log output | DATA_CLASSIFICATION.md |
| Tracing | OpenTelemetry spans for sidecar gRPC calls | Observability guideline |
| Dashboards | Pre-built Grafana JSON (provisioned, not manual) | FR-O01 |

### 4.8 Maintainability

| Requirement | Target |
|-------------|--------|
| Module independence | Each module installable/removable without affecting others |
| Plugin configuration | Declarative via APISIX metadata, no external config store |
| Sidecar modularity | Handler registration per module — add/remove modules without recompile |
| Documentation | README per module, APISIX plugin docs format, API reference |
| Test coverage | > 80% unit, > 60% integration |

---

## 5. Interface Requirements

### 5.1 External Interfaces

| Interface | Type | Description |
|-----------|------|-------------|
| Client -> APISIX | HTTP/HTTPS | OpenAI SDK-compatible REST API (`/v1/chat/completions`) |
| APISIX -> LLM Providers | HTTPS | Provider-specific API (OpenAI, Anthropic, Google, Azure, Ollama) |
| APISIX -> Upstream Services | HTTP/HTTPS | Standard upstream routing (for Mask and Canary modules) |
| Operator -> APISIX Admin API | HTTPS | Plugin configuration, canary management, quota management |
| `ariactl` -> APISIX Admin API | HTTPS | CLI wrapper for Admin API operations |
| Prometheus -> APISIX | HTTP | Metrics scrape endpoint (`/apisix/prometheus/metrics`) |
| Grafana -> Prometheus | HTTP | Dashboard queries |
| Alert -> Webhook/Slack | HTTPS | Budget alerts, canary rollback notifications |

### 5.2 Internal Interfaces

| Interface | Type | Description |
|-----------|------|-------------|
| Lua Plugin -> Java Sidecar | gRPC over UDS | Prompt analysis, token counting, NER, shadow diff |
| Lua Plugin -> Redis | TCP (TLS) | Quota reads/writes, token cache, audit buffer |
| Java Sidecar -> PostgreSQL | TCP (TLS) | Audit trail writes, billing records, compliance data |
| Java Sidecar -> Redis | TCP (TLS) | Async token count reconciliation |

### 5.3 API Contract: Shield (OpenAI-Compatible)

**Request (canonical format):**
```json
POST /v1/chat/completions
{
  "model": "gpt-4o",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello, world!"}
  ],
  "stream": true,
  "temperature": 0.7
}
```

**Response headers (added by Shield):**
```
X-Aria-Provider: openai
X-Aria-Model: gpt-4o-2024-11-20
X-Aria-Tokens-Input: 25
X-Aria-Tokens-Output: 142
X-Aria-Quota-Remaining: 857833
X-Aria-Budget-Remaining: 423.50
X-Aria-Request-Id: aria-req-abc123
```

**Error response format:**
```json
{
  "error": {
    "type": "aria_error",
    "code": "QUOTA_EXCEEDED",
    "message": "Daily token quota exceeded for consumer 'team-a'",
    "aria_request_id": "aria-req-abc123"
  }
}
```

### 5.4 API Contract: Canary Admin

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/aria/canary/{route_id}/status` | GET | Current canary state: stage, traffic %, error rates |
| `/aria/canary/{route_id}/promote` | POST | Instantly promote to 100% |
| `/aria/canary/{route_id}/rollback` | POST | Instantly rollback to 0% |
| `/aria/canary/{route_id}/pause` | POST | Pause automatic stage progression |
| `/aria/canary/{route_id}/resume` | POST | Resume automatic stage progression |

### 5.5 gRPC Service Definition (Sidecar)

```protobuf
syntax = "proto3";
package aria.sidecar.v1;

service ShieldService {
  rpc AnalyzePrompt(PromptRequest) returns (PromptAnalysis);
  rpc CountTokens(TokenRequest) returns (TokenCount);
  rpc FilterResponse(ResponseContent) returns (FilterResult);
}

service MaskService {
  rpc DetectPII(DetectionRequest) returns (DetectionResult);
}

service CanaryService {
  rpc DiffResponses(DiffRequest) returns (DiffResult);
}

service HealthService {
  rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
}
```

---

## 6. Constraints

### 6.1 Technical Constraints

| Constraint | Description |
|-----------|-------------|
| APISIX version | >= 3.8 (required for WASM plugin support and latest metadata API) |
| Lua version | 5.1 (OpenResty/LuaJIT constraint) |
| Java version | >= 21 (Virtual Threads, ScopedValue) |
| Redis version | >= 7.0 (Cluster mode, required for atomic quota operations) |
| PostgreSQL version | >= 16 (for audit table partitioning performance) |
| No `synchronized` in Java | Virtual thread pinning risk — use `ReentrantLock` only |
| No `ThreadLocal` in Java | Memory leak risk with virtual threads — use `ScopedValue` |
| No full-response buffering | SSE streams must be forwarded chunk-by-chunk |
| Plugin crash isolation | A Lua plugin error must never crash the APISIX worker process |

### 6.2 Business Constraints

| Constraint | Description |
|-----------|-------------|
| License | Apache 2.0 (open source, permissive) |
| No vendor lock-in | Must support multiple LLM providers. No single-provider dependency |
| Module independence | Each module must be installable and configurable independently |
| Zero application code changes | Applications integrate by changing `base_url` only (Shield) or at the gateway layer (Mask, Canary) |
| Backward compatibility | APISIX configuration format must remain stable within major versions |

### 6.3 Regulatory Constraints

| Constraint | Description |
|-----------|-------------|
| GDPR | PII masking, right to access/erasure, data minimization |
| KVKK | Turkish data protection law — masking at processing layer |
| PCI-DSS | PAN must never be stored in full. Tokenization or masking required |
| Audit retention | 7 years for compliance audit records |
| Breach notification | 72 hours (KVKK) |

---

## 7. Assumptions and Dependencies

### 7.1 Assumptions

| # | Assumption |
|---|-----------|
| 1 | APISIX is already deployed and operational in the target environment |
| 2 | Redis and PostgreSQL are available as external services (not managed by Aria) |
| 3 | LLM provider API keys are provisioned separately and configured in APISIX secrets |
| 4 | Prometheus and Grafana are deployed for metrics collection and dashboarding |
| 5 | Kubernetes is the deployment target (for sidecar, health checks, Helm chart) |
| 6 | OpenAI-compatible API format is the canonical format for AI requests |

### 7.2 External Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Apache APISIX | >= 3.8 | Plugin host |
| Redis | >= 7.0 | Quota storage, token cache, audit buffer |
| PostgreSQL | >= 16 | Audit trail, billing records |
| Prometheus | Any | Metrics collection |
| Grafana | >= 10 | Dashboards |
| LLM Providers | Current API versions | Upstream AI services |

---

## 8. Platform Compliance (Adapted for Plugin Project)

The following platform compliance items from the corporate guideline have been adapted for an open-source APISIX plugin project:

| Requirement | Status | Notes |
|-------------|--------|-------|
| Authentication (Keycloak) | N/A | Aria is an APISIX plugin — authentication is handled by APISIX's existing auth plugins. Aria trusts APISIX consumer identity |
| API Gateway (APISIX) | Inherent | Aria IS an APISIX plugin |
| Monitoring (Prometheus/Grafana) | Applicable | `aria_*` Prometheus metrics + Grafana dashboards |
| Logging (Loki) | Applicable | JSON structured logging to stdout (Loki-compatible) |
| Tracing (OpenTelemetry/Jaeger) | Applicable | Sidecar gRPC calls include OpenTelemetry spans |
| Frontend (React/Refine) | Deferred | v1.0 uses Grafana dashboards + `ariactl` CLI. Admin UI is a Could-Have |

---

## 9. Traceability Matrix

| Vision Section | Functional Requirement | User Story | NFR |
|---------------|----------------------|------------|-----|
| 4.1 Token Quota | FR-A05, FR-A06 | US-A05, US-A06 | Perf 4.1, Sec 4.4 |
| 4.2 Prompt Security | FR-A10, FR-A11, FR-A12, FR-A13 | US-A10-A13 | Perf 4.1, Sec 4.4 |
| 4.3 Smart Routing | FR-A01, FR-A02, FR-A15, FR-A16, FR-A17 | US-A01-A04, US-A15-A17 | Perf 4.1, Avail 4.3 |
| 5.1 Field Masking | FR-B01, FR-B02, FR-B04 | US-B01, US-B02, US-B04 | Perf 4.1, Compl 4.5 |
| 5.2 PII Detection | FR-B03, FR-B06 | US-B03, US-B06 | Perf 4.1, Sec 4.4 |
| 5.5 Audit | FR-B05, FR-B08 | US-B05, US-B08 | Rel 4.6, Compl 4.5 |
| 6.1 Traffic Splitting | FR-C01, FR-C05 | US-C01, US-C05 | Perf 4.1, Rel 4.6 |
| 6.1 Error Monitoring | FR-C02, FR-C03, FR-C04 | US-C02, US-C03, US-C04 | Perf 4.1 |
| 6.2 Shadowing | FR-C06, FR-C07 | US-C06, US-C07 | Perf 4.1 |
| 7 Architecture | FR-S01, FR-S02, FR-S03, FR-S04 | US-S01-S04 | Perf 4.1, Scal 4.2, Rel 4.6 |

---

*Document Version: 1.0 | Created: 2026-04-08*
*Source: VISION.md v1.0*
*Status: Draft — Pending Product Owner Approval*
