# Release Notes — 3e-Aria-Gatekeeper v0.1.0

**Release Date:** 2026-04-08
**License:** Apache 2.0
**Author:** 3EAI Labs Ltd

---

## Overview

**3e-Aria-Gatekeeper** is a modular governance suite for Apache APISIX — three independent, composable plugins that enforce AI cost control, data privacy, and deployment safety at the gateway layer, without changing application code.

This is the initial release containing all three modules at v0.1 maturity.

---

## What's Included

### 3e-Aria-Shield — AI Governance
Route LLM requests through APISIX with automatic cost control and security.

- **5 LLM providers:** OpenAI, Anthropic, Google Gemini, Azure OpenAI, Ollama
- **Zero code changes:** Point your OpenAI SDK to the gateway by changing only `base_url`
- **Token quotas & dollar budgets:** Daily/monthly limits with block, throttle, or allow-with-alert policies
- **Auto-failover:** Circuit breaker with fallback provider chain
- **SSE streaming:** Non-blocking pass-through with token counting

### 3e-Aria-Mask — Dynamic Data Privacy
Mask PII in API responses at the gateway edge — GDPR/KVKK/PCI-DSS compliance without code changes.

- **JSONPath field masking:** Configure which fields to mask per route
- **Role-based policies:** Admin sees full data, support agent sees last4, partner sees [REDACTED]
- **Auto-detect PII:** Credit cards (Luhn-validated), phone numbers, national IDs, emails, IBANs, and more
- **12 masking strategies:** last4, hash, redact, tokenize, and field-type-specific masks

### 3e-Aria-Canary — Progressive Delivery
Deploy safely with automatic error monitoring and rollback.

- **Configurable schedule:** 5% → 10% → 25% → 50% → 100% with hold durations
- **Error-rate monitoring:** Continuous canary vs. baseline comparison
- **Auto-rollback:** Traffic to 0% when errors sustained above threshold
- **Admin API:** Promote, rollback, pause, resume via APISIX plugin control API

### Aria Runtime — Java 21 Sidecar
Heavy-processing backend with Virtual Threads and gRPC/UDS.

- **~0.1ms IPC** via Unix Domain Sockets
- **Health checks** compatible with Kubernetes liveness/readiness probes
- **Graceful shutdown** with configurable drain period

---

## Quick Start

### 1. Copy Lua plugins to APISIX

```bash
cp apisix/plugins/aria-shield.lua /path/to/apisix/plugins/
cp apisix/plugins/aria-mask.lua /path/to/apisix/plugins/
cp apisix/plugins/aria-canary.lua /path/to/apisix/plugins/
cp -r apisix/plugins/lib/ /path/to/apisix/plugins/lib/
```

### 2. Enable plugins in APISIX config

```yaml
# config.yaml
plugins:
  - aria-shield
  - aria-mask
  - aria-canary
```

### 3. Configure a route with Shield

```bash
curl -X PUT http://apisix-admin:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $ADMIN_KEY" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "aria-shield": {
        "provider": "openai",
        "provider_config": {
          "endpoint": "https://api.openai.com/v1/chat/completions",
          "api_key": "sk-..."
        },
        "fallback_providers": [
          { "provider": "anthropic", "api_key": "sk-ant-..." }
        ],
        "quota": {
          "monthly_tokens": 1000000,
          "monthly_dollars": 500.00,
          "overage_policy": "block"
        }
      }
    }
  }'
```

### 4. Use from your application

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://your-apisix-gateway/v1",
    api_key="your-consumer-api-key"
)

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

---

## Requirements

| Component | Version |
|-----------|---------|
| Apache APISIX | >= 3.8 |
| Redis | >= 7.0 |
| PostgreSQL | >= 16 (for audit tables) |
| Java | 21+ (for sidecar) |

---

## User Story Traceability

| Story | Title | Status |
|-------|-------|--------|
| US-A01 | Multi-provider LLM routing | Implemented |
| US-A02 | Auto-failover | Implemented |
| US-A03 | SSE streaming | Implemented |
| US-A04 | OpenAI SDK compatibility | Implemented |
| US-A05 | Token quota enforcement | Implemented |
| US-A06 | Dollar budget control | Implemented |
| US-A07 | Usage metrics | Implemented |
| US-A08 | Budget alerts | Implemented |
| US-A09 | Overage policy | Implemented |
| US-A17 | Model version pinning | Implemented |
| US-B01 | Field-level masking | Implemented |
| US-B02 | Role-based policies | Implemented |
| US-B03 | PII pattern detection | Implemented |
| US-B04 | Configurable strategies | Implemented |
| US-B05 | Masking audit log | Implemented |
| US-C01 | Progressive splitting | Implemented |
| US-C02 | Error-rate monitoring | Implemented |
| US-C03 | Auto-rollback | Implemented |
| US-C05 | Manual override | Implemented |
| US-S01 | gRPC/UDS server | Implemented |
| US-S02 | Virtual threads | Implemented |
| US-S03 | Health checks | Implemented |
| US-S04 | Graceful shutdown | Implemented |

---

## Known Limitations (v0.1)

- **Sidecar handlers are stubs:** Prompt analysis (vector similarity), tiktoken counting, NER detection, and shadow diff engine will be implemented in v0.3
- **No Admin UI:** Operations via Grafana dashboards + ariactl CLI (planned for post-v1.0)
- **No Kafka:** All IPC is gRPC/UDS or fire-and-forget (Kafka deferred per ADR-006)
- **Latency guard (canary):** P95 tracking uses simplified counters; full t-digest implementation in v0.2
- **WASM masking engine:** Not yet implemented (planned for Mask v0.3)

---

*Copyright 2026 3EAI Labs Ltd. Apache 2.0 License.*
