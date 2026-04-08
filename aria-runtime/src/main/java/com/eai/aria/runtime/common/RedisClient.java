package com.eai.aria.runtime.common;

import com.eai.aria.runtime.config.AriaConfig;
import io.lettuce.core.RedisClient;
import io.lettuce.core.RedisURI;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.api.async.RedisAsyncCommands;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.concurrent.CompletableFuture;

/**
 * Async Redis client for Aria Runtime.
 *
 * Uses Lettuce for non-blocking I/O compatible with Virtual Threads.
 * BR-SH-006: Token count reconciliation writes.
 * BR-SH-015: Audit event buffering.
 */
@Component
public class AriaRedisClient {

    private static final Logger log = LoggerFactory.getLogger(AriaRedisClient.class);

    private final AriaConfig config;
    private RedisClient client;
    private StatefulRedisConnection<String, String> connection;

    public AriaRedisClient(AriaConfig config) {
        this.config = config;
    }

    @PostConstruct
    public void init() {
        var redisConf = config.getRedis();
        var uriBuilder = RedisURI.builder()
                .withHost(redisConf.getHost())
                .withPort(redisConf.getPort())
                .withDatabase(redisConf.getDatabase())
                .withTimeout(Duration.ofMillis(redisConf.getTimeoutMs()));

        if (redisConf.getPassword() != null && !redisConf.getPassword().isEmpty()) {
            uriBuilder.withPassword(redisConf.getPassword().toCharArray());
        }

        client = RedisClient.create(uriBuilder.build());
        connection = client.connect();
        log.info("Redis connected: {}:{}", redisConf.getHost(), redisConf.getPort());
    }

    /** Check if Redis is reachable. */
    public boolean isHealthy() {
        try {
            return "PONG".equals(connection.sync().ping());
        } catch (Exception e) {
            return false;
        }
    }

    /** Async GET. */
    public CompletableFuture<String> get(String key) {
        return connection.async().get(key).toCompletableFuture();
    }

    /** Async SET with TTL. */
    public CompletableFuture<String> setex(String key, long ttlSeconds, String value) {
        return connection.async().setex(key, ttlSeconds, value).toCompletableFuture();
    }

    /** Async INCRBY. */
    public CompletableFuture<Long> incrBy(String key, long amount) {
        return connection.async().incrby(key, amount).toCompletableFuture();
    }

    /** Async RPUSH (for audit buffer). */
    public CompletableFuture<Long> rpush(String key, String value) {
        return connection.async().rpush(key, value).toCompletableFuture();
    }

    /** Get sync commands for simple operations. */
    public RedisAsyncCommands<String, String> async() {
        return connection.async();
    }

    @PreDestroy
    public void close() {
        if (connection != null) {
            connection.close();
        }
        if (client != null) {
            client.shutdown();
        }
        log.info("Redis connection closed");
    }
}
