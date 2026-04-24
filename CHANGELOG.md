# Changelog — 3e-Aria-Gatekeeper

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### Module B: 3e-Aria-Mask
- **NER-based PII detection** — Mask plugin now delegates named-entity detection (PERSON / LOCATION / ORGANIZATION / MISC) to the `aria-runtime` sidecar over an HTTP bridge (POST `/v1/mask/detect`). Regex-only detection remains the default; enable `ner.sidecar.enabled=true` to activate. Runs inline in `body_filter` after regex so the ML model never sees fields already classified as structural PII (BR-MK-006).
  - New schema block: `ner.sidecar.{enabled, endpoint, timeout_ms, max_content_bytes, fail_mode, min_confidence, circuit_breaker.{failure_threshold, cooldown_ms}, entity_strategy}`.
  - **Turkish-first positioning:** ships with pluggable engines — Apache OpenNLP for English + DJL/ONNX Runtime for Turkish BERT (default model: `savasy/bert-base-turkish-ner-cased`). Add new languages by implementing the Java `NerEngine` interface and listing the id in `aria.mask.ner.engines`.
  - **Fail modes:** `open` (default, availability-first — regex-only result if sidecar unreachable) or `closed` (defensive — all candidate fields redacted when NER cannot verify).
  - **Circuit breaker:** per-endpoint breaker in Lua (`ngx.shared.dict` state) short-circuits before HTTP call when the sidecar is unhealthy. Paired with a Resilience4j breaker inside the JVM for defense in depth.
  - New Lua lib: `apisix/plugins/lib/aria-circuit-breaker.lua` — generic, reusable by future sidecar bridges.
  - New metrics: `aria_mask_ner_calls_total{route,result}`, `aria_mask_ner_latency_ms` (histogram), `aria_mask_ner_entities_total{type}`, `aria_mask_ner_circuit_state{endpoint}` (gauge).
  - Unit tests: 32 new Lua tests covering circuit breaker state machine, content collection, offset-to-field mapping, sidecar success + every failure mode, and breaker interaction.

#### Module C: 3e-Aria-Canary
- **Traffic shadowing — basic diff (Iter 1)** — Fire-and-forget duplication of a configurable percentage of live traffic to a shadow upstream, with Lua-side basic diff (HTTP status, body length, latency delta) and Prometheus metrics. Sidecar-based structural diff lands in Iter 2 (US-C06, US-C07, BR-CN-006).
  - New schema block: `shadow.{enabled, traffic_pct, shadow_upstream.nodes, timeout_ms, failure_threshold, disable_window_seconds}`.
  - Auto-disable after configurable consecutive failures (default 3) with sliding-window counter; auto-recover after `disable_window_seconds` (default 300s).
  - Shadow requests carry `X-Aria-Shadow: true` header; the plugin refuses to shadow a request that already has the flag, preventing recursion.
  - New metrics: `aria_shadow_requests_total`, `aria_shadow_diff_count{type=status|body_length}`, `aria_shadow_latency_delta_ms` (histogram), `aria_shadow_upstream_failures`, `aria_shadow_upstream_down`.
  - Unit tests: `tests/lua/test_canary_shadow.lua` (schema validation, sampling, weighted node selection, basic diff, failure threshold, log-phase scheduling).

## [0.1.0] - 2026-04-08

### Added

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
- **JSONPath field masking** — mask specific response fields by JSONPath expression in APISIX `body_filter` phase (US-B01, BR-MK-001)
- **Role-based masking policies** — admin (full), support_agent (mask), external_partner (redact), unknown (failsafe: redact) (US-B02, BR-MK-002)
- **PII auto-detection** — 8 regex patterns with validators: PAN (Luhn), MSISDN, TC Kimlik (mod-11), email, IBAN, IMEI (Luhn), IP, DoB (US-B03, BR-MK-003)
- **12 masking strategies** — last4, first2last2, hash, redact, full, mask:email, mask:phone, mask:national_id, mask:iban, mask:ip, mask:dob, tokenize (US-B04, BR-MK-004)
- **Masking audit logging** — metadata-only audit events (field path, strategy, rule ID — never original values) (US-B05, BR-MK-005)

#### Module C: 3e-Aria-Canary (Progressive Delivery)
- **Progressive traffic splitting** — configurable multi-stage schedule (e.g., 5%→10%→25%→50%→100%) with consistent hashing for stable client experience (US-C01, BR-CN-001)
- **Error-rate monitoring** — continuous canary vs. baseline comparison with sliding window counters. Configurable delta threshold (default: 2%) (US-C02, BR-CN-002)
- **Auto-rollback** — traffic to 0% when error threshold is sustained for configurable duration. Webhook notification on rollback (US-C03, BR-CN-003)
- **Manual override** — Admin API extensions for promote/rollback/pause/resume via APISIX plugin control API (US-C05, BR-CN-005)
- **Configurable retry policy** — manual (default: permanently stopped after rollback) or auto (retry from stage 1 after cooldown) (BR-CN-001 state machine)

#### Aria Runtime (Java 21 Sidecar)
- **gRPC/UDS server** — Unix Domain Socket listener with Epoll, Virtual Thread executor for per-request concurrency (US-S01, BR-RT-001)
- **ScopedValue context** — per-request CONSUMER_ID, ROUTE_ID, REQUEST_ID via Java 21 ScopedValue (US-S02, BR-RT-002)
- **Health checks** — `/healthz` (liveness) and `/readyz` (readiness: Redis + Postgres ping, shutdown-aware) (US-S03, BR-RT-003)
- **Graceful shutdown** — SIGTERM → readiness=503 → drain gRPC → close connections → remove UDS socket (US-S04, BR-RT-004)
- **Async Redis client** — Lettuce with non-blocking operations (US-S01)
- **Async Postgres client** — R2DBC connection pool for audit/billing writes (US-S01)
- **gRPC exception interceptor** — AriaException → gRPC Status mapping, prevents stack trace leakage (BR-RT-001)
- **Shield/Mask/Canary service stubs** — handler framework ready for v0.3 deep processing (tiktoken, NER, diff engine)

#### Database
- **3 PostgreSQL tables** — `audit_events`, `billing_records`, `masking_audit` with monthly partitioning
- **Append-only audit** — PostgreSQL rules prevent UPDATE/DELETE on audit_events and masking_audit
- **CHECK constraints** — non-negative tokens and cost in billing_records
- **Partition maintenance** — auto-create future partitions, auto-drop after 7 years
- **3 Flyway migrations** — V001 (schema + enums), V002 (tables + indexes), V003 (partitions + maintenance function)

#### Shared Libraries
- **aria-core.lua** — Redis pooling, Prometheus metrics (cardinality-guarded), structured logging, audit event buffering
- **aria-provider.lua** — 5 LLM provider transformers with request/response/SSE/error mapping
- **aria-pii.lua** — 8 PII regex patterns with Luhn and TC Kimlik checksum validators
- **aria-quota.lua** — quota/budget enforcement, pricing table, overage policies, alert webhooks
- **aria-mask-strategies.lua** — 12 masking strategy implementations

### Security
- SAST scan: 7/7 passed (no dangerous Lua patterns)
- SQL safety: append-only rules verified, CHECK constraints verified
- No hardcoded secrets in codebase
- Provider API keys never in error responses or logs
- PII masked before audit storage
- Non-root Docker container with Alpine base

### Architecture Decisions
- ADR-001: Auth delegation to APISIX (no own auth)
- ADR-002: Lua + Java hybrid (fast path + heavy processing)
- ADR-003: gRPC over Unix Domain Sockets (~0.1ms IPC)
- ADR-004: Redis + PostgreSQL dual data store
- ADR-005: Optional WASM (Rust) masking engine
- ADR-006: No Kafka in v1.0
- ADR-007: Grafana + ariactl CLI instead of Admin UI
