package com.eai.aria.runtime.common;

import io.grpc.Status;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Tests for {@link AriaException} hierarchy and gRPC status mapping.
 */
class AriaExceptionTest {

    @Nested
    @DisplayName("ResourceExhaustedException")
    class ResourceExhaustedExceptionTests {

        @Test
        @DisplayName("Has correct aria code ARIA_RT_RESOURCE_EXHAUSTED")
        void hasCorrectAriaCode() {
            var ex = new AriaException.ResourceExhaustedException("Thread pool full");

            assertThat(ex.getAriaCode()).isEqualTo("ARIA_RT_RESOURCE_EXHAUSTED");
        }

        @Test
        @DisplayName("Has gRPC status RESOURCE_EXHAUSTED")
        void hasCorrectGrpcStatus() {
            var ex = new AriaException.ResourceExhaustedException("Thread pool full");

            assertThat(ex.getGrpcStatus()).isEqualTo(Status.Code.RESOURCE_EXHAUSTED);
        }

        @Test
        @DisplayName("Message is preserved")
        void messageIsPreserved() {
            var ex = new AriaException.ResourceExhaustedException("Thread pool full");

            assertThat(ex.getMessage()).isEqualTo("Thread pool full");
        }
    }

    @Nested
    @DisplayName("DependencyUnavailableException")
    class DependencyUnavailableExceptionTests {

        @Test
        @DisplayName("Has correct aria code ARIA_RT_DEPENDENCY_UNAVAILABLE")
        void hasCorrectAriaCode() {
            var cause = new RuntimeException("Connection refused");
            var ex = new AriaException.DependencyUnavailableException("Redis", cause);

            assertThat(ex.getAriaCode()).isEqualTo("ARIA_RT_DEPENDENCY_UNAVAILABLE");
        }

        @Test
        @DisplayName("Has gRPC status UNAVAILABLE")
        void hasCorrectGrpcStatus() {
            var cause = new RuntimeException("Connection refused");
            var ex = new AriaException.DependencyUnavailableException("Redis", cause);

            assertThat(ex.getGrpcStatus()).isEqualTo(Status.Code.UNAVAILABLE);
        }

        @Test
        @DisplayName("Message includes dependency name")
        void messageIncludesDependencyName() {
            var cause = new RuntimeException("Connection refused");
            var ex = new AriaException.DependencyUnavailableException("Redis", cause);

            assertThat(ex.getMessage()).contains("Redis");
        }

        @Test
        @DisplayName("Cause is preserved")
        void causeIsPreserved() {
            var cause = new RuntimeException("Connection refused");
            var ex = new AriaException.DependencyUnavailableException("Postgres", cause);

            assertThat(ex.getCause()).isSameAs(cause);
        }
    }

    @Nested
    @DisplayName("HandlerNotFoundException")
    class HandlerNotFoundExceptionTests {

        @Test
        @DisplayName("Has gRPC status UNIMPLEMENTED")
        void hasCorrectGrpcStatus() {
            var ex = new AriaException.HandlerNotFoundException("aria.Proxy/UnknownMethod");

            assertThat(ex.getGrpcStatus()).isEqualTo(Status.Code.UNIMPLEMENTED);
        }

        @Test
        @DisplayName("Has correct aria code ARIA_RT_HANDLER_NOT_FOUND")
        void hasCorrectAriaCode() {
            var ex = new AriaException.HandlerNotFoundException("aria.Proxy/UnknownMethod");

            assertThat(ex.getAriaCode()).isEqualTo("ARIA_RT_HANDLER_NOT_FOUND");
        }

        @Test
        @DisplayName("Message includes method name")
        void messageIncludesMethodName() {
            var ex = new AriaException.HandlerNotFoundException("aria.Proxy/UnknownMethod");

            assertThat(ex.getMessage()).contains("aria.Proxy/UnknownMethod");
        }
    }

    @Nested
    @DisplayName("InternalException")
    class InternalExceptionTests {

        @Test
        @DisplayName("Has gRPC status INTERNAL")
        void hasCorrectGrpcStatus() {
            var cause = new NullPointerException("oops");
            var ex = new AriaException.InternalException("Processing failed", cause);

            assertThat(ex.getGrpcStatus()).isEqualTo(Status.Code.INTERNAL);
        }

        @Test
        @DisplayName("Has correct aria code ARIA_SYS_INTERNAL_ERROR")
        void hasCorrectAriaCode() {
            var cause = new NullPointerException("oops");
            var ex = new AriaException.InternalException("Processing failed", cause);

            assertThat(ex.getAriaCode()).isEqualTo("ARIA_SYS_INTERNAL_ERROR");
        }

        @Test
        @DisplayName("Wraps cause")
        void wrapsCause() {
            var cause = new NullPointerException("oops");
            var ex = new AriaException.InternalException("Processing failed", cause);

            assertThat(ex.getCause()).isSameAs(cause);
        }
    }

    @Nested
    @DisplayName("toGrpcStatus()")
    class ToGrpcStatusTests {

        @Test
        @DisplayName("Returns Status with correct code")
        void returnsStatusWithCorrectCode() {
            var ex = new AriaException.ResourceExhaustedException("Pool full");

            Status status = ex.toGrpcStatus();

            assertThat(status.getCode()).isEqualTo(Status.Code.RESOURCE_EXHAUSTED);
        }

        @Test
        @DisplayName("Description contains aria code and message")
        void descriptionContainsAriaCodeAndMessage() {
            var ex = new AriaException.HandlerNotFoundException("aria.Proxy/Call");

            Status status = ex.toGrpcStatus();

            assertThat(status.getDescription())
                    .contains("ARIA_RT_HANDLER_NOT_FOUND")
                    .contains("aria.Proxy/Call");
        }

        @Test
        @DisplayName("Description format is 'ariaCode: message'")
        void descriptionFormat() {
            var ex = new AriaException.ResourceExhaustedException("Pool full");

            Status status = ex.toGrpcStatus();

            assertThat(status.getDescription())
                    .isEqualTo("ARIA_RT_RESOURCE_EXHAUSTED: Pool full");
        }
    }
}
