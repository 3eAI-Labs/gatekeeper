# Human Sign-Off — v0.1.0 Release

**Signed-Off-By:** Levent Sezgin Genç (PO, 3eAI Labs Ltd)
**Date:** 2026-04-25
**Authorisation:** Per `docs/GUIDELINES_MANIFEST.yaml` `phase_gates.require_human_signature`

## Scope of sign-off

This signature acknowledges that the following artefacts have been reviewed and approved for the `v0.1.0` release tag:

### Phase 3 — Architecture
- `docs/03_architecture/HLD.md` v1.1.1
- `docs/03_architecture/API_CONTRACTS.md` v1.1
- `docs/03_architecture/ADR/ADR-001` … `ADR-009` (all currently registered ADRs)

### Phase 4 — Low-Level Design
- `docs/04_design/LLD.md` v1.1.1
- `docs/04_design/ERROR_CODES.md` v1.1.1 (84 codes)
- `docs/04_design/DB_SCHEMA.md` v1.1.1
- `docs/04_design/SEQUENCE_DIAGRAMS.md` (unchanged from v1.0)

### Phase 6 — Review & Release
- `docs/06_review/CODE_REVIEW_REPORT_2026-04-25.md` v1.1.1 (CONDITIONAL PASS, 1 critical + 4 minor known gaps)
- `docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md` v1.1.1
- `docs/06_review/PHASE_REVIEW_2026-04-25.md` (frozen as input artefact)

## Acknowledged v0.1 Known Limitations

By signing this document I explicitly acknowledge the limitations enumerated in `RELEASE_NOTES_v0.1.0_2026-04-25.md` "Known Limitations" §1–§9, in particular:

- **§1 Audit pipeline (FINDING-003)** — CLOSED in v1.1.1 (`aria-runtime@d487026` + ADR-009)
- **§2 DB migrations not auto-bootstrapped (FINDING-005)** — open; v0.2 fix planned (Flyway in sidecar)
- **§3 ariactl CLI deferred (FINDING-001)** — open; v0.1 substitute is APISIX Admin API + canary `_M.control_api()`
- **§4 PromptAnalyzer + ContentFilter stubs** — v0.3 enterprise CISO scope
- **§5 Karar B (token role semantics) open** — v0.2 ADR-009 → renumber if needed
- **§6 Reversible tokenisation** — v0.2
- **§7 WASM masking engine** — deferred (Lua + Java covers v0.1 envelope)
- **§8 Coverage / SAST re-run** — v0.2 CI gate
- **§9 Latency guard simplification** — v0.2 if customer signals tail-latency drift

## Decision authority for v0.1.0 release

The `v0.1.0` git tag may be created against the commit that includes this sign-off document. The release is community-tier scope; enterprise tiers remain out of v0.1.

---

*This file exists because `GUIDELINES_MANIFEST.yaml phase_gates.require_human_signature` makes silent acceptance of Phase 6 artefacts a process violation. The 2026-04-08 → 2026-04-25 silent-drift episode is the anti-pattern this gate exists to prevent. Subsequent releases (v0.1.x, v0.2.0, …) require analogous sign-off documents.*
