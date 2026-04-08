# ADR-002: Lua + Java Hybrid Architecture

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
APISIX plugins must be written in Lua (runs in Nginx event loop). However, heavy processing (NLP/NER, exact token counting, vector similarity) is impractical in Lua due to limited library ecosystem and single-threaded model.

## Decision
Use a two-tier architecture:
- **Lua (APISIX native):** Fast path — request/response transformation, regex scanning, quota checks, traffic routing. Target: < 5ms overhead.
- **Java 21 sidecar:** Heavy path — tiktoken counting, NER PII detection, prompt vector analysis, shadow diff. Target: async, off critical path.

## Rationale
- Lua runs in the Nginx event loop — zero overhead, no context switching
- Java 21 Virtual Threads handle thousands of concurrent operations without the complexity of reactive programming
- `ScopedValue` (not `ThreadLocal`) provides safe per-request context with virtual threads
- `ReentrantLock` (not `synchronized`) avoids virtual thread pinning to carrier threads
- Sidecar pattern allows independent scaling and deployment

## Consequences
- **Positive:** < 5ms Lua overhead on critical path. Java handles heavy lifting asynchronously
- **Positive:** Graceful degradation — if sidecar is down, Lua-only mode works (reduced accuracy)
- **Negative:** Two languages to maintain (Lua + Java)
- **Negative:** Sidecar adds a container to each APISIX pod (~256MB memory)
- **Mitigation:** Clear module boundaries. Java code organized by module (shield/, mask/, canary/)

## Alternatives Considered
1. **Pure Lua** — rejected (no tiktoken, NER, or vector similarity libraries in Lua)
2. **Pure Java (external proxy)** — rejected (adds network hop, not an APISIX plugin)
3. **Go sidecar** — rejected (Java has better NLP/ML ecosystem, virtual threads are competitive with goroutines)
4. **Python sidecar** — rejected (higher latency, GIL limitations for concurrent requests)
