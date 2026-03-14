# Stage 1: Extract Spring Boot layers from the pre-built jar
FROM amazoncorretto:25-alpine AS builder

WORKDIR /build

COPY build/libs/spring-genai-*SNAPSHOT.jar app.jar

# Extract layers: dependencies, spring-boot-loader, snapshot-dependencies, application
RUN java -Djarmode=tools -jar app.jar extract --layers --launcher --destination extracted

# Download ADOT Java agent (cached here, not re-downloaded on app changes)
ADD https://github.com/aws-observability/aws-otel-java-instrumentation/releases/download/v2.23.0/aws-opentelemetry-agent.jar \
    /build/aws-opentelemetry-agent.jar


# Stage 2: Minimal runtime image
FROM amazoncorretto:25-alpine

RUN addgroup -S appuser && adduser -S appuser -G appuser

WORKDIR /app

# Copy ADOT agent
COPY --from=builder /build/aws-opentelemetry-agent.jar ./

# Copy Spring Boot layers in order of change frequency (least → most)
COPY --from=builder /build/extracted/dependencies/ ./
COPY --from=builder /build/extracted/spring-boot-loader/ ./
COPY --from=builder /build/extracted/snapshot-dependencies/ ./
COPY --from=builder /build/extracted/application/ ./

RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8080

# Load ADOT Java agent; disable log bytecode instrumentation (logback OTEL appender handles logs)
ENV JAVA_TOOL_OPTIONS="-javaagent:/app/aws-opentelemetry-agent.jar \
  -Dotel.instrumentation.logback-appender.enabled=false \
  -Dotel.instrumentation.java-util-logging.enabled=false"

ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
