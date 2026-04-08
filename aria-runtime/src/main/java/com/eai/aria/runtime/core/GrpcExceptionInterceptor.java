package com.eai.aria.runtime.core;

import com.eai.aria.runtime.common.AriaException;
import io.grpc.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * gRPC server interceptor that catches AriaException and maps to gRPC Status.
 *
 * Prevents raw Java exceptions from leaking to the Lua client.
 * Logs errors at appropriate levels per ERROR_HANDLING_GUIDELINE.
 */
@Component
public class GrpcExceptionInterceptor implements ServerInterceptor {

    private static final Logger log = LoggerFactory.getLogger(GrpcExceptionInterceptor.class);

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call,
            Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {

        var listener = next.startCall(call, headers);

        return new ForwardingServerCallListener.SimpleForwardingServerCallListener<>(listener) {
            @Override
            public void onHalfClose() {
                try {
                    super.onHalfClose();
                } catch (AriaException e) {
                    log.warn("Aria error in gRPC call {}: {} - {}",
                            call.getMethodDescriptor().getFullMethodName(),
                            e.getAriaCode(), e.getMessage());
                    call.close(e.toGrpcStatus(), new Metadata());
                } catch (Exception e) {
                    log.error("Unexpected error in gRPC call {}",
                            call.getMethodDescriptor().getFullMethodName(), e);
                    call.close(Status.INTERNAL.withDescription(
                            "ARIA_SYS_INTERNAL_ERROR: " + e.getMessage()), new Metadata());
                }
            }
        };
    }
}
