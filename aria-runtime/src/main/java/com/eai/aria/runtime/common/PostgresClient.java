package com.eai.aria.runtime.common;

import com.eai.aria.runtime.config.AriaConfig;
import io.r2dbc.pool.ConnectionPool;
import io.r2dbc.pool.ConnectionPoolConfiguration;
import io.r2dbc.postgresql.PostgresqlConnectionConfiguration;
import io.r2dbc.postgresql.PostgresqlConnectionFactory;
import io.r2dbc.spi.Connection;
import io.r2dbc.spi.Result;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;

/**
 * Async PostgreSQL client for Aria Runtime.
 *
 * Uses R2DBC for non-blocking writes to audit and billing tables.
 * BR-SH-015: Audit event persistence.
 * BR-SH-006: Billing record persistence.
 */
@Component
public class PostgresClient {

    private static final Logger log = LoggerFactory.getLogger(PostgresClient.class);

    private final AriaConfig config;
    private ConnectionPool pool;

    public PostgresClient(AriaConfig config) {
        this.config = config;
    }

    @PostConstruct
    public void init() {
        var pgConf = config.getPostgres();

        var connConfig = PostgresqlConnectionConfiguration.builder()
                .host(pgConf.getHost())
                .port(pgConf.getPort())
                .database(pgConf.getDatabase())
                .username(pgConf.getUsername())
                .password(pgConf.getPassword() != null ? pgConf.getPassword() : "")
                .build();

        var factory = new PostgresqlConnectionFactory(connConfig);

        var poolConfig = ConnectionPoolConfiguration.builder(factory)
                .maxSize(20)
                .minIdle(2)
                .maxIdleTime(Duration.ofMinutes(5))
                .maxAcquireTime(Duration.ofSeconds(5))
                .build();

        pool = new ConnectionPool(poolConfig);
        log.info("PostgreSQL pool initialized: {}:{}/{}", pgConf.getHost(), pgConf.getPort(), pgConf.getDatabase());
    }

    /** Check if Postgres is reachable. */
    public boolean isHealthy() {
        try {
            return pool.create()
                    .flatMap(conn -> Mono.from(conn.validate(io.r2dbc.spi.ValidationDepth.REMOTE))
                            .doFinally(s -> conn.close()))
                    .block(Duration.ofSeconds(2));
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Insert an audit event record (append-only).
     * Maps to: audit_events table (DB_SCHEMA.md V001).
     */
    public CompletableFuture<Void> insertAuditEvent(String consumerId, String routeId,
                                                     String eventType, String actionTaken,
                                                     String payloadExcerpt, String ruleId,
                                                     Map<String, Object> metadata) {
        return pool.create()
                .flatMap(conn -> Mono.from(conn.createStatement(
                        "INSERT INTO audit_events (id, consumer_id, route_id, event_type, action_taken, " +
                        "payload_excerpt, rule_id, metadata, timestamp, created_at) " +
                        "VALUES ($1, $2, $3, $4::event_type, $5::action_taken, $6, $7, $8::jsonb, $9, $9)")
                        .bind("$1", UUID.randomUUID().toString())
                        .bind("$2", consumerId)
                        .bind("$3", routeId)
                        .bind("$4", eventType)
                        .bind("$5", actionTaken)
                        .bind("$6", payloadExcerpt != null ? payloadExcerpt : "")
                        .bind("$7", ruleId != null ? ruleId : "")
                        .bind("$8", metadata != null ? metadata.toString() : "{}")
                        .bind("$9", OffsetDateTime.now())
                        .execute())
                        .flatMap(result -> Mono.from(result.getRowsUpdated()))
                        .doFinally(s -> conn.close()))
                .then()
                .toFuture();
    }

    /**
     * Insert a billing record.
     * Maps to: billing_records table (DB_SCHEMA.md V002).
     */
    public CompletableFuture<Void> insertBillingRecord(String consumerId, String routeId,
                                                        String model, String provider,
                                                        int tokensInput, int tokensOutput,
                                                        double costDollars, String requestId,
                                                        boolean isReconciled) {
        return pool.create()
                .flatMap(conn -> Mono.from(conn.createStatement(
                        "INSERT INTO billing_records (id, consumer_id, route_id, model, provider, " +
                        "tokens_input, tokens_output, cost_dollars, request_id, is_reconciled, timestamp, created_at) " +
                        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)")
                        .bind("$1", UUID.randomUUID().toString())
                        .bind("$2", consumerId)
                        .bind("$3", routeId)
                        .bind("$4", model)
                        .bind("$5", provider)
                        .bind("$6", tokensInput)
                        .bind("$7", tokensOutput)
                        .bind("$8", costDollars)
                        .bind("$9", requestId)
                        .bind("$10", isReconciled)
                        .bind("$11", OffsetDateTime.now())
                        .execute())
                        .flatMap(result -> Mono.from(result.getRowsUpdated()))
                        .doFinally(s -> conn.close()))
                .then()
                .toFuture();
    }

    @PreDestroy
    public void close() {
        if (pool != null) {
            pool.dispose();
        }
        log.info("PostgreSQL pool closed");
    }
}
