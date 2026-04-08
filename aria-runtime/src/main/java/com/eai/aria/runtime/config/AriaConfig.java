package com.eai.aria.runtime.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

/**
 * Configuration properties for Aria Runtime.
 * Loaded from application.yml or environment variables.
 */
@Configuration
@ConfigurationProperties(prefix = "aria")
public class AriaConfig {

    private String udsPath = "/var/run/aria/aria.sock";
    private int shutdownGraceSeconds = 30;
    private RedisConfig redis = new RedisConfig();
    private PostgresConfig postgres = new PostgresConfig();

    public String getUdsPath() { return udsPath; }
    public void setUdsPath(String udsPath) { this.udsPath = udsPath; }

    public int getShutdownGraceSeconds() { return shutdownGraceSeconds; }
    public void setShutdownGraceSeconds(int s) { this.shutdownGraceSeconds = s; }

    public RedisConfig getRedis() { return redis; }
    public void setRedis(RedisConfig redis) { this.redis = redis; }

    public PostgresConfig getPostgres() { return postgres; }
    public void setPostgres(PostgresConfig postgres) { this.postgres = postgres; }

    public static class RedisConfig {
        private String host = "127.0.0.1";
        private int port = 6379;
        private String password;
        private int database = 0;
        private int timeoutMs = 2000;

        public String getHost() { return host; }
        public void setHost(String host) { this.host = host; }
        public int getPort() { return port; }
        public void setPort(int port) { this.port = port; }
        public String getPassword() { return password; }
        public void setPassword(String password) { this.password = password; }
        public int getDatabase() { return database; }
        public void setDatabase(int database) { this.database = database; }
        public int getTimeoutMs() { return timeoutMs; }
        public void setTimeoutMs(int timeoutMs) { this.timeoutMs = timeoutMs; }
    }

    public static class PostgresConfig {
        private String host = "127.0.0.1";
        private int port = 5432;
        private String database = "aria";
        private String username = "aria";
        private String password;

        public String getHost() { return host; }
        public void setHost(String host) { this.host = host; }
        public int getPort() { return port; }
        public void setPort(int port) { this.port = port; }
        public String getDatabase() { return database; }
        public void setDatabase(String database) { this.database = database; }
        public String getUsername() { return username; }
        public void setUsername(String username) { this.username = username; }
        public String getPassword() { return password; }
        public void setPassword(String password) { this.password = password; }
    }
}
