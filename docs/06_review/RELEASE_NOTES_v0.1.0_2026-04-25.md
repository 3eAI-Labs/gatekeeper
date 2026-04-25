# Release Notes — 3e-Aria-Gatekeeper v0.1.0

**Release Date:** 2026-04-25
**License:** Apache 2.0 (Lua plugins) · community + persona-gated enterprise tiers (Java sidecar)
**Replaces:** [`RELEASE_NOTES v1.0`](archive/RELEASE_NOTES_v1.0_2026-04-08.md) (2026-04-08), now archived
**Driver:** Spec freeze v1.1 (`gatekeeper@a63986f`) + adversarial drift report (`PHASE_REVIEW_2026-04-25.md`) + audit-pipeline closure v1.1.1 (`aria-runtime@d487026`, ADR-009) — supersedes the 2026-04-08 release notes which contained claims that did not match shipped reality.

---

## Overview

**3e-Aria-Gatekeeper** is a modular governance suite for Apache APISIX — three independent, composable plugins that enforce AI cost control, data privacy, and progressive delivery at the gateway layer, without changes to upstream applications. Horizontal product (not telco-specific); customer model mix is unpredictable by design.

This v0.1.0 release captures the first 17 days of community-tier shipping after the initial 2026-04-08 design baseline:
- Real `tiktoken` token counting (jtokkit, `cl100k_base` fallback for unknown models — Karar A)
- Structural shadow diff for canary deployments (3 iterations, 2026-04-22 → 2026-04-23)
- NER-backed PII detection via sidecar HTTP bridge (BR-MK-006, 2026-04-24)
- Generic per-endpoint circuit breaker shared library (`aria-circuit-breaker.lua`, 2026-04-24)
- License model formalised: open-core Apache 2.0 + persona-gated enterprise tiers
- HTTP/JSON over loopback TCP as the canonical Lua↔sidecar transport (ADR-008 supersedes ADR-003 for the Lua portion)
- Operator documentation rewritten end-to-end (QUICK_START + CONFIGURATION + DEPLOYMENT, 2026-04-25)
- Audit pipeline closed end-to-end via `audit/AuditFlusher` Spring `@Scheduled` LPOP drain (ADR-009; closes FINDING-003 from `PHASE_REVIEW_2026-04-25.md`)

---

## What's Included

### 3e-Aria-Shield — AI Governance (Apache 2.0)

Route LLM requests through APISIX with automatic cost control, multi-provider failover, and prompt-tier security.

- 5 LLM providers: OpenAI, Anthropic, Google Gemini, Azure OpenAI, Ollama
- Zero application changes — point your OpenAI SDK at the gateway by changing only `base_url`
- Token quotas + dollar budgets (block / throttle / allow-with-alert)
- Auto-failover with Redis-backed circuit breaker + configurable threshold/cooldown
- SSE streaming pass-through with token counting
- Regex-tier prompt-injection detection (community)
- PII-in-prompt detection with mask/block/warn actions
- Model version pinning (BR-SH-018)
- **NEW** since 2026-04-22: Real `tiktoken` token counting via jtokkit (community sidecar); `cl100k_base` fallback for unknown models (Karar A locked) — see LLD §5.3.1

### 3e-Aria-Mask — Dynamic Data Privacy (Apache 2.0)

Mask PII in API responses (and prompts) at the gateway edge. Supports operator's compliance posture; does not certify compliance.

- JSONPath field masking with role-based policies (admin → full, agent → mask, partner → redact)
- 12 mask strategies (`last4`, `first2last2`, `hash`, `redact`, `mask:email/phone/national_id/iban/ip/dob`, etc.)
- Auto-detect 8 PII patterns: PAN (Luhn-validated), MSISDN, TC Kimlik (with checksum), email, IBAN, IMEI, IP address, DOB
- **NEW** since 2026-04-24 (BR-MK-006): NER-backed PII detection via sidecar HTTP bridge
  - Pluggable multi-engine architecture (Apache OpenNLP for English + DJL HuggingFace ONNX for Turkish/multilingual)
  - Circuit-breaker pairing: Lua outer per-endpoint + Java inner Resilience4j
  - `fail_mode: open` (default, community) or `fail_mode: closed` (per-route, for healthcare/finance/defence)
  - Engine code is community tier; multilingual model artefacts are operator-supplied (see `runtime/docs/NER_MODELS.md`) or enterprise-DPO bundled

### 3e-Aria-Canary — Progressive Delivery (Apache 2.0)

Deploy safely with automatic error monitoring, latency guard, and rollback. Canary "Pro" tier was retired 2026-04-21 — full canary is community tier (no enterprise gating).

- Configurable progressive schedule (e.g. 5% → 10% → 25% → 50% → 100% with hold durations)
- Error-rate monitoring (canary vs. baseline, sliding 10s windows)
- Latency guard (P95 comparison)
- Auto-rollback on sustained breach
- Manual override via APISIX plugin control API (BR-CN-005): `GET/POST /v1/plugin/aria-canary/{status|promote|rollback|pause|resume}/{route_id}` — see API_CONTRACTS §2.2-2.4
- Consistent-hash routing option (sticky client → version assignment within a stage)
- **NEW** since 2026-04-22: Traffic shadow upstream (BR-CN-006, fire-and-forget)
- **NEW** since 2026-04-23 (BR-CN-007): Structural shadow response diff via sidecar HTTP bridge — 3 iterations: Iter 1 Lua-only basic diff, Iter 2 `DiffEngine` in Java, Iter 2c HTTP `POST /v1/diff` bridge with base64 body envelope

### Aria Runtime — Java 21 Sidecar (community + persona-gated enterprise)

Heavy-processing backend for Lua plugins. Per ADR-008: Lua plugins reach the sidecar via **HTTP/JSON over loopback TCP** (`127.0.0.1:8081`). gRPC services exist as forward-compat for non-Lua callers but have no Lua callers in v0.1.

**Community tier** (free; ships in `ghcr.io/3eai-labs/gatekeeper/aria-runtime`):
- `TokenEncoder` — real `tiktoken` via jtokkit; `cl100k_base` fallback (Karar A) for unknown models with `Accuracy.FALLBACK` flag
- `DiffEngine` + `DiffController` — structural shadow diff (status, headers, body similarity, diff paths)
- `NerDetectionService` + 7 supporting NER classes — pluggable multi-engine pipeline (OpenNLP English + DJL multilingual); model artefacts NOT bundled in slim image
- `MaskController` HTTP bridge for Lua-callable NER detection
- HTTP health endpoints (`/healthz`, `/readyz`, `/actuator/*`)

**Enterprise tier** (license-key gated, separate codebase — not shipped in this release; commercial licensing only):
- **Security (CISO):** Vector-similarity prompt-injection detection · Content moderation/response filtering · Continuously-updated injection corpus
- **Privacy & Compliance (DPO):** Multilingual NER **model artefacts** (TR/AR/EN) · Tamper-proof WORM audit log · SOC2 / HIPAA / KVKK / GDPR export formats · Continuously-updated compliance mappings
- **Financial Governance (CFO):** Chargeback reports · Multi-currency · Tax-aware billing · Team/project cost attribution · Budget alert escalation

The defensible enterprise moat is in **continuously-updated assets** (injection corpus, compliance mappings) and **persona-aligned budgets**, not in static feature gates.

---

## Compliance Posture

> **Important framing.** Gatekeeper provides controls that operators use to **support** their compliance audits. Gatekeeper does NOT certify compliance with any framework — that requires an audited cardholder-data / personal-data environment, which is the operator's responsibility.

| Framework | Capability provided |
|---|---|
| **GDPR (EU)** | PII masking at gateway edge; role-based policies; per-consumer data minimisation |
| **KVKK (Turkey)** | Same as GDPR + Turkish ID (TC Kimlik) regex with checksum validation; default Turkish NER model `savasy/bert-base-turkish-ner-cased` (engine code community; model artefact operator-supplied or enterprise-bundled) |
| **PDPL (Saudi Arabia / Iraq)** | Same as GDPR + geographic-policy enforcement via consumer metadata |
| **PCI-DSS scope hygiene** | PAN-shape detection in prompts (Luhn-validated); mask/block strategies prevent cardholder-data egress to upstream LLM providers. **Gatekeeper does NOT claim PCI-DSS compliance** — that requires an audited cardholder-data environment, which remains the operator's audit boundary. |

> **Audit pipeline status:** Durable audit log persistence (required for BR-SH-015 / BR-MK-005 / KVKK Art. 12 retention) is **shipped end-to-end** in v0.1.0 — `audit/AuditFlusher` (Spring `@Scheduled` LPOP drain, ADR-009) persists Lua-emitted events to Postgres. Operators must still ensure the migration Job has run (see Known Limitations §2 about migration bootstrap).

---

## Quick Start

```bash
git clone https://github.com/3eAI-Labs/gatekeeper.git
cd gatekeeper/runtime
docker compose up -d

# Verify (~15s after up)
curl -s http://localhost:8081/healthz | jq    # sidecar liveness
curl -s http://localhost:8081/readyz  | jq    # sidecar readiness (Redis + Postgres)
curl -s http://localhost:9080/health/echo     # APISIX bundled smoke route
```

End-to-end LLM proxy + mask + canary walkthrough lives in [`docs/05_user/QUICK_START.md`](../05_user/QUICK_START.md). Operator-grade configuration reference: [`runtime/docs/CONFIGURATION.md`](../../runtime/docs/CONFIGURATION.md). Kubernetes deployment: [`runtime/docs/DEPLOYMENT.md`](../../runtime/docs/DEPLOYMENT.md).

---

## Requirements

| Component | Version |
|---|---|
| Apache APISIX | >= 3.8 |
| Redis | >= 7.0 (Cluster recommended for production) |
| PostgreSQL | >= 16 (for audit / billing tables — see Known Limitations §2 about v0.1 migration bootstrap) |
| Java | 21+ (toolchain pinned in `aria-runtime/build.gradle.kts`); JVM image based on Java 25 launcher (Gradle 9.4.1) |
| Helm | >= 3.12 (only for Kubernetes deployment) |
| Kubernetes | 1.27+ (only for Kubernetes deployment; Helm chart uses standard `apps/v1`) |
| Docker / OCI runtime | 24+ (multi-arch image, BuildKit) |

Optional for Kubernetes: Prometheus Operator (for the `PrometheusRule` template the chart ships), Grafana with sidecar (for auto-discovery of the 3 bundled dashboards).

---

## User-story Implementation Status

Updated from the 2026-04-08 sister doc with shipped iterations.

| Story | Title | v0.1 Status |
|---|---|---|
| US-A01 | Multi-provider LLM routing | Shipped |
| US-A02 | Auto-failover | Shipped |
| US-A03 | SSE streaming | Shipped |
| US-A04 | OpenAI SDK compatibility | Shipped |
| US-A05 | Token quota enforcement | Shipped |
| US-A06 | Dollar budget control | Shipped (real tiktoken via jtokkit since 2026-04-22) |
| US-A07 | Usage metrics | Shipped |
| US-A08 | Budget alerts | Shipped |
| US-A09 | Overage policy | Shipped |
| US-A10/A11/A12 | Sidecar prompt-injection detection | **Stub in v0.1.** Lua-tier regex coverage active (community); sidecar `analyzePrompt` returns safe defaults. v0.3 enables real vector-similarity (enterprise CISO tier) |
| US-A17 | Model version pinning | Shipped |
| US-B01 | Field-level masking | Shipped |
| US-B02 | Role-based policies | Shipped |
| US-B03 | PII pattern detection | Shipped |
| US-B04 | Configurable strategies | Shipped (12 strategies; `tokenize` emits non-reversible hash in v0.1 — Redis-backed reversible token reserved for v0.2) |
| US-B05 | Masking audit log | Shipped end-to-end (`audit/AuditFlusher` Spring `@Scheduled` LPOP drain — see ADR-009; closes FINDING-003) |
| US-B06 | NER-backed PII detection | Shipped 2026-04-24 (BR-MK-006) — engine code only, model artefacts operator-supplied |
| US-C01 | Progressive splitting | Shipped |
| US-C02 | Error-rate monitoring | Shipped |
| US-C03 | Auto-rollback | Shipped |
| US-C05 | Manual override (Admin API) | Shipped |
| US-C06 | Traffic shadow | Shipped 2026-04-22 (BR-CN-006) |
| US-C07 | Shadow diff comparison | Shipped 2026-04-23 (BR-CN-007) |
| US-S01 | Sidecar transport (was "gRPC/UDS server" in v1.0) | Shipped — **HTTP/JSON over loopback TCP** per ADR-008 (gRPC retained as forward-compat). Original "gRPC/UDS" wording corrected. |
| US-S02 | Virtual threads | Shipped |
| US-S03 | Health checks | Shipped |
| US-S04 | Graceful shutdown | Shipped (HTTP + gRPC drain) |

Full traceability + deferral matrix: LLD v1.1 §12.

---

## Known Limitations (v0.1) — honestly listed

> 🔴 = blocks compliance/durability claims · 🟡 = workaround exists · 🟢 = nice-to-have deferred

### ✅ 1. Audit pipeline (FINDING-003) — CLOSED in v1.1.1 (`aria-runtime@d487026`)

This was tracked as a critical v0.1 gap in earlier drafts of this document. **It was closed end-to-end** in `aria-runtime@d487026` (same-day after the v1.1 spec freeze).

**Implementation:** `audit/AuditFlusher` — Spring `@Component @Scheduled(fixedDelayString="${aria.audit.flush-interval-ms:5000}")`. Non-blocking LPOP loop on `aria:audit_buffer`, drains up to 100 events per scheduler tick to `PostgresClient.insertAuditEvent`. Lua side `record_audit_event` unchanged. Test count 121 → 128, all green.

**Decision rationale (ADR-009):** LPOP polling chosen over the `POST /v1/audit/event` HTTP bridge that this document had earlier labelled "preferred". Karar A (single-path simplicity, sidecar bears all complexity) selected per Levent's "neden iki path?" pushback against the hybrid alternative. ADR-009 documents the orthogonality with ADR-008 (HTTP bridge governs synchronous Lua→sidecar request/response; audit is asynchronous Lua emit → Redis buffer → sidecar drain — different patterns, no conflict).

**Operator signal:** `AuditFlusher.persistedTotal` / `failedTotal` counters expose health to Prometheus. Alert on non-zero `failedTotal` rate. No new ARIA error code is emitted by the closed pipeline (the previously-reserved `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` was retired in ERROR_CODES.md v1.1.1).

**Status:** BR-SH-015 (Audit Event Recording) and BR-MK-005 (Masking Audit) are now Implemented end-to-end. KVKK Art. 12 retention and any compliance-supportive durable-audit claim is substantiated by Gatekeeper alone (modulo operator running migrations — see §2 below).

**Deferred to v0.3:** dead-letter queue for poison messages; longer Redis buffer TTL; backpressure on producer; sub-second visibility (current default is 5s flush interval, configurable down to ~250ms).

### 🔴 2. DB migrations not auto-bootstrapped by sidecar (FINDING-005)

Migration SQL files (`V001..V003`) exist in `db/migration/` and are correct (verified consistent with DB_SCHEMA.md DDL). The Helm chart includes a one-shot Flyway Job that runs them before the sidecar Deployment is rolled. **But the sidecar JAR does not include a Flyway runner** — `aria-runtime/build.gradle.kts` has no Flyway dependency and `application.yml` has no `spring.flyway.*` config.

**Net effect:** docker-compose dev users must apply migrations manually; Helm users get them via the migration Job. Sidecar starts successfully without the tables existing; on missing `audit_events` table the v1.1.1 `AuditFlusher` will increment `failedTotal` and ERROR-log on every drained event — surfacing the gap rather than silencing it. (This is a deliberate change vs the pre-v1.1.1 silent-drop behaviour.)

**Operator workaround for v0.1:** Always run the Helm migration Job before bringing up the sidecar; for docker-compose, run `flyway/flyway:10-alpine migrate` once against the dev Postgres before `compose up`.

**v0.2 fix:** Add Flyway dependency + `spring.flyway.locations: classpath:db/migration` to `build.gradle.kts` and `application.yml`. Sidecar will apply migrations idempotently at startup.

### 🟡 3. ariactl CLI deferred to v0.2 (FINDING-001)

HLD §3.5 originally promised a 7-command Go CLI (`quota set/status`, `mask rules list`, `canary status/promote/rollback`, `pricing update`). Not built in v0.1.

**v0.1 substitute:** Operators use the APISIX Admin API directly + the canary plugin control endpoints already shipped:
- Canary state / progression / manual override:
  - `GET /v1/plugin/aria-canary/status/{route_id}`
  - `POST /v1/plugin/aria-canary/promote/{route_id}`
  - `POST /v1/plugin/aria-canary/rollback/{route_id}`
  - `POST /v1/plugin/aria-canary/pause/{route_id}`
  - `POST /v1/plugin/aria-canary/resume/{route_id}`
- Quota status / pricing: read directly from Redis with `redis-cli` against the Aria key namespace; route metadata via APISIX `GET /apisix/admin/routes/{id}` + `jq` on the plugins block.

**v0.2 plan:** Single Go binary, ~4 commands at MVP (`quota status`, `canary status`, `canary promote`, `canary rollback`); distributed via GitHub Releases for Linux / macOS / Windows.

### 🟡 4. Sidecar PromptAnalyzer + ContentFilter are stubs (FINDING-004)

`ShieldServiceImpl.analyzePrompt` returns `is_injection=false`; `filterResponse` returns `is_harmful=false`. The Lua side does not invoke them in v0.1. Community-tier prompt security is provided by the **regex-tier** branch in `aria-shield.lua` (BR-SH-011 community).

**v0.3 fix:** Vector-similarity prompt-injection detection + content moderation are **enterprise CISO tier** features (HLD §14). The defensible moat is the continuously-updated injection corpus, not the code path itself.

### 🟡 5. Karar B (token-counting role semantics) open

`ShieldServiceImpl.countTokens` returns total `tokenCount` for the supplied content but does NOT separately attribute tokens to message roles (`system` / `user` / `assistant`). Inline source comment: *"Karar B (role semantics) is still open."*

**v0.1 workaround:** Lua side carries the input/output split via the upstream `usage` object that all major providers return.

**v0.2 fix:** Lock OpenAI's standard role overhead (~3 tokens per message) as the policy via **ADR-009**; implement.

### 🟡 6. Reversible tokenization not implemented

`mask_strategies.tokenize` emits a non-reversible hash in v0.1. The HLD §9.1 `aria:tokenize:` Redis key namespace is reserved for v0.2's Redis-backed reversible token store with AES-256 encryption.

**v0.1 workaround:** Use `last4` or `redact` strategies; reversible tokenization is not currently a v0.1 feature.

### 🟢 7. WASM masking engine deferred (HLD §2.3 / ADR-005)

Lua + Java sidecar covers the v0.1 perf envelope. WASM remains a planned high-throughput specialised tier; revisit if a customer's mask-heavy workload requires it.

### 🟢 8. Coverage / SAST re-run on post-NER HEAD

Pre-existing test infrastructure intact (busted for Lua, JUnit + Mockito for Java). v1.0 release notes' coverage / SAST claims have not been re-run against today's HEAD (jtokkit, NER package, HTTP controllers, AuditFlusher all added since); v0.2 should add JaCoCo gate (Java) + busted coverage report (Lua) to CI and re-run SAST against `aria-runtime@d487026` or later.

### 🟢 9. Latency guard P95 simplification

Canary latency guard uses Redis sorted-set sliding windows; full t-digest implementation deferred (ADR opportunity for v0.2 if a customer reports tail-latency drift in canary decisions).

---

## What changed from the original 2026-04-08 release notes

For full audit trail, see [`PHASE_REVIEW_2026-04-25.md`](PHASE_REVIEW_2026-04-25.md) (15 findings).

| 2026-04-08 claim | 2026-04-25 reality / correction |
|---|---|
| *"GDPR/KVKK/PCI-DSS compliance without code changes"* | Reframed: capability statements only. PCI-DSS is **scope hygiene**, not compliance certification. See "Compliance Posture" above and [`feedback memory: compliance framing`](../../memory). |
| *"~0.1ms IPC via Unix Domain Sockets"* | **Wrong by 1-2 orders of magnitude.** UDS gRPC was the v1.0 design intent (ADR-003); shipped reality is HTTP/JSON over loopback TCP (~1-2ms) per ADR-008 (supersedes ADR-003 for Lua transport). Trade-off accepted to avoid `lua-resty-grpc` dependency. |
| *"Sidecar handlers are stubs: Prompt analysis, tiktoken counting, NER detection, and shadow diff engine will be implemented in v0.3"* | **Outdated.** Token counting is real (jtokkit, since 2026-04-22). Shadow diff is real (`DiffEngine`, since 2026-04-22 → 2026-04-23). NER detection engine is real (since 2026-04-24); model artefacts remain operator-supplied or enterprise-DPO bundled. Only `PromptAnalyzer` + `ContentFilter` remain stubs in v0.1 — see Limitations §4. |
| *"All business rules implemented PASS"* | **PARTIAL at v1.0; now Implemented at v1.1.1.** BR-SH-015 / BR-MK-005 audit pipelines were PARTIAL through the v1.1 spec freeze; flipped to Implemented end-to-end in v1.1.1 via `audit/AuditFlusher` (`aria-runtime@d487026`, ADR-009). BR-CN-005 was missing from the v1.0 traceability matrix despite being implemented (corrected in LLD v1.1 §12). New BRs since 2026-04-08: BR-MK-006 (NER), BR-CN-006 (shadow), BR-CN-007 (shadow diff). |
| *"31 codes cataloged"* | **84 codes today** (78 → 85 at v1.1 freeze → 84 after v1.1.1 retired `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` per ADR-009). New ARIA codes added per spec freeze: `ARIA_MK_NER_*` (3), `ARIA_CN_SHADOW_*` (2), `ARIA_RT_TOKENIZER_FALLBACK`. |
| *"ariactl CLI"* — listed as shipped under "Known Limitations: No Admin UI" | **Deferred to v0.2** — see Limitations §3 above. v0.1 substitute documented. |
| *"AI Reviewer pending human final review"* — silently treated as approval | **This release explicitly requires human signature** before merge. See `GUIDELINES_MANIFEST.yaml` `phase_gates.require_human_signature`. The 2026-04-08 process failure must not recur. |

---

## Status

**Pending Human Final Review.** This v0.1.0 release will not be tagged or pushed to a release artefact until a human signature (in commit history, not just memory files) confirms acknowledgment of all Known Limitations §1 (closed in v1.1.1) through §9 above. See `GUIDELINES_MANIFEST.yaml` `phase_gates.require_human_signature`.

---

## See also

- [`HLD.md`](../03_architecture/HLD.md) v1.1 — High-Level Design
- [`LLD.md`](../04_design/LLD.md) v1.1.1 — Low-Level Design (audit pipeline closure update)
- [`API_CONTRACTS.md`](../03_architecture/API_CONTRACTS.md) v1.1 — REST + HTTP bridge + gRPC + plugin schemas
- [`ERROR_CODES.md`](../04_design/ERROR_CODES.md) v1.1.1 — 84 ARIA error codes (`ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` retired)
- [`ADR-008`](../03_architecture/ADR/ADR-008-http-bridge-over-grpc.md) — HTTP-bridge supersedes gRPC-UDS for Lua transport
- [`ADR-009`](../03_architecture/ADR/ADR-009-audit-flusher-lpop-polling.md) — Audit pipeline uses LPOP polling, not HTTP bridge (closes FINDING-003)
- [`PHASE_REVIEW_2026-04-25.md`](PHASE_REVIEW_2026-04-25.md) — adversarial drift report (15 findings) driving this release
- [`CODE_REVIEW_REPORT_2026-04-25.md`](CODE_REVIEW_REPORT_2026-04-25.md) v1.1.1 — code review post-spec-freeze v1.1.1 (audit-pipeline closure update)
- [`archive/RELEASE_NOTES_v1.0_2026-04-08.md`](archive/RELEASE_NOTES_v1.0_2026-04-08.md) — historical baseline (claims now corrected)

---

*Copyright 2026 3eAI Labs Ltd.*
*Open-core: Apache 2.0 Lua plugins · community sidecar · persona-gated enterprise tiers (Security · Privacy · FinOps).*
*3eAI = Ethic · Empathy · Aesthetic.*
