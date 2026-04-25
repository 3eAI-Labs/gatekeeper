# 3e-Aria-Gatekeeper — Technical Datasheet

**Release:** v0.1.1 (2026-04-25)
**License:** Apache 2.0 (community tier)
**Source:** [github.com/3eAI-Labs/gatekeeper](https://github.com/3eAI-Labs/gatekeeper)

This datasheet describes what is in the v0.1.1 community release in enough technical detail that an engineer can decide whether the product fits a specific deployment. It assumes familiarity with Apache APISIX and a typical Java/JVM stack; it is not an introduction to either.

## What you are deploying

Gatekeeper has two halves that ship together but install separately.

The first half is a set of three Lua plugins that run inside Apache APISIX. They are loaded the same way any other APISIX plugin is loaded — registered in `config.yaml`, attached to routes through the Admin API or YAML standalone mode. They run inside the OpenResty workers that already serve traffic; they do not require a new process, a new port, or a separate container. The three plugins are `aria-shield` (AI governance — quotas, routing, prompt security), `aria-mask` (data masking — regex and NER PII detection, role-based policies, twelve mask strategies), and `aria-canary` (progressive delivery — staged rollout, error-rate monitoring, traffic shadowing with structural diff).

The second half is `aria-runtime`, a small Java 21 sidecar that handles the work the Lua plugins delegate. It runs as a co-located container in the same Pod (or, in non-Kubernetes deployments, on the same host), and exposes its capabilities to the plugins over a loopback HTTP bridge bound to `127.0.0.1:8081`. The sidecar is responsible for real OpenAI-compatible token counting, NER inference for multilingual PII detection, structural diff computation for canary shadow comparison, schema migrations against PostgreSQL, and the background drain of the audit-event buffer.

This split exists for a specific reason: Lua is excellent at the per-request hot path and OpenResty is excellent at HTTP request orchestration, but neither is a comfortable home for ML inference, accurate tokenisation against an OpenAI-compatible BPE encoding, or async R2DBC persistence. Java's strengths fill exactly those gaps. By keeping the request critical path in Lua and pushing the heavy work to a co-located sidecar, the gateway stays fast and the heavy work stays maintainable.

## Module A: `aria-shield` — AI governance

The shield plugin is the one that turns "we use OpenAI" into something an SRE can sleep through. It speaks the OpenAI request and response format end-to-end, which means existing applications need only change their `base_url` to start using it. Beneath that surface, it does several things at once.

It enforces token quotas and dollar budgets per consumer, with the consumer identity coming from APISIX's existing authentication plugins (key-auth, JWT, OAuth2-introspection, anything that ends up in `ctx.consumer`). The quota check is a Redis pre-flight pipeline call — typically under two milliseconds — and the failure mode (fail-open if Redis is unavailable, or fail-closed) is a per-route configuration. When a quota is approaching exhaustion, the plugin emits webhook or Slack notifications at configurable thresholds (the defaults are 80%, 90%, 100%); duplicate notifications are suppressed with a Redis SETNX guard so an alert storm cannot happen.

It routes to multiple upstream LLM providers — OpenAI, Anthropic, Google Gemini, Azure OpenAI, and Ollama for self-hosted models — and applies per-provider request and response transformations so the application sees a single OpenAI-shaped surface no matter which provider actually served the request. A Redis-backed circuit breaker tracks per-provider health (CLOSED / OPEN / HALF_OPEN), opens after a configurable consecutive-failure threshold, and probes the primary periodically during the cooldown.

It does prompt-side security work — eight regex patterns for known PII shapes, with proper checksum validation for the formats that have one (PAN by Luhn, Turkish national ID by mod-11, IBAN by ISO-7064, IMEI by Luhn). For prompt-injection detection it runs a community-tier regex scan for known patterns; vector-similarity injection scoring is part of the v0.3 enterprise CISO tier and is not in v0.1 — the sidecar's `analyzePrompt` gRPC method exists as a forward-compat stub and returns `is_injection=false` until the enterprise tier is enabled.

It does token accounting two ways. The Lua side computes a fast approximate count in the `body_filter` phase and updates the Redis quota immediately — write-then-correct, so the next request sees the cost without waiting for the exact reconciliation. The sidecar's `TokenEncoder` (jtokkit, the Apache 2.0 Java port of OpenAI's tiktoken) computes the exact count with model-specific encoding when the response body is available; for models the registry does not recognise it falls back to `cl100k_base` and tags the result `Accuracy.FALLBACK` so downstream billing pipelines can apply provider-specific correction.

It records audit events to a Redis buffer (`aria:audit_buffer`, 1-hour TTL), with PII pre-masked Lua-side so personal data never reaches the sidecar's persistence path. The sidecar drains the buffer on a 5-second scheduled tick (`aria.audit.flush-interval-ms`, configurable), persists each event into the PostgreSQL `audit_events` table, and exposes `persistedTotal` and `failedTotal` counters for Prometheus alerting.

## Module B: `aria-mask` — dynamic data privacy

The mask plugin runs in the response path and is the one that earns its keep when somebody on the team puts a customer's national ID into a prompt and the model echoes it back, or when a tool call returns a JSON object full of fields the application did not anticipate exposing.

It works in two passes. The first pass applies JSONPath-driven field masking — operators write rules that say "this field for this consumer role gets this strategy". Roles are resolved from APISIX consumer metadata; the four built-in roles (`admin`, `support_agent`, `external_partner`, and the failsafe-redact `unknown`) cover most needs and custom roles are straightforward to add. Twelve mask strategies are shipped: `last4` (keep the last four characters), `first2last2`, `hash` (irreversible), `redact` (replace with a placeholder), `full` (drop the field entirely), and per-format formatters for email, phone, national ID, IBAN, IP, date-of-birth, plus a `tokenize` strategy. The `tokenize` strategy in v0.1 emits a non-reversible hash; the original specification (HLD §9.1) reserves the `aria:tokenize:{id}` Redis key namespace for the v0.2 reversible AES-256-encrypted store, but that work is not yet done — operators who need reversible tokens should use the existing `last4` or `redact` strategies.

The second pass is the PII auto-detector. The Lua side runs the eight built-in regex patterns first — running ML against fields that already match a structural pattern would be wasteful and would produce noisier results than the structural classifier. For everything else, when NER bridge is enabled, the plugin makes an HTTP call to the sidecar's `POST /v1/mask/detect` endpoint and merges the returned spans with the regex hits.

The NER pipeline inside the sidecar is pluggable. Two engines ship: `OpenNlpNerEngine` for English (PERSON / LOCATION / ORGANIZATION / MISC), and `DjlHuggingFaceNerEngine` for everything else. The default multilingual model is `savasy/bert-base-turkish-ner-cased`, loaded as ONNX via the Deep Java Library and ONNX Runtime; replacing it is a configuration change, not a code change. The `NerEngine` Java interface is small and stable — adding Arabic, Persian, or any other language is a matter of writing a new engine class and listing its identifier in `aria.mask.ner.engines`. Engine code is community-tier (Apache 2.0); the model artefacts themselves are operator-supplied for the slim image, or bundled in the enterprise DPO tier.

Because NER inference can fail in operationally interesting ways — the sidecar might be unreachable, the model might be slow, the JVM might hit a GC pause — the plugin protects itself with a two-layer circuit breaker. The outer layer lives in Lua (`aria-circuit-breaker.lua`, backed by `ngx.shared.dict` for cross-worker state) and short-circuits the HTTP call entirely when the bridge is unhealthy; the inner layer is a Resilience4j breaker inside the JVM that protects the engine from sustained downstream failures. The fail-mode is a per-route policy: `open` (default, availability-first — return regex-only results) or `closed` (defensive — redact all candidate fields when NER cannot verify them).

The plugin emits structured masking-audit events through the same audit pipeline as Shield — what was masked, for whom, on which request, which rule triggered. The events never contain the original values; they contain field paths, strategy names, and rule identifiers.

## Module C: `aria-canary` — progressive delivery

The canary plugin is the one that lets a team push a new model version, a new prompt template, or a new upstream provider into production without waking up at 3 a.m. when something goes sideways.

It supports multi-stage progressive splitting — the typical schedule is 5% → 10% → 25% → 50% → 100% with hold durations per stage, but the schedule itself is configuration. Routing to canary versus baseline is consistent-hashed on a stable client identifier (default: `client_ip`, configurable to a header or consumer ID); the same client keeps hitting the same upstream throughout the experiment, which keeps user experience smooth and makes per-cohort metrics meaningful.

The plugin continuously compares the canary's error rate against the baseline using sliding-window counters in Redis. The default delta threshold is two percentage points; when the canary sustains an error rate more than two points above the baseline for the configured duration, the plugin auto-rolls-back — traffic to the canary drops to zero, a webhook fires, and the canary state goes into `ROLLED_BACK`. Operators can override manually through the `_M.control_api()` endpoints exposed via the APISIX plugin control plane: `status`, `promote`, `rollback`, `pause`, `resume`. (A dedicated `ariactl` CLI was originally planned and is deferred to v0.2; in v0.1, operators script against these endpoints directly with `curl`, which is what the working installations are doing today.)

Traffic shadowing is the canary feature that ships hardest data. With shadowing enabled, the plugin fire-and-forgets a configurable percentage of live traffic to a shadow upstream alongside the primary; the primary response is what the client sees, and the shadow response is captured in the log phase for analysis. The Lua side computes a basic diff immediately — HTTP status, body length, latency delta — and increments Prometheus counters for each. The structural body diff is the deeper analysis: the plugin sends both responses (or just the parts that differ in a coarse pre-check) to the sidecar's `POST /v1/diff` endpoint, which runs a `DiffEngine` written specifically for the comparison and returns a structured `DiffResult` with status, header, and body-structure deltas. Operators read those deltas to decide whether the candidate is ready before any live user touches it.

The shadow path has two safety properties baked in. Recursion guard: shadow requests carry an `X-Aria-Shadow: true` header, and the plugin refuses to shadow a request that already has the flag — there is no shadow-of-shadow loop even if v1 and v2 both happen to route through the same Canary instance. Auto-disable: after a configurable number of consecutive shadow-upstream failures (default three), shadowing disables itself for a cooldown window (default 300 seconds) so a broken candidate cannot continuously consume gateway resources.

## The sidecar

`aria-runtime` is a Spring Boot 3.4 application on the Java 21 toolchain. It runs as a co-located container in the same Pod (or, in single-host deployments, as a sibling process), with three responsibilities: serve the HTTP bridges that Lua plugins call synchronously, run a small set of background jobs, and bootstrap and maintain the database schema.

The HTTP bridges are `POST /v1/diff` (used by the canary shadow-diff path) and `POST /v1/mask/detect` (used by the mask NER path), plus `/healthz`, `/readyz`, and the standard Spring Actuator endpoints (`/actuator/info`, `/actuator/metrics`, `/actuator/prometheus`). All of these bind exclusively to `127.0.0.1:8081`; the sidecar refuses to bind externally. The Helm chart ships a NetworkPolicy template that further restricts ingress to the same Pod, as defence-in-depth on top of the loopback bind.

The gRPC services exist as forward-compat for non-Lua callers — `MaskServiceImpl`, `CanaryServiceImpl`, `ShieldServiceImpl` — but they are not on the v0.1 hot path; the cross-transport engine-sharing pattern (a Spring `@Service` injected into both the `@RestController` and the `@GrpcService` impl) means the underlying domain logic is the same regardless of how it is called. ADR-008 in the architecture decision register documents the rationale for HTTP being the canonical Lua transport.

The background work is small but important. `AuditFlusher` is a `@Scheduled` `@Component` that drains the `aria:audit_buffer` Redis list every five seconds (configurable via `aria.audit.flush-interval-ms`), persists each event via the R2DBC `PostgresClient`, and exposes counters for Prometheus. The implementation uses LPOP polling rather than an HTTP bridge — ADR-009 documents the choice between Karar A (polling) and Karar B (HTTP bridge per ADR-008 pattern) and the rationale for picking the simpler single-path design.

The database persistence layer uses R2DBC for runtime queries (`PostgresClient.insertAuditEvent`, `insertBillingRecord`) so the request-handling path stays non-blocking. Schema migrations use Flyway through the synchronous JDBC driver — Flyway has no R2DBC equivalent in the ecosystem — but Flyway runs once at startup and closes its connection, so no JDBC pool persists at runtime. The migrations themselves (`V001__create_schema_and_enums.sql`, `V002__create_billing_and_masking_tables.sql`, `V003__create_partitions_and_maintenance.sql`) live in `src/main/resources/db/migration/`; `baseline-on-migrate=true` is configured so the sidecar can be deployed against an already-migrated database without manual baselining.

## Storage

PostgreSQL holds the durable audit and billing tables. `audit_events` is partitioned monthly with seven-year retention; PostgreSQL `DO INSTEAD NOTHING` rules on `UPDATE` and `DELETE` enforce immutability after insert, so the table is tamper-proof from inside the database itself. `billing_records` carries `CHECK` constraints for non-negative tokens and cost. `masking_audit` is the matching table for the mask plugin's audit events. Partition maintenance is automatic — future partitions are created in advance, and partitions older than the retention window are dropped.

Redis carries the real-time state: per-consumer quota counters, circuit-breaker state, canary stage configuration, the audit buffer that the sidecar drains, and the `ngx.shared.dict`-backed circuit-breaker state for the Lua-side bridges. Redis Cluster is recommended for production; a single Redis instance is fine for development and small deployments. TLS is supported.

## Deployment topologies

Three shapes are documented in detail in [`runtime/docs/DEPLOYMENT.md`](../../../runtime/docs/DEPLOYMENT.md). The docker-compose topology is the development default — APISIX, the sidecar, Redis, PostgreSQL, and Prometheus + Grafana all in one compose file — and the QUICK_START walks operators through it in roughly ten minutes. The single-host topology runs APISIX and the sidecar as systemd services on the same host with a connected Redis and PostgreSQL elsewhere; this is what small operators tend to start with. The Kubernetes sidecar topology runs APISIX and the sidecar as containers in the same Pod, with the Helm chart shipping the Deployment, Service, NetworkPolicy, ConfigMap, Secret references, optional Flyway migration Job, PrometheusRule, and the three bundled Grafana dashboards.

## Observability

Both halves emit Prometheus metrics on the standard `/metrics` endpoint. The Lua plugins emit per-request counters with cardinality guards on label values that could otherwise explode (consumer IDs, route IDs); the sidecar emits Spring-Actuator-flavour metrics including `AuditFlusher.persistedTotal` and `failedTotal` for the audit pipeline. Three Grafana dashboards ship in `dashboards/` — one per plugin module — and the Helm chart auto-discovers them via the standard sidecar-injection annotations. A PrometheusRule template is included with starter alerts (`aria_canary_rollback_fired`, `aria_quota_breach_threshold`, `aria_audit_failed_drain_rate`) that operators tune to their own environment.

Structured logging is JSON throughout. The Lua side emits via `aria_core.log` (which writes through OpenResty's standard `ngx.log` with a JSON formatter); the sidecar uses a Logback layout that matches the same JSON shape. Trace IDs (`aria_request_id`) propagate through both halves so a single request can be reconstructed end-to-end from the log stream.

## Compliance posture

This is a capability statement, not a certification claim. The product provides controls that operators use to support their own compliance audits; the product does not certify compliance with any framework, and no claim in this document or any other should be read as a certification. The framework references below describe what the product *does* in support of operator audits in those regulatory contexts.

For **GDPR (EU)**, the product supports data minimisation by masking personal data at the gateway edge before it reaches third-party LLM providers, and supports purpose limitation through role-based masking policies that distinguish administrators from external partners. For **KVKK (Turkey)**, the product extends GDPR-equivalent capabilities with TC Kimlik regex with mod-11 checksum validation and the default Turkish-BERT NER model. For **PDPL (Saudi Arabia / Iraq)**, the product supports data-localisation-aware masking and geographic-policy enforcement through consumer metadata. For **PCI-DSS (scope hygiene)**, the product detects PAN-shaped strings in prompts using Luhn-validated regex and applies mask or block strategies to prevent cardholder data from egressing to upstream LLM providers — the product does **not** claim PCI-DSS compliance, which would require an audited cardholder-data environment that remains the operator's audit boundary.

## What ships and what does not in v0.1.1

What ships, in addition to everything above: 84 ARIA error codes with HTTP/gRPC mapping and traceability to business rules, nine architecture decision records documenting every non-trivial design choice, a Helm chart with NetworkPolicy and PrometheusRule templates, three Grafana dashboards, and a 128-test JUnit suite for the sidecar.

What does not ship in v0.1.1, by name: the `ariactl` Go CLI promised in the original architecture plan (deferred to v0.2 — the v0.1 substitute is the APISIX Admin API plus the canary `_M.control_api()` endpoints, which is what production users do today); the sidecar `PromptAnalyzer` and `ContentFilter` deep implementations (deferred to v0.3 enterprise CISO tier — the Lua-side regex prompt-injection scan covers community needs); reversible tokenisation backed by AES-256 (deferred to v0.2); the Karar B token role-overhead semantics (open as a v0.2 ADR); coverage and SAST re-runs against the post-NER head (deferred to a v0.2 CI gate); the WASM masking engine (ADR-005, deferred indefinitely — Lua plus Java covers the v0.1 performance envelope).

Both v0.1 critical gaps that the 2026-04-25 adversarial spec review surfaced have been closed: the audit pipeline (FINDING-003) was wired in `aria-runtime@d487026` and recorded in ADR-009; the Flyway bootstrap (FINDING-005) was added in `aria-runtime@9bd22d5`. The community tier is genuinely production-ready for the operator who is willing to read the release notes and accept the four documented minor gaps.

## Where to read more

Operator quick start: [`docs/05_user/QUICK_START.md`](../../05_user/QUICK_START.md) — ten-minute walkthrough.
Configuration reference: [`runtime/docs/CONFIGURATION.md`](../../../runtime/docs/CONFIGURATION.md) — operator source-of-truth.
Deployment topologies: [`runtime/docs/DEPLOYMENT.md`](../../../runtime/docs/DEPLOYMENT.md) — three shapes in detail.
Architecture: [`docs/03_architecture/HLD.md`](../../03_architecture/HLD.md), [`docs/04_design/LLD.md`](../../04_design/LLD.md), [ADR registry](../../03_architecture/ADR/).
Long-form: [`WHITE_PAPER.md`](WHITE_PAPER.md) explains the design philosophy.

---

*3eAI Labs Ltd · Document version 1.0 · 2026-04-25 · Apache 2.0 community tier*
