# 3e-Aria-Gatekeeper User Guide

**Version:** 0.1.0
**Last Updated:** 2026-04-08
**License:** Apache 2.0

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Getting Started](#2-getting-started)
3. [Quick Start](#3-quick-start)
4. [Module A: 3e-Aria-Shield (AI Governance)](#4-module-a-3e-aria-shield)
5. [Module B: 3e-Aria-Mask (Data Privacy)](#5-module-b-3e-aria-mask)
6. [Module C: 3e-Aria-Canary (Progressive Delivery)](#6-module-c-3e-aria-canary)
7. [Aria Runtime (Java Sidecar)](#7-aria-runtime)
8. [Configuration Reference](#8-configuration-reference)
9. [Grafana Dashboards](#9-grafana-dashboards)
10. [Troubleshooting](#10-troubleshooting)
11. [FAQ](#11-faq)

---

## 1. Introduction

3e-Aria-Gatekeeper is a modular governance suite for Apache APISIX. It adds three capabilities to your API gateway without changing application code:

| Module | What It Does |
|--------|-------------|
| **3e-Aria-Shield** | AI cost control, prompt security, multi-provider LLM routing |
| **3e-Aria-Mask** | Dynamic PII masking in API responses, GDPR/KVKK/PDPL compliance |
| **3e-Aria-Canary** | Progressive canary deployments with auto-rollback |

Each module is **independent** — install one, two, or all three. They share an optional Java sidecar (Aria Runtime) for advanced features like NER-based PII detection, exact token counting, and response diff analysis.

### Who Is This For?

- **Platform / Infra teams** — control AI spend across teams and applications
- **Security / CISO** — defend against prompt injection and data exfiltration
- **Compliance / DPO** — enforce GDPR/KVKK/PDPL masking without touching microservices
- **SRE / DevOps** — run intelligent canary deploys that auto-rollback on errors
- **FinOps** — budget-cap LLM spending per team, per model, per route

---

## 2. Getting Started

### 2.1 Prerequisites

| Service | Version | Required For |
|---------|---------|-------------|
| Apache APISIX | >= 3.8 | All modules (plugin host) |
| Redis | >= 7.0 | Shield (quotas), Canary (state), Mask (tokenization) |
| PostgreSQL | >= 16 | Audit trail, billing records |
| Prometheus | Any | Metrics collection |
| Grafana | >= 10 | Dashboards (optional) |

### 2.2 Installation

#### Option A: Docker Compose (Recommended for Development)

```bash
git clone https://github.com/3eai-labs/gatekeeper.git
cd gatekeeper/runtime
docker-compose up -d
```

This starts APISIX, Aria Runtime, Redis, PostgreSQL, and Grafana. APISIX is available at `http://localhost:9080`.

#### Option B: Helm (Kubernetes Production)

```bash
helm install aria ./runtime/helm/aria-gatekeeper/ \
  --set redis.host=your-redis.svc.cluster.local \
  --set postgres.host=your-postgres.svc.cluster.local \
  --set postgres.password=your-password
```

#### Option C: Manual Installation (Lua Plugins Only)

Copy the Lua plugin files into your APISIX plugin directory:

```bash
cp apisix/plugins/aria-shield.lua /usr/local/apisix/apisix/plugins/
cp apisix/plugins/aria-mask.lua   /usr/local/apisix/apisix/plugins/
cp apisix/plugins/aria-canary.lua /usr/local/apisix/apisix/plugins/
cp apisix/plugins/lib/aria-*.lua  /usr/local/apisix/apisix/plugins/lib/
```

Enable the plugins in your APISIX `config.yaml`:

```yaml
plugins:
  - aria-shield
  - aria-mask
  - aria-canary
```

Reload APISIX:

```bash
apisix reload
```

### 2.3 Database Setup

Run the Flyway migrations against your PostgreSQL:

```bash
flyway -url=jdbc:postgresql://localhost:5432/aria \
       -user=aria -password=your-password \
       -locations=filesystem:db/migration \
       migrate
```

Or, if using Docker Compose, the migrations run automatically on startup.

---

## 3. Quick Start

### 3.1 Route an LLM Request Through Shield

Create an APISIX route that proxies OpenAI requests through Shield:

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: your-admin-key" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "aria-shield": {
        "provider": "openai",
        "api_key_secret": "sk-your-openai-key",
        "quota": {
          "daily_tokens": 100000,
          "monthly_dollars": 50.00,
          "overage_policy": "block"
        }
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": { "api.openai.com:443": 1 },
      "scheme": "https"
    }
  }'
```

Now send a request using the OpenAI SDK (or curl):

```bash
curl http://localhost:9080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

The response includes Aria headers showing token usage and remaining budget:

```
X-Aria-Provider: openai
X-Aria-Model: gpt-4o-2024-11-20
X-Aria-Tokens-Input: 12
X-Aria-Tokens-Output: 45
X-Aria-Quota-Remaining: 99943
X-Aria-Budget-Remaining: 49.97
```

### 3.2 Mask PII in API Responses

Add Aria Mask to any route to mask sensitive fields:

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/2 \
  -H "X-API-KEY: your-admin-key" \
  -d '{
    "uri": "/api/customers/*",
    "plugins": {
      "aria-mask": {
        "rules": [
          {"path": "$.email", "strategy": "mask:email"},
          {"path": "$.phone", "strategy": "mask:phone"},
          {"path": "$.card_number", "strategy": "last4"}
        ],
        "role_policies": {
          "admin": {"default_strategy": "full"},
          "support": {"default_strategy": "mask"},
          "partner": {"default_strategy": "redact"}
        },
        "auto_detect": {
          "enabled": true,
          "patterns": ["pan", "msisdn", "email", "iban"]
        }
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": { "customer-service:8080": 1 }
    }
  }'
```

A support agent calling this route sees:

```json
{
  "email": "j***@e***.com",
  "phone": "+90 532 *** 45 67",
  "card_number": "****-****-****-1234"
}
```

An admin sees the full values. A partner sees `[REDACTED]` for all fields.

### 3.3 Deploy with a Smart Canary

Set up progressive delivery with auto-rollback:

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/3 \
  -H "X-API-KEY: your-admin-key" \
  -d '{
    "uri": "/api/orders/*",
    "plugins": {
      "aria-canary": {
        "canary_upstream": { "nodes": {"orders-v2:8080": 1} },
        "schedule": [
          {"pct": 5,   "hold": "5m"},
          {"pct": 10,  "hold": "5m"},
          {"pct": 25,  "hold": "10m"},
          {"pct": 50,  "hold": "10m"},
          {"pct": 100, "hold": "0"}
        ],
        "error_threshold_delta": 2.0,
        "rollback_sustained_seconds": 60,
        "webhook_url": "https://hooks.slack.com/your-webhook"
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": { "orders-v1:8080": 1 }
    }
  }'
```

The canary automatically progresses through stages. If the error rate for the canary exceeds the baseline by more than 2%, traffic is rolled back to 0% and a Slack notification is sent.

---

## 4. Module A: 3e-Aria-Shield

### 4.1 Multi-Provider LLM Routing

Shield routes AI requests to any supported provider while keeping the OpenAI SDK-compatible API format. Your applications only need to change `base_url` — no other code changes.

**Supported Providers:**

| Provider | Config Value | Notes |
|----------|-------------|-------|
| OpenAI | `openai` | GPT-4o, GPT-4, GPT-3.5 |
| Anthropic | `anthropic` | Claude models — transformed to Messages API |
| Google Gemini | `google` | Gemini models — transformed to Gemini API |
| Azure OpenAI | `azure_openai` | Includes deployment ID and API version |
| Ollama / vLLM | `ollama` | Local models — self-hosted |

**Example: Route to Anthropic**

```json
{
  "aria-shield": {
    "provider": "anthropic",
    "api_key_secret": "sk-ant-your-key",
    "routing": {
      "strategy": "failover",
      "circuit_breaker": {
        "failure_threshold": 3,
        "cooldown_seconds": 30
      }
    },
    "fallback_providers": ["openai", "google"]
  }
}
```

### 4.2 Auto-Failover & Circuit Breaker

When a provider returns 5xx errors or times out, Shield automatically fails over to the next provider in the fallback chain.

**Circuit breaker states:**

| State | Behavior |
|-------|----------|
| CLOSED | Normal operation — requests go to primary |
| OPEN | Primary failed — requests go to fallback. Probe sent after cooldown |
| HALF_OPEN | Single probe sent to primary. Success → CLOSED. Failure → OPEN again |

All state changes emit the `aria_circuit_breaker_state` Prometheus metric.

### 4.3 SSE Streaming

Shield passes through Server-Sent Events streams chunk-by-chunk with no buffering. Tokens are counted incrementally from `data:` chunks.

```python
# Python example using the OpenAI SDK
from openai import OpenAI

client = OpenAI(base_url="http://gateway:9080/v1", api_key="not-used")

stream = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Explain quantum computing"}],
    stream=True
)

for chunk in stream:
    print(chunk.choices[0].delta.content, end="")
```

### 4.4 Token Quotas & Dollar Budgets

Set daily/monthly limits per consumer, per route, or per application.

| Setting | Description |
|---------|-------------|
| `daily_tokens` | Maximum tokens per day |
| `monthly_tokens` | Maximum tokens per month |
| `monthly_dollars` | Dollar budget per month (calculated from per-model pricing) |
| `overage_policy` | What happens when budget is exhausted |

**Overage policies:**

| Policy | Behavior | HTTP Status |
|--------|----------|-------------|
| `block` | Reject request immediately | 402 Payment Required |
| `throttle` | Allow 1 request per minute | 429 Too Many Requests |
| `allow_with_alert` | Allow but send alert | 200 (with warning header) |

### 4.5 Budget Alerts

Configure webhook notifications at budget thresholds:

```json
{
  "quota": {
    "monthly_dollars": 500.00,
    "alert_thresholds": [80, 90, 100],
    "alert_webhook": "https://hooks.slack.com/your-webhook"
  }
}
```

Alerts are de-duplicated — you receive each threshold notification only once per budget period.

### 4.6 Prompt Security

Shield provides regex-based prompt injection detection in the Lua layer. With the Aria Runtime sidecar, it adds vector-similarity analysis for more sophisticated attacks.

| Feature | Lua (Default) | With Sidecar |
|---------|--------------|-------------|
| Prompt injection detection | Regex patterns | Regex + vector similarity |
| PII-in-prompt scanning | Regex | Regex + NER |
| Response content filtering | Disabled | Active |
| Data exfiltration guard | Pattern matching | Pattern + semantic analysis |

**Actions for detected threats:**

| Action | Behavior |
|--------|----------|
| `block` | Return 403 with `PROMPT_BLOCKED` error |
| `mask` | Mask detected PII before forwarding to LLM |
| `warn` | Forward request but log a warning event |

### 4.7 Prometheus Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `aria_tokens_consumed` | Counter | consumer, model, route, type (input/output) | Tokens consumed |
| `aria_cost_dollars` | Counter | consumer, model, route | Cost in dollars |
| `aria_requests_total` | Counter | consumer, model, route, status | Request count |
| `aria_request_latency_seconds` | Histogram | consumer, model, route | Request latency |
| `aria_circuit_breaker_state` | Gauge | provider, route | 0=closed, 1=open, 2=half_open |
| `aria_quota_utilization_pct` | Gauge | consumer, quota_type | Budget utilization percentage |

---

## 5. Module B: 3e-Aria-Mask

### 5.1 How Masking Works

Aria Mask operates in the APISIX `body_filter` phase. When an upstream service returns a JSON response, Mask:

1. Reads the consumer's role from APISIX context
2. Loads the role's masking policy
3. Applies JSONPath-based field masking rules
4. Optionally runs auto-detection for PII patterns
5. Logs a masking audit event (metadata only — never the original values)

The upstream service returns full data. Masking happens at the gateway edge. **Zero code changes** are required in your services.

### 5.2 Masking Strategies

| Strategy | Example Input | Example Output |
|----------|-------------|---------------|
| `last4` | 4111111111111111 | ****-****-****-1111 |
| `first2last2` | 12345678901 | 12*******01 |
| `hash` | john@example.com | a3f2b8c9d1... (SHA-256) |
| `redact` | Any value | [REDACTED] |
| `full` | Any value | (unchanged — no masking) |
| `mask:email` | john.doe@example.com | j***@e***.com |
| `mask:phone` | +90 532 123 45 67 | +90 532 *** 45 67 |
| `mask:national_id` | 12345678901 | ****56789** |
| `mask:iban` | TR330006100519786457841326 | TR33****1326 |
| `mask:ip` | 192.168.1.100 | 192.168.\*.\* |
| `mask:dob` | 1990-05-13 | ****-**-13 |
| `tokenize` | 4111111111111111 | tok_a8f3b2c1 (reversible with API) |

### 5.3 Role-Based Policies

Define what each consumer role sees:

```json
{
  "role_policies": {
    "admin": { "default_strategy": "full" },
    "support_agent": { "default_strategy": "mask" },
    "external_partner": { "default_strategy": "redact" },
    "unknown": { "default_strategy": "redact" }
  }
}
```

The consumer's role is read from the APISIX consumer metadata. If no role is found, the `unknown` policy is applied (failsafe: `redact`).

### 5.4 Auto-Detection

When `auto_detect.enabled` is `true`, Mask scans the response body for PII patterns regardless of whether explicit rules are configured for those fields.

**Supported patterns:**

| Pattern Key | What It Detects | Validation |
|------------|-----------------|-----------|
| `pan` | Credit card numbers (13-19 digits) | Luhn checksum |
| `msisdn` | Phone numbers (international format) | Format validation |
| `tc_kimlik` | Turkish national ID (11 digits) | Mod-11 checksum |
| `email` | Email addresses | Format validation |
| `iban` | International bank account numbers | Format validation |
| `imei` | Mobile equipment identity (15 digits) | Luhn checksum |
| `ip` | IPv4 addresses | Format validation |
| `dob` | Dates of birth (YYYY-MM-DD) | Format validation |

### 5.5 Compliance Coverage

| Framework | How Aria Mask Helps |
|-----------|-------------------|
| **GDPR (EU)** | Data minimization — consumers see only what they need |
| **KVKK (Turkey)** | Personal data masked at the processing layer |
| **PDPL (Saudi Arabia / Iraq)** | Data masking + localization support |
| **PCI-DSS** | PAN never exposed in full; tokenization or masking enforced |

### 5.6 Prometheus Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `aria_mask_applied` | Counter | field, rule, consumer, strategy | Masking operations |
| `aria_mask_violations` | Counter | consumer, route | Auto-detected PII (not in explicit rules) |
| `aria_mask_latency_seconds` | Histogram | route | Masking processing time |

---

## 6. Module C: 3e-Aria-Canary

### 6.1 Progressive Delivery

Aria Canary splits traffic between a baseline upstream and a canary upstream using a configurable schedule:

```
Stage 1: 5% canary   (hold 5 minutes)
Stage 2: 10% canary  (hold 5 minutes)
Stage 3: 25% canary  (hold 10 minutes)
Stage 4: 50% canary  (hold 10 minutes)
Stage 5: 100% canary (deployment complete)
```

Traffic routing uses consistent hashing — the same client gets routed to the same upstream version during a stage for a stable experience.

### 6.2 Error-Rate Monitoring

Canary continuously compares error rates between baseline and canary using sliding window counters:

- **Error delta threshold:** If canary error rate exceeds baseline by more than the configured delta (default: 2%), the stage is considered failing
- **Sustained duration:** The error must be sustained for the configured period (default: 60 seconds) before rollback triggers

### 6.3 Auto-Rollback

When the error threshold is sustained:

1. Traffic is immediately shifted to 0% canary (all traffic to baseline)
2. A webhook notification is sent (Slack, generic HTTPS)
3. The canary state is set to `ROLLED_BACK`

**Retry policies:**

| Policy | Behavior |
|--------|----------|
| `manual` (default) | Canary stays rolled back until manually restarted |
| `auto` | Retry from stage 1 after configurable cooldown |

### 6.4 Latency Guard

If canary P95 latency exceeds baseline P95 multiplied by a configurable factor (default: 1.5x), stage progression is paused. No rollback — just a hold until latency stabilizes.

### 6.5 Manual Override

Use the APISIX plugin control API:

```bash
# Check canary status
curl http://localhost:9080/aria/canary/route-3/status

# Instantly promote to 100%
curl -X POST http://localhost:9080/aria/canary/route-3/promote

# Instantly rollback to 0%
curl -X POST http://localhost:9080/aria/canary/route-3/rollback

# Pause automatic progression
curl -X POST http://localhost:9080/aria/canary/route-3/pause

# Resume automatic progression
curl -X POST http://localhost:9080/aria/canary/route-3/resume
```

### 6.6 Traffic Shadowing

Copy a percentage of live traffic to a "shadow" upstream without affecting the client response. The shadow response is compared with the primary by the diff engine (requires Aria Runtime sidecar).

```json
{
  "aria-canary": {
    "shadow": {
      "enabled": true,
      "traffic_pct": 10,
      "shadow_upstream": { "nodes": {"orders-next:8080": 1} }
    }
  }
}
```

### 6.7 Prometheus Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `aria_canary_traffic_pct` | Gauge | route | Current canary traffic percentage |
| `aria_canary_error_rate` | Gauge | route, version | Error rate per version |
| `aria_canary_latency_p95` | Gauge | route, version | P95 latency per version |
| `aria_canary_rollback_total` | Counter | route | Total rollback events |
| `aria_shadow_diff_count` | Counter | route | Response differences detected |

---

## 7. Aria Runtime

The Aria Runtime is an optional Java 21 sidecar that provides advanced processing capabilities beyond what Lua can efficiently handle.

### 7.1 What It Adds

| Feature | Module | Without Sidecar | With Sidecar |
|---------|--------|----------------|-------------|
| Token counting | Shield | Approximate (word heuristic) | Exact (tiktoken) — community tier |
| Prompt injection | Shield | Regex only | Regex + vector similarity — enterprise |
| PII detection | Mask | Regex patterns | Regex + NER (Named Entity Recognition) — enterprise |
| Content filtering | Shield | Disabled | Active — enterprise |
| Shadow diff | Canary | Disabled | Active (structural comparison) — enterprise |

> **Tier legend:** *community tier* features are part of the free Aria
> Runtime distribution. *enterprise* features require an active 3EAI Labs
> Enterprise License Agreement.

### 7.2 Deployment

The sidecar runs in the same pod as APISIX and communicates via Unix Domain Socket:

```
APISIX Container <── UDS (~0.1ms) ──> Aria Runtime Container
                  /var/run/aria/aria.sock
```

### 7.3 Health Checks

| Endpoint | Purpose | Passes When |
|----------|---------|-------------|
| `GET /healthz` | Liveness probe | JVM is running |
| `GET /readyz` | Readiness probe | Redis AND PostgreSQL are reachable |

### 7.4 Graceful Shutdown

On `SIGTERM`:
1. `/readyz` returns 503 (stop receiving new requests)
2. Drain in-flight gRPC calls (up to 30s configurable)
3. Close Redis and PostgreSQL connections
4. Remove UDS socket file
5. Exit

---

## 8. Configuration Reference

### 8.1 Aria Runtime Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARIA_REDIS_HOST` | `127.0.0.1` | Redis host |
| `ARIA_REDIS_PORT` | `6379` | Redis port |
| `ARIA_REDIS_PASSWORD` | (empty) | Redis password |
| `ARIA_REDIS_DATABASE` | `0` | Redis database number |
| `ARIA_POSTGRES_HOST` | `127.0.0.1` | PostgreSQL host |
| `ARIA_POSTGRES_PORT` | `5432` | PostgreSQL port |
| `ARIA_POSTGRES_DATABASE` | `aria` | PostgreSQL database name |
| `ARIA_POSTGRES_USERNAME` | `aria` | PostgreSQL username |
| `ARIA_POSTGRES_PASSWORD` | (empty) | PostgreSQL password |
| `SERVER_PORT` | `8081` | Health check HTTP port |

### 8.2 UDS Configuration

| Setting | Default | Notes |
|---------|---------|-------|
| Socket path | `/var/run/aria/aria.sock` | Shared volume between APISIX and sidecar |
| Socket permissions | `0660` | Owner + group read/write |
| Shutdown grace period | `30s` | Maximum drain time on SIGTERM |

### 8.3 Resource Sizing

| Deployment Size | CPU | Memory | Concurrent Requests |
|----------------|-----|--------|-------------------|
| Small (< 100 req/s) | 0.25 cores | 256Mi | 1K virtual threads |
| Medium (< 1K req/s) | 0.5 cores | 384Mi | 5K virtual threads |
| Large (< 10K req/s) | 1.0 cores | 512Mi | 10K+ virtual threads |

### 8.4 Shield Plugin Configuration

```json
{
  "aria-shield": {
    "provider": "openai | anthropic | google | azure_openai | ollama",
    "api_key_secret": "your-provider-api-key",
    "fallback_providers": ["anthropic", "google"],
    "quota": {
      "daily_tokens": 100000,
      "monthly_tokens": 1000000,
      "monthly_dollars": 500.00,
      "overage_policy": "block | throttle | allow_with_alert",
      "fail_policy": "fail_open | fail_closed",
      "alert_thresholds": [80, 90, 100],
      "alert_webhook": "https://hooks.slack.com/your-webhook"
    },
    "security": {
      "prompt_injection": { "enabled": true, "action": "block | mask | warn" },
      "pii_scanner": { "enabled": true, "action": "block | mask | warn" },
      "response_filter": { "enabled": false }
    },
    "routing": {
      "strategy": "failover | latency | cost",
      "circuit_breaker": {
        "failure_threshold": 3,
        "cooldown_seconds": 30
      }
    },
    "model_pin": null,
    "pricing_table": "default"
  }
}
```

### 8.5 Mask Plugin Configuration

```json
{
  "aria-mask": {
    "rules": [
      { "path": "$.customer.email", "strategy": "mask:email", "field_type": "email" },
      { "path": "$.customer.phone", "strategy": "mask:phone", "field_type": "phone" },
      { "path": "$.payment.card_number", "strategy": "last4", "field_type": "pan" }
    ],
    "role_policies": {
      "admin": { "default_strategy": "full" },
      "support_agent": { "default_strategy": "mask" },
      "external_partner": { "default_strategy": "redact" }
    },
    "auto_detect": {
      "enabled": true,
      "patterns": ["pan", "msisdn", "tc_kimlik", "email", "iban", "imei", "ip", "dob"]
    },
    "max_body_size": 10485760,
    "hash_salt_secret": "your-hash-salt",
    "ner_enabled": false
  }
}
```

### 8.6 Canary Plugin Configuration

```json
{
  "aria-canary": {
    "canary_upstream": {
      "nodes": { "service-v2:8080": 1 }
    },
    "schedule": [
      { "pct": 5,   "hold": "5m" },
      { "pct": 10,  "hold": "5m" },
      { "pct": 25,  "hold": "10m" },
      { "pct": 50,  "hold": "10m" },
      { "pct": 100, "hold": "0" }
    ],
    "error_threshold_delta": 2.0,
    "rollback_sustained_seconds": 60,
    "latency_guard": {
      "enabled": true,
      "p95_multiplier": 1.5
    },
    "retry_policy": "manual | auto",
    "retry_cooldown_seconds": 300,
    "webhook_url": "https://hooks.slack.com/your-webhook",
    "shadow": {
      "enabled": false,
      "traffic_pct": 10,
      "shadow_upstream": { "nodes": {} }
    }
  }
}
```

---

## 9. Grafana Dashboards

Pre-built Grafana dashboards are included in the `dashboards/` directory:

| Dashboard | File | What It Shows |
|-----------|------|-------------|
| **Shield** | `shield-dashboard.json` | Token consumption, cost by consumer/model, circuit breaker state, prompt security events |
| **Mask** | `mask-dashboard.json` | Masking operations, PII detections, compliance metrics |
| **Canary** | `canary-dashboard.json` | Traffic split, error rates (canary vs. baseline), rollback events |

### Import

**Automatic (Helm):** Set `dashboards.enabled: true` in Helm values. Dashboards are auto-discovered by Grafana's sidecar.

**Manual:** Import the JSON files via Grafana UI (Dashboards > Import) or copy them to Grafana's provisioning directory.

---

## 10. Troubleshooting

### 10.1 Shield: "QUOTA_EXCEEDED" When Budget Isn't Full

**Cause:** Token counts are approximate in the Lua layer. The Java sidecar reconciles exact counts asynchronously.

**Fix:** Check `aria_quota_utilization_pct` metric for the consumer. If the Lua estimate is consistently over-counting, the sidecar will correct billing records. For immediate relief, increase the daily quota by 5-10%.

### 10.2 Shield: "ALL_PROVIDERS_DOWN"

**Cause:** All configured LLM providers are unreachable or returning errors.

**Check:**
1. Verify provider API keys are valid: `curl -H "Authorization: Bearer sk-..." https://api.openai.com/v1/models`
2. Check circuit breaker state: query `aria_circuit_breaker_state` metric
3. Check network connectivity from the APISIX pod to provider endpoints

### 10.3 Mask: Response Not Being Masked

**Cause:** Consumer role not set, or no matching masking rules.

**Check:**
1. Verify the APISIX consumer has role metadata configured
2. Check that JSONPath rules match the response structure
3. Confirm the route has `aria-mask` plugin enabled
4. Check `aria_mask_applied` metric — if zero, rules aren't matching

### 10.4 Canary: Immediate Rollback After Starting

**Cause:** The canary upstream is returning errors from the start.

**Check:**
1. Verify the canary upstream is healthy: `curl http://canary-service:8080/healthz`
2. Check `aria_canary_error_rate` by version — if canary starts above threshold, it will rollback after `rollback_sustained_seconds`
3. Consider increasing `rollback_sustained_seconds` for cold-start scenarios

### 10.5 Sidecar Not Connecting

**Cause:** UDS socket not shared between containers.

**Check:**
1. Verify the shared volume is mounted at `/var/run/aria` in both containers
2. Check socket file exists: `ls -la /var/run/aria/aria.sock`
3. Check sidecar readiness: `curl http://localhost:8081/readyz`
4. Lua plugins degrade gracefully without the sidecar — check APISIX error logs for "sidecar unavailable" warnings

### 10.6 Redis Connection Failures

**Behavior:** Depends on `fail_policy` configuration:
- `fail_open` (default): Requests proceed without quota checks. Alert sent.
- `fail_closed`: Requests are rejected (503). Use for strict budget enforcement.

**Check:** Verify Redis connectivity from the APISIX pod and sidecar. Check Redis cluster status.

---

## 11. FAQ

### General

**Q: Do I need all three modules?**
A: No. Each module is independent. Install only what you need. Shield alone, Mask alone, or any combination.

**Q: Do I need the Java sidecar?**
A: No. The Lua plugins work standalone. The sidecar adds advanced features (exact token counting, NER, content filtering, shadow diff). Without it, features degrade gracefully to regex-based alternatives.

**Q: Will Aria slow down my requests?**
A: Minimal overhead. Lua plugin latency: < 5ms (Shield), < 1ms (Mask), < 0.5ms (Canary). SSE streaming adds < 1ms per chunk. The sidecar runs async and off the critical path for most operations.

**Q: Does Aria work with non-AI APIs?**
A: Yes. Mask and Canary work with any HTTP API. Shield is specific to LLM/AI APIs.

### Shield

**Q: Can I use Aria Shield as an OpenAI proxy?**
A: Yes. Set `base_url` in your OpenAI SDK to point to the APISIX gateway. No other code changes needed.

**Q: How accurate is Lua token counting?**
A: Approximately 80-90% accuracy (word-based heuristic). The sidecar provides exact tiktoken counting and reconciles billing asynchronously.

**Q: What happens when all LLM providers are down?**
A: Shield returns `503 Service Unavailable` with `aria_error_code: ALL_PROVIDERS_DOWN`. The `aria_circuit_breaker_state` metric reflects the outage.

### Mask

**Q: Does Mask work with nested JSON?**
A: Yes. JSONPath expressions support nested paths (e.g., `$.customer.address.postal_code`).

**Q: Can I mask XML or non-JSON responses?**
A: Currently only JSON responses are supported. XML masking is on the roadmap.

**Q: How does tokenization differ from masking?**
A: Masking is one-way — the original value cannot be recovered. Tokenization generates a reversible token stored in Redis. Authorized API calls can resolve the token back to the original value.

### Canary

**Q: Does Canary work with ArgoCD Rollouts?**
A: Aria Canary works standalone. ArgoCD/Flagger integration is on the roadmap for v1.0.

**Q: Can I have multiple canary deployments at once?**
A: Yes. Each route has independent canary state. Up to 50 concurrent canaries per APISIX instance.

---

*3e-Aria-Gatekeeper is developed by [3EAI Labs](https://3eai-labs.com). Apache 2.0 License.*
*Enterprise support and the Aria Runtime sidecar are available under a commercial license: enterprise@3eai-labs.com*
