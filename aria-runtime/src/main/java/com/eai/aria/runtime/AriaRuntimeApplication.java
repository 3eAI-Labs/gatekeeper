package com.eai.aria.runtime;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Aria Runtime — Java 21 sidecar for 3e-Aria-Gatekeeper.
 *
 * Provides heavy-processing backends for Lua plugins via gRPC over Unix Domain Socket:
 * - Shield: prompt analysis, tiktoken token counting, content filtering
 * - Mask: NER-based PII detection
 * - Canary: shadow response diff engine
 *
 * Uses Virtual Threads (Project Loom) for per-request concurrency
 * and ScopedValue for safe per-request context propagation.
 */
@SpringBootApplication
public class AriaRuntimeApplication {

    public static void main(String[] args) {
        SpringApplication.run(AriaRuntimeApplication.class, args);
    }
}
