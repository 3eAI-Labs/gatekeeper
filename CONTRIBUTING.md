# Contributing to 3e-Aria-Gatekeeper

Thanks for considering a contribution. This project ships an open-core APISIX governance suite (Lua plugins + Java sidecar); the bar is **production-grade quality from day one**, because operators run this in front of paid LLM traffic.

This document covers what we accept, what we don't, and how to make a PR that gets merged with minimal back-and-forth.

---

## TL;DR

1. **Open an issue first** for any change beyond ~20 lines or that touches public schemas, ARIA error codes, or business rules. We'll align on scope before you write code.
2. **Keep the spec coherent.** Any feature that adds or changes a public-facing behaviour MUST update the relevant HLD / LLD / ERROR_CODES / DB_SCHEMA section in the same PR (or open a tracked drift item for the next freeze). The 17-day silent-drift episode of 2026-04-08 → 2026-04-25 is documented in [`docs/06_review/PHASE_REVIEW_2026-04-25.md`](docs/06_review/PHASE_REVIEW_2026-04-25.md) as the anti-pattern this rule exists to prevent.
3. **Test what you ship.** Unit tests for new logic; honest deferral notes (with a v0.x fix item) for anything you knowingly leave incomplete.
4. **Sign off your own work.** Write the commit message as if you'll be reviewed by a human who will ask "did you actually run this end-to-end?". If the answer is no, say so in the PR body.

---

## What we accept

| Type | Bar | Notes |
|---|---|---|
| **Bug fixes** | Reproducer test + fix | Match the existing test style (busted for Lua, JUnit + Mockito for Java) |
| **New Lua plugin features** | Schema + plugin code + integration test + USER_GUIDE update | Public schemas are versioned; breaking schema changes need an ADR |
| **New sidecar features** | Java code + JUnit test + LLD §5.x update + (if Lua-callable) HTTP bridge per [ADR-008](docs/03_architecture/ADR/ADR-008-http-bridge-over-grpc.md) pattern | Cross-transport engine sharing canonical (`@Service` shared by `@RestController` + `@GrpcService`) |
| **New PII pattern** | Regex + checksum validator (where applicable) + unit test + entry in `aria-pii.lua` | Don't add patterns without a checksum if one exists for the format (PAN/Luhn, TC Kimlik/mod-11, IMEI/Luhn) |
| **New mask strategy** | Implementation in `aria-mask-strategies.lua` + unit test + entry in DECISION_MATRIX | We're at 12 strategies — add only if the existing 12 cannot be composed |
| **New ARIA error code** | Entry in [`docs/04_design/ERROR_CODES.md`](docs/04_design/ERROR_CODES.md) with HTTP/gRPC mapping, severity, retry strategy, business rule + user story traceability | Format: `ARIA_{MODULE}_{ERROR_NAME}`. Don't add without a real emit site in code. |
| **New ADR** | Use the structure of [ADR-008](docs/03_architecture/ADR/ADR-008-http-bridge-over-grpc.md) or [ADR-009](docs/03_architecture/ADR/ADR-009-audit-flusher-lpop-polling.md): Context · Decision · Rationale · Consequences · Alternatives Considered · Related | One ADR per non-trivial architectural choice; don't pile multiple decisions into one |
| **Doc refresh** | If it's operator-facing (QUICK_START / USER_GUIDE / CONFIGURATION / DEPLOYMENT / NER_MODELS), match the voice: honest "gap" sections, explicit prerequisites, troubleshooting by failure mode | The 2026-04-25 operator-grade refresh sets the bar; new docs should match it |

## What we don't accept (or will push back on)

- **Speculative features** — "we might want X someday" is not a reason to ship X today. Open an issue, link a customer signal, then we discuss.
- **Comment cruft** — no `// removed for X reason`, no `// TODO: refactor this someday`, no multi-paragraph docstrings explaining what the code already says. The code is the spec for *what*; comments are for non-obvious *why*.
- **Compatibility shims for the v0.1 → v0.2 boundary** — both releases are pre-launch, no production consumers; if a refactor is right, do it cleanly.
- **Silent error handling** — no swallowed exceptions, no `catch (Exception e) { return null; }`. Errors flow through `AriaException` (Java) or structured Lua error tables; mapping happens at boundaries (`GrpcExceptionInterceptor` / `@RestControllerAdvice` / Lua `_M.body_filter` error handler). See [silent-failure-hunter agent precedent](https://github.com/anthropics/claude-code-plugins).
- **Mocked integration tests** — if the test claims to validate a Postgres / Redis / sidecar interaction, it must hit a real instance (Testcontainers welcome). Mock unit tests are fine for pure logic.
- **PRs that don't touch tests** — for any change beyond a typo fix, you need either new tests or a written explanation of why the existing tests cover it.
- **Direct commits to `main`** — always go through a PR, even for one-line fixes. Maintainer included.

## How to make a PR that merges fast

1. **Open an issue first** (required for >20 lines or public-schema changes).
2. **Branch from `main`** with a descriptive name (`feat/aria-shield-vector-injection`, `fix/canary-rollback-edge-case`, `docs/lld-section-5-3-2`).
3. **Commit hygiene:**
   - Conventional Commits format: `feat(shield): ...`, `fix(mask): ...`, `docs(spec): ...`, `chore(build): ...`, `test(canary): ...`, `refactor(runtime): ...`
   - Subject line ≤ 70 chars; body wraps at ~80 chars
   - Body explains *why* (not *what* — the diff shows that)
   - Co-author tags welcome (e.g. AI pair-programmers, multiple humans)
4. **PR body must include:**
   - **Summary** — 1-3 bullets on what this changes
   - **Test plan** — markdown checklist of how you verified (unit tests passed / integration tested with `X` / manually verified UI flow / etc.)
   - **Spec impact** — list of HLD/LLD/ERROR_CODES/DB_SCHEMA sections updated, OR explicit "no spec impact" with one-line reason
   - **Migration notes** — if operators need to do anything, say so explicitly
5. **CI must pass.** SAST + Lua busted + Java JUnit + Trivy. If CI fails on something unrelated to your PR, ping the maintainer rather than disabling the check.
6. **Wait for review.** We aim for first response within 3 business days. PRs with the spec-coherence requirements above land same-day; PRs missing them get a "please add LLD §X update" comment.

## Development setup

```bash
# Lua plugin development
git clone git@github.com:3eAI-Labs/gatekeeper.git
cd gatekeeper
docker compose -f runtime/docker-compose.yaml up -d  # APISIX + Redis + Postgres + sidecar

# Run Lua tests (busted on OpenResty container)
docker compose exec apisix sh -c 'cd /tests/lua && busted'

# Sidecar development (separate repo)
git clone git@github.com:3eAI-Labs/aria-runtime.git
cd aria-runtime
./gradlew test          # JUnit + Mockito unit tests (no real DB needed)
./gradlew bootRun       # Boots sidecar against the docker-compose Redis + Postgres
```

Operator-grade configuration reference: [`runtime/docs/CONFIGURATION.md`](runtime/docs/CONFIGURATION.md). Deployment shapes (docker-compose / single-host / k8s sidecar): [`runtime/docs/DEPLOYMENT.md`](runtime/docs/DEPLOYMENT.md).

## Code style

- **Lua:** Follow the existing `aria-*.lua` style — module-pattern files (`local _M = {}` … `return _M`), explicit `local` for everything, no globals, structured logging via `aria_core.log`.
- **Java:** Spring Boot 3.x conventions, constructor injection (no field injection), virtual threads enabled, `ScopedValue` for request context (no `ThreadLocal`), `AriaException` with structured error codes (no string-error pattern matching).
- **Comments:** Default to writing none. Add one only when the *why* is non-obvious (a hidden constraint, a subtle invariant, a workaround for a specific bug, behaviour that would surprise a reader). Don't reference the current task / commit / fix — that belongs in the PR description and rots as the codebase evolves.
- **Naming:** snake_case in Lua, camelCase in Java, kebab-case for shell + config keys, SCREAMING_SNAKE_CASE for env vars.

## Repository governance

- **Maintainer:** Levent Sezgin Genç (3eAI Labs Ltd) — `levent.genc@3eai-labs.com`
- **Decision authority:** Architectural decisions (ADRs) require maintainer sign-off. Day-to-day PRs land on a single approving review (maintainer or trusted contributor).
- **Release process:** every release tag (`v0.1.x`, `v0.2.0`, …) requires a `HUMAN_SIGN_OFF_v<version>.md` document committed before the tag is created. Pattern established in [v0.1.0 sign-off](docs/06_review/HUMAN_SIGN_OFF_v0.1.0.md). This is enforced by [`docs/GUIDELINES_MANIFEST.yaml`](docs/GUIDELINES_MANIFEST.yaml) `phase_gates.require_human_signature`.
- **License contributions:** by submitting a PR, you agree your contribution is licensed under Apache 2.0 (community-tier) and that 3eAI Labs may include it in commercial enterprise tiers under a dual-licence arrangement consistent with the open-core model in [HLD §14](docs/03_architecture/HLD.md).

## Code of Conduct

We follow the [Contributor Covenant v2.1](CODE_OF_CONDUCT.md). Be kind, be honest, be specific. Disagreement on technical decisions is welcome; ad-hominem is not.

## Security disclosures

Do **not** open public issues for security vulnerabilities. See [SECURITY.md](SECURITY.md) for the disclosure process.

---

Thanks for reading. Now go fix something.
