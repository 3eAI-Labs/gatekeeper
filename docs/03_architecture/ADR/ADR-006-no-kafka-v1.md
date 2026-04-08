# ADR-006: No Kafka in v1.0

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
The corporate guideline recommends Kafka for inter-service communication. However, Aria's internal communication is Lua plugin → Java sidecar (same pod) and fire-and-forget audit writes.

## Decision
Do not use Kafka in v1.0. All IPC uses gRPC/UDS (synchronous, same-pod). Audit events are written directly to Postgres (async, non-blocking) with Redis buffer for resilience.

## Rationale
- Lua plugin → sidecar communication is intra-pod. Kafka would add ~10ms latency vs ~0.1ms UDS
- Audit events are written by a single producer (Aria) to a single consumer (Postgres). No fan-out needed
- Kafka adds operational complexity (broker cluster, topic management, consumer groups) with no proportional benefit for this use case
- Webhook notifications are fire-and-forget HTTP calls — simpler than Kafka for low-volume alerts

## Consequences
- **Positive:** Simpler deployment (no Kafka dependency)
- **Positive:** Lower latency for all internal communication
- **Negative:** No event replay capability for audit events (Postgres is the source of truth)
- **Negative:** If Aria grows into a distributed system (multiple services), Kafka may be needed
- **Mitigation:** Redis buffer provides resilience for audit writes. Architecture allows adding Kafka later if needed (outbox pattern)

## Alternatives Considered
1. **Kafka for audit events** — rejected (overengineered for single-producer single-consumer writes)
2. **Kafka for plugin-to-sidecar** — rejected (unacceptable latency for real-time quota checks)
3. **NATS for lightweight messaging** — considered for future if fan-out is needed
