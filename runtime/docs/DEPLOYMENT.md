# Aria Runtime Deployment Guide

## Kubernetes Sidecar Pattern

Aria Runtime runs as a sidecar container alongside APISIX in the same pod. They communicate via a shared Unix Domain Socket volume.

### Pod Structure

```yaml
spec:
  containers:
    - name: apisix
      image: apache/apisix:3.8.0-debian
      volumeMounts:
        - name: aria-uds
          mountPath: /var/run/aria
        - name: aria-plugins
          mountPath: /usr/local/apisix/apisix/plugins/aria-shield.lua
          subPath: aria-shield.lua
        # ... other plugin mounts

    - name: aria-runtime
      image: ghcr.io/3eai-labs/aria-runtime:latest
      ports:
        - containerPort: 8081
      volumeMounts:
        - name: aria-uds
          mountPath: /var/run/aria
      env:
        - name: ARIA_REDIS_HOST
          value: "redis.default.svc.cluster.local"
        - name: ARIA_POSTGRES_HOST
          value: "postgres.default.svc.cluster.local"
      livenessProbe:
        httpGet:
          path: /healthz
          port: 8081
      readinessProbe:
        httpGet:
          path: /readyz
          port: 8081

  volumes:
    - name: aria-uds
      emptyDir: {}
    - name: aria-plugins
      configMap:
        name: aria-plugins
```

### Helm Deployment

```bash
helm install aria ./helm/aria-gatekeeper/ \
  --set redis.host=redis.default.svc.cluster.local \
  --set postgres.host=postgres.default.svc.cluster.local \
  --set postgres.password=your-password
```

## Docker Compose (Development)

See [docker-compose.yaml](../docker-compose.yaml) for a complete development setup with APISIX, Redis, PostgreSQL, and Aria Runtime.

## Prerequisites

| Service | Version | Purpose |
|---------|---------|---------|
| Apache APISIX | >= 3.8 | Plugin host |
| Redis | >= 7.0 | Quota state, circuit breaker, canary state |
| PostgreSQL | >= 16 | Audit trail, billing records |
