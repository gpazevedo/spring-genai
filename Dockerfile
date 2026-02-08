FROM amazoncorretto:25-alpine

# Create non-root user
RUN addgroup -S appuser && adduser -S appuser -G appuser

WORKDIR /app

# Download ADOT Java agent for SigV4-signed OTLP export to CloudWatch/X-Ray
# Activated only in AgentCore via JAVA_TOOL_OPTIONS env var in Terraform
ADD https://github.com/aws-observability/aws-otel-java-instrumentation/releases/download/v2.23.0/aws-opentelemetry-agent.jar /app/aws-opentelemetry-agent.jar

# Copy the jar file
COPY build/libs/spring-genai-*SNAPSHOT.jar app.jar

# Change ownership
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

ENV AGENT_OBSERVABILITY_ENABLED=true
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
ENV OTEL_RESOURCE_ATTRIBUTES=service.name=spring-genai

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]
