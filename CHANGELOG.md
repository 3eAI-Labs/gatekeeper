# Changelog — 3e-Aria-Gatekeeper

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v0.1.1] — 2026-04-25 (patch)

Same-day patch closing the one remaining v0.1 critical gap. **All v0.1 critical gaps are now closed.**

### Added
- **Sidecar bootstraps schema via Flyway at startup** (`aria-runtime@9bd22d5`). `build.gradle.kts` declares `flyway-core` + `flyway-database-postgresql` + `postgresql` JDBC; `application.yml` configures `spring.flyway.*` against the existing `aria.postgres.*` coordinates (single source of truth). `baseline-on-migrate=true` for safe upgrades against pre-migrated DBs; `validate-on-migrate=true` catches checksum drift; disable via `ARIA_FLYWAY_ENABLED=false` for environments managing migrations externally (e.g., split-permission DDL deployments).
- V001..V003 SQL files vendored into `aria-runtime/src/main/resources/db/migration/` (byte-identical with the canonical copy in `gatekeeper/db/migration/`; v0.2 candidate consolidation).
- `docs/06_review/HUMAN_SIGN_OFF_v0.1.1.md` — explicit Phase 4 + Phase 6 sign-off for the single v0.1.1 delta.

### Fixed
- **FINDING-005** — DB migrations not auto-bootstrapped in sidecar. docker-compose dev users no longer need to apply migrations manually. Helm migration Job remains useful for split-permission deployments where the sidecar role lacks DDL grants.

### Documentation
- `docs/04_design/DB_SCHEMA.md` v1.1.1 → v1.1.2 (§1.2 sidecar-Flyway row flipped ❌ → ✅; v0.2 fix item §1 retired).
- `docs/06_review/CODE_REVIEW_REPORT_2026-04-25.md` v1.1.1 → v1.1.2 (verdict 1 critical → 0 critical; CONDITIONAL PASS → unconditional PASS).
- `docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md` — added "v0.1.1 Patch" subsection at top; Known Limitation §2 rewritten as ✅ CLOSED.

---

## [v0.1.0] — 2026-04-25 (initial honest release)

> **Note:** This release supersedes the [pre-freeze 2026-04-08 baseline](#010-pre-freeze--2026-04-08-never-publicly-released) below, which was tagged but **never publicly released**. The 2026-04-08 baseline contained spec/code drift that was reconciled by the v1.1 spec freeze (`a63986f`) + v1.1.1 audit-pipeline closure (`249474b`) on 2026-04-25, then signed off (`7ea75cc`) and re-tagged. See [HUMAN_SIGN_OFF_v0.1.0.md](docs/06_review/HUMAN_SIGN_OFF_v0.1.0.md) for the explicit sign-off contents.

### Added
#### Module B: 3e-Aria-Mask
- **NER-based PII detection** (BR-MK-006, 2026-04-24). The Mask plugin delegates named-entity detection (PERSON / LOCATION / ORGANIZATION / MISC) to the `aria-runtime` sidecar over an HTTP bridge (`POST /v1/mask/detect`). Regex-only detection remains the default; enable `ner.sidecar.enabled=true` to activate. Runs inline in `body_filter` after regex so the ML model never sees fields already classified as structural PII.
  - **Turkish-first positioning:** ships with pluggable engines — Apache OpenNLP for English + DJL/ONNX Runtime for Turkish BERT (default model: `savasy/bert-base-turkish-ner-cased`). Add new languages by implementing the Java `NerEngine` interface and listing the id in `aria.mask.ner.engines`. Engine code is community tier; multilingual model artefacts are operator-supplied (slim image) or enterprise-DPO bundled.
  - **Fail modes:** `open` (default, availability-first — regex-only result if sidecar unreachable) or `closed` (defensive — all candidate fields redacted when NER cannot verify).
  - **Two-layer circuit breaker:** per-endpoint breaker in Lua (`ngx.shared.dict` state) + Resilience4j inside the JVM for defense in depth.
  - New schema block: `ner.sidecar.{enabled, endpoint, timeout_ms, max_content_bytes, fail_mode, min_confidence, circuit_breaker.{failure_threshold, cooldown_ms}, entity_strategy}`.
  - New metrics: `aria_mask_ner_calls_total{route,result}`, `aria_mask_ner_latency_ms` (histogram), `aria_mask_ner_entities_total{type}`, `aria_mask_ner_circuit_state{endpoint}` (gauge).

#### Module C: 3e-Aria-Canary
- **Traffic shadowing — basic diff (Iter 1, 2026-04-22)** — Fire-and-forget duplication of a configurable percentage of live traffic to a shadow upstream, with Lua-side basic diff (HTTP status, body length, latency delta) and Prometheus metrics (US-C06, BR-CN-006).
  - New schema block: `shadow.{enabled, traffic_pct, shadow_upstream.nodes, timeout_ms, failure_threshold, disable_window_seconds}`.
  - Auto-disable after configurable consecutive failures (default 3) with sliding-window counter; auto-recover after `disable_window_seconds` (default 300s).
  - Shadow requests carry `X-Aria-Shadow: true` header; the plugin refuses to shadow a request that already has the flag, preventing recursion.
  - New metrics: `aria_shadow_requests_total`, `aria_shadow_diff_count{type=status|body_length}`, `aria_shadow_latency_delta_ms` (histogram), `aria_shadow_upstream_failures`, `aria_shadow_upstream_down`.
- **Structural shadow diff engine** (Iter 2 + 2c, 2026-04-22 → 2026-04-23) — Sidecar-side `DiffEngine` (`@Service`) compares status, headers, and body structure between primary and shadow responses; exposed via `POST /v1/diff` HTTP bridge (US-C07, BR-CN-007).
- **Iter 3 documentation** (2026-04-23) — Operator-facing diff report format and tuning guidance.
- **Admin control_api** (BR-CN-005, was missing from v1.0 traceability matrix despite being implemented). `_M.control_api()` exposes status / promote / rollback / pause / resume via APISIX plugin control-plane URLs. v0.1 substitute for the deferred ariactl CLI.

#### Aria Runtime (Java sidecar)
- **Real `tiktoken` token counting via jtokkit** (2026-04-22, Karar A locked) — `TokenEncoder` (`@Component`) uses jtokkit (Apache 2.0 Java port of OpenAI's tiktoken). Per-model `EncodingRegistry` lookup; fallback to `cl100k_base` with `Accuracy.FALLBACK` flag for unknown models. Replaces the v0.1.0-pre-freeze stub.
- **Audit pipeline LPOP drain** (BR-SH-015 / BR-MK-005, 2026-04-25, closes FINDING-003) — `audit/AuditFlusher` (`@Component @Scheduled`) drains the Lua-emitted `aria:audit_buffer` Redis list every 5s (configurable via `aria.audit.flush-interval-ms`), persists each event to `audit_events` via `PostgresClient.insertAuditEvent`. Lua side `record_audit_event` unchanged. `persistedTotal` / `failedTotal` counters expose health to Prometheus.
- **Cross-transport engine sharing** — `DiffEngine`, `NerDetectionService` are Spring `@Service` beans injected into both `@RestController` (HTTP, Lua-callable) and `@GrpcService` impls (forward-compat for non-Lua callers). Logic lives in one place; transport is a thin wrapper.

#### Shared Libraries (Lua)
- **`aria-circuit-breaker.lua`** (2026-04-24) — Generic per-endpoint circuit breaker (`ngx.shared.dict`-backed) reusable by all Lua↔sidecar HTTP bridges. First consumer: NER bridge; precedent for any future bridge.

#### Architecture
- **ADR-008** (2026-04-25) — HTTP/JSON over loopback TCP supersedes gRPC/UDS for Lua-callable sidecar endpoints. Rationale: zero `lua-resty-grpc` dependency, operational debuggability with `curl`, latency trade-off accepted at LLM scale. Cross-transport engine-sharing pattern canonical.
- **ADR-009** (2026-04-25) — Sidecar audit pipeline uses LPOP polling (Karar A), not the `POST /v1/audit/event` HTTP bridge that earlier drafts had labelled "preferred". Decision per Levent's "neden iki path?" pushback against the hybrid alternative. ADR-008 not invalidated — orthogonal patterns (sync request/response vs async emit-and-drain).

#### Documentation
- **Spec freeze v1.1** (`a63986f`) — HLD/LLD/API_CONTRACTS/ERROR_CODES/DB_SCHEMA reconciled to shipped reality after the [`PHASE_REVIEW_2026-04-25.md`](docs/06_review/PHASE_REVIEW_2026-04-25.md) adversarial drift report (15 findings).
- **Audit closure v1.1.1** (`249474b`) — HLD/LLD/ERROR_CODES/DB_SCHEMA flipped to closed-state after audit pipeline shipped.
- **Operator-grade docs** (`3dfcb5f`) — QUICK_START (10-min governed-call walkthrough), CONFIGURATION (operator source-of-truth), DEPLOYMENT (3 shapes: docker-compose / single-host / k8s sidecar) + NER_MODELS rewritten end-to-end.
- **GUIDELINES_MANIFEST.yaml** — declares enabled guidelines, locks "no PCI-DSS compliance claim" rule, sets `phase_gates.require_human_signature` so the silent-approval failure mode (2026-04-08 → 2026-04-25 17-day drift episode) cannot recur.
- **HUMAN_SIGN_OFF_v0.1.0.md** — explicit Phase 3/4/6 sign-off pattern established as precedent for all future releases.

#### Error Codes
- **84 ARIA error codes** total (was 31 in 2026-04-08 baseline). New families: `ARIA_MK_NER_*` (3), `ARIA_CN_SHADOW_*` (2), `ARIA_RT_TOKENIZER_FALLBACK`. The v1.1-era `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` was added then retired in v1.1.1 after FINDING-003 closure.

### Changed
- **License framing formalised** (2026-04-21 refinement, locked in HLD §14): Apache 2.0 Lua plugins + community sidecar + persona-gated enterprise tiers (CISO Security · DPO Privacy · CFO FinOps). Persona-gated rather than feature-gated.
- **Compliance framing** (Karar 3, 2026-04-25): all framework references converted to capability statements. PCI-DSS reframed as "scope hygiene" (cardholder-data egress prevention via PAN detection + masking) — Gatekeeper does NOT certify compliance; that requires an audited cardholder-data environment which remains the operator's audit boundary.
- **`tokenize` masking strategy** — emits non-reversible hash in v0.1 (Redis-backed reversible token deferred to v0.2; HLD §9.1 reservation).

### Deprecated
- **`aria-grpc.lua`** — was specified in the v1.0 plan but never implemented; ADR-008 codifies that Lua uses `resty.http` instead. References removed from LLD §1.
- **ariactl CLI** — promised in v1.0 (HLD §3.5, ADR-007); deferred to v0.2. v0.1 substitute = APISIX Admin API + canary `_M.control_api()` endpoints.

### Removed
- **`ARIA_RT_AUDIT_PIPELINE_NOT_WIRED`** error code — added in v1.1 spec freeze as a v0.1 gap marker; retired in v1.1.1 after FINDING-003 closure (Karar A: retire vs repurpose). Operators monitor audit health via `AuditFlusher.persistedTotal` / `failedTotal` Prometheus counters instead.

### Fixed
- **FINDING-003** (audit pipeline) — closed via `aria-runtime@d487026` (`audit/AuditFlusher` Spring `@Scheduled` LPOP drain). BR-SH-015 + BR-MK-005 status flipped PARTIAL → Implemented end-to-end. KVKK Art. 12 retention and durable-audit compliance claims now substantiated by Gatekeeper alone (modulo operator running migrations — see v0.1.1 closure of FINDING-005).
- **API endpoint URL paths** — corrected canary admin endpoints to actual APISIX plugin control-plane convention (`/v1/plugin/aria-canary/{action}/{route_id}`); v1.0 paths were fictional.
- **Test suite** — 121 → 128 Java tests (AuditFlusher closure +7).

### Security
- All v1.0 baseline security checks intact (SAST, no hardcoded secrets, PII pre-masked before audit, append-only PostgreSQL rules).
- **Loopback TCP threat model documented** (ADR-008 §Consequences) — sidecar binds `127.0.0.1` only + Helm chart NetworkPolicy template restricts ingress to APISIX pod. Replaces the v1.0 "UDS file permissions (0660)" mechanism.
- **`AuditFlusher` poison-message containment** — per-event parse/persist failures logged + counted, single bad event does not stall the drain.

### Known Limitations (v0.1)
0 critical (FINDING-003 closed in v1.1.1; FINDING-005 closed in v1.1.1's same-day patch v0.1.1) + 4 minor (ariactl deferred, sidecar PromptAnalyzer + ContentFilter stubs, Karar B token role semantics open, reversible tokenisation deferred) + 3 nice-to-haves deferred (WASM masking, Coverage/SAST re-run, latency-guard simplification). Full enumeration in [`RELEASE_NOTES_v0.1.0_2026-04-25.md`](docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md) §1-§9.

### Architecture Decisions (current registry)
- ADR-001: Auth delegation to APISIX (no own auth)
- ADR-002: Lua + Java hybrid (fast path + heavy processing)
- ADR-003: gRPC over Unix Domain Sockets — **superseded by ADR-008** for Lua transport
- ADR-004: Redis + PostgreSQL dual data store
- ADR-005: Optional WASM (Rust) masking engine — deferred (Lua + Java covers v0.1 envelope)
- ADR-006: No Kafka in v1.0
- ADR-007: Grafana + ariactl instead of Admin UI — CLI portion deferred to v0.2
- **ADR-008** (2026-04-25): HTTP/JSON bridge supersedes gRPC-UDS for Lua-callable sidecar endpoints
- **ADR-009** (2026-04-25): Sidecar audit pipeline uses LPOP polling, not HTTP bridge (closes FINDING-003)

---

## [0.1.0-pre-freeze] — 2026-04-08 (NEVER PUBLICLY RELEASED)

> ⚠️ **This entry is preserved for audit/historical reference only.** A `v0.1.0` git tag was created at this baseline but the project was not publicly released. Spec/code drift was detected by the [`PHASE_REVIEW_2026-04-25.md`](docs/06_review/PHASE_REVIEW_2026-04-25.md) adversarial review (15 findings, 6 critical) and reconciled by the v1.1 spec freeze + v1.1.1 audit closure on 2026-04-25. The `v0.1.0` tag was force-replaced to point at the [honest 2026-04-25 release](#v010--2026-04-25-initial-honest-release) above; the original baseline commit hash `8b6ad7ea6c16f1e7c086639aee7c4999886cce3f` is preserved in the new tag's annotated message.

### Added (2026-04-08 baseline — partial reality, see corrections in v0.1.0 above)

#### Module A: 3e-Aria-Shield (AI Governance)
- **Multi-provider LLM routing** — route requests to OpenAI, Anthropic, Google Gemini, Azure OpenAI, and Ollama with canonical request/response transformation (US-A01, BR-SH-001)
- **Auto-failover with circuit breaker** — Redis-backed circuit breaker (CLOSED/OPEN/HALF_OPEN) with configurable failure threshold and cooldown. Inline failover to fallback providers on 5xx/timeout (US-A02, BR-SH-002)
- **SSE streaming pass-through** — chunk-by-chunk forwarding without response buffering, incremental token counting (US-A03, BR-SH-003)
- **OpenAI SDK compatibility** — applications change only `base_url` to use the gateway. All provider responses transformed to OpenAI format (US-A04, BR-SH-004)
- **Token quota enforcement** — daily/monthly token limits per consumer with Redis pre-flight check. Configurable fail-open/fail-closed on Redis unavailability (US-A05, BR-SH-005)
- **Dollar budget control** — per-model pricing table with automatic cost calculation. Fixed-point decimal precision (US-A06, BR-SH-007)
- **Prometheus metrics** — `aria_tokens_consumed`, `aria_cost_dollars`, `aria_requests_total`, `aria_request_latency_seconds`, `aria_circuit_breaker_state`, `aria_quota_utilization_pct` (US-A07, BR-SH-008)
- **Budget threshold alerts** — webhook/Slack notifications at configurable thresholds (80%, 90%, 100%) with de-duplication via Redis SETNX (US-A08, BR-SH-009)
- **Overage policies** — block (402), throttle (429, 1 req/min), or allow-with-alert when quota exhausted (US-A09, BR-SH-010)
- **Model version pinning** — per-consumer model override via plugin config (US-A17, BR-SH-018)

#### Module B: 3e-Aria-Mask (Dynamic Data Privacy)
- **JSONPath field masking** (US-B01, BR-MK-001)
- **Role-based masking policies** — admin (full), support_agent (mask), external_partner (redact), unknown (failsafe: redact) (US-B02, BR-MK-002)
- **PII auto-detection** — 8 regex patterns with validators: PAN (Luhn), MSISDN, TC Kimlik (mod-11), email, IBAN, IMEI (Luhn), IP, DoB (US-B03, BR-MK-003)
- **12 masking strategies** — last4, first2last2, hash, redact, full, mask:email, mask:phone, mask:national_id, mask:iban, mask:ip, mask:dob, tokenize (US-B04, BR-MK-004)
- **Masking audit logging** (US-B05, BR-MK-005) — *Lua side only at this point; sidecar consumer was not implemented (became FINDING-003, closed in v1.1.1)*

#### Module C: 3e-Aria-Canary (Progressive Delivery)
- **Progressive traffic splitting** with consistent hashing (US-C01, BR-CN-001)
- **Error-rate monitoring** with sliding window counters (US-C02, BR-CN-002)
- **Auto-rollback** with webhook notification (US-C03, BR-CN-003)
- **Manual override** via APISIX plugin control API (US-C05, BR-CN-005)

#### Aria Runtime (Java 21 Sidecar)
- **gRPC/UDS server** — Unix Domain Socket listener with Epoll, Virtual Thread executor (US-S01, BR-RT-001) — *transport later replaced by HTTP/JSON loopback per ADR-008; gRPC retained as forward-compat*
- **ScopedValue context** (US-S02, BR-RT-002)
- **Health checks** — `/healthz` + `/readyz` (US-S03, BR-RT-003)
- **Graceful shutdown** (US-S04, BR-RT-004)
- **Async Redis (Lettuce) + async Postgres (R2DBC)** clients
- **gRPC exception interceptor**
- **Shield/Mask/Canary service stubs** — *PromptAnalyzer + ContentFilter remain stubs in v0.1.0 (deferred to v0.3 enterprise CISO tier per HLD §14); TokenCounter / Mask NER / Canary diff engines became real before the 2026-04-25 release*

#### Database
- **3 PostgreSQL tables** — `audit_events`, `billing_records`, `masking_audit` with monthly partitioning
- **Append-only audit** — PostgreSQL rules prevent UPDATE/DELETE
- **3 Flyway migrations** — *Sidecar Flyway runner not added until v0.1.1 (FINDING-005)*

#### Architecture Decisions (initial registry)
- ADR-001 .. ADR-007 as listed in the v0.1.0 release above (without ADR-008 / ADR-009).

### Notes on this baseline
The 2026-04-08 entry's claims `"31 codes cataloged"`, `"All business rules implemented"`, `"AI Reviewer pending human final review"` (silently treated as approval), and `"~0.1ms IPC via UDS"` were either false at the time of writing or became false within hours. Full reconciliation: see the [v1.1 spec freeze commit `a63986f`](https://github.com/3eAI-Labs/gatekeeper/commit/a63986f) and the [`PHASE_REVIEW_2026-04-25.md`](docs/06_review/PHASE_REVIEW_2026-04-25.md) audit trail.
