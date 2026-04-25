# 3e-Aria-Gatekeeper

**Modular AI gateway governance for Apache APISIX.**

## What it is

When your applications start sending requests to OpenAI, Anthropic, Gemini, or any other large-language-model provider, three problems show up almost immediately. The bills get unpredictable. Sensitive data ends up in prompts that you never intended to share. And every change to a model or a routing rule is a bet you would rather not make.

Gatekeeper is the layer that sits between your applications and those providers, and answers all three problems from one place. It is not a new gateway you have to deploy alongside the one you already have. It is three plugins that load into Apache APISIX — the gateway many infrastructure teams already run — together with a small companion sidecar that handles the work that does not fit a Lua scripting environment.

## What it does

**Cost and routing live in `aria-shield`.** Per-team token quotas, per-model dollar budgets, multi-provider failover with a Redis-backed circuit breaker, threshold alerts to webhooks, and quota-exhaustion policies (block, throttle, or warn). It speaks the OpenAI request and response format, so existing applications change only their `base_url` to use the gateway.

**Privacy lives in `aria-mask`.** Field-level masking driven by JSONPath rules, role-based policies that distinguish administrators from support agents from external partners, eight built-in PII patterns with proper checksum validation (PAN by Luhn, Turkish national ID by mod-11, IBAN by ISO-7064, IMEI by Luhn), and twelve mask strategies that range from `last4` to keyed redaction. For PII that does not match a regex, the mask plugin can ask a sidecar NER pipeline — Apache OpenNLP for English, a multilingual ONNX engine with a default Turkish-BERT model for everything else.

**Progressive delivery lives in `aria-canary`.** Multi-stage traffic splitting with consistent hashing for stable client experience, error-rate monitoring with sliding-window comparison against the baseline, automatic rollback when the error delta sustains over a configurable duration, and traffic shadowing that fires a copy of live requests at a candidate upstream and asks the sidecar to compute a structural diff between the two responses.

The sidecar — written in Java 21, on top of Spring Boot — handles real `tiktoken` token counting via jtokkit, NER inference via the OpenNLP and DJL engines, structural shadow-diff computation, and an audit pipeline that drains a Redis buffer on a 5-second tick into the durable PostgreSQL audit table. Schema migrations bootstrap themselves at startup via Flyway. The transport between the Lua plugins and the sidecar is HTTP/JSON over loopback TCP — debuggable with `curl`, no native bindings required, and bound to `127.0.0.1` so nothing leaks outside the pod.

## Who it is for

Four kinds of teams keep finding their way to this product. The information security officer who needs to know that AI traffic is observed and bounded. The data protection officer who needs to know that personal data is not silently flowing to a third-party model. The finance lead who needs to know that the AI bill will not surprise anyone next quarter. And the platform engineer who already runs APISIX and wants to add governance without standing up another piece of infrastructure.

The community tier — three Lua plugins and the sidecar engine, Apache 2.0 — gives all four of those people enough to ship into production today. The enterprise tiers, organised by buyer persona rather than by feature flag, layer on the deeper capabilities each persona eventually asks for: a continuously-curated prompt-injection corpus and content moderation for the security buyer; bundled multilingual NER models and DLP-style outbound mask for the privacy buyer; advanced billing reconciliation and chargeback for the finance buyer.

## What "v0.1" actually means

This is the first release in which everything claimed in the documentation is actually shipped in code. An adversarial spec review on 2026-04-25 surfaced fifteen drift findings between the original baseline and the running system; both critical findings were closed the same day, every spec document was reconciled to the running reality, and a human signature gate was put in place so the same drift cannot recur. The four remaining minor gaps — `ariactl` CLI deferred to v0.2, sidecar prompt-analysis stubs, token role semantics open, reversible tokenisation deferred — are listed by name in the release notes, not papered over.

If you want to read further: [QUICK_START](../05_user/QUICK_START.md) is a ten-minute walkthrough; [DATASHEET](DATASHEET.md) is the technical fact sheet; [WHITE_PAPER](WHITE_PAPER.md) is the long argument for why governance belongs at the gateway. The code is on [GitHub](https://github.com/3eAI-Labs/gatekeeper) under Apache 2.0.

---

*3eAI Labs Ltd · 71-75 Shelton Street, Covent Garden, London WC2H 9JQ · `levent.genc@3eai-labs.com`*
