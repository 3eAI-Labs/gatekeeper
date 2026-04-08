package com.eai.aria.runtime.mask;

import com.eai.aria.runtime.core.RequestContext;
import com.eai.aria.runtime.proto.mask.*;
import io.grpc.stub.StreamObserver;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Mask gRPC service implementation.
 *
 * v0.1: Stub implementation.
 * v0.3: NER-based PII detection using NLP model.
 *
 * BR-MK-006: NER PII detection (async, non-blocking).
 */
@Service
public class MaskServiceImpl extends MaskServiceGrpc.MaskServiceImplBase {

    private static final Logger log = LoggerFactory.getLogger(MaskServiceImpl.class);

    @Override
    public void detectPII(PiiDetectionRequest request,
                          StreamObserver<PiiDetectionResponse> observer) {
        RequestContext.run(request.getRequestId(), null, null, () -> {
            log.debug("NER PII detection requested");

            // v0.1: Stub — returns empty entity list.
            // v0.3: NER model integration for named entity recognition.
            var response = PiiDetectionResponse.newBuilder().build();

            observer.onNext(response);
            observer.onCompleted();
        });
    }
}
