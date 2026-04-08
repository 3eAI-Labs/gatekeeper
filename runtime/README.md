# Aria Runtime — Java 21 Sidecar

Aria Runtime is the high-performance processing backend for 3e-Aria-Gatekeeper plugins. It provides capabilities that go beyond what Lua can efficiently handle:

| Feature | Module | What It Does |
|---------|--------|-------------|
| **Prompt Analysis** | Shield | Vector-similarity injection detection beyond regex |
| **Token Counting** | Shield | Exact tiktoken counting for billing accuracy |
| **Content Filtering** | Shield | LLM response moderation |
| **NER PII Detection** | Mask | Named Entity Recognition for PII beyond regex patterns |
| **Shadow Diff Engine** | Canary | Structural comparison of primary vs. shadow responses |

## Architecture

```
┌─────────────────── APISIX Pod ───────────────────┐
│                                                    │
│  APISIX Container          Aria Runtime Container  │
│  ┌──────────────┐          ┌───────────────────┐  │
│  │ Lua Plugins  │◄─ UDS ──►│ gRPC Server       │  │
│  │ (aria-*)     │  ~0.1ms  │ (Java 21)         │  │
│  └──────────────┘          │ Virtual Threads    │  │
│                            │ ScopedValue        │  │
│                            └───────────────────┘  │
│                                                    │
│  Shared Volume: /var/run/aria/aria.sock             │
└────────────────────────────────────────────────────┘
```

**Communication:** gRPC over Unix Domain Socket (~0.1ms round-trip)
**Threading:** Java 21 Virtual Threads (10K+ concurrent requests)
**Context:** ScopedValue (not ThreadLocal) for per-request propagation

## Without the Runtime

The Lua plugins work **standalone without the sidecar**. When the runtime is unavailable, features degrade gracefully:

| Feature | With Runtime | Without Runtime |
|---------|-------------|-----------------|
| Prompt injection detection | Regex + vector similarity | Regex only |
| Token counting | Exact (tiktoken) | Approximate (word heuristic) |
| PII detection | Regex + NER | Regex only |
| Content filtering | Active | Disabled |
| Shadow diff | Active | Disabled |

## Getting Started

### Docker Compose (quickest)

```bash
docker-compose up -d
```

See [docker-compose.yaml](docker-compose.yaml) for the full configuration.

### Helm (Kubernetes)

```bash
helm install aria ./helm/aria-gatekeeper/
```

See [helm/aria-gatekeeper/values.yaml](helm/aria-gatekeeper/values.yaml) for all options.

### Docker (standalone)

```bash
docker run -d \
  --name aria-runtime \
  -v /var/run/aria:/var/run/aria \
  -e ARIA_REDIS_HOST=redis \
  -e ARIA_POSTGRES_HOST=postgres \
  -p 8081:8081 \
  ghcr.io/3eai-labs/aria-runtime:latest
```

## Configuration

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for all environment variables and options.

## gRPC API

The runtime exposes 4 gRPC services over UDS. Proto definitions are in [proto/](proto/):

| Service | Methods | Proto File |
|---------|---------|-----------|
| `ShieldService` | AnalyzePrompt, CountTokens, FilterResponse | [shield.proto](proto/aria/sidecar/v1/shield.proto) |
| `MaskService` | DetectPII | [mask.proto](proto/aria/sidecar/v1/mask.proto) |
| `CanaryService` | DiffResponses | [canary.proto](proto/aria/sidecar/v1/canary.proto) |
| `HealthService` | Check | [health.proto](proto/aria/sidecar/v1/health.proto) |

## Health Checks

| Endpoint | Purpose | Returns 200 When |
|----------|---------|-----------------|
| `GET /healthz` | Liveness probe | JVM is alive |
| `GET /readyz` | Readiness probe | Redis AND Postgres reachable |

## License

Aria Runtime is distributed as a binary (Docker image). Source code is proprietary.
The Lua plugins and proto definitions in this directory are Apache 2.0.

For enterprise licensing: enterprise@3eai-labs.com
