# 3e-Aria-Gatekeeper — Quick Start

**From clone to your first governed LLM call in under 10 minutes.**

This card walks you through the docker-compose stack — the same one CI
uses for end-to-end tests. For Kubernetes, see
[`runtime/docs/DEPLOYMENT.md`](../../runtime/docs/DEPLOYMENT.md).

---

## What you get

```
       ┌──────────┐    ┌──────────────┐    ┌──────────────┐
client │  APISIX  │    │ aria-runtime │    │  Redis +     │
──────▶│  + Lua   │◀──▶│   sidecar    │◀──▶│  PostgreSQL  │
       │  plugins │UDS │              │    │              │
       └──────────┘    └──────────────┘    └──────────────┘
            │
            ▼
        upstream LLM
        (Ollama / OpenAI / Anthropic / …)
```

Three plugins ship in the open-core build:

- **`aria-shield`** — provider routing, quota enforcement, prompt security
- **`aria-mask`** — PII masking in requests and responses (regex + NER)
- **`aria-canary`** — progressive delivery with auto-rollback

Plus three pre-built Grafana dashboards (Shield / Mask / Canary).

## 1. Prerequisites

| Tool | Tested with |
|---|---|
| Docker (with Compose v2) | 24.0+ |
| `curl` | any |
| `jq` | any (optional, for pretty output) |

That's it — no Java, no Lua toolchain, no Kubernetes required for the dev stack.

## 2. Clone and start

```bash
git clone https://github.com/3eai-labs/gatekeeper.git
cd gatekeeper/runtime
docker compose up -d
```

Wait ~15 seconds for everything to settle, then verify:

```bash
# Sidecar JVM is up
curl -s http://localhost:8081/healthz | jq
# → {"status":"alive"}

# Sidecar can reach Redis + PostgreSQL
curl -s http://localhost:8081/readyz | jq
# → {"status":"ready","ready":true,"dependencies":{"redis":true,"postgres":true}}

# APISIX is serving the bundled smoke-test route
curl -s http://localhost:9080/health/echo
# → {"ok":true,"gateway":"3e-aria-gatekeeper"}
```

If any of these fail, jump to [Troubleshooting](#troubleshooting) below.

## 3. Configure routes

The bundled compose runs APISIX in **standalone (YAML) mode** — routes
live in `runtime/apisix.yaml`, **not** the Admin API. Edit that file to
add or change routes; APISIX reloads automatically when the file changes.

The default `apisix.yaml` already includes a working LLM proxy route
that calls Ollama (if you've started the optional Ollama profile) — but
the easiest first request is to point Shield at OpenAI:

```yaml
# runtime/apisix.yaml — replace the /v1/chat/completions route with:
- uri: /v1/chat/completions
  plugins:
    aria-shield:
      provider: openai
      provider_config:
        endpoint: "https://api.openai.com/v1/chat/completions"
        api_key_env: OPENAI_API_KEY
      quota:
        enabled: true
        daily_tokens: 100000
        monthly_dollars: 50
        overage_policy: block
      prompt_security:
        enabled: true
        mode: regex_only
  upstream:
    type: roundrobin
    scheme: https
    nodes:
      "api.openai.com:443": 1
```

Make sure the `#END` marker stays at the very bottom of the file.

Then make the key visible to APISIX. Two steps:

```bash
# 1. Put the key in runtime/.env (gitignored — never commit this file)
echo "OPENAI_API_KEY=sk-..." >> .env

# 2. Pass it through to the apisix service. In runtime/docker-compose.yaml
#    under services.apisix, add:
#
#      environment:
#        - OPENAI_API_KEY
#
#    (the bare form pulls the value from the host shell / .env file)

# 3. Recreate APISIX so the new env var is applied
docker compose up -d --force-recreate apisix
```

For production, source the key from a secret manager (Vault, k8s `Secret`,
sealed-secrets, AWS/GCP secret manager) and project it into the APISIX
container — never bake it into the image, and never commit the `.env` file.

## 4. Make a governed call

```bash
curl -sS http://localhost:9080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Say hello in three words"}]
  }' | jq
```

You'll see the upstream's response, plus extra `X-Aria-*` headers that
prove governance ran:

```
X-Aria-Tokens-Input:        14
X-Aria-Tokens-Output:        5
X-Aria-Quota-Daily-Used:    19
X-Aria-Quota-Daily-Remain:  99981
X-Aria-Budget-Used-Cents:    2
X-Aria-Trace-Id:             d9f2…
```

What just happened:

1. APISIX received the request and invoked `aria-shield`.
2. The plugin counted tokens with the bundled tiktoken-compatible
   tokenizer (no API call needed).
3. Quota state was incremented in Redis.
4. The request was forwarded to OpenAI.
5. Response tokens were counted, budget incremented.
6. Headers added; metrics emitted.

## 5. Add masking

To strip PII out of requests before they leave your perimeter, layer
`aria-mask` onto the same route. Add a second plugin block:

```yaml
- uri: /v1/chat/completions
  plugins:
    aria-mask:
      auto_detect:
        enabled: true
        patterns: [email, phone, iban, msisdn]
      role_policies:
        default: { default_strategy: mask }
        admin:   { default_strategy: full }
    aria-shield:
      # …as before…
```

Now send a request that contains PII:

```bash
curl -sS http://localhost:9080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"gpt-4o-mini",
    "messages":[{"role":"user","content":"My email is alice@example.com, summarize this thread"}]
  }' | jq
```

Check the sidecar log:

```bash
docker compose logs aria-runtime | grep mask
```

You'll see the `alice@example.com` was masked to `a****@e*****.com`
before the request crossed the perimeter — the upstream LLM never saw
the original.

## 6. Try a canary

Canary is the most powerful plugin and the one most worth playing with.
A minimal config that splits traffic 5% → 25% → 100% with auto-rollback:

```yaml
- uri: /api/orders/*
  plugins:
    aria-canary:
      canary_upstream:
        nodes: { "orders-v2:8080": 1 }
      schedule:
        - { pct: 5,   hold: "5m" }
        - { pct: 25,  hold: "10m" }
        - { pct: 100, hold: "0" }
      error_threshold_delta: 2.0
      rollback_sustained_seconds: 60
      shadow_diff:
        enabled: true
        sample_rate: 0.1
  upstream:
    type: roundrobin
    nodes: { "orders-v1:8080": 1 }
```

`shadow_diff.enabled: true` is the **shadow canary** — alongside the live
percentage split, 10% of requests are also sent to v2 in the background
and the response is structurally diffed against v1's. You see what would
have changed *before* you ramp the live traffic. Diffs land in
`docker compose logs aria-runtime | grep shadow.diff`.

Canary status (live cohort, error rate, schedule position):

```bash
curl -s http://localhost:9080/aria/canary/api-orders/status | jq
```

## 7. Open the dashboards

```
http://localhost:3000     (admin / admin)
```

Three pre-built dashboards under **General** folder:

- **Aria Shield** — token spend, cost by consumer, rate-limit hits, provider failover, circuit breaker state
- **Aria Mask** — masking ops/sec, PII detections by category, NER engine latency
- **Aria Canary** — current traffic split, error rate delta, rollback events, shadow diff distributions

Metrics are scraped from APISIX (`:9091`) and the sidecar (`:8081/actuator/prometheus`).

## Endpoint reference

| Endpoint | Purpose |
|---|---|
| `localhost:9080` | APISIX gateway (HTTP) — your application traffic |
| `localhost:9443` | APISIX gateway (HTTPS) — terminate TLS here |
| `localhost:9091` | APISIX Prometheus metrics |
| `localhost:8081/healthz` | Sidecar liveness |
| `localhost:8081/readyz` | Sidecar readiness (includes Redis + PostgreSQL) |
| `localhost:8081/actuator/prometheus` | Sidecar Prometheus metrics |
| `localhost:3000` | Grafana dashboards |
| `localhost:5432` | PostgreSQL (dev only — never expose in prod) |
| `localhost:6379` | Redis (dev only — never expose in prod) |

## Troubleshooting

**`/healthz` returns connection refused**
- The sidecar is still starting (~10s cold start). `docker compose logs aria-runtime | tail` to watch.
- If it persists, the JVM crashed at startup — check the log for stack traces.

**`/readyz` returns 503 with `redis: false` or `postgres: false`**
- The dependent container hasn't finished initialising yet. Compose's
  `depends_on` only waits for *start*, not for *ready*. Wait ~10s and retry.
- If permanently 503, check `docker compose logs redis` and
  `docker compose logs postgres` for credential or boot errors.

**APISIX returns 404 for a route I added to `apisix.yaml`**
- Did you keep the `#END` marker at the bottom of the file?
- Did APISIX hot-reload? `docker compose logs apisix | grep config`. If
  not, `docker compose restart apisix` is the safe nuclear option.

**`X-Aria-*` headers missing from the response**
- The route doesn't have `aria-shield` plugin attached. Plugin order
  matters in `apisix.yaml` — Shield should run before any provider
  rewriting plugin.

**PII masking didn't fire**
- `auto_detect.enabled` defaults to `false` for backward compatibility;
  set it `true` and list the patterns you want.
- For free-text NER (Turkish/English entity recognition), you must mount
  model files into the sidecar — see `runtime/docs/NER_MODELS.md`. The
  default image ships **engine code only**, no models.

## Tearing down

```bash
docker compose down -v   # stops everything and removes volumes
```

`-v` is important: without it, the PostgreSQL volume persists across
runs, so the next `up` reuses the old schema.

## Where to next

- [`docs/05_user/USER_GUIDE.md`](USER_GUIDE.md) — full plugin reference,
  every option for every plugin.
- [`runtime/docs/CONFIGURATION.md`](../../runtime/docs/CONFIGURATION.md) —
  every config knob the sidecar exposes.
- [`runtime/docs/DEPLOYMENT.md`](../../runtime/docs/DEPLOYMENT.md) —
  Kubernetes and production deployment shapes.
- [`runtime/docs/NER_MODELS.md`](../../runtime/docs/NER_MODELS.md) —
  installing optional NER model artefacts for non-English masking.
- `docs/03_architecture/HLD.md` — the design rationale, if you want to
  understand *why* it's built this way before extending it.

---

**3eAI Labs Ltd** — *Ethic · Empathy · Aesthetic*
Open-core: Apache 2.0 Lua plugins · community sidecar · persona-gated enterprise tiers (Security · Privacy · FinOps)
