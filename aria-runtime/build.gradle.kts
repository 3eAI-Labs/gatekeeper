plugins {
    java
    id("org.springframework.boot") version "3.4.1"
    id("io.spring.dependency-management") version "1.1.7"
    id("com.google.protobuf") version "0.9.4"
}

group = "com.eai.aria"
version = "0.1.0"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories {
    mavenCentral()
}

val grpcVersion = "1.69.0"
val protobufVersion = "4.29.2"

dependencies {
    // Spring Boot
    implementation("org.springframework.boot:spring-boot-starter")
    implementation("org.springframework.boot:spring-boot-starter-web") // For health endpoints
    implementation("org.springframework.boot:spring-boot-starter-actuator")

    // gRPC
    implementation("io.grpc:grpc-netty-shaded:$grpcVersion")
    implementation("io.grpc:grpc-protobuf:$grpcVersion")
    implementation("io.grpc:grpc-stub:$grpcVersion")
    implementation("io.grpc:grpc-services:$grpcVersion") // Health check

    // Protobuf
    implementation("com.google.protobuf:protobuf-java:$protobufVersion")

    // Netty Unix Domain Socket support
    implementation("io.netty:netty-transport-native-epoll:4.1.116.Final:linux-x86_64")
    implementation("io.netty:netty-transport-native-unix-common:4.1.116.Final")

    // Redis (Lettuce async client)
    implementation("io.lettuce:lettuce-core:6.4.1.RELEASE")

    // PostgreSQL (async R2DBC)
    implementation("org.postgresql:r2dbc-postgresql:1.0.7.RELEASE")
    implementation("io.r2dbc:r2dbc-pool:1.0.2.RELEASE")

    // JSON
    implementation("com.fasterxml.jackson.core:jackson-databind")

    // Annotation processor
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")

    // Jakarta annotations for gRPC generated code
    implementation("jakarta.annotation:jakarta.annotation-api:3.0.0")

    // Testing
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("io.grpc:grpc-testing:$grpcVersion")
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:$protobufVersion"
    }
    plugins {
        create("grpc") {
            artifact = "io.grpc:protoc-gen-grpc-java:$grpcVersion"
        }
    }
    generateProtoTasks {
        all().forEach { task ->
            task.plugins {
                create("grpc")
            }
        }
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
    jvmArgs("--enable-preview")
}

tasks.withType<JavaCompile> {
    options.compilerArgs.addAll(listOf("--enable-preview"))
}

tasks.withType<org.springframework.boot.gradle.tasks.bundling.BootJar> {
    archiveFileName.set("aria-runtime.jar")
}
