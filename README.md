# Spring GenAI

A Spring AI chat agent built for [Amazon Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/). It uses Claude 3.5 Sonnet via AWS Bedrock Converse API and exports traces, metrics, and logs through OpenTelemetry.

## Prerequisites

- Java 25 (Amazon Corretto recommended)
- Docker
- AWS CLI configured with valid credentials
- Terraform >= 1.14.4 (for AgentCore deployment)
- AWS account with Bedrock model access enabled for `us.anthropic.claude-3-5-sonnet-20241022-v2:0`

## Project Structure

```text
src/main/java/com/gpazevedo/spring_genai/
  InvocationsController.java   # POST /invocations — SSE streaming chat (AgentCore contract)
  PingController.java          # GET /ping — health check (AgentCore contract)
  InvocationRequest.java       # Request model: {"input": {"prompt": "..."}}
  JwtUtil.java                 # Extracts user ID from JWT (signature already validated by AgentCore)
  AwsCredentialsCheck.java     # Validates AWS credentials at startup
  JacksonCompatConfig.java     # Jackson ObjectMapper configuration
terraform/                     # Infrastructure as Code for AgentCore deployment
docker-compose.yml             # Local observability stack (Jaeger, Prometheus, Loki, Grafana)
```

## Running Locally

### 1. Build

```bash
./gradlew build
```

### 2. Start the observability stack (optional)

```bash
docker compose up -d
```

This starts:

| Service        | URL                    | Purpose          |
|----------------|------------------------|------------------|
| OTel Collector | localhost:4318 (HTTP)  | Receives telemetry |
| Jaeger         | <http://localhost:16686> | Traces           |
| Prometheus     | <http://localhost:9090>  | Metrics          |
| Loki           | <http://localhost:3100>  | Logs             |
| Grafana        | <http://localhost:3000>  | Dashboards (admin/admin) |

### 3. Run the application

```bash
export AWS_ACCESS_KEY_ID=<your-key>
export AWS_SECRET_ACCESS_KEY=<your-secret>
export AWS_REGION=us-east-1

./gradlew bootRun
```

The app starts on port 8080.

### 4. Test locally

**Health check:**

```bash
curl http://localhost:8080/ping
```

Expected response:

```json
{"status":"Healthy","time_of_last_update":1738972800}
```

**Chat (SSE streaming):**

```bash
curl -N -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": {"prompt": "What is Spring AI?"}}'
```

**Chat with session ID (conversation memory):**

```bash
SESSION_ID=my-local-session-1

# First message
curl -N -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"input": {"prompt": "My name is Alice."}}'

# Follow-up — the agent remembers the previous message
curl -N -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"input": {"prompt": "What is my name?"}}'
```

## Deploying to AgentCore

### 1. Build and push the container image to ECR

```bash
./build-and-push.sh
```

This script:

- Builds the Spring Boot jar
- Builds an ARM64 Docker image (cross-compiles with QEMU if needed)
- Creates an ECR repository and pushes the image

### 2. Deploy infrastructure with Terraform

```bash
./deploy.sh
```

This provisions:

- **AgentCore Runtime** — runs the container in an isolated microVM
- **Cognito User Pool** — JWT/OAuth 2.0 authentication for inbound requests
- **IAM Role** — permissions for Bedrock model invocation, ECR pull, CloudWatch, X-Ray
- **AgentCore Memory** — conversation state (30-day expiry)
- **X-Ray** — sampling rules, trace groups with anomaly detection, Transaction Search

After deployment, note the Terraform outputs:

```text
cognito_user_pool_id = "us-east-1_xxxxxxx"
cognito_client_id    = "xxxxxxxxxxxxxxxxxxxxxxxxxx"
runtime_name         = "spring_genai_123456789012"
runtime_arn          = "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/spring_genai_123456789012-xxxxxxxxxx"
```

### 3. Test the deployed agent

**Get a Cognito JWT token:**

```bash
USER_POOL_ID=$(cd terraform && terraform output -raw cognito_user_pool_id)
CLIENT_ID=$(cd terraform && terraform output -raw cognito_client_id)
RUNTIME_ARN=$(cd terraform && terraform output -raw runtime_arn)
REGION=us-east-1

# Create a test user (one-time)
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username testuser \
  --temporary-password 'TempPass1!' \
  --message-action SUPPRESS \
  --region $REGION

aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username testuser \
  --password 'TestPass1!' \
  --permanent \
  --region $REGION

# Get JWT token (must use AccessToken — it contains the client_id claim that AgentCore validates)
TOKEN=$(aws cognito-idp initiate-auth \
  --client-id $CLIENT_ID \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=testuser,PASSWORD='TestPass1!' \
  --region $REGION \
  --query 'AuthenticationResult.AccessToken' \
  --output text)
```

**Invoke the agent:**

The runtime uses JWT/OAuth authentication (Cognito), so the AWS CLI (`invoke-agent-runtime`)
cannot be used directly — it signs requests with SigV4 which causes an `AccessDeniedException`.
Use `curl` with the Bearer token instead.

The AgentCore data plane API is:

```text
POST https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{agentRuntimeArn}/invocations
```

```bash
# URL-encode the ARN for use in the path
ENCODED_ARN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$RUNTIME_ARN', safe=''))")
AGENTCORE_URL="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/${ENCODED_ARN}/invocations"

# Simple invocation
curl -N -X POST "$AGENTCORE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input": {"prompt": "Hello, what can you do?"}}'

# Generate a session ID (must be >= 33 chars; a UUID is 36)
SESSION_ID=$(uuidgen || cat /proc/sys/kernel/random/uuid)

# Invoke with a session ID for conversation memory
curl -N -X POST "$AGENTCORE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"input": {"prompt": "My name is Alice."}}'

# Follow-up in the same session — the agent remembers context
curl -N -X POST "$AGENTCORE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"input": {"prompt": "What is my name?"}}'
```

### 4. Monitor

**Check runtime status:**

```bash
RUNTIME_ID=$(cd terraform && terraform output -raw runtime_name)

aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id $RUNTIME_ID \
  --region $REGION
```

**Observability** is available in the AWS Console:

- **CloudWatch Logs** — `/aws/bedrock-agentcore/runtimes/<agent-id>/runtime-logs`
- **X-Ray traces** — CloudWatch > X-Ray > Traces (filtered by service `spring-genai`)
- **Metrics** — CloudWatch > Metrics > `bedrock-agentcore` namespace

## API Contract

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/invocations` | POST | Chat interaction (SSE streaming) |
| `/ping` | GET | Health check (delegates to Spring Actuator) |

### POST /invocations

**Request:**

```json
{
  "input": {
    "prompt": "Your message here"
  }
}
```

**Headers injected by AgentCore:**

| Header | Purpose |
|--------|---------|
| `Authorization` | `Bearer <JWT>` — user identity extracted for per-user conversation memory |
| `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` | Session ID for conversation memory |
| `X-Amzn-Trace-Id` | X-Ray trace propagation |
| `traceparent` / `tracestate` | W3C trace context |

**Response:** `Content-Type: text/event-stream` — Server-Sent Events with streamed text chunks.

### GET /ping

**Response:**

```json
{
  "status": "Healthy",
  "time_of_last_update": 1738972800
}
```

Returns `Healthy` when Spring Actuator health is UP, `Unhealthy` otherwise.

## Configuration

Key properties in `application.properties`:

| Property | Default | Override |
|----------|---------|---------|
| OTLP endpoint | `http://localhost:4318` | `OTEL_EXPORTER_OTLP_ENDPOINT` env var |
| Bedrock region | `us-east-1` | `spring.ai.bedrock.aws.region` |
| Model | Claude 3.5 Sonnet v2 | `spring.ai.bedrock.converse.chat.options.model` |
| Temperature | 0.7 | `spring.ai.bedrock.converse.chat.options.temperature` |
| Max tokens | 1024 | `spring.ai.bedrock.converse.chat.options.max-tokens` |
| Trace sampling | 100% | `management.tracing.sampling.probability` |

## Teardown

```bash
cd terraform
terraform destroy
```

This removes all AWS resources (AgentCore runtime, Cognito, IAM roles, X-Ray config). The ECR repository is not managed by Terraform — delete it manually if needed:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr delete-repository \
  --repository-name "spring-genai-${ACCOUNT_ID}" \
  --force \
  --region us-east-1
```
