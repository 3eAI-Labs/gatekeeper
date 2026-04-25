# Human Sign-Off — v0.1.1 Patch Release

**Signed-Off-By:** Levent Sezgin Genç (PO, 3eAI Labs Ltd)
**Date:** 2026-04-25
**Authorisation:** Per `docs/GUIDELINES_MANIFEST.yaml` `phase_gates.require_human_signature`
**Predecessor:** [`HUMAN_SIGN_OFF_v0.1.0.md`](HUMAN_SIGN_OFF_v0.1.0.md)

## Scope of sign-off

This signature acknowledges that the **single change** between v0.1.0 and v0.1.1 has been reviewed and approved for the `v0.1.1` patch tag:

### Phase 4 — Low-Level Design (delta from v0.1.0 sign-off)
- `docs/04_design/DB_SCHEMA.md` v1.1.1 → **v1.1.2** — §1.2 sidecar-Flyway row flipped ❌ → ✅; v0.2 fix item §1 retired; migration source-of-truth note added.

### Phase 6 — Review & Release (delta)
- `docs/06_review/CODE_REVIEW_REPORT_2026-04-25.md` v1.1.1 → **v1.1.2** — §0 verdict (1 critical → 0 critical); §10 §2 (FINDING-005) flipped to ✅ CLOSED; verdict gap count "0 critical + 4 minor".
- `docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md` — added "v0.1.1 Patch" subsection at top; Known Limitation §2 (FINDING-005) rewritten as ✅ CLOSED.

### `aria-runtime` repo (companion change)
- `aria-runtime@9bd22d5` — `feat(db): bootstrap Flyway in sidecar (closes FINDING-005)`. Adds `flyway-core` + `flyway-database-postgresql` + `postgresql` JDBC; configures `spring.flyway.*` against existing `aria.postgres.*`; vendors V001..V003 SQL into sidecar classpath. Tests 128/128 pass.

## Acknowledged remaining v0.1 limitations (all minor)

By signing this document I explicitly acknowledge the limitations enumerated in `RELEASE_NOTES_v0.1.0_2026-04-25.md` "Known Limitations" §3–§9, in particular:

- **§1 Audit pipeline (FINDING-003)** — CLOSED in v1.1.1 (`aria-runtime@d487026` + ADR-009)
- **§2 DB migrations (FINDING-005)** — **CLOSED in v1.1.2** (`aria-runtime@9bd22d5`); this sign-off acknowledges the closure
- **§3 ariactl CLI deferred (FINDING-001)** — open; v0.1 substitute is APISIX Admin API + canary `_M.control_api()`
- **§4 PromptAnalyzer + ContentFilter stubs** — v0.3 enterprise CISO scope
- **§5 Karar B (token role semantics) open** — v0.2
- **§6 Reversible tokenisation** — v0.2
- **§7 WASM masking engine** — deferred (Lua + Java covers v0.1 envelope)
- **§8 Coverage / SAST re-run** — v0.2 CI gate
- **§9 Latency guard simplification** — v0.2 if customer signals tail-latency drift

## Decision authority for v0.1.1 release

The `v0.1.1` git tag may be created against the commit that includes this sign-off document. **All v0.1 critical gaps are now closed; this is an unconditional PASS for the community tier.** Enterprise tiers remain out of v0.1 scope.

---

*This file exists because `GUIDELINES_MANIFEST.yaml phase_gates.require_human_signature` makes silent acceptance of Phase 6 artefacts a process violation. Subsequent releases (v0.1.2, v0.2.0, …) require analogous sign-off documents.*
