# ADR-004: Redis + PostgreSQL Dual Data Store

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
Aria needs both real-time state (quota checks at < 2ms) and durable audit trail (7-year retention, ACID compliance queries).

## Decision
Use Redis for real-time state and PostgreSQL for audit/billing persistence.

## Rationale
- **Redis:** Sub-millisecond reads for pre-flight quota checks. TTL-based expiry for transient state (circuit breaker, latency windows). Atomic INCRBY for quota counters
- **PostgreSQL:** ACID guarantees for audit trail. Partitioned tables for efficient 7-year retention. Complex compliance queries (by consumer, date range, event type)
- Separating concerns: Redis failure affects real-time enforcement (configurable fail-open/closed). Postgres failure affects audit persistence (buffered in Redis)

## Consequences
- **Positive:** Quota checks at < 2ms (Redis). Compliance-ready audit trail (Postgres)
- **Positive:** Independent failure modes — neither brings down the request pipeline
- **Negative:** Two data stores to operate and monitor
- **Negative:** Eventual consistency between Redis counts and Postgres billing records
- **Mitigation:** Reconciliation job (BR-SH-006) corrects drift. `is_reconciled` flag tracks accuracy

## Alternatives Considered
1. **Redis only** — rejected (no ACID, TTL-based data inappropriate for 7-year audit)
2. **PostgreSQL only** — rejected (too slow for pre-flight quota checks at < 2ms)
3. **SQLite embedded** — rejected (not suitable for distributed APISIX cluster)
