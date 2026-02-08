# Observability with OpenTelemetry

This application uses OpenTelemetry (OTel) to export **traces**, **metrics**, and **logs** via the OTLP protocol.

## Architecture

```text
                              ┌──▶ Jaeger      (traces)
App ──OTLP──▶ OTel Collector ─┼──▶ Prometheus  (metrics)
                              └──▶ Loki        (logs)
                                       ▲
                                   Grafana  (unified dashboards)
```

The application sends all telemetry to an **OpenTelemetry Collector**, which routes each signal to the appropriate backend.

## Dependencies

| Dependency | Purpose |
|---|---|
| `spring-boot-starter-opentelemetry` | OTel SDK + OTLP exporters for traces and metrics |
| `spring-boot-starter-actuator` | Exposes metrics and health endpoints |
| `opentelemetry-logback-appender-1.0` | Bridges Logback logs into the OTel SDK |

## Configuration

### application.properties

| Property | Description |
|---|---|
| `management.opentelemetry.tracing.export.otlp.endpoint` | OTLP HTTP endpoint for traces |
| `management.otlp.metrics.export.url` | OTLP HTTP endpoint for metrics |
| `management.tracing.sampling.probability` | Sampling rate (`1.0` = 100%, `0.1` = 10%) |

### logback-spring.xml

The `OpenTelemetryAppender` captures all log events and sends them through the OTel SDK alongside traces and metrics. It also captures MDC attributes and experimental attributes (like thread name and code location).

## Running the Observability Stack

### Prerequisites

- Docker and Docker Compose

### Start the stack

```bash
docker compose up -d
```

### UIs

| Service | URL | Signal |
|---|---|---|
| Jaeger | <http://localhost:16686> | Traces |
| Prometheus | <http://localhost:9090> | Metrics |
| Grafana | <http://localhost:3000> (admin/admin) | All three |
| Loki | <http://localhost:3100> | Logs (API only) |

### Stop the stack

```bash
docker compose down
```

## Testing

### 1. Start the observability stack and the application

```bash
docker compose up -d
./gradlew bootRun
```

### 2. Send a request

```bash
# Synchronous
curl -X POST http://localhost:8080/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello, tell me a joke"}'

# Streaming
curl -N -G http://localhost:8080/chat/stream \
  --data-urlencode "message=Hello, tell me a joke"
```

### 3. Verify traces

Open Jaeger at <http://localhost:16686>, select the `spring-genai` service, and click **Find Traces**. You should see traces for each HTTP request, including spans for the Bedrock model calls.

### 4. Verify metrics

Open Prometheus at <http://localhost:9090> and query for metrics such as:

- `http_server_request_duration_seconds_bucket` - HTTP request latency
- `gen_ai_client_operation_duration_seconds_bucket` - LLM call latency

### 5. Verify logs

Open Grafana at <http://localhost:3000>, go to **Explore**, select the **Loki** datasource, and run a query:

```text
{service_name="spring-genai"}
```

## Switching to Langfuse

[Langfuse](https://langfuse.com) is an LLM observability platform that natively accepts OTLP traces. Since this application already exports standard OpenTelemetry data, switching to Langfuse requires **configuration changes only** -- no code changes.

### Option A: Send directly to Langfuse (replace local stack)

Update `application.properties`:

```properties
# Langfuse OTLP endpoint (EU region)
management.opentelemetry.tracing.export.otlp.endpoint=https://cloud.langfuse.com/api/public/otel/v1/traces
management.opentelemetry.tracing.export.otlp.headers.Authorization=Basic <BASE64_ENCODED_KEYS>

# For US region, use:
# management.opentelemetry.tracing.export.otlp.endpoint=https://us.cloud.langfuse.com/api/public/otel/v1/traces
```

Generate the auth token:

```bash
echo -n "pk-lf-YOUR_PUBLIC_KEY:sk-lf-YOUR_SECRET_KEY" | base64
```

### Option B: Send to both Langfuse and local stack (via OTel Collector)

Keep `application.properties` unchanged (pointing to `localhost:4318`), and add a second exporter to `otel-collector-config.yml`:

```yaml
exporters:
  otlphttp/jaeger:
    endpoint: http://jaeger:4318

  otlphttp/langfuse:
    endpoint: https://cloud.langfuse.com/api/public/otel
    headers:
      Authorization: "Basic <BASE64_ENCODED_KEYS>"

  # ... other exporters ...

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlphttp/jaeger, otlphttp/langfuse]
```

This approach lets you keep the local Jaeger/Grafana stack for development while also sending traces to Langfuse.
