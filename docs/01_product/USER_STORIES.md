# User Stories — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 1 — Requirements
**Version:** 1.1.3
**Date:** 2026-04-08
**Author:** Levent Sezgin Genc (3EAI Labs Ltd)
**Source:** VISION.md v1.0

---

## Story Index

| ID | Module | Title | MoSCoW | Sprint Target |
|----|--------|-------|--------|---------------|
| US-A01 | Shield | Multi-Provider LLM Routing | Must | v0.1 |
| US-A02 | Shield | Auto-Failover to Fallback Provider | Must | v0.1 |
| US-A03 | Shield | SSE Streaming Pass-Through | Must | v0.1 |
| US-A04 | Shield | OpenAI SDK Compatibility | Must | v0.1 |
| US-A05 | Shield | Token Quota Enforcement | Must | v0.2 |
| US-A06 | Shield | Dollar Budget Control | Must | v0.2 |
| US-A07 | Shield | Usage Tracking & Prometheus Metrics | Must | v0.2 |
| US-A08 | Shield | Budget Threshold Alerts | Should | v0.2 |
| US-A09 | Shield | Overage Policy (Block/Throttle/Allow) | Must | v0.2 |
| US-A10 | Shield | Prompt Injection Detection | Should | v0.3 |
| US-A11 | Shield | PII-in-Prompt Scanner | Should | v0.3 |
| US-A12 | Shield | Response Content Filter | Could | v0.3 |
| US-A13 | Shield | Data Exfiltration Guard | Could | v0.3 |
| US-A14 | Shield | Security Audit Trail | Must | v0.3 |
| US-A15 | Shield | Latency-Based Routing | Should | v0.2 |
| US-A16 | Shield | Cost-Based Routing | Could | v0.2 |
| US-A17 | Shield | Model Version Pinning | Should | v0.2 |
| US-B01 | Mask | Field-Level JSON Response Masking | Must | v0.1 |
| US-B02 | Mask | Role-Based Masking Policy Engine | Must | v0.2 |
| US-B03 | Mask | PII Pattern Detection (Regex) | Must | v0.1 |
| US-B04 | Mask | Configurable Mask Strategies | Must | v0.1 |
| US-B05 | Mask | Masking Audit Log | Must | v1.0 |
| US-B06 | Mask | NER-Based PII Detection (Java Sidecar) | Should | v0.3 |
| US-B07 | Mask | WASM Masking Engine (Rust) | Could | v0.3 |
| US-B08 | Mask | Compliance Report Export | Should | v1.0 |
| US-C01 | Canary | Progressive Traffic Splitting | Must | v0.1 |
| US-C02 | Canary | Error-Rate Monitoring | Must | v0.1 |
| US-C03 | Canary | Auto-Rollback on Error Threshold | Must | v0.1 |
| US-C04 | Canary | Latency Guard | Should | v0.2 |
| US-C05 | Canary | Manual Override (Promote/Rollback) | Must | v0.1 |
| US-C06 | Canary | Traffic Shadowing | Should | v0.3 |
| US-C07 | Canary | Shadow Diff Engine | Could | v0.3 |
| US-S01 | Sidecar | gRPC/UDS Server Core | Must | v0.1 |
| US-S02 | Sidecar | Virtual Thread Pool Management | Must | v0.1 |
| US-S03 | Sidecar | Health Checks & Readiness Probes | Must | v1.0 |
| US-S04 | Sidecar | Graceful Shutdown | Must | v1.0 |
| US-O01 | Ops | Grafana Dashboards (Per Module) | Must | per module v1.0 |
| US-O02 | Ops | ariactl CLI Tool | Should | v1.0 |
| US-O03 | Ops | APISIX Admin API Integration | Must | per module v0.1 |

---

## Module A: 3e-Aria-Shield (AI Governance)

### US-A01: Multi-Provider LLM Routing

**As a** platform engineer,
**I want** to route LLM requests to multiple providers (OpenAI, Anthropic, Google, Azure OpenAI, Ollama/vLLM) through a single APISIX route,
**So that** applications are decoupled from any single LLM vendor.

#### Acceptance Criteria
- [ ] Given a route configured with provider `openai`, when a request arrives in OpenAI-compatible format, then it is forwarded to the OpenAI endpoint with correct auth headers
- [ ] Given a route configured with provider `anthropic`, when a request arrives, then the canonical request is transformed to Anthropic's Messages API format
- [ ] Given a route configured with provider `google`, when a request arrives, then it is transformed to Gemini API format
- [ ] Given a route configured with provider `azure_openai`, when a request arrives, then it includes the deployment ID and API version in the URL
- [ ] Given a route configured with provider `ollama`, when a request arrives, then it is forwarded to the local Ollama endpoint

#### Error Scenarios
- [ ] When the configured provider endpoint is unreachable, then return `502 Bad Gateway` with a structured error body (`aria_error_code: PROVIDER_UNREACHABLE`)
- [ ] When the provider returns an authentication error (401/403), then return `502` with `aria_error_code: PROVIDER_AUTH_FAILED` (do not expose provider API key details)
- [ ] When the request body is malformed (not valid OpenAI-compatible JSON), then return `400` with `aria_error_code: INVALID_REQUEST_FORMAT`

#### Data Classification
- PII Fields: None (request content may contain PII — handled by US-A11)
- Sensitive Fields: Provider API keys (L4), model configuration (L2)

#### NFR Requirements
- Response time overhead: < 5ms added latency for request transformation
- Availability: Plugin must not crash APISIX on provider errors

#### Dependencies
- Depends on: None (foundational)
- Blocks: US-A02, US-A03, US-A04, US-A15, US-A16, US-A17

#### MoSCoW Priority: Must
#### Story Points: 13

---

### US-A02: Auto-Failover to Fallback Provider

**As a** platform engineer,
**I want** APISIX to automatically route to a fallback LLM provider when the primary returns 5xx errors or times out,
**So that** AI-powered applications remain available during provider outages.

#### Acceptance Criteria
- [ ] Given a primary provider returning `5xx` for 3 consecutive requests (configurable), when the circuit breaker opens, then requests are routed to the configured fallback provider
- [ ] Given the circuit breaker is open, when the cooldown period expires (default: 30s, configurable), then a single probe request is sent to the primary; if successful, the circuit closes
- [ ] Given multiple fallback providers are configured, when the primary fails, then fallbacks are tried in priority order
- [ ] Given all providers fail, then return `503 Service Unavailable` with `aria_error_code: ALL_PROVIDERS_DOWN`

#### Error Scenarios
- [ ] When the fallback provider also fails, then try next fallback in chain before returning `503`
- [ ] When circuit breaker state changes, then emit Prometheus metric `aria_circuit_breaker_state{provider, route}`

#### Data Classification
- PII Fields: None
- Sensitive Fields: Circuit breaker state (L1), provider health status (L1)

#### NFR Requirements
- Failover latency: < 100ms to detect failure and reroute
- Availability: 99.9% effective uptime across provider pool

#### Dependencies
- Depends on: US-A01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-A03: SSE Streaming Pass-Through

**As a** developer,
**I want** the gateway to pass through Server-Sent Events (SSE) streams from LLM providers without buffering,
**So that** users experience real-time token-by-token responses with no added latency.

#### Acceptance Criteria
- [ ] Given a request with `stream: true`, when the LLM responds with `text/event-stream`, then the gateway forwards each SSE chunk immediately without buffering the full response
- [ ] Given a streaming response, when the client disconnects mid-stream, then the upstream connection is also closed (no orphaned connections)
- [ ] Given a streaming response, when token counting is enabled, then tokens are counted incrementally from `data:` chunks (approximate in Lua, exact post-facto in Java sidecar)

#### Error Scenarios
- [ ] When the upstream SSE stream terminates unexpectedly (no `[DONE]` event), then close the client connection and log `aria_stream_interrupted`
- [ ] When the upstream times out mid-stream (no data for configurable timeout, default: 30s), then close and return a final SSE error event

#### Data Classification
- PII Fields: Stream content may contain PII (transit only, not stored)
- Sensitive Fields: None stored

#### NFR Requirements
- Added latency per chunk: < 1ms (Lua plugin overhead)
- Memory: No full-response buffering (constant memory per stream)

#### Dependencies
- Depends on: US-A01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-A04: OpenAI SDK Compatibility

**As a** developer,
**I want** to point my existing OpenAI SDK client to the APISIX gateway by changing only `base_url`,
**So that** I can adopt 3e-Aria-Shield with zero application code changes.

#### Acceptance Criteria
- [ ] Given an application using OpenAI Python SDK with `base_url` set to the gateway, when it calls `chat.completions.create()`, then the request is routed correctly and the response is in OpenAI-compatible format
- [ ] Given an application using OpenAI Node.js SDK, when it calls the same endpoint, then behavior is identical
- [ ] Given a request to a non-OpenAI provider (Anthropic, Google), when the response returns, then it is transformed back to OpenAI-compatible format before reaching the client
- [ ] Given a request with `stream: true`, then the SSE format matches OpenAI's `ChatCompletionChunk` schema

#### Error Scenarios
- [ ] When the provider returns a provider-specific error, then it is mapped to the equivalent OpenAI error format (e.g., `{ "error": { "type": "...", "message": "..." } }`)

#### Data Classification
- PII Fields: None
- Sensitive Fields: None

#### NFR Requirements
- SDK test suite: Must pass OpenAI SDK integration tests against the gateway

#### Dependencies
- Depends on: US-A01, US-A03
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-A05: Token Quota Enforcement

**As a** FinOps engineer,
**I want** to set monthly and daily token limits per consumer, per route, and per application,
**So that** no single team or application can generate runaway LLM costs.

#### Acceptance Criteria
- [ ] Given a consumer with a daily token quota of 100K, when they have consumed 99K tokens, then the next request is allowed and the remaining budget is updated in Redis
- [ ] Given a consumer who has exhausted their daily quota, when they send a new request, then it is rejected with `429 Too Many Requests` and header `X-Aria-Quota-Remaining: 0`
- [ ] Given quotas configured at consumer, route, and application levels, when a request arrives, then the most restrictive quota applies
- [ ] Given the Lua plugin counts tokens approximately (word-based heuristic), when the Java sidecar processes the response, then the exact tiktoken count is reconciled asynchronously in Redis and Postgres

#### Error Scenarios
- [ ] When Redis is unavailable, then apply the configured fail-open or fail-closed policy (default: fail-open with alert)
- [ ] When the LLM response does not include `usage.total_tokens`, then use the Lua approximate count as the billing record and log a warning

#### Data Classification
- PII Fields: Consumer ID (L2 — business identifier, not personal)
- Sensitive Fields: Token counts (L2), quota configuration (L2)

#### NFR Requirements
- Redis lookup latency: < 2ms (P95)
- Quota check must not add > 3ms to request pipeline

#### Dependencies
- Depends on: US-A01, US-S01 (sidecar for exact counting)
- Blocks: US-A06, US-A08, US-A09

#### MoSCoW Priority: Must
#### Story Points: 13

---

### US-A06: Dollar Budget Control

**As a** FinOps engineer,
**I want** to set budgets in dollar amounts that auto-calculate from per-model token pricing,
**So that** I can manage LLM spend in financial terms rather than raw token counts.

#### Acceptance Criteria
- [ ] Given a pricing table mapping `model -> $/1K input tokens, $/1K output tokens`, when a request is processed, then the dollar cost is calculated and deducted from the consumer's budget
- [ ] Given a consumer with a monthly budget of $500, when they have spent $499.50, then the remaining budget is reflected in response headers `X-Aria-Budget-Remaining`
- [ ] Given the pricing table is updated (new model added or price change), then the change takes effect on the next request without restart

#### Error Scenarios
- [ ] When a request uses a model not in the pricing table, then apply a configurable default price and log a warning `aria_unknown_model_pricing`

#### Data Classification
- PII Fields: None
- Sensitive Fields: Budget amounts (L2), pricing table (L2)

#### NFR Requirements
- Pricing calculation overhead: < 1ms

#### Dependencies
- Depends on: US-A05
- Blocks: US-A08

#### MoSCoW Priority: Must
#### Story Points: 5

---

### US-A07: Usage Tracking & Prometheus Metrics

**As a** platform engineer,
**I want** real-time Prometheus metrics for token consumption, cost, and request counts per consumer/model/route,
**So that** I can build Grafana dashboards for cost visibility across all teams.

#### Acceptance Criteria
- [ ] Given any LLM request processed through Shield, then the following metrics are emitted:
  - `aria_tokens_consumed{consumer, model, route, type}` (counter, type=input|output)
  - `aria_cost_dollars{consumer, model, route}` (counter)
  - `aria_requests_total{consumer, model, route, status}` (counter)
  - `aria_request_latency_seconds{consumer, model, route}` (histogram)
- [ ] Given Prometheus scrapes the APISIX metrics endpoint, then all `aria_*` metrics are available

#### Error Scenarios
- [ ] When metric emission fails, then the request pipeline is not affected (fire-and-forget)

#### Data Classification
- PII Fields: None
- Sensitive Fields: Usage metrics (L2)

#### NFR Requirements
- Metric cardinality: Must not exceed 10K unique label combinations per APISIX instance

#### Dependencies
- Depends on: US-A05
- Blocks: US-O01

#### MoSCoW Priority: Must
#### Story Points: 5

---

### US-A08: Budget Threshold Alerts

**As a** FinOps engineer,
**I want** to receive webhook/Slack notifications when a consumer reaches 80%, 90%, and 100% of their budget,
**So that** I can take action before costs exceed limits.

#### Acceptance Criteria
- [ ] Given a consumer reaches 80% of their monthly budget, then a notification is sent to the configured webhook URL with consumer details and current spend
- [ ] Given configurable thresholds (default: 80%, 90%, 100%), then each threshold triggers exactly once per budget period
- [ ] Given a Slack webhook is configured, then the notification includes a formatted Slack message with consumer, spend, and budget details

#### Error Scenarios
- [ ] When the webhook endpoint is unreachable, then retry 3 times with exponential backoff, then log failure and continue
- [ ] When the same threshold is crossed multiple times (due to reconciliation), then only alert once

#### Data Classification
- PII Fields: None
- Sensitive Fields: Webhook URLs (L2), budget amounts (L2)

#### NFR Requirements
- Alert delivery: Within 60 seconds of threshold breach

#### Dependencies
- Depends on: US-A05, US-A06
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 5

---

### US-A09: Overage Policy (Block/Throttle/Allow)

**As a** platform engineer,
**I want** to configure what happens when a consumer exceeds their quota — block (402), throttle (rate limit), or allow-with-alert,
**So that** different teams can have different cost governance strictness.

#### Acceptance Criteria
- [ ] Given overage policy `block`, when quota is exhausted, then return `402 Payment Required` with `aria_error_code: QUOTA_EXCEEDED`
- [ ] Given overage policy `throttle`, when quota is exhausted, then rate-limit the consumer to 1 req/min until the next budget period
- [ ] Given overage policy `allow`, when quota is exhausted, then allow the request but emit an alert (US-A08) and increment `aria_overage_requests{consumer}`

#### Error Scenarios
- [ ] When no overage policy is configured, then default to `block`

#### Data Classification
- PII Fields: None
- Sensitive Fields: Policy configuration (L2)

#### NFR Requirements
- Policy evaluation: < 1ms

#### Dependencies
- Depends on: US-A05
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 5

---

### US-A10: Prompt Injection Detection

**As a** security engineer,
**I want** the gateway to detect and block common prompt injection patterns before they reach the LLM,
**So that** malicious users cannot hijack AI agent behavior.

#### Acceptance Criteria
- [ ] Given a request containing known injection patterns (e.g., "ignore previous instructions", "you are now", "system prompt override"), then the request is blocked with `403 Forbidden` and `aria_error_code: PROMPT_INJECTION_DETECTED`
- [ ] Given a request flagged by the regex engine, when the Java sidecar is available, then it performs vector-similarity analysis for more accurate detection
- [ ] Given detection rules are configurable (regex patterns + sensitivity level), then new patterns can be added via APISIX metadata without restart
- [ ] Given a false positive, when the request is manually reviewed, then the pattern can be whitelisted per consumer

#### Error Scenarios
- [ ] When the Java sidecar is unavailable, then fall back to regex-only detection (reduced accuracy) and log a warning
- [ ] When a blocked prompt is logged for audit, then any PII within the prompt is masked before storage

#### Data Classification
- PII Fields: Prompt content may contain PII (transit, masked before audit storage)
- Sensitive Fields: Detection patterns (L2), blocked prompt audit log (L3 — may contain PII fragments)

#### NFR Requirements
- Regex detection latency: < 2ms
- Sidecar detection latency: < 50ms (async, non-blocking)

#### Dependencies
- Depends on: US-A01, US-S01
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 13

---

### US-A11: PII-in-Prompt Scanner

**As a** compliance officer,
**I want** the gateway to detect PII (credit cards, national IDs, phone numbers) in outgoing prompts and either block, mask, or warn,
**So that** sensitive data is not inadvertently sent to third-party LLM providers.

#### Acceptance Criteria
- [ ] Given a prompt containing a credit card number (Luhn-valid), then the configured action is applied: `block` (reject request), `mask` (replace with `[REDACTED_PAN]`), or `warn` (allow but log)
- [ ] Given a prompt containing MSISDN, TC Kimlik, IBAN, or email patterns, then the same action logic applies per pattern type
- [ ] Given the Java sidecar is available, then NER-based detection supplements regex for higher accuracy (e.g., detecting names, addresses)

#### Error Scenarios
- [ ] When masking is applied, then the original prompt is never logged — only the masked version
- [ ] When a false positive occurs on a pattern (e.g., a number that looks like a credit card but isn't), then per-consumer sensitivity can be adjusted

#### Data Classification
- PII Fields: Prompt content with PII (L3/L4 — transit only, never stored in original form)
- Sensitive Fields: Detection configuration (L2)

#### NFR Requirements
- Regex scanning latency: < 3ms
- NER scanning latency: < 15ms (async via sidecar)

#### Dependencies
- Depends on: US-A01, US-S01
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 8

---

### US-A12: Response Content Filter

**As a** security engineer,
**I want** to scan LLM responses for harmful, toxic, or policy-violating content before it reaches the client,
**So that** the gateway acts as a content safety net.

#### Acceptance Criteria
- [ ] Given a response flagged as harmful by the content moderation module (Java sidecar), then the response is replaced with a safe default message and `aria_response_filtered` metric is incremented
- [ ] Given content filtering is enabled, then it operates asynchronously — the response is streamed to the client unless the filter triggers within the first N tokens (configurable buffer window)
- [ ] Given filtering rules are configurable per route, then different routes can have different sensitivity levels

#### Error Scenarios
- [ ] When the sidecar filter is unavailable, then pass through the response unfiltered and log a warning

#### Data Classification
- PII Fields: Response content (transit only)
- Sensitive Fields: Filter rules (L2)

#### NFR Requirements
- Filter latency: < 20ms for first-token decision

#### Dependencies
- Depends on: US-S01
- Blocks: None

#### MoSCoW Priority: Could
#### Story Points: 8

---

### US-A13: Data Exfiltration Guard

**As a** security engineer,
**I want** the gateway to detect when an LLM response contains signs of training data extraction or system prompt leakage,
**So that** proprietary information is not exfiltrated through AI.

#### Acceptance Criteria
- [ ] Given a response containing patterns matching known system prompt leakage (e.g., "My instructions are:", repeated verbatim prompt content), then the response is blocked and logged
- [ ] Given configurable detection patterns, then new patterns can be added without restart

#### Error Scenarios
- [ ] When detection produces a false positive, then allow consumer-level override with audit logging

#### Data Classification
- PII Fields: None (system prompts are L2)
- Sensitive Fields: System prompt patterns (L2), exfiltration audit log (L2)

#### NFR Requirements
- Detection latency: < 10ms

#### Dependencies
- Depends on: US-S01
- Blocks: None

#### MoSCoW Priority: Could
#### Story Points: 5

---

### US-A14: Security Audit Trail

**As a** compliance officer,
**I want** an immutable audit log of all blocked prompts, flagged responses, and quota violations,
**So that** we have evidence for security reviews and regulatory compliance.

#### Acceptance Criteria
- [ ] Given any security event (prompt blocked, PII detected, content filtered, quota exceeded), then an audit record is written to Postgres with: timestamp, consumer, route, event type, action taken, and masked payload excerpt
- [ ] Given audit records, then they are immutable (append-only, no UPDATE/DELETE)
- [ ] Given a compliance query, then audit records are searchable by consumer, date range, and event type

#### Error Scenarios
- [ ] When Postgres is unavailable for audit writes, then buffer events in Redis (max 1000) and flush when Postgres recovers
- [ ] When PII is present in the audit payload, then it is masked using the same rules as US-B03

#### Data Classification
- PII Fields: Masked payload excerpts (L3 — masked PII fragments)
- Sensitive Fields: Audit records (L3)

#### NFR Requirements
- Audit write latency: < 10ms (async, non-blocking to request pipeline)
- Retention: 7 years (compliance requirement)

#### Dependencies
- Depends on: US-A10, US-A11 (events to audit)
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-A15: Latency-Based Routing

**As a** platform engineer,
**I want** the gateway to route requests to the LLM provider with the lowest P95 latency based on recent history,
**So that** users get the fastest possible response times.

#### Acceptance Criteria
- [ ] Given multiple providers configured for a route, when latency-based routing is enabled, then requests are routed to the provider with the lowest P95 over a sliding window (default: 5 min)
- [ ] Given a provider's latency degrades, then traffic shifts to faster providers within one window cycle
- [ ] Given latency data is tracked per model (not just per provider), then `gpt-4o` and `gpt-4o-mini` on OpenAI are tracked independently

#### Error Scenarios
- [ ] When no latency history exists (cold start), then use round-robin until sufficient data is collected (minimum: 10 requests)

#### Data Classification
- PII Fields: None
- Sensitive Fields: Latency metrics (L1)

#### NFR Requirements
- Routing decision latency: < 1ms

#### Dependencies
- Depends on: US-A01
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 8

---

### US-A16: Cost-Based Routing

**As a** FinOps engineer,
**I want** the gateway to route to the cheapest provider that meets a quality threshold,
**So that** I can minimize cost without sacrificing response quality.

#### Acceptance Criteria
- [ ] Given a pricing table and a quality score per model (configurable), when cost-based routing is enabled, then requests are routed to the cheapest model with quality score >= threshold
- [ ] Given two models at the same price, then the one with lower latency is preferred

#### Error Scenarios
- [ ] When no model meets the quality threshold, then use the highest-quality model regardless of cost and log a warning

#### Data Classification
- PII Fields: None
- Sensitive Fields: Pricing data (L2), quality scores (L2)

#### NFR Requirements
- Routing decision: < 1ms

#### Dependencies
- Depends on: US-A01, US-A06 (pricing table)
- Blocks: None

#### MoSCoW Priority: Could
#### Story Points: 5

---

### US-A17: Model Version Pinning

**As a** developer,
**I want** to pin a specific model version (e.g., `gpt-4o-2024-11-20`) per consumer,
**So that** my application behavior is deterministic and not affected by provider model updates.

#### Acceptance Criteria
- [ ] Given a consumer with model override `gpt-4o-2024-11-20`, when they send a request for `gpt-4o`, then the gateway rewrites the model to the pinned version
- [ ] Given no version pin is configured, then the model from the request is used as-is

#### Error Scenarios
- [ ] When the pinned model version is deprecated by the provider, then log a warning `aria_model_deprecated{consumer, model}` and continue routing

#### Data Classification
- PII Fields: None
- Sensitive Fields: Model pin configuration (L1)

#### NFR Requirements
- Overhead: < 0.5ms

#### Dependencies
- Depends on: US-A01
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 3

---

## Module B: 3e-Aria-Mask (Dynamic Data Privacy)

### US-B01: Field-Level JSON Response Masking

**As a** compliance officer,
**I want** the gateway to mask specific JSON fields in API responses based on JSONPath rules,
**So that** PII is redacted at the edge without any microservice code changes.

#### Acceptance Criteria
- [ ] Given a masking rule `$.customer.email -> mask:email`, when an upstream response contains `{"customer": {"email": "john@example.com"}}`, then the response is rewritten to `{"customer": {"email": "j***@e***.com"}}`
- [ ] Given masking rules are configured in APISIX route metadata, then they apply transparently to the upstream response
- [ ] Given nested and array fields (e.g., `$.orders[*].customer.phone`), then masking applies to all matched elements
- [ ] Given the upstream response is not JSON (`Content-Type` is not `application/json`), then the response passes through unmodified

#### Error Scenarios
- [ ] When a JSONPath expression matches no fields, then the response passes through unmodified (no error)
- [ ] When the response body is too large for in-memory parsing (> 10MB, configurable), then stream through unmasked and log `aria_mask_skip_large_body`

#### Data Classification
- PII Fields: Response body fields (L3/L4 — transit, masked at edge)
- Sensitive Fields: Masking rules (L2)

#### NFR Requirements
- Masking latency (Lua): < 1ms for responses up to 100KB
- Memory: O(response size) — single-pass rewrite

#### Dependencies
- Depends on: None (independent module)
- Blocks: US-B02, US-B03

#### MoSCoW Priority: Must
#### Story Points: 13

---

### US-B02: Role-Based Masking Policy Engine

**As a** compliance officer,
**I want** different consumers to see different masking levels for the same field (admin: full, agent: last4, partner: redact),
**So that** data visibility is enforced by role at the gateway.

#### Acceptance Criteria
- [ ] Given consumer `admin` with role policy `full` for field `$.credit_card`, then the full value is visible
- [ ] Given consumer `support_agent` with role policy `last4` for the same field, then only `****-****-****-1234` is visible
- [ ] Given consumer `external_partner` with role policy `redact`, then the field value is `[REDACTED]`
- [ ] Given role policies are defined in APISIX consumer metadata, then they override route-level defaults

#### Error Scenarios
- [ ] When a consumer has no role policy defined, then apply the route-level default (most restrictive)
- [ ] When an unknown role policy name is used, then apply `redact` (fail-safe) and log a warning

#### Data Classification
- PII Fields: None (policies are metadata)
- Sensitive Fields: Role-to-policy mappings (L2)

#### NFR Requirements
- Policy lookup: < 1ms (from APISIX metadata, in-memory)

#### Dependencies
- Depends on: US-B01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-B03: PII Pattern Detection (Regex)

**As a** compliance officer,
**I want** the gateway to automatically detect and mask PII patterns in API responses even when fields are not pre-configured,
**So that** unknown PII leaks are caught at the edge.

#### Acceptance Criteria
- [ ] Given PII detection is enabled for a route, when a response body contains a Luhn-valid credit card number in any field, then it is masked as `****-****-****-1234`
- [ ] Given the response contains MSISDN (`+90 5XX XXX XX XX`), then middle digits are masked
- [ ] Given the response contains TC Kimlik (11-digit Turkish national ID), then it is masked per configured pattern
- [ ] Given the response contains IMEI, IBAN, email, IP address, or date of birth patterns, then each is masked per the pattern table (VISION.md Section 5.2)
- [ ] Given detection patterns are configurable, then new patterns can be added via APISIX metadata

#### Error Scenarios
- [ ] When a pattern false-positive occurs (e.g., an order number matching credit card format), then per-field whitelisting is available

#### Data Classification
- PII Fields: All detected PII (L3/L4 — transit, masked)
- Sensitive Fields: Detection patterns (L2)

#### NFR Requirements
- Detection + masking latency (Lua): < 1ms for responses up to 100KB

#### Dependencies
- Depends on: US-B01
- Blocks: US-B06

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-B04: Configurable Mask Strategies

**As a** compliance officer,
**I want** to choose from multiple masking strategies per field type (`last4`, `first2last2`, `hash`, `redact`, `tokenize`),
**So that** I can balance data utility with privacy requirements.

#### Acceptance Criteria
- [ ] Given mask strategy `last4`, then `4111111111111111` becomes `****-****-****-1111`
- [ ] Given mask strategy `first2last2`, then `john.doe@example.com` becomes `jo***le.com`
- [ ] Given mask strategy `hash`, then the value is replaced with a consistent SHA-256 hash (same input = same hash, useful for correlation)
- [ ] Given mask strategy `redact`, then the value is replaced with `[REDACTED]`
- [ ] Given mask strategy `tokenize`, then the value is replaced with a reversible token stored in Redis (for authorized de-tokenization)

#### Error Scenarios
- [ ] When tokenization is configured but Redis is unavailable, then fall back to `redact` and log a warning

#### Data Classification
- PII Fields: Tokenization mapping (L4 — reversible PII reference)
- Sensitive Fields: Hash salt (L4 if used)

#### NFR Requirements
- All strategies: < 0.5ms per field

#### Dependencies
- Depends on: US-B01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 5

---

### US-B05: Masking Audit Log

**As a** compliance officer,
**I want** an audit log recording what was masked, for which consumer, on which request, and which rule triggered,
**So that** I have evidence for GDPR/KVKK compliance audits.

#### Acceptance Criteria
- [ ] Given a masking action occurs, then an audit record is written: timestamp, consumer, route, field path, mask strategy, rule ID
- [ ] Given the audit log, then the original unmasked value is NEVER stored (only metadata about the masking action)
- [ ] Given Prometheus metrics, then `aria_mask_applied{field, rule, consumer}` and `aria_mask_violations` are emitted

#### Error Scenarios
- [ ] When audit storage is unavailable, then buffer in Redis and flush on recovery

#### Data Classification
- PII Fields: None (audit records contain only metadata, not PII values)
- Sensitive Fields: Audit records (L2)

#### NFR Requirements
- Audit write: async, non-blocking (< 5ms, off critical path)
- Retention: 7 years

#### Dependencies
- Depends on: US-B01
- Blocks: US-B08

#### MoSCoW Priority: Must
#### Story Points: 5

---

### US-B06: NER-Based PII Detection (Java Sidecar)

**As a** compliance officer,
**I want** the gateway to use Named Entity Recognition to detect PII that regex patterns miss (names, addresses, free-text descriptions),
**So that** PII detection coverage is comprehensive.

#### Acceptance Criteria
- [ ] Given NER detection is enabled for a route, when the Java sidecar processes a response, then named entities (PERSON, LOCATION, ORGANIZATION) are detected and masked
- [ ] Given NER runs asynchronously, then the regex-masked response is sent to the client immediately; NER results are used for audit logging and future rule tuning
- [ ] Given NER detects PII that regex missed, then an `aria_ner_pii_found` metric is emitted with the entity type

#### Error Scenarios
- [ ] When the sidecar is unavailable, then regex-only masking is applied (graceful degradation)

#### Data Classification
- PII Fields: Response content analyzed by NER (transit, not stored in original form)
- Sensitive Fields: NER model configuration (L2)

#### NFR Requirements
- NER latency: < 10ms (async, not on critical path)

#### Dependencies
- Depends on: US-B03, US-S01
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 13

---

### US-B07: WASM Masking Engine (Rust)

**As a** platform engineer,
**I want** a high-performance WASM-based masking engine for complex pattern matching at scale,
**So that** masking performance remains under 3ms even for large, complex responses.

#### Acceptance Criteria
- [ ] Given WASM masking is enabled, then complex regex patterns (multi-pattern, overlapping) are processed by the Rust WASM module instead of Lua
- [ ] Given a response > 100KB with 20+ masking rules, then WASM completes masking in < 3ms
- [ ] Given the WASM module, then it can be loaded as an APISIX WASM plugin alongside the Lua plugin

#### Error Scenarios
- [ ] When the WASM module fails to load, then fall back to Lua masking and log a warning

#### Data Classification
- PII Fields: Same as US-B01 (transit)
- Sensitive Fields: None

#### NFR Requirements
- Masking latency: < 3ms for responses up to 1MB

#### Dependencies
- Depends on: US-B01
- Blocks: None

#### MoSCoW Priority: Could
#### Story Points: 13

---

### US-B08: Compliance Report Export

**As a** compliance officer,
**I want** to export masking audit data as a structured compliance report (JSON/CSV),
**So that** I can provide evidence to GDPR/KVKK auditors.

#### Acceptance Criteria
- [ ] Given a date range and optional consumer filter, then a compliance report is generated showing: total requests masked, fields masked by type, rules triggered, violations detected
- [ ] Given the report format is JSON or CSV (selectable), then it is downloadable via API endpoint

#### Error Scenarios
- [ ] When the date range spans > 1 year, then the report is generated asynchronously and the caller receives a job ID

#### Data Classification
- PII Fields: None (aggregate statistics only)
- Sensitive Fields: Report data (L2)

#### NFR Requirements
- Report generation: < 30s for 1-month range

#### Dependencies
- Depends on: US-B05
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 5

---

## Module C: 3e-Aria-Canary (Progressive Delivery)

### US-C01: Progressive Traffic Splitting

**As an** SRE,
**I want** to configure a progressive canary schedule (5% -> 10% -> 25% -> 50% -> 100%) with configurable hold durations per stage,
**So that** new versions are rolled out safely with increasing confidence.

#### Acceptance Criteria
- [ ] Given a canary deployment with schedule `[{pct: 5, hold: "5m"}, {pct: 10, hold: "5m"}, {pct: 25, hold: "10m"}, {pct: 50, hold: "10m"}, {pct: 100, hold: "0"}]`, then traffic is split according to the schedule with automatic stage progression
- [ ] Given the hold duration for a stage has elapsed and no error threshold is breached, then traffic automatically advances to the next stage
- [ ] Given traffic splitting, then the split is applied per-request using consistent hashing (same client gets the same version within a stage)

#### Error Scenarios
- [ ] When the canary upstream is unhealthy (no healthy targets), then route 100% to baseline and emit `aria_canary_upstream_unhealthy`

#### Data Classification
- PII Fields: None
- Sensitive Fields: Canary configuration (L1)

#### NFR Requirements
- Routing decision: < 0.5ms
- Split accuracy: Within 1% of configured percentage

#### Dependencies
- Depends on: None (independent module)
- Blocks: US-C02, US-C03, US-C04

#### MoSCoW Priority: Must
#### Story Points: 13

---

### US-C02: Error-Rate Monitoring

**As an** SRE,
**I want** continuous comparison of canary vs. baseline error rates with a configurable delta threshold,
**So that** degraded deployments are detected automatically.

#### Acceptance Criteria
- [ ] Given error-rate monitoring is enabled with threshold `2%`, when the canary error rate exceeds baseline + 2% over a sliding window (default: 1 min), then the canary stage is paused and an alert is sent
- [ ] Given error rates are tracked, then metrics are emitted: `aria_canary_error_rate{version}` (canary vs. baseline)
- [ ] Given a paused canary, when the error rate recovers (falls below threshold for 2 consecutive windows), then the operator can resume via Admin API

#### Error Scenarios
- [ ] When the baseline also has a high error rate (> 10%), then skip the delta comparison (both are unhealthy — alert but don't auto-rollback)

#### Data Classification
- PII Fields: None
- Sensitive Fields: Error metrics (L1)

#### NFR Requirements
- Monitoring granularity: 10-second sliding window

#### Dependencies
- Depends on: US-C01
- Blocks: US-C03

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-C03: Auto-Rollback on Error Threshold

**As an** SRE,
**I want** the gateway to automatically roll back canary traffic to 0% when the error threshold is exceeded for a sustained period,
**So that** bad deployments are contained without human intervention at 3 AM.

#### Acceptance Criteria
- [ ] Given the error threshold is exceeded for 1 minute (configurable), then canary traffic is set to 0% and all traffic routes to baseline
- [ ] Given an auto-rollback occurs, then a notification is sent (webhook/Slack) with: canary version, error rate, baseline error rate, rollback timestamp
- [ ] Given an auto-rollback, then `aria_canary_rollback_total` metric is incremented

#### Error Scenarios
- [ ] When rollback fails (APISIX Admin API error), then retry 3 times and escalate with a critical alert

#### Data Classification
- PII Fields: None
- Sensitive Fields: Rollback events (L1)

#### NFR Requirements
- Rollback execution: < 5 seconds from decision to traffic shift

#### Dependencies
- Depends on: US-C01, US-C02
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-C04: Latency Guard

**As an** SRE,
**I want** the gateway to pause canary promotion when canary P95 latency exceeds baseline P95 x 1.5,
**So that** performance regressions are caught before full rollout.

#### Acceptance Criteria
- [ ] Given latency guard is enabled, when canary P95 > baseline P95 x 1.5 (configurable multiplier), then the current stage is paused
- [ ] Given a latency breach, then `aria_canary_latency_p95{version}` metrics reflect the breach and an alert is sent

#### Error Scenarios
- [ ] When insufficient latency data exists (< 50 requests in window), then skip latency guard for that window

#### Data Classification
- PII Fields: None
- Sensitive Fields: Latency metrics (L1)

#### NFR Requirements
- Latency tracking: percentile-accurate with t-digest or HDR histogram

#### Dependencies
- Depends on: US-C01
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 5

---

### US-C05: Manual Override (Promote/Rollback)

**As an** SRE,
**I want** to instantly promote a canary to 100% or roll back to 0% via the APISIX Admin API,
**So that** I can override the automated schedule when I have manual confidence or need to act fast.

#### Acceptance Criteria
- [ ] Given an Admin API call to `POST /aria/canary/{route}/promote`, then traffic immediately shifts to 100% canary
- [ ] Given an Admin API call to `POST /aria/canary/{route}/rollback`, then traffic immediately shifts to 0% canary
- [ ] Given a manual action, then it is logged in the audit trail with the operator identity

#### Error Scenarios
- [ ] When no active canary deployment exists for the route, then return `404` with `aria_error_code: NO_ACTIVE_CANARY`

#### Data Classification
- PII Fields: None
- Sensitive Fields: Operator identity (L2)

#### NFR Requirements
- Action execution: < 2 seconds

#### Dependencies
- Depends on: US-C01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 3

---

### US-C06: Traffic Shadowing

**As an** SRE,
**I want** to copy a configurable percentage of live traffic to a "next version" without affecting real users,
**So that** I can validate new versions under real-world load before canary starts.

#### Acceptance Criteria
- [ ] Given shadow mode is enabled with `shadow_pct: 10`, then 10% of live requests are duplicated to the shadow upstream
- [ ] Given a shadow request, then the shadow response is NEVER returned to the client
- [ ] Given shadow mode, then shadow requests carry a header `X-Aria-Shadow: true` so the shadow upstream can distinguish them

#### Error Scenarios
- [ ] When the shadow upstream is unhealthy, then stop shadowing and log `aria_shadow_upstream_down` (do not affect primary traffic)

#### Data Classification
- PII Fields: Duplicated request may contain PII (transit, same classification as original)
- Sensitive Fields: Shadow configuration (L1)

#### NFR Requirements
- Shadow overhead: < 2ms added to primary request (fire-and-forget duplication)

#### Dependencies
- Depends on: US-C01
- Blocks: US-C07

#### MoSCoW Priority: Should
#### Story Points: 8

---

### US-C07: Shadow Diff Engine

**As an** SRE,
**I want** to compare primary vs. shadow responses (status code, body structure, latency) and view discrepancies in a dashboard,
**So that** I can identify behavioral differences before promoting the new version.

#### Acceptance Criteria
- [ ] Given shadow mode is active, when both primary and shadow responses are received, then a diff record is created: status code match, body structure similarity, latency delta
- [ ] Given diff results, then `aria_shadow_diff_count{diff_type}` metrics are emitted (status_mismatch, body_mismatch, latency_regression)
- [ ] Given a Grafana dashboard, then shadow diff results are visualized over time

#### Error Scenarios
- [ ] When the shadow response times out, then record the diff as `shadow_timeout` and continue

#### Data Classification
- PII Fields: Diff records may reference response structure (L2 — no actual field values stored)
- Sensitive Fields: Diff reports (L2)

#### NFR Requirements
- Diff processing: async via Java sidecar, non-blocking

#### Dependencies
- Depends on: US-C06, US-S01
- Blocks: None

#### MoSCoW Priority: Could
#### Story Points: 8

---

## Sidecar: Aria Runtime (Java 21)

### US-S01: gRPC/UDS Server Core

**As a** developer,
**I want** the Java sidecar to expose a gRPC API over Unix Domain Sockets,
**So that** Lua plugins communicate with the sidecar at minimal latency (~0.1ms).

#### Acceptance Criteria
- [ ] Given the sidecar is running, then it listens on a configurable UDS path (default: `/var/run/aria/aria.sock`)
- [ ] Given a gRPC service definition, then Shield, Mask, and Canary modules register their handlers
- [ ] Given UDS communication, then round-trip latency is < 0.5ms for simple requests

#### Error Scenarios
- [ ] When the UDS socket file is inaccessible (permissions), then the sidecar logs an error and exits with a non-zero code
- [ ] When the sidecar process crashes, then Lua plugins detect the failure (gRPC deadline exceeded) and fall back to local-only processing

#### Data Classification
- PII Fields: Request/response payloads may transit through gRPC (same classification as original)
- Sensitive Fields: UDS path (L1)

#### NFR Requirements
- Startup time: < 3 seconds
- Memory footprint: < 256MB base

#### Dependencies
- Depends on: None (foundational)
- Blocks: US-A10, US-A11, US-A12, US-B06, US-C07

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-S02: Virtual Thread Pool Management

**As a** developer,
**I want** the sidecar to use Java 21 Virtual Threads with ScopedValue for per-request context,
**So that** it can handle thousands of concurrent requests efficiently without ThreadLocal memory leaks.

#### Acceptance Criteria
- [ ] Given a gRPC request, then it is processed on a virtual thread (not a platform thread)
- [ ] Given per-request context (consumer ID, route, tenant), then it is propagated via `ScopedValue` (not `ThreadLocal`)
- [ ] Given synchronization is needed, then `ReentrantLock` is used (not `synchronized`) to avoid virtual thread pinning

#### Error Scenarios
- [ ] When virtual thread creation fails (system resource exhaustion), then reject the request with `RESOURCE_EXHAUSTED` gRPC status

#### Data Classification
- PII Fields: Per-request context may contain consumer ID (L2)
- Sensitive Fields: None

#### NFR Requirements
- Concurrent requests: Handle 10K+ concurrent virtual threads
- No pinning: Zero `synchronized` blocks in hot path

#### Dependencies
- Depends on: US-S01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 5

---

### US-S03: Health Checks & Readiness Probes

**As an** SRE,
**I want** the sidecar to expose health and readiness endpoints compatible with Kubernetes,
**So that** orchestration systems can manage sidecar lifecycle correctly.

#### Acceptance Criteria
- [ ] Given a liveness probe at `/healthz`, then return `200` if the process is alive
- [ ] Given a readiness probe at `/readyz`, then return `200` only when all dependent services (Redis, Postgres) are reachable
- [ ] Given a dependency becomes unreachable, then readiness returns `503` until recovery

#### Error Scenarios
- [ ] When the health endpoint itself fails, then Kubernetes restarts the pod (expected behavior)

#### Data Classification
- PII Fields: None
- Sensitive Fields: None

#### NFR Requirements
- Health check latency: < 10ms

#### Dependencies
- Depends on: US-S01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 3

---

### US-S04: Graceful Shutdown

**As an** SRE,
**I want** the sidecar to drain in-flight requests and close connections gracefully on SIGTERM,
**So that** rolling deployments don't drop active requests.

#### Acceptance Criteria
- [ ] Given SIGTERM, then the sidecar stops accepting new gRPC requests, waits for in-flight requests to complete (up to 30s configurable), then exits
- [ ] Given SIGTERM, then Redis and Postgres connections are closed cleanly
- [ ] Given in-flight requests exceed the grace period, then they are terminated and logged

#### Error Scenarios
- [ ] When SIGKILL is received (after grace period), then the JVM exits immediately (expected — no special handling)

#### Data Classification
- PII Fields: None
- Sensitive Fields: None

#### NFR Requirements
- Shutdown time: < 30 seconds (configurable)

#### Dependencies
- Depends on: US-S01
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 3

---

## Operations & Observability

### US-O01: Grafana Dashboards (Per Module)

**As a** platform engineer,
**I want** pre-built Grafana dashboards for each module (Shield cost, Mask compliance, Canary deployment status),
**So that** operational visibility is available out-of-the-box.

#### Acceptance Criteria
- [ ] Given Shield dashboard, then it shows: token consumption over time, cost by consumer/model, quota utilization, blocked prompts
- [ ] Given Mask dashboard, then it shows: masking operations over time, fields masked by type, compliance violations
- [ ] Given Canary dashboard, then it shows: current canary traffic percentage, error rates (canary vs. baseline), latency comparison, rollback events
- [ ] Given dashboards are JSON files, then they can be imported into any Grafana instance via provisioning

#### Error Scenarios
- [ ] When Prometheus is not configured, then dashboards show "No Data" (not errors)

#### Data Classification
- PII Fields: None
- Sensitive Fields: Dashboard configurations (L1)

#### NFR Requirements
- Dashboard load time: < 3 seconds

#### Dependencies
- Depends on: US-A07 (Shield metrics), US-B05 (Mask metrics), US-C02 (Canary metrics)
- Blocks: None

#### MoSCoW Priority: Must
#### Story Points: 8

---

### US-O02: ariactl CLI Tool

**As a** platform engineer,
**I want** a CLI tool (`ariactl`) to manage quotas, masking policies, and canary deployments,
**So that** I can perform common operations without navigating the APISIX Dashboard.

#### Acceptance Criteria
- [ ] Given `ariactl quota set --consumer=team-a --monthly-tokens=1M`, then the quota is configured via the APISIX Admin API
- [ ] Given `ariactl quota status --consumer=team-a`, then current usage vs. budget is displayed
- [ ] Given `ariactl mask rules list --route=my-route`, then current masking rules are displayed
- [ ] Given `ariactl canary status`, then current canary stage, traffic split, and error rates are displayed
- [ ] Given `ariactl canary promote --route=my-route`, then canary is instantly promoted to 100%

#### Error Scenarios
- [ ] When the APISIX Admin API is unreachable, then display a clear error with connection troubleshooting hints

#### Data Classification
- PII Fields: None
- Sensitive Fields: APISIX Admin API credentials (L4 — stored in CLI config)

#### NFR Requirements
- CLI response time: < 2 seconds for all commands

#### Dependencies
- Depends on: US-O03
- Blocks: None

#### MoSCoW Priority: Should
#### Story Points: 8

---

### US-O03: APISIX Admin API Integration

**As a** platform engineer,
**I want** all Aria configuration (quotas, masking rules, canary schedules) to be manageable via the APISIX Admin API and route metadata,
**So that** existing APISIX workflows (Dashboard, declarative config, CI/CD) work with Aria plugins natively.

#### Acceptance Criteria
- [ ] Given Shield plugin configuration, then it is set as APISIX plugin metadata on the route: `{ "ai-token-quota": { "monthly_tokens": 1000000, "overage_policy": "block" } }`
- [ ] Given Mask plugin configuration, then masking rules are route metadata: `{ "field-mask": { "rules": [{ "path": "$.email", "strategy": "mask:email" }] } }`
- [ ] Given Canary plugin configuration, then canary schedule is route metadata: `{ "aria-canary": { "schedule": [...] } }`
- [ ] Given any configuration change via Admin API, then it takes effect on the next request (hot reload)

#### Error Scenarios
- [ ] When invalid configuration is provided, then the APISIX Admin API returns `400` with a validation error describing which field is invalid

#### Data Classification
- PII Fields: None
- Sensitive Fields: Plugin configuration (L2), APISIX Admin API key (L4)

#### NFR Requirements
- Configuration reload: < 1 second

#### Dependencies
- Depends on: None
- Blocks: US-O02

#### MoSCoW Priority: Must
#### Story Points: 5

---

*Document Version: 1.0 | Created: 2026-04-08*
*Source: VISION.md v1.0*
*Status: Draft — Pending Product Owner Approval*
