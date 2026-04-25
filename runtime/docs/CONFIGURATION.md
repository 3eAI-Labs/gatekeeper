# Aria Runtime — Configuration Reference

This document is the **operator's source of truth** for every configurable
knob in the `aria-runtime` sidecar. The Lua plugin in APISIX is configured
separately through APISIX's plugin schema (see the `gatekeeper/apisix/`
directory and the upstream APISIX docs).

## Configuration layers

Settings are resolved in this priority order (later wins):

1. **Compiled defaults** — declared on the Java config classes
   (`AriaConfig.java`, `NerProperties.java`, etc.).
2. **`application.yml`** — bundled inside the JAR and exposed inside the
   container at `/app/BOOT-INF/classes/application.yml`. You normally don't
   edit this file; mount overrides instead.
3. **External `application.yml`** — Spring Boot scans
   `./config/application.yml` and `./application.yml` next to the JAR.
   In Kubernetes, mount your override as a `ConfigMap` volume to
   `/app/config/application.yml`.
4. **Environment variables** — every property in the bundled
   `application.yml` is wrapped in a `${VAR:default}` placeholder, so any
   single setting can be overridden without supplying a full YAML file.
5. **JVM `-Dkey=value` system properties** — useful for one-off debug runs.
6. **Command-line `--key=value` arguments** — highest priority.

For most production deployments you only need **environment variables**
plus a small `application.yml` patch for things that can't be expressed as
flat strings (e.g. a list of NER engines).

## Minimal viable config

The sidecar will start with no external configuration at all — every
setting has a working default suitable for a developer laptop with Redis
and PostgreSQL on `localhost`. The smallest production-grade override is:

```yaml
# config/application.yml
aria:
  redis:
    host: redis-cluster.svc.cluster.local
    password: ${REDIS_PASSWORD}
  postgres:
    host: pg-primary.svc.cluster.local
    password: ${PG_PASSWORD}
```

with the two passwords supplied as environment variables (sealed-secret /
external-secret operator pattern). Everything else inherits defaults.

## Core runtime

| YAML key | Env var | Default | Description |
|---|---|---|---|
| `server.port` | `SERVER_PORT` | `8081` | HTTP port for `/actuator/health`, `/actuator/metrics`, `/actuator/info`. The gRPC traffic is **not** on this port — it flows over the UDS socket below. |
| `aria.uds-path` | `ARIA_UDS_PATH` | `/var/run/aria/aria.sock` | Unix Domain Socket path the Lua plugin connects to. Both APISIX and the sidecar must mount this directory; permissions on the parent dir matter (see *UDS hygiene* below). |
| `aria.shutdown-grace-seconds` | `ARIA_SHUTDOWN_GRACE_SECONDS` | `30` | Maximum drain window after `SIGTERM`. The sidecar stops accepting new gRPC calls immediately and waits up to this long for in-flight calls to finish. Set higher for canary deployments where requests can take seconds. |

### UDS hygiene

The default UDS path lives in `/var/run/aria/`. Three rules:

1. The directory must exist before the sidecar starts (`emptyDir` volume in
   k8s, or `tmpfs` mount in docker-compose).
2. Both containers (`apisix` and `aria-runtime`) must share the same
   volume mount and run as a UID/GID that has read+write on the directory.
3. The socket file is created with mode `0660`. APISIX's worker UID must
   be in the socket's group — easiest is to run both containers as the
   same numeric UID.

Failing rule 2 or 3 is the most common cause of `permission denied` errors
in the Lua plugin's `connect()` call.

## Datastores

### Redis

Used for: rate-limit counters, idempotency keys, ephemeral mask cache,
canary cohort assignments.

| YAML key | Env var | Default |
|---|---|---|
| `aria.redis.host` | `ARIA_REDIS_HOST` | `127.0.0.1` |
| `aria.redis.port` | `ARIA_REDIS_PORT` | `6379` |
| `aria.redis.password` | `ARIA_REDIS_PASSWORD` | (empty) |
| `aria.redis.database` | `ARIA_REDIS_DATABASE` | `0` |
| `aria.redis.timeout-ms` | (override yaml) | `2000` |

**Notes**
- The Lettuce client is async with auto-reconnect; transient connection
  loss does not surface as a request error unless it exceeds `timeout-ms`.
- For Redis Cluster (the default in the recommended stack), set `host` to
  any seed node; Lettuce will discover the rest.
- For TLS, prefix `host` with `rediss://` (Lettuce parses the URI scheme).

### PostgreSQL

Used for: persistent canary configuration, audit log of governance
decisions, license-key validation cache.

| YAML key | Env var | Default |
|---|---|---|
| `aria.postgres.host` | `ARIA_POSTGRES_HOST` | `127.0.0.1` |
| `aria.postgres.port` | `ARIA_POSTGRES_PORT` | `5432` |
| `aria.postgres.database` | `ARIA_POSTGRES_DATABASE` | `aria` |
| `aria.postgres.username` | `ARIA_POSTGRES_USERNAME` | `aria` |
| `aria.postgres.password` | `ARIA_POSTGRES_PASSWORD` | (empty) |

**Notes**
- The driver is **R2DBC** (`io.r2dbc:r2dbc-postgresql`), not JDBC. Pool
  config is hard-coded inside `AriaConfig` (initial=1, max=8) — change the
  source if you need a larger pool.
- Spring Boot's `R2dbcAutoConfiguration` is **explicitly excluded** in
  `application.yml`; the pool is built manually so the sidecar can boot
  without `spring.r2dbc.url` being set.
- Schema migrations are applied by the `aria-migrator` job, not by the
  sidecar at startup. Run migrations before rolling new sidecar versions.

## Mask — NER pipeline

The NER (Named Entity Recognition) pipeline detects PII entities
(`PERSON`, `ORGANIZATION`, `LOCATION`, …) in user prompts so the Lua
plugin can mask them before forwarding. The sidecar ships engine **code**
but not model **artefacts** — see [`NER_MODELS.md`](./NER_MODELS.md) for
the recipes to install models you need.

### Pipeline-level

| YAML key | Env var | Default | Description |
|---|---|---|---|
| `aria.mask.ner.engines` | `ARIA_NER_ENGINES` | `opennlp` | Comma-separated list of engine ids to activate, in call order. Empty list disables NER (the composite returns `[]` and the Lua plugin falls back to regex-only masking). |
| `aria.mask.ner.min-confidence` | `ARIA_NER_MIN_CONFIDENCE` | `0.7` | Per-entity confidence floor applied before deduplication. Raise to reduce false positives; lower for recall-sensitive workloads. Values outside `[0.0, 1.0]` are clamped. |

**Engine registration** is auto-discovered: the registry instantiates each
`NerEngine`-implementing bean and includes it only if `isReady()` returns
`true`. A missing model file is **not** a startup error — the engine logs
one info line and the registry skips it. This means you can ship the same
image to environments with different model coverage.

### Engine: OpenNLP (English)

| YAML key | Env var | Default |
|---|---|---|
| `aria.mask.ner.opennlp.models-dir` | `ARIA_NER_OPENNLP_DIR` | `/opt/aria/models/opennlp` |

Drop `en-ner-person.bin`, `en-ner-location.bin`, `en-ner-organization.bin`
into this directory. The engine auto-detects which of the three models are
present at startup.

### Engine: HuggingFace (token classification, e.g. Turkish BERT)

| YAML key | Env var | Default |
|---|---|---|
| `aria.mask.ner.turkish-bert.id` | `ARIA_NER_TURKISH_ID` | `turkish-bert` |
| `aria.mask.ner.turkish-bert.model-path` | `ARIA_NER_TURKISH_MODEL` | `/opt/aria/models/turkish-bert/model.onnx` |
| `aria.mask.ner.turkish-bert.tokenizer-path` | `ARIA_NER_TURKISH_TOKENIZER` | `/opt/aria/models/turkish-bert/tokenizer.json` |
| `aria.mask.ner.turkish-bert.labels` | `ARIA_NER_TURKISH_LABELS` | (empty → defaults to `savasy/bert-base-turkish-ner-cased` BIO labels) |

> The engine is named `turkish-bert` for historical reasons but is a
> generic HuggingFace token-classification loader. To run a different
> language model (e.g. multilingual NER), point the paths at your ONNX
> file and override `labels` to match the model's output order. Multiple
> instances are not supported in a single sidecar today — pick one
> HuggingFace checkpoint per deployment.

### Engine: circuit breaker

The breaker wraps every `detect(...)` call so a misbehaving model doesn't
cascade into request failures. The Lua plugin carries its own outer
breaker; this one is defense-in-depth at the JVM layer.

| YAML key | Env var | Default | Description |
|---|---|---|---|
| `aria.mask.ner.circuit-breaker.failure-rate-threshold` | `ARIA_NER_CB_FAILURE_PCT` | `50` | Percentage of failing calls in the sliding window that trips the breaker. |
| `aria.mask.ner.circuit-breaker.wait-duration-ms` | `ARIA_NER_CB_WAIT_MS` | `30000` | Cooldown in the open state before a single probe is allowed through. |
| `aria.mask.ner.circuit-breaker.sliding-window-size` | `ARIA_NER_CB_WINDOW` | `20` | Rolling window of call outcomes. Smaller windows react faster but are noisier. |
| `aria.mask.ner.circuit-breaker.permitted-calls-in-half-open` | `ARIA_NER_CB_HALF_OPEN` | `3` | Trial calls allowed through in the half-open state. |
| `aria.mask.ner.circuit-breaker.timeout-ms` | `ARIA_NER_CB_TIMEOUT_MS` | `1000` | Per-`detect()` timeout; calls exceeding this count as failures. |

When the breaker is open the engine returns an empty entity list and
emits the `aria.mask.ner.circuit_open` metric counter. The sidecar **does
not** fail the request — it falls back to the upstream entities the Lua
plugin already extracted with regexes (defense in depth).

## Observability

### Health & info endpoints

The sidecar exposes two **custom k8s-shaped** probes plus the standard
Spring Boot Actuator endpoints. Use the custom ones for `livenessProbe` /
`readinessProbe` — they're shorter, return a stable JSON shape, and don't
depend on Actuator's plumbing.

| Path | Owner | Purpose |
|---|---|---|
| `GET /healthz` | `HealthController` | **Liveness.** Returns `200 {"status":"alive"}` if the JVM is up. No dependency checks. |
| `GET /readyz` | `HealthController` | **Readiness.** Returns `200 {"ready":true,"dependencies":{...}}` only when Redis **and** PostgreSQL respond. Returns `503` during graceful shutdown or when any dependency is down. |
| `GET /actuator/health` | Spring Boot | Composite health used by humans and dashboards. |
| `GET /actuator/info` | Spring Boot | Build version, git commit, license tier. |
| `GET /actuator/metrics` | Spring Boot | Micrometer metric registry. |

Health detail is exposed via `management.endpoint.health.show-details: always`
for in-cluster diagnostics. If you expose `/actuator/*` outside the cluster,
override this to `when-authorized` or `never`.

### Metrics

The sidecar exposes Prometheus-format metrics at
`GET /actuator/metrics/{name}`. Notable gauges and counters:

| Metric | Type | Description |
|---|---|---|
| `aria.mask.ner.detect.duration` | Timer | Per-call latency, tagged by engine id. |
| `aria.mask.ner.entities` | Counter | Number of entities returned, tagged by entity type. |
| `aria.mask.ner.circuit_open` | Counter | Times the engine breaker tripped. |
| `aria.canary.shadow.diff.total` | Counter | Shadow canary diffs computed. |
| `aria.canary.shadow.diff.size` | Distribution | Diff payload size in bytes. |
| `aria.uds.connections.active` | Gauge | Live gRPC streams from APISIX. |

To scrape Prometheus, add the `micrometer-registry-prometheus` dependency
in your fork or run a sidecar `node_exporter`-style collector.

### Logging

Logs are emitted as **single-line JSON** by default — no Logback config
file needed. The pattern is:

```json
{"timestamp":"2026-04-24T10:15:32.108Z","level":"INFO",
 "service":"aria-runtime","logger":"com.eai.aria...",
 "message":"..."}
```

Override the root or per-package log level via env vars:

| Env var | Effect |
|---|---|
| `LOGGING_LEVEL_ROOT=DEBUG` | Verbose — diagnostics only, not production. |
| `LOGGING_LEVEL_COM_EAI_ARIA=DEBUG` | Sidecar-only debug; quieter than root. |
| `LOGGING_LEVEL_IO_GRPC=WARN` | Suppress noisy gRPC stream lifecycle logs. |

For Loki / ELK ingest, the JSON pattern parses out-of-the-box; no Logstash
filter needed.

## JVM tuning

The Docker image starts the JVM with these flags:

| Flag | Purpose |
|---|---|
| `--enable-preview` | Required for `ScopedValue` and other Java 21 preview APIs used in the request scope plumbing. |
| `-XX:+UseZGC` | Sub-millisecond GC pauses; matters because the sidecar is on the request hot path. |
| `-XX:MaxRAMPercentage=75` | Heap ceiling = 75% of container memory limit. The remaining 25% covers DJL native allocations (ONNX Runtime is off-heap), gRPC direct buffers, and OS file cache. |

Override via the standard `JAVA_TOOL_OPTIONS` env var:

```yaml
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-XX:MaxRAMPercentage=60 -XX:+ExitOnOutOfMemoryError"
```

**Don't** disable preview features — the sidecar will fail to start.

## Resource sizing

The sizing below assumes mask + canary + observability are active and NER
runs OpenNLP only (English). Add ~150 MiB resident set if a Turkish-BERT
ONNX model is also loaded. GPU acceleration is **not** assumed.

| Deployment size | CPU request | CPU limit | Memory request | Memory limit | Concurrent gRPC streams |
|---|---|---|---|---|---|
| Small (< 100 req/s) | 100m | 250m | 192Mi | 256Mi | 1K virtual threads |
| Medium (< 1K req/s) | 250m | 500m | 320Mi | 384Mi | 5K virtual threads |
| Large (< 10K req/s) | 500m | 1000m | 480Mi | 512Mi | 10K+ virtual threads |
| Extra-large (10K+ req/s) | 1000m | 2000m | 768Mi | 1Gi | Run multiple replicas behind a sidecar daemonset |

The sidecar is **stateless** — every replica can serve any request.
Horizontal scaling is by replica count, not vertical.

## Production checklist

Before promoting to a production environment, verify:

- [ ] **Datastore secrets**: `ARIA_REDIS_PASSWORD` and `ARIA_POSTGRES_PASSWORD`
      come from a secret manager (sealed-secrets, external-secrets, vault),
      not committed YAML.
- [ ] **UDS volume**: shared `emptyDir` between `apisix` and `aria-runtime`;
      both containers run with the same numeric UID.
- [ ] **Health probes**: k8s `livenessProbe` → `/healthz`, `readinessProbe`
      → `/readyz`; `initialDelaySeconds: 15` to absorb model load time.
- [ ] **Metrics scraping**: Prometheus annotations or a `ServiceMonitor`
      configured to hit `/actuator/metrics`.
- [ ] **NER models**: confirm the engines you listed in
      `aria.mask.ner.engines` actually report `ready=true` in the startup
      log; if any are `not ready`, either fix the model path or remove
      from the list.
- [ ] **Resource limits**: CPU/memory match expected request volume per
      the sizing table above; never run without limits in a shared
      cluster.
- [ ] **Log level**: root level is `INFO`; `DEBUG` only enabled
      transiently for diagnosis.
- [ ] **Shutdown hook**: `aria.shutdown-grace-seconds` covers your slowest
      expected upstream LLM round-trip (canary requests can be seconds).
- [ ] **License tier**: enterprise-only features (advanced canary,
      Shield) are gated by the license key; verify `/actuator/info` shows
      the tier you expect.

## Troubleshooting common config mistakes

**Sidecar starts but Lua plugin gets `connect: permission denied`**
- The UDS file exists but APISIX's UID doesn't have group read on it.
  Fix: run both containers as the same UID, or set the directory's group
  to a shared GID and chmod to `0770`.

**`/actuator/health` returns 503 with `down` for `r2dbc`**
- PostgreSQL is reachable but credentials are wrong, or the `aria`
  database doesn't exist. Check the migrator job ran successfully.

**`min-confidence` is set but the masking is too aggressive / too loose**
- Confidence is the *minimum* before dedup; raising it filters out
  ambiguous matches but also drops legitimate ones. Tune against a labeled
  fixture set (see `aria-runtime/src/test/resources/ner-fixtures/`).

**NER engine logs `ready: false` even though I mounted the model**
- Check the path the engine logged matches what you mounted. The model
  file must be **readable** by the JVM UID — `chmod a+r model.onnx`.
- For ONNX models, the file must be **valid ONNX** and use opset ≤ 17;
  newer opsets aren't supported by the bundled ONNX Runtime.

**`MaxRAMPercentage=75` plus a large Turkish BERT FP32 model causes OOM**
- The 25% headroom isn't enough for a 440 MB FP32 model + ONNX Runtime
  arenas. Either size the container memory up, or run a smaller model
  variant. Model sizing is the operator's choice — see `NER_MODELS.md`
  for what's available; we don't ship the artefacts.

**Circuit breaker keeps tripping in the first 30 seconds**
- The window is `sliding-window-size: 20` calls — if your first 20 calls
  hit a cold model with high `timeout-ms`, you'll see early flapping.
  Either pre-warm the model with a startup probe or raise
  `failure-rate-threshold` for the cold-start period.

## See also

- [`DEPLOYMENT.md`](./DEPLOYMENT.md) — how to package and run the sidecar.
- [`NER_MODELS.md`](./NER_MODELS.md) — installing NER model artefacts.
- `docs/05_user/USER_GUIDE.md` — end-user documentation for the gateway plugin.
- `docs/03_architecture/HLD.md` — why the sidecar exists at all.
