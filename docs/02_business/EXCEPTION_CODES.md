# Exception Codes — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 2 — Business Analysis
**Version:** 1.1.3
**Date:** 2026-04-25 (v1.1.3 spec-coherence sweep); 2026-04-08 (v1.0 baseline)
**Source:** BUSINESS_LOGIC.md v1.1.3, DECISION_MATRIX.md v1.0
**v1.1.3 Driver:** This Phase 2 document is the *business-rule-driven exception taxonomy* (what each business rule says should fail, and how). The *implementation registry* of every code emitted by shipped code lives in [`docs/04_design/ERROR_CODES.md`](../04_design/ERROR_CODES.md) v1.1.1 — currently 84 codes. v1.0 of this Phase 2 doc had 46 codes; the post-v1.0 ship rounds (NER bridge BR-MK-006, shadow diff BR-CN-007, transport reframe per ADR-008, audit closure per ADR-009) added codes that this Phase 2 doc had not been updated to reflect. The v1.1.3 sweep below adds the new code families with business-rule mappings; the canonical implementation registry remains Phase 4 ERROR_CODES.md.

> **For implementers and operators:** [`docs/04_design/ERROR_CODES.md`](../04_design/ERROR_CODES.md) v1.1.1 is the **canonical** registry — full HTTP/gRPC mapping, severity, retry strategy, and traceability to business rules + user stories for all 84 codes. Use that document for emit decisions and operator alerting; this Phase 2 document explains *why* each code exists in business terms.

### Post-v1.0 additions (since 2026-04-08)

| Code | Business Rule | Origin (Phase 4 §) | Notes |
|---|---|---|---|
| `ARIA_MK_NER_SIDECAR_UNAVAILABLE` | BR-MK-006 | §3.2 | NER bridge unreachable; per `fail_mode` returns regex-only result OR redacts candidates |
| `ARIA_MK_NER_FAIL_CLOSED_REDACTED` | BR-MK-006 | §3.2 | Defensive fail-mode applied — operator informed that NER could not verify candidates |
| `ARIA_MK_NER_CIRCUIT_OPEN` | BR-MK-006 | §3.2 | Lua-side circuit breaker (`aria-circuit-breaker.lua`) tripped — call short-circuited |
| `ARIA_CN_SHADOW_DIFF_UNAVAILABLE` | BR-CN-007 | §3.3 | Diff bridge unreachable; shadow comparison skipped (no impact on baseline response) |
| `ARIA_CN_SHADOW_BRIDGE_TIMEOUT` | BR-CN-007 | §3.3 | Diff bridge exceeded deadline; shadow diff skipped this request |
| `ARIA_RT_TOKENIZER_FALLBACK` | BR-SH-006 | §3.4 | Karar A: model unknown to jtokkit registry; fallback to `cl100k_base` with `Accuracy.FALLBACK` flag (informational, not request-failing) |

### Retired in v1.1.1

| Code | Reason |
|---|---|
| `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` | Was registered in v1.1 spec freeze as a v0.1 gap marker for FINDING-003. Audit pipeline was closed in `aria-runtime@d487026` per ADR-009; code retired per Karar A (Retire). Operators monitor audit health via `AuditFlusher.persistedTotal` / `failedTotal` Prometheus counters. |

---

## 1. Error Code Naming Convention

```
ARIA_{MODULE}_{ERROR_NAME}

Modules:
  SH  = Shield
  MK  = Mask
  CN  = Canary
  RT  = Runtime (Sidecar)
  SYS = System-wide
```

All error codes are returned in a standard error response format.

## 2. Standard Error Response Format

```json
{
  "error": {
    "type": "aria_error",
    "code": "ARIA_SH_QUOTA_EXCEEDED",
    "message": "Daily token quota exceeded for consumer 'team-a'",
    "aria_request_id": "aria-req-abc123",
    "details": {}
  }
}
```

**Rules:**
1. `code` is machine-readable — clients should switch on this field.
2. `message` is human-readable — may change between versions.
3. `details` contains structured context (optional, never contains PII).
4. `aria_request_id` is always present for traceability.
5. Provider-specific error details are NEVER exposed to the client.

---

## 3. Exception Code Catalog

### 3.1 Module A: Shield (SH)

| Code | HTTP Status | Description | Retryable | User Action | Business Rule | User Story |
|------|------------|-------------|-----------|-------------|---------------|------------|
| `ARIA_SH_INVALID_REQUEST_FORMAT` | 400 | Request body is not valid OpenAI-compatible JSON | No | Fix request format | BR-SH-001 | US-A01 |
| `ARIA_SH_INVALID_MODEL` | 400 | Requested model is not recognized or not configured for this route | No | Use a configured model | BR-SH-001 | US-A01 |
| `ARIA_SH_PII_IN_PROMPT_DETECTED` | 400 | PII detected in prompt and action is `block` | No | Remove PII from prompt | BR-SH-012 | US-A11 |
| `ARIA_SH_PROMPT_INJECTION_DETECTED` | 403 | Prompt injection pattern detected | No | Modify prompt content | BR-SH-011 | US-A10 |
| `ARIA_SH_QUOTA_EXCEEDED` | 402 | Token or dollar quota exhausted (overage policy: block) | No* | Wait for quota reset or request increase | BR-SH-010 | US-A05, US-A09 |
| `ARIA_SH_QUOTA_THROTTLED` | 429 | Quota exhausted, throttle window active | Yes (after Retry-After) | Wait for throttle window | BR-SH-010 | US-A09 |
| `ARIA_SH_PROVIDER_AUTH_FAILED` | 502 | Provider rejected the API key (401/403 from provider) | No | Verify provider API key configuration | BR-SH-001 | US-A01 |
| `ARIA_SH_PROVIDER_RATE_LIMITED` | 429 | Provider rate limit hit after retries exhausted | Yes (after Retry-After) | Reduce request rate or upgrade provider tier | INT-001 | US-A01 |
| `ARIA_SH_PROVIDER_ERROR` | 502 | Provider returned 5xx error | Yes | Retry; failover may engage automatically | BR-SH-002 | US-A02 |
| `ARIA_SH_PROVIDER_TIMEOUT` | 504 | Provider did not respond within timeout | Yes | Retry; failover may engage automatically | BR-SH-002 | US-A02 |
| `ARIA_SH_PROVIDER_UNREACHABLE` | 502 | Could not connect to provider endpoint | Yes | Check provider status | BR-SH-001 | US-A01 |
| `ARIA_SH_ALL_PROVIDERS_DOWN` | 503 | All providers (primary + fallbacks) are unavailable | Yes | Wait for provider recovery | BR-SH-002 | US-A02 |
| `ARIA_SH_PROVIDER_NOT_CONFIGURED` | 500 | Route has no provider configured | No | Configure provider in route metadata | BR-SH-001 | US-A01 |
| `ARIA_SH_CONTENT_FILTERED` | 422 | LLM response was filtered for harmful content | No | Modify prompt to avoid harmful output | BR-SH-013 | US-A12 |
| `ARIA_SH_EXFILTRATION_DETECTED` | 422 | Response contains suspected data exfiltration | No | Review prompt for extraction attempts | BR-SH-014 | US-A13 |
| `ARIA_SH_STREAM_INTERRUPTED` | 502 | SSE stream from provider terminated unexpectedly | Yes | Retry request | BR-SH-003 | US-A03 |
| `ARIA_SH_QUOTA_SERVICE_UNAVAILABLE` | 503 | Redis unavailable and fail policy is `fail_closed` | Yes | Wait for quota service recovery | BR-SH-005 | US-A05 |

*`ARIA_SH_QUOTA_EXCEEDED`: Retryable after the quota resets (daily/monthly boundary).

### 3.2 Module B: Mask (MK)

| Code | HTTP Status | Description | Retryable | User Action | Business Rule | User Story |
|------|------------|-------------|-----------|-------------|---------------|------------|
| `ARIA_MK_MASKING_ENGINE_ERROR` | 500 | Internal error during response masking | Yes | Retry request | BR-MK-001 | US-B01 |
| `ARIA_MK_INVALID_JSONPATH` | 500 | Configured JSONPath expression is invalid (config error) | No | Fix masking rule configuration | BR-MK-001 | US-B01 |
| `ARIA_MK_TOKENIZE_UNAVAILABLE` | 500 | Tokenization requested but Redis unavailable (fallback to redact) | Yes | Wait for Redis recovery | BR-MK-004 | US-B04 |

**Note:** Most Mask errors are transparent to the client — the response is either masked correctly or passed through with degraded masking. These codes are for internal monitoring and logging.

### 3.3 Module C: Canary (CN)

| Code | HTTP Status | Description | Retryable | User Action | Business Rule | User Story |
|------|------------|-------------|-----------|-------------|---------------|------------|
| `ARIA_CN_NO_ACTIVE_CANARY` | 404 | No active canary deployment for this route | No | Deploy a canary first | BR-CN-005 | US-C05 |
| `ARIA_CN_CANARY_UPSTREAM_UNHEALTHY` | 503 | Canary upstream has no healthy targets | Yes | Check canary deployment health | BR-CN-001 | US-C01 |
| `ARIA_CN_INVALID_SCHEDULE` | 400 | Canary schedule is malformed (percentages not ascending, last stage != 100%) | No | Fix canary schedule configuration | BR-CN-001 | US-C01 |
| `ARIA_CN_ALREADY_PROMOTED` | 409 | Canary is already promoted to 100% | No | N/A — deployment is complete | BR-CN-005 | US-C05 |
| `ARIA_CN_ALREADY_ROLLED_BACK` | 409 | Canary is already rolled back | No | Re-deploy to try again | BR-CN-005 | US-C05 |

### 3.4 Runtime / Sidecar (RT)

| Code | gRPC Status | Description | Retryable | User Action | Business Rule | User Story |
|------|------------|-------------|-----------|-------------|---------------|------------|
| `ARIA_RT_SIDECAR_UNAVAILABLE` | UNAVAILABLE | Sidecar process is not running or UDS is unreachable | Yes | Restart sidecar; features degrade gracefully | BR-RT-001 | US-S01 |
| `ARIA_RT_RESOURCE_EXHAUSTED` | RESOURCE_EXHAUSTED | Sidecar virtual thread pool exhausted | Yes | Scale sidecar resources | BR-RT-002 | US-S02 |
| `ARIA_RT_HANDLER_NOT_FOUND` | UNIMPLEMENTED | Requested gRPC method not registered | No | Check sidecar module configuration | BR-RT-001 | US-S01 |
| `ARIA_RT_DEPENDENCY_UNAVAILABLE` | UNAVAILABLE | Sidecar dependency (Redis/Postgres) unreachable (readiness probe fails) | Yes | Check infrastructure | BR-RT-003 | US-S03 |

### 3.5 System-Wide (SYS)

| Code | HTTP Status | Description | Retryable | User Action | Business Rule |
|------|------------|-------------|-----------|-------------|---------------|
| `ARIA_SYS_INTERNAL_ERROR` | 500 | Unexpected plugin error (catch-all) | Yes | Report bug | N/A |
| `ARIA_SYS_CONFIG_INVALID` | 500 | Plugin configuration is invalid | No | Fix plugin configuration | N/A |

---

## 4. Error Categorization

### 4.1 By Severity

| Severity | Codes | Monitoring Action |
|----------|-------|-------------------|
| **CRITICAL** | `ALL_PROVIDERS_DOWN`, `SIDECAR_UNAVAILABLE` (>5 min), `INTERNAL_ERROR` | Page on-call |
| **HIGH** | `QUOTA_SERVICE_UNAVAILABLE`, `PROVIDER_AUTH_FAILED`, `CANARY_UPSTREAM_UNHEALTHY` | Alert Slack channel |
| **MEDIUM** | `QUOTA_EXCEEDED`, `PROMPT_INJECTION_DETECTED`, `PII_IN_PROMPT_DETECTED` | Dashboard metric |
| **LOW** | `CONTENT_FILTERED`, `EXFILTRATION_DETECTED`, `STREAM_INTERRUPTED` | Log only |

### 4.2 By Client Visibility

| Category | Description | Codes |
|----------|-------------|-------|
| **Client-facing** | Returned to the end user as HTTP response | All HTTP-mapped codes |
| **Internal-only** | Logged and monitored, transparent to client | Mask codes (response is masked or passed through), Runtime gRPC codes |
| **Admin API only** | Returned only to Admin API callers | Canary management codes (`NO_ACTIVE_CANARY`, `ALREADY_PROMOTED`, etc.) |

### 4.3 By Retry Strategy

| Strategy | Description | Codes |
|----------|-------------|-------|
| **Not retryable** | Client must fix the request | `INVALID_REQUEST_FORMAT`, `PII_IN_PROMPT_DETECTED`, `PROMPT_INJECTION_DETECTED`, `QUOTA_EXCEEDED` (until reset), `PROVIDER_AUTH_FAILED` |
| **Retry immediately** | Transient error, retry with same request | `PROVIDER_ERROR`, `STREAM_INTERRUPTED`, `SIDECAR_UNAVAILABLE` |
| **Retry after delay** | Rate-limited or cooldown required | `QUOTA_THROTTLED` (Retry-After), `PROVIDER_RATE_LIMITED` (Retry-After) |
| **Retry after recovery** | Infrastructure issue, wait for ops action | `ALL_PROVIDERS_DOWN`, `QUOTA_SERVICE_UNAVAILABLE`, `CANARY_UPSTREAM_UNHEALTHY` |

---

## 5. Prometheus Metric Mapping

Every exception code maps to a Prometheus metric for monitoring.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `aria_errors_total` | Counter | `module`, `code`, `consumer`, `route` | Total error count by code |
| `aria_errors_by_severity` | Counter | `severity` | Errors by severity (critical/high/medium/low) |
| `aria_provider_errors_total` | Counter | `provider`, `error_type` | Provider-specific errors |
| `aria_security_events_total` | Counter | `event_type` | Security events (injection, PII, exfiltration) |

---

## 6. Error Response Examples

### 6.1 Quota Exceeded (402)

```json
{
  "error": {
    "type": "aria_error",
    "code": "ARIA_SH_QUOTA_EXCEEDED",
    "message": "Daily token quota exceeded for consumer 'team-a'. Resets at 2026-04-09T00:00:00Z.",
    "aria_request_id": "aria-req-7f3a2b",
    "details": {
      "consumer_id": "team-a",
      "quota_type": "daily_tokens",
      "quota_limit": 100000,
      "quota_used": 100247,
      "resets_at": "2026-04-09T00:00:00Z",
      "overage_policy": "block"
    }
  }
}
```

### 6.2 Prompt Injection Blocked (403)

```json
{
  "error": {
    "type": "aria_error",
    "code": "ARIA_SH_PROMPT_INJECTION_DETECTED",
    "message": "Request blocked: potential prompt injection detected.",
    "aria_request_id": "aria-req-9c4d1e",
    "details": {
      "detection_source": "regex",
      "confidence": "HIGH",
      "pattern_category": "direct_override"
    }
  }
}
```

### 6.3 All Providers Down (503)

```json
{
  "error": {
    "type": "aria_error",
    "code": "ARIA_SH_ALL_PROVIDERS_DOWN",
    "message": "All configured LLM providers are currently unavailable.",
    "aria_request_id": "aria-req-b2e8f0",
    "details": {
      "providers_tried": ["openai", "anthropic"],
      "circuit_breaker_states": {
        "openai": "OPEN",
        "anthropic": "OPEN"
      }
    }
  }
}
```

### 6.4 Canary Rollback Notification (Webhook, not HTTP response)

```json
{
  "type": "aria_canary_rollback",
  "code": "ARIA_CN_AUTO_ROLLBACK",
  "route_id": "route-api-v2",
  "canary_version": "v2.1.0",
  "baseline_version": "v2.0.0",
  "canary_error_rate": 0.052,
  "baseline_error_rate": 0.008,
  "sustained_breach_seconds": 65,
  "rollback_trigger": "auto",
  "retry_policy": "manual",
  "timestamp": "2026-04-08T03:15:22Z"
}
```

---

## 7. Cross-Reference

| Exception Code | Business Rule | Decision Matrix | Audit Event Type |
|---------------|---------------|-----------------|-----------------|
| `ARIA_SH_PROMPT_INJECTION_DETECTED` | BR-SH-011 | DM-SH-003 | `PROMPT_BLOCKED` |
| `ARIA_SH_PII_IN_PROMPT_DETECTED` | BR-SH-012 | DM-SH-003 | `PII_IN_PROMPT` |
| `ARIA_SH_QUOTA_EXCEEDED` | BR-SH-010 | DM-SH-001 | `QUOTA_EXCEEDED` |
| `ARIA_SH_ALL_PROVIDERS_DOWN` | BR-SH-002 | DM-SH-005 | `PROVIDER_FAILOVER` |
| `ARIA_SH_CONTENT_FILTERED` | BR-SH-013 | DM-SH-004 | `CONTENT_FILTERED` |
| `ARIA_SH_EXFILTRATION_DETECTED` | BR-SH-014 | DM-SH-004 | `EXFILTRATION_ATTEMPT` |
| `ARIA_SH_QUOTA_SERVICE_UNAVAILABLE` | BR-SH-005 | DM-SH-006 | N/A |
| `ARIA_CN_*` (rollback) | BR-CN-003 | DM-CN-002 | `CANARY_ROLLBACK` |

---

*Document Version: 1.1.3 | Created: 2026-04-08 | Revised: 2026-04-25 (v1.1.3 spec-coherence sweep)*
*Source: BUSINESS_LOGIC.md v1.1.3, DECISION_MATRIX.md v1.0*
*Status: v1.1.3 Draft — Pending Human Approval (part of doc-set audit Wave 3)*
*Change log v1.0 → v1.1.3: Header reframes this Phase 2 doc as the business-rule-driven taxonomy with Phase 4 ERROR_CODES.md v1.1.1 as the canonical implementation registry (single source of truth for 84 codes). Added "Post-v1.0 additions" table covering 6 new codes (3 NER bridge per BR-MK-006, 2 shadow diff per BR-CN-007, 1 tokenizer fallback per Karar A). Added "Retired in v1.1.1" entry for `ARIA_RT_AUDIT_PIPELINE_NOT_WIRED` (FINDING-003 closure, ADR-009). Underlying §3 catalog rows from v1.0 baseline are intact and remain valid for the original 46 BR-driven codes.*
