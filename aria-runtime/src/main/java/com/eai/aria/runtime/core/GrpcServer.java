package com.eai.aria.runtime.core;

import com.eai.aria.runtime.config.AriaConfig;
import io.grpc.BindableService;
import io.grpc.Server;
import io.grpc.ServerInterceptor;
import io.grpc.ServerInterceptors;
import io.grpc.netty.shaded.io.grpc.netty.NettyServerBuilder;
import io.grpc.netty.shaded.io.netty.channel.epoll.EpollEventLoopGroup;
import io.grpc.netty.shaded.io.netty.channel.epoll.EpollServerDomainSocketChannel;
import io.grpc.netty.shaded.io.netty.channel.unix.DomainSocketAddress;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.List;
import java.util.concurrent.Executors;

/**
 * gRPC server listening on Unix Domain Socket.
 *
 * BR-RT-001: gRPC/UDS server with modular handler registration.
 * BR-RT-002: Virtual Thread executor for per-request concurrency.
 *
 * UDS path default: /var/run/aria/aria.sock
 * Socket permissions: 0660 (owner + group read/write).
 */
@Component
public class GrpcServer {

    private static final Logger log = LoggerFactory.getLogger(GrpcServer.class);

    private final AriaConfig config;
    private final List<BindableService> services;
    private final GrpcExceptionInterceptor exceptionInterceptor;
    private Server server;

    public GrpcServer(AriaConfig config,
                      List<BindableService> services,
                      GrpcExceptionInterceptor exceptionInterceptor) {
        this.config = config;
        this.services = services;
        this.exceptionInterceptor = exceptionInterceptor;
    }

    @PostConstruct
    public void start() throws IOException {
        String udsPath = config.getUdsPath();
        Path socketPath = Path.of(udsPath);

        // Ensure parent directory exists
        Files.createDirectories(socketPath.getParent());

        // Remove stale socket file
        Files.deleteIfExists(socketPath);

        var bossGroup = new EpollEventLoopGroup(1);
        var workerGroup = new EpollEventLoopGroup();

        var builder = NettyServerBuilder
                .forAddress(new DomainSocketAddress(udsPath))
                .channelType(EpollServerDomainSocketChannel.class)
                .bossEventLoopGroup(bossGroup)
                .workerEventLoopGroup(workerGroup)
                .executor(Executors.newVirtualThreadPerTaskExecutor());  // BR-RT-002

        // Register all discovered gRPC services with exception interceptor
        for (BindableService service : services) {
            builder.addService(
                ServerInterceptors.intercept(service, exceptionInterceptor)
            );
            log.info("Registered gRPC service: {}", service.bindService().getServiceDescriptor().getName());
        }

        server = builder.build().start();

        // Set socket file permissions: 0660
        try {
            Files.setPosixFilePermissions(socketPath,
                PosixFilePermissions.fromString("rw-rw----"));
        } catch (UnsupportedOperationException e) {
            log.warn("Could not set POSIX permissions on UDS socket (non-POSIX filesystem)");
        }

        log.info("gRPC server started on UDS: {}", udsPath);
    }

    public Server getServer() {
        return server;
    }

    public String getUdsPath() {
        return config.getUdsPath();
    }
}
