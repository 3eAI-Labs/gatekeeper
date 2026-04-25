# 3e-Aria-Gatekeeper

**Modular AI gateway governance for Apache APISIX.** Three composable plugins that enforce AI cost control, data privacy, and progressive delivery at the gateway layer — with no application-side changes.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-v0.1.1-green.svg)](https://github.com/3eAI-Labs/gatekeeper/releases/tag/v0.1.1)
[![Status](https://img.shields.io/badge/status-community%20release-brightgreen.svg)](docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md)

---

## What this is

If you are routing LLM traffic (OpenAI, Anthropic, Gemini, Azure OpenAI, Ollama, …) through APISIX, this gives you three things upstream applications never have to reason about:

| Plugin | Concern | Brief |
|---|---|---|
| **`aria-shield`** | AI governance | Multi-provider routing · token quotas · dollar budgets · circuit-breaker failover · regex prompt-injection scan · model pinning |
| **`aria-mask`** | Data privacy | Field-level + role-based masking · 8 PII regex families (PAN/MSISDN/TC Kimlik/IBAN/email/IMEI/IP/DoB) · 12 mask strategies · NER-backed detection (English + Turkish-BERT, pluggable engines) |
| **`aria-canary`** | Progressive delivery | Multi-stage traffic splitting · error-rate auto-rollback · traffic shadowing · structural diff (status / headers / body) between primary + shadow |

A small Java 21 sidecar (`aria-runtime`) handles the work that doesn't fit Lua's strengths — token counting (jtokkit), NER inference (OpenNLP + DJL/ONNX), shadow-diff analysis, and audit-log persistence. Everything talks HTTP/JSON over loopback TCP — no native bindings, no UDS dance, debuggable with `curl`.

## Quick start

```bash
git clone git@github.com:3eAI-Labs/gatekeeper.git
cd gatekeeper/runtime
docker compose up -d

# verify (~15s after up)
curl -s http://localhost:8081/healthz | jq    # sidecar liveness
curl -s http://localhost:8081/readyz  | jq    # sidecar readiness (Redis + Postgres)
curl -s http://localhost:9080/health/echo     # APISIX bundled smoke route
```

End-to-end LLM proxy + mask + canary walkthrough: **[QUICK_START.md](docs/05_user/QUICK_START.md)** (10-min governed-call tour).

## Architecture (one screen)

```
┌──────────────────────────────────────────────────────────────┐
│  client                                                      │
│    │ (OpenAI-format request)                                 │
│    ▼                                                         │
│  APISIX gateway ───────────────────────────────────────┐     │
│   ├── aria-shield ── policy / quota / failover         │     │
│   ├── aria-mask   ── regex + NER PII mask              │     │
│   └── aria-canary ── progressive split + shadow        │     │
│           │                                            │     │
│           │ HTTP/JSON over 127.0.0.1:8081 (ADR-008)    │     │
│           ▼                                            │     │
│   aria-runtime (Java 21 sidecar)                       │     │
│   ├── /v1/diff       (canary structural diff)          │     │
│   ├── /v1/mask/detect (NER PII)                        │     │
│   └── audit/AuditFlusher → Postgres (ADR-009)          │     │
│                                                        │     │
│  Redis (real-time state) ─────────────────────────────┘     │
│  PostgreSQL (audit + billing) ──────────────────────────────┘
│    ▲                                                         │
│    └── Flyway bootstraps schema at sidecar startup           │
└──────────────────────────────────────────────────────────────┘
```

Detailed architecture: [HLD.md](docs/03_architecture/HLD.md) · ADR registry: [`docs/03_architecture/ADR/`](docs/03_architecture/ADR/) · LLD: [LLD.md](docs/04_design/LLD.md).

## What's actually shipped in v0.1.1

This is the **honest community-tier release** (post spec-freeze v1.1.2). All v0.1 critical gaps closed.

✅ **Community tier (Apache 2.0):**
- 3 Lua plugins (Shield + Mask + Canary), shared libs (`aria-core` / `aria-pii` / `aria-quota` / `aria-mask-strategies` / `aria-provider` / `aria-circuit-breaker`)
- Java sidecar engine (`aria-runtime`) with NER + shadow-diff + token counting + audit drainer + Flyway bootstrap
- 84 ARIA error codes, 9 ADRs
- Operator docs (QUICK_START, USER_GUIDE, CONFIGURATION, DEPLOYMENT, NER_MODELS), Helm chart, docker-compose, 3 Grafana dashboards, PrometheusRule template

🟡 **Known minor gaps** (4) — fully documented in [RELEASE_NOTES](docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md) §3-§9:
- ariactl CLI deferred (use APISIX Admin API + canary control_api endpoints in v0.1)
- Sidecar `PromptAnalyzer` + `ContentFilter` are stubs (Lua-tier regex prompt-injection covers community needs)
- Token role-overhead semantics open (Karar B; v0.2)
- Reversible tokenisation deferred (v0.2)

🔒 **Persona-gated enterprise tiers** (deferred to v0.2+):
- **Security (CISO):** vector-similarity prompt-injection corpus + content moderation + advanced policy semantics
- **Privacy (DPO):** bundled multilingual NER models + DLP-style outbound mask + tamper-proof WORM audit log + compliance export packs
- **FinOps (CFO):** advanced billing reconciliation + chargeback + cost forecasting

Tier model is **persona-gated, not feature-gated** (HLD §14): you don't pay per feature, you adopt the tier that matches your buyer.

## Compliance posture

Gatekeeper provides **controls** that operators use to **support** their compliance audits. Gatekeeper does **NOT** certify compliance with any framework — that requires an audited cardholder-data / personal-data environment, which is the operator's responsibility.

| Framework | Capability provided |
|---|---|
| GDPR (EU) | PII masking at gateway edge; role-based policies; per-consumer data minimisation |
| KVKK (Turkey) | Same as GDPR + Turkish ID (TC Kimlik) regex with checksum validation; default Turkish NER model `savasy/bert-base-turkish-ner-cased` |
| PDPL (Saudi Arabia / Iraq) | Same as GDPR + geographic-policy enforcement via consumer metadata |
| PCI-DSS (scope hygiene) | PAN-shape detection in prompts (Luhn-validated) + mask/block strategies prevent cardholder-data egress to upstream LLM providers. **Gatekeeper does NOT claim PCI-DSS compliance** — that requires an audited cardholder-data environment, which remains the operator's audit boundary. |

## Operator docs

| Question | Doc |
|---|---|
| First 10 minutes — what does a working install look like? | [QUICK_START.md](docs/05_user/QUICK_START.md) |
| What can I configure and how? | [runtime/docs/CONFIGURATION.md](runtime/docs/CONFIGURATION.md) |
| How do I deploy this (docker-compose / single-host / k8s sidecar)? | [runtime/docs/DEPLOYMENT.md](runtime/docs/DEPLOYMENT.md) |
| How do I bring my own NER models? | [runtime/docs/NER_MODELS.md](runtime/docs/NER_MODELS.md) |
| What end-user features ship today? | [USER_GUIDE.md](docs/05_user/USER_GUIDE.md) |

## Architecture & design

| Document | Version | Scope |
|---|---|---|
| [HLD.md](docs/03_architecture/HLD.md) | v1.1.1 | High-level design — system boundaries, modules, transport, threat model, tiering |
| [LLD.md](docs/04_design/LLD.md) | v1.1.1 | Low-level design — class hierarchy, sequences, internal interfaces, traceability matrix |
| [API_CONTRACTS.md](docs/03_architecture/API_CONTRACTS.md) | v1.1 | Plugin schemas, HTTP bridges, gRPC forward-compat, sidecar health endpoints |
| [ERROR_CODES.md](docs/04_design/ERROR_CODES.md) | v1.1.1 | 84 ARIA error codes (`ARIA_{MODULE}_{NAME}`) |
| [DB_SCHEMA.md](docs/04_design/DB_SCHEMA.md) | v1.1.2 | PostgreSQL schema + migration pipeline status |
| [ADR registry](docs/03_architecture/ADR/) | 9 ADRs | Architecture decisions (ADR-001 … ADR-009) |
| [PHASE_REVIEW_2026-04-25.md](docs/06_review/PHASE_REVIEW_2026-04-25.md) | frozen | Adversarial drift report (15 findings) that drove the v1.1 spec freeze |
| [CODE_REVIEW_REPORT_2026-04-25.md](docs/06_review/CODE_REVIEW_REPORT_2026-04-25.md) | v1.1.2 | Phase 6 code review (post-freeze, post-closures) |
| [RELEASE_NOTES_v0.1.0_2026-04-25.md](docs/06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md) | v0.1.0 + v0.1.1 patch | What shipped, what's known-limited |

## License

- **Lua plugins** (`apisix/plugins/aria-{shield,mask,canary}.lua` + `apisix/plugins/lib/*.lua`) — Apache 2.0
- **Java sidecar** (`aria-runtime`, separate repo) — community tier under Apache 2.0; persona-gated enterprise tiers under commercial licence (contact 3eAI Labs Ltd)
- **NER model artefacts** — operator-supplied for the slim community image, or bundled in the enterprise DPO tier. Default Turkish-BERT model (`savasy/bert-base-turkish-ner-cased`) ships under MIT/Apache-2.0-compatible terms.

See [LICENSE](LICENSE) for the full Apache 2.0 text. Apache 2.0 attribution + third-party notices for jtokkit / OpenNLP / DJL / Resilience4j / Lettuce / R2DBC will land in `NOTICE` (planned, see [Issue #TBD](#)).

## Contributing

Plugin development workflow + PR conventions: [CONTRIBUTING.md](CONTRIBUTING.md) *(planned — see Wave 2 in `docs/06_review/HUMAN_SIGN_OFF_v0.1.1.md`'s follow-up scope)*. Until that lands, file issues on GitHub or reach the maintainer at `levent.genc@3eai-labs.com`.

Security disclosures: please **do not** open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md) *(planned)*; until then, e-mail `security@3eai-labs.com`.

## Acknowledgements

Built on the shoulders of:
- [Apache APISIX](https://apisix.apache.org/) — the gateway this is built around
- [jtokkit](https://github.com/knuddelsgmbh/jtokkit) — Java port of OpenAI's tiktoken
- [Apache OpenNLP](https://opennlp.apache.org/) — English NER models
- [Deep Java Library](https://djl.ai/) + [ONNX Runtime](https://onnxruntime.ai/) — multilingual NER inference
- [Resilience4j](https://resilience4j.readme.io/) — JVM circuit breakers
- [Lettuce](https://lettuce.io/) — async Redis client
- [R2DBC](https://r2dbc.io/) — async PostgreSQL driver

---

**Maintained by [3eAI Labs Ltd](https://3eailabs.com/).** Telco AI · TMF standards · MENA / Africa / Türki markets.
