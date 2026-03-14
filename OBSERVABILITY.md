# Observability

This application exports telemetry via the [AWS Distro for OpenTelemetry (ADOT) Java agent v2.23.0](https://github.com/aws-observability/aws-otel-java-instrumentation). Signals are sent directly to AWS backends — no sidecar collector required.

## Architecture (AgentCore / production)

```text
App + ADOT Java agent (loaded via JAVA_TOOL_OPTIONS in Dockerfile)
  ├── Traces  ──OTLP + SigV4──▶ AWS X-Ray        (https://xray.<region>.amazonaws.com/v1/traces)
  ├── Logs    ──OTLP + SigV4──▶ CloudWatch Logs  (https://logs.<region>.amazonaws.com/v1/logs → otel-rt-logs stream)
  └── Metrics ──────────────── none              (AgentCore publishes built-in runtime metrics to AWS/Bedrock-AgentCore)
```

The ADOT agent handles SigV4 request signing automatically using the runtime's IAM role.

## CloudWatch GenAI Observability (AgentCore agents dashboard)

The AgentCore agents dashboard at **CloudWatch → GenAI Observability → Bedrock AgentCore** shows per-agent metrics, sessions, and traces. Three things are required for an agent to appear there:

### 1. ADOT Java agent must be loaded

`AGENT_OBSERVABILITY_ENABLED=true` only auto-injects the agent for Python runtimes. For Java, the agent must be loaded explicitly. Set in `Dockerfile`:

```dockerfile
ENV JAVA_TOOL_OPTIONS="-javaagent:/app/aws-opentelemetry-agent.jar \
  -Dotel.instrumentation.logback-appender.enabled=false \
  -Dotel.instrumentation.java-util-logging.enabled=false"
```

The system properties disable ADOT's bytecode interception of logback/JUL — the explicit logback `OpenTelemetryAppender` in `logback-spring.xml` handles log export instead.

### 2. OTEL resource attributes must include `cloud.resource_id` and `aws.log.group.names`

Set via `OTEL_RESOURCE_ATTRIBUTES` in Terraform:

```text
service.name=spring-genai
aws.log.group.names=/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
cloud.resource_id=arn:aws:bedrock-agentcore:<region>:<account>:runtime/<runtime-id>/runtime-endpoint/DEFAULT
```

**`cloud.resource_id` must be the endpoint ARN, not the runtime ARN.** The endpoint ARN includes `/runtime-endpoint/DEFAULT`. Using the runtime ARN causes the agent to be invisible in the dashboard even though X-Ray traces are flowing.

Get the endpoint ARN:

```bash
aws bedrock-agentcore-control list-agent-runtime-endpoints \
  --agent-runtime-id <runtime-id>
# → agentRuntimeEndpointArn: .../runtime-endpoint/DEFAULT
```

### 3. CloudWatch Transaction Search must be enabled

One-time account setup (managed in `terraform/observability.tf`):

```bash
aws xray update-trace-segment-destination --destination CloudWatchLogs
aws xray update-indexing-rule --name "Default" \
  --rule '{"Probabilistic":{"DesiredSamplingPercentage":<xray_indexing_percentage>}}'
```

This routes X-Ray spans to CloudWatch Logs (`/aws/spans`) so the dashboard can display traces.

## Log groups

AgentCore creates two types of log streams in the native log group automatically:

| Log group | Stream pattern | Content |
| --- | --- | --- |
| `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` | `[runtime-logs]<UUID>` | Container stdout/stderr (one stream per instance) |
| `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` | `otel-rt-logs` | Structured OTEL logs exported by the ADOT agent |

Our Terraform also manages a legacy group `/aws/bedrock-agentcore/runtimes/<runtime-name>` (without the `-DEFAULT` suffix) with a `runtime-logs` stream — this is unused and can be removed in a future cleanup.

```bash
# Tail container logs from the most recent instance
RUNTIME_ID=$(terraform -chdir=terraform output -raw runtime_id)
STREAM=$(aws logs describe-log-streams \
  --log-group-name "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT" \
  --order-by LastEventTime --descending \
  --query "logStreams[0].logStreamName" --output text)
aws logs tail "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT" \
  --log-stream-names "$STREAM" --follow
```

## Environment variables (set by Terraform in AgentCore)

| Variable | Value | Purpose |
| --- | --- | --- |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.name=…,aws.log.group.names=…,cloud.resource_id=…` | Identifies agent in GenAI Observability dashboard |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | OTLP wire format (also set in Dockerfile as a default) |
| `OTEL_TRACES_EXPORTER` | `otlp` | Enable OTLP trace export |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | `https://xray.<region>.amazonaws.com/v1/traces` | X-Ray OTLP endpoint |
| `OTEL_LOGS_EXPORTER` | `otlp` | Enable OTLP log export |
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` | `https://logs.<region>.amazonaws.com/v1/logs` | CloudWatch Logs OTLP endpoint |
| `OTEL_EXPORTER_OTLP_LOGS_HEADERS` | `x-aws-log-group=…,x-aws-log-stream=otel-rt-logs` | Routes logs to native AgentCore log group |
| `OTEL_METRICS_EXPORTER` | `none` | No OTLP metrics (AgentCore publishes native metrics) |
| `OTEL_AWS_APPLICATION_SIGNALS_ENABLED` | `false` | Prevents duplicate instrumentation |

## Vended log delivery (AgentCore native observability)

In addition to custom OTEL instrumentation, AgentCore has a **vended log delivery** mechanism that registers the runtime as a log/trace source. These are configured in `terraform/observability.tf` and are required for the full GenAI Observability dashboard experience.

| Delivery | Source log type | Destination | Purpose |
| --- | --- | --- | --- |
| `runtime_app_logs` | `APPLICATION_LOGS` | CloudWatch Logs `/aws/vendedlogs/bedrock-agentcore/<runtime-id>` | Structured request/response payload logs from AgentCore |
| `runtime_traces` | `TRACES` | X-Ray | Enables the "Tracing" toggle in the AgentCore console; routes native AgentCore spans to X-Ray |

The `TRACES` delivery is the programmatic equivalent of clicking **Agents → select agent → Tracing pane → Enable** in the console. Without it, AgentCore's own spans do not appear in X-Ray even if OTEL traces from the app do.

IAM permissions required on the runtime role (already in `main.tf`):

- `xray:PutTraceSegments`, `xray:PutTelemetryRecords`, `xray:GetSamplingRules`, `xray:GetSamplingTargets` — for trace delivery and ADOT sampling rule fetching
- `logs:CreateLogStream`, `logs:PutLogEvents` — for APPLICATION_LOGS delivery

## Terraform runtime_id_suffix variable

AgentCore appends a random suffix to the runtime name to form the runtime ID (e.g., `spring_genai_<account>-uoAiAY2qWz`). Most Terraform resources (delivery sources, log groups) reference the runtime directly via `aws_bedrockagentcore_agent_runtime.extended_chat.agent_runtime_arn/id` and auto-correct after a recreate.

The exception is the runtime's own `environment_variables` block: `OTEL_RESOURCE_ATTRIBUTES` and `OTEL_EXPORTER_OTLP_LOGS_HEADERS` embed the endpoint ARN and native log group name, which depend on the runtime ID — a circular dependency Terraform cannot resolve automatically. These are constructed from `var.runtime_id_suffix`.

**After a `terraform destroy` + `apply`**, one extra step is needed:

```bash
./update-runtime-suffix.sh
```

Without this step, the agent will still run and serve requests, but `cloud.resource_id` and `aws.log.group.names` will be stale, so the GenAI Observability dashboard will not show the agent.

## X-Ray configuration (Terraform)

| Resource | Purpose |
| --- | --- |
| `aws_xray_group` | Groups traces for this service; enables Insights |
| `aws_xray_sampling_rule` | 100% sampling for `spring-genai` |
| `aws_cloudwatch_log_resource_policy` | Allows X-Ray to write spans to CloudWatch for Transaction Search |
| `null_resource.xray_transaction_search_setup` | Configures X-Ray trace destination and indexing rule (one-time CLI) |

## Viewing telemetry

| View | Location |
| --- | --- |
| GenAI Observability (agents) | CloudWatch → GenAI Observability → Bedrock AgentCore → Agents |
| GenAI Observability (model invocations) | CloudWatch → GenAI Observability → Model Invocations |
| Service map | CloudWatch → X-Ray → Service Map |
| Traces | CloudWatch → X-Ray → Traces, filter `service("spring-genai")` |
| Application Signals | CloudWatch → Application Signals → Services |
| Container logs | CloudWatch → Logs → `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` |
| OTEL structured logs | Same log group, stream `otel-rt-logs` |
| Vended app logs | CloudWatch → Logs → `/aws/vendedlogs/bedrock-agentcore/<runtime-id>` |

## Spring Boot production profile

`application-production.properties` disables Spring Boot's own OTLP exporters to prevent conflicts with the ADOT agent, and sets 100% trace sampling:

```properties
management.otlp.metrics.export.enabled=false
management.defaults.metrics.export.enabled=false
management.tracing.export.otlp.enabled=false
management.tracing.sampling.probability=1.0
```

**Why 100% sampling is required:** The ADOT Java agent uses the `parentbased_always_on` sampler by default, which inherits the root span's sampling decision. Spring Boot Micrometer Tracing creates the root span (for the incoming HTTP request). If that root span is marked `sampled=false` (the default base rate is 5%), all downstream AWS SDK/Bedrock child spans created by ADOT are also dropped and never reach X-Ray.

> **Note:** 100% sampling is appropriate only for testing with low traffic. At production scale it generates significant cost and volume in X-Ray and CloudWatch. Reduce `management.tracing.sampling.probability` (and the `fixed_rate` in the X-Ray sampling rule in `terraform/observability.tf`) to a lower value before going to production.

## Architecture (local development)

```text
App ──OTLP──▶ OTel Collector ─┬──▶ Jaeger      (traces, http://localhost:16686)
                               ├──▶ Prometheus  (metrics, http://localhost:9090)
                               └──▶ Loki        (logs, via Grafana at http://localhost:3000)
```

Start the local stack with `docker compose up -d`, then run `./gradlew bootRun`.
