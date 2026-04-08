FROM eclipse-temurin:21-jre-alpine

LABEL maintainer="3EAI Labs <hello@3eai-labs.com>"
LABEL description="Aria Runtime — Java 21 sidecar for 3e-Aria-Gatekeeper"

RUN addgroup -S aria && adduser -S aria -G aria
RUN mkdir -p /var/run/aria && chown aria:aria /var/run/aria

COPY build/libs/aria-runtime.jar /app/aria-runtime.jar

USER aria
WORKDIR /app

EXPOSE 8081

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost:8081/healthz || exit 1

ENTRYPOINT ["java", \
    "--enable-preview", \
    "-XX:+UseZGC", \
    "-XX:MaxRAMPercentage=75", \
    "-jar", "/app/aria-runtime.jar"]
