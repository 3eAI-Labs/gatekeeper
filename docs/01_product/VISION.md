# 3e-Aria-Gatekeeper: Universal APISIX Governance Suite

**Project:** 3e-Aria-Gatekeeper
**Author:** Levent Sezgin Genc (3EAI Labs Ltd)
**Date:** 2026-04-07
**Version:** 1.0
**License:** Apache 2.0
**Status:** Phase 1 — Vision
**Platform:** Apache APISIX
**Runtime:** Java 21+ (Virtual Threads / Project Loom) + Lua (APISIX native)

---

## 1. Problem Statement

Modern API Gateways handle traffic but miss three critical enterprise concerns:

### 1.1 AI Cost & Security
1. **Cost explosion** — LLM API calls are expensive and unpredictable. A single runaway prompt loop can generate thousands of dollars in charges overnight. No centralized way to enforce budgets per team, per application, or per user.
2. **Security blind spot** — Prompt injection, data exfiltration via prompts, and unfiltered model responses pass through without inspection. Traditional WAFs don't understand AI-specific attack vectors.
3. **Vendor lock-in** — Applications hard-code a single LLM provider. Switching requires code changes across every service.

### 1.2 Data Privacy at the Edge
4. **PII leaking through APIs** — Sensitive data (MSISDN, IMEI, national IDs, credit cards, health records) flows through API responses. Masking it requires code changes in every microservice. GDPR/KVKK/PDPL compliance is enforced inconsistently.
5. **Role-based data visibility** — An admin sees full credit card numbers, a support agent sees only last 4 digits, an external partner sees nothing. This logic is duplicated in every service.

### 1.3 Deployment Risk
6. **Dumb canary releases** — Canary routing exists but is blind — nobody watches error rates at 3 AM. A bad deploy goes unnoticed until customers complain.
7. **No automated rollback** — When a canary fails, someone has to manually intervene. By then, 5-10% of users have been affected.

**The API Gateway is the natural control point.** It sees every request and response. Yet no production-grade, open-source APISIX governance suite exists.

---

## 2. Vision

**3e-Aria-Gatekeeper** is a modular governance suite for Apache APISIX — three independent, composable plugins that enforce cost control, data privacy, and deployment safety at the gateway layer, without changing application code.

| Module | Name | One-liner |
|--------|------|-----------|
| **A** | **3e-Aria-Shield** | AI governance — token quotas, prompt security, smart LLM routing |
| **B** | **3e-Aria-Mask** | Dynamic data masking — GDPR/KVKK/PDPL compliance, zero code changes |
| **C** | **3e-Aria-Canary** | Intelligent progressive delivery — auto-rollback, traffic shadowing |

> *"Makes your infrastructure intelligent and compliant by default. No need to rewrite code — governance is enforced at the entry point of your network."*

---

## 3. Target Users

| User | Pain Point | Module |
|------|-----------|--------|
| **Platform / Infra teams** | "We can't control AI spend across 20 teams" | 3e-Aria-Shield |
| **Security / CISO** | "Prompt injection is our #1 AI risk" | 3e-Aria-Shield |
| **Compliance / DPO** | "We need GDPR/KVKK compliance without rewriting services" | 3e-Aria-Mask |
| **Telco BSS teams** | "MSISDN and IMEI data leaks in API responses" | 3e-Aria-Mask |
| **SRE / DevOps** | "Our canary deployments are blind and manual" | 3e-Aria-Canary |
| **Finance / FinOps** | "We got a $40K surprise bill from OpenAI" | 3e-Aria-Shield |
| **Developers** | "Switching LLM providers requires refactoring" | 3e-Aria-Shield |

---

## 4. Module A: 3e-Aria-Shield (FinOps & AI Security)

*The "Financial Armor" for AI operations.*

### 4.1 Token Quota & Cost Control

| Feature | Description | Technical Detail |
|---------|-------------|-----------------|
| **Token Quota** | Per-consumer, per-route, per-app monthly/daily token limits | Pre-flight: query Redis for budget status. Post-flight: extract `usage.total_tokens` from LLM response, update Redis + Postgres |
| **Dollar Budget** | Dollar-denominated budgets (auto-calculates from per-model pricing) | Pricing table: model → $/1K input tokens, $/1K output tokens |
| **Usage Tracking** | Real-time token count per request | Prometheus metrics: `aria_tokens_consumed{consumer, model, route}` |
| **Budget Alerts** | Webhook/Slack at 80%, 90%, 100% of budget | Configurable thresholds and channels |
| **Overage Policy** | block (return `402`), throttle, or allow-with-alert | Per-consumer config |
| **Cost Dashboard** | Grafana: spend by consumer, model, day, route | Pre-built JSON dashboard |

### 4.2 Prompt Security

| Feature | Description | Technical Detail |
|---------|-------------|-----------------|
| **Prompt Injection Detection** | Block "Ignore previous instructions" patterns | High-performance regex + vector-similarity (Java sidecar) |
| **PII-in-Prompt Scanner** | Detect/mask PII before it reaches the LLM | Regex + NER (Java sidecar). Action: block, mask, or warn |
| **Response Content Filter** | Scan LLM output for harmful/toxic content | Content moderation via Java sidecar (async, non-blocking) |
| **Data Exfiltration Guard** | Detect extraction of training data or system prompts | Pattern detection on response content |
| **Audit Trail** | Log all blocked/flagged prompts | Immutable audit log, compliance evidence |

### 4.3 Smart Routing & Resilience

| Feature | Description | Technical Detail |
|---------|-------------|-----------------|
| **Multi-Provider Routing** | OpenAI, Anthropic, Google, Azure OpenAI, Ollama/vLLM | Canonical request format → provider-specific transform |
| **Auto-Failover** | Primary LLM 5xx/timeout → fallback provider | Circuit breaker with configurable thresholds |
| **Latency-Based Routing** | Route to fastest provider (P95 history) | Sliding window latency tracker per upstream |
| **Cost-Based Routing** | Route to cheapest that meets quality threshold | Model pricing table + quality score |
| **Model Versioning** | Pin model versions per consumer | Consumer metadata → model override |
| **SSE Streaming** | Non-blocking pass-through, no buffering | `chunked transfer` + event-loop friendly |
| **OpenAI SDK Compatible** | Apps change `base_url` only — zero code changes | Canonical ↔ provider request/response mapping |

---

## 5. Module B: 3e-Aria-Mask (Dynamic Data Privacy)

*The "Compliance Shield" for GDPR/KVKK/PDPL.*

### 5.1 Role-Based Field Masking

| Feature | Description | Technical Detail |
|---------|-------------|-----------------|
| **Field-Level Masking** | Mask JSON response fields by consumer role | `body_filter` phase, JSONPath-based field selection |
| **Role Policy Engine** | `admin→full`, `agent→last4`, `partner→redact` | Per-consumer, per-route masking rules in APISIX metadata |
| **Configurable Masks** | `last4`, `first2last2`, `hash`, `redact`, `tokenize` | Per field-type mask strategy |
| **Zero Code Changes** | Services return full data, gateway masks at edge | Transparent to upstream services |

### 5.2 PII Pattern Detection

| Pattern | Example | Masking |
|---------|---------|--------|
| **MSISDN/Phone** | +90 532 *** 12 34 | Middle digits masked |
| **IMEI** | 35209100****** | Show only TAC (first 8) |
| **Credit Card (PAN)** | **** **** **** 1234 | Luhn-compliant, last 4 only |
| **National ID (TC Kimlik)** | ****56789** | Configurable masking |
| **Email** | l***@3eai-labs.com | Local part masked |
| **IBAN** | TR** **** **** **** **** 91 | Middle sections masked |
| **IP Address** | 192.168.*.* | Last octets masked |
| **Date of Birth** | ****-**-13 | Year/month masked |

### 5.3 Performance & Implementation

| Approach | When to Use | Latency |
|----------|-------------|---------|
| **Lua (default)** | Regex-based masking, simple patterns | < 1ms |
| **WASM (Rust)** | Complex NER, high-throughput masking | < 3ms |
| **Java sidecar** | Deep NER (named entity recognition), ML-based PII detection | < 10ms (async) |

### 5.4 Compliance Posture (capability statements only — see framing note below)

> **Important framing (locked 2026-04-25 per Karar 3 + `feedback_compliance_framing` memory):** Gatekeeper provides **controls** that operators use to **support** their compliance audits. Gatekeeper does **NOT** certify compliance with any framework — that requires an audited cardholder-data / personal-data environment, which is the operator's responsibility. The cells below are **capability statements**, not certifications.

| Framework | Capability provided |
|-----------|---------------------|
| GDPR (EU) | Right to minimization, purpose limitation — supported via PII masking at gateway edge + role-based policies + per-consumer data minimisation |
| KVKK (Turkey) | Personal data masking at processing layer; Turkish ID (TC Kimlik) regex with checksum validation; default Turkish NER model `savasy/bert-base-turkish-ner-cased` (engine code community; model artefact operator-supplied or enterprise-DPO bundled) |
| PDPL (Saudi Arabia / Iraq) | Data-localisation-aware masking; geographic-policy enforcement via consumer metadata |
| PCI-DSS (scope hygiene) | PAN-shape detection in prompts (Luhn-validated) + mask/block strategies prevent cardholder-data egress to upstream LLM providers. **Gatekeeper does NOT claim PCI-DSS compliance** — that requires an audited cardholder-data environment, which remains the operator's audit boundary. |

### 5.5 Audit & Evidence

| Feature | Description |
|---------|-------------|
| **Masking Audit Log** | What was masked, for whom, on which request, which rule triggered |
| **Prometheus Metrics** | `aria_mask_applied{field, rule, consumer}`, `aria_mask_violations` |
| **Compliance Report** | Exportable evidence for auditors |

---

## 6. Module C: 3e-Aria-Canary (Progressive Delivery)

*The "SRE Safety Net" for zero-touch deployments.*

### 6.1 Intelligent Traffic Splitting

| Feature | Description | Technical Detail |
|---------|-------------|-----------------|
| **Progressive Schedule** | 5% → 10% → 25% → 50% → 100% | Configurable stages with hold duration per stage |
| **Error-Rate Monitor** | Continuous canary vs. baseline error rate comparison | Sliding window, configurable delta threshold (default: >2%) |
| **Latency Guard** | Pause promotion if canary P95 > baseline P95 × 1.5 | Percentile tracking per upstream version |
| **Auto-Rollback** | If error threshold exceeded for 1 min → traffic to 0% + alert | Circuit breaker pattern with Slack/webhook notification |
| **Manual Override** | Instant promote-to-100% or rollback-to-0% via Admin API | APISIX Admin API extension |

### 6.2 Traffic Shadowing

| Feature | Description | Technical Detail |
|---------|-------------|-----------------|
| **Shadow Copy** | Copy 10% of live traffic to "next version" without affecting users | Duplicate request, discard shadow response to client |
| **Shadow Diff Engine** | Compare current vs. shadow response (status, body, latency) | Java sidecar: diff engine, log discrepancies |
| **Diff Report** | Structured diff report per shadow session | Grafana dashboard or JSON export |

### 6.3 Observability

| Metric | Description |
|--------|-------------|
| `aria_canary_traffic_pct` | Current canary traffic percentage |
| `aria_canary_error_rate{version}` | Error rate per version (canary vs. baseline) |
| `aria_canary_latency_p95{version}` | P95 latency per version |
| `aria_canary_rollback_total` | Total rollback events |
| `aria_shadow_diff_count` | Response differences detected |

**Integration:** Works standalone, or with ArgoCD Rollouts / Flagger.

---

## 7. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      Client / Application                        │
│               (OpenAI SDK with base_url = gateway)               │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                      Apache APISIX Gateway                       │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 3e-Aria-Shield (Module A)                                  │  │
│  │  ai-token-quota │ ai-prompt-firewall │ ai-model-router     │  │
│  │  ai-cost-tracker │ ai-fallback │ ai-response-filter        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 3e-Aria-Mask (Module B)                                    │  │
│  │  field-mask │ pii-detect │ role-policy-engine               │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 3e-Aria-Canary (Module C)                                  │  │
│  │  traffic-splitter │ error-rate-monitor │ shadow-diff        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Java 21 Sidecar — Aria Runtime (Virtual Threads)           │  │
│  │  • ScopedValue for per-request context (user, tenant, $$)  │  │
│  │  • Prompt analysis + injection defense (Shield)            │  │
│  │  • Tiktoken-accurate token counting (Shield)               │  │
│  │  • NER-based PII detection (Mask)                          │  │
│  │  • Shadow response diff engine (Canary)                    │  │
│  │  • Async-first: non-blocking I/O for Redis, Postgres, LLM │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Communication: gRPC over Unix Domain Sockets (UDS)              │
│  Observability: aria_* Prometheus metrics → GLP Stack            │
│                                                                  │
└────────────┬──────────────────┬──────────────────┬───────────────┘
             │                  │                  │
  ┌──────────▼──────┐  ┌───────▼──────┐  ┌───────▼──────┐
  │  LLM Providers  │  │  Upstream    │  │  Upstream    │
  │  OpenAI         │  │  v1 (stable) │  │  v2 (canary) │
  │  Anthropic      │  │              │  │              │
  │  Google Gemini  │  └──────────────┘  └──────────────┘
  │  Azure OpenAI   │
  │  Ollama / vLLM  │
  └─────────────────┘
```

### 7.1 Technical Decisions (Best of Both Approaches)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Plugin language** | Lua (APISIX native) for request/response pipeline | Zero overhead, runs in Nginx event loop |
| **Heavy processing** | Java 21 sidecar (Virtual Threads) | Concurrent long-polling AI requests, NLP/NER, accurate tokenization |
| **Sidecar communication** | gRPC over Unix Domain Sockets (UDS) | Minimal latency (~0.1ms), no TCP overhead |
| **Per-request context** | Java `ScopedValue` (not ThreadLocal) | Safe with millions of virtual threads, no memory leak risk |
| **Synchronization** | `ReentrantLock` (not `synchronized`) | Avoids virtual thread pinning to carrier threads |
| **Quota storage** | Redis (real-time) + Postgres (audit) | Redis for fast pre-flight checks, Postgres for billing accuracy |
| **Token counting** | Lua (approximate, fast) + Java (tiktoken-exact, async) | Lua blocks over-budget instantly, Java corrects billing post-facto |
| **PII masking** | Lua (regex, <1ms) → WASM/Rust (complex, <3ms) → Java (NER, <10ms) | Progressive: fast path for known patterns, heavy path for edge cases |
| **Streaming** | SSE pass-through in Lua, no buffering | Non-blocking, memory-safe for long AI responses |
| **Config format** | APISIX route metadata (JSON) | Native APISIX tooling, no external config store |
| **Metrics prefix** | `aria_*` | `aria_tokens_consumed`, `aria_mask_applied`, `aria_canary_error_rate` |

---

## 8. Non-Goals (v1.0)

| Explicitly NOT doing | Reason |
|---------------------|--------|
| Building our own LLM | We route to existing providers |
| RAG / Vector DB integration | Application concern, not gateway |
| Fine-tuning management | Out of scope |
| Chat history / session management | Application concern |
| UI for prompt playground | Focus on infrastructure |
| Full WAF replacement | Aria complements WAF, doesn't replace it |

---

## 9. Differentiation

| Existing Solution | What It Does | How 3e-Aria Differs |
|-------------------|-------------|---------------------|
| **LiteLLM** | Python proxy for LLM routing | Not a gateway plugin. No WAF/auth/rate-limit integration. No data masking or canary |
| **Portkey** | Commercial AI gateway | Proprietary, SaaS-only, expensive. No data masking or canary |
| **Kong AI Gateway** | Kong plugin for AI routing | Kong Enterprise license required. No data masking. No auto-rollback canary |
| **Cloudflare AI Gateway** | Edge AI proxy | Locked to Cloudflare. No on-prem. No data masking or canary |
| **OpenRouter** | Multi-model routing | SaaS — your data goes through their servers |
| **APISIX traffic-split** | Basic weighted routing | No error-rate monitoring, no auto-rollback, no shadow diff |

**3e-Aria position:** First open-source, composable governance suite for APISIX — AI cost control + data privacy + smart deployment in one package. Apache 2.0. Runs on your infrastructure.

---

## 10. Release Plan

### Track A: 3e-Aria-Shield (highest impact)
| Version | Scope | Month |
|---------|-------|-------|
| v0.1 | ai-model-router + ai-fallback (multi-provider routing, SSE streaming) | M1 |
| v0.2 | ai-token-quota + ai-cost-tracker (Redis quota, Prometheus metrics) | M2 |
| v0.3 | ai-prompt-firewall + ai-response-filter (Java sidecar integration) | M3 |
| **v1.0** | **Production-ready, Grafana dashboard, docs, blog post** | **M4** |

### Track B: 3e-Aria-Mask (compliance driver)
| Version | Scope | Month |
|---------|-------|-------|
| v0.1 | field-mask (Lua, JSONPath, regex — PAN, MSISDN, email, IBAN) | M2 |
| v0.2 | role-policy engine (per-consumer masking rules from APISIX metadata) | M3 |
| v0.3 | pii-detect (NER via Java sidecar) + WASM masking engine (Rust) | M4 |
| **v1.0** | **Audit logging, Grafana dashboard, GDPR/KVKK/PDPL compliance docs** | **M5** |

### Track C: 3e-Aria-Canary (SRE darling)
| Version | Scope | Month |
|---------|-------|-------|
| v0.1 | traffic-splitter + error-rate-monitor (weighted routing with auto-rollback) | M3 |
| v0.2 | latency guard + progressive schedule (configurable stages) | M4 |
| v0.3 | traffic-shadowing + shadow-diff (Java sidecar) | M5 |
| **v1.0** | **Grafana dashboard, ArgoCD/Flagger integration, blog post** | **M6** |

### Java Sidecar (Aria Runtime)
| Version | Scope | Month |
|---------|-------|-------|
| v0.1 | Core framework: gRPC/UDS server, ScopedValue, Virtual Thread pool | M2 |
| v0.2 | Shield modules: prompt analysis, tiktoken token counter | M3 |
| v0.3 | Mask modules: NER PII detection. Canary modules: shadow diff engine | M4-5 |
| **v1.0** | **Health checks, graceful shutdown, Helm chart** | **M5** |

### Combined Timeline
```
Month  │ M1        │ M2          │ M3          │ M4          │ M5          │ M6          │
───────┼───────────┼─────────────┼─────────────┼─────────────┼─────────────┼─────────────┤
Shield │ ██ v0.1   │ ██ v0.2     │ ██ v0.3     │ ██ v1.0 🎉  │             │             │
Mask   │           │ ██ v0.1     │ ██ v0.2     │ ██ v0.3     │ ██ v1.0 🎉  │             │
Canary │           │             │ ██ v0.1     │ ██ v0.2     │ ██ v0.3     │ ██ v1.0 🎉  │
Sidecar│           │ ██ v0.1     │ ██ v0.2     │ ██ v0.3     │ ██ v1.0     │             │
Blog   │           │             │             │ 📝 Shield   │ 📝 Mask     │ 📝 Canary   │
```

---

## 11. Success Metrics

| Metric | Target (6 months post-launch) |
|--------|-------------------------------|
| GitHub stars | 500+ |
| APISIX community | Featured in APISIX blog/newsletter |
| Contributors | 5+ external contributors |
| Production deployments | 10+ known deployments |
| Conference talk | 1 talk at ApacheCon, KubeCon, or API World |
| Blog post views | 5K+ combined across 3 launch posts |

---

## 12. Alignment with 3EAI Labs Portfolio

| Product | Layer | Role |
|---------|-------|------|
| **Sentinel** | Development | SDLC governance — ensures code quality with phase gates |
| **3e-Aria-Gatekeeper** | Runtime | Gateway governance — AI cost, data privacy, safe deployments |
| **CDS Platform** | Application | Consumer — AI agents route through Shield, PII masked by Mask |

**Narrative:** 3EAI Labs builds infrastructure for trustworthy AI — from development (Sentinel) to runtime (Aria) to operation (CDS).

### Why Three Modules, Not One?

| Reason | Explanation |
|--------|-------------|
| **Composable** | Install only what you need — Shield alone, or all three |
| **Independent release** | Each module has its own version, changelog, test suite |
| **Wider audience** | Shield → AI teams, Mask → compliance, Canary → SRE |
| **Shared sidecar** | Aria Runtime serves all three — one deployment, three capabilities |
| **3× visibility** | Each launch is a separate blog post + announcement |

---

## 13. Open Questions (Resolved)

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | API format: OpenAI-compatible or custom? | **OpenAI-compatible** | Lowest adoption barrier — apps change `base_url` only |
| 2 | Sidecar communication: gRPC or HTTP? | **gRPC over UDS** | ~0.1ms latency vs ~1ms HTTP. UDS avoids TCP overhead |
| 3 | Token counting: Lua or Java? | **Both** | Lua (fast, approximate) for real-time quota. Java (tiktoken-exact) for billing |
| 4 | WASM for masking? | **Yes, for v0.3** | Lua for simple patterns, WASM (Rust) for high-throughput complex masking |
| 5 | Virtual Thread pinning risk? | **ReentrantLock** | Avoid `synchronized` blocks. Use `ReentrantLock` throughout |
| 6 | Per-request context? | **ScopedValue** | Java 21 native, safe with virtual threads, no ThreadLocal memory leak |

---

*This document is the Phase 1 deliverable per Sentinel SDLC.*
*Human approval required before proceeding to Phase 2 (Business Analysis).*

*Document Version: 1.1.3 | Created: 2026-04-08 | Revised: 2026-04-25 (v1.1.3 spec-coherence sweep)*
*Change log v1.0 → v1.1.3: §5.4 Compliance section reframed per Karar 3 (2026-04-25) and `feedback_compliance_framing` memory — table is now "Capability provided" (capability statements), not "Coverage" (certification implication). PCI-DSS row explicitly states "Gatekeeper does NOT claim PCI-DSS compliance — scope hygiene only". Other rows extended with concrete capabilities. Mirrors HLD v1.1.1 §10.2 + RELEASE_NOTES v0.1.1 Compliance Posture + README Compliance Posture (single source of framing across artefacts).*

*Copyright 2026 3EAI Labs Ltd. Apache 2.0 License.*
