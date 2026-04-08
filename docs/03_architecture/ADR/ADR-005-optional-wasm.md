# ADR-005: Optional WASM (Rust) Masking Engine

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
Lua regex masking works well for simple patterns (< 100KB response, ≤ 20 rules). For larger responses or complex pattern sets, Lua performance degrades.

## Decision
Implement an optional WASM masking engine in Rust that APISIX loads as a WASM plugin. Selection is automatic based on response size and rule count (DM-MK-003).

## Rationale
- WASM runs in the APISIX process — no IPC overhead
- Rust provides memory-safe, high-performance regex (< 3ms for 1MB response)
- APISIX >= 3.8 has native WASM plugin support
- Optional: if WASM is not loaded, Lua handles all masking (graceful fallback)

## Consequences
- **Positive:** 3x-5x masking performance for large/complex responses
- **Positive:** Optional — no deployment complexity if not needed
- **Negative:** Rust expertise required for WASM module development
- **Negative:** APISIX >= 3.8 required
- **Mitigation:** Lua is always the fallback. WASM is a Could-Have feature (v0.3 Mask)

## Alternatives Considered
1. **Lua only** — viable for v1.0, may not scale for high-throughput masking
2. **Java sidecar masking** — rejected (adds IPC latency for every response, defeats purpose)
3. **C module for OpenResty** — rejected (unsafe, harder to maintain than WASM/Rust)
