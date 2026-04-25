# ADR-009: Sidecar Audit Pipeline Uses LPOP Polling, Not HTTP Bridge

**Status:** Accepted (closes FINDING-003 from `PHASE_REVIEW_2026-04-25`)
**Date:** 2026-04-25
**Decision Makers:** PO (Levent Sezgin Genç) + AI Architect
**Implementing Commit:** `aria-runtime@d487026` (`AuditFlusher` class + tests)

## Context

`PHASE_REVIEW_2026-04-25` FINDING-003 surfaced a v0.1 critical gap: `aria-core.lua record_audit_event` correctly pushed JSON onto the Redis list `aria:audit_buffer` (1h TTL), but the sidecar had **zero callers** of `PostgresClient.insertAuditEvent`. Audit events accumulated in Redis and silently TTL'd out without ever landing in the `audit_events` table. Two `Must`-priority business rules (BR-SH-015 Shield audit, BR-MK-005 Mask audit) were therefore PARTIAL-not-Implemented, and any compliance-supportive durable-audit claim (KVKK Art. 12 retention etc.) was unsubstantiated.

Two design paths were on the table for closing the gap:

- **Karar A — LPOP polling.** Add a Spring `@Scheduled @Component` (`AuditFlusher`) that runs a non-blocking LPOP loop on `aria:audit_buffer` every N ms (default 5s, configurable), drains up to a bounded batch per tick (100), and persists each event via `PostgresClient.insertAuditEvent`. **Lua side unchanged.**
- **Karar B — HTTP bridge.** Add a `POST /v1/audit/event` HTTP endpoint to the sidecar (per ADR-008 pattern). Modify `aria-core.lua record_audit_event` to call this endpoint instead of (or in addition to) the Redis push.

The pre-AuditFlusher `RELEASE_NOTES_v0.1.0_2026-04-25.md` Known Limitation §1 had labelled Karar B as "preferred". An initial design proposal further considered a **hybrid** (Lua double-write: HTTP bridge for fast path + Redis push for catch-up; sidecar consumes both). Levent rejected the hybrid with the question *"neden iki path?"* — establishing single-path simplicity as a hard requirement. The remaining choice was between Karar A and Karar B alone.

This ADR documents why **Karar A was chosen over Karar B**, and supersedes the "preferred: HTTP bridge" claim that appeared in earlier Phase 6 artefacts.

## Decision

1. **The sidecar consumes the Lua audit buffer via Spring `@Scheduled` LPOP polling.** `AuditFlusher.flush()` runs at `aria.audit.flush-interval-ms` (default 5000ms), drains up to `MAX_PER_TICK` (100) events per tick, persists each via `PostgresClient.insertAuditEvent`. Fixed-delay scheduling guarantees only one tick runs at a time.

2. **The Lua audit-emit path is unchanged.** `aria-core.lua record_audit_event` continues to push to `aria:audit_buffer`. No new HTTP call on the request critical path.

3. **No `POST /v1/audit/event` HTTP endpoint.** The audit pipeline does not adopt the ADR-008 bridge pattern. ADR-008 governs **synchronous Lua→sidecar request/response**; the audit pipeline is **asynchronous Lua emit → Redis buffer → sidecar drain**. The two patterns coexist without conflict; ADR-008 is not invalidated.

4. **Failure handling: poison-message containment.** Per-event parse or persist failures increment `failedTotal`, log at ERROR with the event payload, and drop the event. v0.3 candidate: dead-letter queue for failed events.

5. **Operational observability:** `persistedTotal` and `failedTotal` exposed as in-process counters; sidecar metrics endpoint surfaces them. Operators alert on non-zero `failedTotal` rate.

6. **The error code `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` (formerly registered as a v0.1-gap marker) is RETIRED** — see `ERROR_CODES.md v1.1.1` change-log. Code count 85 → 84. Future audit-flusher failure-mode error codes (e.g., `ARIA_RT_AUDIT_FLUSHER_DEGRADED`) will be added on demand if operator feedback requires distinct codes beyond the metric-based signal.

## Rationale

**Why LPOP polling beats HTTP bridge for this specific data flow:**

- **Async-by-design semantics.** Audit events are *fire-and-forget from the request's perspective* — the request must not block on durable persistence. The Redis buffer is already the natural decoupling point. Adding an HTTP hop in front of it would be a synchronous detour around the asynchronous design.
- **Single failure domain.** With LPOP polling, failure of the sidecar (process crash, restart, deploy) does not lose events — they sit in Redis with the configured TTL until the next tick consumes them. With HTTP bridge fire-and-forget, sidecar unavailability during the call drops the event. With HTTP bridge synchronous, sidecar latency stalls the request critical path. Neither HTTP variant offers what LPOP polling gives natively.
- **Lua side already correct.** `record_audit_event` was implemented and tested before FINDING-003 surfaced. Karar B would require a Lua change (and a corresponding circuit breaker + retry + fail-open policy in `aria-circuit-breaker.lua`) for zero functional gain.
- **Levent's "neden iki path?" pushback** specifically rejected hybrid designs that wrote to *both* HTTP and Redis, but the underlying principle generalises: any path that adds a *second* way of moving the same event is complexity that earns no additional safety. Karar A keeps the path-count at one (Redis is the source of truth between Lua emit and Postgres persist); Karar B would either replace the Redis path (losing the buffer's natural retention) or duplicate it (the rejected hybrid).
- **Operational simplicity.** Operators debug audit issues by `redis-cli LRANGE aria:audit_buffer 0 -1` to see what's queued and `SELECT * FROM audit_events ORDER BY occurred_at DESC LIMIT 100` to see what's persisted. With LPOP polling those two queries fully describe the system. With HTTP bridge they would need to also inspect HTTP error logs and bridge state.
- **Backpressure already bounded.** Lua side already enforces 1h TTL on the Redis list. Sidecar tick batch size (100) bounds the per-tick work. Aggregate throughput (~20 events/sec sustained at default settings) covers the v0.1 sidecar's expected audit volume by orders of magnitude.

**Why ADR-008 (HTTP bridge) is not violated:**

ADR-008 governs Lua-callable sidecar endpoints — i.e., synchronous request/response where the Lua plugin needs an answer to proceed. Examples already in production: `POST /v1/diff` (canary needs the structural diff), `POST /v1/mask/detect` (mask needs NER spans). The audit pipeline is fundamentally different: the Lua plugin emits an event and proceeds immediately; no answer is needed. The two ADRs cover orthogonal data flows, not competing approaches to the same flow.

## Consequences

**Positive**

- v0.1 critical FINDING-003 closed. BR-SH-015 + BR-MK-005 status flips PARTIAL → Implemented. Compliance-supportive durable audit claims (KVKK Art. 12 retention, PCI-DSS-equivalent access logs) are now substantiated *modulo* the operator running the migration (FINDING-005 still open).
- Lua-side codebase footprint unchanged; no new circuit breaker tuning, no new failure modes on the request critical path.
- Sidecar-side closure is small: one new `@Component` class (~130 lines) + one test class (~7 new tests). No new transport, no new endpoint, no new dependency.
- Sidecar restart safety: events queued during downtime are drained on next startup tick (within Redis TTL window).

**Negative**

- **Polling latency.** Worst-case visibility lag is one flush interval (default 5s). For human-readable audit timelines this is acceptable; for sub-second forensic queries it would not be. Operators with stricter SLAs can lower `aria.audit.flush-interval-ms` (down to ~250ms before scheduler overhead matters).
- **Loss window during sidecar downtime > Redis TTL (1h).** If the sidecar is down for more than 1h, events older than the TTL are gone. v0.3 candidate mitigations: (a) raise the buffer TTL to 24h, (b) sidecar startup readiness check that fails if Redis buffer length > a threshold (alert, don't drop), (c) `BLPOP` with longer timeout to reduce idle wakeups.
- **Silent drops on per-event persist failure.** `failedTotal` counter + ERROR log are the only signal; no dead-letter queue in v0.1. v0.3 candidate: dead-letter list in Redis (`aria:audit_dead_letter`) with operator-driven replay tooling.
- **No back-pressure on the producer.** Lua side will keep pushing even if the sidecar is consuming slowly. Bounded only by the 1h TTL and by Redis memory limits.

**Mitigations / Compensating Signals**

- `failedTotal` and `persistedTotal` counters exposed for Prometheus alerting.
- Operators alert on `failedTotal` rate change > 0/min sustained.
- Operators alert on `audit_buffer` Redis list length > N (e.g., 10000) sustained — indicates sidecar consumer not keeping up.
- Sidecar startup logs the first successful tick (or first failure) so deploy automation can verify the consumer started.

## Alternatives Considered

1. **Karar B — `POST /v1/audit/event` HTTP bridge per ADR-008 pattern.** Rejected per Rationale above. Was the "preferred" v0.2 fix in `RELEASE_NOTES_v0.1.0_2026-04-25.md` Known Limitation §1 (now retracted by this ADR + the v1.1.1 spec freeze).
2. **Hybrid — Lua double-write (HTTP for fast path + Redis push for catch-up).** Rejected by Levent's *"neden iki path?"* on first proposal. Two write paths means two failure modes, two audit pipelines to reason about, and zero added durability over the chosen single-path design.
3. **`BLPOP` blocking consumer instead of polling.** Considered. `BLPOP` would slightly reduce idle wakeups but couples the Spring scheduler thread to a blocking call (poor fit for `@Scheduled`); the natural alternative is a dedicated worker thread, which adds threading complexity for marginal benefit. Rejected for v0.1.
4. **Kafka topic instead of Redis list.** Rejected per **ADR-006 (no Kafka in v1)**. Audit volume does not justify a second message broker; Redis is already in the stack.
5. **Database-direct from Lua (`PG_BOUNCER` + `lua-resty-postgres`).** Rejected — couples Lua to schema, bypasses sidecar's R2DBC connection pool, no async persistence semantics.

## Related

- `docs/06_review/PHASE_REVIEW_2026-04-25.md` — FINDING-003 (audit pipeline NOT WIRED — origin of this work)
- `docs/03_architecture/ADR/ADR-008-http-bridge-over-grpc.md` — synchronous Lua→sidecar transport (orthogonal pattern; not invalidated by ADR-009)
- `docs/03_architecture/ADR/ADR-006-no-kafka-v1.md` — rules out Kafka as the audit channel
- `docs/04_design/LLD.md §6` — sequence and traceability for the audit pipeline (updated to reflect closure)
- `docs/04_design/ERROR_CODES.md` — `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` retired in v1.1.1
- `aria-runtime/src/main/java/com/eai/aria/runtime/audit/AuditFlusher.java` — implementation
- `aria-runtime/src/test/java/com/eai/aria/runtime/audit/AuditFlusherTest.java` — test coverage (7 new tests, suite 121 → 128)
- `BR-SH-015`, `BR-MK-005` — business rules whose status this ADR flips PARTIAL → Implemented
