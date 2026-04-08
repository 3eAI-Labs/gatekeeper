# Aria Runtime Configuration

All configuration is via environment variables or `application.yml` mounted into the container.

## Environment Variables

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

## UDS Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| UDS path | `/var/run/aria/aria.sock` | Unix Domain Socket path |
| Socket permissions | `0660` | Owner + group read/write |
| Shutdown grace period | `30s` | Max drain time on SIGTERM |

## Resource Recommendations

| Deployment Size | CPU | Memory | Concurrent Requests |
|----------------|-----|--------|-------------------|
| Small (< 100 req/s) | 0.25 cores | 256Mi | 1K virtual threads |
| Medium (< 1K req/s) | 0.5 cores | 384Mi | 5K virtual threads |
| Large (< 10K req/s) | 1.0 cores | 512Mi | 10K+ virtual threads |

## JVM Flags

The Docker image uses these JVM flags by default:
- `--enable-preview` — ScopedValue support
- `-XX:+UseZGC` — Low-latency garbage collector
- `-XX:MaxRAMPercentage=75` — Use 75% of container memory limit
