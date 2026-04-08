package com.eai.aria.runtime.canary;

import com.eai.aria.runtime.core.RequestContext;
import com.eai.aria.runtime.proto.canary.*;
import io.grpc.stub.StreamObserver;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Canary gRPC service implementation.
 *
 * v0.1: Stub implementation.
 * v0.3: Shadow response diff engine.
 *
 * BR-CN-007: Shadow diff comparison.
 */
@Service
public class CanaryServiceImpl extends CanaryServiceGrpc.CanaryServiceImplBase {

    private static final Logger log = LoggerFactory.getLogger(CanaryServiceImpl.class);

    @Override
    public void diffResponses(DiffRequest request,
                              StreamObserver<DiffResponse> observer) {
        RequestContext.run(request.getRequestId(), null, request.getRouteId(), () -> {
            log.debug("Diffing shadow responses for route: {}", request.getRouteId());

            // v0.1: Stub — basic status comparison only.
            // v0.3: Full structural diff with body similarity scoring.
            boolean statusMatch = request.getPrimaryStatus() == request.getShadowStatus();
            long latencyDelta = request.getShadowLatencyMs() - request.getPrimaryLatencyMs();

            var response = DiffResponse.newBuilder()
                    .setStatusMatch(statusMatch)
                    .setBodySimilarity(statusMatch ? 1.0f : 0.0f)
                    .setLatencyDeltaMs(latencyDelta)
                    .setDiffSummary(statusMatch
                            ? "Status codes match"
                            : "Status mismatch: " + request.getPrimaryStatus()
                              + " vs " + request.getShadowStatus())
                    .build();

            observer.onNext(response);
            observer.onCompleted();
        });
    }
}
