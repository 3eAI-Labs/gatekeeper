# Publish — Marketing & Thought Leadership Library

This directory holds the **operator-facing and reader-facing** narrative documents about 3e-Aria-Gatekeeper. Everything here is written for someone who is **trying to understand what the product is and why it exists**, not for someone who has already decided to buy it.

Sales materials (pitch decks, pricing sheets, ROI calculators, proposal templates) are intentionally **not** in this directory. The pieces below explain the product, walk through the design philosophy, and show how it lands in different industry contexts. Sales motion artefacts will live in a separate workspace once a clear go-to-market choice has been made.

## What's here

### `product/` — universal positioning

| Document | When you'd hand it to someone |
|---|---|
| [`ONE_PAGER.md`](product/ONE_PAGER.md) | The single page you'd print out and put in a folder. The "what is this and why should I care" version that fits on one side of A4. |
| [`DATASHEET.md`](product/DATASHEET.md) | The technical fact sheet. Two-to-four pages of every shipped capability with enough specificity that a senior engineer can decide whether it fits. |
| [`WHITE_PAPER.md`](product/WHITE_PAPER.md) | The long read. A reference architecture for AI gateway governance — the design philosophy, the trade-offs, why the boring choices were the right ones. Written for the engineer or architect who wants to understand the *why* before the *what*. |
| [`ARCHITECTURE_OVERVIEW.md`](product/ARCHITECTURE_OVERVIEW.md) | The public-facing technical companion to the internal HLD. Explains the same architecture but for an audience that has not been through the SDLC with us — fewer ADR cross-references, more diagrams in prose. |

### `solutions/` — industry adaptations

The product itself is horizontal — it does not care whether it's protecting a banking app, a hospital chatbot, or a telco self-service portal. But the conversations operators have inside those organisations are very different. These briefs adapt the same product story to four sectors that have come up most often in conversations to date.

| Document | Sector | What it argues |
|---|---|---|
| [`SOLUTION_BRIEF_telco.md`](solutions/SOLUTION_BRIEF_telco.md) | Telecommunications | Carrier-grade governance for AI assistants in customer care, network ops, and self-service. TMF alignment, MSISDN/IMEI handling, multi-region routing. |
| [`SOLUTION_BRIEF_banking.md`](solutions/SOLUTION_BRIEF_banking.md) | Banking & financial services | PAN scope hygiene at the AI gateway, audit trail for retention regulators, per-tenant cost control. |
| [`SOLUTION_BRIEF_healthcare.md`](solutions/SOLUTION_BRIEF_healthcare.md) | Healthcare | Patient data minimisation before the model sees it, role-based masking for clinical vs administrative users, audit trail for HIPAA-equivalent retention. |
| [`SOLUTION_BRIEF_public_sector.md`](solutions/SOLUTION_BRIEF_public_sector.md) | Public sector | KVKK / GDPR / PDPL alignment, on-premises deployment topology, data sovereignty controls. |

### `blog/` — narrative pieces

The blog directory holds longer-form first-person posts that explain the project's thinking out loud. These are the pieces a developer would land on from Hacker News or read after seeing the GitHub repo, and the pieces a customer would forward internally as "this is the kind of thinking we want from a vendor".

| Document | Premise |
|---|---|
| [`BLOG_why_we_built_gatekeeper.md`](blog/BLOG_why_we_built_gatekeeper.md) | The founding story — what was wrong with the existing options, why APISIX was the right host, why open core was the right model. |
| [`BLOG_kvkk_tr_id_at_ai_gateway.md`](blog/BLOG_kvkk_tr_id_at_ai_gateway.md) | A technical deep-dive into how Turkish-language PII detection actually works inside the gateway — TC Kimlik checksum, Turkish-BERT NER pipeline, the trade-offs between regex and ML. |
| [`BLOG_open_core_economics.md`](blog/BLOG_open_core_economics.md) | Why we chose open core over pure-OSS or pure-proprietary, and why the enterprise tier is gated by buyer persona rather than by feature flag. The economics argument. |

## How these documents are written

Three rules govern everything in this directory.

**One — capability statements, not certifications.** The product does not certify compliance with any framework. The product provides controls that operators use to support their own compliance audits. Every framework reference (KVKK, GDPR, PCI-DSS, HIPAA, PDPL) is a capability statement, not a certification claim. This rule is locked in [`docs/GUIDELINES_MANIFEST.yaml`](../GUIDELINES_MANIFEST.yaml) and reflects [`feedback_compliance_framing`](../../memory) lessons from earlier drafts.

**Two — honest about what's shipped.** v0.1.1 has a known scope. Sidecar `PromptAnalyzer` and `ContentFilter` are stubs (deferred to v0.3 enterprise CISO tier). Reversible tokenisation is deferred to v0.2. ariactl CLI is deferred. These deferrals are documented in [`RELEASE_NOTES`](../06_review/RELEASE_NOTES_v0.1.0_2026-04-25.md) and acknowledged where relevant in these documents — we do not paper over them with marketing.

**Three — narrative over bullet salad.** These are documents people read, not lists they scan. Every section explains *why* a capability exists before it explains *what* the capability does, and connects features back to the operator pain that motivated them.

---

*Maintained by 3eAI Labs Ltd. Filed under the doc-set audit Wave 4 (publish/marketing). Written 2026-04-25.*
