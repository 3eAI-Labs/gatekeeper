# Decision Matrices — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 2 — Business Analysis
**Version:** 1.0
**Date:** 2026-04-08
**Source:** BUSINESS_LOGIC.md v1.0

---

## Decision Matrix Index

| ID | Module | Decision | Business Rule |
|----|--------|----------|---------------|
| DM-SH-001 | Shield | Overage Policy Action | BR-SH-010 |
| DM-SH-002 | Shield | Provider Routing Strategy Selection | BR-SH-001, BR-SH-016, BR-SH-017 |
| DM-SH-003 | Shield | Prompt Security Action | BR-SH-011, BR-SH-012 |
| DM-SH-004 | Shield | Sidecar Unavailability Degradation | BR-SH-011, BR-SH-012, BR-SH-013 |
| DM-SH-005 | Shield | Circuit Breaker Action | BR-SH-002 |
| DM-SH-006 | Shield | Redis Unavailability Action | BR-SH-005 |
| DM-MK-001 | Mask | Role-Based Masking Strategy | BR-MK-002 |
| DM-MK-002 | Mask | PII Detection Action by Type | BR-MK-003, BR-MK-004 |
| DM-MK-003 | Mask | Masking Engine Selection | BR-MK-001, BR-MK-007 |
| DM-CN-001 | Canary | Stage Progression Decision | BR-CN-001, BR-CN-002, BR-CN-004 |
| DM-CN-002 | Canary | Rollback and Retry Decision | BR-CN-003 |
| DM-CN-003 | Canary | Canary vs. Baseline Health | BR-CN-002 |

---

## DM-SH-001: Overage Policy Action

**Business Rule:** BR-SH-010
**User Story:** US-A09

When a consumer's quota is exhausted, this matrix determines the action.

| Overage Policy | Quota Status | Action | HTTP Status | Response Header | Metric Emitted |
|---------------|-------------|--------|-------------|-----------------|----------------|
| `block` | Exhausted | Reject request | 402 | `X-Aria-Quota-Remaining: 0` | `aria_overage_requests{policy=block}` |
| `throttle` | Exhausted, within throttle window | Reject request | 429 | `Retry-After: {seconds}` | `aria_overage_requests{policy=throttle}` |
| `throttle` | Exhausted, throttle window elapsed | Allow 1 request | 200 | `X-Aria-Quota-Remaining: 0` | `aria_overage_requests{policy=throttle}` |
| `allow` | Exhausted | Allow request | 200 | `X-Aria-Quota-Remaining: 0` | `aria_overage_requests{policy=allow}` |
| Any | Not exhausted | Allow request | 200 | `X-Aria-Quota-Remaining: {N}` | None |
| (not configured) | Any | Allow request | 200 | (no header) | None |

**Default:** `block`

---

## DM-SH-002: Provider Routing Strategy Selection

**Business Rules:** BR-SH-001, BR-SH-016, BR-SH-017
**User Stories:** US-A01, US-A15, US-A16

When multiple providers are configured, this matrix determines which routing strategy is used and how the provider is selected.

| Routing Strategy | Selection Criteria | Cold Start Behavior | Tie-Breaking |
|-----------------|-------------------|--------------------|--------------| 
| `direct` (default) | Use the single configured provider | N/A | N/A |
| `failover` | Use primary; fallback on failure (BR-SH-002) | Primary first | Priority order |
| `latency` | Lowest P95 in sliding window | Round-robin until 10 requests/provider | Lower P50 |
| `cost` | Cheapest model meeting quality threshold | Cheapest by pricing table | Lower latency |
| `latency` + `failover` | Lowest P95, with circuit breaker | Round-robin, with failover | Lower P50 |
| `cost` + `failover` | Cheapest + quality threshold, with circuit breaker | Cheapest, with failover | Lower latency |

**Strategy composition:** `failover` can be combined with `latency` or `cost`. The circuit breaker (BR-SH-002) removes unhealthy providers from the selection pool before the routing strategy is applied.

---

## DM-SH-003: Prompt Security Action

**Business Rules:** BR-SH-011, BR-SH-012
**User Stories:** US-A10, US-A11

| Detection Type | Detection Source | Confidence | Sidecar Available | Action |
|---------------|-----------------|------------|-------------------|--------|
| Prompt injection | Regex | HIGH | Any | **Block** (403 PROMPT_INJECTION_DETECTED) |
| Prompt injection | Regex | MEDIUM | Yes | Send to sidecar for confirmation |
| Prompt injection | Regex | MEDIUM | No | **Allow** with WARN log + audit event |
| Prompt injection | Sidecar | Score > threshold | N/A | **Block** (403 PROMPT_INJECTION_DETECTED) |
| Prompt injection | Sidecar | Score <= threshold | N/A | **Allow** (false alarm) |
| PII in prompt | Regex | Any | Any | Apply configured action per PII type |
| PII in prompt (action) | Config: `block` | — | — | **Block** (400 PII_IN_PROMPT_DETECTED) |
| PII in prompt (action) | Config: `mask` | — | — | **Mask** PII with placeholder, forward |
| PII in prompt (action) | Config: `warn` | — | — | **Allow** with audit log |
| PII in prompt | Whitelisted consumer | — | — | **Allow** (bypass detection) |

---

## DM-SH-004: Sidecar Unavailability Degradation

**Business Rules:** BR-SH-011, BR-SH-012, BR-SH-013, BR-SH-006, BR-MK-006, BR-CN-007
**User Stories:** US-A10, US-A11, US-A12, US-A05, US-B06, US-C07

When the Java sidecar is unavailable, each feature degrades gracefully.

| Feature | Normal Behavior | Degraded Behavior (Sidecar Down) | Impact |
|---------|----------------|----------------------------------|--------|
| Prompt injection detection | Regex + vector similarity | Regex only | Higher false negative rate for MEDIUM confidence |
| PII-in-prompt scanning | Regex + NER | Regex only | May miss named entities (names, addresses) |
| Response content filtering | Sidecar moderation | **Disabled** — responses pass through unfiltered | No content safety net |
| Token count reconciliation | Exact tiktoken count | Approximate Lua count stands | Billing slightly inaccurate (conservative) |
| NER PII detection (Mask) | Async NER scan | **Disabled** — regex-only masking | May miss non-pattern PII |
| Shadow diff engine (Canary) | Compare primary vs. shadow | **Disabled** — shadow responses discarded | No diff data available |

**Monitoring:** `aria_sidecar_unavailable` gauge metric. Alert if > 0 for > 5 minutes.

---

## DM-SH-005: Circuit Breaker Action

**Business Rule:** BR-SH-002
**User Story:** US-A02

| Current State | Event | New State | Traffic Action |
|--------------|-------|-----------|---------------|
| CLOSED | Success | CLOSED | Continue to primary |
| CLOSED | Failure (count < threshold) | CLOSED | Continue to primary, increment counter |
| CLOSED | Failure (count >= threshold) | **OPEN** | Route to fallback chain |
| OPEN | Cooldown not elapsed | OPEN | Route to fallback chain |
| OPEN | Cooldown elapsed | **HALF_OPEN** | Send single probe to primary |
| HALF_OPEN | Probe success | **CLOSED** | Resume primary, reset counter |
| HALF_OPEN | Probe failure | **OPEN** | Route to fallback chain, reset cooldown |

---

## DM-SH-006: Redis Unavailability Action

**Business Rule:** BR-SH-005
**User Story:** US-A05

| Feature | Fail Policy | Redis Down Action | Metric |
|---------|------------|-------------------|--------|
| Token quota check | `fail_open` (default) | Allow request, skip quota check | `aria_quota_redis_unavailable` |
| Token quota check | `fail_closed` | Reject with 503 QUOTA_SERVICE_UNAVAILABLE | `aria_quota_redis_unavailable` |
| Token count update | N/A | Skip update, log WARN (count lost for this request) | `aria_token_update_failed` |
| Budget alert de-dup | N/A | Skip de-dup, may send duplicate alerts | `aria_alert_dedup_unavailable` |
| Audit event buffer | N/A | Drop event, log WARN | `aria_audit_event_dropped` |
| Tokenization (Mask) | N/A | Fall back to `redact` strategy | `aria_tokenize_fallback` |
| Circuit breaker state | N/A | Use in-memory state (local to this instance) | None |

---

## DM-MK-001: Role-Based Masking Strategy

**Business Rule:** BR-MK-002
**User Story:** US-B02

| Consumer Role | PAN (L4) | MSISDN (L3) | Email (L3) | TC Kimlik (L3) | IBAN (L3) | IMEI (L3) | IP (L3) | DoB (L3) |
|--------------|----------|-------------|-----------|---------------|----------|----------|---------|---------|
| `admin` | Full | Full | Full | Full | Full | Full | Full | Full |
| `operator` | `last4` | `last4` | Full | `last4` | `last4` | Full | Full | Full |
| `support_agent` | `last4` | `mask:phone` | `mask:email` | `mask:national_id` | `mask:iban` | `redact` | `mask:ip` | `mask:dob` |
| `external_partner` | `redact` | `redact` | `redact` | `redact` | `redact` | `redact` | `redact` | `redact` |
| `auditor` | `hash` | `hash` | `hash` | `hash` | `hash` | `hash` | `hash` | `hash` |
| (unknown / no role) | `redact` | `redact` | `redact` | `redact` | `redact` | `redact` | `redact` | `redact` |

**Notes:**
- `admin` sees full values — this role requires MFA and is restricted to authorized personnel.
- `auditor` sees hashed values — consistent hashes allow correlation without exposing PII.
- Unknown/missing roles default to `redact` (fail-safe, most restrictive).
- This is the **default** matrix. Per-route overrides can customize any cell.

---

## DM-MK-002: PII Detection Action by Type

**Business Rules:** BR-MK-003, BR-MK-004
**User Stories:** US-B03, US-B04

| PII Type | Detection Method | Default Mask Strategy | Classification | Compliance Driver |
|----------|-----------------|---------------------|---------------|-------------------|
| Credit Card (PAN) | Regex + Luhn validation | `last4` | L4 | PCI-DSS |
| MSISDN / Phone | Regex + length check | `mask:phone` | L3 | KVKK/GDPR |
| TC Kimlik | Regex + mod-11 checksum | `mask:national_id` | L3 | KVKK |
| IMEI | Regex + Luhn (14-digit) | Show TAC only (first 8) | L3 | Telco regulation |
| Email | Regex + format validation | `mask:email` | L3 | KVKK/GDPR |
| IBAN | Regex + country code | `mask:iban` | L3 | Financial regulation |
| IP Address | Regex + octet validation | `mask:ip` | L3 | GDPR |
| Date of Birth | Regex + date validation | `mask:dob` | L3 | KVKK/GDPR |

**Override hierarchy:** Per-route config > PII type default > global default (`redact`).

---

## DM-MK-003: Masking Engine Selection

**Business Rules:** BR-MK-001, BR-MK-007
**User Stories:** US-B01, US-B07

| Response Size | Number of Rules | Engine | Expected Latency |
|--------------|----------------|--------|-----------------|
| < 100KB | <= 20 | **Lua** (default) | < 1ms |
| < 100KB | > 20 | **WASM** (if available, else Lua) | < 2ms |
| 100KB - 1MB | Any | **WASM** (if available, else Lua) | < 3ms (WASM), < 5ms (Lua) |
| 1MB - 10MB | Any | **WASM** (if available, else Lua) | < 10ms (WASM), < 20ms (Lua) |
| > 10MB | Any | **Skip masking** | 0ms (pass-through + metric) |

**Fallback:** If WASM module is not loaded, all masking falls back to Lua regardless of response size.

---

## DM-CN-001: Stage Progression Decision

**Business Rules:** BR-CN-001, BR-CN-002, BR-CN-004
**User Stories:** US-C01, US-C02, US-C04

| Hold Duration Elapsed? | Error Rate OK? (BR-CN-002) | Latency OK? (BR-CN-004) | Sufficient Data? | Action |
|------------------------|---------------------------|------------------------|-----------------|--------|
| Yes | Yes | Yes | Yes | **Advance** to next stage |
| Yes | Yes | Yes | No | **Wait** until min_requests met |
| Yes | Yes | No (breach) | Yes | **Pause** stage |
| Yes | No (breach) | Any | Yes | **Pause** stage |
| No | Yes | Yes | Any | **Wait** for hold duration |
| No | No (breach) | Any | Yes | **Pause** immediately (don't wait for hold) |
| Any | N/A (baseline > 10%) | Any | Any | **Alert** but don't pause/rollback |

**Note:** Error rate breach during hold duration triggers immediate pause — no need to wait for hold to complete.

---

## DM-CN-002: Rollback and Retry Decision

**Business Rules:** BR-CN-003
**User Stories:** US-C03

| Breach Sustained? | Retry Policy | Retry Count < Max? | Cooldown Elapsed? | Action |
|-------------------|-------------|--------------------|--------------------|--------|
| Yes (>= sustained_duration) | Any | Any | Any | **Auto-rollback** to 0% |
| N/A (post-rollback) | `manual` | N/A | N/A | **Terminal** — wait for manual re-deployment |
| N/A (post-rollback) | `auto` | Yes | No | **Wait** for cooldown |
| N/A (post-rollback) | `auto` | Yes | Yes | **Retry** from stage 1 |
| N/A (post-rollback) | `auto` | No | Any | **Terminal** — max retries exceeded, critical alert |

---

## DM-CN-003: Canary vs. Baseline Health Assessment

**Business Rule:** BR-CN-002
**User Story:** US-C02

This matrix determines how to interpret error rate signals when both canary and baseline may be unhealthy.

| Canary Error Rate | Baseline Error Rate | Delta > Threshold? | Assessment | Action |
|------------------|--------------------|--------------------|-----------|--------|
| Low (< 5%) | Low (< 5%) | No | Both healthy | **Continue** progression |
| High (> threshold) | Low (< 5%) | Yes | Canary problem | **Pause/Rollback** canary |
| Low (< 5%) | High (> 10%) | No | Baseline problem | **Alert** ops, don't rollback canary |
| High | High (> 10%) | Any | Both unhealthy | **Alert** ops, don't rollback canary (not canary's fault) |
| Any | Any | N/A | Insufficient data (<min_requests) | **Skip** comparison, wait for data |

---

*Document Version: 1.0 | Created: 2026-04-08*
*Source: BUSINESS_LOGIC.md v1.0*
*Status: Draft — Pending Human Approval*
