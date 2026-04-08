# ADR-003: gRPC over Unix Domain Sockets for IPC

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
Lua plugins need to communicate with the Java sidecar. Options: HTTP, gRPC over TCP, gRPC over UDS.

## Decision
Use gRPC over Unix Domain Sockets (UDS) for Lua-to-sidecar communication.

## Rationale
- UDS latency: ~0.1ms round-trip (vs ~1ms for TCP, ~2ms for HTTP)
- No TCP overhead (no connection handshake, no port management)
- File-system permissions provide access control (0660 — only APISIX and sidecar)
- gRPC provides typed contracts (protobuf), streaming, and deadline propagation
- UDS is local-only — zero network attack surface

## Consequences
- **Positive:** Minimal IPC latency (~0.1ms)
- **Positive:** No network exposure — sidecar is not reachable from outside the pod
- **Positive:** Typed protobuf contracts prevent serialization errors
- **Negative:** Both containers must share a volume for the UDS socket file
- **Negative:** Lua gRPC client library required (lua-resty-grpc or custom FFI binding)
- **Mitigation:** Shared volume in Kubernetes pod spec. Evaluate lua-resty-grpc maturity

## Alternatives Considered
1. **HTTP REST** — rejected (higher latency ~2ms, no typed contracts)
2. **gRPC over TCP (localhost)** — rejected (unnecessary TCP overhead for same-pod communication)
3. **Shared memory** — rejected (complex, error-prone, no typed contracts)
