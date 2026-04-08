# 3e-Aria-Gatekeeper — Quick Start Card

**From zero to governed in 5 minutes**

---

## 1. Start the Stack

```bash
git clone https://github.com/3eai-labs/gatekeeper.git
cd gatekeeper/runtime
docker-compose up -d
```

Verify: `curl http://localhost:9080` should return APISIX default response.

---

## 2. Shield: Add AI Cost Control

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "aria-shield": {
        "provider": "openai",
        "api_key_secret": "sk-YOUR-KEY",
        "quota": {"daily_tokens": 100000, "monthly_dollars": 50, "overage_policy": "block"}
      }
    },
    "upstream": {"type": "roundrobin", "nodes": {"api.openai.com:443": 1}, "scheme": "https"}
  }'
```

Test: `curl http://localhost:9080/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}]}'`

Check headers: `X-Aria-Tokens-Input`, `X-Aria-Quota-Remaining`, `X-Aria-Budget-Remaining`

---

## 3. Mask: Add PII Masking

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/2 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -d '{
    "uri": "/api/customers/*",
    "plugins": {
      "aria-mask": {
        "rules": [{"path": "$.email", "strategy": "mask:email"}, {"path": "$.phone", "strategy": "mask:phone"}],
        "role_policies": {"admin": {"default_strategy": "full"}, "support": {"default_strategy": "mask"}},
        "auto_detect": {"enabled": true, "patterns": ["pan", "msisdn", "email"]}
      }
    },
    "upstream": {"type": "roundrobin", "nodes": {"your-service:8080": 1}}
  }'
```

Result: `john@example.com` becomes `j***@e***.com` for non-admin consumers.

---

## 4. Canary: Add Safe Deployments

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/3 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -d '{
    "uri": "/api/orders/*",
    "plugins": {
      "aria-canary": {
        "canary_upstream": {"nodes": {"orders-v2:8080": 1}},
        "schedule": [{"pct": 5, "hold": "5m"}, {"pct": 25, "hold": "10m"}, {"pct": 100, "hold": "0"}],
        "error_threshold_delta": 2.0,
        "rollback_sustained_seconds": 60
      }
    },
    "upstream": {"type": "roundrobin", "nodes": {"orders-v1:8080": 1}}
  }'
```

Monitor: `curl http://localhost:9080/aria/canary/3/status`

---

## 5. View Dashboards

Open **Grafana**: http://localhost:3000 (admin/admin)

Three pre-built dashboards:
- **Shield** — Token spend, cost by consumer, circuit breaker state
- **Mask** — Masking operations, PII detections, compliance metrics
- **Canary** — Traffic split, error rates, rollback events

---

## Key Endpoints

| Endpoint | Purpose |
|:---------|:--------|
| `localhost:9080` | APISIX gateway (HTTP) |
| `localhost:9180` | APISIX Admin API |
| `localhost:9091` | Prometheus metrics |
| `localhost:8081` | Aria Runtime health checks |
| `localhost:3000` | Grafana dashboards |

---

## Next Steps

- Full configuration: see `docs/05_user/USER_GUIDE.md`
- Helm deployment: see `runtime/docs/DEPLOYMENT.md`
- Enterprise pilot: enterprise@3eai-labs.com

---

**3EAI Labs** | 3eai-labs.com | Apache 2.0
