package com.eai.aria.runtime.core;

import com.eai.aria.runtime.common.AriaRedisClient;
import com.eai.aria.runtime.common.PostgresClient;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Health and readiness endpoints for Kubernetes probes.
 *
 * BR-RT-003: Kubernetes-compatible health (/healthz) and readiness (/readyz).
 *
 * - /healthz: Returns 200 if the JVM is alive (liveness probe).
 * - /readyz: Returns 200 only when Redis and Postgres are reachable (readiness probe).
 *            Returns 503 during graceful shutdown.
 */
@RestController
public class HealthController {

    private final AriaRedisClient redis;
    private final PostgresClient postgres;
    private final AtomicBoolean ready = new AtomicBoolean(true);

    public HealthController(AriaRedisClient redis, PostgresClient postgres) {
        this.redis = redis;
        this.postgres = postgres;
    }

    @GetMapping("/healthz")
    public ResponseEntity<Map<String, Object>> liveness() {
        return ResponseEntity.ok(Map.of("status", "alive"));
    }

    @GetMapping("/readyz")
    public ResponseEntity<Map<String, Object>> readiness() {
        if (!ready.get()) {
            return ResponseEntity.status(503).body(Map.of(
                    "status", "shutting_down",
                    "ready", false));
        }

        boolean redisOk = redis.isHealthy();
        boolean postgresOk = postgres.isHealthy();
        boolean allOk = redisOk && postgresOk;

        var body = Map.of(
                "status", allOk ? "ready" : "not_ready",
                "ready", allOk,
                "dependencies", Map.of(
                        "redis", redisOk,
                        "postgres", postgresOk
                ));

        return allOk
                ? ResponseEntity.ok(body)
                : ResponseEntity.status(503).body(body);
    }

    /** Called by ShutdownManager to signal shutdown. */
    public void setReady(boolean value) {
        ready.set(value);
    }
}
