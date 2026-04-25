# ADR-008: HTTP/JSON Bridge Supersedes gRPC-UDS for Lua-Callable Sidecar Endpoints

**Status:** Accepted (supersedes ADR-003 for Lua↔sidecar transport)
**Date:** 2026-04-25
**Decision Makers:** PO (Levent Sezgin Genç) + AI Architect

## Context

ADR-003 (2026-04-08) chose **gRPC over Unix Domain Sockets** as the canonical transport for Lua plugins ↔ Java sidecar communication. The decision required a Lua gRPC client (`lua-resty-grpc` or a custom FFI binding) which was never written.

Three iteration rounds shipped Lua↔sidecar features after Phase 5 approval, **all using HTTP/JSON instead of gRPC**:

- **2026-04-22/23 — Shadow diff (BR-CN-007):** `aria-canary.lua` calls `POST http://127.0.0.1:8081/v1/diff` via `resty.http`. Java side: `DiffController` (`@RestController`) wraps `DiffEngine` (Spring `@Service`).
- **2026-04-24 — Mask NER bridge (BR-MK-006):** `aria-mask.lua` calls `POST http://127.0.0.1:8081/v1/mask/detect`. Java side: `MaskController` wraps `NerDetectionService`.
- *(Implicit precedent)*: `aria-circuit-breaker.lua` shared library was added on 2026-04-24 specifically to wrap these HTTP bridges.

As of 2026-04-25:
- **No Lua gRPC client exists.** `aria-grpc.lua` (referenced in LLD §1) was never written; greppable as zero hits.
- **Every Lua↔sidecar call is HTTP/JSON** to `127.0.0.1:8081` endpoints.
- **Java gRPC services exist but have no Lua callers** — `MaskServiceImpl`, `CanaryServiceImpl`, `ShieldServiceImpl` (gRPC) remain in the codebase as ceremonial.
- The cross-transport engine-sharing pattern (`DiffEngine` shared by `DiffController` + `CanaryServiceImpl`; `NerDetectionService` shared by `MaskController` + `MaskServiceImpl`) is now **structural** — same Spring `@Service` injected into both transports, both delegating to identical domain logic.

This drift was caught by the Phase 6 adversarial review (`docs/06_review/PHASE_REVIEW_2026-04-25.md`, FINDING-002 + FINDING-006). This ADR formally records the architectural decision to align the spec with shipped reality.

## Decision

1. **All Lua-callable sidecar endpoints expose HTTP/JSON over loopback TCP (`127.0.0.1:8081`).** This includes existing endpoints (`/v1/diff`, `/v1/mask/detect`, `/healthz`, `/readyz`) and any future Lua-callable RPCs (e.g., audit, prompt analysis).

2. **The cross-transport engine-sharing pattern is canonical:** a Spring `@Service` encodes the domain logic once (e.g., `DiffEngine`, `NerDetectionService`); both an `@RestController` (HTTP) and a `@GrpcService` implementation (gRPC) inject the service and delegate to it. Logic lives in one place, transport is a thin wrapper.

3. **gRPC services remain in the codebase** as a v1.x evolution path for non-Lua callers (other sidecars, admin tools, internal microservices). They are **not** on the Lua hot path. Decision to retain or prune them is deferred to v0.3 review.

4. **ADR-003 is superseded for the Lua↔sidecar transport.** UDS is no longer the canonical Lua IPC. The "UDS — no network exposure" claim in HLD §5.1 trust model is replaced by "loopback TCP + APISIX-only network policy" (see Consequences below).

## Rationale

- **Zero Lua gRPC dependency.** `lua-resty-grpc` is not a maintained package; the alternative was a custom FFI binding requiring protobuf parsing + gRPC framing + HTTP/2 in Lua. Estimated 2–4 weeks of work plus ongoing maintenance. HTTP/JSON via `resty.http` (already transitively present in APISIX) eliminates this entirely.
- **Operational simplicity.** HTTP/JSON is debuggable with `curl` + `jq`. gRPC requires `grpcurl`, knowing the proto file, and decoding binary frames. For an open-core project where operators self-host, the lower troubleshooting bar is product-defining.
- **Cross-language clarity.** Lua's strength is text/JSON; binary protobuf serialization in Lua is awkward. HTTP/JSON keeps each language in its idiomatic zone (Lua does string-y work, Java does typed work, transport is a flat translation).
- **Performance trade-off accepted.** UDS gRPC round-trip: ~0.1ms. Loopback TCP HTTP/JSON: ~1–2ms. The 10–20× latency increase is amortized over the LLM upstream call (50ms–5s) which dominates the request budget. Not material at AI traffic scale.

## Consequences

**Positive**
- Zero Lua-side native binding code; everything stays in `resty.http`.
- Sidecar endpoints are introspectable via standard tools (`curl`, `httpie`, browser dev tools).
- Cross-transport engine-sharing pattern keeps gRPC available for future non-Lua callers without forcing the hot path through it.
- New sidecar bridges (e.g., audit pipeline per FINDING-003, future prompt analyzer) follow a known precedent — `aria-circuit-breaker.lua` library already encodes the failure semantics.

**Negative**
- **Sidecar exposes a TCP listener.** HLD §5.1 previously claimed UDS — no network exposure. Loopback TCP is bound to `127.0.0.1`, but any pod-mate process can reach it. Mitigations below.
- **Latency increase ~1–2ms per sidecar call.** Not material in current designs (canary diff is async, NER detection is sub-LLM-budget). Could matter if multiple sidecar calls stack up per request — flag at design time.
- **gRPC infrastructure is "future-only"** in v0.1. Question of whether to delete remains open; revisit at v0.3.
- **Documentation drift across multiple specs.** HLD §1.2/§2.3/§4.2/§5.1, LLD §1/§5.2, INTEGRATION_MAP §2, QUICK_START.md, runtime/docs/DEPLOYMENT.md all currently claim UDS/gRPC. The v1.1 spec freeze sweep must update each.

**Mitigations**
- **Loopback bind:** sidecar configured with `server.address: 127.0.0.1` (Spring Boot property). External binds explicitly rejected at config-load time.
- **NetworkPolicy template** in Helm chart restricting ingress to APISIX pod only. (Already present for the gRPC port — extend to HTTP port.)
- **Threat model update** in HLD §5.1 v1.1: explicitly enumerate "loopback-listener within shared pod" as a residual risk and document the network-policy mitigation.
- **Loopback authentication is intentionally absent**: the trust boundary is the pod itself; APISIX-only ingress + non-routable bind suffices for v0.1. If the trust model evolves (e.g., multi-tenant pod), revisit — current scope does not require auth.

## Alternatives Considered

1. **Implement Lua gRPC client (revert to ADR-003).** Rejected — 2–4 weeks of effort + ongoing maintenance, no operational benefit, no measurable latency win at LLM scale.
2. **HTTP/1.1 over UDS instead of TCP.** Considered (APISIX's `resty.http` does support UDS sockets via `unix:` URIs). Rejected because: (a) operational debugging tools weaker (UDS not curl-friendly), (b) marginal security benefit over loopback bind + NetworkPolicy, (c) requires shared-volume orchestration in Helm chart which proved fragile in earlier attempts.
3. **WebSocket bridge.** Overkill for synchronous request-response semantics; rejected.
4. **gRPC-Web over loopback TCP.** Adds proxy complexity (Envoy-shaped translation), no clear benefit; rejected.

## Supersedes

**ADR-003 (2026-04-08)** — *Lua↔sidecar transport portion only*. ADR-003's UDS gRPC design intent remains valid for *non-Lua* gRPC clients (future admin tools, other sidecars, observability collectors). The specific decision *"Lua gRPC client library required (lua-resty-grpc or custom FFI binding)"* is invalidated by this ADR.

## Related

- `docs/06_review/PHASE_REVIEW_2026-04-25.md` — FINDING-002 (transport contradiction), FINDING-006 (HTTP-bridge precedent undocumented)
- `BR-CN-007` (canary structural shadow diff) — first instance of the HTTP bridge pattern
- `BR-MK-006` (mask NER bridge) — second instance, established the pattern as canonical
- `apisix/plugins/lib/aria-circuit-breaker.lua` — failure-handling library shared by all HTTP bridges
- `LLD v1.1 §5.2.1` (to be written) — implementation pattern for the cross-transport engine-sharing
