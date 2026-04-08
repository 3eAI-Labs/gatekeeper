package com.eai.aria.runtime.core;

import com.eai.aria.runtime.common.AriaRedisClient;
import com.eai.aria.runtime.common.PostgresClient;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.ResponseEntity;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

/**
 * Tests for {@link HealthController} liveness and readiness endpoints.
 */
@ExtendWith(MockitoExtension.class)
class HealthControllerTest {

    @Mock
    private AriaRedisClient redis;

    @Mock
    private PostgresClient postgres;

    private HealthController controller;

    @BeforeEach
    void setUp() {
        controller = new HealthController(redis, postgres);
    }

    @Nested
    @DisplayName("/healthz (liveness)")
    class LivenessTests {

        @Test
        @DisplayName("Always returns 200 with status=alive")
        void alwaysReturns200WithStatusAlive() {
            ResponseEntity<Map<String, Object>> response = controller.liveness();

            assertThat(response.getStatusCode().value()).isEqualTo(200);
            assertThat(response.getBody()).containsEntry("status", "alive");
        }
    }

    @Nested
    @DisplayName("/readyz (readiness)")
    class ReadinessTests {

        @Test
        @DisplayName("Returns 200 when Redis AND Postgres are healthy")
        void returns200WhenAllDependenciesHealthy() {
            when(redis.isHealthy()).thenReturn(true);
            when(postgres.isHealthy()).thenReturn(true);

            ResponseEntity<Map<String, Object>> response = controller.readiness();

            assertThat(response.getStatusCode().value()).isEqualTo(200);
            assertThat(response.getBody())
                    .containsEntry("status", "ready")
                    .containsEntry("ready", true);
        }

        @Test
        @DisplayName("Returns 503 when Redis is unhealthy")
        void returns503WhenRedisUnhealthy() {
            when(redis.isHealthy()).thenReturn(false);
            when(postgres.isHealthy()).thenReturn(true);

            ResponseEntity<Map<String, Object>> response = controller.readiness();

            assertThat(response.getStatusCode().value()).isEqualTo(503);
            assertThat(response.getBody())
                    .containsEntry("status", "not_ready")
                    .containsEntry("ready", false);
        }

        @Test
        @DisplayName("Returns 503 when Postgres is unhealthy")
        void returns503WhenPostgresUnhealthy() {
            when(redis.isHealthy()).thenReturn(true);
            when(postgres.isHealthy()).thenReturn(false);

            ResponseEntity<Map<String, Object>> response = controller.readiness();

            assertThat(response.getStatusCode().value()).isEqualTo(503);
            assertThat(response.getBody())
                    .containsEntry("status", "not_ready")
                    .containsEntry("ready", false);
        }

        @Test
        @DisplayName("Returns 503 when both Redis and Postgres are unhealthy")
        void returns503WhenBothUnhealthy() {
            when(redis.isHealthy()).thenReturn(false);
            when(postgres.isHealthy()).thenReturn(false);

            ResponseEntity<Map<String, Object>> response = controller.readiness();

            assertThat(response.getStatusCode().value()).isEqualTo(503);
            assertThat(response.getBody())
                    .containsEntry("status", "not_ready")
                    .containsEntry("ready", false);
        }

        @Test
        @DisplayName("Returns 503 when setReady(false) is called (shutdown mode)")
        void returns503WhenShuttingDown() {
            controller.setReady(false);

            ResponseEntity<Map<String, Object>> response = controller.readiness();

            assertThat(response.getStatusCode().value()).isEqualTo(503);
            assertThat(response.getBody())
                    .containsEntry("status", "shutting_down")
                    .containsEntry("ready", false);
        }

        @SuppressWarnings("unchecked")
        @Test
        @DisplayName("Response body includes dependency status when healthy")
        void responseIncludesDependencyStatus() {
            when(redis.isHealthy()).thenReturn(true);
            when(postgres.isHealthy()).thenReturn(false);

            ResponseEntity<Map<String, Object>> response = controller.readiness();

            var dependencies = (Map<String, Boolean>) response.getBody().get("dependencies");
            assertThat(dependencies)
                    .containsEntry("redis", true)
                    .containsEntry("postgres", false);
        }
    }
}
