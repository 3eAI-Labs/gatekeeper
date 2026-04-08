package com.eai.aria.runtime.core;

/**
 * Per-request context propagated via ScopedValue (Java 21).
 *
 * Uses ScopedValue instead of ThreadLocal to avoid memory leaks with Virtual Threads.
 * BR-RT-002: ScopedValue for per-request context propagation.
 */
public final class RequestContext {

    /** Consumer ID from APISIX (e.g., "team-a"). */
    public static final ScopedValue<String> CONSUMER_ID = ScopedValue.newInstance();

    /** APISIX route ID. */
    public static final ScopedValue<String> ROUTE_ID = ScopedValue.newInstance();

    /** Unique request ID for tracing. */
    public static final ScopedValue<String> REQUEST_ID = ScopedValue.newInstance();

    private RequestContext() {
        // Utility class
    }

    /**
     * Execute a runnable within a scoped request context.
     *
     * @param requestId  Request ID for tracing
     * @param consumerId Consumer ID from APISIX
     * @param routeId    Route ID
     * @param action     Runnable to execute within the scope
     */
    public static void run(String requestId, String consumerId, String routeId, Runnable action) {
        ScopedValue.runWhere(REQUEST_ID, requestId != null ? requestId : "",
            () -> ScopedValue.runWhere(CONSUMER_ID, consumerId != null ? consumerId : "",
                () -> ScopedValue.runWhere(ROUTE_ID, routeId != null ? routeId : "",
                    action)));
    }
}
