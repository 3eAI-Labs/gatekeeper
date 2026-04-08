# Integration Map — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 3 — Architecture
**Version:** 1.0
**Date:** 2026-04-08

---

## 1. System Context Diagram (C4 Level 1)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│                          SYSTEM CONTEXT                                      │
│                                                                              │
│  ┌──────────┐      HTTPS       ┌─────────────────────────────────┐          │
│  │ Developer │ ───────────────► │                                 │          │
│  │ (OpenAI   │   base_url =    │     Apache APISIX               │          │
│  │  SDK)     │   gateway       │     + 3e-Aria-Gatekeeper         │          │
│  └──────────┘                  │        plugins                   │          │
│                                │                                 │          │
│  ┌──────────┐      HTTPS       │  ┌─────────┐ ┌────────┐ ┌─────┐│          │
│  │ API      │ ───────────────► │  │ Shield  │ │ Mask   │ │Canry││          │
│  │ Consumer │  any REST API    │  └─────────┘ └────────┘ └─────┘│          │
│  └──────────┘                  │         ┌──────────┐            │          │
│                                │         │ Sidecar  │            │          │
│  ┌──────────┐   APISIX Admin   │         │ (Java)   │            │          │
│  │ Operator │ ───────────────► │         └──────────┘            │          │
│  │ (ariactl)│   API / CLI      └───────────┬──────────┬──────────┘          │
│  └──────────┘                              │          │                      │
│                                    ┌───────▼───┐ ┌────▼───────┐             │
│                                    │  Redis    │ │ PostgreSQL │             │
│                                    │  Cluster  │ │            │             │
│                                    └───────────┘ └────────────┘             │
│                                         │                                    │
│                              ┌──────────▼──────────┐                        │
│                              │    LLM Providers     │                        │
│                              │ OpenAI | Anthropic   │                        │
│                              │ Google | Azure | Ollama                       │
│                              └─────────────────────┘                        │
│                                                                              │
│  ┌──────────┐                ┌──────────┐      ┌──────────┐                │
│  │Prometheus│ ◄── scrape ──  │  APISIX  │      │ Grafana  │                │
│  └──────────┘                └──────────┘      └──────────┘                │
│       │                                              ▲                      │
│       └──────────────────────────────────────────────┘                      │
│                            query                                             │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Container Diagram (C4 Level 2)

```
┌──────────────────────── APISIX Pod ────────────────────────┐
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                APISIX Container                        │  │
│  │                                                       │  │
│  │  Request Pipeline:                                    │  │
│  │  ┌────────┐  ┌──────────┐  ┌────────┐  ┌──────────┐ │  │
│  │  │ Auth   │→ │ Shield   │→ │ Mask   │→ │ Upstream │ │  │
│  │  │ Plugin │  │ Plugin   │  │ Plugin │  │ Proxy    │ │  │
│  │  └────────┘  └────┬─────┘  └───┬────┘  └──────────┘ │  │
│  │                   │            │                      │  │
│  │  Canary routes:   │            │                      │  │
│  │  ┌──────────┐     │            │                      │  │
│  │  │ Canary   │     │            │                      │  │
│  │  │ Plugin   │     │            │                      │  │
│  │  └────┬─────┘     │            │                      │  │
│  │       │           │            │                      │  │
│  └───────┼───────────┼────────────┼──────────────────────┘  │
│          │           │            │                          │
│          │    ┌──────▼────────────▼──────┐                  │
│          │    │  /var/run/aria/aria.sock  │ (UDS)            │
│          │    └──────────────┬───────────┘                  │
│          │                   │                               │
│  ┌───────┼───────────────────┼───────────────────────────┐  │
│  │       │    Aria Runtime Container (Java 21)            │  │
│  │       │                   │                            │  │
│  │       │    ┌──────────────▼────────────────┐           │  │
│  │       │    │       gRPC Server (UDS)        │           │  │
│  │       │    └──┬──────────┬────────────┬────┘           │  │
│  │       │       │          │            │                 │  │
│  │       │  ┌────▼────┐ ┌──▼──────┐ ┌───▼─────┐          │  │
│  │       │  │ Shield  │ │ Mask    │ │ Canary  │          │  │
│  │       │  │Handlers │ │Handlers │ │Handlers │          │  │
│  │       │  └─────────┘ └─────────┘ └─────────┘          │  │
│  │       │                                                │  │
│  │       │    Port 8081: /healthz, /readyz                │  │
│  └───────┼────────────────────────────────────────────────┘  │
│          │                                                    │
└──────────┼────────────────────────────────────────────────────┘
           │
    ───────┼──── Pod Boundary ────────────────────────────
           │
```

---

## 3. Data Flow Diagrams

### 3.1 Shield — LLM Request Flow

```
Client                APISIX (Shield Plugin)           Redis            Sidecar          LLM Provider
  │                         │                            │                 │                  │
  │── POST /v1/chat ───────►│                            │                 │                  │
  │                         │── GET quota ──────────────►│                 │                  │
  │                         │◄── remaining: 50K ─────────│                 │                  │
  │                         │                            │                 │                  │
  │                         │── Regex scan (Lua) ───┐    │                 │                  │
  │                         │◄──────────────────────┘    │                 │                  │
  │                         │   [if MEDIUM confidence]   │                 │                  │
  │                         │── gRPC: AnalyzePrompt ────────────────────►│                  │
  │                         │◄── {is_injection: false} ──────────────────│                  │
  │                         │                            │                 │                  │
  │                         │── Transform request ──┐    │                 │                  │
  │                         │◄──────────────────────┘    │                 │                  │
  │                         │                            │                 │                  │
  │                         │── Forward to provider ───────────────────────────────────────►│
  │                         │◄── Response ──────────────────────────────────────────────────│
  │                         │                            │                 │                  │
  │                         │── Transform to OpenAI ─┐   │                 │                  │
  │                         │◄───────────────────────┘   │                 │                  │
  │                         │── INCRBY tokens ─────────►│                 │                  │
  │                         │── gRPC: CountTokens (async) ──────────────►│                  │
  │                         │                            │                 │── reconcile ───►│
  │                         │── Add X-Aria-* headers ┐   │                 │                  │
  │                         │◄───────────────────────┘   │                 │                  │
  │◄── Response ────────────│                            │                 │                  │
  │                         │── Emit metrics (async) ┐   │                 │                  │
  │                         │◄───────────────────────┘   │                 │                  │
```

### 3.2 Mask — Response Masking Flow

```
Upstream            APISIX (Mask Plugin)              Redis           Sidecar         Client
  │                       │                             │                │               │
  │── JSON Response ────►│                             │                │               │
  │                       │── Read consumer role ──┐    │                │               │
  │                       │◄───────────────────────┘    │                │               │
  │                       │                             │                │               │
  │                       │── Resolve role policy ──┐   │                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │                             │                │               │
  │                       │── Apply JSONPath rules ─┐   │                │               │
  │                       │  (field mask per policy) │   │                │               │
  │                       │◄────────────────────────┘   │                │               │
  │                       │                             │                │               │
  │                       │── PII auto-detect ──────┐   │                │               │
  │                       │  (regex scan) ◄─────────┘   │                │               │
  │                       │                             │                │               │
  │                       │  [if tokenize strategy]     │                │               │
  │                       │── SET tokenize:{id} ──────►│                │               │
  │                       │                             │                │               │
  │                       │── Return masked JSON ──────────────────────────────────────►│
  │                       │                             │                │               │
  │                       │  [if NER enabled, async]    │                │               │
  │                       │── gRPC: DetectPII ─────────────────────────►│               │
  │                       │◄── entities found ─────────────────────────│               │
  │                       │── Emit audit + metrics ─┐   │                │               │
  │                       │◄────────────────────────┘   │                │               │
```

### 3.3 Canary — Traffic Routing Flow

```
Client              APISIX (Canary Plugin)             Redis          Upstream v1     Upstream v2
  │                       │                             │             (baseline)      (canary)
  │── Request ──────────►│                             │                │               │
  │                       │── GET canary state ───────►│                │               │
  │                       │◄── {pct: 10, state: S2} ──│                │               │
  │                       │                             │                │               │
  │                       │── Route decision ──────┐    │                │               │
  │                       │  (hash(client_ip) % 100)│   │                │               │
  │                       │◄───────────────────────┘    │                │               │
  │                       │                             │                │               │
  │                       │  [if hash < 10 → canary]    │                │               │
  │                       │── Forward to v2 ───────────────────────────────────────────►│
  │                       │◄── Response ────────────────────────────────────────────────│
  │                       │                             │                │               │
  │                       │  [if hash >= 10 → baseline] │                │               │
  │                       │── Forward to v1 ──────────────────────────►│               │
  │                       │◄── Response ──────────────────────────────│               │
  │                       │                             │                │               │
  │◄── Response ──────────│                             │                │               │
  │                       │                             │                │               │
  │                       │── INCR error counters ────►│                │               │
  │                       │── Check stage progression ►│                │               │
  │                       │  [if error delta > 2%]      │                │               │
  │                       │── PAUSE or ROLLBACK ──────►│                │               │
```

---

## 4. Integration Points Summary

| # | From | To | Protocol | Direction | Auth | Data Classification | SLA |
|---|------|-----|----------|-----------|------|-------------------|-----|
| 1 | Client | APISIX (Shield) | HTTPS | Inbound | APISIX consumer auth | L3-L4 transit (prompts) | < 10ms overhead |
| 2 | Client | APISIX (Mask) | HTTPS | Inbound | APISIX consumer auth | L3-L4 transit (responses) | < 1ms overhead |
| 3 | Client | APISIX (Canary) | HTTPS | Inbound | APISIX consumer auth | Inherits upstream | < 0.5ms overhead |
| 4 | Operator | APISIX Admin API | HTTPS | Inbound | Admin API key (L4) | L2 config data | < 2s response |
| 5 | Shield Lua | LLM Provider | HTTPS | Outbound | Provider API key (L4) | L3-L4 transit | Provider SLA |
| 6 | Shield Lua | Redis | TCP/TLS | Internal | Redis AUTH | L2 quota state | < 2ms |
| 7 | Mask Lua | Redis | TCP/TLS | Internal | Redis AUTH | L4 tokenization | < 2ms |
| 8 | Canary Lua | Redis | TCP/TLS | Internal | Redis AUTH | L1 canary state | < 2ms |
| 9 | Lua Plugins | Aria Runtime | gRPC/UDS | Internal | FS permissions | L3 transit | < 0.5ms |
| 10 | Aria Runtime | Redis | TCP/TLS | Internal | Redis AUTH | L2 reconciliation | < 2ms |
| 11 | Aria Runtime | PostgreSQL | TCP/TLS | Internal | User/password | L3 audit records | < 5ms |
| 12 | Shield | Webhook/Slack | HTTPS | Outbound | Webhook URL | L2 alert data | Best effort |
| 13 | Prometheus | APISIX | HTTP | Inbound | None (internal) | L1 metrics | Scrape interval |
| 14 | Canary Lua | Shadow Upstream | HTTP/HTTPS | Outbound | Pass-through | Inherits original | Fire-and-forget |

---

## 5. Trust Boundary Analysis

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRUST ZONE 1: External / Untrusted            │
│                                                                  │
│  • Client applications (OpenAI SDK)                              │
│  • API consumers (any HTTP client)                               │
│  • LLM providers (third-party services)                          │
│  • Webhook endpoints (Slack, custom)                             │
│                                                                  │
├──────────────── BOUNDARY: APISIX Auth Layer ─────────────────────┤
│                                                                  │
│                    TRUST ZONE 2: Gateway (APISIX Process)        │
│                                                                  │
│  • APISIX core (Nginx + OpenResty)                               │
│  • Lua plugins (aria-shield, aria-mask, aria-canary)             │
│  • Consumer identity validated by APISIX auth plugins            │
│                                                                  │
├──────────────── BOUNDARY: UDS (File Permissions) ────────────────┤
│                                                                  │
│                    TRUST ZONE 3: Sidecar (JVM Process)           │
│                                                                  │
│  • Aria Runtime (Java 21)                                        │
│  • gRPC handlers (Shield, Mask, Canary)                          │
│  • Trusts all requests from UDS (same pod only)                  │
│                                                                  │
├──────────────── BOUNDARY: TLS + Auth ────────────────────────────┤
│                                                                  │
│                    TRUST ZONE 4: Data Stores                     │
│                                                                  │
│  • Redis Cluster (quota state, token cache)                      │
│  • PostgreSQL (audit trail, billing records)                     │
│  • Access: Redis AUTH + TLS, Postgres user/password + TLS        │
│                                                                  │
├──────────────── BOUNDARY: Network + API Key ─────────────────────┤
│                                                                  │
│                    TRUST ZONE 5: Admin                            │
│                                                                  │
│  • APISIX Admin API (restricted network)                         │
│  • ariactl CLI (authenticated via Admin API key)                 │
│  • Grafana dashboards (Grafana auth)                             │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Trust Boundary Rules

| Boundary | Validation | Violation Response |
|----------|-----------|-------------------|
| Zone 1 → Zone 2 | APISIX auth plugin validates consumer identity. Input validation on request body | 401/403 for auth failure, 400 for validation |
| Zone 2 → Zone 3 | UDS file permissions (0660). Only APISIX and sidecar have access | Connection refused if permissions wrong |
| Zone 2/3 → Zone 4 | Redis AUTH + TLS 1.3. Postgres user/password + TLS 1.3 | Connection failure, fail-open/closed policy |
| Zone 1 → Zone 5 | Admin API key (L4). Network policy restricts access | 401 for invalid key |
| Zone 2 → External (LLM) | Provider API key (L4). TLS 1.3 | 502 PROVIDER_AUTH_FAILED |

---

*Document Version: 1.0 | Created: 2026-04-08*
*Status: Draft — Pending Human Approval*
