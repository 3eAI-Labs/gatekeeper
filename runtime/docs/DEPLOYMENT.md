# Aria Runtime — Deployment Guide

Three supported deployment shapes:

1. **Local dev** — `docker-compose` with APISIX, Redis, PostgreSQL, and the
   sidecar all running side-by-side. Best for development and demos.
2. **Single-host production** — same `docker-compose` topology with
   external secrets and managed datastores. Suitable for pilots and small
   internal deployments.
3. **Kubernetes** — APISIX and `aria-runtime` co-located **in the same
   pod** via the sidecar pattern, communicating over a shared Unix Domain
   Socket. Ships with a Helm chart for the sidecar half; APISIX colocation
   needs a small extension (see *Kubernetes — sidecar pattern* below).

> **A note on the sidecar pattern.** The `aria-runtime` container talks to
> APISIX over a UDS file in a shared volume. Unix Domain Sockets only work
> *within a single Linux kernel namespace* — i.e. **same pod**. You cannot
> put APISIX and the sidecar in separate Deployments and connect them
> over a Service IP; that's TCP, not UDS. The helm chart in this repo
> deploys the sidecar half; pairing it with APISIX is the operator's
> integration step.

## Prerequisites

| Service | Version | Why |
|---|---|---|
| Docker / OCI runtime | 24+ | Multi-arch image, BuildKit features used in the build pipeline. |
| Apache APISIX | 3.8+ | Plugin host. The Lua plugins target the 3.8 plugin loader API. |
| Redis | 7.0+ (Cluster recommended) | Quota counters, idempotency keys, canary cohort assignment, ephemeral mask cache. |
| PostgreSQL | 16+ | Audit trail, persistent canary configuration, license-key validation cache. |
| Kubernetes | 1.27+ (only for k8s deployment) | The Helm chart uses `apps/v1` and standard probe semantics — no exotic CRDs. |
| Helm | 3.12+ | Chart syntax used. |

Kubernetes deployments additionally benefit from:

- **Prometheus Operator** — the chart ships a `PrometheusRule` template
  with sensible alert defaults (provider-down, sidecar-down, audit
  buffer overflow, canary rollback).
- **Grafana** with the dashboard sidecar — the chart can label dashboards
  for auto-discovery via the standard `grafana_dashboard=1` annotation.

## Image references

The sidecar image is published from this repo's CI:

| Registry | Path |
|---|---|
| GitHub Container Registry | `ghcr.io/3eai-labs/gatekeeper/aria-runtime:<tag>` |

Tags follow [Semantic Versioning](https://semver.org). Use:

- `:latest` for **dev only** — every push to `main` updates this tag.
- `:0.1.0` (or any explicit version) for **everything else**.
- `:0.1.0-amd64` / `:0.1.0-arm64` if you need a single-arch pull (the
  default tag is a multi-arch manifest).

## Local development — docker-compose

The `runtime/docker-compose.yaml` brings up the full stack:

- `apisix` (3.8.0) — gateway with Aria plugins mounted from
  `../apisix/plugins/` (read-only)
- `aria-runtime` (`:latest`) — sidecar with health on `:8081`
- `redis` (7-alpine) — small in-memory store, 256 MB ceiling, LRU
- `postgres` (16-alpine) — runs `db/migration/*.sql` at first boot via
  the standard `/docker-entrypoint-initdb.d/` path
- `grafana` (10.4.0) — optional, dashboards from `../dashboards/` mounted

```bash
cd runtime
docker compose up -d

# Health check
curl -s http://localhost:8081/healthz | jq
curl -s http://localhost:8081/readyz  | jq

# APISIX Admin (no key in standalone mode)
curl -s http://localhost:9080/apisix/status

# Grafana
open http://localhost:3000  # admin / admin
```

The compose file uses the `:latest` tag — for reproducible local work,
override:

```bash
ARIA_TAG=0.1.0 docker compose up -d
```

after editing `aria-runtime.image` to read from `${ARIA_TAG:-latest}`.

## Single-host production

For a pilot or small internal deployment, the same compose file works
with three production hardening steps:

1. **Move passwords out of the compose file.** Replace inline values
   with `${VAR}` references and source them from a `.env` file owned
   by `root:root`, mode `0600`, mounted into the host but **not**
   committed.
2. **Use managed datastores.** Replace the `redis` and `postgres`
   services with `external_links` or remove them entirely and point
   `ARIA_REDIS_HOST` / `ARIA_POSTGRES_HOST` at your managed instances
   (AWS ElastiCache + RDS, GCP Memorystore + Cloud SQL, etc.).
3. **Pin the image tag.** Never run `:latest` in production — pick a
   specific version, test it, and only roll forward through your
   change management process.

```bash
# .env on the host
ARIA_TAG=0.1.0
REDIS_PASSWORD=<from-vault>
PG_PASSWORD=<from-vault>

# docker-compose.override.yaml
services:
  aria-runtime:
    image: ghcr.io/3eai-labs/gatekeeper/aria-runtime:${ARIA_TAG}
    environment:
      ARIA_REDIS_PASSWORD: ${REDIS_PASSWORD}
      ARIA_POSTGRES_PASSWORD: ${PG_PASSWORD}
```

## Kubernetes — sidecar pattern

### Why same-pod

The Lua plugin in APISIX must reach the sidecar over a **Unix Domain
Socket** for two reasons:

1. **Latency.** UDS round-trip is ~5–10 μs; TCP loopback is ~50–100 μs.
   On the request hot path with multiple plugin hops, this matters.
2. **Security.** The socket is a file. File permissions (`0660` + shared
   group) gate who can connect — there's no port to firewall, no TLS
   to terminate, no service mesh to traverse.

UDS only works within a single Linux network namespace — i.e. inside
**one Pod**. Two Pods talking over a Service IP is TCP, not UDS, and
the Lua plugin won't connect.

### Pod skeleton

The minimum viable pod runs both containers and shares an `emptyDir`
volume mounted at `/var/run/aria` in both:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apisix-with-aria
spec:
  replicas: 2
  selector:
    matchLabels:
      app: apisix-with-aria
  template:
    metadata:
      labels:
        app: apisix-with-aria
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8081"
        prometheus.io/path: "/actuator/prometheus"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000           # both containers share GID for UDS access
      containers:
        - name: apisix
          image: apache/apisix:3.8.0-debian
          ports:
            - containerPort: 9080      # http
            - containerPort: 9443      # https
          volumeMounts:
            - name: aria-uds
              mountPath: /var/run/aria
            - name: aria-plugins
              mountPath: /opt/aria-plugins/apisix/plugins
              readOnly: true
            - name: apisix-config
              mountPath: /usr/local/apisix/conf/config.yaml
              subPath: config.yaml

        - name: aria-runtime
          image: ghcr.io/3eai-labs/gatekeeper/aria-runtime:0.1.0
          ports:
            - containerPort: 8081      # health + metrics
          env:
            - name: ARIA_REDIS_HOST
              value: redis-cluster.svc.cluster.local
            - name: ARIA_REDIS_PASSWORD
              valueFrom:
                secretKeyRef: { name: aria-secrets, key: redis-password }
            - name: ARIA_POSTGRES_HOST
              value: postgres.svc.cluster.local
            - name: ARIA_POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: aria-secrets, key: postgres-password }
          volumeMounts:
            - name: aria-uds
              mountPath: /var/run/aria
          livenessProbe:
            httpGet: { path: /healthz, port: 8081 }
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: 8081 }
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 1
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]
          resources:
            requests: { cpu: 250m, memory: 320Mi }
            limits:   { cpu: 500m, memory: 384Mi }

      volumes:
        - name: aria-uds
          emptyDir: {}
        - name: aria-plugins
          configMap:
            name: aria-plugins        # rendered by the helm chart
        - name: apisix-config
          configMap:
            name: apisix-config       # operator-supplied
      terminationGracePeriodSeconds: 30
```

Key points:

- `fsGroup: 1000` — both containers see `/var/run/aria` as group-owned
  by GID 1000, so the socket file (created `0660`) is readable by both.
- `livenessProbe` on `/healthz` (no dependency check) — restarts only on
  hard JVM hang.
- `readinessProbe` on `/readyz` (Redis + PostgreSQL must respond) —
  removes the pod from Service rotation if dependencies blip, but
  doesn't restart it.
- `preStop sleep 5` — gives the readiness probe one cycle to flip and
  Service to drain endpoints before the SIGTERM.
- `terminationGracePeriodSeconds` matches `aria.shutdown-grace-seconds`
  on the runtime side.

### Helm chart

The chart at `runtime/helm/aria-gatekeeper/` ships:

| Template | Purpose |
|---|---|
| `sidecar-deployment.yaml` | The `aria-runtime` container half of the sidecar pair. **Ships standalone** — you must extend it to add the APISIX container, or apply the manifest into an existing pod spec via Kustomize / a wrapper chart. |
| `configmap-plugins.yaml` | Renders the Lua plugins as a ConfigMap so they can be mounted into the APISIX container. |
| `secret.yaml` | Holds `redis-password` and `postgres-password` if you didn't supply an `existingSecret`. |
| `migration-job.yaml` | Flyway job that runs DB migrations as a one-shot Job before the sidecar starts. |
| `prometheusrule.yaml` | Alert rules: provider-down, sidecar-down, audit-buffer-overflow, canary-rollback. Requires the Prometheus Operator. |

```bash
# Minimum viable install
helm install aria runtime/helm/aria-gatekeeper/ \
  --set redis.host=redis-cluster.svc.cluster.local \
  --set postgres.host=postgres.svc.cluster.local \
  --set postgres.existingSecret=postgres-credentials \
  --set postgres.existingSecretKey=password
```

### Honest gap: APISIX colocation

The chart **does not** template the APISIX container — that's the
operator's choice (you may already run APISIX from the official Apache
chart, or have customised it heavily). To pair them, two patterns work:

**Pattern A — wrap the sidecar in your own chart.** Vendor or depend on
this chart, then add an APISIX container to the same Pod template via
Kustomize or a chart-of-charts.

**Pattern B — fork the sidecar template.** Copy
`sidecar-deployment.yaml` into your own chart, add the APISIX container
spec, point both at the same UDS volume, render with both halves
together.

We don't recommend (or test) running the chart with `runtime.enabled:
false` and trying to bridge the sidecar from a separate Pod over TCP —
the Lua plugin doesn't speak TCP to the sidecar today.

## Building from source

The sidecar JAR is built by Gradle in the `aria-runtime` repository
(separate from `gatekeeper` — see the parent README for repo layout):

```bash
cd ../aria-runtime
./gradlew bootJar               # → build/libs/aria-runtime.jar
docker build -t aria-runtime:dev .
```

Optional flags:

- `-PwithTurkishNer=true` — bake `src/main/resources/models/turkish-bert/`
  into the JAR (only useful if you've placed the model files there
  yourself; see `runtime/docs/NER_MODELS.md`).

To produce a multi-arch image:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/3eai-labs/gatekeeper/aria-runtime:0.1.0 \
  --push .
```

## Database migrations

The schema lives in `gatekeeper/db/migration/` (Flyway-format SQL files).
The Helm chart ships a Job that runs Flyway against the configured
PostgreSQL **before** the sidecar Deployment is rolled.

For non-Helm deployments, run migrations manually before deploying a new
sidecar version:

```bash
docker run --rm \
  --network host \
  -v $(pwd)/db/migration:/flyway/sql:ro \
  flyway/flyway:10-alpine \
  -url=jdbc:postgresql://localhost:5432/aria \
  -user=aria \
  -password=$PG_PASSWORD \
  migrate
```

**Never** roll a new sidecar version forward without first running its
migrations — startup will succeed but feature-level queries may fail.

## Upgrade workflow

1. **Read the release notes** for any migration or config breaking
   changes (`docs/06_review/RELEASE_NOTES.md`).
2. **Run migrations** against staging, verify they're clean.
3. **Roll the sidecar** to staging with the new image tag; check
   `/readyz` reports all dependencies up.
4. **Smoke-test** through APISIX — at minimum, hit a route that touches
   the mask plugin and a route that triggers canary; verify metrics
   show traffic flowing through the sidecar.
5. **Promote to production** with a canary rollout (10% → 50% → 100%).
   The sidecar is stateless; rolling restarts are safe.

## Operational concerns

### Secrets

| Secret | How to supply |
|---|---|
| Redis password | `existingSecret` referenced by the chart, or env var `ARIA_REDIS_PASSWORD` from your secret manager. |
| PostgreSQL password | Same — `postgres.existingSecret` / `postgres.existingSecretKey` in `values.yaml`. |
| License key (enterprise tier) | Mount as a file at `/etc/aria/license.key`; the sidecar reads it once at startup. Never bake into the image. |

Use [external-secrets](https://external-secrets.io) or
[sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) — never
commit raw secrets, and never use the chart's inline `redis.password` /
`postgres.password` values outside of dev.

### Network policies

The sidecar needs:

- **Egress to Redis** (port 6379, or 6380 for TLS).
- **Egress to PostgreSQL** (port 5432).
- **Ingress from the same Pod** (`localhost:8081`) — the only thing
  that should reach the health/metrics port from outside the Pod is
  your monitoring scraper.

A typical NetworkPolicy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: aria-sidecar }
spec:
  podSelector: { matchLabels: { app: apisix-with-aria } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{ namespaceSelector: { matchLabels: { name: monitoring }}}]
      ports: [{ port: 8081 }]
  egress:
    - to: [{ podSelector: { matchLabels: { app: redis }}}]
      ports: [{ port: 6379 }]
    - to: [{ podSelector: { matchLabels: { app: postgres }}}]
      ports: [{ port: 5432 }]
    - to: [{ namespaceSelector: { matchLabels: { name: kube-system }}}]
      ports: [{ port: 53, protocol: UDP }]   # DNS
```

### RBAC

The sidecar needs **no** Kubernetes API access. If you see RBAC errors
in the logs, something is misconfigured — the sidecar should not have a
ServiceAccount with cluster permissions.

## Smoke test after deploy

Five checks, in order:

```bash
# 1. Pod is Running and Ready
kubectl get pod -l app=apisix-with-aria

# 2. Sidecar liveness
kubectl exec -it <pod> -c aria-runtime -- \
  wget -qO- http://localhost:8081/healthz

# 3. Sidecar readiness (datastores reachable)
kubectl exec -it <pod> -c aria-runtime -- \
  wget -qO- http://localhost:8081/readyz | jq

# 4. UDS file exists and is socket-shaped
kubectl exec -it <pod> -c aria-runtime -- \
  ls -la /var/run/aria/aria.sock

# 5. APISIX-side connection (look for connection errors)
kubectl logs <pod> -c apisix | grep -i 'aria\|uds\|sidecar'
```

If any step fails, see the *Troubleshooting* section of
[`CONFIGURATION.md`](./CONFIGURATION.md) — the same root causes apply.

## See also

- [`CONFIGURATION.md`](./CONFIGURATION.md) — every config knob the sidecar exposes.
- [`NER_MODELS.md`](./NER_MODELS.md) — installing optional NER model artefacts.
- `docs/03_architecture/HLD.md` — why the sidecar exists and what the trust boundaries are.
- `docs/05_user/USER_GUIDE.md` — end-user/operator usage of the gateway plugin.
