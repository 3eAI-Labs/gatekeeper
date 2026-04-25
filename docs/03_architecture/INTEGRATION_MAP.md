# Integration Map — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 3 — Architecture
**Version:** 1.1.3
**Date:** 2026-04-25 (v1.1.3 spec-coherence sweep); 2026-04-08 (v1.0 baseline)
**Input:** HLD.md v1.1.1, ADR-008 (HTTP bridge), ADR-009 (audit pipeline LPOP)
**v1.1.3 Driver:** Spec-coherence sweep — INTEGRATION_MAP at v1.0 had drifted out of sync with shipped reality. Reconciles transport (UDS gRPC → HTTP/JSON loopback per ADR-008), adds NER bridge + shadow diff data flows (BR-MK-006 + BR-CN-007), adds audit pipeline LPOP drain (ADR-009), updates trust boundary diagram (Zone 2 ↔ Zone 3 from "UDS file permissions" to "loopback TCP + NetworkPolicy"), corrects ariactl row in Zone 5 (deferred to v0.2; APISIX Admin API + canary `_M.control_api()` is the v0.1 substitute).

---

## 1. System Context Diagram (C4 Level 1)

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                            SYSTEM CONTEXT                                        │
│                                                                                  │
│  ┌──────────┐      HTTPS       ┌─────────────────────────────────┐              │
│  │ Developer│ ───────────────► │                                 │              │
│  │ (OpenAI  │   base_url =     │     Apache APISIX                │              │
│  │  SDK)    │   gateway        │     + 3e-Aria-Gatekeeper         │              │
│  └──────────┘                  │        plugins                   │              │
│                                │                                  │              │
│  ┌──────────┐      HTTPS       │  ┌─────────┐ ┌────────┐ ┌──────┐│              │
│  │ API      │ ───────────────► │  │ Shield  │ │ Mask   │ │Canary││              │
│  │ Consumer │  any REST API    │  └─────────┘ └────────┘ └──────┘│              │
│  └──────────┘                  │             │           │       │              │
│                                │     HTTP loopback     HTTP      │              │
│                                │     127.0.0.1:8081 (ADR-008)    │              │
│                                │             │           │       │              │
│                                │      ┌──────▼───────────▼─────┐ │              │
│  ┌──────────┐  APISIX Admin    │      │  aria-runtime sidecar  │ │              │
│  │ Operator │ ───────────────► │      │  (Java 21 + Spring)    │ │              │
│  │ (curl /  │  API + canary    │      │  • DiffEngine          │ │              │
│  │  ariactl │  control_api     │      │  • NerDetectionService │ │              │
│  │  v0.2)   │  (v0.1 sub)      │      │  • TokenEncoder        │ │              │
│  └──────────┘                  │      │  • AuditFlusher (ADR-9)│ │              │
│                                │      └────────┬─────────┬─────┘ │              │
│                                └───────────────┼─────────┼───────┘              │
│                                                │         │                       │
│                                       ┌────────▼───┐ ┌───▼─────────┐            │
│                                       │  Redis     │ │ PostgreSQL  │            │
│                                       │  Cluster   │ │ (audit +    │            │
│                                       │            │ │  billing)   │            │
│                                       └────────────┘ └─────────────┘            │
│                                            ▲              ▲                      │
│                                            │              │                      │
│                                  ┌─────────┘     Flyway bootstraps schema       │
│                                  │              at sidecar startup (v0.1.1)     │
│                                  │                                               │
│                              ┌───┴───────────────────┐                          │
│                              │    LLM Providers       │                          │
│                              │ OpenAI | Anthropic     │                          │
│                              │ Google | Azure | Ollama│                          │
│                              └───────────────────────┘                           │
│                                                                                  │
│  ┌──────────┐                ┌──────────┐      ┌──────────┐                    │
│  │Prometheus│ ◄── scrape ──  │  APISIX  │      │ Grafana  │                    │
│  └──────────┘                │ + sidecar│      │ (3 dash- │                    │
│       │                      └──────────┘      │  boards) │                    │
│       └────────────────────────────────────────►──────────┘                    │
│                              query                                              │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Container Diagram (C4 Level 2)

```
┌──────────────────────────── Pod (single trust boundary) ──────────────────────────┐
│                                                                                   │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │                APISIX Container                                           │    │
│  │                                                                          │    │
│  │  Request Pipeline (Lua plugins, OpenResty workers):                      │    │
│  │  ┌────────┐  ┌──────────┐  ┌────────┐  ┌──────────┐                     │    │
│  │  │ Auth   │→ │ Shield   │→ │ Mask   │→ │ Upstream │ → LLM provider      │    │
│  │  │ Plugin │  │ Plugin   │  │ Plugin │  │  Proxy   │                     │    │
│  │  └────────┘  └────┬─────┘  └────┬───┘  └──────────┘                     │    │
│  │                   │              │                                       │    │
│  │  Canary routes:   │              │                                       │    │
│  │  ┌──────────┐     │              │                                       │    │
│  │  │ Canary   │     │              │                                       │    │
│  │  │ Plugin   │     │              │                                       │    │
│  │  └────┬─────┘     │              │                                       │    │
│  │       │           │              │                                       │    │
│  │       │  HTTP/JSON via resty.http (per-endpoint circuit breaker          │    │
│  │       │  via aria-circuit-breaker.lua, ADR-008)                          │    │
│  │       │           │              │                                       │    │
│  │       └─────► POST /v1/diff      └─► POST /v1/mask/detect                │    │
│  │           (canary shadow diff, BR-CN-007)  (NER PII, BR-MK-006)         │    │
│  │                                                                          │    │
│  │  Lua → Redis (audit emit):                                               │    │
│  │       record_audit_event() → LPUSH aria:audit_buffer (1h TTL)            │    │
│  │                                                                          │    │
│  └──────┬─────────────────────────────────────────┬────────────────────────┘    │
│         │ HTTP loopback                            │ TCP/TLS                     │
│         │ 127.0.0.1:8081                           │ Redis AUTH                  │
│         ▼                                          ▼                             │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │   aria-runtime sidecar Container (Java 21 + Spring Boot 3.4)              │    │
│  │                                                                          │    │
│  │   ┌──────────────────────────────────────────────────────────────────┐  │    │
│  │   │  HTTP transport (Spring Web, canonical for Lua callers)          │  │    │
│  │   │   /v1/diff          → DiffController → DiffEngine                 │  │    │
│  │   │   /v1/mask/detect   → MaskController → NerDetectionService        │  │    │
│  │   │   /healthz, /readyz → HealthController                            │  │    │
│  │   │   /actuator/*       → Spring Actuator (metrics, info)             │  │    │
│  │   └──────────────────────────────────────────────────────────────────┘  │    │
│  │                                                                          │    │
│  │   ┌──────────────────────────────────────────────────────────────────┐  │    │
│  │   │  gRPC transport (forward-compat only — no Lua callers in v0.1)   │  │    │
│  │   │   ShieldServiceImpl   (analyzePrompt + filterResponse stubs)      │  │    │
│  │   │   MaskServiceImpl     (delegates to NerDetectionService)          │  │    │
│  │   │   CanaryServiceImpl   (delegates to DiffEngine)                   │  │    │
│  │   │   Cross-transport engine sharing — ADR-008 §Decision              │  │    │
│  │   └──────────────────────────────────────────────────────────────────┘  │    │
│  │                                                                          │    │
│  │   ┌──────────────────────────────────────────────────────────────────┐  │    │
│  │   │  Background work (Spring @Scheduled)                              │  │    │
│  │   │   audit/AuditFlusher                                              │  │    │
│  │   │     • LPOP loop on aria:audit_buffer every 5s                     │  │    │
│  │   │     • drains ≤100 events per tick                                 │  │    │
│  │   │     • persists each via PostgresClient.insertAuditEvent           │  │    │
│  │   │     • exposes persistedTotal / failedTotal counters               │  │    │
│  │   │     • ADR-009 closes FINDING-003                                  │  │    │
│  │   └──────────────────────────────────────────────────────────────────┘  │    │
│  │                                                                          │    │
│  │   ┌──────────────────────────────────────────────────────────────────┐  │    │
│  │   │  Persistence clients                                              │  │    │
│  │   │   AriaRedisClient   — Lettuce async (audit drain, quota,          │  │    │
│  │   │                       circuit-breaker state)                      │  │    │
│  │   │   PostgresClient    — R2DBC async (audit insert, billing insert)  │  │    │
│  │   │   Flyway (JDBC)     — schema bootstrap at startup, then closes    │  │    │
│  │   │                       its connection (FINDING-005 closure, v0.1.1)│  │    │
│  │   └──────────────────────────────────────────────────────────────────┘  │    │
│  │                                                                          │    │
│  │   Bind: 127.0.0.1:8081 only (loopback). Sidecar refuses external binds. │    │
│  └──────┬─────────────────────────────────────────────────────┬───────────┘    │
│         │ TCP/TLS                                              │ TCP/TLS         │
│         │ Redis AUTH                                           │ User/password   │
│         ▼                                                      ▼                 │
└────────────────────────────────────────────────────────────────────────────────────┘
                  │                                                  │
              Redis Cluster                                  PostgreSQL
              (real-time state)                              (durable audit + billing)
```

**Pod boundary:** APISIX + sidecar in the same Pod (sidecar pattern). NetworkPolicy in the Helm chart restricts ingress to the sidecar's `127.0.0.1:8081` to APISIX traffic only — defense-in-depth on top of the loopback bind.

---

## 3. Data Flow Diagrams

### 3.1 Shield — LLM Request Flow (v0.1 community tier)

```
Client                APISIX (Shield Plugin)           Redis            Sidecar          LLM Provider
  │                         │                            │                 │                  │
  │── POST /v1/chat ───────►│                            │                 │                  │
  │                         │── GET quota ──────────────►│                 │                  │
  │                         │◄── remaining: 50K ─────────│                 │                  │
  │                         │                            │                 │                  │
  │                         │── Regex injection scan ┐   │                 │                  │
  │                         │  (Lua-tier, BR-SH-011)  │   │                 │                  │
  │                         │◄────────────────────────┘   │                 │                  │
  │                         │                            │                 │                  │
  │                         │  [v0.3 enterprise CISO:    │                 │                  │
  │                         │   sidecar vector-similarity scan would call here — ShieldServiceImpl │
  │                         │   gRPC analyzePrompt currently STUB returns is_injection=false]    │
  │                         │                            │                 │                  │
  │                         │── Transform request ──┐    │                 │                  │
  │                         │  (BR-SH-001, 5 providers)  │                 │                  │
  │                         │◄──────────────────────┘    │                 │                  │
  │                         │                            │                 │                  │
  │                         │── Forward to provider ───────────────────────────────────────►│
  │                         │◄── Response ──────────────────────────────────────────────────│
  │                         │                            │                 │                  │
  │                         │── Transform → OpenAI ──┐   │                 │                  │
  │                         │  (BR-SH-004)            │   │                 │                  │
  │                         │◄────────────────────────┘   │                 │                  │
  │                         │── Approx token count ──┐   │                 │                  │
  │                         │  (Lua, BR-SH-006)       │   │                 │                  │
  │                         │◄────────────────────────┘   │                 │                  │
  │                         │── INCRBY tokens ──────────►│                 │                  │
  │                         │                            │                 │                  │
  │                         │  [v0.2: sidecar exact reconcile via TokenEncoder              │
  │                         │   (jtokkit, real impl shipped 2026-04-22) — HTTP bridge       │
  │                         │   path POST /v1/shield/count not yet wired]                   │
  │                         │                            │                 │                  │
  │                         │── record_audit_event() ───►│                 │                  │
  │                         │  LPUSH aria:audit_buffer    │                 │                  │
  │                         │                            │                 │                  │
  │                         │── Add X-Aria-* headers ┐   │                 │                  │
  │                         │◄────────────────────────┘   │                 │                  │
  │◄── Response ────────────│                            │                 │                  │
  │                         │── Emit metrics (async) ┐   │                 │                  │
  │                         │◄────────────────────────┘   │                 │                  │
                                                          │                 │                  │
                                                          │ ┌──────────────────┐               │
                                                          │ │ Every 5s tick:   │               │
                                                          │ │ AuditFlusher     │               │
                                                          │ │ LPOP drain       │ ──► Postgres  │
                                                          │ │ (ADR-009)        │   insertAudit │
                                                          │ └──────────────────┘               │
```

### 3.2 Mask — Response Masking Flow with NER (v0.1 community tier)

```
Upstream            APISIX (Mask Plugin)              Redis           Sidecar         Client
  │                       │                             │                │               │
  │── JSON Response ────►│                             │                │               │
  │                       │── Read consumer role ──┐    │                │               │
  │                       │  (BR-MK-002)            │   │                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │── Resolve role policy ──┐   │                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │                             │                │               │
  │                       │── Apply JSONPath rules ─┐   │                │               │
  │                       │  (BR-MK-001)             │   │                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │                             │                │               │
  │                       │── PII regex scan ───────┐   │                │               │
  │                       │  (BR-MK-003, 8 patterns) │   │                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │                             │                │               │
  │                       │  [if NER bridge enabled — BR-MK-006]         │               │
  │                       │── aria-circuit-breaker.lua check ┐           │               │
  │                       │   (per-endpoint state, ngx.shared.dict)      │               │
  │                       │◄──────────────────────────────────┘           │               │
  │                       │                             │                │               │
  │                       │  [if breaker CLOSED]        │                │               │
  │                       │── POST /v1/mask/detect ───────────────────►│               │
  │                       │   (HTTP/JSON loopback)      │                │               │
  │                       │                             │       MaskController          │
  │                       │                             │           ▼                    │
  │                       │                             │       NerDetectionService     │
  │                       │                             │       (Resilience4j inner CB) │
  │                       │                             │           ▼                    │
  │                       │                             │       CompositeNerEngine      │
  │                       │                             │       ├── OpenNlpNerEngine    │
  │                       │                             │       │   (English)           │
  │                       │                             │       └── DjlHuggingFace…     │
  │                       │                             │           (Turkish-BERT ONNX) │
  │                       │◄── { entities: [...] } ──────────────────────│               │
  │                       │                             │                │               │
  │                       │  [fail mode = open]         │                │               │
  │                       │  → if sidecar unreachable: regex-only result │               │
  │                       │  [fail mode = closed]       │                │               │
  │                       │  → all candidate fields redacted             │               │
  │                       │                             │                │               │
  │                       │── Apply mask strategy ──┐   │                │               │
  │                       │  (BR-MK-004, 12 strategies)│                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │                             │                │               │
  │                       │  [if tokenize strategy]     │                │               │
  │                       │── SET aria:tokenize:{id} ─►│                │               │
  │                       │  (v0.1: non-reversible hash; v0.2: AES-256)  │               │
  │                       │                             │                │               │
  │                       │── record_audit_event() ───►│                │               │
  │                       │  LPUSH aria:audit_buffer    │                │               │
  │                       │  (BR-MK-005)                │                │               │
  │                       │                             │                │               │
  │                       │── Return masked JSON ──────────────────────────────────────►│
  │                       │── Emit metrics (async) ─┐   │                │               │
  │                       │◄────────────────────────┘   │                │               │
```

### 3.3 Canary — Traffic Routing + Shadow Diff (v0.1 community tier)

```
Client              APISIX (Canary Plugin)             Redis          Upstream v1     Upstream v2     Sidecar
  │                       │                             │             (baseline)      (canary)
  │── Request ──────────►│                             │                │               │             │
  │                       │── GET canary state ───────►│                │               │             │
  │                       │◄── {pct: 10, state: S2} ──│                │               │             │
  │                       │                             │                │               │             │
  │                       │── Route decision ──────┐    │                │               │             │
  │                       │  hash(client_ip) % 100  │   │                │               │             │
  │                       │  (BR-CN-001)            │   │                │               │             │
  │                       │◄───────────────────────┘    │                │               │             │
  │                       │                             │                │               │             │
  │                       │  [primary path]             │                │               │             │
  │                       │── Forward (hash >= pct) ──────────────────►│               │             │
  │                       │◄── Response ──────────────────────────────│               │             │
  │                       │                             │                │               │             │
  │                       │  [shadow — BR-CN-006, fire-and-forget]      │               │             │
  │                       │  if hash < shadow_pct                       │               │             │
  │                       │── Forward (X-Aria-Shadow:true) ──────────────────────────► │             │
  │                       │   (no response wait — log phase analyses)                  │             │
  │                       │                             │                │               │             │
  │                       │  [shadow diff — BR-CN-007, async log phase] │               │             │
  │                       │  collect baseline + shadow responses (capture in            │             │
  │                       │  aria-canary.lua _M.log)                                    │             │
  │                       │── aria-circuit-breaker check ┐               │               │             │
  │                       │   (per-endpoint, ngx.shared.dict)            │               │             │
  │                       │◄───────────────────────────────┘             │               │             │
  │                       │                             │                │               │             │
  │                       │  [if breaker CLOSED]        │                │               │             │
  │                       │── POST /v1/diff ────────────────────────────────────────────────────────►│
  │                       │   { primary: {...}, shadow: {...} }         │               │             │
  │                       │                             │                │           DiffController     │
  │                       │                             │                │               ▼             │
  │                       │                             │                │           DiffEngine         │
  │                       │                             │                │           (status / headers /│
  │                       │                             │                │            body structure)   │
  │                       │◄── { diff: {...} } ────────────────────────────────────────────────────────│
  │                       │                             │                │               │             │
  │                       │── Emit shadow diff metrics ┐│                │               │             │
  │                       │   aria_shadow_diff_count    │                │               │             │
  │                       │   (BR-CN-007)               │                │               │             │
  │                       │◄────────────────────────────┘│                │               │             │
  │                       │                             │                │               │             │
  │◄── Response (primary) │                             │                │               │             │
  │                       │                             │                │               │             │
  │                       │── INCR error counters ────►│                │               │             │
  │                       │── Check stage progression ►│                │               │             │
  │                       │  (BR-CN-002, sliding window, 2% delta)       │               │             │
  │                       │  [if error delta sustained > duration]       │               │             │
  │                       │── PAUSE or ROLLBACK ──────►│                │               │             │
  │                       │  (BR-CN-003)                │                │               │             │
  │                       │── Webhook notification ─┐   │                │               │             │
  │                       │◄────────────────────────┘   │                │               │             │
```

### 3.4 Audit Pipeline — Async Drain (ADR-009, v0.1.1)

```
Lua plugins                      Redis                     Sidecar (background)         PostgreSQL
  │                                │                          │                            │
  │── record_audit_event() ──────►│                          │                            │
  │   LPUSH aria:audit_buffer      │ (1h TTL on the list)     │                            │
  │   (PII pre-masked Lua-side)    │                          │                            │
  │   • from Shield (BR-SH-015)    │                          │                            │
  │   • from Mask   (BR-MK-005)    │                          │                            │
  │                                │                          │                            │
  │                                │  Every 5s tick:          │                            │
  │                                │  AuditFlusher @Scheduled │                            │
  │                                │                          │                            │
  │                                │◄── LPOP (loop ≤100/tick) │                            │
  │                                │ ── event ──────────────►│                            │
  │                                │                          │── parse JSON              │
  │                                │                          │   (poison-message contained:│
  │                                │                          │    on parse fail, log+drop, │
  │                                │                          │    failedTotal++)          │
  │                                │                          │── insertAuditEvent ──────►│
  │                                │                          │   (R2DBC, async)           │
  │                                │                          │◄── ack ────────────────────│
  │                                │                          │── persistedTotal++         │
  │                                │                          │                            │
  │                                │  Lettuce auto-reconnects │                            │
  │                                │  on transient Redis blip │                            │
```

PostgreSQL `audit_events` has `DO INSTEAD NOTHING` rules on UPDATE / DELETE → tamper-proof once persisted. Operators alert on non-zero `failedTotal` rate (Prometheus).

---

## 4. Integration Points Summary

| # | From | To | Protocol | Direction | Auth | Data Classification | SLA |
|---|------|-----|----------|-----------|------|---------------------|-----|
| 1 | Client | APISIX (Shield) | HTTPS | Inbound | APISIX consumer auth | L3-L4 transit (prompts) | < 10ms overhead |
| 2 | Client | APISIX (Mask) | HTTPS | Inbound | APISIX consumer auth | L3-L4 transit (responses) | < 1ms overhead |
| 3 | Client | APISIX (Canary) | HTTPS | Inbound | APISIX consumer auth | Inherits upstream | < 0.5ms overhead |
| 4 | Operator | APISIX Admin API | HTTPS | Inbound | Admin API key (L4) | L2 config data | < 2s response |
| 5 | Operator | Canary `_M.control_api()` | HTTP (via APISIX plugin control plane) | Inbound | Inherits APISIX Admin API auth | L2 canary state ops | < 500ms |
| 6 | Shield Lua | LLM Provider | HTTPS | Outbound | Provider API key (L4) | L3-L4 transit | Provider SLA |
| 7 | Shield Lua | Redis | TCP/TLS | Internal | Redis AUTH | L2 quota state | < 2ms |
| 8 | Mask Lua | Redis | TCP/TLS | Internal | Redis AUTH | L4 tokenization (v0.1: hash; v0.2: AES) | < 2ms |
| 9 | Canary Lua | Redis | TCP/TLS | Internal | Redis AUTH | L1 canary state | < 2ms |
| 10 | Lua plugins | Lua audit emit (LPUSH `aria:audit_buffer`) | Redis TCP/TLS | Internal | Redis AUTH | L3 audit events (PII pre-masked Lua-side) | < 1ms (async) |
| 11 | Mask Lua | aria-runtime sidecar `/v1/mask/detect` | HTTP/JSON over loopback (`127.0.0.1:8081`) | Internal | None (loopback bind + NetworkPolicy) | L3 transit + NER spans | < 5ms P95 |
| 12 | Canary Lua | aria-runtime sidecar `/v1/diff` | HTTP/JSON over loopback (`127.0.0.1:8081`) | Internal | None (loopback bind + NetworkPolicy) | L3 transit (response bodies) | < 20ms P95 |
| 13 | aria-runtime AuditFlusher | Redis `aria:audit_buffer` | TCP/TLS (Lettuce LPOP) | Internal | Redis AUTH | L3 audit events | tick=5s default |
| 14 | aria-runtime PostgresClient | PostgreSQL | TCP/TLS (R2DBC) | Internal | User/password | L3 audit + billing records | < 5ms |
| 15 | aria-runtime Flyway | PostgreSQL | TCP/TLS (JDBC, startup-only) | Internal | User/password (DDL grants needed unless externally managed) | DDL | startup-time only, then connection closed |
| 16 | Shield | Webhook/Slack | HTTPS | Outbound | Webhook URL | L2 alert data | Best effort |
| 17 | Prometheus | APISIX + sidecar | HTTP | Inbound | None (internal) | L1 metrics | Scrape interval |
| 18 | Canary Lua | Shadow Upstream | HTTP/HTTPS | Outbound | Pass-through | Inherits original | Fire-and-forget |
| 19 | aria-runtime gRPC services | (no Lua callers in v0.1) | gRPC | Internal | n/a | n/a | forward-compat per ADR-008 — retained for non-Lua future callers |

**Removed in v1.1.3:** the v1.0 row "Lua Plugins → Aria Runtime via gRPC/UDS" — replaced by rows 11+12 (HTTP loopback per ADR-008). The UDS socket file `/var/run/aria/aria.sock` is no longer used; sidecar binds `127.0.0.1:8081` instead.

---

## 5. Trust Boundary Analysis

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRUST ZONE 1: External / Untrusted            │
│                                                                  │
│  • Client applications (OpenAI SDK, any HTTP client)             │
│  • LLM providers (third-party services)                          │
│  • Webhook endpoints (Slack, custom)                             │
│                                                                  │
├──────────────── BOUNDARY: APISIX Auth Layer ─────────────────────┤
│                                                                  │
│                    TRUST ZONE 2: Gateway (APISIX Process)        │
│                                                                  │
│  • APISIX core (Nginx + OpenResty)                               │
│  • Lua plugins (aria-shield, aria-mask, aria-canary)             │
│  • Lua shared libs (aria-core, aria-pii, aria-quota,             │
│    aria-mask-strategies, aria-provider, aria-circuit-breaker)    │
│  • Consumer identity validated by APISIX auth plugins            │
│                                                                  │
├──────────────── BOUNDARY: Loopback TCP + NetworkPolicy ──────────┤
│                                                                  │
│                    TRUST ZONE 3: Sidecar (JVM Process)           │
│                                                                  │
│  • aria-runtime (Spring Boot)                                    │
│  • HTTP bridges canonical (ADR-008): /v1/diff, /v1/mask/detect   │
│  • Background AuditFlusher (ADR-009)                             │
│  • Bind: 127.0.0.1:8081 only (sidecar refuses external binds)    │
│  • Helm NetworkPolicy template restricts ingress to APISIX pod   │
│  • Trusts all requests reaching the loopback port — same-pod     │
│    boundary is the trust boundary (ADR-008 §Consequences)        │
│  • gRPC services exist as forward-compat only — no Lua callers   │
│                                                                  │
├──────────────── BOUNDARY: TLS + Auth ────────────────────────────┤
│                                                                  │
│                    TRUST ZONE 4: Data Stores                     │
│                                                                  │
│  • Redis Cluster (quota state, canary state, circuit-breaker     │
│    state, audit buffer)                                          │
│  • PostgreSQL (audit_events, billing_records, masking_audit;     │
│    Flyway-bootstrapped at sidecar startup since v0.1.1)          │
│  • Access: Redis AUTH + TLS, Postgres user/password + TLS        │
│                                                                  │
├──────────────── BOUNDARY: Network + API Key ─────────────────────┤
│                                                                  │
│                    TRUST ZONE 5: Admin                            │
│                                                                  │
│  • APISIX Admin API (restricted network)                         │
│  • Canary `_M.control_api()` endpoints (status/promote/rollback/ │
│    pause/resume) — invoked via APISIX plugin control plane,      │
│    inherits Admin API auth                                       │
│  • Grafana dashboards (Grafana auth)                             │
│  • ariactl CLI: deferred to v0.2 — operators script against      │
│    APISIX Admin API + canary control_api in v0.1                 │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Trust Boundary Rules

| Boundary | Validation | Violation Response |
|----------|-----------|--------------------|
| Zone 1 → Zone 2 | APISIX auth plugin validates consumer identity. Input validation on request body | 401/403 for auth failure, 400 for validation |
| Zone 2 → Zone 3 | Sidecar binds `127.0.0.1` only. NetworkPolicy in Helm chart restricts ingress to APISIX pod traffic. Loopback authentication is intentionally absent — same-pod is the trust boundary (ADR-008 §Consequences). | If multi-tenant pod is later required, revisit (would need bridge auth) |
| Zone 2/3 → Zone 4 | Redis AUTH + TLS 1.3. Postgres user/password + TLS 1.3 | Connection failure → fail-open/closed per quota config (BR-SH-002 / BR-SH-005); audit events accumulate in Redis until PG returns (ADR-009 §Consequences) |
| Zone 1 → Zone 5 | Admin API key (L4). Network policy restricts access | 401 for invalid key |
| Zone 2 → External (LLM) | Provider API key (L4). TLS 1.3 | 502 PROVIDER_AUTH_FAILED |

### Departures from v1.0 trust model

- **Zone 2 ↔ Zone 3 boundary mechanism changed.** v1.0 spec'd "UDS file permissions (0660)"; v0.1 ships "loopback TCP + NetworkPolicy" per ADR-008. Both achieve "no network exposure within trusted pod boundary" in their respective threat models; the change is debugability + zero Lua native-binding code. See [ADR-008 §Consequences §Mitigations](ADR/ADR-008-http-bridge-over-grpc.md).
- **No bridge auth on the loopback port.** Intentional per ADR-008 — the trust boundary is the pod itself. If the trust model evolves (e.g., multi-tenant pod), this becomes the open design question.

---

*Document Version: 1.1.3 | Created: 2026-04-08 | Revised: 2026-04-25 (v1.1.3 spec-coherence sweep)*
*Status: v1.1.3 Draft — Pending Human Approval (part of doc-set audit Wave 3)*
*Change log v1.0 → v1.1.3: §1 system context (UDS → HTTP loopback, ariactl deferred row, AuditFlusher + Flyway boxes added); §2 container diagram fully redrawn (HTTP bridges canonical, gRPC forward-compat only, AuditFlusher background work, Flyway bootstrap, loopback bind callout); §3 data flow diagrams (3.1 Shield: STUB note on AnalyzePrompt + audit emit; 3.2 Mask: full NER bridge sequence with circuit breaker + fail-mode notes; 3.3 Canary: shadow + shadow diff sequences added per BR-CN-006/007; 3.4 NEW Audit pipeline drain per ADR-009); §4 integration points table fully rebuilt (rows 11+12 for HTTP bridges, row 13 for AuditFlusher LPOP, row 15 for Flyway, row 19 for forward-compat gRPC; old "Lua → Aria via gRPC/UDS" row removed); §5 trust boundary diagram + rules updated (Zone 2↔3 mechanism: UDS file permissions → loopback TCP + NetworkPolicy; ariactl row corrected to "deferred to v0.2").*
