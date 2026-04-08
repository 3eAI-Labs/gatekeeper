package com.eai.aria.runtime.core;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Tests for {@link RequestContext} ScopedValue-based context propagation.
 *
 * Requires --enable-preview JVM arg (configured in build.gradle.kts).
 */
class RequestContextTest {

    @Test
    @DisplayName("run() sets all three scoped values accessible within the runnable")
    void run_setsAllScopedValues() {
        var capturedRequestId = new AtomicReference<String>();
        var capturedConsumerId = new AtomicReference<String>();
        var capturedRouteId = new AtomicReference<String>();

        RequestContext.run("req-001", "team-a", "route-42", () -> {
            capturedRequestId.set(RequestContext.REQUEST_ID.get());
            capturedConsumerId.set(RequestContext.CONSUMER_ID.get());
            capturedRouteId.set(RequestContext.ROUTE_ID.get());
        });

        assertThat(capturedRequestId.get()).isEqualTo("req-001");
        assertThat(capturedConsumerId.get()).isEqualTo("team-a");
        assertThat(capturedRouteId.get()).isEqualTo("route-42");
    }

    @Test
    @DisplayName("Values are not bound outside the runnable scope")
    void scopedValues_notBoundOutsideRun() {
        RequestContext.run("req-002", "team-b", "route-99", () -> {
            // Values are bound here, but we only care about outside
        });

        assertThat(RequestContext.REQUEST_ID.isBound()).isFalse();
        assertThat(RequestContext.CONSUMER_ID.isBound()).isFalse();
        assertThat(RequestContext.ROUTE_ID.isBound()).isFalse();
    }

    @Test
    @DisplayName("Null requestId is converted to empty string")
    void run_nullRequestId_convertedToEmptyString() {
        var capturedRequestId = new AtomicReference<String>();

        RequestContext.run(null, "team-c", "route-1", () ->
                capturedRequestId.set(RequestContext.REQUEST_ID.get()));

        assertThat(capturedRequestId.get()).isEmpty();
    }

    @Test
    @DisplayName("Null consumerId is converted to empty string")
    void run_nullConsumerId_convertedToEmptyString() {
        var capturedConsumerId = new AtomicReference<String>();

        RequestContext.run("req-003", null, "route-1", () ->
                capturedConsumerId.set(RequestContext.CONSUMER_ID.get()));

        assertThat(capturedConsumerId.get()).isEmpty();
    }

    @Test
    @DisplayName("Null routeId is converted to empty string")
    void run_nullRouteId_convertedToEmptyString() {
        var capturedRouteId = new AtomicReference<String>();

        RequestContext.run("req-004", "team-d", null, () ->
                capturedRouteId.set(RequestContext.ROUTE_ID.get()));

        assertThat(capturedRouteId.get()).isEmpty();
    }

    @Test
    @DisplayName("All null values are converted to empty strings")
    void run_allNullValues_convertedToEmptyStrings() {
        var capturedRequestId = new AtomicReference<String>();
        var capturedConsumerId = new AtomicReference<String>();
        var capturedRouteId = new AtomicReference<String>();

        RequestContext.run(null, null, null, () -> {
            capturedRequestId.set(RequestContext.REQUEST_ID.get());
            capturedConsumerId.set(RequestContext.CONSUMER_ID.get());
            capturedRouteId.set(RequestContext.ROUTE_ID.get());
        });

        assertThat(capturedRequestId.get()).isEmpty();
        assertThat(capturedConsumerId.get()).isEmpty();
        assertThat(capturedRouteId.get()).isEmpty();
    }
}
