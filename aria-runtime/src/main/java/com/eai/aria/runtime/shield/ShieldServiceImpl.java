package com.eai.aria.runtime.shield;

import com.eai.aria.runtime.common.AriaRedisClient;
import com.eai.aria.runtime.common.PostgresClient;
import com.eai.aria.runtime.core.RequestContext;
import com.eai.aria.runtime.proto.shield.*;
import io.grpc.stub.StreamObserver;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Shield gRPC service implementation.
 *
 * v0.1: Stub implementations that return basic responses.
 * v0.3: Full prompt analysis, tiktoken counting, content filtering.
 *
 * BR-SH-011: Prompt injection analysis (vector similarity)
 * BR-SH-006: Exact token counting (tiktoken)
 * BR-SH-013: Response content filtering
 */
@Service
public class ShieldServiceImpl extends ShieldServiceGrpc.ShieldServiceImplBase {

    private static final Logger log = LoggerFactory.getLogger(ShieldServiceImpl.class);

    private final AriaRedisClient redis;
    private final PostgresClient postgres;

    public ShieldServiceImpl(AriaRedisClient redis, PostgresClient postgres) {
        this.redis = redis;
        this.postgres = postgres;
    }

    @Override
    public void analyzePrompt(PromptAnalysisRequest request,
                              StreamObserver<PromptAnalysisResponse> observer) {
        RequestContext.run(request.getRequestId(), request.getConsumerId(), null, () -> {
            log.debug("Analyzing prompt for consumer: {}", request.getConsumerId());

            // v0.1: Basic stub — returns not-injection.
            // v0.3: Vector similarity analysis against injection pattern embeddings.
            var response = PromptAnalysisResponse.newBuilder()
                    .setIsInjection(false)
                    .setConfidenceScore(0.0f)
                    .setPatternCategory("")
                    .setRecommendation("allow")
                    .build();

            observer.onNext(response);
            observer.onCompleted();
        });
    }

    @Override
    public void countTokens(TokenCountRequest request,
                            StreamObserver<TokenCountResponse> observer) {
        RequestContext.run(request.getRequestId(), request.getConsumerId(), null, () -> {
            log.debug("Counting tokens for model: {}, consumer: {}",
                    request.getModel(), request.getConsumerId());

            // v0.1: Use approximate count (no tiktoken yet).
            // v0.2: Integrate tiktoken for exact counting + reconciliation.
            int approximate = request.getLuaApproximateCount();

            var response = TokenCountResponse.newBuilder()
                    .setExactTokenCount(approximate)
                    .setInputTokens(0)
                    .setOutputTokens(0)
                    .setDelta(0)
                    .build();

            observer.onNext(response);
            observer.onCompleted();
        });
    }

    @Override
    public void filterResponse(ContentFilterRequest request,
                               StreamObserver<ContentFilterResponse> observer) {
        RequestContext.run(request.getRequestId(), null, null, () -> {
            log.debug("Filtering response content, level: {}", request.getFilterLevel());

            // v0.1: Stub — returns not harmful.
            // v0.3: Content moderation pipeline.
            var response = ContentFilterResponse.newBuilder()
                    .setIsHarmful(false)
                    .setCategory("")
                    .setConfidenceScore(0.0f)
                    .setRecommendation("allow")
                    .build();

            observer.onNext(response);
            observer.onCompleted();
        });
    }
}
