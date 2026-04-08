# Error Code Registry — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 4 — Low-Level Design
**Version:** 1.0
**Date:** 2026-04-08
**Source:** EXCEPTION_CODES.md v1.0 (Phase 2), ERROR_HANDLING_GUIDELINE.md v3.0, OBSERVABILITY_GUIDELINE.md v4.0

---

## 1. Error Code Naming Convention

```
ARIA_{MODULE}_{ERROR_NAME}

Modules:
  SH  = Shield   (AI governance plugin)
  MK  = Mask     (Data privacy plugin)
  CN  = Canary   (Progressive delivery plugin)
  RT  = Runtime  (Java 21 sidecar)
  SYS = System   (Cross-cutting / catch-all)
```

**Guideline Category Mapping:**

The ERROR_HANDLING_GUIDELINE defines standard categories (`VAL_`, `BUS_`, `AUTH_`, `RES_`, `SYS_`, `EXT_`). Aria error codes use the `ARIA_{MODULE}_` prefix established in Phase 2 but map to those categories for consistency.

| Guideline Category | Aria Mapping | Examples |
|---|---|---|
| `VAL_` (Validation) | `ARIA_SH_INVALID_*`, `ARIA_CN_INVALID_*` | Client sent malformed input |
| `BUS_` (Business) | `ARIA_SH_QUOTA_*`, `ARIA_SH_*_DETECTED`, `ARIA_CN_ALREADY_*` | Valid input rejected by business rule |
| `AUTH_` (Auth) | `ARIA_SH_PROVIDER_AUTH_FAILED` | Provider key rejected |
| `RES_` (Resource) | `ARIA_CN_NO_ACTIVE_CANARY` | Entity does not exist |
| `SYS_` (System) | `ARIA_SYS_*`, `ARIA_MK_*` | Internal / infrastructure failures |
| `EXT_` (External) | `ARIA_SH_PROVIDER_*`, `ARIA_RT_*` | Third-party or sidecar failures |

**Rules:**

1. Codes are uppercase with underscores, no spaces.
2. Codes are stable across versions -- once assigned, a code is never reused for a different meaning.
3. Deprecated codes are kept in the registry with a `DEPRECATED` flag and removal target version.
4. New codes require a PR review that updates this registry.

---

## 2. Standard Error Response Format

### 2.1 Shield -- OpenAI-Compatible Envelope

Shield proxies OpenAI-compatible endpoints. Error responses follow the OpenAI error format with Aria extensions so that client SDKs (e.g., `openai-python`) can parse them natively.

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

### 2.2 Mask and Canary -- Aria Standard Envelope

Non-Shield errors use the standard API envelope from the API_DESIGN_GUIDELINE:

```json
{
  "success": false,
  "message": "No active canary deployment for route 'route-api-v2'.",
  "code": "ARIA_CN_NO_ACTIVE_CANARY",
  "data": null,
  "meta": {
    "traceId": "abc-123-xyz",
    "timestamp": "2026-04-08T12:00:00Z",
    "aria_request_id": "aria-req-d4e5f6"
  },
  "errors": []
}
```

### 2.3 Response Rules

| Rule | Rationale |
|---|---|
| `code` is machine-readable -- clients MUST switch on this field | Stable contract |
| `message` is human-readable -- MAY change between versions | UX flexibility |
| `details` contains structured context (optional, NEVER contains PII) | Debugging without leaking |
| `aria_request_id` is ALWAYS present | Trace correlation |
| Provider-specific error details are NEVER exposed to the client | Security -- prevents reconnaissance |
| Stack traces are NEVER included in client responses | Per ERROR_HANDLING_GUIDELINE Section 2.1 |

---

## 3. Error Code Catalog

### 3.1 Shield (ARIA_SH_*)

| Code | HTTP | Category | Log Level | Retry Strategy | Description | Business Rule | User Story |
|---|---|---|---|---|---|---|---|
| `ARIA_SH_INVALID_REQUEST_FORMAT` | 400 | VAL | WARN | Not retryable | Malformed request body (not valid OpenAI-compatible JSON) | BR-SH-001 | US-A01 |
| `ARIA_SH_INVALID_MODEL` | 400 | VAL | WARN | Not retryable | Requested model not recognized or not configured for this route | BR-SH-001 | US-A01 |
| `ARIA_SH_PII_IN_PROMPT_DETECTED` | 400 | BUS | WARN | Not retryable | PII detected in prompt and action is `block` | BR-SH-012 | US-A11 |
| `ARIA_SH_PROMPT_INJECTION_DETECTED` | 403 | BUS | WARN | Not retryable | Prompt injection pattern detected | BR-SH-011 | US-A10 |
| `ARIA_SH_QUOTA_EXCEEDED` | 402 | BUS | WARN | Not retryable (until quota resets) | Token or dollar quota exhausted (overage policy: block) | BR-SH-010 | US-A05, US-A09 |
| `ARIA_SH_QUOTA_THROTTLED` | 429 | BUS | WARN | Retry after delay (`Retry-After` header) | Quota exhausted, throttle window active | BR-SH-010 | US-A09 |
| `ARIA_SH_PROVIDER_AUTH_FAILED` | 502 | EXT | ERROR | Not retryable | Provider rejected API key (401/403 from provider) | BR-SH-001 | US-A01 |
| `ARIA_SH_PROVIDER_RATE_LIMITED` | 429 | EXT | WARN | Retry after delay (`Retry-After` header) | Provider rate limit hit after retries exhausted | INT-001 | US-A01 |
| `ARIA_SH_PROVIDER_ERROR` | 502 | EXT | ERROR | Retry immediately (exponential backoff) | Provider returned 5xx error | BR-SH-002 | US-A02 |
| `ARIA_SH_PROVIDER_TIMEOUT` | 504 | EXT | ERROR | Retry immediately (exponential backoff) | Provider did not respond within timeout | BR-SH-002 | US-A02 |
| `ARIA_SH_PROVIDER_UNREACHABLE` | 502 | EXT | ERROR | Retry immediately (exponential backoff) | Could not connect to provider endpoint | BR-SH-001 | US-A01 |
| `ARIA_SH_ALL_PROVIDERS_DOWN` | 503 | EXT | ERROR | Retry after recovery | All providers (primary + fallbacks) unavailable, circuit breakers open | BR-SH-002 | US-A02 |
| `ARIA_SH_PROVIDER_NOT_CONFIGURED` | 500 | SYS | ERROR | Not retryable | Route has no provider configured (configuration error) | BR-SH-001 | US-A01 |
| `ARIA_SH_CONTENT_FILTERED` | 422 | BUS | WARN | Not retryable | LLM response was filtered for harmful content | BR-SH-013 | US-A12 |
| `ARIA_SH_EXFILTRATION_DETECTED` | 422 | BUS | WARN | Not retryable | Response contains suspected data exfiltration | BR-SH-014 | US-A13 |
| `ARIA_SH_STREAM_INTERRUPTED` | 502 | EXT | ERROR | Retry immediately | SSE stream from provider terminated unexpectedly | BR-SH-003 | US-A03 |
| `ARIA_SH_QUOTA_SERVICE_UNAVAILABLE` | 503 | SYS | ERROR | Retry after recovery | Redis unavailable and fail policy is `fail_closed` | BR-SH-005 | US-A05 |

### 3.2 Mask (ARIA_MK_*)

| Code | HTTP | Category | Log Level | Retry Strategy | Description | Business Rule | User Story |
|---|---|---|---|---|---|---|---|
| `ARIA_MK_MASKING_ENGINE_ERROR` | 500 | SYS | ERROR | Retry immediately | Internal error during response masking | BR-MK-001 | US-B01 |
| `ARIA_MK_INVALID_JSONPATH` | 500 | SYS | ERROR | Not retryable | Configured JSONPath expression is invalid (configuration error) | BR-MK-001 | US-B01 |
| `ARIA_MK_TOKENIZE_UNAVAILABLE` | 500 | SYS | ERROR | Retry after recovery | Redis unavailable for tokenization (fallback to redact) | BR-MK-004 | US-B04 |

**Note:** Most Mask errors are transparent to the client. The response is either masked correctly or passed through with degraded masking. These codes are used for internal monitoring and logging only.

### 3.3 Canary (ARIA_CN_*)

| Code | HTTP | Category | Log Level | Retry Strategy | Description | Business Rule | User Story |
|---|---|---|---|---|---|---|---|
| `ARIA_CN_NO_ACTIVE_CANARY` | 404 | RES | WARN | Not retryable | No active canary deployment for this route | BR-CN-005 | US-C05 |
| `ARIA_CN_CANARY_UPSTREAM_UNHEALTHY` | 503 | EXT | ERROR | Retry after recovery | Canary upstream has no healthy targets | BR-CN-001 | US-C01 |
| `ARIA_CN_INVALID_SCHEDULE` | 400 | VAL | WARN | Not retryable | Canary schedule is malformed (percentages not ascending, last stage != 100%) | BR-CN-001 | US-C01 |
| `ARIA_CN_ALREADY_PROMOTED` | 409 | BUS | WARN | Not retryable | Canary is already promoted to 100% | BR-CN-005 | US-C05 |
| `ARIA_CN_ALREADY_ROLLED_BACK` | 409 | BUS | WARN | Not retryable | Canary is already rolled back to 0% | BR-CN-005 | US-C05 |

### 3.4 Runtime / Sidecar (ARIA_RT_*)

Runtime errors use gRPC status codes (the sidecar communicates with Lua plugins over Unix Domain Socket / gRPC).

| Code | gRPC Status | Category | Log Level | Retry Strategy | Description | Business Rule | User Story |
|---|---|---|---|---|---|---|---|
| `ARIA_RT_SIDECAR_UNAVAILABLE` | UNAVAILABLE (14) | EXT | ERROR | Retry immediately | Sidecar process not running or UDS unreachable | BR-RT-001 | US-S01 |
| `ARIA_RT_RESOURCE_EXHAUSTED` | RESOURCE_EXHAUSTED (8) | SYS | ERROR | Retry after delay (backoff) | Sidecar virtual thread pool exhausted | BR-RT-002 | US-S02 |
| `ARIA_RT_HANDLER_NOT_FOUND` | UNIMPLEMENTED (12) | VAL | WARN | Not retryable | Requested gRPC method not registered in sidecar | BR-RT-001 | US-S01 |
| `ARIA_RT_DEPENDENCY_UNAVAILABLE` | UNAVAILABLE (14) | EXT | ERROR | Retry after recovery | Sidecar dependency (Redis/Postgres) unreachable | BR-RT-003 | US-S03 |

### 3.5 System-Wide (ARIA_SYS_*)

| Code | HTTP | Category | Log Level | Retry Strategy | Description | Business Rule | User Story |
|---|---|---|---|---|---|---|---|
| `ARIA_SYS_INTERNAL_ERROR` | 500 | SYS | ERROR | Retry immediately | Unexpected plugin error (catch-all) | N/A | N/A |
| `ARIA_SYS_CONFIG_INVALID` | 500 | SYS | ERROR | Not retryable | Plugin configuration is invalid | N/A | N/A |

---

## 4. Java Exception Class Hierarchy (Sidecar)

The Java 21 sidecar uses a single exception hierarchy rooted at `AriaException`. All exceptions are unchecked (`RuntimeException`) to work cleanly with virtual threads and gRPC interceptors.

```
RuntimeException
  └── AriaException                          (abstract base)
        ├── AriaValidationException          (VAL_ codes, maps to INVALID_ARGUMENT)
        ├── AriaBusinessException            (BUS_ codes, maps to FAILED_PRECONDITION)
        │     ├── AriaQuotaExceededException
        │     └── AriaSecurityViolationException
        ├── AriaResourceException            (RES_ codes, maps to NOT_FOUND / ALREADY_EXISTS)
        ├── AriaExternalException            (EXT_ codes, maps to UNAVAILABLE / DEADLINE_EXCEEDED)
        │     ├── AriaProviderException
        │     └── AriaDependencyException
        └── AriaSystemException              (SYS_ codes, maps to INTERNAL)
              └── AriaConfigException
```

### 4.1 Base Exception

```java
package com.threeai.aria.gatekeeper.exception;

/**
 * Abstract base for all Aria sidecar exceptions.
 * <p>
 * Every subclass carries a stable {@code ariaCode} (e.g., "ARIA_SH_QUOTA_EXCEEDED"),
 * a gRPC status mapping, an HTTP status mapping, and a retry indicator.
 */
public abstract class AriaException extends RuntimeException {

    private final String ariaCode;
    private final int httpStatus;
    private final io.grpc.Status.Code grpcStatus;
    private final boolean retryable;
    private final Map<String, Object> details;

    protected AriaException(String ariaCode,
                            String message,
                            int httpStatus,
                            io.grpc.Status.Code grpcStatus,
                            boolean retryable,
                            Map<String, Object> details,
                            Throwable cause) {
        super(message, cause);
        this.ariaCode = ariaCode;
        this.httpStatus = httpStatus;
        this.grpcStatus = grpcStatus;
        this.retryable = retryable;
        this.details = details != null ? Map.copyOf(details) : Map.of();
    }

    public String getAriaCode()                 { return ariaCode; }
    public int getHttpStatus()                  { return httpStatus; }
    public io.grpc.Status.Code getGrpcStatus()  { return grpcStatus; }
    public boolean isRetryable()                { return retryable; }
    public Map<String, Object> getDetails()     { return details; }
}
```

### 4.2 Concrete Subclasses (Selected)

```java
/** Validation errors — client sent bad input. */
public class AriaValidationException extends AriaException {
    public AriaValidationException(String ariaCode, String message) {
        super(ariaCode, message, 400, Status.Code.INVALID_ARGUMENT, false, null, null);
    }
}

/** Business rule violations — input valid but rejected by policy. */
public class AriaBusinessException extends AriaException {
    public AriaBusinessException(String ariaCode, String message,
                                  int httpStatus, boolean retryable,
                                  Map<String, Object> details) {
        super(ariaCode, message, httpStatus, Status.Code.FAILED_PRECONDITION,
              retryable, details, null);
    }
}

/** Quota exceeded — specialization of business exception. */
public class AriaQuotaExceededException extends AriaBusinessException {
    public AriaQuotaExceededException(String ariaCode, String message,
                                      int httpStatus, boolean retryable,
                                      Map<String, Object> details) {
        super(ariaCode, message, httpStatus, retryable, details);
    }
}

/** External service failures (providers, dependencies). */
public class AriaExternalException extends AriaException {
    public AriaExternalException(String ariaCode, String message,
                                  int httpStatus,
                                  io.grpc.Status.Code grpcStatus,
                                  boolean retryable,
                                  Throwable cause) {
        super(ariaCode, message, httpStatus, grpcStatus, retryable, null, cause);
    }
}

/** System / infrastructure errors. */
public class AriaSystemException extends AriaException {
    public AriaSystemException(String ariaCode, String message, Throwable cause) {
        super(ariaCode, message, 500, Status.Code.INTERNAL, true, null, cause);
    }
}

/** Configuration errors — not retryable. */
public class AriaConfigException extends AriaSystemException {
    public AriaConfigException(String ariaCode, String message) {
        super(ariaCode, message, null);
    }

    @Override
    public boolean isRetryable() { return false; }
}
```

### 4.3 gRPC Exception Interceptor

All `AriaException` instances are translated to gRPC status responses by a server interceptor:

```java
public class AriaGrpcExceptionInterceptor implements ServerInterceptor {
    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call,
            Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {

        return new ForwardingServerCallListener.SimpleForwardingServerCallListener<>(
                next.startCall(call, headers)) {
            @Override
            public void onHalfClose() {
                try {
                    super.onHalfClose();
                } catch (AriaException e) {
                    Metadata trailers = new Metadata();
                    trailers.put(ARIA_CODE_KEY, e.getAriaCode());
                    trailers.put(ARIA_RETRYABLE_KEY, String.valueOf(e.isRetryable()));
                    call.close(
                        e.getGrpcStatus().toStatus().withDescription(e.getMessage()),
                        trailers
                    );
                }
            }
        };
    }
}
```

---

## 5. Lua Error Table Structure

APISIX Lua plugins use a standard error table passed to `core.response.exit()` or returned from sidecar gRPC calls.

### 5.1 Error Table Schema

```lua
-- Standard Aria error table
local aria_error = {
    type       = "aria_error",           -- constant
    code       = "ARIA_SH_QUOTA_EXCEEDED",
    message    = "Daily token quota exceeded for consumer 'team-a'.",
    request_id = ctx.var.aria_request_id, -- from request context
    details    = {                        -- optional, never contains PII
        consumer_id   = "team-a",
        quota_type    = "daily_tokens",
        quota_limit   = 100000,
        quota_used    = 100247,
        resets_at     = "2026-04-09T00:00:00Z",
        overage_policy = "block",
    },
}
```

### 5.2 Error Return Helper

```lua
local _M = {}

--- Build and return an Aria error response.
-- @param ctx       APISIX request context
-- @param http_code HTTP status code
-- @param aria_code Aria error code (e.g., "ARIA_SH_QUOTA_EXCEEDED")
-- @param message   Human-readable message
-- @param details   Optional table of structured details (no PII)
function _M.exit_with_error(ctx, http_code, aria_code, message, details)
    local body = {
        error = {
            type           = "aria_error",
            code           = aria_code,
            message        = message,
            aria_request_id = ctx.var.aria_request_id,
            details        = details or {},
        }
    }

    core.log.warn("aria_error: ", aria_code,
                  " request_id=", ctx.var.aria_request_id,
                  " consumer=", ctx.var.consumer_name or "unknown")

    return core.response.exit(http_code, body)
end

--- Translate a gRPC error from the sidecar into an HTTP Aria error.
-- @param ctx        APISIX request context
-- @param grpc_err   gRPC error table from lua-resty-grpc
function _M.exit_from_grpc_error(ctx, grpc_err)
    local aria_code = grpc_err.trailers and grpc_err.trailers["aria-code"]
                      or "ARIA_SYS_INTERNAL_ERROR"
    local http_code = grpc_status_to_http(grpc_err.code)
    return _M.exit_with_error(ctx, http_code, aria_code, grpc_err.message)
end

return _M
```

### 5.3 gRPC-to-HTTP Status Mapping

```lua
local grpc_to_http = {
    [0]  = 200,  -- OK
    [1]  = 499,  -- CANCELLED
    [2]  = 500,  -- UNKNOWN
    [3]  = 400,  -- INVALID_ARGUMENT
    [4]  = 504,  -- DEADLINE_EXCEEDED
    [5]  = 404,  -- NOT_FOUND
    [6]  = 409,  -- ALREADY_EXISTS
    [7]  = 403,  -- PERMISSION_DENIED
    [8]  = 429,  -- RESOURCE_EXHAUSTED
    [13] = 500,  -- INTERNAL
    [12] = 501,  -- UNIMPLEMENTED
    [14] = 503,  -- UNAVAILABLE
    [16] = 401,  -- UNAUTHENTICATED
}
```

---

## 6. Error Logging Rules

Per OBSERVABILITY_GUIDELINE v4.0 Section 2.2 and ERROR_HANDLING_GUIDELINE v3.0 Section 6.

### 6.1 Log Level Assignment

| Error Category | Log Level | Rationale |
|---|---|---|
| Validation (`VAL_`) | WARN | Client mistake, not system failure |
| Business rule (`BUS_`) | WARN | Expected behavior -- policy enforced correctly |
| Resource not found (`RES_`) | WARN | Client asked for something that does not exist |
| External service error (`EXT_`) | ERROR | Requires engineering attention |
| System / infrastructure (`SYS_`) | ERROR | Unexpected failure, requires investigation |

**Key rule from ERROR_HANDLING_GUIDELINE:** Business rule violations are WARN, never ERROR. ERROR fires only for conditions that require engineering attention.

### 6.2 Structured Log Fields

Every error log entry MUST include the following fields (per OBSERVABILITY_GUIDELINE Section 2.1):

```json
{
  "timestamp": "2026-04-08T14:30:00.123Z",
  "level": "WARN",
  "service": "aria-shield",
  "trace_id": "abc-123-def-456",
  "span_id": "xyz-789",
  "message": "Quota exceeded",
  "aria_code": "ARIA_SH_QUOTA_EXCEEDED",
  "aria_request_id": "aria-req-7f3a2b",
  "consumer_id": "team-a",
  "route_id": "route-openai-v1",
  "context": {
    "quota_type": "daily_tokens",
    "quota_limit": 100000,
    "quota_used": 100247
  }
}
```

### 6.3 What to Include per Log Level

| Level | Required Fields | Additional Context |
|---|---|---|
| WARN | `aria_code`, `aria_request_id`, `consumer_id`, `route_id`, `trace_id` | Business context (quota details, detection source, etc.) |
| ERROR | All WARN fields + `error_message`, `error_class` | Stack trace (Java sidecar), upstream response code, circuit breaker state |

### 6.4 What NEVER to Log

| Forbidden | Rationale |
|---|---|
| API keys, tokens, secrets | Security -- credential leak |
| Full prompt content | Data governance -- may contain PII |
| Provider-specific internal error details | Security -- prevents reconnaissance |
| PII values detected by Mask | Data governance -- defeats masking purpose |

---

## 7. Recovery Patterns per Error Category

### 7.1 Not Retryable

Errors where the client must fix the request before retrying.

| Code Pattern | Client Action |
|---|---|
| `ARIA_SH_INVALID_REQUEST_FORMAT` | Fix the request body format |
| `ARIA_SH_INVALID_MODEL` | Use a model configured for this route |
| `ARIA_SH_PII_IN_PROMPT_DETECTED` | Remove PII from the prompt |
| `ARIA_SH_PROMPT_INJECTION_DETECTED` | Modify prompt content |
| `ARIA_SH_QUOTA_EXCEEDED` | Wait for quota reset (daily/monthly boundary) or request increase |
| `ARIA_SH_PROVIDER_AUTH_FAILED` | Verify provider API key configuration (ops action) |
| `ARIA_SH_PROVIDER_NOT_CONFIGURED` | Configure provider in route metadata (ops action) |
| `ARIA_SH_CONTENT_FILTERED` | Modify prompt to avoid harmful output |
| `ARIA_SH_EXFILTRATION_DETECTED` | Review prompt for extraction attempts |
| `ARIA_MK_INVALID_JSONPATH` | Fix masking rule configuration (ops action) |
| `ARIA_CN_NO_ACTIVE_CANARY` | Deploy a canary first |
| `ARIA_CN_INVALID_SCHEDULE` | Fix canary schedule configuration |
| `ARIA_CN_ALREADY_PROMOTED` | No action needed -- deployment is complete |
| `ARIA_CN_ALREADY_ROLLED_BACK` | Re-deploy to try again |
| `ARIA_RT_HANDLER_NOT_FOUND` | Check sidecar module configuration |
| `ARIA_SYS_CONFIG_INVALID` | Fix plugin configuration (ops action) |

### 7.2 Retry Immediately (Exponential Backoff)

Transient errors where the same request can be retried with backoff.

| Attempt | Wait | Total Elapsed |
|---|---|---|
| 1 | 0s (immediate) | 0s |
| 2 | 1s + jitter | ~1s |
| 3 | 2s + jitter | ~3s |
| 4 | 4s + jitter | ~7s |
| 5 | Give up, return error | ~7s |

**Applies to:** `ARIA_SH_PROVIDER_ERROR`, `ARIA_SH_PROVIDER_TIMEOUT`, `ARIA_SH_PROVIDER_UNREACHABLE`, `ARIA_SH_STREAM_INTERRUPTED`, `ARIA_MK_MASKING_ENGINE_ERROR`, `ARIA_RT_SIDECAR_UNAVAILABLE`, `ARIA_SYS_INTERNAL_ERROR`

**Jitter formula:** `wait = baseDelay * 2^attempt + random(0, 1s)` to prevent thundering herd.

### 7.3 Retry After Delay (Retry-After Header)

Rate-limited or throttled errors. The response includes a `Retry-After` header with seconds to wait.

**Applies to:** `ARIA_SH_QUOTA_THROTTLED`, `ARIA_SH_PROVIDER_RATE_LIMITED`

Client behavior:
1. Read `Retry-After` header value (seconds).
2. Wait the specified duration.
3. Retry the exact same request.
4. If still throttled, follow the new `Retry-After` value.

### 7.4 Retry After Recovery (Infrastructure Recovery)

Infrastructure-level failures where ops intervention may be required. Clients should use long polling or exponential backoff with large intervals.

**Applies to:** `ARIA_SH_ALL_PROVIDERS_DOWN`, `ARIA_SH_QUOTA_SERVICE_UNAVAILABLE`, `ARIA_MK_TOKENIZE_UNAVAILABLE`, `ARIA_CN_CANARY_UPSTREAM_UNHEALTHY`, `ARIA_RT_DEPENDENCY_UNAVAILABLE`

Recovery pattern:
1. Return 503 with `Retry-After: 30` (suggested initial wait).
2. Client retries with exponential backoff starting at 30s, max 5 min.
3. Circuit breaker transitions to HALF_OPEN after configured duration (default 30s).
4. If health check succeeds, circuit transitions to CLOSED.

### 7.5 Circuit Breaker Configuration

Per ERROR_HANDLING_GUIDELINE Section 4.2, circuit breaker is mandatory for all external service calls.

```
Component              Failure Threshold    Open Duration    Success Threshold
Provider (per-provider)     5 consecutive       30s              3 consecutive
Sidecar (UDS)               3 consecutive       10s              2 consecutive
Redis                       5 consecutive       15s              3 consecutive
```

---

## 8. Alerting Rules

Per OBSERVABILITY_GUIDELINE v4.0 Section 5.

### 8.1 Alert Severity Mapping

| Severity | Response Time | Channel | Aria Error Codes |
|---|---|---|---|
| **critical** | Immediate (< 5 min) | PagerDuty + Slack | `ARIA_SH_ALL_PROVIDERS_DOWN`, `ARIA_RT_SIDECAR_UNAVAILABLE` (sustained > 5 min), `ARIA_SYS_INTERNAL_ERROR` (rate > 10/min) |
| **warning** | Within 1 hour | Slack only | `ARIA_SH_QUOTA_SERVICE_UNAVAILABLE`, `ARIA_SH_PROVIDER_AUTH_FAILED`, `ARIA_CN_CANARY_UPSTREAM_UNHEALTHY`, `ARIA_MK_TOKENIZE_UNAVAILABLE`, `ARIA_RT_DEPENDENCY_UNAVAILABLE` |
| **info** | Next business day | Dashboard only | `ARIA_SH_QUOTA_EXCEEDED` (rate spike), `ARIA_SH_PROMPT_INJECTION_DETECTED`, `ARIA_SH_PII_IN_PROMPT_DETECTED`, `ARIA_SH_CONTENT_FILTERED`, `ARIA_SH_EXFILTRATION_DETECTED` |

### 8.2 PrometheusRule Definitions

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: aria-gatekeeper-alerts
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
    # ── Critical: All Providers Down ──
    - name: aria.shield.availability
      rules:
        - alert: AriaAllProvidersDown
          expr: |
            increase(aria_errors_total{code="ARIA_SH_ALL_PROVIDERS_DOWN"}[5m]) > 0
          for: 2m
          labels:
            severity: critical
            component: aria-shield
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "All LLM providers are unavailable"
            description: "ARIA_SH_ALL_PROVIDERS_DOWN fired {{ $value }} times in 5m in namespace {{ $labels.namespace }}."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-all-providers-down"

    # ── Critical: Sidecar Down ──
    - name: aria.runtime.availability
      rules:
        - alert: AriaSidecarUnavailable
          expr: |
            increase(aria_errors_total{code="ARIA_RT_SIDECAR_UNAVAILABLE"}[5m]) > 5
          for: 5m
          labels:
            severity: critical
            component: aria-sidecar
            namespace: "{{ $labels.namespace }}"
            remediation: restart_pod
          annotations:
            summary: "Aria sidecar is unreachable for over 5 minutes"
            description: "ARIA_RT_SIDECAR_UNAVAILABLE sustained for 5m in namespace {{ $labels.namespace }}."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-sidecar-unavailable"

    # ── Critical: Internal Error Spike ──
        - alert: AriaInternalErrorSpike
          expr: |
            rate(aria_errors_total{code="ARIA_SYS_INTERNAL_ERROR"}[5m]) > 0.17
          for: 3m
          labels:
            severity: critical
            component: aria-gatekeeper
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "Aria internal error rate exceeds 10/min"
            description: "ARIA_SYS_INTERNAL_ERROR rate is {{ $value }}/s in namespace {{ $labels.namespace }}."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-internal-error-spike"

    # ── Warning: Provider Auth Failed ──
    - name: aria.shield.config
      rules:
        - alert: AriaProviderAuthFailed
          expr: |
            increase(aria_errors_total{code="ARIA_SH_PROVIDER_AUTH_FAILED"}[10m]) > 0
          for: 1m
          labels:
            severity: warning
            component: aria-shield
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "LLM provider rejected API key"
            description: "ARIA_SH_PROVIDER_AUTH_FAILED in namespace {{ $labels.namespace }}. Verify provider credentials."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-provider-auth-failed"

    # ── Warning: Quota Service Down ──
        - alert: AriaQuotaServiceUnavailable
          expr: |
            increase(aria_errors_total{code="ARIA_SH_QUOTA_SERVICE_UNAVAILABLE"}[5m]) > 0
          for: 2m
          labels:
            severity: warning
            component: aria-shield
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "Quota service (Redis) is unavailable"
            description: "ARIA_SH_QUOTA_SERVICE_UNAVAILABLE in namespace {{ $labels.namespace }}. Requests are being blocked (fail_closed)."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-quota-service-unavailable"

    # ── Warning: Canary Upstream Unhealthy ──
    - name: aria.canary.health
      rules:
        - alert: AriaCanaryUpstreamUnhealthy
          expr: |
            increase(aria_errors_total{code="ARIA_CN_CANARY_UPSTREAM_UNHEALTHY"}[5m]) > 0
          for: 2m
          labels:
            severity: warning
            component: aria-canary
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "Canary upstream has no healthy targets"
            description: "ARIA_CN_CANARY_UPSTREAM_UNHEALTHY in namespace {{ $labels.namespace }}."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-canary-upstream-unhealthy"

    # ── Warning: Dependency Unavailable ──
    - name: aria.runtime.dependencies
      rules:
        - alert: AriaDependencyUnavailable
          expr: |
            increase(aria_errors_total{code="ARIA_RT_DEPENDENCY_UNAVAILABLE"}[5m]) > 3
          for: 3m
          labels:
            severity: warning
            component: aria-sidecar
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "Sidecar dependency (Redis/Postgres) is unreachable"
            description: "ARIA_RT_DEPENDENCY_UNAVAILABLE fired {{ $value }} times in 5m in namespace {{ $labels.namespace }}."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-dependency-unavailable"

    # ── Info: Security Event Rate ──
    - name: aria.shield.security
      rules:
        - alert: AriaSecurityEventSpike
          expr: |
            sum(rate(aria_security_events_total[10m])) > 1
          for: 5m
          labels:
            severity: info
            component: aria-shield
            namespace: "{{ $labels.namespace }}"
          annotations:
            summary: "Elevated security event rate (injection / PII / exfiltration)"
            description: "Security events at {{ $value }}/s for 5m in namespace {{ $labels.namespace }}."
            runbook_url: "https://runbooks.3eai.com/alerts/aria-security-event-spike"
```

### 8.3 Prometheus Metric Mapping

| Metric | Type | Labels | Description |
|---|---|---|---|
| `aria_errors_total` | Counter | `module`, `code`, `consumer`, `route` | Total error count by code |
| `aria_errors_by_severity` | Counter | `severity` | Errors by severity (critical/warning/info) |
| `aria_provider_errors_total` | Counter | `provider`, `error_type` | Provider-specific errors |
| `aria_security_events_total` | Counter | `event_type` | Security events (injection, PII, exfiltration) |
| `aria_quota_rejections_total` | Counter | `consumer`, `quota_type`, `policy` | Quota rejections by consumer and policy |

---

## 9. Traceability Matrix

### 9.1 Error Code to Business Rule and User Story

| Error Code | Business Rule | User Story | Decision Matrix | Audit Event Type |
|---|---|---|---|---|
| `ARIA_SH_INVALID_REQUEST_FORMAT` | BR-SH-001 | US-A01 | -- | -- |
| `ARIA_SH_INVALID_MODEL` | BR-SH-001 | US-A01 | -- | -- |
| `ARIA_SH_PII_IN_PROMPT_DETECTED` | BR-SH-012 | US-A11 | DM-SH-003 | `PII_IN_PROMPT` |
| `ARIA_SH_PROMPT_INJECTION_DETECTED` | BR-SH-011 | US-A10 | DM-SH-003 | `PROMPT_BLOCKED` |
| `ARIA_SH_QUOTA_EXCEEDED` | BR-SH-010 | US-A05, US-A09 | DM-SH-001 | `QUOTA_EXCEEDED` |
| `ARIA_SH_QUOTA_THROTTLED` | BR-SH-010 | US-A09 | DM-SH-001 | `QUOTA_THROTTLED` |
| `ARIA_SH_PROVIDER_AUTH_FAILED` | BR-SH-001 | US-A01 | -- | -- |
| `ARIA_SH_PROVIDER_RATE_LIMITED` | INT-001 | US-A01 | -- | -- |
| `ARIA_SH_PROVIDER_ERROR` | BR-SH-002 | US-A02 | -- | `PROVIDER_FAILOVER` |
| `ARIA_SH_PROVIDER_TIMEOUT` | BR-SH-002 | US-A02 | -- | `PROVIDER_FAILOVER` |
| `ARIA_SH_PROVIDER_UNREACHABLE` | BR-SH-001 | US-A01 | -- | `PROVIDER_FAILOVER` |
| `ARIA_SH_ALL_PROVIDERS_DOWN` | BR-SH-002 | US-A02 | DM-SH-005 | `PROVIDER_FAILOVER` |
| `ARIA_SH_PROVIDER_NOT_CONFIGURED` | BR-SH-001 | US-A01 | -- | -- |
| `ARIA_SH_CONTENT_FILTERED` | BR-SH-013 | US-A12 | DM-SH-004 | `CONTENT_FILTERED` |
| `ARIA_SH_EXFILTRATION_DETECTED` | BR-SH-014 | US-A13 | DM-SH-004 | `EXFILTRATION_ATTEMPT` |
| `ARIA_SH_STREAM_INTERRUPTED` | BR-SH-003 | US-A03 | -- | -- |
| `ARIA_SH_QUOTA_SERVICE_UNAVAILABLE` | BR-SH-005 | US-A05 | DM-SH-006 | -- |
| `ARIA_MK_MASKING_ENGINE_ERROR` | BR-MK-001 | US-B01 | -- | -- |
| `ARIA_MK_INVALID_JSONPATH` | BR-MK-001 | US-B01 | -- | -- |
| `ARIA_MK_TOKENIZE_UNAVAILABLE` | BR-MK-004 | US-B04 | -- | -- |
| `ARIA_CN_NO_ACTIVE_CANARY` | BR-CN-005 | US-C05 | -- | -- |
| `ARIA_CN_CANARY_UPSTREAM_UNHEALTHY` | BR-CN-001 | US-C01 | -- | -- |
| `ARIA_CN_INVALID_SCHEDULE` | BR-CN-001 | US-C01 | -- | -- |
| `ARIA_CN_ALREADY_PROMOTED` | BR-CN-005 | US-C05 | -- | -- |
| `ARIA_CN_ALREADY_ROLLED_BACK` | BR-CN-005 | US-C05 | -- | -- |
| `ARIA_RT_SIDECAR_UNAVAILABLE` | BR-RT-001 | US-S01 | -- | -- |
| `ARIA_RT_RESOURCE_EXHAUSTED` | BR-RT-002 | US-S02 | -- | -- |
| `ARIA_RT_HANDLER_NOT_FOUND` | BR-RT-001 | US-S01 | -- | -- |
| `ARIA_RT_DEPENDENCY_UNAVAILABLE` | BR-RT-003 | US-S03 | -- | -- |
| `ARIA_SYS_INTERNAL_ERROR` | N/A | N/A | -- | -- |
| `ARIA_SYS_CONFIG_INVALID` | N/A | N/A | -- | -- |

### 9.2 Cross-Reference to Design Documents

| Document | Relevance |
|---|---|
| `docs/02_business/EXCEPTION_CODES.md` | Phase 2 origin of all error codes |
| `docs/02_business/BUSINESS_LOGIC.md` | Business rules (BR-*) referenced in this registry |
| `docs/02_business/DECISION_MATRIX.md` | Decision matrix entries (DM-*) |
| `guidelines/ERROR_HANDLING_GUIDELINE.md` | Error taxonomy, recovery patterns, logging rules |
| `guidelines/OBSERVABILITY_GUIDELINE.md` | Log format, metrics, alerting standards |
| `guidelines/API_DESIGN_GUIDELINE.md` | Error response envelope format |

---

*Document Version: 1.0 | Created: 2026-04-08*
*Source: EXCEPTION_CODES.md v1.0, ERROR_HANDLING_GUIDELINE.md v3.0, OBSERVABILITY_GUIDELINE.md v4.0*
*Status: Draft*
