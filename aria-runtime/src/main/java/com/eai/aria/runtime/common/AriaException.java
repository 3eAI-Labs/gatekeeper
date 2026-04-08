package com.eai.aria.runtime.common;

import io.grpc.Status;

/**
 * Base exception hierarchy for Aria Runtime.
 *
 * Maps to gRPC status codes for sidecar error responses
 * and to ARIA error codes for audit/logging.
 *
 * See: docs/04_design/ERROR_CODES.md
 */
public class AriaException extends RuntimeException {

    private final String ariaCode;
    private final Status.Code grpcStatus;

    protected AriaException(String ariaCode, String message, Status.Code grpcStatus) {
        super(message);
        this.ariaCode = ariaCode;
        this.grpcStatus = grpcStatus;
    }

    protected AriaException(String ariaCode, String message, Status.Code grpcStatus, Throwable cause) {
        super(message, cause);
        this.ariaCode = ariaCode;
        this.grpcStatus = grpcStatus;
    }

    public String getAriaCode() { return ariaCode; }
    public Status.Code getGrpcStatus() { return grpcStatus; }

    /** Convert to a gRPC Status for the response stream. */
    public Status toGrpcStatus() {
        return Status.fromCode(grpcStatus)
                .withDescription(ariaCode + ": " + getMessage());
    }

    // ── Concrete subclasses ──────────────────────────────────────────────

    /** Resource exhaustion — virtual thread pool full (BR-RT-002). */
    public static class ResourceExhaustedException extends AriaException {
        public ResourceExhaustedException(String message) {
            super("ARIA_RT_RESOURCE_EXHAUSTED", message, Status.Code.RESOURCE_EXHAUSTED);
        }
    }

    /** Sidecar dependency unavailable — Redis or Postgres down (BR-RT-003). */
    public static class DependencyUnavailableException extends AriaException {
        public DependencyUnavailableException(String dependency, Throwable cause) {
            super("ARIA_RT_DEPENDENCY_UNAVAILABLE",
                  "Dependency unavailable: " + dependency,
                  Status.Code.UNAVAILABLE, cause);
        }
    }

    /** Handler not found — unknown gRPC service/method (BR-RT-001). */
    public static class HandlerNotFoundException extends AriaException {
        public HandlerNotFoundException(String method) {
            super("ARIA_RT_HANDLER_NOT_FOUND",
                  "Unknown method: " + method,
                  Status.Code.UNIMPLEMENTED);
        }
    }

    /** Internal processing error. */
    public static class InternalException extends AriaException {
        public InternalException(String message, Throwable cause) {
            super("ARIA_SYS_INTERNAL_ERROR", message, Status.Code.INTERNAL, cause);
        }
    }
}
