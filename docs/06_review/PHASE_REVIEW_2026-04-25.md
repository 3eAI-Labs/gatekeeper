# Phase 6 Adversarial Drift Review — 2026-04-25

**Phase under review:** 6 (re-review after 17 days of un-synced iteration)
**Review date:** 2026-04-25
**Reviewer:** Sentinel adversarial fresh-context (Opus, 1M)
**Repos audited:**
- `gatekeeper` @ `3dfcb5f` (`main`)
- `aria-runtime` @ `723ae23` (`main`)
**Previous Phase 6 artifacts:** `docs/06_review/CODE_REVIEW_REPORT.md` and `RELEASE_NOTES.md`, both dated **2026-04-08 07:46**, marked *"pending human final review"*, scope says *"Phase 5 (32 source files)"* — **stale by 17 days**.
**Sentinel manifest present:** **No** — there is no `MANIFEST.md` / `GUIDELINES_MANIFEST.yaml` in this repo. Default workspace guidelines (`/home/lsg/Workspaces/guidelines/*`) used. Logged as FINDING-000.

---

## Verdict

**HAS-BLOCKERS — DO NOT advance.** Phase 1–5 specifications and the Phase 6 Code Review Report describe a system materially different from the one in `main`: artifacts that do not exist (`ariactl`, Flyway migrations, `aria-grpc.lua`, `PromptAnalyzer`, `ContentFilter`), a transport that is not used (gRPC/UDS — every Lua↔sidecar call is HTTP over TCP), and a broken audit pipeline (`insertAuditEvent` has zero callers; the Lua side buffers events to a Redis list nothing consumes). At the same time, real shipped behaviour (HTTP bridge precedent, `aria-circuit-breaker.lua` shared lib, `BR-MK-006` NER bridge, `BR-CN-007` structural diff, license-tier reframing, Karar A `cl100k_base` fallback, Gradle 9 / jtokkit deps) is invisible to every Phase 1–4 document. Until HLD and LLD are reconciled to v1.1 and the Phase 6 report is replaced, the v0.1.0 release notes describe a release that **does not exist**.

The core of the report is a `Drift Catalogue` section. **15 findings**: 6 critical, 7 major, 2 minor. The orchestrator's pre-supplied findings were largely correct; 1 of them (`BR-CN-005` Admin endpoints) was **wrong** — they are implemented in `aria-canary.lua control_api()` and were missed by the orchestrator's grep. I extended the list with 9 additional drifts.

---

## Repository State Snapshot

### What the spec says shipped (per CODE_REVIEW_REPORT v1.0, 2026-04-08)
- 32 source files, 8 test files, "all business rules implemented", `ariactl` CLI, gRPC/UDS transport, Java sidecar with `PromptAnalyzer`, `TokenCounter`, `ContentFilter`, `NerDetector`, `DiffEngine`.
- Verdict: **APPROVE for merge. Pending human final review.**
- Human approval was **never recorded.** 17 days of iteration followed.

### What actually exists today
**Lua plugins** (`apisix/plugins/`):
- `aria-shield.lua`, `aria-mask.lua`, `aria-canary.lua`
- `lib/`: `aria-core.lua` (386 lines), `aria-mask-strategies.lua`, `aria-pii.lua`, `aria-provider.lua`, `aria-quota.lua` (526 lines), `aria-circuit-breaker.lua` (NEW 2026-04-24, undocumented in LLD)
- **Missing vs. LLD §1:** `aria-grpc.lua` (LLD line 24) — does not exist. Greppable as zero hits.

**Java sidecar source** (`/home/lsg/Workspaces/3eai-labs/aria-runtime/src/main/java/com/eai/aria/runtime/`):
- `core/`: `GrpcServer`, `GrpcExceptionInterceptor`, `HealthController`, `ShutdownManager`, `RequestContext` (AriaRuntimeApplication.java is in root)
- `shield/`: `ShieldServiceImpl` (combines stubbed PromptAnalyzer + real TokenCounter + stubbed ContentFilter into ONE class), `TokenEncoder` (REAL since 2026-04-22, uses jtokkit, Karar A `cl100k_base` fallback)
- `mask/`: `MaskController` (HTTP, Apr 23), `MaskServiceImpl` (gRPC stub), `mask/ner/`: 8 classes (NerEngine, OpenNlpNerEngine, DjlHuggingFaceNerEngine, CompositeNerEngine, NerEngineRegistry, NerProperties, NerDetectionService, PiiEntity) — all NEW 2026-04-23/24, not in LLD
- `canary/`: `CanaryServiceImpl` (gRPC), `DiffController` (HTTP, Apr 23), `DiffEngine` (REAL since 2026-04-22)
- `common/`: `AriaException`, `AriaRedisClient` (Lettuce), `PostgresClient` (R2DBC) — `insertAuditEvent` exists, **0 callers** (verified: `grep -rn insertAuditEvent` returns 1 line: the definition only)
- `config/`: `AriaConfig`
- **Missing vs. LLD §1 / §5.1:** `PromptAnalyzer.java`, `TokenCounter.java`, `ContentFilter.java`, `NerDetector.java` (separate classes never created), `RedisClient.java` (renamed `AriaRedisClient`)

**Proto contracts** (`src/main/proto/`):
- `shield.proto`, `mask.proto`, `canary.proto`, `health.proto`
- **No `audit` RPC** anywhere — confirmed via `grep -i audit` against all proto files: zero hits

**ariactl CLI:** **Does not exist anywhere.** No `ariactl/` directory, no Go module, no commands. HLD §3.5 lists 7 commands; 0 are implemented.

**DB migrations:** **Do not exist.** `find aria-runtime -name "V*.sql"` returns nothing. Only `application.yml` is in `src/main/resources/`. DB_SCHEMA.md ships full DDL but it has never been turned into Flyway migrations.

**ariactl + audit-flusher + Flyway = three "infrastructure" pieces that exist only on paper.**

### Iteration timeline since Phase 5/5.5 approval (2026-04-08)

| Date | Event | Repo @ commit | Spec sync? |
|---|---|---|---|
| 2026-04-08 | Phase 5+5.5 approved (speed-run) | gatekeeper@? | ✅ baseline |
| 2026-04-21 | Dual-license refinement, Canary Pro retired, persona-gating | (memory only) | ❌ HLD/LLD not updated |
| 2026-04-22 | tiktoken real impl + Karar A cl100k_base fallback | aria-runtime@19c8118 | ❌ |
| 2026-04-22 | Shadow diff Iter 1 (Lua-only basic diff) | gatekeeper@6b944e3 | ❌ |
| 2026-04-22 | Shadow diff Iter 2 (DiffEngine in Java) | aria-runtime@bff4be1 | ❌ |
| 2026-04-23 | Shadow diff Iter 2c (HTTP `/v1/diff` bridge) — **introduces "HTTP over gRPC" precedent** | aria-runtime@ceba83c, gatekeeper@24feeda | ❌ |
| 2026-04-23 | Shadow diff Iter 3 (docs + metrics) | gatekeeper@c55776c | ❌ |
| 2026-04-24 | Mask NER bridge (BR-MK-006) — 9 new Java classes + new shared lib | aria-runtime@7f211aa, gatekeeper@b3398a9 | ❌ |
| 2026-04-24 | Gradle 8.11 → 9.4.1 | aria-runtime@723ae23 | ❌ |
| 2026-04-25 | Operator-grade doc refresh (QUICK_START + runtime/CONFIGURATION + DEPLOYMENT) | gatekeeper@3dfcb5f | partial — user-facing only |

The pattern is clear: **17 days of horizontal feature development with zero feedback into the architecture spec.**

---

## Drift Catalogue

> Severity legend
> - 🔴 **Critical** — blocks Phase 6 approval. Spec materially misrepresents shipped reality OR a critical product feature is broken.
> - 🟡 **Major** — must fix before next code change in the affected area; ship-blockers for v0.2.
> - 🟢 **Minor** — cosmetic / can follow.

### FINDING-000 🟡 [ManifestDiscipline] No Sentinel manifest in repo

- **What:** Sentinel `MANIFEST.md` / `GUIDELINES_MANIFEST.yaml` not found anywhere in `gatekeeper/` (or under `docs/`). Workspace-level guidelines were assumed.
- **Where:** Repo root.
- **Evidence:** `find gatekeeper -name "MANIFEST*" -o -name "manifest.yaml"` returns nothing.
- **Why it matters:** Without a manifest, future phase reviews cannot mechanically detect padding (e.g., the v1.0 CODE_REVIEW_REPORT cites GDPR/KVKK/PCI-DSS interchangeably without a classification document tying any of them to the product). Also, the v0.1.0 RELEASE_NOTES claim "GDPR/KVKK/PCI-DSS compliance" — the second is plausible (Turkish identifiers in PII patterns); PCI-DSS is **not justified** by an enabled compliance guideline.
- **Severity:** 🟡 Major.
- **Suggested resolution:** Create `docs/GUIDELINES_MANIFEST.yaml` enabling: core (CODING_*, ERROR_HANDLING, OBSERVABILITY, API_DESIGN, DATABASE, CONFIG_MANAGEMENT, DATA_GOVERNANCE), domain (HLD, LLD, ARCHITECT, DEVOPS), compliance (GDPR, KVKK; **not** PCI-DSS unless a real cardholder route exists). Re-run all phase reviews after.

### FINDING-001 🔴 [Spec→Code, Critical] `ariactl` CLI does not exist

- **What:** HLD §3.5 (lines 362–381) and ADR-007 promise an `ariactl` Go/GraalVM CLI with 7 commands (`quota set/status`, `mask rules list`, `canary status/promote/rollback`, `pricing update`). LLD §1 lists `ariactl/cmd/{root,quota,mask,canary}.go`. RELEASE_NOTES "Known Limitations" says "No Admin UI: Operations via Grafana dashboards + ariactl CLI".
- **Where:** Spec: `docs/03_architecture/HLD.md` §3.5, ADR-007, `docs/04_design/LLD.md` lines 59–65, `docs/06_review/RELEASE_NOTES.md` line 163.
- **Evidence:** `find . -type d -name "ariactl*" -o -name "aria-cli"` returns nothing across both repos. No Go module exists.
- **Why it matters:** Operators have no admin path beyond raw APISIX Admin API + APISIX plugin control endpoints. The "ariactl" reference is uniformly cited in HLD/LLD/release-notes/ADR — every reader is being told a tool ships that doesn't.
- **Severity:** 🔴 Critical (release-blocker for the spec, not the code — the *code* is fine; the *advertised feature set* is fiction).
- **Suggested resolution:** Either (a) create a stub `ariactl/README.md` with v0.2 timeline and strike all v1.0 claims of CLI shipping, OR (b) write the CLI before re-asserting v0.1.0. Recommendation: (a). Update HLD §3.5, ADR-007, LLD §1, RELEASE_NOTES "Known Limitations", and *also* RELEASE_NOTES line 163 which currently asserts the CLI ships.

### FINDING-002 🔴 [Spec↔Code Contradiction, Critical] gRPC/UDS is the spec; HTTP/TCP is the implementation

- **What:** Every architecture document (SRS §2.1 line 71, HLD §1.2 boundary diagram + §2.3 stack table line 123 + §4.2 internal interfaces line 404, ADR-003 in full, LLD §1 plugin tree comment line 24, INTEGRATION_MAP §2 container diagram, QUICK_START.md line 17 diagram, runtime/docs/DEPLOYMENT.md "sidecar pattern" UDS paragraph) claims **gRPC over Unix Domain Sockets** is the canonical Lua↔sidecar transport. The shipped reality is **HTTP/1.1 over TCP** via `resty.http`, hitting Spring `@RestController` endpoints `/v1/diff` and `/v1/mask/detect`.
- **Where:**
  - SRS §2.1 line 71 (`gRPC/UDS`)
  - HLD §1.2 (UDS in boundary diagram), §2.3 line 123 (`gRPC over Unix Domain Socket`), §4.2 line 404 (`Lua Plugin ↔ Aria Runtime / gRPC over UDS`), §5.1 trust-boundary diagram (`UDS (local)`)
  - ADR-003 entire decision (including "Lua gRPC client library required (lua-resty-grpc or custom FFI binding)" — this binding never happened)
  - LLD §1 line 24 (`aria-grpc.lua # gRPC/UDS client wrapper`) — file does not exist
  - QUICK_START.md line 17 ASCII diagram still labels the sidecar arrow `UDS`
  - runtime/docs/DEPLOYMENT.md: "communicating over a shared Unix Domain Socket"
  - Code: `apisix/plugins/aria-mask.lua:421-431` and `aria-canary.lua:851-859`, `927-935`, `989-997` — all `httpc:request_uri` to `http://127.0.0.1:8081/...`
  - Code: `MaskController.java` Javadoc states explicitly: *"The canonical transport for sidecar services remains gRPC; this endpoint exists so aria-mask.lua can speak a protocol it has first-class libraries for (resty.http) without pulling in lua-resty-grpc."* — **the gRPC stubs (`MaskServiceImpl`, `CanaryServiceImpl`, `ShieldServiceImpl`) have no Lua callers**, so their existence is ceremonial.
- **Why it matters:** This is the single most consequential drift. The threat model in HLD §5.1 ("UDS — no network exposure") is broken — the sidecar listens on TCP `:8081` and any pod-mate can reach it. The latency budget in §7.4 ("gRPC round-trip (UDS) < 0.5ms") is not the budget the code is meeting. Every operator reading the deployment guide is being told to share a volume for a UDS file that nothing uses.
- **Severity:** 🔴 Critical.
- **Suggested resolution:**
  1. Decide: do we want UDS, or do we accept HTTP/TCP as the production transport?
  2. If HTTP/TCP: write **ADR-008 (HTTP-over-gRPC bridge precedent)** superseding ADR-003 §"Decision". Update SRS §2.1, HLD §2.3 + §4.2 + §5.1 trust diagram, LLD §1, INTEGRATION_MAP §2, QUICK_START.md diagram, runtime/docs/DEPLOYMENT.md "sidecar pattern" paragraph. Tighten §5.1 threat model to acknowledge TCP exposure on the pod network and document the mitigation (loopback bind + APISIX-only network policy).
  3. If we want UDS for v1.0: write the Lua gRPC client and remove the HTTP controllers — but this is many weeks of work and is not the path of least resistance.
- **Recommendation:** option (2). It's the path the code already took.

### FINDING-003 🔴 [Code Defect, Critical] Audit pipeline is broken end-to-end

- **What:** Lua plugins call `aria_core.record_audit_event` (5 call-sites in shield/mask), which buffers JSON onto Redis list `aria:audit_buffer`. There is **no consumer of that list** anywhere on the sidecar side. `PostgresClient.insertAuditEvent` exists with full implementation, but `grep -rn insertAuditEvent` over the entire `aria-runtime/src` tree returns **one line — the method definition itself**. There is no flush job, no scheduler, no gRPC/HTTP RPC that takes audit events from Lua and writes them to Postgres.
- **Where:**
  - Lua sender: `apisix/plugins/lib/aria-core.lua:302-329`
  - Java consumer (claimed): `aria-runtime/src/main/java/com/eai/aria/runtime/common/PostgresClient.java:83-106`
  - Spec: HLD §8.3 ("Buffer audit events in Redis (max 1000, FIFO). Background flush job retries every 5 seconds"), LLD §2.4 ("BR-SH-015: Postgres write (async)"), DB_SCHEMA.md §3.1 (full `audit_events` DDL).
  - Proto: zero `audit` RPC across all 4 .proto files.
- **Why it matters:** BR-SH-015 (Audit Event Recording, "Must" priority) and BR-MK-005 (Masking Audit, "Must" priority) are claimed as Implemented in RELEASE_NOTES line 144, 148 and CODE_REVIEW_REPORT line 17 ("All business rules implemented PASS"). They are **not implemented** in any meaningful sense. Audit events are written to a Redis list and silently dropped. There is no immutable trail; PCI-DSS compliance claimed in RELEASE_NOTES line 29 cannot be substantiated; KVKK Article 12 retention requirement cannot be met.
- **Severity:** 🔴 Critical (functional + compliance).
- **Suggested resolution:**
  - Short-term (before any v0.2): write `AuditFlusher` (`@Scheduled` Spring bean) that BLPOPs `aria:audit_buffer` and calls `insertAuditEvent`. Add a Flyway `V001__create_audit_events.sql` from DB_SCHEMA.md §3.1.
  - Long-term: add an `AuditService` proto + RPC and have the Lua side fire-and-forget over the existing HTTP bridge precedent (`POST /v1/audit/event`). This avoids requiring a Redis list as a queue.
  - Spec: this finding cannot be closed by editing docs. It requires code.

### FINDING-004 🔴 [Spec→Code, Critical] `PromptAnalyzer` and `ContentFilter` are stubs hardcoded to "not detected"

- **What:** HLD §3.4 lists `PromptAnalyzer.java` (vector-similarity injection detection) and `ContentFilter.java` (response content moderation) as separate classes. LLD §5.1 (lines 815–826) gives them class hierarchies with multiple methods. ADR/HLD describe DM-SH-003/004 fallback behaviour relying on these. In actual code, **no separate classes exist**. Their proto methods are implemented inside `ShieldServiceImpl` as **hardcoded stubs returning `is_injection=false` / `is_harmful=false`** with comments like `// v0.1: Basic stub — returns not-injection. // v0.3: Vector similarity analysis...`.
- **Where:** `aria-runtime/src/main/java/com/eai/aria/runtime/shield/ShieldServiceImpl.java:39-57, 93-111`. LLD §5.1 lines 816–826.
- **Why it matters:** RELEASE_NOTES line 134 lists `US-A10/A11/A12` (prompt security related) under "Implemented". These user stories require a working detection — a stub is not an implementation. It also breaks the DM-SH-003 medium-confidence fallback path described in BUSINESS_LOGIC: the Lua side never escalates to the Java side for prompt analysis (no `grpc_analyze_prompt` caller in `aria-shield.lua` — verified: no Lua gRPC client at all).
- **Severity:** 🔴 Critical (release notes overclaim; security feature is theatrical).
- **Suggested resolution:**
  - RELEASE_NOTES: move US-A10/A11/A12 from "Implemented" to "Known Limitations / v0.3".
  - HLD §3.4: rewrite to acknowledge "v0.1 stubs return safe defaults; v0.3 implements full detection". Document that `PromptAnalyzer` and `ContentFilter` collapse into `ShieldServiceImpl` — this is a permitted simplification, not a deviation, but spec must reflect it.
  - LLD §5.1: prune class hierarchy to actual shipped classes. Add explicit "v0.1 stub" markers.

### FINDING-005 🔴 [Spec→Code, Critical] No DB migrations exist

- **What:** DB_SCHEMA.md (789 lines) defines audit_events, billing_records, masking_audit, monthly partitions, indexes, ENUMs in `aria_gatekeeper` schema. LLD §1 lists `db/migration/V001__create_audit_events.sql`, `V002__create_billing_records.sql`, `V003__create_masking_audit.sql`. **None of these files exist** in either repo.
- **Where:** Both `gatekeeper/db/` and `aria-runtime/src/main/resources/` checked. `find . -name "V*.sql"` returns nothing in either tree.
- **Evidence:** `aria-runtime/src/main/resources/` contains only `application.yml`. No Flyway. No migration runner.
- **Why it matters:** The Postgres tables that `PostgresClient.insertAuditEvent` and `insertBillingRecord` are written against do not exist on a fresh installation. The sidecar starts up, accepts traffic, and silently fails on any audit/billing write. Combined with FINDING-003 (no caller), the failure has been invisible.
- **Severity:** 🔴 Critical (release-blocker).
- **Suggested resolution:** Generate `V001..V003.sql` from DB_SCHEMA.md §3 directly. Add Flyway dependency to `aria-runtime/build.gradle.kts` and configure datasource. Add a startup health check that verifies schema presence.

### FINDING-006 🟡 [Code→Spec, Major] HTTP bridge pattern undocumented as architecture decision

- **What:** The pattern *"sidecar engine class is shared by both gRPC service-impl and HTTP @RestController, both delegating to the same domain object"* now appears in two places (`DiffEngine` ↔ `DiffController`+`CanaryServiceImpl`; `NerDetectionService` ↔ `MaskController`+`MaskServiceImpl`). This is a permanent architectural pattern, not an experiment. There is **no ADR for it**. ADR-003 still says gRPC is the choice; nothing supersedes it.
- **Where:** `aria-runtime/src/main/java/com/eai/aria/runtime/canary/{DiffEngine,DiffController,CanaryServiceImpl}.java`, `mask/{NerDetectionService,MaskController,MaskServiceImpl}.java`. ADR directory has no ADR-008.
- **Why it matters:** New developers will look at the protos and the gRPC stubs and assume gRPC is the active path. Code review of the v0.2 audit RPC will not know whether to extend the HTTP bridge or write a new gRPC RPC — there is no recorded principle.
- **Severity:** 🟡 Major.
- **Suggested resolution:** Write **ADR-008: HTTP/JSON bridge for Lua-callable sidecar endpoints (supersedes ADR-003 for inter-process transport)**. Decision text: "All sidecar endpoints exposed to the Lua plugins use HTTP/JSON over loopback TCP. Cross-transport engine sharing (one Spring `@Service` injected into both `@RestController` and `@GrpcService`) is the canonical pattern. gRPC services remain in the codebase as a v1.x evolution path but are not on the Lua hot path." Add ADR-003 status: "Superseded by ADR-008 (2026-04-25) for the Lua↔sidecar transport. UDS is no longer the canonical IPC."

### FINDING-007 🟡 [Code→Spec, Major] `aria-circuit-breaker.lua` shared lib not in LLD

- **What:** `apisix/plugins/lib/aria-circuit-breaker.lua` (157 lines) was added 2026-04-24 by gatekeeper@b3398a9 as a new shared library. It is required by `aria-mask.lua` (NER bridge) and is the design pattern for future bridges. LLD §6 enumerates `aria-core.lua`, §7 covers `aria-pii.lua`, but **no section covers `aria-circuit-breaker.lua`**.
- **Where:** Code: `apisix/plugins/lib/aria-circuit-breaker.lua`. Spec gap: LLD §6 (aria-core), §7 (aria-pii). LLD §1 line 22 originally listed only 4 files in `lib/` (`aria-core, aria-provider, aria-pii, aria-grpc`). Reality is 6 files: `aria-core, aria-provider, aria-pii, aria-quota, aria-mask-strategies, aria-circuit-breaker` — 4 of 6 don't match LLD's roster.
- **Why it matters:** The circuit-breaker library encodes the failure_threshold/cooldown/half_open semantics that BR-MK-006 and the future BR-SH-013 sidecar bridges will all rely on. Without LLD section, future authors will reinvent it inline (the Shield circuit breaker in §2.6 is already a parallel implementation, Redis-backed instead of shared-dict-backed — there's an unresolved design question about whether to unify them).
- **Severity:** 🟡 Major.
- **Suggested resolution:** Add LLD §8: "Shared Library: `aria-circuit-breaker.lua`" with state machine diagram, dict-key layout, threshold/cooldown semantics, and a note on the shield-internal Redis-backed CB (§2.6) as a separate-but-related concern to consider unifying in v0.2. Update LLD §1 plugin tree to list all 6 lib files.

### FINDING-008 🟡 [Code→Spec, Major] BR-MK-006 and BR-CN-007 absent from LLD traceability

- **What:** LLD §11 traceability matrix (lines 1207–1231) lists business rules from BR-SH-001 through BR-CN-004 + BR-RT-001/002/004. Missing: **BR-MK-006** (NER PII Detection) — shipped 2026-04-24 with 9 Java classes + Lua bridge code. **BR-CN-005** (Manual Override) — shipped via `_M.control_api()` admin endpoints. **BR-CN-006** (Traffic Shadow). **BR-CN-007** (Shadow Diff Comparison). **BR-MK-007/008**, **BR-SH-013/014/015/016/017/018** are also absent (some are unshipped, but BR-SH-018 is implemented per LLD §2.2 line 158, so the absence from §11 is the gap, not the implementation).
- **Where:** LLD §11 (lines 1207–1231). BUSINESS_LOGIC.md confirms BR-MK-006 (line 38), BR-CN-005 (line 45), BR-CN-006 (line 46), BR-CN-007 (line 47) all exist as defined business rules. Code confirms implementations: `aria-canary.lua control_api()` lines 1012–1097, `aria-mask.lua` lines 503–698, `DiffController.java` (BR-CN-007), `MaskController.java` + `mask/ner/*` (BR-MK-006).
- **Why it matters:** Reviewers using the LLD traceability matrix as the authoritative "what's done" map will draw wrong conclusions. The orchestrator's pre-supplied finding that "BR-CN-005 has no manual trigger" was a direct casualty — the Admin API IS implemented; the matrix just doesn't say so.
- **Severity:** 🟡 Major.
- **Suggested resolution:** Rewrite LLD §11 with one row per BR ID that has any implementation, plus explicit "deferred to v0.3" rows for BR-SH-013/014, BR-MK-007/008. New rows must include: BR-CN-005 → `aria-canary.lua _M.control_api()` lines 1012–1097, BR-CN-006 → `aria-canary.lua should_shadow + capture_shadow_payload + fire_shadow`, BR-CN-007 → `try_sidecar_diff` + `DiffController.java`, BR-MK-006 → `aria-mask.lua try_sidecar_ner + NER pipeline` + 9 Java classes in `mask/ner/`, BR-SH-018 → `aria-shield.lua apply_model_pin`.

### FINDING-009 🟡 [Spec→Code, Major] License-tier reframe (2026-04-21) not reflected in HLD/release notes

- **What:** Per memory `project_license_split_refinement.md`: Canary "Pro" enterprise tier was retired 2026-04-21; tiktoken moved to community tier; enterprise reframed to **persona-gated** (CISO/DPO/CFO). HLD §11.1 / §11.2 cost tables and RELEASE_NOTES make no reference to community/enterprise tiers. RELEASE_NOTES line 4 simply says "License: Apache 2.0" — accurate for the open core, silent on the enterprise add-ons that the GTM strategy assumes will exist.
- **Where:** Spec gap throughout `docs/`. Memory: `gatekeeper/.../memory/project_license_split_refinement.md`, `project_dual_license.md`. Code: README.md does not exist in repo root (verified). Top-level `LICENSE` file — not inspected here, but the Apache statement is the open-core reality.
- **Why it matters:** A strategic decision (license/persona model) made 17 days ago lives only in memory files. New contributors and especially future PR reviewers cannot tell whether a feature should be community-tier or enterprise-tier. The `feature_we_ship_plugin_not_models` memory file similarly is invisible to the docs.
- **Severity:** 🟡 Major.
- **Suggested resolution:** Add to HLD a new §14 "Tiering & License Strategy" cross-referencing `LICENSE` and explicitly stating: open core (Apache 2.0) covers Shield + Mask + Canary all with shadow diff + tiktoken + NER bridge; persona-gated enterprise (CISO/DPO/CFO) is **separate code**, not gated features. Update RELEASE_NOTES "Overview" and add a "License" section that's more than one line. Reflect the same in QUICK_START.md and runtime/docs/DEPLOYMENT.md.

### FINDING-010 🟡 [Spec→Code, Major] Karar A `cl100k_base` fallback policy not in HLD/LLD

- **What:** Per memory and `TokenEncoder.java` doc comments / `ShieldServiceImpl.countTokens` lines 79–80 ("Karar B (role semantics) is still open"), the policy for unknown models is **"fall back to cl100k_base, return `accuracy=APPROXIMATE`, never throw"**. This is locked per memory `project_session_2026-04-22.md`. HLD/LLD nowhere mention this fallback chain.
- **Where:** Code: `aria-runtime/.../shield/TokenEncoder.java`. Spec gap: HLD §3.4 mentions `tiktoken-exact counting` (line 327) but no fallback policy; LLD §5.3 (lines 882–937) describes a `getTokenizer(model)` that "returns Tokenizer" without specifying behaviour for unknown models.
- **Why it matters:** Auditors looking at quota over-/under-counting will not understand why the Lua estimate is sometimes echoed back as exact (delta=0) — that's the cl100k_base fallback hitting an unencodable model. Also, **Karar B is left open in code comments** ("input_tokens / output_tokens left at 0 — Karar B (role semantics) is still open"). This is a known unresolved decision that has no spec home.
- **Severity:** 🟡 Major.
- **Suggested resolution:** Add LLD §5.3.1 "Tokenizer fallback chain" describing: model → tokenizer mapping registry → cl100k_base default → APPROXIMATE accuracy flag → reconciliation with Lua estimate. Add Karar B as an explicit **Open Decision** in HLD §13 ADR list with status "Open — pending v0.2 decision".

### FINDING-011 🟡 [Spec Staleness, Major] CODE_REVIEW_REPORT.md actively misrepresents shipped state

- **What:** The 2026-04-08 CODE_REVIEW_REPORT.md gives "PASS" verdict to claims that are now demonstrably false:
  - Line 14: "LLD exists and approved" — true at the time, but **LLD has been silently invalidated** by 17 days of development.
  - Line 15: "Implementation matches LLD. File structure, function signatures, class hierarchy match LLD Sections 2-7" — false. `aria-grpc.lua` doesn't exist. `PromptAnalyzer/TokenCounter/ContentFilter` are not separate classes. `RedisClient.java` is `AriaRedisClient.java`. `NerDetector.java` is the entire `mask/ner/` package of 8 classes.
  - Line 17: "All business rules implemented PASS. Traceability matrix in LLD Section 11 covers BR-SH-001 through BR-RT-004" — covers them; doesn't *implement* them. Stub `analyzePrompt` is not "implemented".
  - Line 26: "Circuit breakers PASS. Redis-backed + in-memory fallback (aria-shield.lua lines 100-170)" — there is now a third circuit breaker (`aria-circuit-breaker.lua` shared dict-backed), and the line numbers are stale.
  - Line 53: "No TODO/FIXME in production code PASS — Verified via grep — zero occurrences" — verifiable claim, easy to refute today; not re-checked.
  - Line 63: "No hardcoded secrets PASS... SAST 7/7 passed" — the SAST scan was on Apr 8 code; 17 days of Java NER code and a Spring HTTP controller have not been re-scanned.
  - Line 153: **"Recommendation: APPROVE for merge. Pending human final review."** Status line: *Status: AI Review Complete — Pending Human Final Review.* The human review **never happened**, and the report has been silently treated as approval.
- **Where:** `docs/06_review/CODE_REVIEW_REPORT.md` in entirety.
- **Why it matters:** This is the document a v0.2 reviewer or external auditor would read first. It tells them everything is fine. It is wrong on multiple critical claims.
- **Severity:** 🟡 Major (catalogue-of-stale-claims; the *factual* inaccuracies are 🔴 but those are already covered in FINDING-001..006; this finding is about the *document* itself).
- **Suggested resolution:** **Delete or move to `docs/06_review/archive/CODE_REVIEW_REPORT_v1.0_2026-04-08.md`**. Replace with a new `CODE_REVIEW_REPORT_2026-04-25.md` that reviews the actual current code, post-NER-bridge. Or, alternatively, leave the stale one with a prominent banner: *"SUPERSEDED — see PHASE_REVIEW_2026-04-25.md. Claims herein are accurate as of 2026-04-08 but do not reflect the 17 days of subsequent shipping."*

### FINDING-012 🟡 [Spec Staleness, Major] RELEASE_NOTES v0.1.0 advertises features that are stubs or absent

- **What:** RELEASE_NOTES.md (2026-04-08) lists user stories under "Implemented" that are not implemented or are stubs:
  - US-A10/A11/A12 (prompt security) — `analyzePrompt` is a hardcoded `is_injection=false` stub. Listed lines 134 (US-A10 absent — actually US-A10/11/12 are NOT in the table; checked again: table lists A01–A09 and A17 only. **My initial recall here was wrong; correcting**: the absent-from-table user stories include US-A10/11/12/13/14/15/16, US-B06/07/08, US-C04/06/07, US-S05+. Some are deliberately deferred. But "Implemented" includes US-S01 "gRPC/UDS server" — gRPC server *is* there, but no Lua client uses it; characterising it as "Implemented" is technically true and operationally misleading).
  - "5 LLM providers: OpenAI, Anthropic, Google Gemini, Azure OpenAI, Ollama" (line 22) — provider transformer registry coverage not re-verified in this review; orchestrator should re-verify against `aria-provider.lua`.
  - "PCI-DSS compliance" (line 29) — claims compliance without an enabled PCI-DSS guideline or audit trail to back it. Per FINDING-000, this is unsupported.
  - Sidecar metric (line 47): "~0.1ms IPC via Unix Domain Sockets" — wrong by 1–2 orders of magnitude given HTTP/TCP reality.
- **Where:** `docs/06_review/RELEASE_NOTES.md`.
- **Why it matters:** The release notes are the public-facing story. They describe a v0.1.0 with persistent audit, gRPC/UDS, and Apache CLI tooling — none of which actually ship.
- **Severity:** 🟡 Major.
- **Suggested resolution:** Rewrite as `RELEASE_NOTES_v0.1.0_2026-04-25.md`:
  - Strike PCI-DSS claim (or substantiate with a compliance manifest entry).
  - Replace "~0.1ms IPC via UDS" with "<5ms HTTP/JSON over loopback TCP".
  - Add a "What changed since the original 2026-04-08 freeze" section listing: NER bridge (BR-MK-006), structural shadow diff (BR-CN-007), tiktoken via jtokkit + Karar A, Gradle 9, license-tier reframe, doc refresh.
  - Move audit persistence and ariactl to "Known Limitations / Deferred to v0.2".

### FINDING-013 🟢 [Minor] Gradle 9 / jtokkit dependencies absent from HLD tech stack

- **What:** HLD §2.3 technology stack table lists Lua 5.1, Java 21, gRPC 1.60+, Redis 7+, Postgres 18.1+, optional WASM. **Build system not listed.** Actual code uses Gradle 9.4.1 (post-2026-04-24 bump) with jtokkit (tiktoken Java port), DJL HuggingFace tokenizers + Translate4j (NER), Spring Boot, R2DBC.
- **Where:** HLD §2.3 lines 117–129.
- **Why it matters:** Minor — these aren't load-bearing architectural decisions but they affect supply-chain analysis and onboarding.
- **Severity:** 🟢 Minor.
- **Suggested resolution:** Add a sub-table to HLD §2.3 "Build & Notable Libraries" listing: Gradle 9.4.1, Spring Boot 3.x, jtokkit (cl100k_base), DJL HuggingFace, OpenNLP, R2DBC pgvector. Cite ADR-002 for the Java choice.

### FINDING-014 🟢 [Minor] DATA_CLASSIFICATION.md and PCI-DSS reference not cross-verified

- **What:** RELEASE_NOTES line 29 claims "PCI-DSS compliance" for Mask. DATA_CLASSIFICATION.md (263 lines, not fully read in this review) needs to confirm whether PAN handling justifies that claim. The product is positioned as horizontal — telco/finance/ecommerce. PAN appears in `aria-pii.lua` patterns line 1041 with Luhn validation, which is a credible PCI-DSS edge feature, but no compliance manifest binds it.
- **Where:** `docs/01_product/DATA_CLASSIFICATION.md` (not exhaustively reviewed), `docs/06_review/RELEASE_NOTES.md` line 29.
- **Why it matters:** Minor — leaves a question, doesn't break anything.
- **Severity:** 🟢 Minor.
- **Suggested resolution:** Either make PCI-DSS an explicit `enabled:` compliance entry in the new manifest (FINDING-000) and document the scope (Mask plugin only, PAN routes only), or downgrade RELEASE_NOTES wording to "PAN-handling capable" without claiming compliance.

---

## HLD v1.1 Recommended Edits

| Section | Action | Driver |
|---|---|---|
| §1.2 boundary diagram | Replace `gRPC / UDS` arrow with `HTTP/JSON loopback`; mark gRPC/UDS as "v1.x — not active" | F-002 |
| §2.3 stack table line 123 | Change "gRPC over Unix Domain Socket" to "HTTP/JSON over loopback TCP (gRPC/UDS planned, not active)"; add Build sub-table (Gradle 9.4.1, jtokkit, DJL, OpenNLP, R2DBC) | F-002, F-013 |
| §2.3 line 129 | Change "ariactl (Go or Java native)" to "ariactl — DEFERRED to v0.2 (see ADR-007 update)" | F-001 |
| §3.4 module structure tree | Replace `PromptAnalyzer.java`, `TokenCounter.java`, `ContentFilter.java` with `ShieldServiceImpl.java + TokenEncoder.java`; replace `mask/NerDetector.java` with `mask/MaskController.java + MaskServiceImpl.java + mask/ner/{NerEngine, OpenNlpNerEngine, DjlHuggingFaceNerEngine, CompositeNerEngine, NerEngineRegistry, NerProperties, NerDetectionService, PiiEntity}.java`; add `canary/DiffController.java` next to `DiffEngine.java` | F-004 |
| §3.4 gRPC services table | Add note: "gRPC stubs exist for forward-compat. Active sidecar transport in v0.1 is HTTP — see §4.2 and ADR-008." | F-002, F-006 |
| §3.5 ariactl | Strike or rewrite as "Deferred to v0.2 / v0.3"; remove from Section 12.1 packaging list | F-001 |
| §4.2 internal interfaces | `Lua Plugin ↔ Aria Runtime` row → protocol = "HTTP/1.1 over loopback TCP", auth = "loopback bind + APISIX-only network policy", latency = "< 5ms (P95)" | F-002 |
| §5.1 trust diagram | Remove `UDS (local)` arrow; add `HTTP loopback (127.0.0.1:8081)` with note about exposure risk + mitigation | F-002 |
| §5.4 data protection | Add row: "audit_events durability — REQUIRES `AuditFlusher` job + Flyway V001 migration; not yet shipped" | F-003, F-005 |
| §8.3 Postgres failure | Acknowledge that today the Redis audit buffer has no consumer; document this as a known gap | F-003 |
| §11 cost / §11.2 scaling | Re-validate; out of scope for this review | — |
| §13 ADR table | Mark ADR-003 status "Superseded by ADR-008 (2026-04-25)"; add ADR-008 row | F-002, F-006 |
| §14 NEW | "Tiering & License Strategy" — open-core Apache 2.0 + persona-gated enterprise (CISO/DPO/CFO); list which BRs are community vs enterprise (per memory project_license_split_refinement) | F-009 |
| Appendix Traceability | Sync with LLD §11 v1.1 (see below) | F-008 |

## LLD v1.1 Recommended Edits

| Section | Action | Driver |
|---|---|---|
| §1 plugin tree | Update `apisix/plugins/lib/` to actual 6 files (`aria-core, aria-provider, aria-pii, aria-quota, aria-mask-strategies, aria-circuit-breaker`); REMOVE `aria-grpc.lua`; REMOVE `ariactl/` block; REMOVE `db/migration/` block (or convert to "TBD — see FINDING-005"); fix `aria-runtime/src/main/java/.../shield/` and `mask/` and `canary/` to match actual class roster (8 NER classes under `mask/ner/`, MaskController, DiffController, AriaRedisClient renamed) | F-001, F-004, F-005, F-007 |
| §2.2 line 131 `grpc_analyze_prompt` | Mark as "Not wired in v0.1 — sidecar stub returns is_injection=false. v0.3 enables this path." | F-002, F-004 |
| §2.4 (audit log) | Update `record_audit_event` description: "Currently buffers to Redis list `aria:audit_buffer`. v0.2 adds `AuditFlusher` consumer + Flyway V001." | F-003 |
| §3.2 / new section | Add NER sidecar bridge sub-section describing `try_sidecar_ner`, `assign_entities_to_parts`, `collect_ner_candidates`, the delimiter-byte trick, fail_mode open/closed semantics, the inner+outer breaker pattern | F-008 |
| §4 Canary | Add Iter 2c sub-section describing `try_sidecar_diff` HTTP bridge with body-base64 envelope, fall-back to `compute_basic_diff` on any sidecar failure, and the metrics it emits (`aria_shadow_sidecar_calls_total`, `aria_shadow_body_similarity`) | F-008 |
| §4.4 NEW | Admin API extensions via `_M.control_api()` — document the 5 endpoints (status/promote/rollback/pause/resume) and link to BR-CN-005. Note that they're served by APISIX's plugin control plane, not a custom HTTP server | F-008 |
| §5.1 class hierarchy | Replace `PromptAnalyzer/TokenCounter/ContentFilter` with `ShieldServiceImpl + TokenEncoder`; replace `NerDetector` with `MaskServiceImpl + MaskController + mask/ner/*`; add `DiffController` next to `DiffEngine`; rename `RedisClient` → `AriaRedisClient` | F-004 |
| §5.2 | Title is "gRPC Server Implementation" — keep it for Health / future; add §5.2.1 "HTTP/JSON Bridges" with the dual-transport pattern; cite ADR-008 | F-002, F-006 |
| §5.3 token counter | Replace fictional impl with actual `TokenEncoder.count(model, content)` returning `{tokenCount, encodingUsed, accuracy}`; add §5.3.1 fallback chain (model → tokenizer registry → cl100k_base default → APPROXIMATE flag) | F-010 |
| §6 (aria-core) | Add subsection on circuit-breaker dependency injection (uses `prometheus-metrics` shared dict) | F-007 |
| §8 NEW | "Shared Library: aria-circuit-breaker.lua" — full design (state machine, dict keys, threshold/cooldown defaults, OO method API, half-open probe semantics) | F-007 |
| §9 perf decisions | Add HTTP/JSON loopback row: "HTTP bridge over gRPC chosen for Lua-callable endpoints — 1-2ms vs UDS gRPC 0.1ms; trade-off accepted to avoid lua-resty-grpc dependency. ADR-008." | F-002, F-006 |
| §11 traceability | Full rewrite. Include all implemented BRs: BR-SH-001..007/008/009/010/015/018, BR-MK-001..006, BR-CN-001..007, BR-RT-001/002/004. Mark BR-SH-013/014, BR-MK-007/008 as "Deferred to v0.3" | F-008 |

## API_CONTRACTS / ERROR_CODES / DB_SCHEMA Delta

### API_CONTRACTS.md
- **§2.2–2.4 Canary Admin endpoints:** Today documented as `POST /aria/canary/{id}/{promote|rollback|pause|resume}` (per orchestrator note). Reality is APISIX plugin control plane: `GET /v1/plugin/aria-canary/status/{route_id}` + `POST /v1/plugin/aria-canary/{promote|rollback|pause|resume}/{route_id}`. **Update §2.2–2.4 path templates** and add note about APISIX Admin API auth being required (key-auth).
- **NEW §2.5 Sidecar HTTP bridges:** document `POST /v1/diff` (canary shadow) and `POST /v1/mask/detect` (mask NER) — request/response shapes (DiffHttpRequest with base64 bodies, DetectRequest/DetectResponse), failure modes, latency budgets. These are operator-relevant: the sidecar listens on TCP `:8081`.
- **NEW §2.6 Sidecar health:** `GET /healthz`, `GET /readyz` (already in QUICK_START.md but not in API_CONTRACTS).

### ERROR_CODES.md (78 codes today)
- Spec has 78 ARIA codes. RELEASE_NOTES line 81 of CODE_REVIEW_REPORT claims "31 codes cataloged" — stale.
- **Add codes** for new bridge failures: `ARIA_MK_NER_SIDECAR_UNAVAILABLE` (502, EXT, when NER sidecar is unreachable and fail_mode=closed), `ARIA_MK_NER_FAIL_CLOSED_REDACTED` (informational metric, not an error response), `ARIA_CN_SHADOW_DIFF_UNAVAILABLE` (informational), `ARIA_RT_TOKENIZER_FALLBACK` (informational — Karar A cl100k_base path taken).
- **Verify** that all error codes the Lua/Java code actually raises are present. This requires a `git grep -E 'ARIA_[A-Z]+_[A-Z_]+'` against the source tree, cross-referenced against ERROR_CODES.md table — out of scope for this review pass; enqueue for the v1.1 LLD work.

### DB_SCHEMA.md
- DDL is correct in spirit but **has no V*.sql counterpart**. Generate V001 (audit_events + ENUMs + partitions for next 12 months), V002 (billing_records), V003 (masking_audit) from §3.
- Add V004 monthly partition rotation procedure (or document as a manual ops task).
- Add Flyway runner config to `aria-runtime/build.gradle.kts` and `application.yml`.

---

## Phase 6 Artifact Refresh Scope

The two existing files in `docs/06_review/` (CODE_REVIEW_REPORT.md, RELEASE_NOTES.md) cannot be salvaged in place. Recommended approach:

1. **Move to archive:** rename both to `docs/06_review/archive/{file}_v1.0_2026-04-08.md` with no content changes — preserve history.
2. **Write new CODE_REVIEW_REPORT_2026-04-25.md** that:
   - Replaces "PASS" with honest assessments per FINDING-001..014.
   - Reviews the actual current code: 9 NER classes, MaskController, DiffController, TokenEncoder w/ Karar A, aria-circuit-breaker.lua, the new schema flags (`fail_mode`, `consistent_hash`, `shadow.sidecar.*`, `ner.sidecar.*`).
   - Re-runs the SAST/dependency scans on today's HEAD.
   - Re-runs the "no TODO/FIXME" grep on today's HEAD (memory mentions "künye pilot KEEP locked" — there may be intentional comments worth preserving but they should not pretend to be a clean grep).
   - Notes the audit pipeline gap (FINDING-003) as a 🔴 finding in the new report — not a "PASS".
3. **Write new RELEASE_NOTES_v0.1.0_2026-04-25.md** that:
   - Releases what actually shipped, not what the 04-08 doc imagined.
   - Lists the new BRs (BR-MK-006, BR-CN-006, BR-CN-007) with implementation evidence.
   - Strikes PCI-DSS unless backed by manifest.
   - Replaces the `~0.1ms IPC via UDS` line with the HTTP reality.
   - Lists open known issues honestly: no audit persistence, no DB migrations, no ariactl, sidecar prompt analysis is a stub.
4. **Both new artifacts must be marked `Status: Pending Human Final Review` and the human review must actually be done before merge.**

---

## Approval Gate Recommendation

**BLOCK Phase 6 closure.** Re-running `/sentinel:phase-review 6` after the following items are resolved:

- 🔴 **F-001..006** must be addressed in code or in spec (with explicit deferral entries) before any v0.2 work begins.
- 🟡 **F-000, F-007..010** must be acknowledged in writing by the PO with rationale for any items chosen to remain unresolved.
- The HLD and LLD v1.1 edits above must land as a single coherent spec freeze.
- The new CODE_REVIEW_REPORT_2026-04-25.md and RELEASE_NOTES_v0.1.0_2026-04-25.md must be drafted, reviewed by a human, and the human approval must be recorded in commit history (not just memory files).

---

## Honesty — What I Did Not Check

- **Provider transformers:** `aria-provider.lua` not read line-by-line — I trusted the orchestrator's claim that 5 providers are wired. Verify in v1.1 LLD work.
- **Quota system:** `aria-quota.lua` (526 lines) not read — orchestrator did not flag drift here. Possibility of hidden drift not ruled out.
- **DATA_CLASSIFICATION.md:** read first 90 lines only.
- **DECISION_MATRIX.md, EXCEPTION_CODES.md:** spot-checked for BR-ID coverage, not read end-to-end.
- **Test coverage:** I confirmed test files exist for the new pieces (`test_mask_ner.lua`, `test_canary_shadow.lua`, `MaskControllerTest`, `DiffControllerTest`, etc.) but did not run them or measure coverage. CODE_REVIEW_REPORT line 105 claim "8 test files" is now obsolete (Lua: 7+ test files; Java: 16+ test files).
- **Helm chart, Grafana dashboards:** not inspected. RELEASE_NOTES claims pre-built dashboards for Shield/Mask/Canary; verify they exist and reflect new metrics (`aria_mask_ner_*`, `aria_shadow_sidecar_*`).
- **Build reproducibility:** Gradle 9 bump claimed to be a non-breaking native-Java-25 readiness move. Did not verify the build succeeds on a fresh checkout.
- **License/legal soundness of the persona-gating model:** PO/legal call.

---

## Final Verdict

**Phase 6 cannot be closed. The advertised v0.1.0 is a release of a system that does not exist; the system that does exist is v0.1.1-equivalent with valuable shipped features (NER bridge, structural diff, real tiktoken) but a broken audit pipeline, no DB migrations, no admin CLI, and a transport that contradicts its own architecture decision record.**
