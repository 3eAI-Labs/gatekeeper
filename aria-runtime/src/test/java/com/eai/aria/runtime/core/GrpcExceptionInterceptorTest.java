package com.eai.aria.runtime.core;

import com.eai.aria.runtime.common.AriaException;
import io.grpc.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * Tests for {@link GrpcExceptionInterceptor} exception-to-gRPC-status mapping.
 */
@ExtendWith(MockitoExtension.class)
class GrpcExceptionInterceptorTest {

    private GrpcExceptionInterceptor interceptor;

    @Mock
    private ServerCall<Object, Object> serverCall;

    @Mock
    private ServerCallHandler<Object, Object> next;

    private final Metadata headers = new Metadata();

    @BeforeEach
    void setUp() {
        interceptor = new GrpcExceptionInterceptor();
        MethodDescriptor<Object, Object> methodDescriptor = MethodDescriptor.newBuilder()
                .setType(MethodDescriptor.MethodType.UNARY)
                .setFullMethodName("aria.Proxy/Forward")
                .setRequestMarshaller(marshallerStub())
                .setResponseMarshaller(marshallerStub())
                .build();
        lenient().when(serverCall.getMethodDescriptor()).thenReturn(methodDescriptor);
    }

    @Test
    @DisplayName("AriaException is caught and mapped to gRPC Status with correct code")
    void ariaException_mappedToCorrectGrpcStatus() {
        var ariaEx = new AriaException.ResourceExhaustedException("Pool full");
        var throwingListener = createThrowingListener(ariaEx);
        when(next.startCall(any(), any())).thenReturn(throwingListener);

        ServerCall.Listener<Object> listener = interceptor.interceptCall(serverCall, headers, next);
        listener.onHalfClose();

        ArgumentCaptor<Status> statusCaptor = ArgumentCaptor.forClass(Status.class);
        verify(serverCall).close(statusCaptor.capture(), any(Metadata.class));

        Status captured = statusCaptor.getValue();
        assertThat(captured.getCode()).isEqualTo(Status.Code.RESOURCE_EXHAUSTED);
        assertThat(captured.getDescription()).contains("ARIA_RT_RESOURCE_EXHAUSTED");
        assertThat(captured.getDescription()).contains("Pool full");
    }

    @Test
    @DisplayName("HandlerNotFoundException maps to UNIMPLEMENTED")
    void handlerNotFound_mappedToUnimplemented() {
        var ariaEx = new AriaException.HandlerNotFoundException("aria.Proxy/Unknown");
        var throwingListener = createThrowingListener(ariaEx);
        when(next.startCall(any(), any())).thenReturn(throwingListener);

        ServerCall.Listener<Object> listener = interceptor.interceptCall(serverCall, headers, next);
        listener.onHalfClose();

        ArgumentCaptor<Status> statusCaptor = ArgumentCaptor.forClass(Status.class);
        verify(serverCall).close(statusCaptor.capture(), any(Metadata.class));

        assertThat(statusCaptor.getValue().getCode()).isEqualTo(Status.Code.UNIMPLEMENTED);
    }

    @Test
    @DisplayName("Unexpected Exception is caught and mapped to INTERNAL")
    void unexpectedException_mappedToInternal() {
        var unexpectedEx = new NullPointerException("something went wrong");
        var throwingListener = createThrowingListener(unexpectedEx);
        when(next.startCall(any(), any())).thenReturn(throwingListener);

        ServerCall.Listener<Object> listener = interceptor.interceptCall(serverCall, headers, next);
        listener.onHalfClose();

        ArgumentCaptor<Status> statusCaptor = ArgumentCaptor.forClass(Status.class);
        verify(serverCall).close(statusCaptor.capture(), any(Metadata.class));

        Status captured = statusCaptor.getValue();
        assertThat(captured.getCode()).isEqualTo(Status.Code.INTERNAL);
        assertThat(captured.getDescription()).contains("ARIA_SYS_INTERNAL_ERROR");
        assertThat(captured.getDescription()).contains("something went wrong");
    }

    @Test
    @DisplayName("Normal call without exception proceeds without closing")
    void normalCall_noExceptionThrown_doesNotClose() {
        var normalListener = new ServerCall.Listener<Object>() {
            @Override
            public void onHalfClose() {
                // no-op, success
            }
        };
        when(next.startCall(any(), any())).thenReturn(normalListener);

        ServerCall.Listener<Object> listener = interceptor.interceptCall(serverCall, headers, next);
        listener.onHalfClose();

        verify(serverCall, never()).close(any(Status.class), any(Metadata.class));
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /**
     * Creates a listener whose onHalfClose() throws the given exception,
     * simulating a handler failure.
     */
    private ServerCall.Listener<Object> createThrowingListener(RuntimeException ex) {
        return new ServerCall.Listener<>() {
            @Override
            public void onHalfClose() {
                throw ex;
            }
        };
    }

    /**
     * Stub marshaller for building a MethodDescriptor in tests.
     */
    @SuppressWarnings("unchecked")
    private static <T> MethodDescriptor.Marshaller<T> marshallerStub() {
        return mock(MethodDescriptor.Marshaller.class);
    }
}
