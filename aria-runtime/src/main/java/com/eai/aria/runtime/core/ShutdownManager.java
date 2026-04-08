package com.eai.aria.runtime.core;

import com.eai.aria.runtime.common.AriaRedisClient;
import com.eai.aria.runtime.common.PostgresClient;
import com.eai.aria.runtime.config.AriaConfig;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;

/**
 * Graceful shutdown sequence for Aria Runtime.
 *
 * BR-RT-004: On SIGTERM:
 * 1. Set readiness to 503 (stop receiving new traffic)
 * 2. Stop accepting new gRPC requests
 * 3. Wait for in-flight requests to complete (up to grace period)
 * 4. Close Redis and Postgres connections
 * 5. Remove UDS socket file
 */
@Component
public class ShutdownManager {

    private static final Logger log = LoggerFactory.getLogger(ShutdownManager.class);

    private final GrpcServer grpcServer;
    private final HealthController healthController;
    private final AriaRedisClient redis;
    private final PostgresClient postgres;
    private final AriaConfig config;

    public ShutdownManager(GrpcServer grpcServer,
                           HealthController healthController,
                           AriaRedisClient redis,
                           PostgresClient postgres,
                           AriaConfig config) {
        this.grpcServer = grpcServer;
        this.healthController = healthController;
        this.redis = redis;
        this.postgres = postgres;
        this.config = config;
    }

    @PreDestroy
    public void onShutdown() {
        log.info("Initiating graceful shutdown (grace period: {}s)", config.getShutdownGraceSeconds());

        // Step 1: Set readiness to 503
        healthController.setReady(false);
        log.info("Readiness set to NOT_READY");

        // Step 2: Stop accepting new gRPC requests
        var server = grpcServer.getServer();
        if (server != null) {
            server.shutdown();
            log.info("gRPC server shutdown initiated");

            // Step 3: Wait for in-flight requests
            try {
                boolean terminated = server.awaitTermination(
                        config.getShutdownGraceSeconds(), TimeUnit.SECONDS);
                if (!terminated) {
                    log.warn("Grace period expired, forcing shutdown of remaining requests");
                    server.shutdownNow();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.warn("Shutdown interrupted, forcing immediate shutdown");
                server.shutdownNow();
            }
        }

        // Step 4: Close connections
        redis.close();
        postgres.close();

        // Step 5: Remove UDS socket file
        try {
            Files.deleteIfExists(Path.of(grpcServer.getUdsPath()));
            log.info("UDS socket file removed: {}", grpcServer.getUdsPath());
        } catch (Exception e) {
            log.warn("Could not remove UDS socket file: {}", e.getMessage());
        }

        log.info("Graceful shutdown complete");
    }
}
