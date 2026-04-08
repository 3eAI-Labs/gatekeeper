# ADR-001: Authentication Delegation to APISIX

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
The corporate guideline mandates Keycloak + platform auth libraries. However, Aria is an APISIX plugin suite — it runs inside APISIX, which already has authentication plugins (key-auth, jwt-auth, openid-connect backed by Keycloak).

## Decision
Aria delegates all authentication to APISIX's native auth plugins. It trusts the consumer identity provided by APISIX's request context (`ctx.var.consumer_name`, consumer metadata).

## Rationale
- Aria runs inside APISIX — it would be circular to call back to APISIX for auth
- APISIX already supports Keycloak via the `openid-connect` plugin
- Consumer metadata (role, quota config) is natively available in the plugin context
- Adding a separate auth layer would add latency and complexity with zero benefit

## Consequences
- **Positive:** Zero auth overhead for Aria plugins. Leverages existing APISIX auth ecosystem
- **Positive:** Consumer role for masking (DM-MK-001) comes from APISIX metadata — no additional lookup
- **Negative:** Aria cannot enforce auth independently. If APISIX auth is misconfigured, Aria has no safety net
- **Mitigation:** Documentation clearly states APISIX auth must be configured before Aria plugins in the plugin chain

## Alternatives Considered
1. **Aria implements its own JWT validation** — rejected (redundant, adds ~5ms)
2. **Aria calls Keycloak directly** — rejected (circular dependency, network call from inside gateway)
