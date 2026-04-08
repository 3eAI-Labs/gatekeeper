# ADR-007: Grafana + ariactl CLI Instead of Admin UI

**Status:** Accepted
**Date:** 2026-04-08
**Decision Makers:** AI Architect + PO

## Context
Corporate guideline requires every backend service to have an Admin UI (React/Refine). However, Aria is an APISIX plugin suite with three operational concerns: configuration, visibility, and management.

## Decision
v1.0 uses:
- **Configuration:** APISIX Admin API + Dashboard (native APISIX tooling)
- **Visibility:** Pre-built Grafana dashboards (Shield cost, Mask compliance, Canary deployment)
- **Management:** `ariactl` CLI for quota/policy/canary operations

A custom React/Refine Admin UI is deferred to post-v1.0 (Could-Have).

## Rationale
- APISIX users already have APISIX Dashboard for plugin configuration — a separate portal would fragment the experience
- Grafana is already deployed for monitoring — adding Aria dashboards is zero-cost
- CLI tools (`ariactl`) are the natural interface for SRE/DevOps users (primary Aria audience)
- Building a React/Refine portal is significant effort with low v1.0 ROI

## Consequences
- **Positive:** Zero frontend development effort for v1.0
- **Positive:** Leverages existing Grafana and APISIX Dashboard infrastructure
- **Positive:** CLI is scriptable and CI/CD-friendly
- **Negative:** No custom web UI for non-technical users
- **Negative:** Non-compliance with corporate Admin UI guideline (approved exception for open-source plugin project)
- **Mitigation:** Admin UI can be added post-v1.0 if adoption demands it

## Alternatives Considered
1. **Full React/Refine Admin UI** — deferred (high effort, low v1.0 ROI)
2. **APISIX Dashboard plugin** — considered for v1.1 (extend APISIX Dashboard with Aria panels)
