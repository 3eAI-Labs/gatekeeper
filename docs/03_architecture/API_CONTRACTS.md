# API Contracts — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 3 — Architecture
**Version:** 1.0
**Date:** 2026-04-08

---

## 1. Shield — OpenAI-Compatible REST API

### 1.1 Chat Completions

**Endpoint:** `POST /v1/chat/completions`
**Auth:** APISIX consumer authentication (key-auth, JWT, etc.)
**Content-Type:** `application/json`

#### Request

```json
{
  "model": "gpt-4o",
  "messages": [
    { "role": "system", "content": "You are a helpful assistant." },
    { "role": "user", "content": "Hello, world!" }
  ],
  "temperature": 0.7,
  "max_tokens": 1024,
  "top_p": 1.0,
  "stream": false,
  "n": 1
}
```

| Field | Type | Required | Validation | Notes |
|-------|------|----------|-----------|-------|
| `model` | string | Yes | 1-256 chars, non-empty | Mapped to provider-specific model |
| `messages` | array | Yes | 1-1000 items | Each item: `{role, content}` |
| `messages[].role` | string | Yes | `system`, `user`, `assistant` | |
| `messages[].content` | string | Yes | Non-empty | Subject to PII scan (BR-SH-012) |
| `temperature` | float | No | 0.0-2.0 | Default: 1.0 |
| `max_tokens` | int | No | 1 to model max | Default: model-specific |
| `top_p` | float | No | 0.0-1.0 | Default: 1.0 |
| `stream` | bool | No | — | Default: false |
| `n` | int | No | 1-10 | Default: 1 |

#### Response (Non-Streaming)

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1712592600,
  "model": "gpt-4o-2024-11-20",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 12,
    "total_tokens": 37
  }
}
```

#### Aria Response Headers

| Header | Type | Description |
|--------|------|-------------|
| `X-Aria-Provider` | string | Actual provider used (e.g., `openai`, `anthropic`) |
| `X-Aria-Model` | string | Actual model version used |
| `X-Aria-Tokens-Input` | int | Input tokens consumed |
| `X-Aria-Tokens-Output` | int | Output tokens consumed |
| `X-Aria-Quota-Remaining` | int | Remaining token quota (if configured) |
| `X-Aria-Budget-Remaining` | string | Remaining dollar budget (e.g., `423.50`) |
| `X-Aria-Request-Id` | string | Unique request ID for tracing |

#### Response (Streaming: `stream: true`)

```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1712592600,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1712592600,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1712592600,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":25,"completion_tokens":2,"total_tokens":27}}

data: [DONE]
```

#### Error Responses

| HTTP Status | Aria Code | When |
|------------|-----------|------|
| 400 | `ARIA_SH_INVALID_REQUEST_FORMAT` | Malformed request body |
| 400 | `ARIA_SH_PII_IN_PROMPT_DETECTED` | PII found, action=block |
| 402 | `ARIA_SH_QUOTA_EXCEEDED` | Quota exhausted, policy=block |
| 403 | `ARIA_SH_PROMPT_INJECTION_DETECTED` | Injection pattern detected |
| 429 | `ARIA_SH_QUOTA_THROTTLED` | Quota exhausted, policy=throttle |
| 429 | `ARIA_SH_PROVIDER_RATE_LIMITED` | Provider rate limit |
| 502 | `ARIA_SH_PROVIDER_ERROR` | Provider 5xx |
| 503 | `ARIA_SH_ALL_PROVIDERS_DOWN` | All providers unavailable |
| 504 | `ARIA_SH_PROVIDER_TIMEOUT` | Provider timeout |

---

## 2. Canary — Admin API Extensions

Base URL: `http://apisix-admin:9180` (APISIX Admin API)

### 2.1 Get Canary Status

```
GET /aria/canary/{route_id}/status
Authorization: APISIX Admin API key
```

**Response (200):**
```json
{
  "route_id": "route-api-v2",
  "state": "STAGE_2",
  "current_stage_index": 1,
  "traffic_pct": 10,
  "stage_started_at": "2026-04-08T14:00:00Z",
  "hold_remaining_seconds": 180,
  "schedule": [
    { "pct": 5, "hold": "5m" },
    { "pct": 10, "hold": "5m" },
    { "pct": 25, "hold": "10m" },
    { "pct": 50, "hold": "10m" },
    { "pct": 100, "hold": "0" }
  ],
  "canary_error_rate": 0.008,
  "baseline_error_rate": 0.005,
  "canary_latency_p95_ms": 245,
  "baseline_latency_p95_ms": 210,
  "retry_count": 0,
  "retry_policy": "manual",
  "canary_upstream": "upstream-v2",
  "baseline_upstream": "upstream-v1"
}
```

**Response (404):**
```json
{
  "error": {
    "type": "aria_error",
    "code": "ARIA_CN_NO_ACTIVE_CANARY",
    "message": "No active canary deployment for route 'route-api-v2'"
  }
}
```

### 2.2 Promote Canary

```
POST /aria/canary/{route_id}/promote
Authorization: APISIX Admin API key
```

**Response (200):**
```json
{
  "route_id": "route-api-v2",
  "state": "PROMOTED",
  "traffic_pct": 100,
  "promoted_at": "2026-04-08T14:35:00Z",
  "promoted_by": "operator:admin-1"
}
```

### 2.3 Rollback Canary

```
POST /aria/canary/{route_id}/rollback
Authorization: APISIX Admin API key
```

**Response (200):**
```json
{
  "route_id": "route-api-v2",
  "state": "ROLLED_BACK",
  "traffic_pct": 0,
  "rolled_back_at": "2026-04-08T14:35:00Z",
  "rolled_back_by": "operator:admin-1"
}
```

### 2.4 Pause / Resume

```
POST /aria/canary/{route_id}/pause
POST /aria/canary/{route_id}/resume
Authorization: APISIX Admin API key
```

---

## 3. Sidecar — gRPC Service Definitions

### 3.1 Shield Service

```protobuf
syntax = "proto3";
package aria.sidecar.v1;

service ShieldService {
  // Analyze prompt for injection patterns using vector similarity
  rpc AnalyzePrompt(PromptAnalysisRequest) returns (PromptAnalysisResponse);
  
  // Count tokens using exact tiktoken tokenizer
  rpc CountTokens(TokenCountRequest) returns (TokenCountResponse);
  
  // Filter response content for harmful/toxic material
  rpc FilterResponse(ContentFilterRequest) returns (ContentFilterResponse);
}

message PromptAnalysisRequest {
  string request_id = 1;
  string consumer_id = 2;
  string content = 3;          // User message content
  string model = 4;
  repeated string patterns = 5; // Regex matches from Lua tier (for context)
}

message PromptAnalysisResponse {
  bool is_injection = 1;
  float confidence_score = 2;   // 0.0 - 1.0
  string pattern_category = 3;  // "direct_override", "role_manipulation", etc.
  string recommendation = 4;    // "block", "allow"
}

message TokenCountRequest {
  string request_id = 1;
  string consumer_id = 2;
  string model = 3;             // For model-specific tokenizer
  string content = 4;           // Full response content
  int32 lua_approximate_count = 5; // Lua estimate for reconciliation
}

message TokenCountResponse {
  int32 exact_token_count = 1;
  int32 input_tokens = 2;
  int32 output_tokens = 3;
  int32 delta = 4;              // exact - approximate
}

message ContentFilterRequest {
  string request_id = 1;
  string content = 2;
  string filter_level = 3;      // "strict", "moderate", "permissive"
}

message ContentFilterResponse {
  bool is_harmful = 1;
  string category = 2;          // "toxic", "violence", "hate", etc.
  float confidence_score = 3;
  string recommendation = 4;    // "block", "allow"
}
```

### 3.2 Mask Service

```protobuf
syntax = "proto3";
package aria.sidecar.v1;

service MaskService {
  // Detect PII using Named Entity Recognition
  rpc DetectPII(PiiDetectionRequest) returns (PiiDetectionResponse);
}

message PiiDetectionRequest {
  string request_id = 1;
  string content = 2;           // Response body text
  repeated string already_masked_paths = 3; // JSONPaths already masked by regex
}

message PiiDetectionResponse {
  repeated PiiEntity entities = 1;
}

message PiiEntity {
  string entity_type = 1;       // "PERSON", "LOCATION", "ORGANIZATION", "PHONE", etc.
  int32 start_offset = 2;       // Character offset in content
  int32 end_offset = 3;
  float confidence = 4;         // 0.0 - 1.0
  bool already_masked = 5;      // Was this caught by regex?
}
```

### 3.3 Canary Service

```protobuf
syntax = "proto3";
package aria.sidecar.v1;

service CanaryService {
  // Compare primary and shadow responses
  rpc DiffResponses(DiffRequest) returns (DiffResponse);
}

message DiffRequest {
  string request_id = 1;
  string route_id = 2;
  int32 primary_status = 3;
  bytes primary_body = 4;
  int64 primary_latency_ms = 5;
  int32 shadow_status = 6;
  bytes shadow_body = 7;
  int64 shadow_latency_ms = 8;
}

message DiffResponse {
  bool status_match = 1;
  float body_similarity = 2;    // 0.0 - 1.0 (structural similarity)
  int64 latency_delta_ms = 3;   // shadow - primary
  repeated string diff_fields = 4; // JSONPaths that differ
  string diff_summary = 5;      // Human-readable summary
}
```

### 3.4 Health Service

```protobuf
syntax = "proto3";
package aria.sidecar.v1;

service HealthService {
  rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
}

message HealthCheckRequest {
  string service = 1;           // Empty = all services
}

message HealthCheckResponse {
  enum ServingStatus {
    UNKNOWN = 0;
    SERVING = 1;
    NOT_SERVING = 2;
  }
  ServingStatus status = 1;
  map<string, bool> dependencies = 2; // {"redis": true, "postgres": false}
}
```

---

## 4. Plugin Configuration Schemas

### 4.1 Shield Plugin Configuration (APISIX Route Metadata)

```json
{
  "plugins": {
    "aria-shield": {
      "provider": "openai",
      "provider_config": {
        "endpoint": "https://api.openai.com/v1/chat/completions",
        "api_key_secret": "$secret://aria/openai-key",
        "timeout_ms": 30000
      },
      "fallback_providers": [
        {
          "provider": "anthropic",
          "endpoint": "https://api.anthropic.com/v1/messages",
          "api_key_secret": "$secret://aria/anthropic-key"
        }
      ],
      "quota": {
        "daily_tokens": 100000,
        "monthly_tokens": 1000000,
        "monthly_dollars": 500.00,
        "overage_policy": "block",
        "fail_policy": "fail_open"
      },
      "security": {
        "prompt_injection": {
          "enabled": true,
          "action": "block",
          "custom_patterns": [],
          "whitelist_consumers": []
        },
        "pii_scanner": {
          "enabled": true,
          "action": "mask",
          "patterns": ["pan", "msisdn", "tc_kimlik", "email"]
        }
      },
      "routing": {
        "strategy": "failover",
        "circuit_breaker": {
          "failure_threshold": 3,
          "cooldown_seconds": 30,
          "timeout_ms": 30000
        }
      },
      "model_pin": "gpt-4o-2024-11-20",
      "alerts": {
        "thresholds": [80, 90, 100],
        "webhook_url": "https://hooks.slack.com/services/xxx"
      }
    }
  }
}
```

### 4.2 Mask Plugin Configuration

```json
{
  "plugins": {
    "aria-mask": {
      "rules": [
        {
          "id": "rule-email-01",
          "path": "$.customer.email",
          "strategy": "mask:email",
          "field_type": "email"
        },
        {
          "id": "rule-pan-01",
          "path": "$.payment.card_number",
          "strategy": "last4",
          "field_type": "pan"
        },
        {
          "id": "rule-phone-01",
          "path": "$..phone",
          "strategy": "mask:phone",
          "field_type": "phone"
        }
      ],
      "role_policies": {
        "admin": { "default_strategy": "full" },
        "support_agent": {
          "default_strategy": "mask",
          "overrides": {
            "pan": "last4",
            "email": "mask:email"
          }
        },
        "external_partner": { "default_strategy": "redact" }
      },
      "auto_detect": {
        "enabled": true,
        "patterns": ["pan", "msisdn", "tc_kimlik", "email", "iban"],
        "whitelist_paths": ["$.order_id", "$.transaction_ref"]
      },
      "max_body_size": 10485760,
      "ner_enabled": false
    }
  }
}
```

### 4.3 Canary Plugin Configuration

```json
{
  "plugins": {
    "aria-canary": {
      "canary_upstream": "upstream-v2",
      "baseline_upstream": "upstream-v1",
      "schedule": [
        { "pct": 5, "hold": "5m" },
        { "pct": 10, "hold": "5m" },
        { "pct": 25, "hold": "10m" },
        { "pct": 50, "hold": "10m" },
        { "pct": 100, "hold": "0" }
      ],
      "error_monitor": {
        "enabled": true,
        "threshold_pct": 2.0,
        "window_seconds": 60,
        "min_requests": 10,
        "sustained_breach_seconds": 60
      },
      "latency_guard": {
        "enabled": true,
        "multiplier": 1.5,
        "min_requests": 50
      },
      "auto_rollback": true,
      "retry_policy": "manual",
      "retry_cooldown": "10m",
      "max_retries": 3,
      "consistent_hash": true,
      "shadow": {
        "enabled": false,
        "shadow_pct": 10,
        "shadow_upstream": "upstream-v2-shadow"
      },
      "notifications": {
        "webhook_url": "https://hooks.slack.com/services/xxx"
      }
    }
  }
}
```

### 4.4 Global Pricing Table (Plugin Metadata)

```json
{
  "plugin_metadata": {
    "aria-shield": {
      "pricing_table": {
        "gpt-4o": { "input_per_1k": 0.0025, "output_per_1k": 0.01 },
        "gpt-4o-mini": { "input_per_1k": 0.00015, "output_per_1k": 0.0006 },
        "claude-sonnet-4-6": { "input_per_1k": 0.003, "output_per_1k": 0.015 },
        "claude-haiku-4-5": { "input_per_1k": 0.0008, "output_per_1k": 0.004 },
        "gemini-2.0-flash": { "input_per_1k": 0.0001, "output_per_1k": 0.0004 },
        "_default": { "input_per_1k": 0.01, "output_per_1k": 0.03 }
      }
    }
  }
}
```

---

## 5. Webhook Notification Contracts

### 5.1 Budget Alert

```json
{
  "type": "aria_budget_alert",
  "consumer_id": "team-a",
  "threshold_pct": 80,
  "current_spend": 400.00,
  "budget_limit": 500.00,
  "budget_period": "monthly",
  "period": "2026-04",
  "timestamp": "2026-04-08T14:30:00Z"
}
```

### 5.2 Canary Rollback

```json
{
  "type": "aria_canary_rollback",
  "route_id": "route-api-v2",
  "canary_version": "v2.1.0",
  "baseline_version": "v2.0.0",
  "canary_error_rate": 0.052,
  "baseline_error_rate": 0.008,
  "rollback_trigger": "auto",
  "retry_count": 1,
  "max_retries": 3,
  "timestamp": "2026-04-08T03:15:22Z"
}
```

### 5.3 Security Event

```json
{
  "type": "aria_security_event",
  "event_type": "PROMPT_INJECTION_DETECTED",
  "consumer_id": "team-a",
  "route_id": "route-llm-proxy",
  "detection_source": "regex",
  "confidence": "HIGH",
  "action_taken": "BLOCKED",
  "timestamp": "2026-04-08T14:30:00Z"
}
```

---

*Document Version: 1.0 | Created: 2026-04-08*
*Status: Draft — Pending Human Approval*
